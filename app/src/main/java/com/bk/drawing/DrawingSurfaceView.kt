package com.bk.drawing

import android.content.Context
import android.util.AttributeSet
import android.util.Log
import android.view.MotionEvent
import android.view.SurfaceView
import androidx.graphics.lowlatency.BufferInfo
import androidx.graphics.lowlatency.GLFrontBufferedRenderer
import androidx.graphics.opengl.egl.EGLManager

data class StrokeSample(
    val x: Float,
    val y: Float,
    val pressure: Float,
    val isNewStroke: Boolean
)

enum class Tool(val nativeId: Int) { BRUSH(0), ERASER(1) }

class DrawingSurfaceView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null
) : SurfaceView(context, attrs) {

    private val callback = object : GLFrontBufferedRenderer.Callback<StrokeSample> {
        override fun onDrawFrontBufferedLayer(
            eglManager: EGLManager,
            width: Int,
            height: Int,
            bufferInfo: BufferInfo,
            transform: FloatArray,
            param: StrokeSample
        ) {
            if (param.isNewStroke) {
                NativeRenderer.beginStroke()
            }
            NativeRenderer.extendStroke(
                bufferInfo.width, bufferInfo.height,
                transform,
                param.x, param.y, param.pressure
            )
        }

        override fun onDrawMultiBufferedLayer(
            eglManager: EGLManager,
            width: Int,
            height: Int,
            bufferInfo: BufferInfo,
            transform: FloatArray,
            params: Collection<StrokeSample>
        ) {
            // Empty params means a refresh (e.g. orientation change), not a
            // commit — don't promote the in-progress stroke to committed in
            // that case, since the user may still be drawing it.
            if (params.isNotEmpty()) {
                NativeRenderer.commitStroke()
            }
            NativeRenderer.renderDocument(
                bufferInfo.width, bufferInfo.height,
                transform
            )
        }
    }

    private var renderer: GLFrontBufferedRenderer<StrokeSample>? =
        GLFrontBufferedRenderer(this, callback)

    private var currentTool = Tool.BRUSH

    /** Notified after the active tool changes (from the UI button or
     *  the stylus side-button). MainActivity uses this to refresh the
     *  on-screen tool button label. */
    var onToolChanged: ((Tool) -> Unit)? = null

    /** Public so MainActivity's tool button can route through the same
     *  code path the stylus side-button uses. */
    fun toggleTool() {
        currentTool = if (currentTool == Tool.BRUSH) Tool.ERASER else Tool.BRUSH
        NativeRenderer.setTool(currentTool.nativeId)
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
        val tool = event.getToolType(0)
        if (tool != MotionEvent.TOOL_TYPE_STYLUS && tool != MotionEvent.TOOL_TYPE_FINGER) {
            return super.onTouchEvent(event)
        }
        val r = renderer ?: return super.onTouchEvent(event)

        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                r.renderFrontBufferedLayer(
                    StrokeSample(event.x, event.y, event.pressure, isNewStroke = true)
                )
            }
            MotionEvent.ACTION_MOVE -> {
                for (i in 0 until event.historySize) {
                    r.renderFrontBufferedLayer(
                        StrokeSample(
                            event.getHistoricalX(i),
                            event.getHistoricalY(i),
                            event.getHistoricalPressure(i),
                            isNewStroke = false
                        )
                    )
                }
                r.renderFrontBufferedLayer(
                    StrokeSample(event.x, event.y, event.pressure, isNewStroke = false)
                )
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
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
