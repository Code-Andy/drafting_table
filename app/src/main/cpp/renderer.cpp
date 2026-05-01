// Tile-based document renderer.
//
// Document model:
//   - Document is an infinite 2D plane in floating-point coordinates
//     (origin top-left, y-down — same convention as MotionEvent).
//   - Storage is a sparse grid of 256x256 RGBA tiles. Tiles are allocated
//     lazily when a stroke first touches them and cleared to white.
//   - Each tile is a GL texture + FBO; dabs blend onto the white background
//     so tile alpha stays implicitly 1 throughout (revisit when adding
//     layers — we'll switch to premultiplied alpha + transparent clear).
//
// Stroke lifecycle:
//   beginStroke      - reset emitter, clear in-progress sample list
//   extendStroke     - append a sample, emit new dabs additively into the
//                      currently-bound (front-buffered) layer
//   commitStroke     - bake the in-progress stroke into the tiles its
//                      bbox touches, then drop the samples
//   renderDocument   - clear the bound (multi-buffered) layer to white and
//                      composite every tile onto it
//
// All entry points run on the GLFrontBufferedRenderer's render thread, so
// no locking is needed for any of the C++-side state.

#include <jni.h>
#include <GLES3/gl3.h>
#include <android/log.h>
#include <cmath>
#include <cstdint>
#include <unordered_map>
#include <vector>

#define LOG_TAG "DrawingApp"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

// ---- Tunables -------------------------------------------------------------

constexpr int   kTileSize  = 256;
constexpr float kTileSizeF = 256.0f;
constexpr float kTileHalfF = 128.0f;

constexpr float kSpacing   = 0.18f;
constexpr float kMinRadius = 2.0f;
constexpr float kMaxRadius = 18.0f;
constexpr float kColor[4]  = { 0.08f, 0.09f, 0.12f, 0.85f };

constexpr float kIdentity[16] = {
    1, 0, 0, 0,
    0, 1, 0, 0,
    0, 0, 1, 0,
    0, 0, 0, 1,
};

// ---- Shaders --------------------------------------------------------------

const char* kDabVS = R"(#version 300 es
layout(location = 0) in vec2 aQuad;
out vec2 vUv;
uniform mat4  uTransform;
uniform vec2  uScreen;
uniform vec2  uCenter;
uniform float uRadius;
void main() {
    vUv = aQuad;
    vec2 viewPx = uCenter + aQuad * uRadius;
    vec4 bufPx  = uTransform * vec4(viewPx, 0.0, 1.0);
    vec2 ndc = (bufPx.xy / uScreen) * 2.0 - 1.0;
    gl_Position = vec4(ndc, 0.0, 1.0);
}
)";

const char* kDabFS = R"(#version 300 es
precision mediump float;
in vec2 vUv;
out vec4 outColor;
uniform vec4 uColor;
void main() {
    float r = length(vUv);
    if (r > 1.0) discard;
    float a = 1.0 - smoothstep(0.55, 1.0, r);
    outColor = vec4(uColor.rgb, uColor.a * a);
}
)";

const char* kCompVS = R"(#version 300 es
layout(location = 0) in vec2 aQuad;
out vec2 vUv;
uniform mat4  uTransform;
uniform vec2  uScreen;
uniform vec2  uTileCenter;
uniform float uTileHalf;
void main() {
    vec2 viewPx = uTileCenter + aQuad * uTileHalf;
    vec4 bufPx  = uTransform * vec4(viewPx, 0.0, 1.0);
    vec2 ndc = (bufPx.xy / uScreen) * 2.0 - 1.0;
    gl_Position = vec4(ndc, 0.0, 1.0);
    vUv = aQuad * 0.5 + 0.5;
}
)";

const char* kCompFS = R"(#version 300 es
precision mediump float;
in vec2 vUv;
out vec4 outColor;
uniform sampler2D uTileTex;
void main() {
    // Tile rgb is already paper+ink composited; force alpha=1 so the
    // multi-buffer ends up fully opaque.
    outColor = vec4(texture(uTileTex, vUv).rgb, 1.0);
}
)";

// ---- State ----------------------------------------------------------------

