// Spike 1 renderer: draws a single pressure-scaled dot per input sample.
//
// Three entry points called from Kotlin:
//   drawFrontDot — additive, no clear. Called once per pen sample.
//   drawAllDots  — clears the framebuffer, redraws every committed dot.
//
// Coordinate handling: pen positions arrive in pixel space matching the
// callback's (width, height). We project pixel → NDC manually in the shader,
// then pre-multiply by the `transform` matrix that GLFrontBufferedRenderer
// supplies. That matrix is an NDC→NDC rotation correcting for any difference
// between the view's orientation and the underlying buffer's orientation.
//
// Both entry points run inside an EGL context owned by
// GLFrontBufferedRenderer, on its dedicated render thread.

#include <jni.h>
#include <GLES3/gl3.h>
#include <android/log.h>
#include <cmath>
#include <vector>

#define LOG_TAG "DrawingApp"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

constexpr int kCircleSegments = 32;

const char* kVertexShader = R"(#version 300 es
layout(location = 0) in vec2 aUnit;       // unit-circle vertex (-1..1)
uniform mat4  uTransform;                 // view-pixel -> buffer-pixel
uniform vec2  uScreen;                    // buffer-pixel size
uniform vec2  uCenter;                    // pen center in view-pixel coords
uniform float uRadius;                    // dot radius in pixels
void main() {
    vec2 viewPx = uCenter + aUnit * uRadius;
    vec4 bufPx  = uTransform * vec4(viewPx, 0.0, 1.0);
    // Direct buffer-pixel -> NDC. We don't y-flip here: the buffer is rotated
    // 90° relative to the display, so buffer's y axis becomes display's x and
    // vice versa. The standard "y is up in NDC" flip would mirror display x.
    vec2 ndc = vec2(
        (bufPx.x / uScreen.x) * 2.0 - 1.0,
        (bufPx.y / uScreen.y) * 2.0 - 1.0
    );
    gl_Position = vec4(ndc, 0.0, 1.0);
}
)";

const char* kFragShader = R"(#version 300 es
precision mediump float;
out vec4 outColor;
void main() {
    outColor = vec4(0.08, 0.08, 0.08, 1.0);
}
)";

struct Gl {
    GLuint program    = 0;
    GLuint vao        = 0;
    GLuint vbo        = 0;
    GLint  uTransform = -1;
    GLint  uScreen    = -1;
    GLint  uCenter    = -1;
    GLint  uRadius    = -1;
    bool   inited     = false;
};
Gl g;

GLuint compile(GLenum type, const char* src) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, nullptr);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[1024];
        glGetShaderInfoLog(s, sizeof(log), nullptr, log);
        LOGE("shader compile failed: %s", log);
    }
    return s;
}

void ensureInited() {
    if (g.inited) return;

    GLuint vs = compile(GL_VERTEX_SHADER,   kVertexShader);
    GLuint fs = compile(GL_FRAGMENT_SHADER, kFragShader);
    g.program = glCreateProgram();
    glAttachShader(g.program, vs);
    glAttachShader(g.program, fs);
    glLinkProgram(g.program);
    GLint ok = 0;
    glGetProgramiv(g.program, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[1024];
        glGetProgramInfoLog(g.program, sizeof(log), nullptr, log);
        LOGE("program link failed: %s", log);
    }
    glDeleteShader(vs);
    glDeleteShader(fs);

    g.uTransform = glGetUniformLocation(g.program, "uTransform");
    g.uScreen    = glGetUniformLocation(g.program, "uScreen");
    g.uCenter    = glGetUniformLocation(g.program, "uCenter");
    g.uRadius    = glGetUniformLocation(g.program, "uRadius");

    // Triangle fan: center vertex plus a ring of unit-circle vertices.
    std::vector<float> verts;
    verts.reserve((kCircleSegments + 2) * 2);
    verts.push_back(0.0f); verts.push_back(0.0f);
    for (int i = 0; i <= kCircleSegments; ++i) {
        float t = (float)i / (float)kCircleSegments * 2.0f * 3.14159265358979f;
        verts.push_back(std::cos(t));
        verts.push_back(std::sin(t));
    }

    glGenVertexArrays(1, &g.vao);
    glGenBuffers(1, &g.vbo);
    glBindVertexArray(g.vao);
    glBindBuffer(GL_ARRAY_BUFFER, g.vbo);
    glBufferData(GL_ARRAY_BUFFER,
                 verts.size() * sizeof(float),
                 verts.data(),
                 GL_STATIC_DRAW);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 2 * sizeof(float), nullptr);
    glEnableVertexAttribArray(0);
    glBindVertexArray(0);

    g.inited = true;
    LOGI("renderer initialized");
}

void uploadTransform(JNIEnv* env, jfloatArray transform) {
    jfloat* arr = env->GetFloatArrayElements(transform, nullptr);
    glUniformMatrix4fv(g.uTransform, 1, GL_FALSE, arr);
    env->ReleaseFloatArrayElements(transform, arr, JNI_ABORT);
}

void drawDot(float x, float y, float pressure) {
    glBindVertexArray(g.vao);
    glUniform2f(g.uCenter, x, y);
    // Pressure is 0..1 from MotionEvent. Map to a visible 4..28 px radius.
    float radius = 4.0f + pressure * 24.0f;
    glUniform1f(g.uRadius, radius);
    glDrawArrays(GL_TRIANGLE_FAN, 0, kCircleSegments + 2);
    glBindVertexArray(0);
}

}  // namespace

extern "C" {

JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_drawFrontDot(
        JNIEnv* env, jobject,
        jint width, jint height,
        jfloatArray transform,
        jfloat x, jfloat y, jfloat pressure) {
    ensureInited();
    glViewport(0, 0, width, height);
    glUseProgram(g.program);
    uploadTransform(env, transform);
    glUniform2f(g.uScreen, (float)width, (float)height);
    // No clear — front buffer accumulates dabs until commit().
    drawDot(x, y, pressure);
}

JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_drawAllDots(
        JNIEnv* env, jobject,
        jint width, jint height,
        jfloatArray transform,
        jfloatArray xyp, jint count) {
    ensureInited();
    glViewport(0, 0, width, height);
    glClearColor(1.0f, 1.0f, 1.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    if (count <= 0 || xyp == nullptr) return;

    glUseProgram(g.program);
    uploadTransform(env, transform);
    glUniform2f(g.uScreen, (float)width, (float)height);

    jfloat* arr = env->GetFloatArrayElements(xyp, nullptr);
    for (int i = 0; i < count; ++i) {
        float x = arr[i * 3 + 0];
        float y = arr[i * 3 + 1];
        float p = arr[i * 3 + 2];
        drawDot(x, y, p);
    }
    env->ReleaseFloatArrayElements(xyp, arr, JNI_ABORT);
}

}  // extern "C"
