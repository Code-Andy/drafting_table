// Tile-based document renderer with on-disk persistence and layers.
//
// Document model:
//   Document
//     └── Layer[]                  (z-ordered, bottom-up)
//           └── tile grid          (sparse: unordered_map<(tx, ty), Tile>)
//
//   - Document is an infinite 2D plane in floating-point coordinates
//     (origin top-left, y-down — matches MotionEvent).
//   - Each layer holds its own sparse 256x256 RGBA tile grid; tiles are
//     allocated lazily when a stroke first touches them and cleared to
//     fully-transparent.
//   - The multi-buffer is cleared to paper-white before tiles composite,
//     so the bottom-most "paper" is implicit (no dedicated layer for it).
//
// Premultiplied alpha:
//   Tile contents are stored premultiplied. Dab fragment shader outputs
//   vec4(rgb*α, α). Both intra-tile baking and tile compositing use
//   glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA), which is the correct
//   blend mode for premultiplied alpha.
//
// Persistence:
//   <docDir>/layer_<idx>/tile_<tx>_<ty>.bin holds raw 256x256x4 RGBA bytes
//   per tile (premultiplied). Single-layer documents from before the layer
//   refactor are migrated into layer_0/ on first load.
//
// Stroke lifecycle:
//   beginStroke      - reset emitter, snapshot active layer as stroke target
//   extendStroke     - append a sample, emit dabs additively into the
//                      front-buffered layer
//   commitStroke     - bake the stroke into the snapshotted target layer's
//                      tiles, save those tiles to disk, drop samples
//   renderDocument   - clear the multi-buffer to white, composite every
//                      tile of every layer in z-order
//
// Cross-thread layer ops:
//   addLayer / cycleActiveLayer can be called from the UI thread; they
//   enqueue an action under a mutex and the GL thread drains the queue at
//   the start of each operation. This avoids racy access to g_layers.

#include <jni.h>
#include <GLES3/gl3.h>
#include <android/log.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <dirent.h>
#include <memory>
#include <mutex>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <unordered_map>
#include <vector>

#define LOG_TAG "DrawingApp"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

// ---- Tunables -------------------------------------------------------------

constexpr int    kTileSize  = 256;
constexpr float  kTileSizeF = 256.0f;
constexpr float  kTileHalfF = 128.0f;
constexpr size_t kTileBytes = static_cast<size_t>(kTileSize) * kTileSize * 4;

constexpr float kSpacing   = 0.18f;
constexpr float kMinRadius = 2.0f;
constexpr float kMaxRadius = 18.0f;

// Brush dabs render this dark ink color, premultiplied + additive.
constexpr float kBrushColor[4] = { 0.08f, 0.09f, 0.12f, 0.85f };

// During an erase stroke, the front-buffered live preview shows a pink
// indicator (blended additively, like a brush) so the user can see where
// they're about to erase. The actual erase happens at commit, in the
// tile bake path, with a different blend mode.
constexpr float kEraserPreviewColor[4] = { 1.00f, 0.40f, 0.45f, 0.55f };

// When baking an erase stroke into a tile we use glBlendFunc(GL_ZERO,
// GL_ONE_MINUS_SRC_ALPHA), so src.rgb is multiplied by zero — only src.a
// matters. The 0.85 here mirrors brush coverage so erase strength feels
// symmetric with how the brush deposits ink.
constexpr float kEraserBakeColor[4] = { 0.00f, 0.00f, 0.00f, 0.85f };

// During eraser live preview we accumulate erase coverage into a separate
// FBO with additive premultiplied blend. The dab fragment shader outputs
// (rgb*alpha, alpha); rgb=0 here so only alpha lands in the coverage map,
// and alpha=0.85 matches the bake-time strength so live preview equals
// the post-commit appearance.
constexpr float kCoverageColor[4] = { 0.00f, 0.00f, 0.00f, 0.85f };

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
    float alpha = uColor.a * a;
    // Premultiplied output, blended with GL_ONE / GL_ONE_MINUS_SRC_ALPHA.
    outColor = vec4(uColor.rgb * alpha, alpha);
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
    // Tile texture is premultiplied; preserve alpha for correct compositing.
    outColor = texture(uTileTex, vUv);
}
)";

