package com.bk.drawing

import android.content.Context
import android.util.AttributeSet
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

    override fun onTouchEvent(event: MotionEvent): Boolean {
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

    fun release() {
        renderer?.release(true)
        renderer = null
    }

    override fun onDetachedFromWindow() {
        release()
        super.onDetachedFromWindow()
    }
}
