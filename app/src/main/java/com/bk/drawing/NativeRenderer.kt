package com.bk.drawing

object NativeRenderer {
    init { System.loadLibrary("drawing") }

    /** Append a single dab at (x, y) on top of whatever is already in the front buffer. */
    external fun drawFrontDot(
        width: Int, height: Int,
        transform: FloatArray,
        x: Float, y: Float, pressure: Float
    )

    /** Clear and render every committed dab. xyp is a flat [x0, y0, p0, x1, y1, p1, ...] array. */
    external fun drawAllDots(
        width: Int, height: Int,
        transform: FloatArray,
        xyp: FloatArray, count: Int
    )
}
