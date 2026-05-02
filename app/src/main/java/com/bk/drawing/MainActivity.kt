package com.bk.drawing

import android.os.Bundle
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.GridLayout
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
    private lateinit var gridButton: Button
    private lateinit var snapButton: Button

    // Grid cycles off → lines → dots → off.
    private var gridState = 0   // 0 = off, 1 = lines, 2 = dots
    private var snapEnabled = true

    // Local prediction of native layer state. Initialized from a one-shot
    // read after the GL thread has had a chance to load tiles from disk.
    private var layerCount = 1
    private var activeLayerIndex = 0

    // Preset brush palette — 0xRRGGBB. First entry is the default.
    private val palette = intArrayOf(
        0x14171F,   // dark blue-black (default)
        0xB02828,   // red
        0xC07020,   // orange
        0xB8A020,   // mustard
        0x408840,   // green
        0x3060B8,   // blue
        0x782878,   // purple
        0x806040    // brown
    )

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

        val undoButton = Button(this).apply {
            text = "Undo"
            alpha = 0.92f
            setOnClickListener { userUndo() }
        }
        panel.addView(undoButton, panelChildParams())

        val redoButton = Button(this).apply {
            text = "Redo"
            alpha = 0.92f
            setOnClickListener { userRedo() }
        }
        panel.addView(redoButton, panelChildParams())

        val addButton = Button(this).apply {
            text = "+ Layer"
            alpha = 0.92f
            setOnClickListener { userAddLayer() }
        }
        panel.addView(addButton, panelChildParams())

        val addVectorButton = Button(this).apply {
            text = "+ V Layer"
            alpha = 0.92f
            setOnClickListener { userAddVectorLayer() }
        }
        panel.addView(addVectorButton, panelChildParams())

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

        gridButton = Button(this).apply {
            text = "Grid: off"
            alpha = 0.92f
            setOnClickListener { cycleGrid() }
        }
        panel.addView(gridButton, panelChildParams())

        val deleteButton = Button(this).apply {
            text = "Delete"
            alpha = 0.92f
            setOnClickListener { userDeleteSelection() }
        }
        panel.addView(deleteButton, panelChildParams())

        snapButton = Button(this).apply {
            text = "Snap: on"
            alpha = 0.92f
            setOnClickListener { toggleSnap() }
        }
        panel.addView(snapButton, panelChildParams())

        val resetViewButton = Button(this).apply {
            text = "Reset View"
            alpha = 0.92f
            setOnClickListener { drawingView?.resetView() }
        }
        panel.addView(resetViewButton, panelChildParams())

        panel.addView(buildColorGrid(), panelChildParams())

        return panel
    }

    private fun cycleGrid() {
        gridState = (gridState + 1) % 3
        when (gridState) {
            0 -> {
                NativeRenderer.setGridEnabled(false)
                gridButton.text = "Grid: off"
            }
            1 -> {
                NativeRenderer.setGridStyle(1)
                NativeRenderer.setGridEnabled(true)
                gridButton.text = "Grid: lines"
            }
            2 -> {
                NativeRenderer.setGridStyle(2)
                NativeRenderer.setGridEnabled(true)
                gridButton.text = "Grid: dots"
            }
        }
        drawingView?.forceRedraw()
    }

    private fun buildColorGrid(): GridLayout {
        val grid = GridLayout(this).apply {
            columnCount = 4
            alpha = 0.92f
        }
        palette.forEach { rgb ->
            val swatch = View(this).apply {
                setBackgroundColor(0xFF000000.toInt() or rgb)
                setOnClickListener { NativeRenderer.setBrushColor(rgb) }
            }
            val lp = GridLayout.LayoutParams().apply {
                width  = 32.dp
                height = 32.dp
                setMargins(2.dp, 2.dp, 2.dp, 2.dp)
            }
            grid.addView(swatch, lp)
        }
        return grid
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
        toolButton.text = when (tool) {
            Tool.BRUSH     -> "Brush"
            Tool.ERASER    -> "Eraser"
            Tool.LINE      -> "Line"
            Tool.RECTANGLE -> "Rect"
            Tool.CIRCLE    -> "Circle"
            Tool.ELLIPSE   -> "Ellipse"
            Tool.SELECT    -> "Select"
        }
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

    private fun userAddVectorLayer() {
        NativeRenderer.addVectorLayer()
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

    private fun userDeleteSelection() {
        if (NativeRenderer.hasSelection()) {
            NativeRenderer.deleteSelection()
            drawingView?.forceRedraw()
        }
    }

    private fun toggleSnap() {
        snapEnabled = !snapEnabled
        NativeRenderer.setSnapEnabled(snapEnabled)
        snapButton.text = if (snapEnabled) "Snap: on" else "Snap: off"
    }

    private fun userUndo() {
        NativeRenderer.undo()
        // Undo runs on the GL thread on the next render; trigger one and
        // resync our local layer-state mirror once it's had a chance to
        // apply (LayerAdd / LayerClear undos can change layer count or
        // active index).
        drawingView?.forceRedraw()
        drawingView?.postDelayed({ syncLayerStateFromNative() }, 60L)
    }

    private fun userRedo() {
        NativeRenderer.redo()
        drawingView?.forceRedraw()
        drawingView?.postDelayed({ syncLayerStateFromNative() }, 60L)
    }

    // ---- Helpers ---------------------------------------------------------

    private val Int.dp: Int
        get() = (this * resources.displayMetrics.density).toInt()
}
