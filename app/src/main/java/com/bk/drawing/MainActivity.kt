package com.bk.drawing

import android.app.AlertDialog
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.view.Gravity
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.GridLayout
import android.widget.HorizontalScrollView
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.PopupMenu
import android.widget.ScrollView
import android.widget.SeekBar
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.res.ResourcesCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import java.io.File

/**
 * Main UI host. Layout follows the Concept A v4 design:
 *
 *   ┌─────┬───────┬──────────┬─────────────────────────────┐
 *   │tool │ pages │  layer   │           canvas            │
 *   │rail │  bar  │  panel   │         (drawing)           │
 *   │56dp │ 84dp  │  180dp   │       (weight = 1)          │
 *   ├─────┴───────┴──────────┴─────────────────────────────┤
 *   │                  status bar (28dp)                   │
 *   └──────────────────────────────────────────────────────┘
 *
 * Floating chrome (undo/redo chip) is positioned over the canvas frame.
 */
class MainActivity : AppCompatActivity() {

    private var drawingView: DrawingSurfaceView? = null

    // ---- Tool rail ------------------------------------------------------
    // Rail tiles are pure Views with isSelected() driving their bg drawable
    // and tint. We keep references so onToolChanged can flip selection
    // without rebuilding the rail.
    private val railToolTiles  = mutableMapOf<Tool, ImageView>()
    private lateinit var gridRailTile:   ImageView   // also used as panel toggle
    private lateinit var pagesRailTile:  ImageView

    // ---- Layer panel ----------------------------------------------------
    private lateinit var layerListContainer: LinearLayout
    private lateinit var layerActiveHeading: TextView
    private lateinit var layerOpacitySlider: SeekBar
    private lateinit var layerOpacityValue: TextView

    // Layer drag-to-reorder state. dragSourceIdx is the native idx (not
    // ui position); -1 means not dragging. Other rows are displaced via
    // translationY as the dragged row passes over their centers.
    private var dragSourceIdx: Int = -1
    private var dragSourceView: View? = null
    private var dragStartRawY: Float = 0f
    private var dragStartTranslationY: Float = 0f
    private var dragRowHeightPx: Int = 0
    private var dragCurrentTargetUiPos: Int = -1

    // Page drag-to-reorder state. Same shape as the layer fields. Page
    // sidebar layout is top-down with idx 0 at top, so uiPos == pageIdx
    // and no conversion is needed.
    private var dragPageSourceIdx: Int = -1
    private var dragPageSourceView: View? = null
    private var dragPageStartRawY: Float = 0f
    private var dragPageStartTranslationY: Float = 0f
    private var dragPageSlotHeightPx: Int = 0
    private var dragPageCurrentTargetIdx: Int = -1
    private lateinit var sizeSlider: SeekBar
    private lateinit var sizeSliderLabel: TextView
    private lateinit var sizeValueLabel: TextView
    private lateinit var colorChip: View

    // ---- Status bar -----------------------------------------------------
    private lateinit var statusToolText:  TextView
    private lateinit var statusDocText:   TextView
    private lateinit var statusGridText:  TextView
    private lateinit var statusSnapText:  TextView
    private lateinit var statusPageText:  TextView

    // ---- Page sidebar (restyled to 84dp) -------------------------------
    private lateinit var sidebarScroll: ScrollView
    private lateinit var sidebarLayout: LinearLayout
    private lateinit var docsButton:    LinearLayout
    private lateinit var docsButtonLabel: TextView
    private val pageItems = mutableListOf<PageSidebarItem>()
    private val kSidebarWidthDp   = 84
    // Page-thumbnail bounding box. Actual thumbnail dimensions are
    // derived from the canvas aspect ratio inside thumbDimensions() so
    // the thumb is always the same shape as the page — no letterboxing.
    // The design ships portrait (60×78); we honor whichever fit produces
    // the canvas aspect within these bounds.
    private val kThumbMaxWidthDp  = 60
    private val kThumbMaxHeightDp = 78
    private var lastBuiltActivePage = -1
    private var lastBuiltPageCount  = -1

    private data class PageSidebarItem(
        val container: LinearLayout,
        val frame: FrameLayout,
        val imageView: ImageView,
        val numberBadge: TextView,
        val bitmap: Bitmap,
        var pageIdx: Int
    )

    // ---- App state mirrors ---------------------------------------------
    private var gridState = 0          // 0 = off, 1 = lines, 2 = dots
    private var snapEnabled = true
    private var stylusOnly  = true
    private var layerCount = 1
    private var activeLayerIndex = 0
    private var currentToolMirror: Tool = Tool.BRUSH
    private val kPrefsName = "drawing_app_prefs"
    private val kPrefLastDoc = "last_doc"
    private val kDocumentsRootName = "documents"
    private var currentDocName: String = ""

    // ---- Brush + vector width (single slider routes to the right one) --
    private var brushSizeScale = 1.0f
    private var vectorLineWidth = 2.0f
    private var brushAlpha = 1.0f
    private var brushHardness = 1.0f
    private val kPrefBrushSize     = "brush_size_scale"
    private val kPrefVectorWidth   = "vector_line_width"
    private val kPrefStylusOnly    = "stylus_only"
    private val kPrefBrushAlpha    = "brush_alpha"
    private val kPrefBrushHardness = "brush_hardness"
    private val kBrushSizeMin = 0.25f
    private val kBrushSizeMax = 4.0f
    private val kVectorWidthMin = 0.5f
    private val kVectorWidthMax = 16.0f
    // Brush-alpha mapping: invert the dab-accumulation curve so the
    // slider position equals target *stroke* opacity (not per-dab α).
    // A stroke at position (x, y) is roughly N overlapping dabs deep
    // (kSpacing = 0.18 × radius → ~1/0.18 ≈ 5.5 overlap at the
    // stroke spine). With per-dab α and premultiplied-over compose,
    // cumulative coverage = 1 - (1 - α)^N. Inverting:
    //     α(target) = 1 - (1 - target)^(1/N)
    // gives a per-dab α whose stroke result matches `target`. So
    // slider=50 produces a 50%-opaque-looking stroke instead of one
    // that's nearly identical to 100% (which is what the prior
    // mappings gave because dab accumulation saturates quickly).
    private val kAlphaDabsPerOverlap = 6.0

    // Preset brush palette — 0xRRGGBB. First entry is the default.
    private val palette = intArrayOf(
        0x14171F, 0xB02828, 0xC07020, 0xB8A020,
        0x408840, 0x3060B8, 0x782878, 0x806040
    )
    private var currentColorRgb = palette[0]

    // ---- Fonts (downloadable) ------------------------------------------
    private var fontMono:          Typeface? = null
    private var fontMonoSemibold:  Typeface? = null
    private var fontInter:         Typeface? = null
    private var fontInterSemibold: Typeface? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        loadFonts()

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
        NativeRenderer.setDocumentDir(docDir.absolutePath)

