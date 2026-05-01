package com.bk.drawing

import android.content.Context
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.SurfaceView
import androidx.graphics.lowlatency.BufferInfo
import androidx.graphics.lowlatency.GLFrontBufferedRenderer
import androidx.graphics.opengl.egl.EGLManager

data class StrokePoint(val x: Float, val y: Float, val pressure: Float)

class DrawingSurfaceView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null
) : SurfaceView(context, attrs) {

    private val callback = object : GLFrontBufferedRenderer.Callback<StrokePoint> {
        override fun onDrawFrontBufferedLayer(
            eglManager: EGLManager,
            width: Int,
            height: Int,
            bufferInfo: BufferInfo,
            transform: FloatArray,
            param: StrokePoint
        ) {
            // width/height are view-space (landscape) dims. bufferInfo.width/height are
            // the actual buffer pixel dims (often portrait on devices whose panel is
            // physically portrait). The transform maps view-pixel -> buffer-pixel.
            NativeRenderer.drawFrontDot(
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
            params: Collection<StrokePoint>
        ) {
            val flat = FloatArray(params.size * 3)
            var i = 0
            for (p in params) {
                flat[i++] = p.x
                flat[i++] = p.y
                flat[i++] = p.pressure
            }
            NativeRenderer.drawAllDots(
                bufferInfo.width, bufferInfo.height,
                transform,
                flat, params.size
            )
        }
    }

    private var renderer: GLFrontBufferedRenderer<StrokePoint>? =
        GLFrontBufferedRenderer(this, callback)

    override fun onTouchEvent(event: MotionEvent): Boolean {
        val tool = event.getToolType(0)
        if (tool != MotionEvent.TOOL_TYPE_STYLUS && tool != MotionEvent.TOOL_TYPE_FINGER) {
            return super.onTouchEvent(event)
        }
        val r = renderer ?: return super.onTouchEvent(event)

        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                r.renderFrontBufferedLayer(StrokePoint(event.x, event.y, event.pressure))
            }
            MotionEvent.ACTION_MOVE -> {
                // Walk historical samples between vsyncs — Android delivers many input
                // samples per frame and we want every dab, not just the latest.
                for (i in 0 until event.historySize) {
                    r.renderFrontBufferedLayer(
                        StrokePoint(
                            event.getHistoricalX(i),
                            event.getHistoricalY(i),
                            event.getHistoricalPressure(i)
                        )
                    )
                }
                r.renderFrontBufferedLayer(StrokePoint(event.x, event.y, event.pressure))
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
