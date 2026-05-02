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

// Brush dabs render with a runtime-settable color. The dab's per-fragment
// alpha (kBrushAlpha * radial falloff) controls stroke buildup as
// overlapping dabs accumulate; the *color* is g_strokeBrushColor, which
// is captured from g_currentBrushColor at beginStroke.
constexpr float kBrushAlpha = 0.85f;

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

// Unified live-preview composite for both brush and eraser. Output is
// premultiplied with alpha = c (accumulated coverage), so the framework's
// premultiplied composite over the multi-buffer yields:
//     result = fullColor * c + multi * (1 - c)
//            = lerp(multi, fullColor, c)
// where fullColor is "the displayed pixel value if the active layer were
// fully painted (brush) / fully erased (eraser) at this point". By the
// linearity of premultiplied compositing in any single layer's
// contribution, this lerp equals the true WYSIWYG display target for any
// 0 ≤ c ≤ 1. Both tools therefore correctly render strokes UNDER any
// layers above active, instead of overlaying them on top of multi.
//
//   eraser: fullColor = above + below * (1 - above.a)   // active gone
//   brush:  fullColor = above + brushRgb * (1 - above.a) // active fully painted
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
uniform sampler2D uCoverage;  // accumulated coverage in alpha channel
uniform int       uMode;      // 0 = brush, 1 = eraser
uniform vec3      uBrushRgb;  // un-premultiplied brush color (ignored for eraser)
out vec4 outColor;
void main() {
    vec4 above = texture(uAbove, vUv);
    float c    = texture(uCoverage, vUv).a;

    vec3 fullColor;
    if (uMode == 1) {
        vec4 below = texture(uBelow, vUv);
        fullColor = above.rgb + below.rgb * (1.0 - above.a);
    } else {
        fullColor = above.rgb + uBrushRgb * (1.0 - above.a);
    }
    outColor = vec4(fullColor * c, c);
}
)";

// Vector-layer line. Vertex shader morphs the unit quad into a
// capsule-shaped quad oriented along the line, with an extra halfWidth
// of margin past each endpoint so the rounded caps fit. Fragment shader
// computes a capsule SDF (signed distance to the segment with rounded
// ends) and anti-aliases over a 1-pixel band at the edge.
const char* kLineVS = R"(#version 300 es
layout(location = 0) in vec2 aQuad;
out vec2 vLineSpace;       // (along, across) from line midpoint, in doc-pixels
uniform mat4  uTransform;
uniform vec2  uScreen;
uniform vec2  uP0;
uniform vec2  uP1;
uniform float uHalfWidth;
void main() {
    vec2 dir = uP1 - uP0;
    float len = length(dir);
    vec2 ndir = (len > 1e-6) ? dir / len : vec2(1.0, 0.0);
    vec2 nrm  = vec2(-ndir.y, ndir.x);
    vec2 mid  = (uP0 + uP1) * 0.5;

    float halfLen   = len * 0.5;
    float along     = aQuad.x * (halfLen + uHalfWidth);
    float across    = aQuad.y * uHalfWidth;
    vec2  docPos    = mid + ndir * along + nrm * across;

    vec4 bufPx = uTransform * vec4(docPos, 0.0, 1.0);
    vec2 ndc   = (bufPx.xy / uScreen) * 2.0 - 1.0;
    gl_Position = vec4(ndc, 0.0, 1.0);

    vLineSpace = vec2(along, across);
}
)";

const char* kLineFS = R"(#version 300 es
// highp throughout — uP0/uP1 carry full-buffer-magnitude pixel
// coordinates (up to ~2200), and at that magnitude the default mediump
// (10-bit mantissa) has ~1.7 unit precision. length(uP1 - uP0) for
// short lines then loses most of its accuracy, which warps the SDF
// enough that alpha can't ramp correctly.
precision highp float;
in vec2 vLineSpace;
uniform vec2  uP0;
uniform vec2  uP1;
uniform float uHalfWidth;
uniform vec4  uColor;        // straight RGBA (premultiplied at output)
out vec4 outColor;
void main() {
    float halfLen = length(uP1 - uP0) * 0.5;
    float dAlong  = max(abs(vLineSpace.x) - halfLen, 0.0);
    float dist    = sqrt(dAlong * dAlong + vLineSpace.y * vLineSpace.y);
    float alpha   = 1.0 - smoothstep(uHalfWidth - 0.5, uHalfWidth + 0.5, dist);
    if (alpha <= 0.0) discard;
    float a = uColor.a * alpha;
    outColor = vec4(uColor.rgb * a, a);
}
)";