// Eraser preview composite. Output is premultiplied with alpha=c, so the
// framework's premultiplied composite over the multi-buffer evaluates to:
//     result = (fullErase * c) + multi * (1 - c)
//            = lerp(multi, fullErase, c)
// where fullErase = composite(below, above) is the "what would be left if
// the active layer were removed entirely". By the linearity of
// premultiplied compositing in any single layer's contribution, this lerp
// equals the true WYSIWYG display target — the same result the eraser
// bake will produce — for any 0 ≤ c ≤ 1. Includes the layers above
// active correctly, so erasing under them doesn't make them disappear.
const char* kPreviewVS = R"(#version 300 es
layout(location = 0) in vec2 aQuad;
out vec2 vUv;
void main() {
    gl_Position = vec4(aQuad, 0.0, 1.0);
    vUv = aQuad * 0.5 + 0.5;
}
)";

const char* kPreviewFS = R"(#version 300 es
precision mediump float;
in vec2 vUv;
uniform sampler2D uBelow;     // paper + layers strictly below active; alpha=1
uniform sampler2D uAbove;     // layers strictly above active, premultiplied
uniform sampler2D uCoverage;  // erase coverage in alpha
out vec4 outColor;
void main() {
    vec4 below = texture(uBelow, vUv);
    vec4 above = texture(uAbove, vUv);
    float c    = texture(uCoverage, vUv).a;
    vec3 fullErase = above.rgb + below.rgb * (1.0 - above.a);
    outColor = vec4(fullErase * c, c);
}
)";

// ---- Data structures ------------------------------------------------------

struct Sample { float x, y, p; };
struct Stroke { std::vector<Sample> samples; };

struct Tile {
    GLuint texture = 0;
    GLuint fbo     = 0;
};

struct Layer {
    std::unordered_map<int64_t, Tile> tiles;
};

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

struct PreviewProg {
    GLuint program   = 0;
    GLint  uBelow    = -1;
    GLint  uAbove    = -1;
    GLint  uCoverage = -1;
};

struct ViewFbo {
    GLuint texture = 0;
    GLuint fbo     = 0;
    int    width   = 0;
    int    height  = 0;
};

// ---- State (GL-thread-only unless noted) ----------------------------------

DabProg     g_dab;
CompProg    g_comp;
PreviewProg g_preview;
GLuint      g_quadVao = 0;
GLuint      g_quadVbo = 0;
bool        g_inited  = false;

// Live eraser preview state. Two layer-stack snapshots and one coverage
// map, all sized to the buffer dimensions and lazily (re)allocated.
//   - belowFbo: paper + layers strictly below active (alpha=1)
//   - aboveFbo: layers strictly above active, premultiplied over transparent
//   - coverage: accumulated erase-coverage alpha as the user drags
ViewFbo g_belowFbo;
ViewFbo g_aboveFbo;
ViewFbo g_coverage;
bool    g_needsErasePrep = false;    // set at beginStroke (eraser); cleared on first extendStroke

std::vector<std::unique_ptr<Layer>> g_layers;
size_t g_activeLayer  = 0;
size_t g_strokeTarget = 0;          // captured at beginStroke

// Active tool: 0 = brush, 1 = eraser. Settable from any thread (UI thread
// flips it via setTool() on stylus-button press); the GL thread reads it
// at beginStroke into g_strokeTool so a stroke uses one consistent tool
// even if the user toggles mid-stroke.
std::atomic<int> g_currentTool{0};
int g_strokeTool = 0;