struct Sample { float x, y, p; };
struct Stroke { std::vector<Sample> samples; };

struct DabProg {
    GLuint program    = 0;
    GLint  uTransform = -1;
    GLint  uScreen    = -1;
    GLint  uCenter    = -1;
    GLint  uRadius    = -1;
    GLint  uColor     = -1;
};

struct CompProg {
    GLuint program     = 0;
    GLint  uTransform  = -1;
    GLint  uScreen     = -1;
    GLint  uTileCenter = -1;
    GLint  uTileHalf   = -1;
    GLint  uTileTex    = -1;
};

struct Tile {
    GLuint texture = 0;
    GLuint fbo     = 0;
};

DabProg  g_dab;
CompProg g_comp;
GLuint   g_quadVao = 0;
GLuint   g_quadVbo = 0;
bool     g_inited  = false;

std::unordered_map<int64_t, Tile> g_tiles;

Stroke g_current;

inline int64_t tileKey(int tx, int ty) {
    uint32_t ux = static_cast<uint32_t>(tx);
    uint32_t uy = static_cast<uint32_t>(ty);
    return static_cast<int64_t>(static_cast<uint64_t>(ux) |
                                (static_cast<uint64_t>(uy) << 32));
}

inline void unpackTileKey(int64_t k, int& tx, int& ty) {
    uint64_t uk = static_cast<uint64_t>(k);
    tx = static_cast<int32_t>(static_cast<uint32_t>(uk & 0xFFFFFFFFu));
    ty = static_cast<int32_t>(static_cast<uint32_t>(uk >> 32));
}

inline float clamp01(float v) { return v < 0 ? 0 : (v > 1 ? 1 : v); }

inline float radiusOf(float pressure) {
    return kMinRadius + clamp01(pressure) * (kMaxRadius - kMinRadius);
}

// ---- Drawing primitive ----------------------------------------------------
// Caller is responsible for binding the dab program and VAO and setting
// uTransform / uScreen / uColor. drawDab only sets per-dab uniforms.

void drawDab(float x, float y, float radius) {
    glUniform2f(g_dab.uCenter, x, y);
    glUniform1f(g_dab.uRadius, radius);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

// ---- DabEmitter: spaces dabs along an incoming sample stream -------------

struct DabEmitter {
    bool  active        = false;
    float lastX         = 0.0f;
    float lastY         = 0.0f;
    float lastP         = 0.0f;
    float distToNextDab = 0.0f;

    void reset() {
        active = false;
        distToNextDab = 0.0f;
    }

    void extend(float x, float y, float p) {
        if (!active) {
            drawDab(x, y, radiusOf(p));
            active = true;
            lastX = x; lastY = y; lastP = p;
            distToNextDab = kSpacing * radiusOf(p);
            return;
        }
        float dx = x - lastX, dy = y - lastY;
        float dist = std::sqrt(dx * dx + dy * dy);
        if (dist < 1e-4f) return;
        float ux = dx / dist, uy = dy / dist;

        float traveled = 0.0f;
        while (traveled + distToNextDab <= dist) {
            traveled += distToNextDab;
            float t    = traveled / dist;
            float dabX = lastX + ux * traveled;
            float dabY = lastY + uy * traveled;
            float dabP = lastP + (p - lastP) * t;
            drawDab(dabX, dabY, radiusOf(dabP));
            distToNextDab = kSpacing * radiusOf(dabP);
        }
        distToNextDab -= (dist - traveled);
        lastX = x; lastY = y; lastP = p;
    }
};

DabEmitter g_liveEmitter;

// ---- Shader / program helpers --------------------------------------------

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

GLuint linkProgram(const char* vs, const char* fs) {
    GLuint v = compile(GL_VERTEX_SHADER,   vs);
    GLuint f = compile(GL_FRAGMENT_SHADER, fs);
    GLuint p = glCreateProgram();
    glAttachShader(p, v);
    glAttachShader(p, f);
    glLinkProgram(p);
    GLint ok = 0;
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[1024];
        glGetProgramInfoLog(p, sizeof(log), nullptr, log);
        LOGE("program link failed: %s", log);
    }
    glDeleteShader(v);
    glDeleteShader(f);
    return p;
}

