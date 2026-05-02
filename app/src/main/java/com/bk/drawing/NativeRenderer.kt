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
     * The layer itself remains; its tile map is just emptied. Safe to
     * call from any thread.
     */
    external fun clearActiveLayer()

    /**
     * Set the active drawing tool: 0 = brush, 1 = eraser. The next stroke
     * (i.e. the next beginStroke) snapshots this value, so toggling
     * mid-stroke doesn't split a stroke. Safe to call from any thread.
     */
    external fun setTool(tool: Int)

    /**
     * Layer-state read accessors for UI display. Values may lag queued
     * addLayer/cycleActiveLayer calls by up to one stroke/render; that's
     * fine for status text.
     */
    external fun getLayerCount(): Int
    external fun getActiveLayer(): Int
}