        // Restore brush size + vector width + opacity and push to native.
        brushSizeScale = prefs().getFloat(kPrefBrushSize, 1.0f)
            .coerceIn(kBrushSizeMin, kBrushSizeMax)
        vectorLineWidth = prefs().getFloat(kPrefVectorWidth, 2.0f)
            .coerceIn(kVectorWidthMin, kVectorWidthMax)
        brushAlpha = prefs().getFloat(kPrefBrushAlpha, 1.0f)
            .coerceIn(0.0f, 1.0f)
        brushHardness = prefs().getFloat(kPrefBrushHardness, 1.0f)
            .coerceIn(0.0f, 1.0f)
        NativeRenderer.setBrushSize(brushSizeScale)
        NativeRenderer.setVectorLineWidth(vectorLineWidth)
        NativeRenderer.setBrushAlpha(brushAlpha)
        NativeRenderer.setBrushHardness(brushHardness)
        // Palm-rejection mode persists across launches; defaults on so
        // accidental finger touches don't draw out of the box.
        stylusOnly = prefs().getBoolean(kPrefStylusOnly, true)

        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }

        // Outer column: main horizontal row (rail + sidebar + panel + canvas)
        // on top, status bar pinned across the bottom.
        val outer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(getColor(R.color.paper))
        }

        val mainRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
        }

        mainRow.addView(buildToolRail(),
            LinearLayout.LayoutParams(56.dp, ViewGroup.LayoutParams.MATCH_PARENT))

        sidebarScroll = buildPageSidebar()
        mainRow.addView(sidebarScroll,
            LinearLayout.LayoutParams(kSidebarWidthDp.dp, ViewGroup.LayoutParams.MATCH_PARENT))

        mainRow.addView(buildLayerPanel(),
            LinearLayout.LayoutParams(180.dp, ViewGroup.LayoutParams.MATCH_PARENT))

        // Canvas frame: drawing surface + floating undo/redo chip on top.
        val canvasFrame = FrameLayout(this).apply {
            setBackgroundColor(getColor(R.color.bezel))
        }
        val canvas = DrawingSurfaceView(this).also { v ->
            v.onToolChanged = { tool -> onToolChanged(tool) }
            v.onThumbnailsUpdated = { onThumbnailsUpdated() }
            v.stylusOnlyDrawing = stylusOnly
            canvasFrame.addView(
                v,
                FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT
                )
            )
        }
        drawingView = canvas
        canvasFrame.addView(buildUndoRedoChip(), undoRedoChipParams())
        mainRow.addView(
            canvasFrame,
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1.0f)
        )

        outer.addView(
            mainRow,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1.0f
            )
        )
        outer.addView(buildStatusBar(),
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 28.dp))

        setContentView(outer)

        // Opt into the highest refresh rate the panel offers (90 Hz on the MovinkPad).
        val highest = display?.supportedModes?.maxByOrNull { it.refreshRate }
        if (highest != null) {
            val attrs = window.attributes
            attrs.preferredDisplayModeId = highest.modeId
            window.attributes = attrs
        }

        // Apply initial selection state to the brush tile.
        onToolChanged(Tool.BRUSH)
        // Push the persisted color into native and reflect it in the chip.
        NativeRenderer.setBrushColor(currentColorRgb)
        updateColorChip()
        // Once the GL thread has had time to ensureLoaded(), pull real
        // layer/page state and rebuild the panels.
        canvas.postDelayed({
            syncLayerStateFromNative()
            rebuildSidebar()
            rebuildLayerList()
        }, 250L)
    }

    override fun onDestroy() {
        drawingView?.release()
        drawingView = null
        super.onDestroy()
    }

    /** Volume keys cycle/add layers; stylus side-button cycles tools. */
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

    // ====================================================================
    // Tool rail
    // ====================================================================

    /** Vertical rail of icon tiles. Sections separated by hairline rules.
     *  Wrapped in a ScrollView so it gracefully degrades on shorter screens. */
    private fun buildToolRail(): View {
        val scroll = ScrollView(this).apply {
            isVerticalScrollBarEnabled = false
            overScrollMode = View.OVER_SCROLL_NEVER
            setBackgroundColor(getColor(R.color.paperDeep))
        }
        val rail = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(0, 8.dp, 0, 8.dp)
        }
        // Right-edge hairline so the rail visually separates from the
        // sidebar / layer panel even when paperDeep is the same tone.
        rail.addView(View(this).apply {
            setBackgroundColor(getColor(R.color.rule))
        }, LinearLayout.LayoutParams(0, 0))   // placeholder, replaced below

        // Menu (top of rail): opens overflow popover with rarely-used actions.
        rail.addView(toolTile(R.drawable.ic_menu, "menu", isToggle = false) {
            showOverflowMenu(it)
        })
        rail.addView(railRule())

        rail.addView(railSectionLabel("DRAW"))
        rail.addView(makeRailToolTile(Tool.BRUSH,   R.drawable.ic_pen,    "brush"))
        rail.addView(makeRailToolTile(Tool.ERASER,  R.drawable.ic_eraser, "eraser"))
        rail.addView(makeRailToolTile(Tool.BUCKET,  R.drawable.ic_bucket, "bucket"))

        rail.addView(railRule())
        rail.addView(railSectionLabel("BUILD"))
        rail.addView(makeRailToolTile(Tool.LINE,        R.drawable.ic_line,          "line"))
        rail.addView(makeRailToolTile(Tool.RECTANGLE,   R.drawable.ic_rect,          "rectangle"))
        rail.addView(makeRailToolTile(Tool.CIRCLE,      R.drawable.ic_circle,        "circle"))
        rail.addView(makeRailToolTile(Tool.ELLIPSE,     R.drawable.ic_ellipse,       "ellipse"))
        rail.addView(makeRailToolTile(Tool.SELECT,      R.drawable.ic_vector_select, "vector select"))
        rail.addView(makeRailToolTile(Tool.SELECT_RECT, R.drawable.ic_select,        "marquee"))
        rail.addView(makeRailToolTile(Tool.SELECT_LASSO,R.drawable.ic_lasso,         "lasso"))

        rail.addView(railRule())
        // Panel toggles. layers/color are present for design fidelity but
        // don't toggle anything in Phase 1 (their panels are always shown
        // in the layer column), so they stay unselected to avoid the
        // visual clutter of every tile reading as active. pages + grid
        // do reflect real state.
        rail.addView(toolTile(R.drawable.ic_layers, "layers", isToggle = false) { /* no-op */ })
        pagesRailTile = toolTile(R.drawable.ic_pages, "pages", isToggle = false) { tile ->
            togglePageSidebar()
            tile.isSelected = sidebarScroll.visibility == View.VISIBLE
        } as ImageView
        pagesRailTile.isSelected = true
        rail.addView(pagesRailTile)
        rail.addView(toolTile(R.drawable.ic_color, "color", isToggle = false) { /* no-op */ })
        gridRailTile = toolTile(R.drawable.ic_grid, "grid", isToggle = false) { tile ->
            cycleGrid()
            tile.isSelected = (gridState != 0)
        } as ImageView
        rail.addView(gridRailTile)

        // View controls live below the panel toggles, separated by a
        // rule so they read as their own group (not part of the panel
        // selectors above).
        rail.addView(railRule())
        rail.addView(toolTile(R.drawable.ic_reset_view, "reset view",
            isToggle = false) { drawingView?.resetView() })

        scroll.addView(rail, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        ))
        return scroll
    }

    private fun railRule(): View = View(this).apply {
        setBackgroundColor(getColor(R.color.rule))
        layoutParams = LinearLayout.LayoutParams(36.dp, 1.dp).apply {
            topMargin = 6.dp; bottomMargin = 4.dp
        }
    }

    private fun railSectionLabel(text: String): TextView = TextView(this).apply {
        this.text = text
        textSize = 8f
        typeface = fontMonoSemibold ?: Typeface.MONOSPACE
        letterSpacing = 0.12f
        setTextColor(getColor(R.color.inkFaint))
        gravity = Gravity.CENTER
        setPadding(0, 2.dp, 0, 2.dp)
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
    }

    private fun makeRailToolTile(tool: Tool, iconRes: Int, label: String): ImageView {
        val tile = toolTile(iconRes, label, isToggle = false) { drawingView?.setTool(tool) }
                as ImageView
        railToolTiles[tool] = tile
        return tile
    }

    /**
     * Generic 44dp icon tile. `isToggle` toggles `isSelected` on tap;
     * non-toggle tiles fire `onClick` and the caller manages state.
     */
    private fun toolTile(iconRes: Int, label: String,
                         isToggle: Boolean,
                         onClick: (ImageView) -> Unit): View {
        val tile = ImageView(this).apply {
            setImageResource(iconRes)
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            background = ResourcesCompat.getDrawable(
                resources, R.drawable.tool_tile_bg, theme)
            setPadding(10.dp, 10.dp, 10.dp, 10.dp)
            contentDescription = label
            imageTintList = ColorStateList(
                arrayOf(intArrayOf(android.R.attr.state_selected),
                        intArrayOf()),
                intArrayOf(getColor(R.color.hot), getColor(R.color.ink))
            )
            isClickable = true
            isFocusable = true
            setOnClickListener {
                if (isToggle) isSelected = !isSelected
                onClick(this)
            }
        }
        tile.layoutParams = LinearLayout.LayoutParams(44.dp, 44.dp).apply {
            topMargin = 2.dp; bottomMargin = 2.dp
        }
        return tile
    }

    /** Reflect the active tool by toggling `isSelected` on the rail tiles. */
    private fun onToolChanged(tool: Tool) {
        for ((t, tile) in railToolTiles) tile.isSelected = (t == tool)
        currentToolMirror = tool
        if (::statusToolText.isInitialized) {
            statusToolText.text = "◇ ${tool.displayName.lowercase()}"
        }
        if (::sizeSliderLabel.isInitialized) {
            updateSizeSliderForTool()
        }
    }

    private val Tool.displayName: String
        get() = when (this) {
            Tool.BRUSH        -> "brush"
            Tool.ERASER       -> "eraser"
            Tool.BUCKET       -> "bucket"
            Tool.LINE         -> "line"
            Tool.RECTANGLE    -> "rect"
            Tool.CIRCLE       -> "circle"
            Tool.ELLIPSE      -> "ellipse"
            Tool.SELECT       -> "select"
            Tool.SELECT_RECT  -> "marquee"
            Tool.SELECT_LASSO -> "lasso"
        }

    // ====================================================================
    // Layer panel: LAYERS + BRUSH + COLOR
    // ====================================================================

    private fun buildLayerPanel(): View {
        val panel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(getColor(R.color.paper))
        }
        // Right-edge hairline (between layer panel and canvas frame).
        // We add the rule as a sibling inside an outer FrameLayout so the
        // rule doesn't take vertical space inside the column.
        val wrapper = FrameLayout(this)
        wrapper.addView(panel, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT
        ))
        wrapper.addView(View(this).apply {
            setBackgroundColor(getColor(R.color.rule))
        }, FrameLayout.LayoutParams(1.dp, ViewGroup.LayoutParams.MATCH_PARENT,
            Gravity.END))

        // ---- LAYERS section ----
        panel.addView(buildLayerHeader(),
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 28.dp))
        layerListContainer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        panel.addView(layerListContainer,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT))

        // Active-layer opacity slider, sitting just under the layer list
        // so it visually belongs to the LAYERS section rather than the
        // BRUSH section below.
        panel.addView(buildLayerOpacityRow(),
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT))

        panel.addView(panelDivider())

        // ---- BRUSH section ----
        panel.addView(buildBrushSection(),
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT))

        panel.addView(panelDivider())

        // ---- COLOR section ----
        panel.addView(buildColorSection(),
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT))

        return wrapper
    }

    private fun panelDivider(): View = View(this).apply {
        setBackgroundColor(getColor(R.color.rule))
        layoutParams = LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, 1.dp)
    }

    private fun buildLayerHeader(): View {
        val header = FrameLayout(this).apply {
            background = ResourcesCompat.getDrawable(
                resources, R.drawable.panel_section_header, theme)
        }
        layerActiveHeading = TextView(this).apply {
            text = "LAYERS"
            typeface = fontMonoSemibold ?: Typeface.MONOSPACE
            textSize = 10f
            letterSpacing = 0.08f
            setTextColor(getColor(R.color.ink))
            gravity = Gravity.CENTER_VERTICAL
            setPadding(10.dp, 0, 0, 0)
        }
        header.addView(layerActiveHeading, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.MATCH_PARENT,
            Gravity.START or Gravity.CENTER_VERTICAL
        ))

        // + raster layer
        val plus = ImageView(this).apply {
            setImageResource(R.drawable.ic_plus)
            imageTintList = ColorStateList.valueOf(getColor(R.color.inkSoft))
            setPadding(8.dp, 4.dp, 4.dp, 4.dp)
            contentDescription = "add layer"
            isClickable = true; isFocusable = true
            setOnClickListener { userAddLayer() }
        }
        // ⋯ overflow → vector-layer / clear / delete
        val more = ImageView(this).apply {
            setImageResource(R.drawable.ic_more)
            imageTintList = ColorStateList.valueOf(getColor(R.color.inkSoft))
            setPadding(4.dp, 4.dp, 8.dp, 4.dp)
            contentDescription = "more"
            isClickable = true; isFocusable = true
            setOnClickListener { showLayerOverflow(it) }
        }
        val rightRow = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(plus, LinearLayout.LayoutParams(28.dp, 28.dp))
            addView(more, LinearLayout.LayoutParams(32.dp, 28.dp))
        }
        header.addView(rightRow, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.MATCH_PARENT,
            Gravity.END or Gravity.CENTER_VERTICAL
        ))
        return header
    }

    /** Re-render the layer list. Called whenever layer state changes. */
    private fun rebuildLayerList() {
        layerListContainer.removeAllViews()
        // Rows have a fixed height: the active row's MATCH_PARENT sienna
        // left bar would otherwise fight WRAP_CONTENT and inflate the
        // whole row to fill the panel. List is top-down: highest-index
        // (visually-topmost) layer first.
        for (idx in (layerCount - 1) downTo 0) {
            layerListContainer.addView(buildLayerRow(idx),
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, 32.dp))
            layerListContainer.addView(View(this).apply {
                setBackgroundColor(getColor(R.color.rule))
            }, LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 1.dp))
        }
        // Sync the opacity slider to whatever the active layer is now.
        refreshLayerOpacitySlider()
    }

    private fun buildLayerRow(idx: Int): View {
        val isActive  = (idx == activeLayerIndex)
        val isVector  = NativeRenderer.getLayerType(idx) == 1
        val isVisible = NativeRenderer.getLayerVisible(idx)
        val customName = NativeRenderer.getLayerName(idx)
        val displayName = if (customName.isNotEmpty()) customName
                          else (if (isVector) "vector ${idx + 1}" else "layer ${idx + 1}")

        val row = FrameLayout(this).apply {
            setBackgroundColor(
                if (isActive) getColor(R.color.paperDeep) else Color.TRANSPARENT)
            // 2dp sienna left bar for active; transparent otherwise.
            if (isActive) {
                addView(View(this@MainActivity).apply {
                    setBackgroundColor(getColor(R.color.hot))
                }, FrameLayout.LayoutParams(2.dp,
                    ViewGroup.LayoutParams.MATCH_PARENT))
            }
            isClickable = true; isFocusable = true
            setOnClickListener {
                // Cycle to this layer. Native cycleActiveLayer goes one at
                // a time, so we cycle until we land on idx.
                while (activeLayerIndex != idx) userCycleLayer()
            }
            setOnLongClickListener {
                showRenameLayerDialog(idx); true
            }
        }
        val rowContent = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(10.dp, 0, 10.dp, 0)
            minimumHeight = 28.dp
        }
        // Eye icon — toggles layer visibility. Has its own click handler
        // so taps here don't bubble up to the row's set-active listener.
        // Hidden layers get a faint tint to read as inactive at a glance.
        val eye = ImageView(this).apply {
            setImageResource(if (isVisible) R.drawable.ic_eye else R.drawable.ic_eye_off)
            imageTintList = ColorStateList.valueOf(
                getColor(if (isVisible) R.color.ink else R.color.inkFaint))
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            isClickable = true; isFocusable = true
            setOnClickListener {
                NativeRenderer.setLayerVisible(idx, !isVisible)
                drawingView?.forceRedraw()
                rebuildLayerList()
            }
        }
        rowContent.addView(eye, LinearLayout.LayoutParams(20.dp, 20.dp).apply {
            rightMargin = 8.dp
        })
        val name = TextView(this).apply {
            text = displayName
            typeface = if (isActive) fontMonoSemibold ?: Typeface.MONOSPACE
                       else fontMono ?: Typeface.MONOSPACE
            textSize = 11f
            setTextColor(getColor(R.color.ink))
            ellipsize = android.text.TextUtils.TruncateAt.END
            maxLines = 1
        }
        rowContent.addView(name, LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1.0f))
        val tag = TextView(this).apply {
            text = if (isVector) "V" else "R"
            typeface = fontMono ?: Typeface.MONOSPACE
            textSize = 8f
            setTextColor(getColor(R.color.inkFaint))
            setPadding(4.dp, 1.dp, 4.dp, 1.dp)
            background = ResourcesCompat.getDrawable(
                resources, R.drawable.chrome_chip_bg, theme)
        }
        rowContent.addView(tag)

        // Per-row ⋯ overflow → rename / delete (move is via drag handle).
        // Has its own click handler so taps here don't bubble to the
        // row's "set active" listener.
        val rowMore = ImageView(this).apply {
            setImageResource(R.drawable.ic_more)
            imageTintList = ColorStateList.valueOf(getColor(R.color.inkSoft))
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            isClickable = true; isFocusable = true
            setOnClickListener { showLayerRowOverflow(it, idx) }
        }
        rowContent.addView(rowMore, LinearLayout.LayoutParams(20.dp, 20.dp).apply {
            leftMargin = 6.dp
        })

        // Drag handle for reorder. Captures touch on DOWN and grabs the
        // row's parent (FrameLayout) so we can translate the entire row
        // as the user drags. Other rows shift aside in updateDragRowDisplacement.
        val dragHandle = ImageView(this).apply {
            setImageResource(R.drawable.ic_drag_handle)
            imageTintList = ColorStateList.valueOf(getColor(R.color.inkSoft))
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            contentDescription = "drag to reorder"
            isClickable = true; isFocusable = true
        }
        installDragHandleListener(dragHandle, idx, row)
        rowContent.addView(dragHandle, LinearLayout.LayoutParams(20.dp, 28.dp).apply {
            leftMargin = 4.dp
        })

        row.addView(rowContent, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.CENTER_VERTICAL))
        return row
    }

    /** Per-row overflow menu: rename / delete. Reordering is done with the
     *  drag handle; Delete is disabled when only one layer remains and
     *  prompts for confirmation otherwise (no undo for layer deletes). */
    private fun showLayerRowOverflow(anchor: View, idx: Int) {
        val menu = PopupMenu(this, anchor, Gravity.END)
        menu.menu.add(0, 0, 0, "Rename…")
        val delete = menu.menu.add(0, 1, 1, "Delete")
        delete.isEnabled = layerCount > 1
        menu.setOnMenuItemClickListener { item ->
            when (item.itemId) {
                0 -> showRenameLayerDialog(idx)
                1 -> confirmDeleteLayer(idx)
            }
            true
        }
        menu.show()
    }

    /** Confirm-then-delete a layer. There is no undo for layer ops, so
     *  the dialog spells that out before the destructive call. */
    private fun confirmDeleteLayer(idx: Int) {
        val customName = NativeRenderer.getLayerName(idx)
        val isVector = NativeRenderer.getLayerType(idx) == 1
        val displayName = if (customName.isNotEmpty()) customName
                          else (if (isVector) "vector ${idx + 1}" else "layer ${idx + 1}")
        AlertDialog.Builder(this)
            .setTitle("Delete layer")
            .setMessage("Delete “$displayName”? This can't be undone.")
            .setPositiveButton("Delete") { _, _ -> userDeleteLayer(idx) }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun userDeleteLayer(idx: Int) {
        if (layerCount <= 1) return
        NativeRenderer.deleteLayer(idx)
        drawingView?.forceRedraw()
        // Native applies the delete on the GL thread next op; sync after a
        // beat so getLayerCount/getActiveLayer reflect the new state.
        drawingView?.postDelayed({ syncLayerStateFromNative() }, 60L)
    }

    private fun userMoveLayer(from: Int, to: Int) {
        if (from == to || from < 0 || to < 0
            || from >= layerCount || to >= layerCount) return
        NativeRenderer.moveLayer(from, to)
        drawingView?.forceRedraw()
        // Active layer index may shift; resync so the highlighted row is
        // correct after the move lands on the GL thread.
        drawingView?.postDelayed({ syncLayerStateFromNative() }, 60L)
    }

    /** Layer rows render top-to-bottom with the highest idx at the top, so
     *  ui-position 0 corresponds to native idx (count-1). This pair maps
     *  between the two so the drag math can stay in ui-position space. */
    private fun uiPosToIdx(uiPos: Int): Int = (layerCount - 1) - uiPos
    private fun idxToUiPos(idx: Int): Int   = (layerCount - 1) - idx

    /** Layer rows are interleaved with 1dp dividers in layerListContainer.
     *  Children at even indices (0, 2, 4, ...) are rows; odd indices are
     *  dividers. */
    private fun rowViewAtUiPos(uiPos: Int): View? {
        if (!::layerListContainer.isInitialized) return null
        val childIdx = uiPos * 2
        if (childIdx < 0 || childIdx >= layerListContainer.childCount) return null
        return layerListContainer.getChildAt(childIdx)
    }

    /** Bind the drag-to-reorder touch handler onto the handle ImageView for
     *  the row at native index [idx]. Handles its own touch stream — no
     *  click listener — so the row's "set active" tap can't fire when the
     *  user is grabbing the handle. */
    private fun installDragHandleListener(handle: View, idx: Int, rowView: View) {
        handle.setOnTouchListener { v, ev ->
            when (ev.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    if (layerCount <= 1) return@setOnTouchListener false
                    dragSourceIdx = idx
                    dragSourceView = rowView
                    dragStartRawY = ev.rawY
                    dragStartTranslationY = rowView.translationY
                    // Row + 1dp divider = the per-slot height we use to
                    // displace other rows by integer multiples.
                    dragRowHeightPx = rowView.height + 1.dp
                    dragCurrentTargetUiPos = idxToUiPos(idx)
                    // Float the row above the others while dragging.
                    rowView.elevation = 6.dp.toFloat()
                    rowView.alpha = 0.95f
                    // We need parent disallowInterceptTouchEvent so a
                    // ScrollView ancestor doesn't steal the gesture.
                    v.parent?.requestDisallowInterceptTouchEvent(true)
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    if (dragSourceIdx != idx || dragSourceView !== rowView) {
                        return@setOnTouchListener false
                    }
                    val dy = ev.rawY - dragStartRawY
                    rowView.translationY = dragStartTranslationY + dy
                    updateDragRowDisplacement(rowView)
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    if (dragSourceIdx != idx || dragSourceView !== rowView) {
                        return@setOnTouchListener false
                    }
                    val targetUiPos = dragCurrentTargetUiPos
                    val sourceIdx = dragSourceIdx
                    // Reset visual state for every row before either
                    // committing the move (which rebuilds the list) or
                    // bouncing back.
                    rowView.elevation = 0f
                    rowView.alpha = 1.0f
                    rowView.translationY = 0f
                    resetAllRowDisplacements()
                    dragSourceIdx = -1
                    dragSourceView = null
                    dragCurrentTargetUiPos = -1

                    val sourceUiPos = idxToUiPos(sourceIdx)
                    if (targetUiPos in 0 until layerCount && targetUiPos != sourceUiPos) {
                        val targetIdx = uiPosToIdx(targetUiPos)
                        userMoveLayer(sourceIdx, targetIdx)
                    }
                    true
                }
                else -> false
            }
        }
    }

    /** While the user drags [draggedRow], shift the other rows so a visual
     *  insertion gap follows the dragged row. Called on every MOVE event;
     *  also recomputes [dragCurrentTargetUiPos] (used at UP to choose the
     *  destination). */
    private fun updateDragRowDisplacement(draggedRow: View) {
        val sourceIdx = dragSourceIdx
        if (sourceIdx < 0) return
        val sourceUiPos = idxToUiPos(sourceIdx)
        // Center of the dragged row in container-local coords.
        val draggedCenter = draggedRow.top + draggedRow.translationY +
                            draggedRow.height / 2f
        // Target ui-position: the count of *other* rows whose original
        // center lies above the dragged center. This is the stable
        // formulation — independent of which way the user crossed.
        var newUiPos = 0
        for (uiPos in 0 until layerCount) {
            if (uiPos == sourceUiPos) continue
            val row = rowViewAtUiPos(uiPos) ?: continue
            val originalCenter = row.top + row.height / 2f
            if (originalCenter < draggedCenter) newUiPos++
        }
        if (newUiPos == dragCurrentTargetUiPos) return
        dragCurrentTargetUiPos = newUiPos
        // Displace other rows so a gap opens at newUiPos. A row's *display*
        // ui-position after a hypothetical commit determines its translation.
        for (uiPos in 0 until layerCount) {
            if (uiPos == sourceUiPos) continue
            val row = rowViewAtUiPos(uiPos) ?: continue
            val displayedUiPos = when {
                sourceUiPos < newUiPos ->
                    if (uiPos in (sourceUiPos + 1)..newUiPos) uiPos - 1 else uiPos
                sourceUiPos > newUiPos ->
                    if (uiPos in newUiPos..(sourceUiPos - 1)) uiPos + 1 else uiPos
                else -> uiPos
            }
            val target = ((displayedUiPos - uiPos) * dragRowHeightPx).toFloat()
            // Animate so the shifts feel smooth instead of teleporting.
            row.animate().translationY(target).setDuration(120L).start()
        }
    }

    /** Clear translationY on every layer row. Called at the end of a drag
     *  so the visible state matches the (possibly committed) data. */
    private fun resetAllRowDisplacements() {
        if (!::layerListContainer.isInitialized) return
        for (i in 0 until layerListContainer.childCount) {
            layerListContainer.getChildAt(i).translationY = 0f
        }
    }

    /** AlertDialog with an EditText prepopulated with the current layer
     *  name (or empty if none was set). Empty input clears the custom
     *  name and reverts to the "layer N" / "vector N" default. */
    private fun showRenameLayerDialog(idx: Int) {
        val current = NativeRenderer.getLayerName(idx)
        val input = android.widget.EditText(this).apply {
            setText(current)
            setSelection(current.length)
            hint = "layer name"
        }
        val container = FrameLayout(this).apply {
            val pad = 16.dp
            setPadding(pad, 8.dp, pad, 0)
            addView(input, FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT))
        }
        AlertDialog.Builder(this)
            .setTitle("Rename layer")
            .setView(container)
            .setPositiveButton("OK") { _, _ ->
                NativeRenderer.setLayerName(idx, input.text.toString().trim())
                rebuildLayerList()
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    /** "α" slider that always edits the active layer's opacity. The
     *  slider's progress is in [0, 100]; the value is divided by 100
     *  before it goes to native. We avoid pushing native writes for
     *  programmatic progress changes (active-layer-changed sync) by
     *  gating on the listener's `fromUser` flag. */
    private fun buildLayerOpacityRow(): View {
        val label = TextView(this).apply {
            text = "α"
            typeface = fontMono ?: Typeface.MONOSPACE
            textSize = 9f
            setTextColor(getColor(R.color.inkSoft))
        }
        layerOpacityValue = TextView(this).apply {
            typeface = fontMono ?: Typeface.MONOSPACE
            textSize = 9f
            setTextColor(getColor(R.color.ink))
            gravity = Gravity.END
            text = "100"
        }
        layerOpacitySlider = SeekBar(this).apply {
            max = 100
            progress = 100
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(sb: SeekBar?, p: Int, fromUser: Boolean) {
                    layerOpacityValue.text = p.toString()
                    if (!fromUser) return
                    NativeRenderer.setLayerOpacity(activeLayerIndex, p / 100f)
                    drawingView?.forceRedraw()
                }
                override fun onStartTrackingTouch(sb: SeekBar?) {}
                override fun onStopTrackingTouch(sb: SeekBar?) {}
            })
        }
        return buildSliderRow(label, layerOpacitySlider, layerOpacityValue)
    }

    /** Push the native opacity value for the currently-active layer
     *  into the slider. Called whenever the active layer changes (or
     *  rebuildLayerList runs) so the slider always reflects the right
     *  layer. fromUser=false on this programmatic set, so the listener
     *  won't echo it back to native. */
    private fun refreshLayerOpacitySlider() {
        if (!::layerOpacitySlider.isInitialized) return
        val o = NativeRenderer.getLayerOpacity(activeLayerIndex)
        layerOpacitySlider.progress = (o * 100f).toInt().coerceIn(0, 100)
    }

    private fun buildBrushSection(): View {
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        // Header
        val header = FrameLayout(this).apply {
            background = ResourcesCompat.getDrawable(
                resources, R.drawable.panel_section_header, theme)
        }
        val headerLabel = TextView(this).apply {
            text = "BRUSH"
            typeface = fontMonoSemibold ?: Typeface.MONOSPACE
            textSize = 10f
            letterSpacing = 0.08f
            setTextColor(getColor(R.color.ink))
            gravity = Gravity.CENTER_VERTICAL
            setPadding(10.dp, 0, 10.dp, 0)
        }
        header.addView(headerLabel, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT,
            Gravity.START or Gravity.CENTER_VERTICAL))
        container.addView(header,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 28.dp))

        // Active "size" slider routes to brush vs vector width based on tool.
        sizeSliderLabel = TextView(this).apply {
            typeface = fontMono ?: Typeface.MONOSPACE
            textSize = 9f
            setTextColor(getColor(R.color.inkSoft))
            text = "size"
        }
        sizeValueLabel = TextView(this).apply {
            typeface = fontMono ?: Typeface.MONOSPACE
            textSize = 9f
            setTextColor(getColor(R.color.ink))
            gravity = Gravity.END
        }
        sizeSlider = SeekBar(this).apply {
            max = 100
            progress = brushScaleToProgress(brushSizeScale)
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(sb: SeekBar?, p: Int, fromUser: Boolean) {
                    if (!fromUser) return
                    if (currentToolEditsVector()) {
                        val w = progressToVectorWidth(p)
                        vectorLineWidth = w
                        sizeValueLabel.text = "%.1f".format(w)
                        NativeRenderer.setVectorLineWidth(w)
                    } else {
                        val s = progressToBrushScale(p)
                        brushSizeScale = s
                        sizeValueLabel.text = "%.2fx".format(s)
                        NativeRenderer.setBrushSize(s)
                    }
                }
                override fun onStartTrackingTouch(sb: SeekBar?) {}
                override fun onStopTrackingTouch(sb: SeekBar?) {
                    if (currentToolEditsVector()) {
                        prefs().edit().putFloat(kPrefVectorWidth, vectorLineWidth).apply()
                    } else {
                        prefs().edit().putFloat(kPrefBrushSize, brushSizeScale).apply()
                    }
                }
            })
        }
        container.addView(buildSliderRow(sizeSliderLabel, sizeSlider, sizeValueLabel))

        // α slider — controls brush opacity. Active for any tool, but
        // only affects brush strokes (eraser keeps a fixed strength).
        container.addView(buildBrushAlphaRow())

        // hard slider — radial dab hardness. Replaces the old "smth"
        // stub. 0 = full radial gradient (smooth dab), 100 = solid
        // disc (hard dab). Applies to brush + eraser.
        container.addView(buildBrushHardnessRow())

        // Disabled stub — placeholder for future pressure curve.
        container.addView(buildSliderRow(
            makeStubSliderLabel("press"),
            makeStubSlider(),
            makeStubValueLabel("—")
        ))
        // Push the initial value display.
        updateSizeSliderForTool()
        return container
    }

    private fun buildBrushAlphaRow(): View {
        val label = TextView(this).apply {
            text = "α"
            typeface = fontMono ?: Typeface.MONOSPACE
            textSize = 9f
            setTextColor(getColor(R.color.inkSoft))
        }
        val valueLabel = TextView(this).apply {
            typeface = fontMono ?: Typeface.MONOSPACE
            textSize = 9f
            setTextColor(getColor(R.color.ink))
            gravity = Gravity.END
            // Initial display matches the initial slider position
            // (target stroke opacity %), not the per-dab α value.
            text = brushAlphaToProgress(brushAlpha).toString()
        }
        val slider = SeekBar(this).apply {
            max = 100
            progress = brushAlphaToProgress(brushAlpha)
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(sb: SeekBar?, p: Int, fromUser: Boolean) {
                    // p is the target stroke opacity (0..100); display
                    // matches slider position so the user sees what
                    // they get.
                    valueLabel.text = p.toString()
                    if (!fromUser) return
                    brushAlpha = progressToBrushAlpha(p)
                    NativeRenderer.setBrushAlpha(brushAlpha)
                }
                override fun onStartTrackingTouch(sb: SeekBar?) {}
                override fun onStopTrackingTouch(sb: SeekBar?) {
                    prefs().edit().putFloat(kPrefBrushAlpha, brushAlpha).apply()
                }
            })
        }
        return buildSliderRow(label, slider, valueLabel)
    }

    private fun buildBrushHardnessRow(): View {
        val label = TextView(this).apply {
            text = "hard"
            typeface = fontMono ?: Typeface.MONOSPACE
            textSize = 9f
            setTextColor(getColor(R.color.inkSoft))
        }
        val valueLabel = TextView(this).apply {
            typeface = fontMono ?: Typeface.MONOSPACE
            textSize = 9f
            setTextColor(getColor(R.color.ink))
            gravity = Gravity.END
            text = (brushHardness * 100).toInt().toString()
        }
        val slider = SeekBar(this).apply {
            max = 100
            progress = (brushHardness * 100).toInt().coerceIn(0, 100)
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(sb: SeekBar?, p: Int, fromUser: Boolean) {
                    valueLabel.text = p.toString()
                    if (!fromUser) return
                    brushHardness = p / 100f
                    NativeRenderer.setBrushHardness(brushHardness)
                }
                override fun onStartTrackingTouch(sb: SeekBar?) {}
                override fun onStopTrackingTouch(sb: SeekBar?) {
                    prefs().edit().putFloat(kPrefBrushHardness, brushHardness).apply()
                }
            })
        }
        return buildSliderRow(label, slider, valueLabel)
    }

    private fun buildSliderRow(label: View, slider: View, valueLabel: View): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(10.dp, 4.dp, 10.dp, 4.dp)
        }
        row.addView(label, LinearLayout.LayoutParams(36.dp,
            ViewGroup.LayoutParams.WRAP_CONTENT))
        row.addView(slider, LinearLayout.LayoutParams(
            0, ViewGroup.LayoutParams.WRAP_CONTENT, 1.0f))
        row.addView(valueLabel, LinearLayout.LayoutParams(36.dp,
            ViewGroup.LayoutParams.WRAP_CONTENT))
        return row
    }

    private fun makeStubSliderLabel(text: String): TextView = TextView(this).apply {
        this.text = text
        typeface = fontMono ?: Typeface.MONOSPACE
        textSize = 9f
        setTextColor(getColor(R.color.inkDisabled))
    }

    private fun makeStubSlider(): SeekBar = SeekBar(this).apply {
        max = 100
        progress = 100
        isEnabled = false
        alpha = 0.55f
    }

    private fun makeStubValueLabel(text: String): TextView = TextView(this).apply {
        this.text = text
        typeface = fontMono ?: Typeface.MONOSPACE
        textSize = 9f
        setTextColor(getColor(R.color.inkDisabled))
        gravity = Gravity.END
    }

    private fun currentToolEditsVector(): Boolean = when (currentToolMirror) {
        Tool.LINE, Tool.RECTANGLE, Tool.CIRCLE, Tool.ELLIPSE -> true
        else -> false
    }

    /** Refresh the size slider's progress / value display when the tool
     *  changes (or after a one-shot sync at startup). */
    private fun updateSizeSliderForTool() {
        if (currentToolEditsVector()) {
            sizeSliderLabel.text = "width"
            sizeSlider.progress = vectorWidthToProgress(vectorLineWidth)
            sizeValueLabel.text = "%.1f".format(vectorLineWidth)
        } else {
            sizeSliderLabel.text = "size"
            sizeSlider.progress = brushScaleToProgress(brushSizeScale)
            sizeValueLabel.text = "%.2fx".format(brushSizeScale)
        }
    }

    private fun buildColorSection(): View {
        val container = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        // Header with a small color chip on the right.
        val header = FrameLayout(this).apply {
            background = ResourcesCompat.getDrawable(
                resources, R.drawable.panel_section_header, theme)
        }
        val headerLabel = TextView(this).apply {
            text = "COLOR"
            typeface = fontMonoSemibold ?: Typeface.MONOSPACE
            textSize = 10f
            letterSpacing = 0.08f
            setTextColor(getColor(R.color.ink))
            setPadding(10.dp, 0, 0, 0)
            gravity = Gravity.CENTER_VERTICAL
        }
        header.addView(headerLabel, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.MATCH_PARENT,
            Gravity.START or Gravity.CENTER_VERTICAL))
        colorChip = View(this).apply {
            setBackgroundColor(0xFF000000.toInt() or currentColorRgb)
        }
        header.addView(colorChip, FrameLayout.LayoutParams(18.dp, 14.dp,
            Gravity.END or Gravity.CENTER_VERTICAL).apply {
                marginEnd = 10.dp
            })
        container.addView(header,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 28.dp))

        // 8-swatch grid (placeholder for the full HSV picker that's
        // designed but not implemented — Phase 2).
        val grid = GridLayout(this).apply {
            columnCount = 4
            setPadding(10.dp, 8.dp, 10.dp, 12.dp)
        }
        palette.forEach { rgb ->
            val swatch = View(this).apply {
                setBackgroundColor(0xFF000000.toInt() or rgb)
                setOnClickListener {
                    NativeRenderer.setBrushColor(rgb)
                    currentColorRgb = rgb
                    updateColorChip()
                }
            }
            val lp = GridLayout.LayoutParams().apply {
                width  = 30.dp
                height = 22.dp
                setMargins(2.dp, 2.dp, 2.dp, 2.dp)
            }
            grid.addView(swatch, lp)
        }
        container.addView(grid)
        return container
    }

    private fun updateColorChip() {
        if (::colorChip.isInitialized) {
            colorChip.setBackgroundColor(0xFF000000.toInt() or currentColorRgb)
        }
    }

    // ====================================================================
    // Page sidebar (84dp wide, restyled)
    // ====================================================================

    private fun buildPageSidebar(): ScrollView {
        val scroll = ScrollView(this).apply {
            isFillViewport = true
            isVerticalScrollBarEnabled = false
            overScrollMode = View.OVER_SCROLL_NEVER
            setBackgroundColor(getColor(R.color.paper))
        }
        sidebarLayout = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        // Right-edge hairline so the sidebar visually ends.
        val container = FrameLayout(this)
        container.addView(sidebarLayout, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        ))
        container.addView(View(this).apply {
            setBackgroundColor(getColor(R.color.rule))
        }, FrameLayout.LayoutParams(1.dp, ViewGroup.LayoutParams.MATCH_PARENT,
            Gravity.END))
        scroll.addView(container, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        ))
        return scroll
    }

    /** DOCS button at the top of the sidebar — opens the doc picker. */
    private fun buildDocsButton(): View {
        val tile = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            background = ResourcesCompat.getDrawable(
                resources, R.drawable.panel_section_header, theme)
            setPadding(0, 8.dp, 0, 8.dp)
            isClickable = true; isFocusable = true
            setOnClickListener { showDocsMenu(it) }
        }
        val icon = ImageView(this).apply {
            setImageResource(R.drawable.ic_docs)
            imageTintList = ColorStateList.valueOf(getColor(R.color.ink))
        }
        tile.addView(icon, LinearLayout.LayoutParams(16.dp, 16.dp))
        docsButtonLabel = TextView(this).apply {
            text = "DOCS"
            typeface = fontMonoSemibold ?: Typeface.MONOSPACE
            textSize = 10f
            letterSpacing = 0.1f
            setTextColor(getColor(R.color.ink))
            setPadding(6.dp, 0, 6.dp, 0)
        }
        tile.addView(docsButtonLabel)
        val chev = ImageView(this).apply {
            setImageResource(R.drawable.ic_chev_d)
            imageTintList = ColorStateList.valueOf(getColor(R.color.inkSoft))
        }
        tile.addView(chev, LinearLayout.LayoutParams(12.dp, 12.dp))
        docsButton = tile
        return tile
    }

    /** Recreate every sidebar entry from current page state. */
    private fun rebuildSidebar() {
        sidebarLayout.removeAllViews()
        pageItems.clear()

        // DOCS header — replaces the old name-label + new/open/delete row.
        sidebarLayout.addView(buildDocsButton(),
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT))

        val pageCount = NativeRenderer.getPageCount().coerceAtLeast(1)
        val active    = NativeRenderer.getActivePage()
        for (i in 0 until pageCount) {
            val item = createPageSidebarItem(i, isActive = (i == active))
            pageItems.add(item)
            sidebarLayout.addView(item.container, sidebarItemParams())
        }

        // + Page row, designed as a dashed-frame thumbnail.
        sidebarLayout.addView(buildAddPageRow(), sidebarItemParams())

        lastBuiltPageCount  = pageCount
        lastBuiltActivePage = active

        drawingView?.setThumbnailTargets(
            pageItems.associate { it.pageIdx to it.bitmap }
        )
        drawingView?.forceRedraw()
    }

    private fun buildAddPageRow(): View {
        val frame = FrameLayout(this).apply {
            isClickable = true; isFocusable = true
            setOnClickListener { userAddPage() }
        }
        val plus = ImageView(this).apply {
            setImageResource(R.drawable.ic_plus)
            imageTintList = ColorStateList.valueOf(getColor(R.color.inkSoft))
        }
        // Render via a thin-bordered View so the dashed-frame impression
        // comes through without needing a custom dashed drawable.
        val box = View(this).apply {
            background = makeDashedFrame()
        }
        frame.addView(box, FrameLayout.LayoutParams(kThumbMaxWidthDp.dp, 36.dp,
            Gravity.CENTER))
        frame.addView(plus, FrameLayout.LayoutParams(20.dp, 20.dp,
            Gravity.CENTER))
        return frame
    }

    private fun makeDashedFrame(): android.graphics.drawable.Drawable {
        val s = android.graphics.drawable.GradientDrawable()
        s.shape = android.graphics.drawable.GradientDrawable.RECTANGLE
        s.setColor(Color.TRANSPARENT)
        s.setStroke(1.dp,
            getColor(R.color.inkFaint),
            /* dashWidth */ 4f * resources.displayMetrics.density,
            /* dashGap   */ 3f * resources.displayMetrics.density)
        return s
    }

    /** Pick the thumbnail bitmap dimensions that match the canvas aspect
     *  ratio, fit inside the design's max box (60×78 dp). Without this
     *  we'd letterbox a wide canvas into a portrait thumb and end up
     *  with gray bars top + bottom. Falls back to the raw maximums when
     *  the SurfaceView hasn't been laid out yet. */
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
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            isClickable = true; isFocusable = true
            setOnClickListener {
                NativeRenderer.switchPage(idx)
                drawingView?.forceRedraw()
            }
        }

        // Thumbnail frame holds the bitmap + a corner page-number badge.
        val frame = FrameLayout(this).apply {
            background = ResourcesCompat.getDrawable(
                resources, R.drawable.page_thumb_bg, theme)
            isSelected = isActive
            setPadding(2.dp, 2.dp, 2.dp, 2.dp)
        }
        val imageView = ImageView(this).apply {
            setImageBitmap(bitmap)
            scaleType = ImageView.ScaleType.FIT_CENTER
        }
        frame.addView(imageView, FrameLayout.LayoutParams(thumbW, thumbH))

        val numberBadge = TextView(this).apply {
            text = String.format("%02d", idx + 1)
            typeface = fontMonoSemibold ?: Typeface.MONOSPACE
            textSize = 8f
            setTextColor(getColor(if (isActive) R.color.hot else R.color.inkSoft))
            setPadding(2.dp, 0, 0, 0)
        }
        frame.addView(numberBadge, FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.START or Gravity.TOP))

        container.addView(frame)

        // Per-thumbnail icons stacked vertically in the dead space to the
        // right of the thumbnail. Drag handle on top, overflow below;
        // same idiom as layer rows so gesture vocabulary stays consistent.
        val iconCol = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
        }
        val dragHandle = ImageView(this).apply {
            setImageResource(R.drawable.ic_drag_handle)
            imageTintList = ColorStateList.valueOf(getColor(R.color.inkSoft))
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            contentDescription = "drag to reorder"
            isClickable = true; isFocusable = true
        }
        installPageDragHandleListener(dragHandle, idx, container)
        iconCol.addView(dragHandle, LinearLayout.LayoutParams(18.dp, 18.dp))

        val pageMore = ImageView(this).apply {
            setImageResource(R.drawable.ic_more)
            imageTintList = ColorStateList.valueOf(getColor(R.color.inkSoft))
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            contentDescription = "more"
            isClickable = true; isFocusable = true
            setOnClickListener { showPageOverflow(it, idx) }
        }
        iconCol.addView(pageMore, LinearLayout.LayoutParams(18.dp, 18.dp).apply {
            topMargin = 2.dp
        })
        container.addView(iconCol, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        ).apply {
            leftMargin = 4.dp
        })

        return PageSidebarItem(container, frame, imageView, numberBadge, bitmap, idx)
    }

    private fun sidebarItemParams() = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.WRAP_CONTENT
    ).apply {
        topMargin = 6.dp
        bottomMargin = 0
    }

    private fun togglePageSidebar() {
        sidebarScroll.visibility =
            if (sidebarScroll.visibility == View.VISIBLE) View.GONE else View.VISIBLE
    }

    // ====================================================================
    // Floating chrome (undo / redo chip)
    // ====================================================================

    private fun buildUndoRedoChip(): View {
        val chip = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            background = ResourcesCompat.getDrawable(
                resources, R.drawable.chrome_chip_bg, theme)
            setPadding(8.dp, 6.dp, 8.dp, 6.dp)
        }
        val undo = ImageView(this).apply {
            setImageResource(R.drawable.ic_undo)
            imageTintList = ColorStateList.valueOf(getColor(R.color.ink))
            isClickable = true; isFocusable = true
            contentDescription = "undo"
            setOnClickListener { userUndo() }
            setPadding(2.dp, 2.dp, 6.dp, 2.dp)
        }
        val redo = ImageView(this).apply {
            setImageResource(R.drawable.ic_redo)
            imageTintList = ColorStateList.valueOf(getColor(R.color.ink))
            isClickable = true; isFocusable = true
            contentDescription = "redo"
            setOnClickListener { userRedo() }
            setPadding(6.dp, 2.dp, 2.dp, 2.dp)
        }
        chip.addView(undo, LinearLayout.LayoutParams(28.dp, 22.dp))
        chip.addView(redo, LinearLayout.LayoutParams(28.dp, 22.dp))
        return chip
    }

    private fun undoRedoChipParams() = FrameLayout.LayoutParams(
        ViewGroup.LayoutParams.WRAP_CONTENT,
        ViewGroup.LayoutParams.WRAP_CONTENT
    ).apply {
        gravity = Gravity.TOP or Gravity.START
        topMargin  = 16.dp
        marginStart = 16.dp
    }

    // ====================================================================
    // Status bar
    // ====================================================================

    private fun buildStatusBar(): View {
        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setBackgroundColor(getColor(R.color.paperDeep))
            setPadding(12.dp, 0, 12.dp, 0)
        }
        // Top hairline so the bar feels separated from the canvas above.
        val wrapper = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
        }
        wrapper.addView(View(this).apply {
            setBackgroundColor(getColor(R.color.rule))
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 1.dp))
        wrapper.addView(bar, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, 0, 1.0f))

        statusDocText  = makeStatusText("doc · $currentDocName")
        statusToolText = makeStatusText("◇ ${currentToolMirror.displayName.lowercase()}")
        statusGridText = makeStatusText("grid: off")
        statusSnapText = makeStatusText("snap: on")
        statusPageText = makeStatusText("page —")

        bar.addView(statusDocText,  statusItemLp())
        bar.addView(statusToolText, statusItemLp())
        bar.addView(statusGridText, statusItemLp())
        bar.addView(statusSnapText, statusItemLp())
        // Spacer pushes pageText to the right edge.
        bar.addView(View(this), LinearLayout.LayoutParams(
            0, 0, 1.0f))
        bar.addView(statusPageText, LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT))
        return wrapper
    }

    private fun makeStatusText(initial: String): TextView = TextView(this).apply {
        text = initial
        typeface = fontMono ?: Typeface.MONOSPACE
        textSize = 9f
        setTextColor(getColor(R.color.inkSoft))
    }

    private fun statusItemLp() = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.WRAP_CONTENT,
        ViewGroup.LayoutParams.WRAP_CONTENT
    ).apply { marginEnd = 18.dp }

    private fun updateStatusBarPage() {
        if (!::statusPageText.isInitialized) return
        val pc = NativeRenderer.getPageCount().coerceAtLeast(1)
        val ap = NativeRenderer.getActivePage().coerceIn(0, pc - 1)
        statusPageText.text = "page ${String.format("%02d", ap + 1)} / $pc"
    }

    // ====================================================================
    // Overflow menus
    // ====================================================================

    private fun showOverflowMenu(anchor: View) {
        val menu = PopupMenu(this, anchor, Gravity.END)
        menu.menu.add("Snap: ${if (snapEnabled) "on" else "off"}")
        menu.menu.add("Stylus only: ${if (stylusOnly) "on" else "off"}")
        menu.menu.add("Delete selection")
        menu.menu.add("Copy")
        menu.menu.add("Paste")
        menu.setOnMenuItemClickListener { item ->
            val title = item.title.toString()
            when {
                title == "Delete selection"       -> userDeleteSelection()
                title == "Copy"                   -> drawingView?.queueCopySelection()
                title == "Paste"                  -> drawingView?.queuePasteSelection()
                title.startsWith("Snap:")         -> toggleSnap()
                title.startsWith("Stylus only:")  -> toggleStylusOnly()
            }
            true
        }
        menu.show()
    }

    private fun showLayerOverflow(anchor: View) {
        val menu = PopupMenu(this, anchor, Gravity.END)
        menu.menu.add("+ Vector layer")
        menu.menu.add("Clear active layer")
        menu.setOnMenuItemClickListener { item ->
            when (item.title.toString()) {
                "+ Vector layer"     -> userAddVectorLayer()
                "Clear active layer" -> userClearLayer()
            }
            true
        }
        menu.show()
    }

    private fun showDocsMenu(anchor: View) {
        val menu = PopupMenu(this, anchor, Gravity.END)
        // Prefix the active doc with • so the user sees what's open.
        for (name in listDocumentNames()) {
            menu.menu.add(if (name == currentDocName) "• $name" else "  $name")
        }
        menu.menu.add("+ New document")
        menu.menu.add("Rename current…")
        menu.menu.add("Delete current")
        menu.setOnMenuItemClickListener { item ->
            val title = item.title.toString()
            when {
                title == "+ New document"   -> userNewDocument()
                title == "Rename current…"  -> showRenameDocDialog()
                title == "Delete current"   -> userDeleteCurrentDocument()
                else -> {
                    val name = title.removePrefix("• ").removePrefix("  ").trim()
                    if (name != currentDocName) switchToDocument(name)
                }
            }
            true
        }
        menu.show()
    }

    /** Rename the currently-open document. Validates non-empty, no
     *  collision with another doc, and that the underlying directory
     *  rename succeeds. After rename, points native at the new path
     *  (without going through loadDocument so undo state survives) and
     *  refreshes the status bar / sidebar mirrors. */
    private fun showRenameDocDialog() {
        val current = currentDocName
        val input = android.widget.EditText(this).apply {
            setText(current)
            setSelection(current.length)
            hint = "document name"
        }
        val container = FrameLayout(this).apply {
            val pad = 16.dp
            setPadding(pad, 8.dp, pad, 0)
            addView(input, FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT))
        }
        AlertDialog.Builder(this)
            .setTitle("Rename document")
            .setView(container)
            .setPositiveButton("OK") { _, _ ->
                val raw = input.text.toString().trim()
                if (raw.isEmpty() || raw == current) return@setPositiveButton
                if (raw in listDocumentNames()) {
                    android.widget.Toast.makeText(this,
                        "A document named “$raw” already exists",
                        android.widget.Toast.LENGTH_SHORT).show()
                    return@setPositiveButton
                }
                renameCurrentDocument(raw)
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun renameCurrentDocument(newName: String) {
        val oldDir = docDirFor(currentDocName)
        val newDir = docDirFor(newName)
        if (!oldDir.exists() || !oldDir.renameTo(newDir)) {
            android.widget.Toast.makeText(this,
                "Couldn't rename document",
                android.widget.Toast.LENGTH_SHORT).show()
            return
        }
        currentDocName = newName
        rememberDocName(newName)
        // Point native I/O at the new path. setDocumentDir is safe to call
        // mid-session — it just stores the path; the in-memory layer
        // state stays put, and future tile saves go to the new location.
        // Avoids the undo-stack reset that loadDocument would trigger.
        NativeRenderer.setDocumentDir(newDir.absolutePath)
        if (::statusDocText.isInitialized) statusDocText.text = "doc · $newName"
    }

    // ====================================================================
    // State sync + action helpers (preserved from previous implementation)
    // ====================================================================

    private fun syncLayerStateFromNative() {
        val count = NativeRenderer.getLayerCount().coerceAtLeast(1)
        val active = NativeRenderer.getActiveLayer().coerceIn(0, count - 1)
        layerCount = count
        activeLayerIndex = active
        if (::layerListContainer.isInitialized) rebuildLayerList()
        updateStatusBarPage()
    }

    private fun userAddLayer() {
        NativeRenderer.addLayer()
        layerCount++
        activeLayerIndex = layerCount - 1
        rebuildLayerList()
    }

    private fun userAddVectorLayer() {
        NativeRenderer.addVectorLayer()
        layerCount++
        activeLayerIndex = layerCount - 1
        rebuildLayerList()
    }

    private fun userCycleLayer() {
        NativeRenderer.cycleActiveLayer()
        activeLayerIndex = (activeLayerIndex + 1) % layerCount
        rebuildLayerList()
    }

    private fun userClearLayer() {
        NativeRenderer.clearActiveLayer()
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
        if (::statusSnapText.isInitialized) {
            statusSnapText.text = if (snapEnabled) "snap: on" else "snap: off"
        }
    }

    /** Flip palm-rejection mode. Persisted across launches; the view's
     *  touch dispatcher reads stylusOnlyDrawing every event so the
     *  change takes effect immediately. */
    private fun toggleStylusOnly() {
        stylusOnly = !stylusOnly
        drawingView?.stylusOnlyDrawing = stylusOnly
        prefs().edit().putBoolean(kPrefStylusOnly, stylusOnly).apply()
    }

    private fun userUndo() {
        NativeRenderer.undo()
        drawingView?.forceRedraw()
        drawingView?.postDelayed({ syncLayerStateFromNative() }, 60L)
    }

    private fun userRedo() {
        NativeRenderer.redo()
        drawingView?.forceRedraw()
        drawingView?.postDelayed({ syncLayerStateFromNative() }, 60L)
    }

    private fun cycleGrid() {
        gridState = (gridState + 1) % 3
        when (gridState) {
            0 -> {
                NativeRenderer.setGridEnabled(false)
            }
            1 -> {
                NativeRenderer.setGridStyle(1)
                NativeRenderer.setGridEnabled(true)
            }
            2 -> {
                NativeRenderer.setGridStyle(2)
                NativeRenderer.setGridEnabled(true)
            }
        }
        if (::statusGridText.isInitialized) {
            statusGridText.text = when (gridState) {
                0 -> "grid: off"; 1 -> "grid: lines"; else -> "grid: dots"
            }
        }
        drawingView?.forceRedraw()
    }

    // ---- Slider geometric mappings (unchanged from previous version) ----

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

    /** Slider position (0..100, target stroke opacity %) → per-dab α. */
    private fun progressToBrushAlpha(p: Int): Float {
        if (p >= 100) return 1.0f
        if (p <= 0)   return 0.0f
        val target = p / 100.0
        return (1.0 - Math.pow(1.0 - target, 1.0 / kAlphaDabsPerOverlap)).toFloat()
    }

    /** Per-dab α → slider position (target stroke opacity %). */
    private fun brushAlphaToProgress(a: Float): Int {
        if (a >= 1.0f) return 100
        if (a <= 0.0f) return 0
        val target = 1.0 - Math.pow(1.0 - a.toDouble(), kAlphaDabsPerOverlap)
        return (target * 100).toInt().coerceIn(0, 100)
    }

    // ---- Document I/O ---------------------------------------------------

    private fun documentsRoot(): File =
        File(filesDir, kDocumentsRootName).apply { mkdirs() }

    private fun docDirFor(name: String): File = File(documentsRoot(), name)

    private fun listDocumentNames(): List<String> =
        documentsRoot().listFiles { f -> f.isDirectory }
            ?.map { it.name }
            ?.sorted()
            ?: emptyList()

    private fun nextUntitledName(): String {
        val existing = listDocumentNames().toSet()
        var n = 1
        while ("Untitled $n" in existing) n++
        return "Untitled $n"
    }

    /** Move filesDir/document/ → filesDir/documents/document/ on first run. */
    private fun migrateLegacyDocumentIfNeeded() {
        val legacy = File(filesDir, "document")
        if (!legacy.isDirectory) return
        val target = docDirFor("document")
        if (target.exists()) return
        if (!documentsRoot().exists()) documentsRoot().mkdirs()
        if (!legacy.renameTo(target)) {
            android.util.Log.e("DrawingApp", "failed to migrate legacy document/")
        }
    }

    private fun prefs() = getSharedPreferences(kPrefsName, Context.MODE_PRIVATE)
    private fun rememberDocName(name: String) {
        prefs().edit().putString(kPrefLastDoc, name).apply()
    }
    private fun lastOpenedDocName(): String? = prefs().getString(kPrefLastDoc, null)

    private fun switchToDocument(name: String) {
        val dir = docDirFor(name).apply { mkdirs() }
        currentDocName = name
        rememberDocName(name)
        if (::statusDocText.isInitialized) statusDocText.text = "doc · $name"
        NativeRenderer.loadDocument(dir.absolutePath)
        drawingView?.forceRedraw()
        lastBuiltPageCount = -1
        lastBuiltActivePage = -1
    }

    private fun userNewDocument() {
        switchToDocument(nextUntitledName())
    }

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
        val others = listDocumentNames().filter { it != name }
        val target = others.firstOrNull() ?: nextUntitledName()
        switchToDocument(target)
        val ok = docDirFor(name).deleteRecursively()
        if (!ok) android.util.Log.e("DrawingApp", "deleteRecursively($name) failed")
    }

    // ---- Page sidebar wiring -------------------------------------------

    private fun userAddPage() {
        NativeRenderer.addPage()
        drawingView?.forceRedraw()
    }

    /** Per-thumbnail overflow menu: just Delete for now. Disabled when
     *  there's only one page (the document needs at least one). */
    private fun showPageOverflow(anchor: View, idx: Int) {
        val menu = PopupMenu(this, anchor, Gravity.END)
        val delete = menu.menu.add(0, 0, 0, "Delete page")
        delete.isEnabled = NativeRenderer.getPageCount() > 1
        menu.setOnMenuItemClickListener { item ->
            when (item.itemId) {
                0 -> confirmDeletePage(idx)
            }
            true
        }
        menu.show()
    }

    private fun confirmDeletePage(idx: Int) {
        AlertDialog.Builder(this)
            .setTitle("Delete page")
            .setMessage("Delete page ${idx + 1}? This can't be undone.")
            .setPositiveButton("Delete") { _, _ -> userDeletePage(idx) }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun userDeletePage(idx: Int) {
        if (NativeRenderer.getPageCount() <= 1) return
        NativeRenderer.deletePage(idx)
        drawingView?.forceRedraw()
        // Native applies the delete on the GL thread next op. Rebuild the
        // sidebar after a beat so getPageCount/getActivePage reflect the
        // post-drain state. syncLayerStateFromNative covers the layer
        // mirror because the active page's layers may differ.
        drawingView?.postDelayed({
            rebuildSidebar()
            syncLayerStateFromNative()
        }, 60L)
    }

    private fun userMovePage(from: Int, to: Int) {
        val count = NativeRenderer.getPageCount()
        if (from == to || from < 0 || to < 0 || from >= count || to >= count) return
        NativeRenderer.movePage(from, to)
        drawingView?.forceRedraw()
        drawingView?.postDelayed({
            rebuildSidebar()
            syncLayerStateFromNative()
        }, 60L)
    }

    /** Bind the drag-to-reorder touch handler onto the handle ImageView for
     *  the page item at native [idx]. Same gesture vocabulary as the
     *  layer panel's handle, but operates on pageItems / sidebarLayout
     *  for displacement. */
    private fun installPageDragHandleListener(handle: View, idx: Int, container: View) {
        handle.setOnTouchListener { v, ev ->
            when (ev.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    if (NativeRenderer.getPageCount() <= 1) return@setOnTouchListener false
                    dragPageSourceIdx = idx
                    dragPageSourceView = container
                    dragPageStartRawY = ev.rawY
                    dragPageStartTranslationY = container.translationY
                    // Slot height = container + topMargin (sidebarItemParams).
                    dragPageSlotHeightPx = container.height + 6.dp
                    dragPageCurrentTargetIdx = idx
                    container.elevation = 6.dp.toFloat()
                    container.alpha = 0.95f
                    // Stop the ScrollView ancestor from intercepting the
                    // gesture mid-drag (it would otherwise grab on
                    // vertical movement).
                    v.parent?.requestDisallowInterceptTouchEvent(true)
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    if (dragPageSourceIdx != idx || dragPageSourceView !== container) {
                        return@setOnTouchListener false
                    }
                    val dy = ev.rawY - dragPageStartRawY
                    container.translationY = dragPageStartTranslationY + dy
                    updatePageDragDisplacement(container)
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    if (dragPageSourceIdx != idx || dragPageSourceView !== container) {
                        return@setOnTouchListener false
                    }
                    val targetIdx = dragPageCurrentTargetIdx
                    val sourceIdx = dragPageSourceIdx
                    container.elevation = 0f
                    container.alpha = 1.0f
                    container.translationY = 0f
                    resetAllPageDisplacements()
                    dragPageSourceIdx = -1
                    dragPageSourceView = null
                    dragPageCurrentTargetIdx = -1

                    val count = NativeRenderer.getPageCount()
                    if (targetIdx in 0 until count && targetIdx != sourceIdx) {
                        userMovePage(sourceIdx, targetIdx)
                    }
                    true
                }
                else -> false
            }
        }
    }

    /** While a page item is being dragged, shift the other items so a
     *  visual gap follows the dragged thumb. Called on every MOVE event;
     *  also updates [dragPageCurrentTargetIdx] (used at UP). Mirrors the
     *  layer-row version but operates on pageItems where uiPos == idx. */
    private fun updatePageDragDisplacement(draggedContainer: View) {
        val sourceIdx = dragPageSourceIdx
        if (sourceIdx < 0) return
        val draggedCenter = draggedContainer.top + draggedContainer.translationY +
                            draggedContainer.height / 2f
        var newIdx = 0
        for (item in pageItems) {
            if (item.pageIdx == sourceIdx) continue
            val originalCenter = item.container.top + item.container.height / 2f
            if (originalCenter < draggedCenter) newIdx++
        }
        if (newIdx == dragPageCurrentTargetIdx) return
        dragPageCurrentTargetIdx = newIdx
        for (item in pageItems) {
            if (item.pageIdx == sourceIdx) continue
            val origIdx = item.pageIdx
            val displayedIdx = when {
                sourceIdx < newIdx ->
                    if (origIdx in (sourceIdx + 1)..newIdx) origIdx - 1 else origIdx
                sourceIdx > newIdx ->
                    if (origIdx in newIdx..(sourceIdx - 1)) origIdx + 1 else origIdx
                else -> origIdx
            }
            val target = ((displayedIdx - origIdx) * dragPageSlotHeightPx).toFloat()
            item.container.animate().translationY(target).setDuration(120L).start()
        }
    }

    private fun resetAllPageDisplacements() {
        for (item in pageItems) item.container.translationY = 0f
    }

    private fun onThumbnailsUpdated() {
        for (item in pageItems) item.imageView.invalidate()
        val pc = NativeRenderer.getPageCount()
        val ap = NativeRenderer.getActivePage()
        if (pc != lastBuiltPageCount || ap != lastBuiltActivePage) {
            syncLayerStateFromNative()
            rebuildSidebar()
        }
        updateStatusBarPage()
    }

    // ---- Fonts (downloadable) ------------------------------------------

    private fun loadFonts() {
        // The synchronous ResourcesCompat.getFont throws Resources$
        // NotFoundException when downloadable fonts can't be resolved
        // on the calling thread (e.g. provider unreachable, GMS query
        // pending, signature mismatch). We never want that to crash
        // the activity — fall back to the system mono/sans Typeface,
        // which the rest of the UI consumes through `?:` defaults.
        //
        // The async path (ResourcesCompat.getFont with FontCallback)
        // would let the real fonts swap in once they download; we can
        // wire that in a follow-up if the system mono isn't acceptable.
        fontMono          = tryLoadFont(R.font.jetbrains_mono)
        fontMonoSemibold  = tryLoadFont(R.font.jetbrains_mono_semibold)
        fontInter         = tryLoadFont(R.font.inter)
        fontInterSemibold = tryLoadFont(R.font.inter_semibold)
    }

    private fun tryLoadFont(@androidx.annotation.FontRes id: Int): Typeface? = try {
        ResourcesCompat.getFont(this, id)
    } catch (t: Throwable) {
        android.util.Log.w("DrawingApp",
            "downloadable font ${resources.getResourceEntryName(id)} unavailable: $t")
        null
    }

    // ---- Helpers --------------------------------------------------------

    private val Int.dp: Int
        get() = (this * resources.displayMetrics.density).toInt()
}
