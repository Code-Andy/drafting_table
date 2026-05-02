package com.bk.drawing

import android.os.Bundle
import android.view.Gravity
import android.view.KeyEvent
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import java.io.File

class MainActivity : AppCompatActivity() {

    private var drawingView: DrawingSurfaceView? = null
    private lateinit var toolButton: Button
    private lateinit var layerButton: Button

    // Local prediction of native layer state. Initialized from a one-shot
    // read after the GL thread has had a chance to load tiles from disk.
    private var layerCount = 1
    private var activeLayerIndex = 0

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Where the document is persisted on disk. Tiles live as
        // <docDir>/layer_<i>/tile_<tx>_<ty>.bin. Set before any GL op.
        val docDir = File(filesDir, "document").apply { mkdirs() }
        NativeRenderer.setDocumentDir(docDir.absolutePath)

        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }

        // Root: FrameLayout so the button panel can sit on top of the canvas.
        // Child z-order = add-order; touches dispatch to topmost child first,
        // so taps on the panel never reach the SurfaceView underneath.
        val root = FrameLayout(this)

        val canvas = DrawingSurfaceView(this).also { v ->
            v.onToolChanged = { tool -> updateToolButton(tool) }
            root.addView(
                v,
                FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT
                )
            )
        }
        drawingView = canvas

        root.addView(buildButtonPanel(), topRightPanelParams())

        setContentView(root)

        // Opt into the highest refresh rate the panel offers (90 Hz on the MovinkPad).
        val highest = display?.supportedModes?.maxByOrNull { it.refreshRate }
        if (highest != null) {
            val attrs = window.attributes
            attrs.preferredDisplayModeId = highest.modeId
            window.attributes = attrs
        }

        // Once the GL thread has had time to ensureLoaded(), pull the real
        // layer count/active so the layer button label is accurate.
        canvas.postDelayed({ syncLayerStateFromNative() }, 250L)
    }

    override fun onDestroy() {
        drawingView?.release()
        drawingView = null
        super.onDestroy()
    }

    // Volume keys still cycle/add layers — useful when finger-touching
    // buttons isn't convenient mid-sketch. Also catch stylus-button
    // keycodes here, in case the device reports stylus buttons as keys
    // rather than as MotionEvent button bits.
    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val keyCode = event.keyCode
        when (keyCode) {
            KeyEvent.KEYCODE_VOLUME_UP, KeyEvent.KEYCODE_VOLUME_DOWN -> {
                if (event.action == KeyEvent.ACTION_DOWN) {
                    if (keyCode == KeyEvent.KEYCODE_VOLUME_UP) userCycleLayer()
                    else                                       userAddLayer()
                }
                return true
            }
            KeyEvent.KEYCODE_STYLUS_BUTTON_PRIMARY,
            KeyEvent.KEYCODE_STYLUS_BUTTON_SECONDARY,
            KeyEvent.KEYCODE_STYLUS_BUTTON_TERTIARY -> {
                if (event.action == KeyEvent.ACTION_DOWN
                    && keyCode == KeyEvent.KEYCODE_STYLUS_BUTTON_SECONDARY) {
                    drawingView?.toggleTool()
                }
                return true
            }
        }
        return super.dispatchKeyEvent(event)
    }

    // ---- UI construction -------------------------------------------------

    private fun buildButtonPanel(): LinearLayout {
        val panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val pad = 12.dp
            setPadding(pad, pad, pad, pad)
        }

        toolButton = Button(this).apply {
            text = "Brush"
            alpha = 0.92f
            setOnClickListener { drawingView?.toggleTool() }
        }
        panel.addView(toolButton, panelChildParams())

        val addButton = Button(this).apply {
            text = "+ Layer"
            alpha = 0.92f
            setOnClickListener { userAddLayer() }
        }
        panel.addView(addButton, panelChildParams())

        layerButton = Button(this).apply {
            text = "Layer 1/1"
            alpha = 0.92f
            setOnClickListener { userCycleLayer() }
        }
        panel.addView(layerButton, panelChildParams())

        val clearButton = Button(this).apply {
            text = "Clear"
            alpha = 0.92f
            setOnClickListener { userClearLayer() }
        }
        panel.addView(clearButton, panelChildParams())

        return panel
    }

    private fun topRightPanelParams() = FrameLayout.LayoutParams(
        ViewGroup.LayoutParams.WRAP_CONTENT,
        ViewGroup.LayoutParams.WRAP_CONTENT
    ).apply {
        gravity = Gravity.TOP or Gravity.END
        topMargin = 24.dp
        marginEnd  = 24.dp
    }

    private fun panelChildParams() = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.WRAP_CONTENT,
        ViewGroup.LayoutParams.WRAP_CONTENT
    ).apply {
        topMargin = 4.dp
        bottomMargin = 4.dp
    }

    // ---- State updates ---------------------------------------------------

    private fun syncLayerStateFromNative() {
        val count = NativeRenderer.getLayerCount().coerceAtLeast(1)
        val active = NativeRenderer.getActiveLayer().coerceIn(0, count - 1)
        layerCount = count
        activeLayerIndex = active
        updateLayerButton()
    }

    private fun updateToolButton(tool: Tool) {
        toolButton.text = if (tool == Tool.BRUSH) "Brush" else "Eraser"
    }

    private fun updateLayerButton() {
        layerButton.text = "Layer ${activeLayerIndex + 1}/$layerCount"
    }

    private fun userAddLayer() {
        NativeRenderer.addLayer()
        layerCount++
        activeLayerIndex = layerCount - 1
        updateLayerButton()
    }

    private fun userCycleLayer() {
        NativeRenderer.cycleActiveLayer()
        activeLayerIndex = (activeLayerIndex + 1) % layerCount
        updateLayerButton()
    }

    private fun userClearLayer() {
        NativeRenderer.clearActiveLayer()
        // The clear is a queued action that applies on the GL thread.
        // Force a multi-buffer redraw so the cleared state shows up right
        // away (otherwise it only appears after the next stroke commit).
        drawingView?.forceRedraw()
    }

    // ---- Helpers ---------------------------------------------------------

    private val Int.dp: Int
        get() = (this * resources.displayMetrics.density).toInt()
}
