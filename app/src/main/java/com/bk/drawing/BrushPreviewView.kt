package com.bk.drawing

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.view.View

// BrushPreviewView — thin outline circle drawn on top of the canvas at
// the pen's current position to preview the brush's effective dab
// radius. Sits in the same FrameLayout as DrawingSurfaceView; touch
// events pass through (isClickable / isFocusable = false).
//
// State is push-only from MainActivity (which knows brush size and view
// scale). null centerX = nothing to show; calling show(x, y, radius)
// updates state and invalidates the view.
class BrushPreviewView(context: Context) : View(context) {

    private var centerX: Float? = null
    private var centerY: Float = 0f
    private var radiusPx: Float = 0f

    private val density = context.resources.displayMetrics.density
    private val paint = Paint().apply {
        // Two-tone outline: a fatter light halo behind a thin dark
        // line so the circle stays visible on both light and dark
        // canvas content. We draw two passes in onDraw.
        style = Paint.Style.STROKE
        isAntiAlias = true
    }

    init {
        setWillNotDraw(false)
        isClickable = false
        isFocusable = false
    }

    /** Place the preview at view-px coords with the given view-px
     *  radius. Triggers a redraw. No-op (and clears any prior preview)
     *  if [radius] is non-positive. */
    fun show(x: Float, y: Float, radius: Float) {
        if (radius <= 0f) {
            hide()
            return
        }
        centerX = x
        centerY = y
        radiusPx = radius
        invalidate()
    }

    /** Stop drawing the preview. */
    fun hide() {
        if (centerX != null) {
            centerX = null
            invalidate()
        }
    }

    override fun onDraw(canvas: Canvas) {
        val cx = centerX ?: return

        // Light halo first — slightly thicker, semi-transparent white —
        // then the dark hairline on top. Reads on both ink-on-paper
        // strokes and brighter raster regions.
        paint.color = 0x80FFFFFF.toInt()
        paint.strokeWidth = 2.4f * density
        canvas.drawCircle(cx, centerY, radiusPx, paint)

        paint.color = 0xC0000000.toInt()
        paint.strokeWidth = 1.0f * density
        canvas.drawCircle(cx, centerY, radiusPx, paint)
    }
}
