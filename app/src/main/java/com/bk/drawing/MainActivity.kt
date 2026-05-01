package com.bk.drawing

import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat

class MainActivity : AppCompatActivity() {

    private var drawingView: DrawingSurfaceView? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, window.decorView).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }

        drawingView = DrawingSurfaceView(this).also { setContentView(it) }

        // Opt into the highest refresh rate the panel offers (90 Hz on MovinkPad 11).
        val highest = display?.supportedModes?.maxByOrNull { it.refreshRate }
        if (highest != null) {
            val attrs = window.attributes
            attrs.preferredDisplayModeId = highest.modeId
            window.attributes = attrs
        }
    }

    override fun onDestroy() {
        drawingView?.release()
        drawingView = null
        super.onDestroy()
    }
}
