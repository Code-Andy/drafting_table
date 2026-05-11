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
            // Velocity from the latest step only — averaging across
            // the whole history lags behind both direction reversals
            // and decelerations, so prediction overshoots when the
            // pen turns or stops. Latest-step velocity tracks current
            // motion directly; the deceleration scale below handles
            // the one case it can't catch on its own (the pen still
            // appears to be moving fast on the very last sample
            // before a sharp stop).
            val prev = history.elementAt(history.size - 2)
            val cur  = history.last()
            val dtMs = (cur.tNs - prev.tNs) / 1_000_000.0f
            if (dtMs > 0.5f) {
                var vx = (cur.x - prev.x) / dtMs
                var vy = (cur.y - prev.y) / dtMs

                // Deceleration-aware scale: compare the latest step's
                // speed to the previous step's speed. If we're
                // slowing down, scale prediction toward zero (the
                // pen is likely about to stop, so projecting ahead
                // would overshoot). Constant or accelerating motion
                // gets full prediction.
                var scale = 1.0f
                if (history.size >= 3) {
                    val prev2 = history.elementAt(history.size - 3)
                    val pdtMs = (prev.tNs - prev2.tNs) / 1_000_000.0f
                    if (pdtMs > 0.5f) {
                        val pvx = (prev.x - prev2.x) / pdtMs
                        val pvy = (prev.y - prev2.y) / pdtMs
                        val curSpeed  = kotlin.math.sqrt(vx * vx + vy * vy)
                        val prevSpeed = kotlin.math.sqrt(pvx * pvx + pvy * pvy)
                        if (prevSpeed > 1e-3f && curSpeed < prevSpeed) {
                            scale = curSpeed / prevSpeed
                        }
                    }
                }

                // Clamp magnitude (safety net against bad samples).
                val mag = kotlin.math.sqrt(vx * vx + vy * vy)
                if (mag > kMaxVelocityViewPxPerMs) {
                    val s = kMaxVelocityViewPxPerMs / mag
                    vx *= s; vy *= s
                }
                px = x + vx * kLookAheadMs * scale
                py = y + vy * kLookAheadMs * scale
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
