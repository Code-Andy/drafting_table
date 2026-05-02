package com.bk.drawing

import android.content.Context
import android.util.AttributeSet
import android.util.Log
import android.view.MotionEvent
import android.view.SurfaceView
import androidx.graphics.lowlatency.BufferInfo
import androidx.graphics.lowlatency.GLFrontBufferedRenderer
import androidx.graphics.opengl.egl.EGLManager

// Param type for the front-buffered renderer. Brush/eraser strokes flow
// through Sample (a stream per stroke); the shape tools (line, rect,
// circle, ellipse) flow through ShapePreview (one entry per pen position
// during the drag), with shapeType selecting which shape to render.
sealed class StrokeAction {
    data class Sample(
        val x: Float, val y: Float, val pressure: Float,
        val isNewStroke: Boolean
    ) : StrokeAction()

    data class ShapePreview(
        val shapeType: Int,             // matches NativeRenderer.renderShapePreview
        val x0: Float, val y0: Float,
        val x1: Float, val y1: Float,
        val snapped: Boolean            // shows snap marker at (x1, y1)
    ) : StrokeAction()
}

// Only BRUSH and ERASER correspond to native "stroke tools" (running
// through beginStroke / extendStroke / commitStroke). The shape tools
// have their own gesture path and don't update the native stroke tool.
enum class Tool(val nativeId: Int) {
    BRUSH    (0),
    ERASER   (1),
    LINE     (2),
    RECTANGLE(3),
    CIRCLE   (4),
    ELLIPSE  (5),
    SELECT   (6);

    /** Shape-type code passed to NativeRenderer for shape tools. */
    val shapeType: Int
        get() = when (this) {
            LINE      -> 0
            RECTANGLE -> 1
            CIRCLE    -> 2
            ELLIPSE   -> 3
            else      -> -1
        }

    val isShape: Boolean
        get() = this == LINE || this == RECTANGLE || this == CIRCLE || this == ELLIPSE
}

