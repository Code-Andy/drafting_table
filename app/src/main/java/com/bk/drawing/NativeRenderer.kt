package com.bk.drawing

object NativeRenderer {
    init { System.loadLibrary("drawing") }

    /**
     * Configure where on disk the document is persisted. Tiles are read from
     * and written to `<dir>/tile_<tx>_<ty>.bin`. Call before any draw work;
     * loading happens lazily on the first GL operation.
     */
    external fun setDocumentDir(path: String)

    /** Reset emitter state and start a new in-progress stroke. */
    external fun beginStroke()

    /**
     * Append a sample to the current stroke and emit any new dabs needed to
     * reach (x, y), additively, into the bound (front-buffered) layer.
     */
    external fun extendStroke(
        width: Int, height: Int,
        transform: FloatArray,
        x: Float, y: Float, pressure: Float
    )

    /**
     * Bake the in-progress stroke into the tiles its bbox touches, then drop
     * the stroke samples. The tiles ARE the document state from now on.
     */
    external fun commitStroke()

    /**
     * Clear the bound (multi-buffered) layer to white and composite every
     * allocated tile onto it.
     */
    external fun renderDocument(
        width: Int, height: Int,
        transform: FloatArray
    )

    /**
     * Append a new (empty) layer above the current top, and switch the
     * active layer to it. Safe to call from any thread; the action is
     * applied on the GL thread at the start of the next operation.
     */
    external fun addLayer()

    /**
     * Move the active-layer pointer to the next layer, wrapping. Safe to
     * call from any thread.
     */
    external fun cycleActiveLayer()

    /**
     * Delete every tile in the active layer (GL textures + on-disk files).
     * For a vector layer, drops every shape and rewrites the empty marker.
     * Safe to call from any thread.
     */
    external fun clearActiveLayer()

    /**
     * Append a new (empty) vector layer above the current top, switch the
     * active layer to it. Vector layers hold parametric shapes (lines for
     * now; circles/rects later) instead of a tile grid.
     */
    external fun addVectorLayer()

    /**
     * Append shapes to the active layer (only effective if the active
     * layer is a vector layer). Color and width follow the current brush
     * color and a fixed line width. Each gesture's (x0, y0, x1, y1)
     * interpretation:
     *   addLine:      endpoints
     *   addRectangle: opposite bbox corners
     *   addEllipse:   opposite bbox corners (oval inscribed)
     *   addCircle:    p0 = center, p1 = point on circle
     * Safe to call from any thread; takes effect on the next render.
     */
    external fun addLine     (x0: Float, y0: Float, x1: Float, y1: Float)
    external fun addRectangle(x0: Float, y0: Float, x1: Float, y1: Float)
    external fun addEllipse  (x0: Float, y0: Float, x1: Float, y1: Float)
    external fun addCircle   (x0: Float, y0: Float, x1: Float, y1: Float)

    /**
     * Live preview for the shape tools. shapeType:
     *   0 = line, 1 = rectangle, 2 = circle, 3 = ellipse
     * Renders into the currently-bound framebuffer (intended to be the
     * front-buffered layer, called from inside onDrawFrontBufferedLayer).
     * Clears the buffer first so successive previews replace rather than
     * accumulate.
     */
    external fun renderShapePreview(
        width: Int, height: Int,
        transform: FloatArray,
        shapeType: Int,
        x0: Float, y0: Float, x1: Float, y1: Float,
        snapped: Boolean
    )

    /**
     * Find the nearest snap target to (x, y) within the snap radius.
     * Fills output[0..2] with [snapX, snapY, didSnap (1.0/0.0)]. Output
     * is overwritten in place; pre-allocate one FloatArray(3) and reuse.
     * Snap targets are vector-shape vertices/centers and (when grid is
     * on) grid intersections. No-op + didSnap=0 if snap is disabled.
     */
    external fun snapPoint(x: Float, y: Float, output: FloatArray)

    /** Toggle whether snapping is active. Default on. */
    external fun setSnapEnabled(enabled: Boolean)

    /**
     * Selection helpers — operate on the active vector layer.
     *
     *  selectShapeAt(x, y): hit-test, set selection on hit, returns true
     *     on hit; on miss clears any prior selection and returns false.
     *  hasSelection: whether anything is currently selected.
     *  clearSelection: drop the current selection.
     *  translateSelection: move the selected shape by (dx, dy) doc px.
     *  moveSelectionTo:    snap-aware absolute move; drives an in-progress
     *     Move drag using the captured pen-to-center offset.
     *  deleteSelection: remove the selected shape from its layer.
     *  persistActiveVectorLayer: write shapes.bin for the active layer
     *     (used after a transform drag completes).
     *
     * All are safe to call from any thread.
     */
    external fun selectShapeAt(x: Float, y: Float): Boolean
    external fun hasSelection(): Boolean
    external fun clearSelection()
    external fun translateSelection(dx: Float, dy: Float)
    external fun moveSelectionTo(x: Float, y: Float)
    external fun deleteSelection()
    external fun persistActiveVectorLayer()

    /**
     * Begin a SELECT-tool interaction at (x, y). Returns the drag mode:
     *   0 = none (tap missed everything; selection cleared if there was one)
     *   1 = move  (drive moveSelectionTo with absolute pen pos; native
     *              uses the offset captured here so the grab-point follows)
     *   2 = scale (drive updateInteractionAt with absolute pen pos)
     *   3 = rotate (drive updateInteractionAt with absolute pen pos)
     */
    external fun beginInteractionAt(x: Float, y: Float): Int

    /** Drive an in-progress scale, rotate, or move interaction to (x, y).
     *  No-op if no interaction is active. (For Move, prefer the dedicated
     *  moveSelectionTo entry point — both go through the same path.) */
    external fun updateInteractionAt(x: Float, y: Float)

    /** Mark the current interaction complete. */
    external fun endInteraction()

    /**
     * Set the active drawing tool: 0 = brush, 1 = eraser. The next stroke
     * (i.e. the next beginStroke) snapshots this value, so toggling
     * mid-stroke doesn't split a stroke. Safe to call from any thread.
     */
    external fun setTool(tool: Int)

    /**
     * Set the brush RGB color (alpha is fixed). `rgb` is 0xRRGGBB; any
     * upper bits are ignored. Snapshotted at the next beginStroke. Safe
     * to call from any thread.
     */
    external fun setBrushColor(rgb: Int)

    /**
     * Page-background grid controls. Read at multi-buffer composite time;
     * call forceRedraw() afterward to make a change appear immediately.
     */
    external fun setGridEnabled(enabled: Boolean)
    external fun setGridStyle(style: Int)   // 1 = lines, 2 = dots

    /**
     * Layer-state read accessors for UI display. Values may lag queued
     * addLayer/cycleActiveLayer calls by up to one stroke/render; that's
     * fine for status text.
     */
    external fun getLayerCount(): Int
    external fun getActiveLayer(): Int
}
