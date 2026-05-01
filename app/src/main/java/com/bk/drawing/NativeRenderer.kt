package com.bk.drawing

object NativeRenderer {
    init { System.loadLibrary("drawing") }

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
}