// Page-background grid. A fullscreen NDC quad whose fragment shader
// computes each pixel's document position via the inverse of the
// framework's transform matrix, then evaluates a periodic line/dot
// pattern. Output is premultiplied so it composites cleanly onto the
// paper-white-cleared multi-buffer ahead of the layer tiles.
const char* kGridVS = R"(#version 300 es
layout(location = 0) in vec2 aQuad;
void main() {
    gl_Position = vec4(aQuad, 0.0, 1.0);
}
)";

const char* kGridFS = R"(#version 300 es
precision mediump float;
uniform mat4  uInverseTransform;   // buffer-pixel -> document-pixel
uniform float uSpacing;            // minor grid spacing in document pixels
uniform float uSubdivisions;       // major lines every Nth minor
uniform float uMinorWidth;         // half-width of minor line/dot in doc pixels
uniform float uMajorWidth;
uniform vec4  uMinorColor;         // straight RGBA
uniform vec4  uMajorColor;
uniform int   uStyle;              // 1 = lines, 2 = dots
out vec4 outColor;

void main() {
    vec2 docPos = (uInverseTransform * vec4(gl_FragCoord.xy, 0.0, 1.0)).xy;

    float sMin = uSpacing;
    float sMaj = uSpacing * uSubdivisions;

    // Distance to the nearest grid line per axis, in document pixels.
    vec2 dMin = abs(mod(docPos + sMin * 0.5, sMin) - sMin * 0.5);
    vec2 dMaj = abs(mod(docPos + sMaj * 0.5, sMaj) - sMaj * 0.5);

    float aMinor = 0.0;
    float aMajor = 0.0;

    if (uStyle == 1) {
        // Lines — close to ANY axis lights up.
        aMinor = max(
            1.0 - smoothstep(uMinorWidth, uMinorWidth + 1.0, dMin.x),
            1.0 - smoothstep(uMinorWidth, uMinorWidth + 1.0, dMin.y));
        aMajor = max(
            1.0 - smoothstep(uMajorWidth, uMajorWidth + 1.0, dMaj.x),
            1.0 - smoothstep(uMajorWidth, uMajorWidth + 1.0, dMaj.y));
    } else if (uStyle == 2) {
        // Dots — only at intersections (both axes close).
        aMinor = 1.0 - smoothstep(uMinorWidth, uMinorWidth + 1.0, length(dMin));
        aMajor = 1.0 - smoothstep(uMajorWidth, uMajorWidth + 1.0, length(dMaj));
    }

    vec4 col = vec4(0.0);
    if (aMajor >= aMinor && aMajor > 0.001) {
        col = vec4(uMajorColor.rgb, uMajorColor.a * aMajor);
    } else if (aMinor > 0.001) {
        col = vec4(uMinorColor.rgb, uMinorColor.a * aMinor);
    }

    // Premultiplied output for blending against the paper-white clear.
    outColor = vec4(col.rgb * col.a, col.a);
}
)";

// ---- Data structures ------------------------------------------------------

struct Sample { float x, y, p; };
struct Stroke { std::vector<Sample> samples; };

struct Tile {
    GLuint texture = 0;
    GLuint fbo     = 0;
};

// Vector-layer primitives. All coordinates are in document pixels.
enum class LayerType : int { Raster = 0, Vector = 1 };

struct Line {
    float    x0, y0;
    float    x1, y1;
    uint32_t color;     // 0xRRGGBB
    float    width;     // full line width in doc pixels
};

struct Layer {
    LayerType type = LayerType::Raster;
    std::unordered_map<int64_t, Tile> tiles;   // populated for raster
    std::vector<Line> lines;                   // populated for vector
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
    GLint  uMode     = -1;
    GLint  uBrushRgb = -1;
};

struct GridProg {
    GLuint program           = 0;
    GLint  uInverseTransform = -1;
    GLint  uSpacing          = -1;
    GLint  uSubdivisions     = -1;
    GLint  uMinorWidth       = -1;
    GLint  uMajorWidth       = -1;
    GLint  uMinorColor       = -1;
    GLint  uMajorColor       = -1;
    GLint  uStyle            = -1;
};