Stroke     g_current;
struct DabEmitter;                  // forward-decl
extern DabEmitter g_liveEmitter;

std::string g_docDir;               // empty = persistence disabled
bool        g_loaded = false;

// Cross-thread queue: UI-thread layer ops enqueue, GL thread drains at the
// start of each operation.
std::mutex g_pendingMutex;
std::vector<int> g_pendingActions;
constexpr int kActionAddLayer    = 1;
constexpr int kActionCycleActive = 2;
constexpr int kActionClearActive = 3;

// ---- Helpers --------------------------------------------------------------

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

void drawDab(float x, float y, float radius) {
    glUniform2f(g_dab.uCenter, x, y);
    glUniform1f(g_dab.uRadius, radius);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

// ---- DabEmitter -----------------------------------------------------------

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

// ---- Pending layer actions ------------------------------------------------

void enqueuePendingAction(int a) {
    std::lock_guard<std::mutex> lock(g_pendingMutex);
    g_pendingActions.push_back(a);
}

void applyPendingLayerActions() {
    std::vector<int> actions;
    {
        std::lock_guard<std::mutex> lock(g_pendingMutex);
        actions.swap(g_pendingActions);
    }
    for (int a : actions) {
        if (a == kActionAddLayer) {
            g_layers.push_back(std::make_unique<Layer>());
            g_activeLayer = g_layers.size() - 1;
            LOGI("layer added (count=%zu, active=%zu)",
                 g_layers.size(), g_activeLayer);
        } else if (a == kActionCycleActive && !g_layers.empty()) {
            g_activeLayer = (g_activeLayer + 1) % g_layers.size();
            LOGI("active layer cycled to %zu/%zu",
                 g_activeLayer, g_layers.size() - 1);
        } else if (a == kActionClearActive
                   && g_activeLayer < g_layers.size()
                   && g_layers[g_activeLayer]) {
            Layer& layer = *g_layers[g_activeLayer];
            for (auto& kv : layer.tiles) {
                if (kv.second.fbo)     glDeleteFramebuffers(1, &kv.second.fbo);
                if (kv.second.texture) glDeleteTextures(1, &kv.second.texture);
            }
            layer.tiles.clear();
            // Also wipe the on-disk copy so the cleared state persists.
            if (!g_docDir.empty()) {
                std::string layerDir = g_docDir + "/layer_"
                                     + std::to_string(g_activeLayer);
                DIR* d = opendir(layerDir.c_str());
                if (d) {
                    struct dirent* e;
                    while ((e = readdir(d)) != nullptr) {
                        const char* n = e->d_name;
                        if (n[0] == '.') continue;
                        std::string p = layerDir + "/" + n;
                        unlink(p.c_str());
                    }
                    closedir(d);
                }
            }
            LOGI("active layer %zu cleared", g_activeLayer);
        }
    }
}

void ensureAtLeastOneLayer() {
    if (g_layers.empty()) {
        g_layers.push_back(std::make_unique<Layer>());
        g_activeLayer = 0;
    }
    if (g_activeLayer >= g_layers.size()) {
        g_activeLayer = g_layers.size() - 1;
    }
}

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

    g_preview.program   = linkProgram(kPreviewVS, kPreviewFS);
    g_preview.uBelow    = glGetUniformLocation(g_preview.program, "uBelow");
    g_preview.uAbove    = glGetUniformLocation(g_preview.program, "uAbove");
    g_preview.uCoverage = glGetUniformLocation(g_preview.program, "uCoverage");

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
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);  // premultiplied

    g_inited = true;
    LOGI("renderer initialized");
}

void uploadMat4(JNIEnv* env, GLint loc, jfloatArray transform) {
    jfloat* arr = env->GetFloatArrayElements(transform, nullptr);
    glUniformMatrix4fv(loc, 1, GL_FALSE, arr);
    env->ReleaseFloatArrayElements(transform, arr, JNI_ABORT);
}

