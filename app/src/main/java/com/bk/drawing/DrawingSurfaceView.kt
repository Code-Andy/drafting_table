package com.bk.drawing

import android.content.Context
import android.opengl.Matrix
import android.util.AttributeSet
import android.util.Log
import android.view.MotionEvent
import android.view.SurfaceView
import androidx.graphics.lowlatency.BufferInfo
import androidx.graphics.lowlatency.GLFrontBufferedRenderer
import androidx.graphics.opengl.egl.EGLManager
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.sin

// Param type for the front-buffered renderer. Brush/eraser strokes flow
// through Sample (a stream per stroke); the shape tools (line, rect,
// circle, ellipse) flow through ShapePreview (one entry per pen position
// during the drag), with shapeType selecting which shape to render.
sealed class StrokeAction {
    data class Sample(
        val x: Float, val y: Float, val pressure: Float,
        val isNewStroke: Boolean,
        // Predicted samples render into the front buffer to mask input
        // latency but are never baked into the doc on commit (so the
        // committed stroke matches the actual pen path, not the guesses).
        val predicted: Boolean = false
    ) : StrokeAction()

    data class ShapePreview(
        val shapeType: Int,             // matches NativeRenderer.renderShapePreview
        val x0: Float, val y0: Float,
        val x1: Float, val y1: Float,
        val snapped: Boolean            // shows snap marker at (x1, y1)
    ) : StrokeAction()
}

// Only BRUSH and ERASER correspond to native "stroke tools" (running
// through beginStroke / extendStroke / commitStroke). The shape tools
// have their own gesture path and don't update the native stroke tool.
// BUCKET is a click-to-act tool with its own native entrypoint; nativeId
// is unused for it.
enum class Tool(val nativeId: Int) {
    BRUSH      (0),
    ERASER     (1),
    BUCKET     (-1),
    LINE       (2),
    RECTANGLE  (3),
    CIRCLE     (4),
    ELLIPSE    (5),
    SELECT     (6),
    SELECT_RECT(-1);    // raster rectangle marquee; no native tool id

    /** Shape-type code passed to NativeRenderer for shape tools. */
    val shapeType: Int
        get() = when (this) {
            LINE      -> 0
            RECTANGLE -> 1
            CIRCLE    -> 2
            ELLIPSE   -> 3
            else      -> -1
        }

    val isShape: Boolean
        get() = this == LINE || this == RECTANGLE || this == CIRCLE || this == ELLIPSE
}

