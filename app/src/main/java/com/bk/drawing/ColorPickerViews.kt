package com.bk.drawing

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Shader
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.View

// Two custom Views shared by ColorPickerDialog.
//
// HsvSquareView   2D explore surface for saturation (x) and value (y) at a
//                 given hue. Renders three blended layers — pure hue base,
//                 white-to-transparent horizontal, transparent-to-black
//                 vertical — with a circular crosshair at the active (s, v).
// HueSliderView   Horizontal hue strip (red → magenta → red), with a
//                 vertical bar marker at the active hue.
//
// Both are touch-interactive: the active values update on DOWN and MOVE
// and the listener fires for each change so the dialog can preview the
// new color live. Touch coordinates are clamped to the View's bounds so a
// drag past the edge sticks the marker at 0 or 1.

class HsvSquareView @JvmOverloads constructor(
    context: Context, attrs: AttributeSet? = null, defStyle: Int = 0
) : View(context, attrs, defStyle) {

    var hue: Float = 0f
        set(value) { field = value; rebuildHueShader(); invalidate() }
    var saturation: Float = 1f
    var value: Float = 1f

    /** Fired on every touch down / move; receives the new s, v in [0, 1]. */
    var onSvChange: ((s: Float, v: Float) -> Unit)? = null

    private val basePaint     = Paint(Paint.ANTI_ALIAS_FLAG)
    private val hueLayerPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val whiteOverlay  = Paint(Paint.ANTI_ALIAS_FLAG)
    private val blackOverlay  = Paint(Paint.ANTI_ALIAS_FLAG)
    private val crosshairFill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val crosshairOuter = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE; strokeWidth = 2f
        color = Color.WHITE
    }
    private val crosshairInner = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE; strokeWidth = 1f
        color = Color.argb(0xC0, 0, 0, 0)
    }

    private val rect = RectF()

    init {
        rebuildHueShader()
    }

    private fun rebuildHueShader() {
        // Pure-hue color at full sat/val for the base fill.
        hueLayerPaint.color = Color.HSVToColor(floatArrayOf(hue, 1f, 1f))
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        rect.set(0f, 0f, w.toFloat(), h.toFloat())
        whiteOverlay.shader = LinearGradient(
            0f, 0f, w.toFloat(), 0f,
            Color.WHITE, Color.TRANSPARENT, Shader.TileMode.CLAMP
        )
        blackOverlay.shader = LinearGradient(
            0f, h.toFloat(), 0f, 0f,
            Color.BLACK, Color.TRANSPARENT, Shader.TileMode.CLAMP
        )
    }

    override fun onDraw(canvas: Canvas) {
        // Layer 1 — pure hue base.
        canvas.drawRect(rect, hueLayerPaint)
        // Layer 2 — white-to-transparent (saturation: 0 = white).
        canvas.drawRect(rect, whiteOverlay)
        // Layer 3 — black-to-transparent (value: 0 = black).
        canvas.drawRect(rect, blackOverlay)

        // Crosshair at (s * w, (1 - v) * h).
        val cx = saturation * width
        val cy = (1f - value) * height
        val r = 7f * resources.displayMetrics.density
        // Solid fill in the active color so the crosshair reads on any bg.
        crosshairFill.color = Color.HSVToColor(floatArrayOf(hue, saturation, value))
        canvas.drawCircle(cx, cy, r - 2f, crosshairFill)
        canvas.drawCircle(cx, cy, r,         crosshairOuter)
        canvas.drawCircle(cx, cy, r + 1f,    crosshairInner)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_MOVE -> {
                parent?.requestDisallowInterceptTouchEvent(true)
                val s = (event.x / width).coerceIn(0f, 1f)
                val v = 1f - (event.y / height).coerceIn(0f, 1f)
                saturation = s
                value      = v
                invalidate()
                onSvChange?.invoke(s, v)
                return true
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                parent?.requestDisallowInterceptTouchEvent(false)
                return true
            }
        }
        return super.onTouchEvent(event)
    }
}

class HueSliderView @JvmOverloads constructor(
    context: Context, attrs: AttributeSet? = null, defStyle: Int = 0
) : View(context, attrs, defStyle) {

    var hue: Float = 0f

    /** Fired on every touch down / move; receives the new hue in [0, 360). */
    var onHueChange: ((h: Float) -> Unit)? = null

    private val barPaint    = Paint(Paint.ANTI_ALIAS_FLAG)
    private val borderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE; strokeWidth = 1f
        color = Color.argb(0x66, 0, 0, 0)
    }
    private val markerOuter = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE; strokeWidth = 2f
        color = Color.argb(0xE0, 0, 0, 0)
    }
    private val markerInner = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        color = Color.WHITE
    }

    private val rect = RectF()

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        rect.set(0f, 0f, w.toFloat(), h.toFloat())
        // Hue gradient: 7 stops covering 0..360 hue, both ends red.
        val stops = intArrayOf(
            Color.HSVToColor(floatArrayOf(  0f, 1f, 1f)),
            Color.HSVToColor(floatArrayOf( 60f, 1f, 1f)),
            Color.HSVToColor(floatArrayOf(120f, 1f, 1f)),
            Color.HSVToColor(floatArrayOf(180f, 1f, 1f)),
            Color.HSVToColor(floatArrayOf(240f, 1f, 1f)),
            Color.HSVToColor(floatArrayOf(300f, 1f, 1f)),
            Color.HSVToColor(floatArrayOf(360f, 1f, 1f)),
        )
        val positions = floatArrayOf(0f, 1f/6, 2f/6, 3f/6, 4f/6, 5f/6, 1f)
        barPaint.shader = LinearGradient(
            0f, 0f, w.toFloat(), 0f, stops, positions, Shader.TileMode.CLAMP
        )
    }

    override fun onDraw(canvas: Canvas) {
        canvas.drawRect(rect, barPaint)
        canvas.drawRect(rect, borderPaint)
        // Vertical marker bar at the current hue position.
        val x = (hue / 360f).coerceIn(0f, 1f) * width
        val mw = 4f * resources.displayMetrics.density
        val mh = 3f * resources.displayMetrics.density
        canvas.drawRect(x - mw / 2f, -mh, x + mw / 2f, height + mh, markerInner)
        canvas.drawRect(x - mw / 2f, -mh, x + mw / 2f, height + mh, markerOuter)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_MOVE -> {
                parent?.requestDisallowInterceptTouchEvent(true)
                val h = (event.x / width).coerceIn(0f, 1f) * 360f
                hue = h
                invalidate()
                onHueChange?.invoke(h)
                return true
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                parent?.requestDisallowInterceptTouchEvent(false)
                return true
            }
        }
        return super.onTouchEvent(event)
    }
}