// ---- Eraser-preview FBO helpers ------------------------------------------

void ensureViewFbo(ViewFbo& v, int width, int height) {
    if (v.texture != 0 && v.width == width && v.height == height) return;

    if (v.fbo)     glDeleteFramebuffers(1, &v.fbo);
    if (v.texture) glDeleteTextures(1, &v.texture);
    v.fbo = 0; v.texture = 0;

    glGenTextures(1, &v.texture);
    glBindTexture(GL_TEXTURE_2D, v.texture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0,
                 GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    glGenFramebuffers(1, &v.fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, v.fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                           GL_TEXTURE_2D, v.texture, 0);
    GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        LOGE("view FBO incomplete: 0x%x (size %dx%d)", status, width, height);
    }

    v.width  = width;
    v.height = height;
}

// Composite the layers in [startIdx, endExclusive) into target FBO. If
// clearWhite is true, the FBO is first cleared to opaque paper-white;
// otherwise to transparent. Result is premultiplied either way.
void renderLayerRangeIntoFbo(JNIEnv* env, ViewFbo& target,
                             size_t startIdx, size_t endExclusive,
                             int width, int height, jfloatArray transform,
                             bool clearWhite) {
    ensureViewFbo(target, width, height);
    glBindFramebuffer(GL_FRAMEBUFFER, target.fbo);
    glViewport(0, 0, width, height);
    if (clearWhite) {
        glClearColor(1.0f, 1.0f, 1.0f, 1.0f);
    } else {
        glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
    }
    glClear(GL_COLOR_BUFFER_BIT);

    if (startIdx >= endExclusive) return;

    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    glUseProgram(g_comp.program);
    glBindVertexArray(g_quadVao);
    uploadMat4(env, g_comp.uTransform, transform);
    glUniform2f(g_comp.uScreen, (float)width, (float)height);
    glUniform1f(g_comp.uTileHalf, kTileHalfF);
    glUniform1i(g_comp.uTileTex, 0);
    glActiveTexture(GL_TEXTURE0);

    for (size_t i = startIdx; i < endExclusive && i < g_layers.size(); ++i) {
        if (!g_layers[i]) continue;
        for (const auto& kv : g_layers[i]->tiles) {
            int tx, ty;
            unpackTileKey(kv.first, tx, ty);
            float cx = tx * kTileSizeF + kTileHalfF;
            float cy = ty * kTileSizeF + kTileHalfF;
            glBindTexture(GL_TEXTURE_2D, kv.second.texture);
            glUniform2f(g_comp.uTileCenter, cx, cy);
            glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        }
    }

    glBindTexture(GL_TEXTURE_2D, 0);
    glBindVertexArray(0);
}

// Populate the scratch buffers used by the eraser preview composite. The
// active layer is intentionally omitted — by compositing linearity, lerp
// between multi (active in) and fullErase (active out) recovers the true
// disp(c) for any 0 ≤ c ≤ 1, and the framework's alpha-blend does the
// lerp for free.
void prepareErasePreviewBuffers(JNIEnv* env, int width, int height,
                                jfloatArray transform) {
    // below: paper + layers strictly below active (paper-backed, alpha=1)
    renderLayerRangeIntoFbo(env, g_belowFbo, 0, g_strokeTarget,
                            width, height, transform, /*clearWhite=*/true);
    // above: layers strictly above active (premultiplied over transparent;
    // empty range when active is the top layer is handled by early-return)
    renderLayerRangeIntoFbo(env, g_aboveFbo, g_strokeTarget + 1, g_layers.size(),
                            width, height, transform, /*clearWhite=*/false);

    // Reset coverage to zero.
    ensureViewFbo(g_coverage, width, height);
    glBindFramebuffer(GL_FRAMEBUFFER, g_coverage.fbo);
    glViewport(0, 0, width, height);
    glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
    glClear(GL_COLOR_BUFFER_BIT);
}

