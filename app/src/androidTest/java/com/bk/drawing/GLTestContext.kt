package com.bk.drawing

import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.os.Handler
import android.os.HandlerThread
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicReference

/**
 * Offscreen EGL 3.x context on a dedicated thread. Created once per
 * test, every NativeRenderer call is dispatched onto this thread so
 * the GL context stays current. Tests don't need a SurfaceView, the
 * pbuffer is a stand-in render target — we never actually present it.
 *
 * Use [run] to execute a block synchronously on the GL thread and
 * propagate exceptions back to the caller. The renderer can be
 * driven from inside the block as if it were on the production GL
 * thread.
 */
class GLTestContext private constructor(
    private val thread: HandlerThread,
    private val handler: Handler,
    private val display: EGLDisplay,
    private val context: EGLContext,
    private val surface: EGLSurface,
) {
    /** Run [block] synchronously on the GL thread. Re-throws any
     *  exception that block raises so tests fail with the right
     *  stack trace. */
    fun <T> run(block: () -> T): T {
        val result = AtomicReference<T>()
        val error  = AtomicReference<Throwable>()
        val latch  = CountDownLatch(1)
        handler.post {
            try { result.set(block()) }
            catch (t: Throwable) { error.set(t) }
            finally { latch.countDown() }
        }
        latch.await()
        error.get()?.let { throw it }
        return result.get()
    }

    /** Tear down EGL state and stop the worker thread. Safe to call
     *  more than once — subsequent calls are no-ops. */
    fun shutdown() {
        if (!thread.isAlive) return
        run {
            EGL14.eglMakeCurrent(display,
                EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE,
                EGL14.EGL_NO_CONTEXT)
            EGL14.eglDestroySurface(display, surface)
            EGL14.eglDestroyContext(display, context)
            EGL14.eglTerminate(display)
        }
        thread.quitSafely()
        thread.join()
    }

    companion object {
        // EGL_OPENGL_ES3_BIT_KHR — not exposed by android.opengl.EGL14,
        // pass the value directly.
        private const val EGL_OPENGL_ES3_BIT_KHR = 0x40

        // One GL context per test process. Recreating per-test would
        // strand the native renderer's tile FBO / texture handles
        // (g_pages survives across tests) in a destroyed context,
        // leaving stale GL IDs that the next test would use as UB.
        // Sharing the context means tests must reset native state
        // explicitly between cases — see RendererTestBase.
        private var shared: GLTestContext? = null

        @Synchronized
        fun shared(): GLTestContext {
            return shared ?: create().also { shared = it }
        }

        fun create(): GLTestContext {
            val t = HandlerThread("renderer-test-gl")
            t.start()
            val h = Handler(t.looper)

            val dRef = AtomicReference<EGLDisplay>()
            val cRef = AtomicReference<EGLContext>()
            val sRef = AtomicReference<EGLSurface>()
            val err  = AtomicReference<Throwable>()
            val latch = CountDownLatch(1)

            h.post {
                try {
                    val d = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
                    require(d != EGL14.EGL_NO_DISPLAY) { "no EGL display" }
                    val ver = IntArray(2)
                    require(EGL14.eglInitialize(d, ver, 0, ver, 1)) { "eglInitialize failed" }

                    val cfgAttrs = intArrayOf(
                        EGL14.EGL_RED_SIZE,       8,
                        EGL14.EGL_GREEN_SIZE,     8,
                        EGL14.EGL_BLUE_SIZE,      8,
                        EGL14.EGL_ALPHA_SIZE,     8,
                        EGL14.EGL_SURFACE_TYPE,   EGL14.EGL_PBUFFER_BIT,
                        EGL14.EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR,
                        EGL14.EGL_NONE
                    )
                    val configs = arrayOfNulls<EGLConfig>(1)
                    val n = IntArray(1)
                    require(
                        EGL14.eglChooseConfig(d, cfgAttrs, 0, configs, 0, 1, n, 0)
                            && n[0] > 0
                    ) { "no matching EGL config" }
                    val cfg = configs[0]!!

                    val ctxAttrs = intArrayOf(
                        EGL14.EGL_CONTEXT_CLIENT_VERSION, 3,
                        EGL14.EGL_NONE
                    )
                    val c = EGL14.eglCreateContext(d, cfg, EGL14.EGL_NO_CONTEXT, ctxAttrs, 0)
                    require(c != EGL14.EGL_NO_CONTEXT) { "eglCreateContext failed" }

                    val surfAttrs = intArrayOf(
                        EGL14.EGL_WIDTH,  16,
                        EGL14.EGL_HEIGHT, 16,
                        EGL14.EGL_NONE
                    )
                    val s = EGL14.eglCreatePbufferSurface(d, cfg, surfAttrs, 0)
                    require(s != EGL14.EGL_NO_SURFACE) { "eglCreatePbufferSurface failed" }

                    require(EGL14.eglMakeCurrent(d, s, s, c)) { "eglMakeCurrent failed" }

                    dRef.set(d); cRef.set(c); sRef.set(s)
                } catch (t: Throwable) {
                    err.set(t)
                } finally {
                    latch.countDown()
                }
            }
            latch.await()
            err.get()?.let { throw it }

            return GLTestContext(t, h, dRef.get(), cRef.get(), sRef.get())
        }
    }
}
