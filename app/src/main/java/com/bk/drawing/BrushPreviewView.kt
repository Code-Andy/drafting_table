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

    // Recent (x, y, time) samples for motion prediction. The preview
    // is drawn through the standard View pipeline (invalidate() waits
    // for the next vsync), while stroke dabs render via the
    // GLFrontBufferedRenderer (no vsync gate) — that gap is ~1 frame.
    // Predicting the pen position forward by roughly one frame closes
    // the visible gap so the outline tracks the brush tip.
    private data class TimedPoint(val x: Float, val y: Float, val tNs: Long)
    private val history = ArrayDeque<TimedPoint>()
    private val kHistoryCap   = 4
    // Project ~12 ms ahead. Slightly less than a 60 Hz frame so a
    // sudden stop overshoots minimally; tune if needed.
    private val kLookAheadMs  = 12.0f
    // Velocity beyond this (view-px per ms) is clamped — keeps
    // unintentional flicks from launching the outline far past the
    // pen tip.
    private val kMaxVelocityViewPxPerMs = 8.0f

    init {
        setWillNotDraw(false)
        isClickable = false
        isFocusable = false
    }

    /** Place the preview at view-px coords with the given view-px
     *  radius. Triggers a redraw. No-op (and clears any prior preview)
     *  if [radius] is non-positive. The drawn position is predicted
     *  forward from recent samples to compensate for the View
     *  pipeline's vsync-aligned draw latency. */
    fun show(x: Float, y: Float, radius: Float) {
        if (radius <= 0f) {
            hide()
            return
        }
        val now = System.nanoTime()
        history.addLast(TimedPoint(x, y, now))
        while (history.size > kHistoryCap) history.removeFirst()

        var px = x
        var py = y
        if (history.size >= 2) {
            val first = history.first()
            val last  = history.last()
            val dtMs  = (last.tNs - first.tNs) / 1_000_000.0f
            if (dtMs > 0.5f) {
                var vx = (last.x - first.x) / dtMs
                var vy = (last.y - first.y) / dtMs
                // Clamp magnitude.
                val mag = kotlin.math.sqrt(vx * vx + vy * vy)
                if (mag > kMaxVelocityViewPxPerMs) {
                    val s = kMaxVelocityViewPxPerMs / mag
                    vx *= s; vy *= s
                }
                px = x + vx * kLookAheadMs
                py = y + vy * kLookAheadMs
            }
        }
        centerX = px
        centerY = py
        radiusPx = radius
        invalidate()
    }

    /** Stop drawing the preview. */
    fun hide() {
        history.clear()
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
