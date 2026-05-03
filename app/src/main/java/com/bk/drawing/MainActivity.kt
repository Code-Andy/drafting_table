package com.bk.drawing

import android.app.AlertDialog
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.GridLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.SeekBar
import android.widget.TextView
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

    // Page sidebar.
    private lateinit var sidebarScroll: ScrollView
    private lateinit var sidebarLayout: LinearLayout
    private val pageItems = mutableListOf<PageSidebarItem>()
    private val kSidebarWidthDp    = 130
    private val kThumbMaxWidthDp   = 110
    private val kThumbMaxHeightDp  = 200   // generous: aspect drives the actual size
    // Native-state mirrors. Used by onThumbnailsUpdated to detect drift
    // (e.g. switchPage took longer than expected) and self-heal by
    // rebuilding the sidebar — avoids the timing-fragile postDelayed
    // pattern around GL-thread state changes.
    private var lastBuiltActivePage = -1
    private var lastBuiltPageCount  = -1

    private data class PageSidebarItem(
        val container: LinearLayout,
        val imageView: ImageView,
        val label: TextView,
        val bitmap: Bitmap,
        var pageIdx: Int
    )

    // Document state. Multiple documents live under filesDir/documents/<name>/.
    // The current doc's name is mirrored into SharedPreferences so we can
    // re-open it on next launch.
    private lateinit var docNameLabel: TextView
    private var currentDocName: String = ""
    private val kPrefsName = "drawing_app_prefs"
    private val kPrefLastDoc = "last_doc"
    private val kDocumentsRootName = "documents"

    // Brush size + vector width sliders. Geometric (log-scale) progress
    // mapping so equal-distance ticks produce equal-ratio size changes.
    // Persisted across launches.
    private lateinit var brushSizeLabel: TextView
    private lateinit var vectorWidthLabel: TextView
    private var brushSizeScale = 1.0f
    private var vectorLineWidth = 2.0f
    private val kPrefBrushSize     = "brush_size_scale"
    private val kPrefVectorWidth   = "vector_line_width"
    private val kBrushSizeMin = 0.25f
    private val kBrushSizeMax = 4.0f
    private val kVectorWidthMin = 0.5f
    private val kVectorWidthMax = 16.0f

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

        // Migrate the legacy single-doc layout, then pick which document
        // to open: last-used (if it still exists), the only doc on disk,
        // or a fresh "Untitled 1".
        migrateLegacyDocumentIfNeeded()
        val available = listDocumentNames()
        val initialDoc = lastOpenedDocName()?.takeIf { it in available }
            ?: available.firstOrNull()
            ?: nextUntitledName()
        currentDocName = initialDoc
        rememberDocName(initialDoc)
        val docDir = docDirFor(initialDoc).apply { mkdirs() }
        // Use the synchronous setter here (not loadDocument) — at startup
        // there's nothing in-memory yet, so the queued-action path isn't
        // needed and we'd just incur an extra render before anything loads.
        NativeRenderer.setDocumentDir(docDir.absolutePath)

        // Restore brush size + vector width from prefs and push to native.
        brushSizeScale = prefs().getFloat(kPrefBrushSize, 1.0f)
            .coerceIn(kBrushSizeMin, kBrushSizeMax)
        vectorLineWidth = prefs().getFloat(kPrefVectorWidth, 2.0f)
            .coerceIn(kVectorWidthMin, kVectorWidthMax)
        NativeRenderer.setBrushSize(brushSizeScale)
        NativeRenderer.setVectorLineWidth(vectorLineWidth)

        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }

        // Root: horizontal LinearLayout — page sidebar on the left, then a
        // FrameLayout that hosts the canvas and the right-side button panel.
        // Touches dispatch to topmost child first, so taps on the sidebar
        // and panel never reach the SurfaceView underneath them.
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
        }

        sidebarScroll = buildSidebarScroll()
        root.addView(
            sidebarScroll,
            LinearLayout.LayoutParams(
                kSidebarWidthDp.dp,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        )

        val canvasFrame = FrameLayout(this)
        val canvas = DrawingSurfaceView(this).also { v ->
            v.onToolChanged = { tool -> updateToolButton(tool) }
            v.onThumbnailsUpdated = { onThumbnailsUpdated() }
            canvasFrame.addView(
                v,
                FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT
                )
            )
        }
        drawingView = canvas

        canvasFrame.addView(buildButtonPanel(), topRightPanelParams())
        root.addView(
            canvasFrame,
            LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.MATCH_PARENT, 1.0f   // weight = 1
            )
        )

        setContentView(root)

        // Opt into the highest refresh rate the panel offers (90 Hz on the MovinkPad).
        val highest = display?.supportedModes?.maxByOrNull { it.refreshRate }
        if (highest != null) {
            val attrs = window.attributes
            attrs.preferredDisplayModeId = highest.modeId
            window.attributes = attrs
        }

        // Once the GL thread has had time to ensureLoaded(), pull the real
        // layer/page state so the sidebar and layer button reflect reality.
        canvas.postDelayed({
            syncLayerStateFromNative()
            rebuildSidebar()
        }, 250L)
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

        panel.addView(buildBrushSizeSlider(), panelChildParams())
        panel.addView(buildVectorWidthSlider(), panelChildParams())
        panel.addView(buildColorGrid(), panelChildParams())

        return panel
    }

    /** Brush-size slider (geometric mapping from progress 0..100 → scale
     *  kBrushSizeMin..kBrushSizeMax). 1× lands at progress=50. */
    private fun buildBrushSizeSlider(): View {
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            alpha = 0.92f
        }
        brushSizeLabel = TextView(this).apply {
            textSize = 11f
            text = formatBrushSizeLabel(brushSizeScale)
        }
        container.addView(brushSizeLabel)

        val seek = SeekBar(this).apply {
            max = 100
            progress = brushScaleToProgress(brushSizeScale)
            // 120 dp gives a usable touch target without bloating the panel.
            layoutParams = LinearLayout.LayoutParams(120.dp,
                ViewGroup.LayoutParams.WRAP_CONTENT)
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(sb: SeekBar?, p: Int, fromUser: Boolean) {
                    val s = progressToBrushScale(p)
                    brushSizeScale = s
                    brushSizeLabel.text = formatBrushSizeLabel(s)
                    NativeRenderer.setBrushSize(s)
                }
                override fun onStartTrackingTouch(sb: SeekBar?) {}
                override fun onStopTrackingTouch(sb: SeekBar?) {
                    prefs().edit().putFloat(kPrefBrushSize, brushSizeScale).apply()
                }
            })
        }
        container.addView(seek)
        return container
    }

    /** Vector line width slider (geometric mapping). */
    private fun buildVectorWidthSlider(): View {
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            alpha = 0.92f
        }
        vectorWidthLabel = TextView(this).apply {
            textSize = 11f
            text = formatVectorWidthLabel(vectorLineWidth)
        }
        container.addView(vectorWidthLabel)

        val seek = SeekBar(this).apply {
            max = 100
            progress = vectorWidthToProgress(vectorLineWidth)
            layoutParams = LinearLayout.LayoutParams(120.dp,
                ViewGroup.LayoutParams.WRAP_CONTENT)
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(sb: SeekBar?, p: Int, fromUser: Boolean) {
                    val w = progressToVectorWidth(p)
                    vectorLineWidth = w
                    vectorWidthLabel.text = formatVectorWidthLabel(w)
                    NativeRenderer.setVectorLineWidth(w)
                }
                override fun onStartTrackingTouch(sb: SeekBar?) {}
                override fun onStopTrackingTouch(sb: SeekBar?) {
                    prefs().edit().putFloat(kPrefVectorWidth, vectorLineWidth).apply()
                }
            })
        }
        container.addView(seek)
        return container
    }

    private fun formatBrushSizeLabel(scale: Float) =
        "Brush: %.2f×".format(scale)
    private fun formatVectorWidthLabel(w: Float) =
        "Width: %.1f px".format(w)

    private fun progressToBrushScale(p: Int): Float =
        (kBrushSizeMin * Math.pow(
            (kBrushSizeMax / kBrushSizeMin).toDouble(), p / 100.0)).toFloat()

    private fun brushScaleToProgress(scale: Float): Int =
        (Math.log((scale / kBrushSizeMin).toDouble())
            / Math.log((kBrushSizeMax / kBrushSizeMin).toDouble())
            * 100).toInt().coerceIn(0, 100)

    private fun progressToVectorWidth(p: Int): Float =
        (kVectorWidthMin * Math.pow(
            (kVectorWidthMax / kVectorWidthMin).toDouble(), p / 100.0)).toFloat()

    private fun vectorWidthToProgress(w: Float): Int =
        (Math.log((w / kVectorWidthMin).toDouble())
            / Math.log((kVectorWidthMax / kVectorWidthMin).toDouble())
            * 100).toInt().coerceIn(0, 100)

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
            Tool.BRUSH       -> "Brush"
            Tool.ERASER      -> "Eraser"
            Tool.BUCKET      -> "Bucket"
            Tool.LINE        -> "Line"
            Tool.RECTANGLE   -> "Rect"
            Tool.CIRCLE      -> "Circle"
            Tool.ELLIPSE     -> "Ellipse"
            Tool.SELECT      -> "Select"
            Tool.SELECT_RECT -> "Marquee"
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

    // ---- Document I/O ----------------------------------------------------

    private fun documentsRoot(): File =
        File(filesDir, kDocumentsRootName).apply { mkdirs() }

    private fun docDirFor(name: String): File = File(documentsRoot(), name)

    private fun listDocumentNames(): List<String> =
        documentsRoot().listFiles { f -> f.isDirectory }
            ?.map { it.name }
            ?.sorted()
            ?: emptyList()

    /** Pick a fresh "Untitled N" not already on disk. */
    private fun nextUntitledName(): String {
        val existing = listDocumentNames().toSet()
        var n = 1
        while ("Untitled $n" in existing) n++
        return "Untitled $n"
    }

    /** Move the legacy single-doc filesDir/document/ to filesDir/documents/document/
     *  the first time this version of the app runs. No-op if there's
     *  nothing to migrate or migration already happened. */
    private fun migrateLegacyDocumentIfNeeded() {
        val legacy = File(filesDir, "document")
        if (!legacy.isDirectory) return
        val target = docDirFor("document")
        if (target.exists()) return     // already migrated or naming collision
        if (!documentsRoot().exists()) documentsRoot().mkdirs()
        if (legacy.renameTo(target)) {
            android.util.Log.i("DrawingApp", "migrated legacy document/ → documents/document/")
        } else {
            android.util.Log.e("DrawingApp", "failed to migrate legacy document/")
        }
    }

    private fun prefs() = getSharedPreferences(kPrefsName, Context.MODE_PRIVATE)
    private fun rememberDocName(name: String) {
        prefs().edit().putString(kPrefLastDoc, name).apply()
    }
    private fun lastOpenedDocName(): String? = prefs().getString(kPrefLastDoc, null)

    /** Switch to the given doc on the native side, persist as last-opened,
     *  and refresh the sidebar / labels. Creates the directory if absent. */
    private fun switchToDocument(name: String) {
        val dir = docDirFor(name).apply { mkdirs() }
        currentDocName = name
        rememberDocName(name)
        if (::docNameLabel.isInitialized) docNameLabel.text = name
        NativeRenderer.loadDocument(dir.absolutePath)
        // Force redraw triggers the action drain (close current + set new
        // path); subsequent multi-buffer pass loads the new doc.
        drawingView?.forceRedraw()
        // Reset our sidebar mirrors so onThumbnailsUpdated triggers a
        // rebuild against the new doc's page state.
        lastBuiltPageCount = -1
        lastBuiltActivePage = -1
    }

    private fun userNewDocument() {
        switchToDocument(nextUntitledName())
    }

    private fun userOpenDocument() {
        val docs = listDocumentNames()
        if (docs.isEmpty()) {
            // Nothing to open; treat as new.
            userNewDocument()
            return
        }
        val items = docs.toTypedArray()
        AlertDialog.Builder(this)
            .setTitle("Open document")
            .setItems(items) { _, which ->
                val picked = items[which]
                if (picked != currentDocName) switchToDocument(picked)
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    /** Two-step delete with a confirmation dialog. After deletion, switch
     *  to another existing doc (or create a fresh Untitled if the deleted
     *  doc was the only one) so we never end up in a no-document state. */
    private fun userDeleteCurrentDocument() {
        val toDelete = currentDocName
        if (toDelete.isEmpty()) return
        AlertDialog.Builder(this)
            .setTitle("Delete document")
            .setMessage("Delete “$toDelete”? This can't be undone.")
            .setPositiveButton("Delete") { _, _ -> performDelete(toDelete) }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun performDelete(name: String) {
        // Pick a target to switch to BEFORE deleting on disk: the first
        // remaining doc, or a fresh Untitled if `name` was the only one.
        val others = listDocumentNames().filter { it != name }
        val target = others.firstOrNull() ?: nextUntitledName()
        switchToDocument(target)
        // The native side queues a closeCurrentDocument; by the time the
        // action drains it points at `target`, not `name`. Auto-save only
        // happens on stroke commit / explicit persist, neither of which
        // can race here (user isn't drawing during a confirm dialog).
        val ok = docDirFor(name).deleteRecursively()
        if (!ok) {
            android.util.Log.e("DrawingApp", "deleteRecursively($name) failed")
        }
    }

    // ---- Page sidebar ----------------------------------------------------

    private fun buildSidebarScroll(): ScrollView {
        val scroll = ScrollView(this).apply {
            isFillViewport = true
            setBackgroundColor(0xFFE8EAEEu.toInt())
        }
        sidebarLayout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            val pad = 8.dp
            setPadding(pad, pad, pad, pad)
        }
        scroll.addView(
            sidebarLayout,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        )
        return scroll
    }

    /** Document name + New/Open buttons. Lives at the top of the sidebar
     *  above the page list. The label updates whenever switchToDocument
     *  runs so the user can always see which doc is open. */
    private fun buildDocHeader(): View {
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(0, 0, 0, 8.dp)
        }
        docNameLabel = TextView(this).apply {
            text = currentDocName
            textSize = 13f
            gravity = Gravity.CENTER
            setPadding(0, 0, 0, 6.dp)
            setTextColor(0xFF222222u.toInt())
            // Long-press to rename — deferred for a later pass.
        }
        container.addView(
            docNameLabel,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        )
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
        }
        val newBtn = Button(this).apply {
            text = "New"
            alpha = 0.92f
            setOnClickListener { userNewDocument() }
        }
        val openBtn = Button(this).apply {
            text = "Open"
            alpha = 0.92f
            setOnClickListener { userOpenDocument() }
        }
        val btnParams = LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1.0f
        ).apply { setMargins(2.dp, 0, 2.dp, 0) }
        row.addView(newBtn, btnParams)
        row.addView(openBtn, btnParams)
        container.addView(
            row,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        )
        // Delete on its own row, visually de-emphasized so a stray tap
        // is harder; the confirmation dialog is the real safety net.
        val deleteBtn = Button(this).apply {
            text = "Delete"
            alpha = 0.85f
            setOnClickListener { userDeleteCurrentDocument() }
        }
        container.addView(
            deleteBtn,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply { setMargins(2.dp, 4.dp, 2.dp, 0) }
        )
        return container
    }

    /** Recreate every sidebar entry from current page state. Called after
     *  any change that affects page count or active page. Cheap — pages
     *  are typically a handful, and the bitmap allocations are small. */
    private fun rebuildSidebar() {
        sidebarLayout.removeAllViews()
        pageItems.clear()

        // Doc header (name + New/Open) sits above the page list and a
        // thin separator line.
        sidebarLayout.addView(
            buildDocHeader(),
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        )
        val sep = View(this).apply { setBackgroundColor(0xFFB0B4BAu.toInt()) }
        sidebarLayout.addView(
            sep,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 1.dp
            ).apply { setMargins(0, 4.dp, 0, 4.dp) }
        )

        val pageCount = NativeRenderer.getPageCount().coerceAtLeast(1)
        val active    = NativeRenderer.getActivePage()
        for (i in 0 until pageCount) {
            val item = createPageSidebarItem(i, isActive = (i == active))
            pageItems.add(item)
            sidebarLayout.addView(item.container, sidebarItemParams())
        }

        val addButton = Button(this).apply {
            text = "+ Page"
            alpha = 0.92f
            setOnClickListener { userAddPage() }
        }
        sidebarLayout.addView(addButton, sidebarItemParams())

        // Record what we just rendered so onThumbnailsUpdated can detect
        // post-build drift (the GL thread may apply a queued switch/add
        // after this rebuild) and re-rebuild itself.
        lastBuiltPageCount  = pageCount
        lastBuiltActivePage = active

        // Hand the live Bitmaps to the renderer so the next multi-buffer
        // pass populates them; trigger that pass via forceRedraw.
        drawingView?.setThumbnailTargets(
            pageItems.associate { it.pageIdx to it.bitmap }
        )
        drawingView?.forceRedraw()
    }

    /** Thumbnail size in pixels matching the page's aspect ratio, fit
     *  inside the sidebar width / max height bounds. Falls back to the
     *  raw maximums if the SurfaceView hasn't been laid out yet. */
    private fun thumbDimensions(): Pair<Int, Int> {
        val maxW = kThumbMaxWidthDp.dp
        val maxH = kThumbMaxHeightDp.dp
        val pageW = drawingView?.width ?: 0
        val pageH = drawingView?.height ?: 0
        if (pageW <= 0 || pageH <= 0) return Pair(maxW, maxH)
        val aspect = pageH.toFloat() / pageW.toFloat()
        return if (maxW * aspect <= maxH) {
            Pair(maxW, (maxW * aspect).toInt().coerceAtLeast(1))
        } else {
            Pair((maxH / aspect).toInt().coerceAtLeast(1), maxH)
        }
    }

    private fun createPageSidebarItem(idx: Int, isActive: Boolean): PageSidebarItem {
        val (thumbW, thumbH) = thumbDimensions()
        val bitmap = Bitmap.createBitmap(thumbW, thumbH, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(Color.WHITE)

        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            val pad = 4.dp
            setPadding(pad, pad, pad, pad)
            // Active page gets a thin accent border via a colored bg.
            setBackgroundColor(
                if (isActive) 0xFF4080FFu.toInt() else 0x00000000
            )
            isClickable = true
            isFocusable = true
            setOnClickListener {
                // Always enqueue — native no-ops if idx is already active.
                // We don't read getActivePage() here because it can be
                // stale relative to queued switches (last-write-wins on
                // the native side; the optimistic skip used to silently
                // eat the user's tap if the sidebar showed stale state).
                NativeRenderer.switchPage(idx)
                drawingView?.forceRedraw()
                // syncLayerStateFromNative & sidebar rebuild are driven
                // by onThumbnailsUpdated when native state changes.
            }
        }

        val imageView = ImageView(this).apply {
            setImageBitmap(bitmap)
            setBackgroundColor(Color.WHITE)
            layoutParams = LinearLayout.LayoutParams(thumbW, thumbH)
        }
        container.addView(imageView)

        val label = TextView(this).apply {
            text = "Page ${idx + 1}"
            gravity = Gravity.CENTER
            textSize = 11f
            setTextColor(if (isActive) Color.WHITE else 0xFF333333u.toInt())
            setPadding(0, 4.dp, 0, 0)
        }
        container.addView(
            label,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            )
        )

        return PageSidebarItem(container, imageView, label, bitmap, idx)
    }

    private fun sidebarItemParams() = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.WRAP_CONTENT
    ).apply {
        topMargin = 4.dp
        bottomMargin = 4.dp
    }

    private fun userAddPage() {
        NativeRenderer.addPage()
        drawingView?.forceRedraw()
        // Sidebar rebuild + layer-state sync happen in onThumbnailsUpdated
        // once the GL thread has actually applied the queued addPage.
    }

    /** Called on the UI thread after the renderer finishes a thumbnail pass.
     *  Drives sidebar self-healing: any time native page state diverges
     *  from what the sidebar last rendered, rebuild it. This avoids the
     *  timing fragility of postDelayed callbacks waiting on GL drains. */
    private fun onThumbnailsUpdated() {
        for (item in pageItems) item.imageView.invalidate()
        val pc = NativeRenderer.getPageCount()
        val ap = NativeRenderer.getActivePage()
        if (pc != lastBuiltPageCount || ap != lastBuiltActivePage) {
            syncLayerStateFromNative()
            rebuildSidebar()
        }
    }

    // ---- Helpers ---------------------------------------------------------

    private val Int.dp: Int
        get() = (this * resources.displayMetrics.density).toInt()
}