void ensureInited() {
    if (g_inited) return;

    g_dab.program    = linkProgram(kDabVS, kDabFS);
    g_dab.uTransform = glGetUniformLocation(g_dab.program, "uTransform");
    g_dab.uScreen    = glGetUniformLocation(g_dab.program, "uScreen");
    g_dab.uCenter    = glGetUniformLocation(g_dab.program, "uCenter");
    g_dab.uRadius    = glGetUniformLocation(g_dab.program, "uRadius");
    g_dab.uColor     = glGetUniformLocation(g_dab.program, "uColor");

    g_comp.program     = linkProgram(kCompVS, kCompFS);
    g_comp.uTransform  = glGetUniformLocation(g_comp.program, "uTransform");
    g_comp.uScreen     = glGetUniformLocation(g_comp.program, "uScreen");
    g_comp.uTileCenter = glGetUniformLocation(g_comp.program, "uTileCenter");
    g_comp.uTileHalf   = glGetUniformLocation(g_comp.program, "uTileHalf");
    g_comp.uTileTex    = glGetUniformLocation(g_comp.program, "uTileTex");

    const float verts[] = {
        -1.0f, -1.0f,
         1.0f, -1.0f,
        -1.0f,  1.0f,
         1.0f,  1.0f,
    };
    glGenVertexArrays(1, &g_quadVao);
    glGenBuffers(1, &g_quadVbo);
    glBindVertexArray(g_quadVao);
    glBindBuffer(GL_ARRAY_BUFFER, g_quadVbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(verts), verts, GL_STATIC_DRAW);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 2 * sizeof(float), nullptr);
    glEnableVertexAttribArray(0);
    glBindVertexArray(0);

    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

    g_inited = true;
    LOGI("renderer initialized");
}

void uploadMat4(JNIEnv* env, GLint loc, jfloatArray transform) {
    jfloat* arr = env->GetFloatArrayElements(transform, nullptr);
    glUniformMatrix4fv(loc, 1, GL_FALSE, arr);
    env->ReleaseFloatArrayElements(transform, arr, JNI_ABORT);
}

// ---- Tile management ------------------------------------------------------

Tile& getOrCreateTile(int tx, int ty) {
    int64_t k = tileKey(tx, ty);
    auto it = g_tiles.find(k);
    if (it != g_tiles.end()) return it->second;

    Tile t;
    glGenTextures(1, &t.texture);
    glBindTexture(GL_TEXTURE_2D, t.texture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, kTileSize, kTileSize, 0,
                 GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    glGenFramebuffers(1, &t.fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, t.fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                           GL_TEXTURE_2D, t.texture, 0);
    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        LOGE("tile (%d, %d) FBO incomplete: 0x%x", tx, ty, status);
    }

    glViewport(0, 0, kTileSize, kTileSize);
    glClearColor(1.0f, 1.0f, 1.0f, 1.0f);   // paper white
    glClear(GL_COLOR_BUFFER_BIT);

    g_tiles[k] = t;
    return g_tiles[k];
}

// ---- Bake -----------------------------------------------------------------
// Re-render the in-progress stroke's dabs into every tile its bbox touches.
// Caller restores the previously bound framebuffer afterward.