class DrawingSurfaceView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null
) : SurfaceView(context, attrs) {

    private val callback = object : GLFrontBufferedRenderer.Callback<StrokeAction> {
        override fun onDrawFrontBufferedLayer(
            eglManager: EGLManager,
            width: Int,
            height: Int,
            bufferInfo: BufferInfo,
            transform: FloatArray,
            param: StrokeAction
        ) {
            // Native shaders expect `transform` to be doc-pixel →
            // buffer-pixel; compose the framework's view→buffer with our
            // current doc→view here.
            val composed = composedTransform(transform)
            when (param) {
                is StrokeAction.Sample -> {
                    if (param.isNewStroke) {
                        NativeRenderer.beginStroke()
                    }
                    if (param.predicted) {
                        NativeRenderer.extendStrokePredicted(
                            bufferInfo.width, bufferInfo.height,
                            composed,
                            param.x, param.y, param.pressure
                        )
                    } else {
                        NativeRenderer.extendStroke(
                            bufferInfo.width, bufferInfo.height,
                            composed,
                            param.x, param.y, param.pressure
                        )
                    }
                }
                is StrokeAction.ShapePreview -> {
                    NativeRenderer.renderShapePreview(
                        bufferInfo.width, bufferInfo.height,
                        composed,
                        param.shapeType,
                        param.x0, param.y0, param.x1, param.y1,
                        param.snapped
                    )
                }
            }
        }

        override fun onDrawMultiBufferedLayer(
            eglManager: EGLManager,
            width: Int,
            height: Int,
            bufferInfo: BufferInfo,
            transform: FloatArray,
            params: Collection<StrokeAction>
        ) {
            val composed = composedTransform(transform)
            // Only commit a brush/eraser stroke if this batch actually
            // contained Sample entries. Line previews go through here too
            // when the line tool's commit calls renderer.commit(); we
            // mustn't bake an empty stroke in that case. cancelNextCommit
            // (set when a 2-finger gesture interrupts a stroke) suppresses
            // the bake entirely so the in-progress stroke is discarded.
            val hadStrokeSamples = params.any { it is StrokeAction.Sample }
            if (hadStrokeSamples && !cancelNextCommit) {
                NativeRenderer.commitStroke()
            }
            cancelNextCommit = false
            // Drain a queued bucket fill before the main render so the
            // newly-painted tiles show up in this very pass.
            val bucket = pendingBucketFill
            if (bucket != null) {
                pendingBucketFill = null
                NativeRenderer.bucketFillAt(bucket.x, bucket.y)
            }
            NativeRenderer.renderDocument(
                bufferInfo.width, bufferInfo.height,
                composed
            )
            // Refresh page thumbnails for the sidebar. By default we only
            // re-render the ACTIVE page (the only one whose pixels can
            // have changed since the last multi-buffer pass under normal
            // drawing). setThumbnailTargets / requestFullThumbnailRefresh
            // sets a one-shot flag to refresh all entries the next time
            // around (used after addPage / switchPage / sidebar rebuild).
            val targets = thumbnailTargets
            if (targets != null && targets.isNotEmpty()) {
                val pageCount  = NativeRenderer.getPageCount()
                val activePage = NativeRenderer.getActivePage()
                val refreshAll = thumbnailRefreshAllOnce
                thumbnailRefreshAllOnce = false

                for ((idx, bitmap) in targets) {
                    if (idx !in 0 until pageCount) continue
                    if (refreshAll || idx == activePage) {
                        NativeRenderer.renderPageThumbnail(idx, bitmap)
                    }
                }
                post { onThumbnailsUpdated?.invoke() }
            }
        }
    }

    // Map of page index → Bitmap to write thumbnail pixels into. Set by
    // MainActivity each time the sidebar is (re)built. Read on the GL
    // thread; the map itself is only ever replaced wholesale, never
    // mutated in place.
    @Volatile
    private var thumbnailTargets: Map<Int, android.graphics.Bitmap>? = null
    @Volatile
    private var thumbnailRefreshAllOnce = false

    /** Notified on the UI thread after every batch of thumbnails finishes
     *  rendering. The sidebar uses this to ImageView.invalidate() each item. */
    var onThumbnailsUpdated: (() -> Unit)? = null

    fun setThumbnailTargets(targets: Map<Int, android.graphics.Bitmap>?) {
        thumbnailTargets = targets
        thumbnailRefreshAllOnce = true
    }

    /** Force every registered thumbnail to refresh on the next multi-buffer
     *  pass, even those for non-active pages. */
    fun requestFullThumbnailRefresh() {
        thumbnailRefreshAllOnce = true
    }

    private var renderer: GLFrontBufferedRenderer<StrokeAction>? =
        GLFrontBufferedRenderer(this, callback)

    // -------------------------------------------------------------------
    // View transform: doc-pixel → view-pixel, parameterized as scale,
    // rotation (radians, applied around origin), and translation.
    // Identity by default. Updated by 2-finger gestures.
    //
    // The composition viewBufferTransform * docToViewMatrix is the matrix
    // we send to native shaders, so all native rendering operates in
    // doc-px and the view transform is "free" downstream.
    // -------------------------------------------------------------------
    private var viewScale = 1.0f
    private var viewRotation = 0.0f
    private var viewPanX = 0.0f
    private var viewPanY = 0.0f

    // Reused scratch buffers; touch handling runs at high rate, avoid alloc.
    private val tmpDoc = FloatArray(2)
    private val tmpDocToView = FloatArray(16)
    private val tmpComposed = FloatArray(16)

    /** Convert a view-pixel coordinate to its doc-pixel equivalent. */
    private fun viewToDoc(vx: Float, vy: Float, out: FloatArray) {
        val tx = vx - viewPanX
        val ty = vy - viewPanY
        val invS = 1f / viewScale
        // Inverse rotation = R(-rotation).
        val c = cos(-viewRotation)
        val s = sin(-viewRotation)
        out[0] = invS * (c * tx - s * ty)
        out[1] = invS * (s * tx + c * ty)
    }

    /** Build a column-major 4x4 of the current doc→view affine. */
    private fun fillDocToViewMatrix(out: FloatArray) {
        val c = cos(viewRotation)
        val s = sin(viewRotation)
        val a = viewScale * c
        val b = viewScale * s
        // Column 0
        out[0]  =  a;  out[1]  =  b;  out[2]  = 0f; out[3]  = 0f
        // Column 1
        out[4]  = -b;  out[5]  =  a;  out[6]  = 0f; out[7]  = 0f
        // Column 2 (z)
        out[8]  = 0f;  out[9]  = 0f;  out[10] = 1f; out[11] = 0f
        // Column 3 (translation)
        out[12] = viewPanX; out[13] = viewPanY; out[14] = 0f; out[15] = 1f
    }

    /** Compose framework's view→buffer transform with our doc→view, giving
     *  the doc→buffer matrix the native shaders consume as `uTransform`. */
    private fun composedTransform(framebufferTransform: FloatArray): FloatArray {
        fillDocToViewMatrix(tmpDocToView)
        Matrix.multiplyMM(tmpComposed, 0,
            framebufferTransform, 0,
            tmpDocToView, 0)
        return tmpComposed
    }

    /** Reset view transform to identity. Forces a redraw. */
    fun resetView() {
        viewScale = 1.0f
        viewRotation = 0.0f
        viewPanX = 0.0f
        viewPanY = 0.0f
        NativeRenderer.setViewScale(viewScale)
        forceRedraw()
    }

    // Shape-tool drag state (doc-pixels, post-snap). Shared by Line,
    // Rectangle, Circle, Ellipse — only the interpretation differs.
    private var shapeP0X = 0f
    private var shapeP0Y = 0f
    private var shapeP1X = 0f
    private var shapeP1Y = 0f

    private var currentTool = Tool.BRUSH

    /** Notified after the active tool changes (from the UI button or
     *  the stylus side-button). MainActivity uses this to refresh the
     *  on-screen tool button label. */
    var onToolChanged: ((Tool) -> Unit)? = null

    /** Public so MainActivity's tool button can route through the same
     *  code path the stylus side-button uses. Cycles through every tool. */
    fun toggleTool() {
        // Auto-commit any floating raster selection before swapping tools
        // so the user doesn't lose their work or end up with a stranded
        // floating overlay belonging to a tool they can no longer interact
        // with. Cheap no-op when nothing is selected.
        if (NativeRenderer.hasRasterSelection()) {
            NativeRenderer.commitRasterSelection()
            forceRedraw()
        }
        currentTool = when (currentTool) {
            Tool.BRUSH       -> Tool.ERASER
            Tool.ERASER      -> Tool.BUCKET
            Tool.BUCKET      -> Tool.LINE
            Tool.LINE        -> Tool.RECTANGLE
            Tool.RECTANGLE   -> Tool.CIRCLE
            Tool.CIRCLE      -> Tool.ELLIPSE
            Tool.ELLIPSE     -> Tool.SELECT
            Tool.SELECT      -> Tool.SELECT_RECT
            Tool.SELECT_RECT -> Tool.BRUSH
        }
        // Native only knows about the raster stroke tools (brush/eraser);
        // shape and select tools are handled entirely on the Kotlin side
        // via their own gesture paths.
        if (currentTool == Tool.BRUSH || currentTool == Tool.ERASER) {
            NativeRenderer.setTool(currentTool.nativeId)
        }
        Log.i("DrawingApp", "tool -> ${currentTool.name.lowercase()}")
        onToolChanged?.invoke(currentTool)
    }

    // Last-seen stylus button bitmask, used to detect press transitions
    // even on devices/states that don't fire ACTION_BUTTON_PRESS (notably
    // Wacom EMR while the pen is hovering — buttonState is reported on
    // hover events too, but the discrete press action isn't always).
    private var prevButtonState = 0

    /**
     * Detect stylus side-button presses two ways:
     *   1. ACTION_BUTTON_PRESS with actionButton == BUTTON_STYLUS_SECONDARY
     *      (the standard path; fires while pen is in contact).
     *   2. A 0→1 transition of the BUTTON_STYLUS_SECONDARY bit in
     *      event.buttonState (catches presses during hover that don't
     *      generate ACTION_BUTTON_PRESS).
     */
    private fun handleStylusButton(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_BUTTON_PRESS) {
            val ab = event.actionButton
            Log.i("DrawingApp", "ACTION_BUTTON_PRESS: 0x${ab.toString(16)}")
            if (ab == MotionEvent.BUTTON_STYLUS_SECONDARY) {
                toggleTool()
                prevButtonState = event.buttonState
                return true
            }
        }
        val state = event.buttonState
        val newlyPressed = state and prevButtonState.inv()
        prevButtonState = state
        if (newlyPressed and MotionEvent.BUTTON_STYLUS_SECONDARY != 0) {
            Log.i("DrawingApp",
                "stylus button transition (during action=${event.actionMasked}): " +
                "0x${newlyPressed.toString(16)}")
            toggleTool()
            return true
        }
        return false
    }

    override fun onGenericMotionEvent(event: MotionEvent): Boolean {
        if (handleStylusButton(event)) return true
        return super.onGenericMotionEvent(event)
    }

    override fun onHoverEvent(event: MotionEvent): Boolean {
        if (handleStylusButton(event)) return true
        return super.onHoverEvent(event)
    }

    // ---- 2-finger pan/zoom/rotate gesture state ----------------------
    //
    // While a gesture is active, viewScale/Rotation/Pan are recomputed
    // each MOVE so the two anchor doc-points (captured at the moment the
    // 2nd finger touched) stay locked under their respective fingers.
    // suppressTouches stays true after the gesture ends until every finger
    // has lifted, so a finger left from the gesture doesn't accidentally
    // start a stroke.
    private var gestureActive = false
    private var gestureP1Id = -1
    private var gestureP2Id = -1
    private var gestureP1DocX = 0f; private var gestureP1DocY = 0f
    private var gestureP2DocX = 0f; private var gestureP2DocY = 0f
    private var suppressTouches = false

    // Set by the gesture path when an in-progress brush/eraser stroke is
    // discarded; checked in onDrawMultiBufferedLayer to skip the bake.
    private var cancelNextCommit = false

    private fun anyStylusPointer(event: MotionEvent): Boolean {
        for (i in 0 until event.pointerCount) {
            if (event.getToolType(i) == MotionEvent.TOOL_TYPE_STYLUS) return true
        }
        return false
    }

    private fun beginGesture(event: MotionEvent, p1Index: Int, p2Index: Int) {
        // Cancel any in-progress draw / interaction so the user's drag
        // doesn't bleed into a stroke or transform on gesture release.
        when (currentTool) {
            Tool.BRUSH, Tool.ERASER -> {
                NativeRenderer.discardStroke()
                cancelNextCommit = true
                renderer?.commit()
            }
            Tool.BUCKET -> {
                // Click-to-act, nothing in flight to cancel.
            }
            Tool.LINE, Tool.RECTANGLE, Tool.CIRCLE, Tool.ELLIPSE -> {
                renderer?.commit()
                p1Snapped = false
            }
            Tool.SELECT -> {
                if (selectMode != 0) {
                    NativeRenderer.endInteraction()
                    selectMode = 0
                    selectChanged = false
                }
            }
            Tool.SELECT_RECT -> {
                // If mid-define, cancel the rectangle preview; the
                // floating selection (if any) survives the gesture.
                if (selRectMode == SelRectMode.DEFINE) {
                    renderer?.commit()
                }
                selRectMode = SelRectMode.NONE
            }
        }
        gestureP1Id = event.getPointerId(p1Index)
        gestureP2Id = event.getPointerId(p2Index)
        viewToDoc(event.getX(p1Index), event.getY(p1Index), tmpDoc)
        gestureP1DocX = tmpDoc[0]; gestureP1DocY = tmpDoc[1]
        viewToDoc(event.getX(p2Index), event.getY(p2Index), tmpDoc)
        gestureP2DocX = tmpDoc[0]; gestureP2DocY = tmpDoc[1]
        gestureActive   = true
        suppressTouches = true
    }

    private fun updateGesture(event: MotionEvent) {
        val i1 = event.findPointerIndex(gestureP1Id)
        val i2 = event.findPointerIndex(gestureP2Id)
        if (i1 < 0 || i2 < 0) return
        val v1x = event.getX(i1); val v1y = event.getY(i1)
        val v2x = event.getX(i2); val v2y = event.getY(i2)

        // Solve the 2-point similarity problem: find scale, rotation, pan
        // such that view(D1) = V1' and view(D2) = V2', where view(D) =
        // pan + scale * R(rotation) * D.
        val viewDx = v2x - v1x; val viewDy = v2y - v1y
        val docDx  = gestureP2DocX - gestureP1DocX
        val docDy  = gestureP2DocY - gestureP1DocY
        val viewLen = hypot(viewDx, viewDy)
        val docLen  = hypot(docDx,  docDy)
        if (viewLen < 1e-3f || docLen < 1e-3f) return

        // Clamp scale to a sane range. Without this, zooming far out makes
        // any natural finger movement span enormous doc-pixel distances,
        // and the stroke bake then has to materialize a tile FBO for every
        // cell along the way — which can OOM the GPU.
        val rawScale    = (viewLen / docLen).toFloat()
        val newScale    = rawScale.coerceIn(kMinViewScale, kMaxViewScale)
        val newRotation = (atan2(viewDy, viewDx) - atan2(docDy, docDx)).toFloat()
        val c = cos(newRotation); val s = sin(newRotation)
        val newPanX = v1x - newScale * (c * gestureP1DocX - s * gestureP1DocY)
        val newPanY = v1y - newScale * (s * gestureP1DocX + c * gestureP1DocY)

        viewScale    = newScale
        viewRotation = newRotation
        viewPanX     = newPanX
        viewPanY     = newPanY
        NativeRenderer.setViewScale(viewScale)
        forceRedraw()
    }

    private companion object {
        // Limits on the gesture-driven view scale.
        const val kMinViewScale = 0.25f
        const val kMaxViewScale = 8.0f
    }

    private fun endGesture() {
        gestureActive = false
        gestureP1Id = -1
        gestureP2Id = -1
        // suppressTouches stays true until the last finger lifts.
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (handleStylusButton(event)) return true

        val r = renderer ?: return super.onTouchEvent(event)
        val action = event.actionMasked

        // ACTION_DOWN = transition from 0 → 1 pointers on screen, so no
        // prior gesture state should leak through. Reset defensively in
        // case an earlier ACTION_UP / ACTION_POINTER_UP was dropped (palm
        // rejection edge cases can do this); without this, a stuck flag
        // would silently swallow the new stroke.
        if (action == MotionEvent.ACTION_DOWN) {
            gestureActive   = false
            suppressTouches = false
            cancelNextCommit = false
        }

        // While a gesture is active, all events drive the gesture path.
        if (gestureActive) {
            when (action) {
                MotionEvent.ACTION_MOVE -> updateGesture(event)
                MotionEvent.ACTION_POINTER_UP -> {
                    val upId = event.getPointerId(event.actionIndex)
                    if (upId == gestureP1Id || upId == gestureP2Id) endGesture()
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    endGesture()
                    suppressTouches = false
                }
            }
            return true
        }

        // After gesture, swallow remaining-finger events until all fingers
        // have lifted. Otherwise the trailing finger would start a stroke.
        if (suppressTouches) {
            if (action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL) {
                suppressTouches = false
            }
            return true
        }

        // 2nd finger down (with no stylus involved) starts a gesture.
        if (action == MotionEvent.ACTION_POINTER_DOWN
            && event.pointerCount == 2
            && !anyStylusPointer(event)) {
            beginGesture(event, 0, 1)
            return true
        }

        // Single-pointer path: dispatch to the active tool.
        val tt = event.getToolType(0)
        if (tt != MotionEvent.TOOL_TYPE_STYLUS && tt != MotionEvent.TOOL_TYPE_FINGER) {
            return super.onTouchEvent(event)
        }
        return when (currentTool) {
            Tool.BRUSH, Tool.ERASER -> handleStrokeEvent(r, event)
            Tool.BUCKET             -> handleBucketEvent(event)
            Tool.SELECT             -> handleSelectEvent(event)
            Tool.SELECT_RECT        -> handleSelectRectEvent(r, event)
            else                    -> handleShapeEvent(r, event, currentTool.shapeType)
        }
    }

    // ---- Raster selection (rectangle marquee) ------------------------
    //
    // Three sub-modes inside this handler:
    //   - DEFINE: no selection active → drag draws a preview rectangle.
    //     On UP the rect lifts the underlying pixels into a floating
    //     selection (handled entirely on the native side).
    //   - TRANSLATE: selection active and ACTION_DOWN landed inside its
    //     bbox → drag translates the floating selection.
    //   - COMMIT_THEN_DEFINE: selection active and ACTION_DOWN landed
    //     outside → commit it, then start a new DEFINE in the same gesture.
    private enum class SelRectMode { NONE, DEFINE, TRANSLATE }
    private var selRectMode = SelRectMode.NONE
    private var selRectStartX = 0f
    private var selRectStartY = 0f
    private var selRectLastX = 0f
    private var selRectLastY = 0f
    // Live preview of the rect being defined, in doc-px (only valid while
    // selRectMode == DEFINE).
    private var selRectPreviewX0 = 0f
    private var selRectPreviewY0 = 0f
    private var selRectPreviewX1 = 0f
    private var selRectPreviewY1 = 0f

    private fun handleSelectRectEvent(
        r: GLFrontBufferedRenderer<StrokeAction>,
        event: MotionEvent
    ): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                viewToDoc(event.x, event.y, tmpDoc)
                val dx = tmpDoc[0]; val dy = tmpDoc[1]
                if (NativeRenderer.hasRasterSelection()
                    && NativeRenderer.rasterSelectionContains(dx, dy)) {
                    // TRANSLATE mode: drag the floating selection.
                    selRectMode = SelRectMode.TRANSLATE
                    selRectLastX = dx
                    selRectLastY = dy
                } else {
                    // If a selection exists, commit it first.
                    if (NativeRenderer.hasRasterSelection()) {
                        NativeRenderer.commitRasterSelection()
                    }
                    selRectMode = SelRectMode.DEFINE
                    selRectStartX = dx
                    selRectStartY = dy
                    selRectPreviewX0 = dx; selRectPreviewY0 = dy
                    selRectPreviewX1 = dx; selRectPreviewY1 = dy
                    forceRedraw()
                }
            }
            MotionEvent.ACTION_MOVE -> {
                viewToDoc(event.x, event.y, tmpDoc)
                val dx = tmpDoc[0]; val dy = tmpDoc[1]
                when (selRectMode) {
                    SelRectMode.DEFINE -> {
                        selRectPreviewX1 = dx
                        selRectPreviewY1 = dy
                        // Render a rectangle outline on the front buffer
                        // so the user sees what they're selecting. Reuse
                        // the existing ShapePreview code path with the
                        // RECTANGLE shape type (1).
                        r.renderFrontBufferedLayer(
                            StrokeAction.ShapePreview(
                                shapeType = 1,
                                x0 = selRectPreviewX0, y0 = selRectPreviewY0,
                                x1 = selRectPreviewX1, y1 = selRectPreviewY1,
                                snapped = false
                            )
                        )
                    }
                    SelRectMode.TRANSLATE -> {
                        val mdx = dx - selRectLastX
                        val mdy = dy - selRectLastY
                        if (mdx != 0f || mdy != 0f) {
                            NativeRenderer.translateRasterSelection(mdx, mdy)
                            selRectLastX = dx
                            selRectLastY = dy
                            forceRedraw()
                        }
                    }
                    SelRectMode.NONE -> {}
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                when (selRectMode) {
                    SelRectMode.DEFINE -> {
                        // Clear the front-buffer preview rectangle.
                        r.commit()
                        // Lift the rect — native handles the empty-rect case.
                        NativeRenderer.beginRasterSelection(
                            selRectPreviewX0, selRectPreviewY0,
                            selRectPreviewX1, selRectPreviewY1
                        )
                        forceRedraw()
                    }
                    SelRectMode.TRANSLATE -> {
                        // Stay floating; user can drag again or tap
                        // outside to commit.
                    }
                    SelRectMode.NONE -> {}
                }
                selRectMode = SelRectMode.NONE
            }
        }
        return true
    }

    /** Bucket tool: tap-to-fill. The native fill needs a current GL
     *  context (it runs a full-page composite, glReadPixels, etc.), and
     *  no GL context is current on the UI thread — so we just stash the
     *  request and trigger a multi-buffer pass. The pass's GL-thread
     *  callback (onDrawMultiBufferedLayer) actually runs the fill. */
    private fun handleBucketEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_DOWN) {
            viewToDoc(event.x, event.y, tmpDoc)
            pendingBucketFill = PendingBucketFill(tmpDoc[0], tmpDoc[1])
            forceRedraw()
        }
        return true
    }

    private data class PendingBucketFill(val x: Float, val y: Float)
    // Single volatile reference packages both coords + request flag — UI
    // thread writes a fully-constructed object, GL thread reads it whole.
    @Volatile
    private var pendingBucketFill: PendingBucketFill? = null

    // Drag state for the SELECT tool.
    private var selectMode = 0          // 0=none, 1=move, 2=scale, 3=rotate
    private var selectChanged = false   // true if we should persist on UP

    private fun handleSelectEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                viewToDoc(event.x, event.y, tmpDoc)
                selectMode = NativeRenderer.beginInteractionAt(tmpDoc[0], tmpDoc[1])
                selectChanged = false
                forceRedraw()
            }
            MotionEvent.ACTION_MOVE -> {
                viewToDoc(event.x, event.y, tmpDoc)
                when (selectMode) {
                    1 -> { // move — snap-aware absolute, native uses captured offset
                        NativeRenderer.moveSelectionTo(tmpDoc[0], tmpDoc[1])
                        selectChanged = true
                        forceRedraw()
                    }
                    2, 3 -> { // scale / rotate — absolute pen position
                        NativeRenderer.updateInteractionAt(tmpDoc[0], tmpDoc[1])
                        selectChanged = true
                        forceRedraw()
                    }
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                NativeRenderer.endInteraction()
                if (selectChanged) {
                    NativeRenderer.persistActiveVectorLayer()
                }
                selectMode = 0
                selectChanged = false
            }
        }
        return true
    }

    private fun handleStrokeEvent(
        r: GLFrontBufferedRenderer<StrokeAction>,
        event: MotionEvent
    ): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                viewToDoc(event.x, event.y, tmpDoc)
                r.renderFrontBufferedLayer(
                    StrokeAction.Sample(tmpDoc[0], tmpDoc[1], event.pressure,
                                        isNewStroke = true)
                )
            }
            MotionEvent.ACTION_MOVE -> {
                for (i in 0 until event.historySize) {
                    viewToDoc(event.getHistoricalX(i), event.getHistoricalY(i), tmpDoc)
                    r.renderFrontBufferedLayer(
                        StrokeAction.Sample(
                            tmpDoc[0], tmpDoc[1],
                            event.getHistoricalPressure(i),
                            isNewStroke = false
                        )
                    )
                }
                viewToDoc(event.x, event.y, tmpDoc)
                r.renderFrontBufferedLayer(
                    StrokeAction.Sample(tmpDoc[0], tmpDoc[1], event.pressure,
                                        isNewStroke = false)
                )
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                r.commit()
            }
        }
        return true
    }

    // Reused output buffer for NativeRenderer.snapPoint — avoids
    // allocating a fresh FloatArray per pen sample.
    private val snapOut = FloatArray(3)
    private var p1Snapped = false

    /** Snap the given doc-space point to the nearest snap target if any.
     *  Updates p1Snapped as a side effect. Inputs and outputs are doc-px. */
    private fun snap(x: Float, y: Float): Pair<Float, Float> {
        NativeRenderer.snapPoint(x, y, snapOut)
        p1Snapped = snapOut[2] > 0.5f
        return if (p1Snapped) Pair(snapOut[0], snapOut[1]) else Pair(x, y)
    }

    private fun handleShapeEvent(
        r: GLFrontBufferedRenderer<StrokeAction>,
        event: MotionEvent,
        shapeType: Int
    ): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                viewToDoc(event.x, event.y, tmpDoc)
                val (sx, sy) = snap(tmpDoc[0], tmpDoc[1])
                shapeP0X = sx; shapeP0Y = sy
                shapeP1X = sx; shapeP1Y = sy
                r.renderFrontBufferedLayer(
                    StrokeAction.ShapePreview(shapeType,
                        shapeP0X, shapeP0Y, shapeP1X, shapeP1Y, p1Snapped)
                )
            }
            MotionEvent.ACTION_MOVE -> {
                viewToDoc(event.x, event.y, tmpDoc)
                val (sx, sy) = snap(tmpDoc[0], tmpDoc[1])
                shapeP1X = sx; shapeP1Y = sy
                r.renderFrontBufferedLayer(
                    StrokeAction.ShapePreview(shapeType,
                        shapeP0X, shapeP0Y, shapeP1X, shapeP1Y, p1Snapped)
                )
            }
            MotionEvent.ACTION_UP -> {
                when (shapeType) {
                    0 -> NativeRenderer.addLine     (shapeP0X, shapeP0Y, shapeP1X, shapeP1Y)
                    1 -> NativeRenderer.addRectangle(shapeP0X, shapeP0Y, shapeP1X, shapeP1Y)
                    2 -> NativeRenderer.addCircle   (shapeP0X, shapeP0Y, shapeP1X, shapeP1Y)
                    3 -> NativeRenderer.addEllipse  (shapeP0X, shapeP0Y, shapeP1X, shapeP1Y)
                }
                // commit() clears the front buffer preview and triggers a
                // multi-buffer redraw via onDrawMultiBufferedLayer, which
                // applies the queued shape and re-renders the document.
                r.commit()
                p1Snapped = false
            }
            MotionEvent.ACTION_CANCEL -> {
                r.commit()
                p1Snapped = false
            }
        }
        return true
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        // First time we know the surface size, kick a multi-buffer pass so
        // the saved document loads and shows immediately on app launch
        // (rather than only appearing after the first stroke commit).
        if (oldw == 0 && oldh == 0 && w > 0 && h > 0) {
            // Page-boundary rectangle defaults to the initial visible
            // viewport — what the user sees as "the page" at startup.
            NativeRenderer.setPageBounds(0f, 0f, w.toFloat(), h.toFloat())
            renderer?.commit()
        }
    }

    /** Force a multi-buffer redraw (used after layer-state changes that
     *  need to be reflected on screen, e.g. clearing a layer). */
    fun forceRedraw() {
        renderer?.commit()
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