// ---- Tile management ------------------------------------------------------

Tile& getOrCreateTile(Layer& layer, int tx, int ty,
                      const uint8_t* initial = nullptr) {
    int64_t k = tileKey(tx, ty);
    auto it = layer.tiles.find(k);
    if (it != layer.tiles.end()) return it->second;

    Tile t;
    glGenTextures(1, &t.texture);
    glBindTexture(GL_TEXTURE_2D, t.texture);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, kTileSize, kTileSize, 0,
                 GL_RGBA, GL_UNSIGNED_BYTE, initial);
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

    if (!initial) {
        glViewport(0, 0, kTileSize, kTileSize);
        glClearColor(0.0f, 0.0f, 0.0f, 0.0f);  // transparent — premultiplied
        glClear(GL_COLOR_BUFFER_BIT);
    }

    layer.tiles[k] = t;
    return layer.tiles[k];
}

// ---- Persistence ---------------------------------------------------------

// Move any tile_*_*.bin files at <docDir> root into <docDir>/layer_0/.
// One-time migration for documents written before the layer refactor.
void migrateLegacyTilesToLayer0IfNeeded() {
    if (g_docDir.empty()) return;

    DIR* d = opendir(g_docDir.c_str());
    if (!d) return;

    std::vector<std::string> legacy;
    struct dirent* e;
    while ((e = readdir(d)) != nullptr) {
        int tx, ty;
        if (sscanf(e->d_name, "tile_%d_%d.bin", &tx, &ty) == 2) {
            legacy.emplace_back(e->d_name);
        }
    }
    closedir(d);

    if (legacy.empty()) return;

    std::string layer0Dir = g_docDir + "/layer_0";
    if (mkdir(layer0Dir.c_str(), 0755) != 0 && errno != EEXIST) {
        LOGE("can't create %s (errno=%d)", layer0Dir.c_str(), errno);
        return;
    }

    int moved = 0;
    for (const auto& name : legacy) {
        std::string from = g_docDir + "/" + name;
        std::string to   = layer0Dir + "/" + name;
        if (rename(from.c_str(), to.c_str()) == 0) ++moved;
    }
    LOGI("migrated %d legacy tiles to layer_0", moved);
}

void loadTilesIntoLayer(Layer& layer, const std::string& dir) {
    DIR* d = opendir(dir.c_str());
    if (!d) return;

    std::vector<uint8_t> buf(kTileBytes);
    int loaded = 0;
    struct dirent* e;
    while ((e = readdir(d)) != nullptr) {
        int tx, ty;
        if (sscanf(e->d_name, "tile_%d_%d.bin", &tx, &ty) != 2) continue;
        std::string path = dir + "/" + e->d_name;
        FILE* f = fopen(path.c_str(), "rb");
        if (!f) {
            LOGE("can't open %s", path.c_str());
            continue;
        }
        size_t n = fread(buf.data(), 1, buf.size(), f);
        fclose(f);
        if (n != buf.size()) {
            LOGE("tile %s short read: %zu bytes", e->d_name, n);
            continue;
        }
        getOrCreateTile(layer, tx, ty, buf.data());
        ++loaded;
    }
    closedir(d);
    LOGI("loaded %d tiles from %s", loaded, dir.c_str());
}

void loadAllLayersFromDisk() {
    if (g_docDir.empty()) return;

    migrateLegacyTilesToLayer0IfNeeded();

    DIR* d = opendir(g_docDir.c_str());
    if (!d) return;

    std::vector<int> indices;
    struct dirent* e;
    while ((e = readdir(d)) != nullptr) {
        int idx;
        if (sscanf(e->d_name, "layer_%d", &idx) == 1 && idx >= 0) {
            indices.push_back(idx);
        }
    }
    closedir(d);

    if (indices.empty()) return;

    std::sort(indices.begin(), indices.end());
    int maxIdx = indices.back();
    g_layers.resize(static_cast<size_t>(maxIdx + 1));
    for (auto& slot : g_layers) {
        if (!slot) slot = std::make_unique<Layer>();
    }

    for (int idx : indices) {
        std::string dirPath = g_docDir + "/layer_" + std::to_string(idx);
        loadTilesIntoLayer(*g_layers[idx], dirPath);
    }
}

