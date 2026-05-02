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
// through Sample (a stream per stroke); the line tool flows through
// LinePreview (one entry per pen position during the drag).
sealed class StrokeAction {
    data class Sample(
        val x: Float, val y: Float, val pressure: Float,
        val isNewStroke: Boolean
    ) : StrokeAction()

    data class LinePreview(
        val x0: Float, val y0: Float,
        val x1: Float, val y1: Float
    ) : StrokeAction()
}

// LINE doesn't correspond to a native "stroke tool" (it doesn't flow
// through beginStroke / extendStroke / commitStroke); its nativeId is
// unused but kept consistent with the others for symmetry.
enum class Tool(val nativeId: Int) { BRUSH(0), ERASER(1), LINE(2) }

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
                is StrokeAction.LinePreview -> {
                    NativeRenderer.renderLinePreview(
                        bufferInfo.width, bufferInfo.height,
                        transform,
                        param.x0, param.y0, param.x1, param.y1
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

    // Line-tool drag state (in view-space pixels).
    private var lineP0X = 0f
    private var lineP0Y = 0f
    private var lineP1X = 0f
    private var lineP1Y = 0f

    private var currentTool = Tool.BRUSH

    /** Notified after the active tool changes (from the UI button or
     *  the stylus side-button). MainActivity uses this to refresh the
     *  on-screen tool button label. */
    var onToolChanged: ((Tool) -> Unit)? = null

    /** Public so MainActivity's tool button can route through the same
     *  code path the stylus side-button uses. Cycles brush → eraser →
     *  line → brush. */
    fun toggleTool() {
        currentTool = when (currentTool) {
            Tool.BRUSH  -> Tool.ERASER
            Tool.ERASER -> Tool.LINE
            Tool.LINE   -> Tool.BRUSH
        }
        // Native only knows about the raster stroke tools (brush/eraser);
        // LINE is handled entirely on the Kotlin side via the line tool
        // gesture path, so we don't update the native tool state for it.
        if (currentTool != Tool.LINE) {
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
            Tool.LINE               -> handleLineEvent(r, event)
        }
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

    private fun handleLineEvent(
        r: GLFrontBufferedRenderer<StrokeAction>,
        event: MotionEvent
    ): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                lineP0X = event.x; lineP0Y = event.y
                lineP1X = event.x; lineP1Y = event.y
                r.renderFrontBufferedLayer(
                    StrokeAction.LinePreview(lineP0X, lineP0Y, lineP1X, lineP1Y)
                )
            }
            MotionEvent.ACTION_MOVE -> {
                lineP1X = event.x; lineP1Y = event.y
                r.renderFrontBufferedLayer(
                    StrokeAction.LinePreview(lineP0X, lineP0Y, lineP1X, lineP1Y)
                )
            }
            MotionEvent.ACTION_UP -> {
                NativeRenderer.addLine(lineP0X, lineP0Y, lineP1X, lineP1Y)
                // commit() clears the front buffer's preview and triggers a
                // multi-buffer redraw via onDrawMultiBufferedLayer, which
                // applies the queued line and re-renders the document.
                r.commit()
            }
            MotionEvent.ACTION_CANCEL -> {
                r.commit()
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