struct LineProg {
    GLuint program    = 0;
    GLint  uTransform = -1;
    GLint  uScreen    = -1;
    GLint  uP0        = -1;
    GLint  uP1        = -1;
    GLint  uHalfWidth = -1;
    GLint  uColor     = -1;
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
GridProg    g_grid;
LineProg    g_lineProg;
GLuint      g_quadVao = 0;
GLuint      g_quadVbo = 0;
bool        g_inited  = false;

// Grid overlay state. Settable from any thread; read at multi-buffer
// composite time. Style = 0 means "use most recent non-zero style"
// internally, but the public setter only sends 1 (lines) or 2 (dots).
std::atomic<int> g_gridEnabled{0};   // 0 = off, 1 = on
std::atomic<int> g_gridStyle{1};     // 1 = lines, 2 = dots

constexpr float kGridSpacing      = 50.0f;       // doc pixels between minor lines
constexpr float kGridSubdivisions = 5.0f;        // major every Nth minor
// Half-widths in doc pixels. Lines look fine at sub-pixel widths since they're
// extended; isolated dots need to be chunkier to read.
constexpr float kGridMinorLineWidth = 0.5f;
constexpr float kGridMajorLineWidth = 1.0f;
constexpr float kGridMinorDotWidth  = 1.5f;
constexpr float kGridMajorDotWidth  = 2.5f;
constexpr float kGridMinorColor[4] = { 0.55f, 0.60f, 0.70f, 0.45f };  // straight RGBA
constexpr float kGridMajorColor[4] = { 0.40f, 0.45f, 0.55f, 0.70f };

// Live eraser preview state. Two layer-stack snapshots and one coverage
// map, all sized to the buffer dimensions and lazily (re)allocated.
//   - belowFbo: paper + layers strictly below active (alpha=1)
//   - aboveFbo: layers strictly above active, premultiplied over transparent
//   - coverage: accumulated erase-coverage alpha as the user drags
ViewFbo g_belowFbo;
ViewFbo g_aboveFbo;
ViewFbo g_coverage;
bool    g_needsPreviewPrep = false;  // set at beginStroke; cleared on first extendStroke

std::vector<std::unique_ptr<Layer>> g_layers;
size_t g_activeLayer  = 0;
size_t g_strokeTarget = 0;          // captured at beginStroke

// Active tool: 0 = brush, 1 = eraser. Settable from any thread (UI thread
// flips it via setTool() on stylus-button press); the GL thread reads it
// at beginStroke into g_strokeTool so a stroke uses one consistent tool
// even if the user toggles mid-stroke.
std::atomic<int> g_currentTool{0};
int g_strokeTool = 0;

// Brush color: RGB packed into low 24 bits (0xRRGGBB). Settable from any
// thread; the GL thread snapshots into g_strokeBrushColor at beginStroke.
// Alpha component of the snapshot is kBrushAlpha.
std::atomic<uint32_t> g_currentBrushColor{0x14171Fu};
float g_strokeBrushColor[4] = { 0.08f, 0.09f, 0.12f, kBrushAlpha };

Stroke     g_current;
struct DabEmitter;                  // forward-decl
extern DabEmitter g_liveEmitter;

std::string g_docDir;               // empty = persistence disabled
bool        g_loaded = false;

// Cross-thread queue: UI-thread layer ops enqueue, GL thread drains at the
// start of each operation.
std::mutex g_pendingMutex;
std::vector<int> g_pendingActions;
constexpr int kActionAddLayer       = 1;
constexpr int kActionCycleActive    = 2;
constexpr int kActionClearActive    = 3;
constexpr int kActionAddVectorLayer = 4;

// Lines added from the UI thread are queued separately because they
// carry data (the Line struct) that doesn't fit in the int-tagged action
// queue. Drained on the GL thread alongside the layer-action queue.
std::mutex        g_pendingLineMutex;
std::vector<Line> g_pendingLines;

constexpr float kDefaultLineWidth = 2.0f;

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

// Forward declarations; defined down with the persistence helpers.
void saveVectorLayer(size_t layerIdx, const Layer& layer);
void loadVectorLayerShapes(Layer& layer, const std::string& dir);

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
        } else if (a == kActionAddVectorLayer) {
            auto layer = std::make_unique<Layer>();
            layer->type = LayerType::Vector;
            g_layers.push_back(std::move(layer));
            g_activeLayer = g_layers.size() - 1;
            LOGI("vector layer added (count=%zu, active=%zu)",
                 g_layers.size(), g_activeLayer);
            // Marker file so loadAllLayersFromDisk recognizes the type
            // even before any line is drawn. saveVectorLayer creates the
            // dir if needed and writes a header with zero shapes.
            saveVectorLayer(g_activeLayer, *g_layers[g_activeLayer]);
        } else if (a == kActionClearActive
                   && g_activeLayer < g_layers.size()
                   && g_layers[g_activeLayer]) {
            Layer& layer = *g_layers[g_activeLayer];
            // Drop GL resources for raster tiles.
            for (auto& kv : layer.tiles) {
                if (kv.second.fbo)     glDeleteFramebuffers(1, &kv.second.fbo);
                if (kv.second.texture) glDeleteTextures(1, &kv.second.texture);
            }
            layer.tiles.clear();
            // Drop vector shapes too.
            layer.lines.clear();
            // Wipe the on-disk copy so the cleared state persists.
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
                // For vector layers, re-create the empty marker so the
                // type is preserved across launches.
                if (layer.type == LayerType::Vector) {
                    saveVectorLayer(g_activeLayer, layer);
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
    g_preview.uMode     = glGetUniformLocation(g_preview.program, "uMode");
    g_preview.uBrushRgb = glGetUniformLocation(g_preview.program, "uBrushRgb");

    g_grid.program           = linkProgram(kGridVS, kGridFS);
    g_grid.uInverseTransform = glGetUniformLocation(g_grid.program, "uInverseTransform");
    g_grid.uSpacing          = glGetUniformLocation(g_grid.program, "uSpacing");
    g_grid.uSubdivisions     = glGetUniformLocation(g_grid.program, "uSubdivisions");
    g_grid.uMinorWidth       = glGetUniformLocation(g_grid.program, "uMinorWidth");
    g_grid.uMajorWidth       = glGetUniformLocation(g_grid.program, "uMajorWidth");
    g_grid.uMinorColor       = glGetUniformLocation(g_grid.program, "uMinorColor");
    g_grid.uMajorColor       = glGetUniformLocation(g_grid.program, "uMajorColor");
    g_grid.uStyle            = glGetUniformLocation(g_grid.program, "uStyle");

    g_lineProg.program    = linkProgram(kLineVS, kLineFS);
    g_lineProg.uTransform = glGetUniformLocation(g_lineProg.program, "uTransform");
    g_lineProg.uScreen    = glGetUniformLocation(g_lineProg.program, "uScreen");
    g_lineProg.uP0        = glGetUniformLocation(g_lineProg.program, "uP0");
    g_lineProg.uP1        = glGetUniformLocation(g_lineProg.program, "uP1");
    g_lineProg.uHalfWidth = glGetUniformLocation(g_lineProg.program, "uHalfWidth");
    g_lineProg.uColor     = glGetUniformLocation(g_lineProg.program, "uColor");

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

// General 4x4 matrix inverse via cofactor expansion (column-major in/out).
// Returns true on success; on a singular matrix, leaves out untouched and
// returns false. Used to map buffer-pixel coords back to document-pixel
// coords for the grid overlay shader.
bool invertMat4(const float* m, float* out) {
    float inv[16];
    inv[0]  =  m[5]*m[10]*m[15] - m[5]*m[11]*m[14] - m[9]*m[6]*m[15] + m[9]*m[7]*m[14] + m[13]*m[6]*m[11] - m[13]*m[7]*m[10];
    inv[4]  = -m[4]*m[10]*m[15] + m[4]*m[11]*m[14] + m[8]*m[6]*m[15] - m[8]*m[7]*m[14] - m[12]*m[6]*m[11] + m[12]*m[7]*m[10];
    inv[8]  =  m[4]*m[9]*m[15]  - m[4]*m[11]*m[13] - m[8]*m[5]*m[15] + m[8]*m[7]*m[13] + m[12]*m[5]*m[11] - m[12]*m[7]*m[9];
    inv[12] = -m[4]*m[9]*m[14]  + m[4]*m[10]*m[13] + m[8]*m[5]*m[14] - m[8]*m[6]*m[13] - m[12]*m[5]*m[10] + m[12]*m[6]*m[9];
    inv[1]  = -m[1]*m[10]*m[15] + m[1]*m[11]*m[14] + m[9]*m[2]*m[15] - m[9]*m[3]*m[14] - m[13]*m[2]*m[11] + m[13]*m[3]*m[10];
    inv[5]  =  m[0]*m[10]*m[15] - m[0]*m[11]*m[14] - m[8]*m[2]*m[15] + m[8]*m[3]*m[14] + m[12]*m[2]*m[11] - m[12]*m[3]*m[10];
    inv[9]  = -m[0]*m[9]*m[15]  + m[0]*m[11]*m[13] + m[8]*m[1]*m[15] - m[8]*m[3]*m[13] - m[12]*m[1]*m[11] + m[12]*m[3]*m[9];
    inv[13] =  m[0]*m[9]*m[14]  - m[0]*m[10]*m[13] - m[8]*m[1]*m[14] + m[8]*m[2]*m[13] + m[12]*m[1]*m[10] - m[12]*m[2]*m[9];
    inv[2]  =  m[1]*m[6]*m[15]  - m[1]*m[7]*m[14]  - m[5]*m[2]*m[15] + m[5]*m[3]*m[14] + m[13]*m[2]*m[7]  - m[13]*m[3]*m[6];
    inv[6]  = -m[0]*m[6]*m[15]  + m[0]*m[7]*m[14]  + m[4]*m[2]*m[15] - m[4]*m[3]*m[14] - m[12]*m[2]*m[7]  + m[12]*m[3]*m[6];
    inv[10] =  m[0]*m[5]*m[15]  - m[0]*m[7]*m[13]  - m[4]*m[1]*m[15] + m[4]*m[3]*m[13] + m[12]*m[1]*m[7]  - m[12]*m[3]*m[5];
    inv[14] = -m[0]*m[5]*m[14]  + m[0]*m[6]*m[13]  + m[4]*m[1]*m[14] - m[4]*m[2]*m[13] - m[12]*m[1]*m[6]  + m[12]*m[2]*m[5];
    inv[3]  = -m[1]*m[6]*m[11]  + m[1]*m[7]*m[10]  + m[5]*m[2]*m[11] - m[5]*m[3]*m[10] - m[9]*m[2]*m[7]   + m[9]*m[3]*m[6];
    inv[7]  =  m[0]*m[6]*m[11]  - m[0]*m[7]*m[10]  - m[4]*m[2]*m[11] + m[4]*m[3]*m[10] + m[8]*m[2]*m[7]   - m[8]*m[3]*m[6];
    inv[11] = -m[0]*m[5]*m[11]  + m[0]*m[7]*m[9]   + m[4]*m[1]*m[11] - m[4]*m[3]*m[9]  - m[8]*m[1]*m[7]   + m[8]*m[3]*m[5];
    inv[15] =  m[0]*m[5]*m[10]  - m[0]*m[6]*m[9]   - m[4]*m[1]*m[10] + m[4]*m[2]*m[9]  + m[8]*m[1]*m[6]   - m[8]*m[2]*m[5];

    float det = m[0]*inv[0] + m[1]*inv[4] + m[2]*inv[8] + m[3]*inv[12];
    if (det == 0.0f) return false;
    float invDet = 1.0f / det;
    for (int i = 0; i < 16; ++i) out[i] = inv[i] * invDet;
    return true;
}

void renderGridOverlay(JNIEnv* env, int width, int height,
                       jfloatArray transform) {
    if (g_gridEnabled.load() == 0) return;

    jfloat* m = env->GetFloatArrayElements(transform, nullptr);
    float invM[16];
    bool ok = invertMat4(m, invM);
    env->ReleaseFloatArrayElements(transform, m, JNI_ABORT);
    if (!ok) return;

    glViewport(0, 0, width, height);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    glUseProgram(g_grid.program);
    glBindVertexArray(g_quadVao);

    int style = g_gridStyle.load();
    glUniformMatrix4fv(g_grid.uInverseTransform, 1, GL_FALSE, invM);
    glUniform1f(g_grid.uSpacing, kGridSpacing);
    glUniform1f(g_grid.uSubdivisions, kGridSubdivisions);
    glUniform1f(g_grid.uMinorWidth,
                style == 2 ? kGridMinorDotWidth : kGridMinorLineWidth);
    glUniform1f(g_grid.uMajorWidth,
                style == 2 ? kGridMajorDotWidth : kGridMajorLineWidth);
    glUniform4fv(g_grid.uMinorColor, 1, kGridMinorColor);
    glUniform4fv(g_grid.uMajorColor, 1, kGridMajorColor);
    glUniform1i(g_grid.uStyle, style);

    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glBindVertexArray(0);
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

// Populate the scratch buffers used by the live-preview composite. Both
// the brush and the eraser paths share the same plumbing — only the
// preview shader's mode + uniforms differ. The active layer is
// intentionally omitted: compositing is linear in any single layer's
// contribution, so the framework's alpha-blend recovers the true
// disp(c) for free as a lerp between multi and fullColor.
void preparePreviewBuffers(JNIEnv* env, int width, int height,
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
        Layer& layer = *g_layers[idx];
        // Detect type by file presence: shapes.bin → Vector; tiles → Raster.
        struct stat st;
        std::string shapesPath = dirPath + "/shapes.bin";
        if (stat(shapesPath.c_str(), &st) == 0) {
            layer.type = LayerType::Vector;
            loadVectorLayerShapes(layer, dirPath);
        } else {
            layer.type = LayerType::Raster;
            loadTilesIntoLayer(layer, dirPath);
        }
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

// ---- Vector-layer persistence --------------------------------------------
//
// Each vector layer is one file: <docDir>/layer_<idx>/shapes.bin. The
// presence of this file is also how loadAllLayersFromDisk recognizes a
// layer as Vector vs Raster, so we always write at least the header
// (4-byte magic + 4-byte shape count) — even for an empty vector layer.

constexpr uint32_t kShapesMagic = 0x30434556u;   // "VEC0" little-endian
constexpr uint8_t  kShapeTypeLine = 1;

void saveVectorLayer(size_t layerIdx, const Layer& layer) {
    if (g_docDir.empty()) return;

    std::string layerDir = g_docDir + "/layer_" + std::to_string(layerIdx);
    if (mkdir(layerDir.c_str(), 0755) != 0 && errno != EEXIST) {
        LOGE("save vector layer %zu: mkdir failed (errno=%d)", layerIdx, errno);
        return;
    }

    std::string path    = layerDir + "/shapes.bin";
    std::string tmpPath = path + ".tmp";

    FILE* f = fopen(tmpPath.c_str(), "wb");
    if (!f) {
        LOGE("save vector layer %zu: fopen failed", layerIdx);
        return;
    }
    uint32_t magic = kShapesMagic;
    uint32_t count = static_cast<uint32_t>(layer.lines.size());
    fwrite(&magic, sizeof(magic), 1, f);
    fwrite(&count, sizeof(count), 1, f);
    for (const auto& l : layer.lines) {
        uint8_t type = kShapeTypeLine;
        fwrite(&type, sizeof(type), 1, f);
        fwrite(&l, sizeof(Line), 1, f);
    }
    fclose(f);
    if (rename(tmpPath.c_str(), path.c_str()) != 0) {
        LOGE("save vector layer %zu: rename failed", layerIdx);
    }
}

void loadVectorLayerShapes(Layer& layer, const std::string& dir) {
    std::string path = dir + "/shapes.bin";
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) return;

    uint32_t magic = 0, count = 0;
    if (fread(&magic, sizeof(magic), 1, f) != 1 || magic != kShapesMagic) {
        LOGE("vector layer at %s: bad magic", dir.c_str());
        fclose(f);
        return;
    }
    if (fread(&count, sizeof(count), 1, f) != 1) {
        fclose(f);
        return;
    }
    layer.lines.reserve(count);
    for (uint32_t i = 0; i < count; ++i) {
        uint8_t type = 0;
        if (fread(&type, sizeof(type), 1, f) != 1) break;
        if (type == kShapeTypeLine) {
            Line l;
            if (fread(&l, sizeof(Line), 1, f) != 1) break;
            layer.lines.push_back(l);
        } else {
            // Unknown shape type — bail rather than mis-parse downstream.
            LOGE("vector layer at %s: unknown shape type %d", dir.c_str(), type);
            break;
        }
    }
    fclose(f);
    LOGI("loaded %zu shapes from %s", layer.lines.size(), dir.c_str());
}

// ---- Pending vector-layer line additions ---------------------------------

void applyPendingLines() {
    std::vector<Line> lines;
    {
        std::lock_guard<std::mutex> lock(g_pendingLineMutex);
        lines.swap(g_pendingLines);
    }
    if (lines.empty()) return;

    // Lines append to whichever layer is active when applied. If the
    // active layer isn't vector, drop them (the line tool shouldn't have
    // committed in the first place; user UI can prevent this).
    if (g_activeLayer >= g_layers.size() || !g_layers[g_activeLayer]) return;
    Layer& layer = *g_layers[g_activeLayer];
    if (layer.type != LayerType::Vector) {
        LOGE("dropping %zu queued lines: active layer %zu is not vector",
             lines.size(), g_activeLayer);
        return;
    }
    for (const Line& l : lines) {
        layer.lines.push_back(l);
    }
    saveVectorLayer(g_activeLayer, layer);
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

    // Brush/eraser are raster operations; they can't bake into a vector
    // layer. Drop the samples so they don't get re-tried on next render
    // and so stale tiles don't end up in the layer's tile map.
    if (layer.type != LayerType::Raster) {
        g_current.samples.clear();
        LOGI("brush/eraser stroke dropped: active layer %zu is vector",
             layerIdx);
        return;
    }

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
        glUniform4fv(g_dab.uColor, 1, g_strokeBrushColor);
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

// Helper: bind the raster compositing pipeline (program + uniforms).
// Reused both at the top of compositeAllLayers and after we temporarily
// switch to the line program for a vector layer.
void bindRasterCompositePipeline(JNIEnv* env, jint width, jint height,
                                 jfloatArray transform) {
    glUseProgram(g_comp.program);
    glBindVertexArray(g_quadVao);
    uploadMat4(env, g_comp.uTransform, transform);
    glUniform2f(g_comp.uScreen, (float)width, (float)height);
    glUniform1f(g_comp.uTileHalf, kTileHalfF);
    glUniform1i(g_comp.uTileTex, 0);
    glActiveTexture(GL_TEXTURE0);
}

void compositeRasterLayer(const Layer& layer) {
    // Caller must have bound the raster pipeline first.
    for (const auto& kv : layer.tiles) {
        int tx, ty;
        unpackTileKey(kv.first, tx, ty);
        float cx = tx * kTileSizeF + kTileHalfF;
        float cy = ty * kTileSizeF + kTileHalfF;
        glBindTexture(GL_TEXTURE_2D, kv.second.texture);
        glUniform2f(g_comp.uTileCenter, cx, cy);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }
}

void compositeVectorLayer(JNIEnv* env, const Layer& layer,
                          jint width, jint height, jfloatArray transform) {
    if (layer.lines.empty()) return;
    glUseProgram(g_lineProg.program);
    glBindVertexArray(g_quadVao);
    uploadMat4(env, g_lineProg.uTransform, transform);
    glUniform2f(g_lineProg.uScreen, (float)width, (float)height);

    for (const auto& l : layer.lines) {
        glUniform2f(g_lineProg.uP0, l.x0, l.y0);
        glUniform2f(g_lineProg.uP1, l.x1, l.y1);
        glUniform1f(g_lineProg.uHalfWidth, l.width * 0.5f);
        float r = ((l.color >> 16) & 0xFFu) / 255.0f;
        float g = ((l.color >>  8) & 0xFFu) / 255.0f;
        float b = ( l.color        & 0xFFu) / 255.0f;
        float c[4] = { r, g, b, 1.0f };
        glUniform4fv(g_lineProg.uColor, 1, c);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }
}

void compositeAllLayers(JNIEnv* env, jint width, jint height,
                        jfloatArray transform) {
    glViewport(0, 0, width, height);
    glClearColor(1.0f, 1.0f, 1.0f, 1.0f);          // paper white
    glClear(GL_COLOR_BUFFER_BIT);

    // Grid is part of the page background — between the paper-white clear
    // and the layer tiles, so user strokes naturally occlude it.
    renderGridOverlay(env, width, height, transform);

    if (g_layers.empty()) return;

    // Premultiplied blend is the global default; both raster tiles and
    // vector lines composite correctly under it.
    glEnable(GL_BLEND);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);

    bindRasterCompositePipeline(env, width, height, transform);

    for (const auto& layer : g_layers) {
        if (!layer) continue;
        if (layer->type == LayerType::Raster) {
            compositeRasterLayer(*layer);
        } else { // Vector
            compositeVectorLayer(env, *layer, width, height, transform);
            // Switch back to raster pipeline for the next raster layer.
            bindRasterCompositePipeline(env, width, height, transform);
        }
    }

    glBindTexture(GL_TEXTURE_2D, 0);
    glBindVertexArray(0);
}

// Renders a single line into the currently-bound framebuffer, used for
// the live preview during the line tool's drag. Clears the buffer first
// so successive previews replace rather than accumulate.
void renderLinePreviewToFront(JNIEnv* env, jint width, jint height,
                              jfloatArray transform,
                              float x0, float y0, float x1, float y1,
                              uint32_t rgb, float lineWidth, float alpha) {
    glViewport(0, 0, width, height);
    glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    glEnable(GL_BLEND);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    glUseProgram(g_lineProg.program);
    glBindVertexArray(g_quadVao);
    uploadMat4(env, g_lineProg.uTransform, transform);
    glUniform2f(g_lineProg.uScreen, (float)width, (float)height);
    glUniform2f(g_lineProg.uP0, x0, y0);
    glUniform2f(g_lineProg.uP1, x1, y1);
    glUniform1f(g_lineProg.uHalfWidth, lineWidth * 0.5f);
    float r = ((rgb >> 16) & 0xFFu) / 255.0f;
    float g = ((rgb >>  8) & 0xFFu) / 255.0f;
    float b = ( rgb        & 0xFFu) / 255.0f;
    float c[4] = { r, g, b, alpha };
    glUniform4fv(g_lineProg.uColor, 1, c);

    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
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
Java_com_bk_drawing_NativeRenderer_setBrushColor(JNIEnv*, jobject, jint rgb) {
    // Mask to 24 bits in case caller passes a packed ARGB; we ignore alpha.
    g_currentBrushColor.store(static_cast<uint32_t>(rgb) & 0x00FFFFFFu);
}

JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_setGridEnabled(JNIEnv*, jobject, jboolean enabled) {
    g_gridEnabled.store(enabled ? 1 : 0);
}

JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_setGridStyle(JNIEnv*, jobject, jint style) {
    // Only 1 (lines) or 2 (dots) are valid; clamp.
    int s = (style == 2) ? 2 : 1;
    g_gridStyle.store(s);
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

JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_addVectorLayer(JNIEnv*, jobject) {
    enqueuePendingAction(kActionAddVectorLayer);
}

// Append a line to the active vector layer. Color (0xRRGGBB) and width
// default to the brush color and a fixed line width if Kotlin passes 0.
JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_addLine(
        JNIEnv*, jobject,
        jfloat x0, jfloat y0, jfloat x1, jfloat y1) {
    Line l;
    l.x0 = x0; l.y0 = y0;
    l.x1 = x1; l.y1 = y1;
    l.color = g_currentBrushColor.load();
    l.width = kDefaultLineWidth;
    {
        std::lock_guard<std::mutex> lock(g_pendingLineMutex);
        g_pendingLines.push_back(l);
    }
}

// Live preview during line-tool drag: renders into the currently-bound
// framebuffer (the front-buffered layer when called from the framework
// callback). Color follows the current brush color.
JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_renderLinePreview(
        JNIEnv* env, jobject,
        jint width, jint height,
        jfloatArray transform,
        jfloat x0, jfloat y0, jfloat x1, jfloat y1) {
    ensureInited();
    uint32_t rgb = g_currentBrushColor.load();
    // Slightly translucent so the preview reads as "in progress".
    renderLinePreviewToFront(env, width, height, transform,
                             x0, y0, x1, y1,
                             rgb, kDefaultLineWidth, /*alpha=*/0.7f);
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
    applyPendingLines();
    ensureAtLeastOneLayer();

    g_strokeTarget = g_activeLayer;
    g_strokeTool   = g_currentTool.load();
    // Snapshot brush RGB so mid-stroke color changes don't split a stroke.
    {
        uint32_t rgb = g_currentBrushColor.load();
        g_strokeBrushColor[0] = ((rgb >> 16) & 0xFFu) / 255.0f;
        g_strokeBrushColor[1] = ((rgb >>  8) & 0xFFu) / 255.0f;
        g_strokeBrushColor[2] = ( rgb        & 0xFFu) / 255.0f;
        g_strokeBrushColor[3] = kBrushAlpha;
    }
    // Both brush and eraser strokes use the WYSIWYG preview path so that
    // strokes appear under layers-above-active correctly. Defer the
    // setup to first extendStroke (we don't have width/height/transform
    // here yet).
    g_needsPreviewPrep = true;
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

    // Both brush and eraser run through the same WYSIWYG preview pipeline:
    // accumulate the dab's coverage into g_coverage, then composite a
    // fullscreen overlay of (fullColor * c, c) into the front buffer. The
    // framework's premultiplied blend over multi yields display(c) =
    // lerp(multi, fullColor, c) — correct under layers above active for
    // either tool. fullColor differs by mode and is computed in the
    // preview shader.

    GLint frontFbo = 0;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &frontFbo);

    if (g_needsPreviewPrep) {
        preparePreviewBuffers(env, width, height, transform);
        g_needsPreviewPrep = false;
    }

    // Step 1: accumulate this dab's coverage into g_coverage. RGB is
    // ignored (kCoverageColor has rgb=0, premultiplied output is (0,0,0,α));
    // only the alpha is sampled by the preview shader.
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

    // Step 2: re-render the front-buffer overlay using the unified
    // preview shader. The mode uniform selects brush vs. eraser fullColor
    // formula; the brushRgb uniform feeds the brush path (un-premult RGB).
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
    glUniform1i(g_preview.uMode,     g_strokeTool);            // 0=brush, 1=eraser
    glUniform3fv(g_preview.uBrushRgb, 1, g_strokeBrushColor);  // 1st 3 floats = RGB
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
    applyPendingLines();
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
    applyPendingLines();
    compositeAllLayers(env, width, height, transform);
}

}  // extern "C"