void ensureLoaded() {
    if (g_loaded) return;
    g_loaded = true;

    GLint prevFbo = 0;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prevFbo);
    loadAllLayersFromDisk();
    glBindFramebuffer(GL_FRAMEBUFFER, prevFbo);
}

void saveTileToDisk(size_t layerIdx, int64_t tileK) {
    if (g_docDir.empty()) return;
    if (layerIdx >= g_layers.size() || !g_layers[layerIdx]) return;
    auto& tiles = g_layers[layerIdx]->tiles;
    auto it = tiles.find(tileK);
    if (it == tiles.end()) return;

    int tx, ty;
    unpackTileKey(tileK, tx, ty);

    glBindFramebuffer(GL_FRAMEBUFFER, it->second.fbo);
    std::vector<uint8_t> buf(kTileBytes);
    glReadPixels(0, 0, kTileSize, kTileSize, GL_RGBA, GL_UNSIGNED_BYTE,
                 buf.data());

    std::string layerDir = g_docDir + "/layer_" + std::to_string(layerIdx);
    if (mkdir(layerDir.c_str(), 0755) != 0 && errno != EEXIST) {
        LOGE("can't create %s (errno=%d)", layerDir.c_str(), errno);
        return;
    }

    char path[1024], tmpPath[1024];
    snprintf(path,    sizeof(path),    "%s/tile_%d_%d.bin",     layerDir.c_str(), tx, ty);
    snprintf(tmpPath, sizeof(tmpPath), "%s/tile_%d_%d.bin.tmp", layerDir.c_str(), tx, ty);

    FILE* f = fopen(tmpPath, "wb");
    if (!f) {
        LOGE("save tile (%d, %d) layer %zu: fopen %s failed",
             tx, ty, layerIdx, tmpPath);
        return;
    }
    size_t written = fwrite(buf.data(), 1, buf.size(), f);
    fclose(f);
    if (written != buf.size()) {
        LOGE("save tile (%d, %d) layer %zu: short write %zu",
             tx, ty, layerIdx, written);
        unlink(tmpPath);
        return;
    }
    if (rename(tmpPath, path) != 0) {
        LOGE("save tile (%d, %d) layer %zu: rename failed (errno=%d)",
             tx, ty, layerIdx, errno);
    }
}

// ---- Bake -----------------------------------------------------------------

void bakeCurrentStrokeIntoTiles(std::vector<int64_t>* dirtyOut,
                                size_t layerIdx) {
    if (g_current.samples.empty()) return;
    if (layerIdx >= g_layers.size()) return;
    Layer& layer = *g_layers[layerIdx];

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

    if (g_strokeTool == 0) {
        // Brush: additive premultiplied.
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
        glUniform4fv(g_dab.uColor, 1, kBrushColor);
    } else {
        // Eraser: subtract coverage. Tile alpha (and rgb) get scaled by
        // (1 - srcAlpha), so painted pixels go transparent and the
        // multi-buffer's paper-white shows through during composite.
        glBlendFunc(GL_ZERO, GL_ONE_MINUS_SRC_ALPHA);
        glUniform4fv(g_dab.uColor, 1, kEraserBakeColor);
    }

    for (int ty = ty0; ty <= ty1; ++ty) {
        for (int tx = tx0; tx <= tx1; ++tx) {
            Tile& tile = getOrCreateTile(layer, tx, ty);
            glBindFramebuffer(GL_FRAMEBUFFER, tile.fbo);
            glViewport(0, 0, kTileSize, kTileSize);

            float ox = tx * kTileSizeF;
            float oy = ty * kTileSizeF;

            DabEmitter e;
            for (const auto& s : g_current.samples) {
                e.extend(s.x - ox, s.y - oy, s.p);
            }

            if (dirtyOut) dirtyOut->push_back(tileKey(tx, ty));
        }
    }

    g_current.samples.clear();
    glBindVertexArray(0);

    // Restore the default (additive premultiplied) blend so subsequent
    // paths don't inherit eraser state.
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
}