class DrawingSurfaceView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null
) : SurfaceView(context, attrs) {

    private val callback = object : GLFrontBufferedRenderer.Callback<StrokeAction> {
        override fun onDrawFrontBufferedLayer(
            eglManager: EGLManager,
            width: Int,
            height: Int,
            bufferInfo: BufferInfo,
            transform: FloatArray,
            param: StrokeAction
        ) {
            when (param) {
                is StrokeAction.Sample -> {
                    if (param.isNewStroke) {
                        NativeRenderer.beginStroke()
                    }
                    NativeRenderer.extendStroke(
                        bufferInfo.width, bufferInfo.height,
                        transform,
                        param.x, param.y, param.pressure
                    )
                }
                is StrokeAction.ShapePreview -> {
                    NativeRenderer.renderShapePreview(
                        bufferInfo.width, bufferInfo.height,
                        transform,
                        param.shapeType,
                        param.x0, param.y0, param.x1, param.y1,
                        param.snapped
                    )
                }
            }
        }

        override fun onDrawMultiBufferedLayer(
            eglManager: EGLManager,
            width: Int,
            height: Int,
            bufferInfo: BufferInfo,
            transform: FloatArray,
            params: Collection<StrokeAction>
        ) {
            // Only commit a brush/eraser stroke if this batch actually
            // contained Sample entries. Line previews go through here too
            // when the line tool's commit calls renderer.commit(); we
            // mustn't bake an empty stroke in that case.
            val hadStrokeSamples = params.any { it is StrokeAction.Sample }
            if (hadStrokeSamples) {
                NativeRenderer.commitStroke()
            }
            NativeRenderer.renderDocument(
                bufferInfo.width, bufferInfo.height,
                transform
            )
        }
    }

    private var renderer: GLFrontBufferedRenderer<StrokeAction>? =
        GLFrontBufferedRenderer(this, callback)

    // Shape-tool drag state (in view-space pixels). Shared by Line,
    // Rectangle, Circle, Ellipse — only the interpretation differs.
    private var shapeP0X = 0f
    private var shapeP0Y = 0f
    private var shapeP1X = 0f
    private var shapeP1Y = 0f

    private var currentTool = Tool.BRUSH

    /** Notified after the active tool changes (from the UI button or
     *  the stylus side-button). MainActivity uses this to refresh the
     *  on-screen tool button label. */
    var onToolChanged: ((Tool) -> Unit)? = null

    /** Public so MainActivity's tool button can route through the same
     *  code path the stylus side-button uses. Cycles through every tool. */
    fun toggleTool() {
        currentTool = when (currentTool) {
            Tool.BRUSH     -> Tool.ERASER
            Tool.ERASER    -> Tool.LINE
            Tool.LINE      -> Tool.RECTANGLE
            Tool.RECTANGLE -> Tool.CIRCLE
            Tool.CIRCLE    -> Tool.ELLIPSE
            Tool.ELLIPSE   -> Tool.SELECT
            Tool.SELECT    -> Tool.BRUSH
        }
        // Native only knows about the raster stroke tools (brush/eraser);
        // shape and select tools are handled entirely on the Kotlin side
        // via their own gesture paths.
        if (currentTool == Tool.BRUSH || currentTool == Tool.ERASER) {
            NativeRenderer.setTool(currentTool.nativeId)
        }
        Log.i("DrawingApp", "tool -> ${currentTool.name.lowercase()}")
        onToolChanged?.invoke(currentTool)
    }

    // Last-seen stylus button bitmask, used to detect press transitions
    // even on devices/states that don't fire ACTION_BUTTON_PRESS (notably
    // Wacom EMR while the pen is hovering — buttonState is reported on
    // hover events too, but the discrete press action isn't always).
    private var prevButtonState = 0

    /**
     * Detect stylus side-button presses two ways:
     *   1. ACTION_BUTTON_PRESS with actionButton == BUTTON_STYLUS_SECONDARY
     *      (the standard path; fires while pen is in contact).
     *   2. A 0→1 transition of the BUTTON_STYLUS_SECONDARY bit in
     *      event.buttonState (catches presses during hover that don't
     *      generate ACTION_BUTTON_PRESS).
     */
    private fun handleStylusButton(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_BUTTON_PRESS) {
            val ab = event.actionButton
            Log.i("DrawingApp", "ACTION_BUTTON_PRESS: 0x${ab.toString(16)}")
            if (ab == MotionEvent.BUTTON_STYLUS_SECONDARY) {
                toggleTool()
                prevButtonState = event.buttonState
                return true
            }
        }
        val state = event.buttonState
        val newlyPressed = state and prevButtonState.inv()
        prevButtonState = state
        if (newlyPressed and MotionEvent.BUTTON_STYLUS_SECONDARY != 0) {
            Log.i("DrawingApp",
                "stylus button transition (during action=${event.actionMasked}): " +
                "0x${newlyPressed.toString(16)}")
            toggleTool()
            return true
        }
        return false
    }

    override fun onGenericMotionEvent(event: MotionEvent): Boolean {
        if (handleStylusButton(event)) return true
        return super.onGenericMotionEvent(event)
    }

    override fun onHoverEvent(event: MotionEvent): Boolean {
        if (handleStylusButton(event)) return true
        return super.onHoverEvent(event)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (handleStylusButton(event)) return true
        val tt = event.getToolType(0)
        if (tt != MotionEvent.TOOL_TYPE_STYLUS && tt != MotionEvent.TOOL_TYPE_FINGER) {
            return super.onTouchEvent(event)
        }
        val r = renderer ?: return super.onTouchEvent(event)

        return when (currentTool) {
            Tool.BRUSH, Tool.ERASER -> handleStrokeEvent(r, event)
            Tool.SELECT             -> handleSelectEvent(event)
            else                    -> handleShapeEvent(r, event, currentTool.shapeType)
        }
    }

    // Drag state for the SELECT tool.
    private var selectMode = 0          // 0=none, 1=move, 2=scale, 3=rotate
    private var selectChanged = false   // true if we should persist on UP

    private fun handleSelectEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                selectMode = NativeRenderer.beginInteractionAt(event.x, event.y)
                selectChanged = false
                forceRedraw()
            }
            MotionEvent.ACTION_MOVE -> {
                when (selectMode) {
                    1 -> { // move — snap-aware absolute, native uses captured offset
                        NativeRenderer.moveSelectionTo(event.x, event.y)
                        selectChanged = true
                        forceRedraw()
                    }
                    2, 3 -> { // scale / rotate — absolute pen position
                        NativeRenderer.updateInteractionAt(event.x, event.y)
                        selectChanged = true
                        forceRedraw()
                    }
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                NativeRenderer.endInteraction()
                if (selectChanged) {
                    NativeRenderer.persistActiveVectorLayer()
                }
                selectMode = 0
                selectChanged = false
            }
        }
        return true
    }

    private fun handleStrokeEvent(
        r: GLFrontBufferedRenderer<StrokeAction>,
        event: MotionEvent
    ): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                r.renderFrontBufferedLayer(
                    StrokeAction.Sample(event.x, event.y, event.pressure,
                                        isNewStroke = true)
                )
            }
            MotionEvent.ACTION_MOVE -> {
                for (i in 0 until event.historySize) {
                    r.renderFrontBufferedLayer(
                        StrokeAction.Sample(
                            event.getHistoricalX(i),
                            event.getHistoricalY(i),
                            event.getHistoricalPressure(i),
                            isNewStroke = false
                        )
                    )
                }
                r.renderFrontBufferedLayer(
                    StrokeAction.Sample(event.x, event.y, event.pressure,
                                        isNewStroke = false)
                )
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                r.commit()
            }
        }
        return true
    }

    // Reused output buffer for NativeRenderer.snapPoint — avoids
    // allocating a fresh FloatArray per pen sample.
    private val snapOut = FloatArray(3)
    private var p1Snapped = false

    /** Snap the given pen position to the nearest snap target if any.
     *  Updates p1Snapped as a side effect. */
    private fun snap(x: Float, y: Float): Pair<Float, Float> {
        NativeRenderer.snapPoint(x, y, snapOut)
        p1Snapped = snapOut[2] > 0.5f
        return if (p1Snapped) Pair(snapOut[0], snapOut[1]) else Pair(x, y)
    }

    private fun handleShapeEvent(
        r: GLFrontBufferedRenderer<StrokeAction>,
        event: MotionEvent,
        shapeType: Int
    ): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                val (sx, sy) = snap(event.x, event.y)
                shapeP0X = sx; shapeP0Y = sy
                shapeP1X = sx; shapeP1Y = sy
                r.renderFrontBufferedLayer(
                    StrokeAction.ShapePreview(shapeType,
                        shapeP0X, shapeP0Y, shapeP1X, shapeP1Y, p1Snapped)
                )
            }
            MotionEvent.ACTION_MOVE -> {
                val (sx, sy) = snap(event.x, event.y)
                shapeP1X = sx; shapeP1Y = sy
                r.renderFrontBufferedLayer(
                    StrokeAction.ShapePreview(shapeType,
                        shapeP0X, shapeP0Y, shapeP1X, shapeP1Y, p1Snapped)
                )
            }
            MotionEvent.ACTION_UP -> {
                when (shapeType) {
                    0 -> NativeRenderer.addLine     (shapeP0X, shapeP0Y, shapeP1X, shapeP1Y)
                    1 -> NativeRenderer.addRectangle(shapeP0X, shapeP0Y, shapeP1X, shapeP1Y)
                    2 -> NativeRenderer.addCircle   (shapeP0X, shapeP0Y, shapeP1X, shapeP1Y)
                    3 -> NativeRenderer.addEllipse  (shapeP0X, shapeP0Y, shapeP1X, shapeP1Y)
                }
                // commit() clears the front buffer preview and triggers a
                // multi-buffer redraw via onDrawMultiBufferedLayer, which
                // applies the queued shape and re-renders the document.
                r.commit()
                p1Snapped = false
            }
            MotionEvent.ACTION_CANCEL -> {
                r.commit()
                p1Snapped = false
            }
        }
        return true
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        // First time we know the surface size, kick a multi-buffer pass so
        // the saved document loads and shows immediately on app launch
        // (rather than only appearing after the first stroke commit).
        if (oldw == 0 && oldh == 0 && w > 0 && h > 0) {
            renderer?.commit()
        }
    }

    /** Force a multi-buffer redraw (used after layer-state changes that
     *  need to be reflected on screen, e.g. clearing a layer). */
    fun forceRedraw() {
        renderer?.commit()
    }

    fun release() {
        renderer?.release(true)
        renderer = null
    }

    override fun onDetachedFromWindow() {
        release()
        super.onDetachedFromWindow()
    }
}