void bakeCurrentStrokeIntoTiles() {
    if (g_current.samples.empty()) return;

    // bbox in document space, padded by max radius so a dab sitting right
    // on a tile boundary affects the neighboring tile too.
    float pad = kMaxRadius;
    float minX = g_current.samples.front().x, maxX = minX;
    float minY = g_current.samples.front().y, maxY = minY;
    for (const auto& s : g_current.samples) {
        if (s.x < minX) minX = s.x;
        if (s.x > maxX) maxX = s.x;
        if (s.y < minY) minY = s.y;
        if (s.y > maxY) maxY = s.y;
    }
    minX -= pad; maxX += pad;
    minY -= pad; maxY += pad;

    int tx0 = static_cast<int>(std::floor(minX / kTileSizeF));
    int tx1 = static_cast<int>(std::floor(maxX / kTileSizeF));
    int ty0 = static_cast<int>(std::floor(minY / kTileSizeF));
    int ty1 = static_cast<int>(std::floor(maxY / kTileSizeF));

    glUseProgram(g_dab.program);
    glBindVertexArray(g_quadVao);
    glUniformMatrix4fv(g_dab.uTransform, 1, GL_FALSE, kIdentity);
    glUniform2f(g_dab.uScreen, kTileSizeF, kTileSizeF);
    glUniform4fv(g_dab.uColor, 1, kColor);

    for (int ty = ty0; ty <= ty1; ++ty) {
        for (int tx = tx0; tx <= tx1; ++tx) {
            Tile& tile = getOrCreateTile(tx, ty);
            glBindFramebuffer(GL_FRAMEBUFFER, tile.fbo);
            glViewport(0, 0, kTileSize, kTileSize);

            float ox = tx * kTileSizeF;
            float oy = ty * kTileSizeF;

            DabEmitter e;
            for (const auto& s : g_current.samples) {
                e.extend(s.x - ox, s.y - oy, s.p);
            }
        }
    }

    g_current.samples.clear();
    glBindVertexArray(0);
}

// ---- Compose --------------------------------------------------------------
// Composite every tile onto the bound framebuffer. Caller has already bound
// the destination FBO; we set viewport from width/height.

void compositeAllTiles(JNIEnv* env, jint width, jint height,
                       jfloatArray transform) {
    glViewport(0, 0, width, height);
    glClearColor(1.0f, 1.0f, 1.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    if (g_tiles.empty()) return;

    glDisable(GL_BLEND);
    glUseProgram(g_comp.program);
    glBindVertexArray(g_quadVao);
    uploadMat4(env, g_comp.uTransform, transform);
    glUniform2f(g_comp.uScreen, (float)width, (float)height);
    glUniform1f(g_comp.uTileHalf, kTileHalfF);
    glUniform1i(g_comp.uTileTex, 0);  // sampler bound to texture unit 0

    glActiveTexture(GL_TEXTURE0);

    for (const auto& kv : g_tiles) {
        int tx, ty;
        unpackTileKey(kv.first, tx, ty);
        float cx = tx * kTileSizeF + kTileHalfF;
        float cy = ty * kTileSizeF + kTileHalfF;

        glBindTexture(GL_TEXTURE_2D, kv.second.texture);
        glUniform2f(g_comp.uTileCenter, cx, cy);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }

    glBindTexture(GL_TEXTURE_2D, 0);
    glBindVertexArray(0);
    glEnable(GL_BLEND);
}

}  // namespace

// ---- JNI ------------------------------------------------------------------

extern "C" {

JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_beginStroke(JNIEnv*, jobject) {
    g_current.samples.clear();
    g_liveEmitter.reset();
}

JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_extendStroke(
        JNIEnv* env, jobject,
        jint width, jint height,
        jfloatArray transform,
        jfloat x, jfloat y, jfloat pressure) {
    ensureInited();
    glViewport(0, 0, width, height);
    glUseProgram(g_dab.program);
    glBindVertexArray(g_quadVao);
    uploadMat4(env, g_dab.uTransform, transform);
    glUniform2f(g_dab.uScreen, (float)width, (float)height);
    glUniform4fv(g_dab.uColor, 1, kColor);

    g_current.samples.push_back({x, y, pressure});
    g_liveEmitter.extend(x, y, pressure);

    glBindVertexArray(0);
}

JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_commitStroke(JNIEnv*, jobject) {
    ensureInited();

    // bakeCurrentStrokeIntoTiles binds tile FBOs; restore the caller's
    // FBO afterward so subsequent rendering goes back to the multi-buffer.
    GLint prevFbo = 0;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prevFbo);

    bakeCurrentStrokeIntoTiles();

    glBindFramebuffer(GL_FRAMEBUFFER, prevFbo);
    g_liveEmitter.reset();
}

JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_renderDocument(
        JNIEnv* env, jobject,
        jint width, jint height,
        jfloatArray transform) {
    ensureInited();
    compositeAllTiles(env, width, height, transform);
}

}  // extern "C"