// ---- Compose --------------------------------------------------------------

void compositeAllLayers(JNIEnv* env, jint width, jint height,
                        jfloatArray transform) {
    glViewport(0, 0, width, height);
    glClearColor(1.0f, 1.0f, 1.0f, 1.0f);          // paper white
    glClear(GL_COLOR_BUFFER_BIT);

    if (g_layers.empty()) return;

    // Tiles are premultiplied, so the global blend is the right setting.
    glUseProgram(g_comp.program);
    glBindVertexArray(g_quadVao);
    uploadMat4(env, g_comp.uTransform, transform);
    glUniform2f(g_comp.uScreen, (float)width, (float)height);
    glUniform1f(g_comp.uTileHalf, kTileHalfF);
    glUniform1i(g_comp.uTileTex, 0);

    glActiveTexture(GL_TEXTURE0);

    for (const auto& layer : g_layers) {
        if (!layer) continue;
        for (const auto& kv : layer->tiles) {
            int tx, ty;
            unpackTileKey(kv.first, tx, ty);
            float cx = tx * kTileSizeF + kTileHalfF;
            float cy = ty * kTileSizeF + kTileHalfF;

            glBindTexture(GL_TEXTURE_2D, kv.second.texture);
            glUniform2f(g_comp.uTileCenter, cx, cy);
            glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        }
    }

    glBindTexture(GL_TEXTURE_2D, 0);
    glBindVertexArray(0);
}

}  // namespace

// ---- JNI ------------------------------------------------------------------

extern "C" {

JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_setDocumentDir(JNIEnv* env, jobject, jstring jpath) {
    const char* str = env->GetStringUTFChars(jpath, nullptr);
    g_docDir = str;
    env->ReleaseStringUTFChars(jpath, str);
    LOGI("document dir = %s", g_docDir.c_str());
}

JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_setTool(JNIEnv*, jobject, jint tool) {
    g_currentTool.store(tool);
}

JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_addLayer(JNIEnv*, jobject) {
    enqueuePendingAction(kActionAddLayer);
}

JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_cycleActiveLayer(JNIEnv*, jobject) {
    enqueuePendingAction(kActionCycleActive);
}

JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_clearActiveLayer(JNIEnv*, jobject) {
    enqueuePendingAction(kActionClearActive);
}

// Read accessors for UI display. Called from the UI thread; the values may
// momentarily be stale relative to queued addLayer/cycleActiveLayer
// actions (which apply on the GL thread) but the discrepancy resolves on
// the next stroke or render and is fine for status text.
JNIEXPORT jint JNICALL
Java_com_bk_drawing_NativeRenderer_getLayerCount(JNIEnv*, jobject) {
    return static_cast<jint>(g_layers.size());
}

JNIEXPORT jint JNICALL
Java_com_bk_drawing_NativeRenderer_getActiveLayer(JNIEnv*, jobject) {
    return static_cast<jint>(g_activeLayer);
}

JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_beginStroke(JNIEnv*, jobject) {
    ensureInited();
    ensureLoaded();
    applyPendingLayerActions();
    ensureAtLeastOneLayer();

    g_strokeTarget = g_activeLayer;
    g_strokeTool   = g_currentTool.load();
    // Eraser strokes need a WYSIWYG preview, which depends on snapshots
    // of below/active/above. We can't render those yet (no width/
    // height/transform here); defer to first extendStroke.
    g_needsErasePrep = (g_strokeTool == 1);
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
    g_current.samples.push_back({x, y, pressure});

    if (g_strokeTool == 0) {
        // Brush: dabs go directly into the front buffer, additive premult.
        glViewport(0, 0, width, height);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
        glUseProgram(g_dab.program);
        glBindVertexArray(g_quadVao);
        uploadMat4(env, g_dab.uTransform, transform);
        glUniform2f(g_dab.uScreen, (float)width, (float)height);
        glUniform4fv(g_dab.uColor, 1, kBrushColor);
        g_liveEmitter.extend(x, y, pressure);
        glBindVertexArray(0);
        return;
    }

    // Eraser: WYSIWYG preview. The front buffer can only ADD on top of the
    // multi-buffer, so to fake "live erasing" we composite a fullscreen
    // overlay equal to (below.rgb * coverage, coverage). When the framework
    // blends that over the multi-buffer (premultiplied), the displayed
    // pixel ends up at coverage*below + (1-coverage)*multi — i.e. fully
    // erased pixels show what's beneath the active layer, partially
    // erased pixels fade proportionally, untouched pixels stay as-is.

    GLint frontFbo = 0;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &frontFbo);

    if (g_needsErasePrep) {
        prepareErasePreviewBuffers(env, width, height, transform);
        g_needsErasePrep = false;
    }

    // Step 1: accumulate this dab's erase coverage into g_coverage.
    glBindFramebuffer(GL_FRAMEBUFFER, g_coverage.fbo);
    glViewport(0, 0, width, height);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    glUseProgram(g_dab.program);
    glBindVertexArray(g_quadVao);
    uploadMat4(env, g_dab.uTransform, transform);
    glUniform2f(g_dab.uScreen, (float)width, (float)height);
    glUniform4fv(g_dab.uColor, 1, kCoverageColor);
    g_liveEmitter.extend(x, y, pressure);
    glBindVertexArray(0);

    // Step 2: re-render the front-buffer overlay as the proper layered
    // composite. Output alpha is 1, so this fully replaces the multi
    // buffer wherever it lands — for c=0 pixels it evaluates to multi
    // exactly (compositing is associative), so unaffected regions look
    // identical to the bare multi-buffer.
    glBindFramebuffer(GL_FRAMEBUFFER, frontFbo);
    glViewport(0, 0, width, height);
    glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    glUseProgram(g_preview.program);
    glBindVertexArray(g_quadVao);
    glUniform1i(g_preview.uBelow,    0);
    glUniform1i(g_preview.uAbove,    1);
    glUniform1i(g_preview.uCoverage, 2);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, g_belowFbo.texture);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, g_aboveFbo.texture);
    glActiveTexture(GL_TEXTURE2);
    glBindTexture(GL_TEXTURE_2D, g_coverage.texture);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

    glBindTexture(GL_TEXTURE_2D, 0);
    glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, 0);
    glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, 0);
    glBindVertexArray(0);
}

JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_commitStroke(JNIEnv*, jobject) {
    ensureInited();

    GLint prevFbo = 0;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prevFbo);

    ensureLoaded();
    applyPendingLayerActions();
    ensureAtLeastOneLayer();

    size_t layerIdx = g_strokeTarget < g_layers.size() ? g_strokeTarget
                                                       : g_layers.size() - 1;

    std::vector<int64_t> dirty;
    bakeCurrentStrokeIntoTiles(&dirty, layerIdx);

    for (int64_t k : dirty) {
        saveTileToDisk(layerIdx, k);
    }

    glBindFramebuffer(GL_FRAMEBUFFER, prevFbo);
    g_liveEmitter.reset();
}

JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_renderDocument(
        JNIEnv* env, jobject,
        jint width, jint height,
        jfloatArray transform) {
    ensureInited();
    ensureLoaded();
    applyPendingLayerActions();
    compositeAllLayers(env, width, height, transform);
}

}  // extern "C"
