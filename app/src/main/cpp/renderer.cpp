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
//
// Coordinate spaces:
//   doc-px:    document coordinates. The natural unit for shapes, tiles,
//              snap targets, and stroke samples. Persistent.
//   view-px:   on-screen pixels in the SurfaceView (MotionEvent coords).
//   buffer-px: pixels of the GL buffer (may be rotated relative to view
//              by the framework on certain device orientations).
//   The `transform` mat4 passed into render JNIs is doc→buffer (Kotlin
//   composes its doc→view view-transform with the framework's view→buffer
//   matrix). Native consumes only this composed form, so 2-finger pan/
//   zoom/rotate doesn't require any native-side coordinate plumbing.
//   View scale is mirrored into g_viewScaleBits via setViewScale so snap
//   radii and selection-handle sizes stay constant in screen-space.

#include <jni.h>
#include <GLES3/gl3.h>
#include <android/log.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
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
out vec2 vDocPos;
uniform mat4  uTransform;
uniform vec2  uScreen;
uniform vec2  uCenter;
uniform float uRadius;
void main() {
    vUv = aQuad;
    // docPos is in the SAME frame as uCenter (tile-local during bake,
    // doc-pixels during live preview); the page-clip rect uniforms must
    // be set in that same frame.
    vec2 docPos = uCenter + aQuad * uRadius;
    vDocPos = docPos;
    vec4 bufPx = uTransform * vec4(docPos, 0.0, 1.0);
    vec2 ndc = (bufPx.xy / uScreen) * 2.0 - 1.0;
    gl_Position = vec4(ndc, 0.0, 1.0);
}
)";

const char* kDabFS = R"(#version 300 es
precision mediump float;
in vec2 vUv;
in vec2 vDocPos;
out vec4 outColor;
uniform vec4 uColor;
uniform vec2 uPageMin;
uniform vec2 uPageMax;
uniform int  uPageActive;     // 0 = no page clip
void main() {
    if (uPageActive != 0 && (
        vDocPos.x < uPageMin.x || vDocPos.x > uPageMax.x ||
        vDocPos.y < uPageMin.y || vDocPos.y > uPageMax.y)) {
        discard;
    }
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
out vec2 vDocPos;          // for page-bounds discard in FS (doc-pixels)
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
    vDocPos = docPos;

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
in vec2 vDocPos;
uniform vec2  uP0;
uniform vec2  uP1;
uniform float uHalfWidth;
uniform vec4  uColor;        // straight RGBA (premultiplied at output)
uniform vec2  uPageMin;
uniform vec2  uPageMax;
uniform int   uPageActive;
out vec4 outColor;
void main() {
    if (uPageActive != 0 && (
        vDocPos.x < uPageMin.x || vDocPos.x > uPageMax.x ||
        vDocPos.y < uPageMin.y || vDocPos.y > uPageMax.y)) {
        discard;
    }
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
uniform vec2  uPageMin;
uniform vec2  uPageMax;
uniform int   uPageActive;
out vec4 outColor;

void main() {
    vec2 docPos = (uInverseTransform * vec4(gl_FragCoord.xy, 0.0, 1.0)).xy;
    if (uPageActive != 0 && (
        docPos.x < uPageMin.x || docPos.x > uPageMax.x ||
        docPos.y < uPageMin.y || docPos.y > uPageMax.y)) {
        discard;
    }

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

// Solid-color fill of an axis-aligned doc-coord rectangle. Used to paint
// the page-area paper-white over the gray (off-canvas) clear.
const char* kFillVS = R"(#version 300 es
layout(location = 0) in vec2 aQuad;
uniform mat4 uTransform;
uniform vec2 uScreen;
uniform vec2 uMin;
uniform vec2 uMax;
void main() {
    vec2 t = aQuad * 0.5 + 0.5;
    vec2 docPos = mix(uMin, uMax, t);
    vec4 bufPx  = uTransform * vec4(docPos, 0.0, 1.0);
    vec2 ndc = (bufPx.xy / uScreen) * 2.0 - 1.0;
    gl_Position = vec4(ndc, 0.0, 1.0);
}
)";

const char* kFillFS = R"(#version 300 es
precision mediump float;
uniform vec4 uFillColor;       // straight RGBA, opaque expected
out vec4 outColor;
void main() {
    outColor = uFillColor;
}
)";

// ---- Data structures ------------------------------------------------------

struct Sample { float x, y, p; };
struct Stroke { std::vector<Sample> samples; };

struct Tile {
    GLuint texture = 0;
    GLuint fbo     = 0;
};

// Vector-layer primitives. All coordinates are in document pixels. Each
// struct is plain-old-data so we can fwrite it byte-for-byte during
// persistence. If you change a layout, bump kShapesMagic.
enum class LayerType : int { Raster = 0, Vector = 1 };

struct Line {
    float    x0, y0;
    float    x1, y1;
    uint32_t color;     // 0xRRGGBB
    float    width;     // full line width in doc pixels
};

struct Rect {
    float    x0, y0;    // axis-aligned bbox in shape-local frame (rotation
    float    x1, y1;    //   = 0 means these are also world-space corners).
    float    rotation;  // radians, applied around the bbox center.
    uint32_t color;
    float    width;
};

struct Ellipse {
    float    cx, cy;    // center
    float    rx, ry;    // semi-axes (in shape-local frame)
    float    rotation;  // radians, applied around the center
    uint32_t color;
    float    width;
};

struct Circle {
    float    cx, cy;    // center
    float    radius;
    uint32_t color;
    float    width;
};

struct Layer {
    LayerType type = LayerType::Raster;
    std::unordered_map<int64_t, Tile> tiles;   // populated for raster
    // Vector-layer shape lists (populated for vector). Kept as separate
    // typed vectors rather than a tagged union — shape counts are small
    // and per-type iteration in the compositor is cleaner.
    std::vector<Line>    lines;
    std::vector<Rect>    rects;
    std::vector<Ellipse> ellipses;
    std::vector<Circle>  circles;
};

struct DabProg {
    GLuint program    = 0;
    GLint  uTransform = -1;
    GLint  uScreen    = -1;
    GLint  uCenter    = -1;
    GLint  uRadius    = -1;
    GLint  uColor     = -1;
    GLint  uPageMin    = -1;
    GLint  uPageMax    = -1;
    GLint  uPageActive = -1;
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
    GLint  uPageMin          = -1;
    GLint  uPageMax          = -1;
    GLint  uPageActive       = -1;
};

struct LineProg {
    GLuint program    = 0;
    GLint  uTransform = -1;
    GLint  uScreen    = -1;
    GLint  uP0        = -1;
    GLint  uP1        = -1;
    GLint  uHalfWidth = -1;
    GLint  uColor     = -1;
    GLint  uPageMin    = -1;
    GLint  uPageMax    = -1;
    GLint  uPageActive = -1;
};

struct FillProg {
    GLuint program    = 0;
    GLint  uTransform = -1;
    GLint  uScreen    = -1;
    GLint  uMin       = -1;
    GLint  uMax       = -1;
    GLint  uFillColor = -1;
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
FillProg    g_fill;
GLuint      g_quadVao = 0;
GLuint      g_quadVbo = 0;
bool        g_inited  = false;

// Grid overlay state. Settable from any thread; read at multi-buffer
// composite time. Style = 0 means "use most recent non-zero style"
// internally, but the public setter only sends 1 (lines) or 2 (dots).
std::atomic<int> g_gridEnabled{0};   // 0 = off, 1 = on
std::atomic<int> g_gridStyle{1};     // 1 = lines, 2 = dots

// Snapping is on by default. Settable from any thread.
std::atomic<int> g_snapEnabled{1};

// Page bounds in doc-pixels — a fixed rectangle drawn during composite
// to give the user a visual anchor when zoomed/rotated. Optional;
// disabled when w/h are 0. Set from Kotlin via setPageBounds. Stored
// under a mutex (the rect's 4 floats need to update atomically together).
std::mutex g_pageBoundsMutex;
float      g_pageX0 = 0.0f, g_pageY0 = 0.0f;
float      g_pageX1 = 0.0f, g_pageY1 = 0.0f;

struct PageClip {
    bool  active;
    float minX, minY, maxX, maxY;
};

PageClip readPageClip() {
    PageClip out;
    std::lock_guard<std::mutex> lock(g_pageBoundsMutex);
    out.minX = g_pageX0; out.minY = g_pageY0;
    out.maxX = g_pageX1; out.maxY = g_pageY1;
    out.active = (out.maxX > out.minX && out.maxY > out.minY);
    return out;
}

// Apply the page-clip uniforms to the currently-bound program. The
// caller passes the program's uPageMin/Max/Active locations and the
// page rect in whatever coord frame the program's vDocPos varying uses
// (tile-local for bake, doc-pixels everywhere else).
void uploadPageClip(GLint locMin, GLint locMax, GLint locActive,
                    const PageClip& p) {
    if (locActive >= 0) glUniform1i(locActive, p.active ? 1 : 0);
    if (p.active) {
        if (locMin >= 0) glUniform2f(locMin, p.minX, p.minY);
        if (locMax >= 0) glUniform2f(locMax, p.maxX, p.maxY);
    }
}

// Current view-zoom factor (doc-px per view-px). Set from Kotlin whenever
// the 2-finger gesture changes scale; used to keep snap/hit-test radii
// screen-relative — otherwise zooming out would make snap useless and
// zooming in would make it overshoot. Stored as raw bits in an atomic
// uint32 to avoid std::atomic<float> on platforms where it requires
// special linkage.
std::atomic<uint32_t> g_viewScaleBits{0x3F800000u};   // 1.0f
inline float currentViewScale() {
    uint32_t bits = g_viewScaleBits.load();
    float f;
    std::memcpy(&f, &bits, sizeof(f));
    return f > 1e-6f ? f : 1.0f;
}

// All values below are *view-pixel* targets — divided by currentViewScale()
// at use time to get the equivalent doc-pixel radius/threshold.
constexpr float    kSnapRadiusViewPx   = 20.0f;
constexpr uint32_t kSnapMarkerColor    = 0xFFC020u;       // amber
constexpr float    kSnapMarkerRViewPx  = 9.0f;            // ring radius (view px)

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
constexpr int kActionUndo           = 5;
constexpr int kActionRedo           = 6;

// Shapes added from the UI thread are queued separately because they
// carry per-shape data that doesn't fit in the int-tagged action queue.
// Drained on the GL thread alongside the layer-action queue. One mutex
// covers all four queues — adds are infrequent and the lock is brief.
std::mutex           g_pendingShapesMutex;
std::vector<Line>    g_pendingLines;
std::vector<Rect>    g_pendingRects;
std::vector<Ellipse> g_pendingEllipses;
std::vector<Circle>  g_pendingCircles;

// Current selection — at most one shape on a vector layer. Mutated from
// the UI thread (tap to select) and read from the GL thread (highlight
// on composite, transforms during drag). Mutex-protected.
enum class ShapeKind : int {
    None = 0,
    Line = 1,
    Rect = 2,
    Ellipse = 3,
    Circle = 4,
};

struct Selection {
    ShapeKind kind     = ShapeKind::None;
    size_t    layerIdx = 0;
    size_t    shapeIdx = 0;
};

std::mutex g_selectionMutex;
Selection  g_selection;

// Active drag interaction state (for SELECT-tool gestures). Only valid
// when g_selection.kind != None and an interaction is in progress.
// Mutex-protected by g_selectionMutex.
enum class DragMode : int {
    None = 0,
    Move = 1,
    Scale = 2,
    Rotate = 3,
};
struct DragState {
    DragMode mode = DragMode::None;
    int      handleIdx = 0;          // for Scale: 0..3 (or 0..1 for Line)
    // Scale: world-space anchor (opposite handle) and initial OBB
    // rotation, snapshotted at drag start so subsequent moves don't
    // accumulate float drift.
    float    anchorX = 0.0f, anchorY = 0.0f;
    float    initialRotation = 0.0f;
    // Rotate: shape center (fixed), initial pen-to-center angle, and the
    // shape's initial rotation. Also a snapshot of the initial Line
    // endpoints (for rotating Lines, which have no rotation field).
    float    centerX = 0.0f, centerY = 0.0f;
    float    initialPenAngle = 0.0f;
    Line     initialLine{};
    // Move: offset from pen to shape center, captured at drag start.
    // The shape's center tracks (pen − offset) so the user's grab-point
    // follows the pen. Snap is applied to the would-be center.
    float    moveOffsetX = 0.0f, moveOffsetY = 0.0f;
    // Snap indicator state, set by transforms when a snap is engaged.
    // Read by compositeAllLayers to draw an amber marker.
    bool     snapActive = false;
    float    snapX = 0.0f, snapY = 0.0f;
};
DragState g_drag;

// ---- Undo / redo ---------------------------------------------------------
//
// Single global stack of reversible actions. Entries are pushed at the
// point each mutation is realized (so e.g. queued vector-shape adds push
// from applyPendingShapes after they actually land in g_layers, not from
// the JNI thread when they're queued). Bounded by entry count and total
// memory; oldest entries evict first.
//
// Threading: pushes happen from the GL thread (commitStroke, applyPending*,
// applyUndo) and the UI thread (deleteSelection, end of a transform drag).
// All access is protected by g_undoMutex. The actual undo() / redo() JNI
// calls just enqueue a kActionUndo/Redo into the pending-action queue;
// the GL thread runs the inverse mutation in applyPendingLayerActions so
// GL state stays single-threaded.

enum class UndoOp : int {
    RasterStroke = 0,   // tile snapshots before/after a stroke bake
    VectorAdd,          // shape was appended to a vector layer
    VectorDelete,       // shape was removed from a vector layer
    VectorMutate,       // shape was transformed (move/scale/rotate)
    LayerClear,         // active layer was cleared
    LayerAdd,           // a new layer was appended
};

struct TileSnap {
    int  tx = 0, ty = 0;
    bool existed = false;            // tile present at snapshot time
    std::vector<uint8_t> bytes;      // size = kTileBytes when existed; else empty
};

struct ShapeData {
    ShapeKind kind = ShapeKind::None;
    Line    line{};
    Rect    rect{};
    Ellipse ellipse{};
    Circle  circle{};
};

struct UndoEntry {
    UndoOp op = UndoOp::RasterStroke;
    size_t layerIdx = 0;

    // RasterStroke: tile state before / after the bake (snapshots cover
    //   the same tx,ty grid in both arrays in the same order).
    // LayerClear:   beforeTiles holds the pre-clear tile state (raster).
    std::vector<TileSnap> beforeTiles;
    std::vector<TileSnap> afterTiles;

    // VectorAdd:    afterShape  = pushed shape; shapeIdx = its index.
    // VectorDelete: beforeShape = removed shape; shapeIdx = original index.
    // VectorMutate: beforeShape / afterShape; shapeIdx = the shape's index.
    ShapeData beforeShape;
    ShapeData afterShape;
    size_t    shapeIdx = 0;

    // LayerClear (vector path): full pre-clear shape lists.
    std::vector<Line>    beforeLines;
    std::vector<Rect>    beforeRects;
    std::vector<Ellipse> beforeEllipses;
    std::vector<Circle>  beforeCircles;
    LayerType            layerTypeBefore = LayerType::Raster;

    // LayerAdd: type of the layer that was appended; previous active idx.
    LayerType addedLayerType  = LayerType::Raster;
    size_t    prevActiveLayer = 0;

    size_t bytes = 0;                // approximate memory cost
};

constexpr size_t kMaxUndoEntries = 50;
constexpr size_t kMaxUndoBytes   = 200u * 1024u * 1024u;   // combined cap

std::mutex            g_undoMutex;
std::deque<UndoEntry> g_undoStack;
std::deque<UndoEntry> g_redoStack;
size_t                g_undoTotalBytes = 0;
size_t                g_redoTotalBytes = 0;

// Drag-scoped pre-transform shape snapshot. Captured at beginInteractionAt
// and consumed at endInteraction to build a VectorMutate entry. Both are
// guarded by g_selectionMutex.
Selection g_transformBeforeSel;
ShapeData g_transformBeforeShape;

size_t computeEntrySize(const UndoEntry& e) {
    size_t s = sizeof(UndoEntry);
    for (const auto& t : e.beforeTiles) s += t.bytes.size();
    for (const auto& t : e.afterTiles)  s += t.bytes.size();
    s += e.beforeLines.size()    * sizeof(Line);
    s += e.beforeRects.size()    * sizeof(Rect);
    s += e.beforeEllipses.size() * sizeof(Ellipse);
    s += e.beforeCircles.size()  * sizeof(Circle);
    return s;
}

void clearRedoStack_locked() {
    g_redoTotalBytes = 0;
    g_redoStack.clear();
}

// Drop oldest entries until under both the count and byte budgets.
void enforceUndoBudget_locked() {
    while ((g_undoStack.size() > kMaxUndoEntries
            || g_undoTotalBytes + g_redoTotalBytes > kMaxUndoBytes)
           && !g_undoStack.empty()) {
        g_undoTotalBytes -= g_undoStack.front().bytes;
        g_undoStack.pop_front();
    }
}

// Push a fresh action onto the undo stack. Clears the redo stack (any
// re-do history is invalidated by a new mutation).
void pushUndoEntry(UndoEntry e) {
    e.bytes = computeEntrySize(e);
    std::lock_guard<std::mutex> lock(g_undoMutex);
    clearRedoStack_locked();
    g_undoTotalBytes += e.bytes;
    g_undoStack.push_back(std::move(e));
    enforceUndoBudget_locked();
}

bool shapeDataEqual(const ShapeData& a, const ShapeData& b) {
    if (a.kind != b.kind) return false;
    switch (a.kind) {
        case ShapeKind::Line:    return std::memcmp(&a.line,    &b.line,    sizeof(Line))    == 0;
        case ShapeKind::Rect:    return std::memcmp(&a.rect,    &b.rect,    sizeof(Rect))    == 0;
        case ShapeKind::Ellipse: return std::memcmp(&a.ellipse, &b.ellipse, sizeof(Ellipse)) == 0;
        case ShapeKind::Circle:  return std::memcmp(&a.circle,  &b.circle,  sizeof(Circle))  == 0;
        case ShapeKind::None:    return true;
    }
    return true;
}

// Snapshot the active selection's shape into a ShapeData (used at drag
// start and drag end for VectorMutate entries). Returns false if there's
// no selection or the layer is gone.
bool snapshotSelectionShape(const Selection& sel, ShapeData& out) {
    out.kind = ShapeKind::None;
    if (sel.kind == ShapeKind::None) return false;
    if (sel.layerIdx >= g_layers.size() || !g_layers[sel.layerIdx]) return false;
    const Layer& layer = *g_layers[sel.layerIdx];
    out.kind = sel.kind;
    switch (sel.kind) {
        case ShapeKind::Line:
            if (sel.shapeIdx >= layer.lines.size()) return false;
            out.line = layer.lines[sel.shapeIdx]; return true;
        case ShapeKind::Rect:
            if (sel.shapeIdx >= layer.rects.size()) return false;
            out.rect = layer.rects[sel.shapeIdx]; return true;
        case ShapeKind::Ellipse:
            if (sel.shapeIdx >= layer.ellipses.size()) return false;
            out.ellipse = layer.ellipses[sel.shapeIdx]; return true;
        case ShapeKind::Circle:
            if (sel.shapeIdx >= layer.circles.size()) return false;
            out.circle = layer.circles[sel.shapeIdx]; return true;
        case ShapeKind::None:
            return false;
    }
    return false;
}

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
    // Optional clip bounds (in the same coord frame extend() is called in).
    // Dabs whose square footprint lies entirely outside these bounds are
    // skipped — saving the GL draw call. Used by bake (per-tile bounds);
    // live preview leaves the bounds at +/-inf so all dabs render.
    float clipMinX = -1e30f, clipMinY = -1e30f;
    float clipMaxX =  1e30f, clipMaxY =  1e30f;

    void reset() {
        active = false;
        distToNextDab = 0.0f;
        clipMinX = clipMinY = -1e30f;
        clipMaxX = clipMaxY =  1e30f;
    }

    void setClipBounds(float minX, float minY, float maxX, float maxY) {
        clipMinX = minX; clipMinY = minY;
        clipMaxX = maxX; clipMaxY = maxY;
    }

    void emit(float x, float y, float radius) {
        if (x + radius < clipMinX || x - radius > clipMaxX ||
            y + radius < clipMinY || y - radius > clipMaxY) {
            return;
        }
        drawDab(x, y, radius);
    }

    void extend(float x, float y, float p) {
        if (!active) {
            emit(x, y, radiusOf(p));
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
            emit(dabX, dabY, radiusOf(dabP));
            distToNextDab = kSpacing * radiusOf(dabP);
        }
        distToNextDab -= (dist - traveled);
        lastX = x; lastY = y; lastP = p;
    }
};

DabEmitter g_liveEmitter;

// Forward declarations; defined down with the persistence and composite
// helpers.
void saveVectorLayer(size_t layerIdx, const Layer& layer);
void loadVectorLayerShapes(Layer& layer, const std::string& dir);
void saveTileToDisk(size_t layerIdx, int64_t tileK);
void writeTileBytesToDisk(size_t layerIdx, int tx, int ty,
                          const uint8_t* bytes);
void snapshotAllTiles(size_t layerIdx, std::vector<TileSnap>& out);
void snapshotTilesInBbox(size_t layerIdx, int tx0, int tx1, int ty0, int ty1,
                         std::vector<TileSnap>& out);
void uploadTileBytesAndSave(size_t layerIdx, int tx, int ty,
                            const uint8_t* bytes);
void deleteTileIfExists(size_t layerIdx, int tx, int ty);
void applyTileSnap(size_t layerIdx, const TileSnap& snap);
void deleteLayerDirIfExists(size_t layerIdx);
void applyUndo();
void applyRedo();
void applyPendingShapes();
void bindRasterCompositePipeline(JNIEnv* env, jint width, jint height,
                                 jfloatArray transform);
void compositeRasterLayer(const Layer& layer);
void compositeVectorLayer(JNIEnv* env, const Layer& layer, size_t layerIdx,
                          jint width, jint height, jfloatArray transform);

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
            size_t prevActive = g_activeLayer;
            g_layers.push_back(std::make_unique<Layer>());
            g_activeLayer = g_layers.size() - 1;
            LOGI("layer added (count=%zu, active=%zu)",
                 g_layers.size(), g_activeLayer);
            UndoEntry e;
            e.op = UndoOp::LayerAdd;
            e.layerIdx = g_activeLayer;
            e.addedLayerType = LayerType::Raster;
            e.prevActiveLayer = prevActive;
            pushUndoEntry(std::move(e));
        } else if (a == kActionCycleActive && !g_layers.empty()) {
            g_activeLayer = (g_activeLayer + 1) % g_layers.size();
            LOGI("active layer cycled to %zu/%zu",
                 g_activeLayer, g_layers.size() - 1);
        } else if (a == kActionAddVectorLayer) {
            size_t prevActive = g_activeLayer;
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
            UndoEntry e;
            e.op = UndoOp::LayerAdd;
            e.layerIdx = g_activeLayer;
            e.addedLayerType = LayerType::Vector;
            e.prevActiveLayer = prevActive;
            pushUndoEntry(std::move(e));
        } else if (a == kActionClearActive
                   && g_activeLayer < g_layers.size()
                   && g_layers[g_activeLayer]) {
            Layer& layer = *g_layers[g_activeLayer];
            // Snapshot pre-clear state for undo (raster tiles or vector
            // shapes, depending on layer type).
            UndoEntry undo;
            undo.op = UndoOp::LayerClear;
            undo.layerIdx = g_activeLayer;
            undo.layerTypeBefore = layer.type;
            if (layer.type == LayerType::Raster) {
                snapshotAllTiles(g_activeLayer, undo.beforeTiles);
            } else {
                undo.beforeLines    = layer.lines;
                undo.beforeRects    = layer.rects;
                undo.beforeEllipses = layer.ellipses;
                undo.beforeCircles  = layer.circles;
            }
            bool somethingToUndo = !undo.beforeTiles.empty()
                                || !undo.beforeLines.empty()
                                || !undo.beforeRects.empty()
                                || !undo.beforeEllipses.empty()
                                || !undo.beforeCircles.empty();
            // Drop GL resources for raster tiles.
            for (auto& kv : layer.tiles) {
                if (kv.second.fbo)     glDeleteFramebuffers(1, &kv.second.fbo);
                if (kv.second.texture) glDeleteTextures(1, &kv.second.texture);
            }
            layer.tiles.clear();
            // Drop all vector shapes too.
            layer.lines.clear();
            layer.rects.clear();
            layer.ellipses.clear();
            layer.circles.clear();
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
            if (somethingToUndo) pushUndoEntry(std::move(undo));
        } else if (a == kActionUndo) {
            // Realize any queued shapes first so they end up on the undo
            // stack and can themselves be undone in the natural order.
            applyPendingShapes();
            applyUndo();
        } else if (a == kActionRedo) {
            applyPendingShapes();
            applyRedo();
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
    g_dab.uPageMin    = glGetUniformLocation(g_dab.program, "uPageMin");
    g_dab.uPageMax    = glGetUniformLocation(g_dab.program, "uPageMax");
    g_dab.uPageActive = glGetUniformLocation(g_dab.program, "uPageActive");

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
    g_grid.uPageMin          = glGetUniformLocation(g_grid.program, "uPageMin");
    g_grid.uPageMax          = glGetUniformLocation(g_grid.program, "uPageMax");
    g_grid.uPageActive       = glGetUniformLocation(g_grid.program, "uPageActive");

    g_lineProg.program    = linkProgram(kLineVS, kLineFS);
    g_lineProg.uTransform = glGetUniformLocation(g_lineProg.program, "uTransform");
    g_lineProg.uScreen    = glGetUniformLocation(g_lineProg.program, "uScreen");
    g_lineProg.uP0        = glGetUniformLocation(g_lineProg.program, "uP0");
    g_lineProg.uP1        = glGetUniformLocation(g_lineProg.program, "uP1");
    g_lineProg.uHalfWidth = glGetUniformLocation(g_lineProg.program, "uHalfWidth");
    g_lineProg.uColor     = glGetUniformLocation(g_lineProg.program, "uColor");
    g_lineProg.uPageMin    = glGetUniformLocation(g_lineProg.program, "uPageMin");
    g_lineProg.uPageMax    = glGetUniformLocation(g_lineProg.program, "uPageMax");
    g_lineProg.uPageActive = glGetUniformLocation(g_lineProg.program, "uPageActive");

    g_fill.program    = linkProgram(kFillVS, kFillFS);
    g_fill.uTransform = glGetUniformLocation(g_fill.program, "uTransform");
    g_fill.uScreen    = glGetUniformLocation(g_fill.program, "uScreen");
    g_fill.uMin       = glGetUniformLocation(g_fill.program, "uMin");
    g_fill.uMax       = glGetUniformLocation(g_fill.program, "uMax");
    g_fill.uFillColor = glGetUniformLocation(g_fill.program, "uFillColor");

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

// Composite the layers in [startIdx, endExclusive) into target FBO,
// dispatching by layer type so both raster tiles and vector shapes get
// rendered. If clearWhite is true the FBO is first cleared to opaque
// paper-white; otherwise to transparent. Result is premultiplied either
// way. Blends with GL_ONE / GL_ONE_MINUS_SRC_ALPHA throughout.
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

    glEnable(GL_BLEND);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    bindRasterCompositePipeline(env, width, height, transform);

    for (size_t i = startIdx; i < endExclusive && i < g_layers.size(); ++i) {
        if (!g_layers[i]) continue;
        if (g_layers[i]->type == LayerType::Raster) {
            compositeRasterLayer(*g_layers[i]);
        } else { // Vector
            compositeVectorLayer(env, *g_layers[i], i, width, height, transform);
            // compositeVectorLayer leaves the line program bound; restore
            // the raster pipeline for the next iteration.
            bindRasterCompositePipeline(env, width, height, transform);
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

// Snapshot every tile in the inclusive bbox (tx0..tx1, ty0..ty1) of the
// given layer into `out`. Tiles that don't currently exist are recorded
// with `existed=false` and zero bytes (so undo of a stroke that created
// new tiles deletes them rather than leaving zero-alpha leftovers). Tile
// pixels are read via the tile's FBO with glReadPixels.
void snapshotTilesInBbox(size_t layerIdx, int tx0, int tx1, int ty0, int ty1,
                         std::vector<TileSnap>& out) {
    out.clear();
    if (layerIdx >= g_layers.size() || !g_layers[layerIdx]) return;
    Layer& layer = *g_layers[layerIdx];
    if (layer.type != LayerType::Raster) return;
    GLint prevFbo = 0;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prevFbo);
    for (int ty = ty0; ty <= ty1; ++ty) {
        for (int tx = tx0; tx <= tx1; ++tx) {
            TileSnap snap;
            snap.tx = tx; snap.ty = ty;
            auto it = layer.tiles.find(tileKey(tx, ty));
            if (it != layer.tiles.end()) {
                snap.existed = true;
                snap.bytes.resize(kTileBytes);
                glBindFramebuffer(GL_FRAMEBUFFER, it->second.fbo);
                glReadPixels(0, 0, kTileSize, kTileSize, GL_RGBA, GL_UNSIGNED_BYTE,
                             snap.bytes.data());
            }
            out.push_back(std::move(snap));
        }
    }
    glBindFramebuffer(GL_FRAMEBUFFER, prevFbo);
}

// Snapshot every existing tile in the layer (for full-layer-clear undo).
void snapshotAllTiles(size_t layerIdx, std::vector<TileSnap>& out) {
    out.clear();
    if (layerIdx >= g_layers.size() || !g_layers[layerIdx]) return;
    Layer& layer = *g_layers[layerIdx];
    if (layer.type != LayerType::Raster) return;
    GLint prevFbo = 0;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prevFbo);
    out.reserve(layer.tiles.size());
    for (const auto& kv : layer.tiles) {
        TileSnap snap;
        unpackTileKey(kv.first, snap.tx, snap.ty);
        snap.existed = true;
        snap.bytes.resize(kTileBytes);
        glBindFramebuffer(GL_FRAMEBUFFER, kv.second.fbo);
        glReadPixels(0, 0, kTileSize, kTileSize, GL_RGBA, GL_UNSIGNED_BYTE,
                     snap.bytes.data());
        out.push_back(std::move(snap));
    }
    glBindFramebuffer(GL_FRAMEBUFFER, prevFbo);
}

// Upload bytes into a tile's texture (creating it if necessary), then
// persist to disk. Used by undo/redo to restore tile state.
//
// Save+restore the FBO binding so this is safe to call from inside the
// pending-action drain at the start of compositeAllLayers, where the
// caller's bound FBO is the multi-buffer and any leak would cause the
// subsequent clear/grid/composite to write into a tile FBO instead.
// (getOrCreateTile binds the new tile's FBO during its clear path.)
void uploadTileBytesAndSave(size_t layerIdx, int tx, int ty,
                            const uint8_t* bytes) {
    if (layerIdx >= g_layers.size() || !g_layers[layerIdx]) return;
    Layer& layer = *g_layers[layerIdx];
    GLint prevFbo = 0;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prevFbo);
    Tile& tile = getOrCreateTile(layer, tx, ty);
    glBindTexture(GL_TEXTURE_2D, tile.texture);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, kTileSize, kTileSize,
                    GL_RGBA, GL_UNSIGNED_BYTE, bytes);
    glBindTexture(GL_TEXTURE_2D, 0);
    saveTileToDisk(layerIdx, tileKey(tx, ty));
    glBindFramebuffer(GL_FRAMEBUFFER, prevFbo);
}

// Drop a tile's GL resources, remove it from the layer's map, and unlink
// its on-disk file. No-op if the tile isn't present.
void deleteTileIfExists(size_t layerIdx, int tx, int ty) {
    if (layerIdx >= g_layers.size() || !g_layers[layerIdx]) return;
    Layer& layer = *g_layers[layerIdx];
    int64_t k = tileKey(tx, ty);
    auto it = layer.tiles.find(k);
    if (it == layer.tiles.end()) {
        // Even if no GPU tile, an orphan disk file from a partially-saved
        // state should still be cleaned up; harmless if absent.
        if (!g_docDir.empty()) {
            char path[1024];
            snprintf(path, sizeof(path), "%s/layer_%zu/tile_%d_%d.bin",
                     g_docDir.c_str(), layerIdx, tx, ty);
            unlink(path);
        }
        return;
    }
    if (it->second.fbo)     glDeleteFramebuffers(1, &it->second.fbo);
    if (it->second.texture) glDeleteTextures(1, &it->second.texture);
    layer.tiles.erase(it);
    if (!g_docDir.empty()) {
        char path[1024];
        snprintf(path, sizeof(path), "%s/layer_%zu/tile_%d_%d.bin",
                 g_docDir.c_str(), layerIdx, tx, ty);
        unlink(path);
    }
}

// Apply one tile snapshot (existed=true → upload bytes; false → delete).
void applyTileSnap(size_t layerIdx, const TileSnap& snap) {
    if (snap.existed) {
        uploadTileBytesAndSave(layerIdx, snap.tx, snap.ty, snap.bytes.data());
    } else {
        deleteTileIfExists(layerIdx, snap.tx, snap.ty);
    }
}

// Compute the tile-space bbox a stroke's samples will touch, the same
// way bakeCurrentStrokeIntoTiles does. Returns false if there are no
// samples (caller should skip snapshotting).
bool currentStrokeTileBbox(int& tx0, int& tx1, int& ty0, int& ty1) {
    if (g_current.samples.empty()) return false;
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
    tx0 = static_cast<int>(std::floor(minX / kTileSizeF));
    tx1 = static_cast<int>(std::floor(maxX / kTileSizeF));
    ty0 = static_cast<int>(std::floor(minY / kTileSizeF));
    ty1 = static_cast<int>(std::floor(maxY / kTileSizeF));
    return true;
}

// Wipe the on-disk dir for a layer (used when undoing a layer add to
// remove stranded shapes.bin / tile files).
void deleteLayerDirIfExists(size_t layerIdx) {
    if (g_docDir.empty()) return;
    std::string layerDir = g_docDir + "/layer_" + std::to_string(layerIdx);
    DIR* d = opendir(layerDir.c_str());
    if (!d) return;
    struct dirent* e;
    while ((e = readdir(d)) != nullptr) {
        const char* n = e->d_name;
        if (n[0] == '.') continue;
        std::string p = layerDir + "/" + n;
        unlink(p.c_str());
    }
    closedir(d);
    rmdir(layerDir.c_str());
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

constexpr uint32_t kShapesMagicV0   = 0x30434556u;   // "VEC0" — pre-rotation
constexpr uint32_t kShapesMagicV1   = 0x31434556u;   // "VEC1" — Rect/Ellipse have rotation
constexpr uint8_t  kShapeTypeLine    = 1;
constexpr uint8_t  kShapeTypeRect    = 2;
constexpr uint8_t  kShapeTypeEllipse = 3;
constexpr uint8_t  kShapeTypeCircle  = 4;

// Pre-rotation struct layouts, used only for migrating V0 files. Keep
// these byte-for-byte identical to what V0 was writing.
struct RectV0 {
    float    x0, y0;
    float    x1, y1;
    uint32_t color;
    float    width;
};
struct EllipseV0 {
    float    cx, cy;
    float    rx, ry;
    uint32_t color;
    float    width;
};

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
    uint32_t magic = kShapesMagicV1;
    uint32_t count = static_cast<uint32_t>(
        layer.lines.size() + layer.rects.size()
        + layer.ellipses.size() + layer.circles.size());
    fwrite(&magic, sizeof(magic), 1, f);
    fwrite(&count, sizeof(count), 1, f);
    for (const auto& l : layer.lines) {
        uint8_t t = kShapeTypeLine;    fwrite(&t, 1, 1, f); fwrite(&l, sizeof(Line),    1, f);
    }
    for (const auto& r : layer.rects) {
        uint8_t t = kShapeTypeRect;    fwrite(&t, 1, 1, f); fwrite(&r, sizeof(Rect),    1, f);
    }
    for (const auto& e : layer.ellipses) {
        uint8_t t = kShapeTypeEllipse; fwrite(&t, 1, 1, f); fwrite(&e, sizeof(Ellipse), 1, f);
    }
    for (const auto& c : layer.circles) {
        uint8_t t = kShapeTypeCircle;  fwrite(&t, 1, 1, f); fwrite(&c, sizeof(Circle),  1, f);
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
    if (fread(&magic, sizeof(magic), 1, f) != 1
        || (magic != kShapesMagicV0 && magic != kShapesMagicV1)) {
        LOGE("vector layer at %s: bad magic 0x%x", dir.c_str(), magic);
        fclose(f);
        return;
    }
    bool migrate = (magic == kShapesMagicV0);
    if (fread(&count, sizeof(count), 1, f) != 1) {
        fclose(f);
        return;
    }
    for (uint32_t i = 0; i < count; ++i) {
        uint8_t type = 0;
        if (fread(&type, sizeof(type), 1, f) != 1) break;
        if (type == kShapeTypeLine) {
            Line l;    if (fread(&l, sizeof(Line),    1, f) != 1) break; layer.lines.push_back(l);
        } else if (type == kShapeTypeRect) {
            if (migrate) {
                RectV0 v0; if (fread(&v0, sizeof(RectV0), 1, f) != 1) break;
                Rect r{ v0.x0, v0.y0, v0.x1, v0.y1, /*rotation*/ 0.0f, v0.color, v0.width };
                layer.rects.push_back(r);
            } else {
                Rect r;    if (fread(&r, sizeof(Rect),    1, f) != 1) break; layer.rects.push_back(r);
            }
        } else if (type == kShapeTypeEllipse) {
            if (migrate) {
                EllipseV0 v0; if (fread(&v0, sizeof(EllipseV0), 1, f) != 1) break;
                Ellipse e{ v0.cx, v0.cy, v0.rx, v0.ry, /*rotation*/ 0.0f, v0.color, v0.width };
                layer.ellipses.push_back(e);
            } else {
                Ellipse e; if (fread(&e, sizeof(Ellipse), 1, f) != 1) break; layer.ellipses.push_back(e);
            }
        } else if (type == kShapeTypeCircle) {
            Circle c;  if (fread(&c, sizeof(Circle),  1, f) != 1) break; layer.circles.push_back(c);
        } else {
            LOGE("vector layer at %s: unknown shape type %d", dir.c_str(), type);
            break;
        }
    }
    fclose(f);
    // After migrating, rewrite in V1 format so subsequent loads are clean.
    // Caller will trigger save naturally on next stroke; but write here too.
    // (No-op for V1 files since we'd just overwrite identical content.)
    LOGI("loaded %zu lines + %zu rects + %zu ellipses + %zu circles from %s",
         layer.lines.size(), layer.rects.size(),
         layer.ellipses.size(), layer.circles.size(), dir.c_str());
}

// ---- Pending vector-layer shape additions --------------------------------

void applyPendingShapes() {
    std::vector<Line>    lines;
    std::vector<Rect>    rects;
    std::vector<Ellipse> ellipses;
    std::vector<Circle>  circles;
    {
        std::lock_guard<std::mutex> lock(g_pendingShapesMutex);
        lines.swap(g_pendingLines);
        rects.swap(g_pendingRects);
        ellipses.swap(g_pendingEllipses);
        circles.swap(g_pendingCircles);
    }
    if (lines.empty() && rects.empty() && ellipses.empty() && circles.empty())
        return;

    // Shapes append to whichever layer is active when applied. If the
    // active layer isn't vector, drop them (the shape tools shouldn't
    // have committed in the first place; UI can prevent this).
    if (g_activeLayer >= g_layers.size() || !g_layers[g_activeLayer]) return;
    Layer& layer = *g_layers[g_activeLayer];
    if (layer.type != LayerType::Vector) {
        LOGE("dropping queued shapes: active layer %zu is not vector",
             g_activeLayer);
        return;
    }
    for (const auto& s : lines) {
        layer.lines.push_back(s);
        UndoEntry e;
        e.op = UndoOp::VectorAdd;
        e.layerIdx = g_activeLayer;
        e.shapeIdx = layer.lines.size() - 1;
        e.afterShape.kind = ShapeKind::Line;
        e.afterShape.line = s;
        pushUndoEntry(std::move(e));
    }
    for (const auto& s : rects) {
        layer.rects.push_back(s);
        UndoEntry e;
        e.op = UndoOp::VectorAdd;
        e.layerIdx = g_activeLayer;
        e.shapeIdx = layer.rects.size() - 1;
        e.afterShape.kind = ShapeKind::Rect;
        e.afterShape.rect = s;
        pushUndoEntry(std::move(e));
    }
    for (const auto& s : ellipses) {
        layer.ellipses.push_back(s);
        UndoEntry e;
        e.op = UndoOp::VectorAdd;
        e.layerIdx = g_activeLayer;
        e.shapeIdx = layer.ellipses.size() - 1;
        e.afterShape.kind = ShapeKind::Ellipse;
        e.afterShape.ellipse = s;
        pushUndoEntry(std::move(e));
    }
    for (const auto& s : circles) {
        layer.circles.push_back(s);
        UndoEntry e;
        e.op = UndoOp::VectorAdd;
        e.layerIdx = g_activeLayer;
        e.shapeIdx = layer.circles.size() - 1;
        e.afterShape.kind = ShapeKind::Circle;
        e.afterShape.circle = s;
        pushUndoEntry(std::move(e));
    }
    saveVectorLayer(g_activeLayer, layer);
}

// Write tile pixel bytes to disk via tmp+rename. Callable when the
// caller already has the bytes in hand (e.g. commitStroke's combined
// after-snapshot + disk save pass). Bytes must be exactly kTileBytes.
void writeTileBytesToDisk(size_t layerIdx, int tx, int ty,
                          const uint8_t* bytes) {
    if (g_docDir.empty()) return;
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
    size_t written = fwrite(bytes, 1, kTileBytes, f);
    fclose(f);
    if (written != kTileBytes) {
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

void saveTileToDisk(size_t layerIdx, int64_t tileK) {
    if (g_docDir.empty()) return;
    if (layerIdx >= g_layers.size() || !g_layers[layerIdx]) return;
    auto& tiles = g_layers[layerIdx]->tiles;
    auto it = tiles.find(tileK);
    if (it == tiles.end()) return;

    int tx, ty;
    unpackTileKey(tileK, tx, ty);

    // Read pixels via the tile's FBO. Restore the previous binding before
    // returning so callers (notably undo/redo from inside the pending-
    // action drain at the start of compositeAllLayers) don't end up with
    // a tile FBO leaked into the multi-buffer composite path.
    GLint prevFbo = 0;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prevFbo);
    glBindFramebuffer(GL_FRAMEBUFFER, it->second.fbo);
    std::vector<uint8_t> buf(kTileBytes);
    glReadPixels(0, 0, kTileSize, kTileSize, GL_RGBA, GL_UNSIGNED_BYTE,
                 buf.data());
    glBindFramebuffer(GL_FRAMEBUFFER, prevFbo);

    writeTileBytesToDisk(layerIdx, tx, ty, buf.data());
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

    // Page bounds (doc-px) treat the canvas as a fixed-size sheet:
    //   - Tiles fully outside the page aren't created or baked at all.
    //   - Boundary tiles only emit dabs within the page rectangle.
    //   - The dab fragment shader also discards fragments outside the
    //     page in those boundary tiles, giving clean truncation right at
    //     the edge (the emitter-level clip alone leaves half-dab blobs).
    // When the bounds are inactive (zero-size), no clipping happens and
    // the doc behaves as the original infinite plane.
    PageClip pageClip = readPageClip();
    bool  pageActive = pageClip.active;
    float pageX0 = pageClip.minX, pageY0 = pageClip.minY;
    float pageX1 = pageClip.maxX, pageY1 = pageClip.maxY;

    // Walk the cells in the AABB but skip ones the stroke can't reach.
    // Without this, a long diagonal stroke (especially at low zoom-out)
    // would create thousands of empty 256x256 RGBA tile FBOs purely
    // because the AABB spans them — quickly exhausting GPU memory.
    // Pessimistic check uses kMaxRadius regardless of per-sample pressure.
    for (int ty = ty0; ty <= ty1; ++ty) {
        float tileY0 = ty * kTileSizeF;
        float tileY1 = tileY0 + kTileSizeF;
        for (int tx = tx0; tx <= tx1; ++tx) {
            float tileX0 = tx * kTileSizeF;
            float tileX1 = tileX0 + kTileSizeF;

            // Skip tiles entirely outside the page.
            if (pageActive
                && (tileX1 <= pageX0 || tileX0 >= pageX1
                 || tileY1 <= pageY0 || tileY0 >= pageY1)) {
                continue;
            }

            bool touched = false;
            for (const auto& s : g_current.samples) {
                if (s.x + kMaxRadius >= tileX0 && s.x - kMaxRadius <= tileX1
                 && s.y + kMaxRadius >= tileY0 && s.y - kMaxRadius <= tileY1) {
                    touched = true;
                    break;
                }
            }
            if (!touched) continue;

            Tile& tile = getOrCreateTile(layer, tx, ty);
            glBindFramebuffer(GL_FRAMEBUFFER, tile.fbo);
            glViewport(0, 0, kTileSize, kTileSize);

            float ox = tx * kTileSizeF;
            float oy = ty * kTileSizeF;

            // Per-tile clip bounds in tile-local coords. Start with the
            // full tile, then narrow to the intersection with the page
            // for boundary tiles so dabs that cross the edge stop at it.
            float clipMinX = 0.0f, clipMinY = 0.0f;
            float clipMaxX = kTileSizeF, clipMaxY = kTileSizeF;
            if (pageActive) {
                clipMinX = std::max(0.0f,        pageX0 - ox);
                clipMinY = std::max(0.0f,        pageY0 - oy);
                clipMaxX = std::min(kTileSizeF,  pageX1 - ox);
                clipMaxY = std::min(kTileSizeF,  pageY1 - oy);
            }

            // Set the dab fragment shader's page-clip uniforms in
            // tile-local coords. Together with the emitter-level clip
            // above, this gives clean fragment-level truncation at the
            // page edge (no half-dab blobs leaking past it).
            PageClip tilePage{pageActive, clipMinX, clipMinY, clipMaxX, clipMaxY};
            uploadPageClip(g_dab.uPageMin, g_dab.uPageMax,
                           g_dab.uPageActive, tilePage);

            DabEmitter e;
            // Clip to the tile (and page, where applicable) so the path's
            // interpolated dabs outside this region don't issue throwaway
            // GL draw calls and don't paint outside the canvas.
            e.setClipBounds(clipMinX, clipMinY, clipMaxX, clipMaxY);
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

// Draws one line segment using the line program (caller has already
// bound the program, VAO, and set uTransform / uScreen).
void drawLineSegment(float x0, float y0, float x1, float y1,
                     uint32_t rgb, float width, float alpha) {
    glUniform2f(g_lineProg.uP0, x0, y0);
    glUniform2f(g_lineProg.uP1, x1, y1);
    glUniform1f(g_lineProg.uHalfWidth, width * 0.5f);
    float r = ((rgb >> 16) & 0xFFu) / 255.0f;
    float g = ((rgb >>  8) & 0xFFu) / 255.0f;
    float b = ( rgb        & 0xFFu) / 255.0f;
    float c[4] = { r, g, b, alpha };
    glUniform4fv(g_lineProg.uColor, 1, c);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
}

constexpr uint32_t kHandleColor       = 0x4080FFu;   // blue
// Visual / hit-test sizes for selection UI, expressed in view pixels.
// Wrapped through vpxToDoc() at use sites so the on-screen size stays
// constant regardless of view scale. (Drawn shape widths remain in
// doc-px since they're a property of the doc, not the viewport.)
constexpr float    kHandleSizeViewPx        = 14.0f;
constexpr float    kHandleHitRadiusViewPx   = 18.0f;
constexpr float    kRotateHandleOffsetViewPx = 28.0f;
constexpr float    kSelectionOutlineWidthViewPx = 1.5f;
inline float vpxToDoc(float vpx) { return vpx / currentViewScale(); }

// Oriented bounding box for a shape, in doc-pixel space. Defined before
// the handle-rendering helpers (which take it by reference) and before
// hit-testing helpers; the obbFor* dispatchers are defined alongside.
struct Obb {
    float cx, cy;     // center
    float hw, hh;     // half-extents (in shape-local frame)
    float rotation;   // radians
};

inline void rotateLocalToWorld(const Obb& o, float lx, float ly,
                               float& wx, float& wy) {
    float c = std::cos(o.rotation), s = std::sin(o.rotation);
    wx = o.cx + lx * c - ly * s;
    wy = o.cy + lx * s + ly * c;
}

inline void rotateWorldToLocal(const Obb& o, float wx, float wy,
                               float& lx, float& ly) {
    float c = std::cos(-o.rotation), s = std::sin(-o.rotation);
    float dx = wx - o.cx, dy = wy - o.cy;
    lx = dx * c - dy * s;
    ly = dx * s + dy * c;
}

Obb obbForLine(const Line& l) {
    float cx = (l.x0 + l.x1) * 0.5f;
    float cy = (l.y0 + l.y1) * 0.5f;
    float dx = l.x1 - l.x0;
    float dy = l.y1 - l.y0;
    float len = std::sqrt(dx*dx + dy*dy);
    float angle = (len > 1e-6f) ? std::atan2(dy, dx) : 0.0f;
    float hh = std::max(l.width * 0.5f, 6.0f);
    return { cx, cy, len * 0.5f, hh, angle };
}

Obb obbForRect(const Rect& r) {
    float cx = (r.x0 + r.x1) * 0.5f;
    float cy = (r.y0 + r.y1) * 0.5f;
    float hw = std::fabs(r.x1 - r.x0) * 0.5f;
    float hh = std::fabs(r.y1 - r.y0) * 0.5f;
    return { cx, cy, hw, hh, r.rotation };
}

Obb obbForEllipse(const Ellipse& e) {
    return { e.cx, e.cy, e.rx, e.ry, e.rotation };
}

Obb obbForCircle(const Circle& c) {
    return { c.cx, c.cy, c.radius, c.radius, 0.0f };
}

bool obbForSelection(const Selection& sel, Obb& out) {
    if (sel.kind == ShapeKind::None) return false;
    if (sel.layerIdx >= g_layers.size() || !g_layers[sel.layerIdx]) return false;
    const Layer& layer = *g_layers[sel.layerIdx];
    switch (sel.kind) {
        case ShapeKind::Line:
            if (sel.shapeIdx < layer.lines.size())   { out = obbForLine(layer.lines[sel.shapeIdx]);   return true; }
            break;
        case ShapeKind::Rect:
            if (sel.shapeIdx < layer.rects.size())   { out = obbForRect(layer.rects[sel.shapeIdx]);   return true; }
            break;
        case ShapeKind::Ellipse:
            if (sel.shapeIdx < layer.ellipses.size()){ out = obbForEllipse(layer.ellipses[sel.shapeIdx]); return true; }
            break;
        case ShapeKind::Circle:
            if (sel.shapeIdx < layer.circles.size()) { out = obbForCircle(layer.circles[sel.shapeIdx]); return true; }
            break;
        case ShapeKind::None:
            break;
    }
    return false;
}

// ---- Snapping ------------------------------------------------------------

// Visit every snap-target point in every vector layer with the given
// callback. Each shape contributes its natural anchor points:
//   Line:    p0, p1, midpoint
//   Rect:    4 (rotated) corners + center
//   Ellipse: center + 4 cardinal points (rotated)
//   Circle:  center + 4 cardinal points
//
// `exclude`, if non-null, skips that exact (layer, kind, shapeIdx) so a
// shape can't snap to its own vertices during a transform drag.
template <typename F>
void forEachShapeSnapTarget(const F& cb, const Selection* exclude = nullptr) {
    for (size_t li = 0; li < g_layers.size(); ++li) {
        const auto& layer = g_layers[li];
        if (!layer || layer->type != LayerType::Vector) continue;
        auto skip = [&](ShapeKind k, size_t i) {
            return exclude && exclude->kind == k
                && exclude->layerIdx == li && exclude->shapeIdx == i;
        };
        for (size_t i = 0; i < layer->lines.size(); ++i) {
            if (skip(ShapeKind::Line, i)) continue;
            const auto& l = layer->lines[i];
            cb(l.x0, l.y0);
            cb(l.x1, l.y1);
            cb((l.x0 + l.x1) * 0.5f, (l.y0 + l.y1) * 0.5f);
        }
        for (size_t i = 0; i < layer->rects.size(); ++i) {
            if (skip(ShapeKind::Rect, i)) continue;
            Obb o = obbForRect(layer->rects[i]);
            float cx, cy;
            // Corners.
            rotateLocalToWorld(o, -o.hw, -o.hh, cx, cy); cb(cx, cy);
            rotateLocalToWorld(o, +o.hw, -o.hh, cx, cy); cb(cx, cy);
            rotateLocalToWorld(o, +o.hw, +o.hh, cx, cy); cb(cx, cy);
            rotateLocalToWorld(o, -o.hw, +o.hh, cx, cy); cb(cx, cy);
            // Edge midpoints (rotated).
            rotateLocalToWorld(o, 0,     -o.hh, cx, cy); cb(cx, cy);
            rotateLocalToWorld(o, +o.hw, 0,     cx, cy); cb(cx, cy);
            rotateLocalToWorld(o, 0,     +o.hh, cx, cy); cb(cx, cy);
            rotateLocalToWorld(o, -o.hw, 0,     cx, cy); cb(cx, cy);
            cb(o.cx, o.cy);
        }
        for (size_t i = 0; i < layer->ellipses.size(); ++i) {
            if (skip(ShapeKind::Ellipse, i)) continue;
            Obb o = obbForEllipse(layer->ellipses[i]);
            cb(o.cx, o.cy);
            float cx, cy;
            rotateLocalToWorld(o, +o.hw, 0,      cx, cy); cb(cx, cy);
            rotateLocalToWorld(o, -o.hw, 0,      cx, cy); cb(cx, cy);
            rotateLocalToWorld(o, 0,     +o.hh,  cx, cy); cb(cx, cy);
            rotateLocalToWorld(o, 0,     -o.hh,  cx, cy); cb(cx, cy);
        }
        for (size_t i = 0; i < layer->circles.size(); ++i) {
            if (skip(ShapeKind::Circle, i)) continue;
            const auto& c = layer->circles[i];
            cb(c.cx, c.cy);
            cb(c.cx + c.radius, c.cy);
            cb(c.cx - c.radius, c.cy);
            cb(c.cx, c.cy + c.radius);
            cb(c.cx, c.cy - c.radius);
        }
    }
}

// Returns the nearest snap target to (x, y) within the screen-relative
// snap radius. Falls back to the nearest grid intersection when the grid
// is on and no shape target qualifies.
struct SnapHit { float x, y; bool found; };

SnapHit findSnap(float x, float y, const Selection* exclude = nullptr) {
    if (g_snapEnabled.load() == 0) return { x, y, false };

    // Convert the view-pixel target radius into doc-px at the current zoom
    // so snap stays the same on-screen distance regardless of view scale.
    float radiusDoc  = kSnapRadiusViewPx / currentViewScale();
    float bestDist2  = radiusDoc * radiusDoc;
    SnapHit best     = { x, y, false };

    forEachShapeSnapTarget([&](float tx, float ty) {
        float dx = tx - x, dy = ty - y;
        float d2 = dx * dx + dy * dy;
        if (d2 < bestDist2) {
            bestDist2 = d2;
            best = { tx, ty, true };
        }
    }, exclude);

    if (!best.found && g_gridEnabled.load() != 0) {
        float gx = std::round(x / kGridSpacing) * kGridSpacing;
        float gy = std::round(y / kGridSpacing) * kGridSpacing;
        float dx = gx - x, dy = gy - y;
        if (dx * dx + dy * dy < radiusDoc * radiusDoc) {
            best = { gx, gy, true };
        }
    }
    return best;
}

// Forward decl; defined below in the shape-rendering helpers section.
void drawEllipseAsLines(float cx, float cy, float rx, float ry, float rotation,
                        uint32_t rgb, float width, float alpha);

// Draw a small ring + crosshair at (x, y) — the visual indicator for an
// active snap. Caller has already bound the line program.
void drawSnapMarker(float x, float y) {
    float r = vpxToDoc(kSnapMarkerRViewPx);
    float w = vpxToDoc(kSelectionOutlineWidthViewPx);
    drawEllipseAsLines(x, y, r, r, /*rotation*/ 0.0f,
                       kSnapMarkerColor, w, 1.0f);
    drawLineSegment(x - r, y, x + r, y, kSnapMarkerColor, w, 1.0f);
    drawLineSegment(x, y - r, x, y + r, kSnapMarkerColor, w, 1.0f);
}

// Draw a small square handle (4 line segments) centered at (x, y).
void drawHandle(float x, float y, float size, uint32_t color) {
    float h = size * 0.5f;
    float w = vpxToDoc(kSelectionOutlineWidthViewPx);
    drawLineSegment(x - h, y - h, x + h, y - h, color, w, 1.0f);
    drawLineSegment(x + h, y - h, x + h, y + h, color, w, 1.0f);
    drawLineSegment(x + h, y + h, x - h, y + h, color, w, 1.0f);
    drawLineSegment(x - h, y + h, x - h, y - h, color, w, 1.0f);
}

// Compute the world position of one of the four scale handles. handleIdx:
// 0 = top-left, 1 = top-right, 2 = bottom-right, 3 = bottom-left.
// For a Line (kind==Line) we emit only handles 0 (left endpoint) and 1
// (right endpoint), at the midpoints of the OBB's left/right sides.
void scaleHandlePosition(const Obb& o, ShapeKind kind, int handleIdx,
                         float& outX, float& outY) {
    float lx = 0.0f, ly = 0.0f;
    if (kind == ShapeKind::Line) {
        lx = (handleIdx == 0) ? -o.hw : +o.hw;
        ly = 0.0f;
    } else {
        lx = (handleIdx == 0 || handleIdx == 3) ? -o.hw : +o.hw;
        ly = (handleIdx == 0 || handleIdx == 1) ? -o.hh : +o.hh;
    }
    rotateLocalToWorld(o, lx, ly, outX, outY);
}

// Rotate handle is offset above the OBB top-center.
void rotateHandlePosition(const Obb& o, float& outX, float& outY) {
    rotateLocalToWorld(o, 0.0f, -o.hh - vpxToDoc(kRotateHandleOffsetViewPx),
                       outX, outY);
}

// Number of scale handles for the shape (2 for Line, 4 for others).
int scaleHandleCount(ShapeKind kind) {
    return (kind == ShapeKind::Line) ? 2 : 4;
}

// Renders the OBB outline + scale handles + rotate handle for the given
// selection. Caller must already have the line program / VAO bound.
void renderSelectionOverlay(const Selection& sel) {
    Obb obb;
    if (!obbForSelection(sel, obb)) return;

    float outlineW = vpxToDoc(kSelectionOutlineWidthViewPx);
    float handleSz = vpxToDoc(kHandleSizeViewPx);

    // OBB outline — 4 corners of the box (rotated).
    float c0x, c0y, c1x, c1y, c2x, c2y, c3x, c3y;
    rotateLocalToWorld(obb, -obb.hw, -obb.hh, c0x, c0y);
    rotateLocalToWorld(obb, +obb.hw, -obb.hh, c1x, c1y);
    rotateLocalToWorld(obb, +obb.hw, +obb.hh, c2x, c2y);
    rotateLocalToWorld(obb, -obb.hw, +obb.hh, c3x, c3y);
    drawLineSegment(c0x, c0y, c1x, c1y, kHandleColor, outlineW, 1.0f);
    drawLineSegment(c1x, c1y, c2x, c2y, kHandleColor, outlineW, 1.0f);
    drawLineSegment(c2x, c2y, c3x, c3y, kHandleColor, outlineW, 1.0f);
    drawLineSegment(c3x, c3y, c0x, c0y, kHandleColor, outlineW, 1.0f);

    // Scale handles.
    int n = scaleHandleCount(sel.kind);
    for (int i = 0; i < n; ++i) {
        float hx, hy;
        scaleHandlePosition(obb, sel.kind, i, hx, hy);
        drawHandle(hx, hy, handleSz, kHandleColor);
    }

    // Rotate handle (skip for circles — rotation is invariant).
    if (sel.kind != ShapeKind::Circle) {
        float anchorX, anchorY;
        rotateLocalToWorld(obb, 0.0f, -obb.hh, anchorX, anchorY);
        float rhX, rhY;
        rotateHandlePosition(obb, rhX, rhY);
        drawLineSegment(anchorX, anchorY, rhX, rhY,
                        kHandleColor, outlineW, 1.0f);
        drawHandle(rhX, rhY, handleSz, kHandleColor);
    }
}

// Helper: rotate (lx, ly) around (cx, cy) by `rotation` radians.
inline void rotateAround(float cx, float cy, float lx, float ly, float rotation,
                         float& outX, float& outY) {
    float c = std::cos(rotation), s = std::sin(rotation);
    float dx = lx - cx, dy = ly - cy;
    outX = cx + dx * c - dy * s;
    outY = cy + dx * s + dy * c;
}

void drawRectangleAsLines(float x0, float y0, float x1, float y1, float rotation,
                          uint32_t rgb, float width, float alpha) {
    float cx = (x0 + x1) * 0.5f;
    float cy = (y0 + y1) * 0.5f;
    float ax, ay, bx, by, cx_, cy_, dx, dy;
    rotateAround(cx, cy, x0, y0, rotation, ax, ay);
    rotateAround(cx, cy, x1, y0, rotation, bx, by);
    rotateAround(cx, cy, x1, y1, rotation, cx_, cy_);
    rotateAround(cx, cy, x0, y1, rotation, dx, dy);
    drawLineSegment(ax, ay, bx, by, rgb, width, alpha);
    drawLineSegment(bx, by, cx_, cy_, rgb, width, alpha);
    drawLineSegment(cx_, cy_, dx, dy, rgb, width, alpha);
    drawLineSegment(dx, dy, ax, ay, rgb, width, alpha);
}

void drawEllipseAsLines(float cx, float cy, float rx, float ry, float rotation,
                        uint32_t rgb, float width, float alpha) {
    constexpr int   kSegments = 32;
    constexpr float kTau      = 6.283185307179586f;
    float c = std::cos(rotation), s = std::sin(rotation);
    auto pointAt = [&](float a, float& x, float& y) {
        float lx = std::cos(a) * rx;
        float ly = std::sin(a) * ry;
        x = cx + lx * c - ly * s;
        y = cy + lx * s + ly * c;
    };
    float prevX, prevY;
    pointAt(0.0f, prevX, prevY);
    for (int i = 1; i <= kSegments; ++i) {
        float a = (float)i / (float)kSegments * kTau;
        float x, y;
        pointAt(a, x, y);
        drawLineSegment(prevX, prevY, x, y, rgb, width, alpha);
        prevX = x;
        prevY = y;
    }
}

// ---- Selection helpers ---------------------------------------------------

constexpr float kSelectionHaloPad = 3.0f;            // extra half-width
constexpr uint32_t kSelectionHaloColor = 0xFF8030u;  // orange
constexpr float kSelectionHaloAlpha = 0.55f;
constexpr float kHitThresholdPadViewPx = 6.0f;       // tap tolerance, view px

// Convert the view-pixel hit-test pad to a doc-pixel pad at the current
// zoom level, so tapping near a shape outline keeps the same on-screen
// tolerance regardless of how zoomed-in the user is.
inline float hitThresholdPadDoc() {
    return kHitThresholdPadViewPx / currentViewScale();
}

inline bool isShapeSelected(const Selection& sel, size_t layerIdx,
                            ShapeKind kind, size_t shapeIdx) {
    return sel.kind == kind && sel.layerIdx == layerIdx
        && sel.shapeIdx == shapeIdx;
}

float distToSegment(float px, float py,
                    float ax, float ay, float bx, float by) {
    float abx = bx - ax, aby = by - ay;
    float apx = px - ax, apy = py - ay;
    float ab2 = abx*abx + aby*aby;
    float t = (ab2 > 1e-6f) ? (apx*abx + apy*aby) / ab2 : 0.0f;
    if (t < 0.0f) t = 0.0f; else if (t > 1.0f) t = 1.0f;
    float cx = ax + abx * t, cy = ay + aby * t;
    float dx = px - cx, dy = py - cy;
    return std::sqrt(dx*dx + dy*dy);
}

float distToRectOutline(float px, float py,
                        float x0, float y0, float x1, float y1) {
    float d1 = distToSegment(px, py, x0, y0, x1, y0);
    float d2 = distToSegment(px, py, x1, y0, x1, y1);
    float d3 = distToSegment(px, py, x1, y1, x0, y1);
    float d4 = distToSegment(px, py, x0, y1, x0, y0);
    return std::min(std::min(d1, d2), std::min(d3, d4));
}

float distToCircleOutline(float px, float py,
                          float cx, float cy, float r) {
    float dx = px - cx, dy = py - cy;
    return std::fabs(std::sqrt(dx*dx + dy*dy) - r);
}

// Approximate distance from point to ellipse outline. Scales to a unit
// circle, computes distance there, then scales back by the average
// radius. Good enough for tap-to-select.
float distToEllipseOutline(float px, float py,
                           float cx, float cy, float rx, float ry) {
    if (rx < 1e-3f || ry < 1e-3f) return 1e9f;
    float dx = (px - cx) / rx, dy = (py - cy) / ry;
    float lenScaled = std::sqrt(dx*dx + dy*dy);
    float avg = (rx + ry) * 0.5f;
    return std::fabs(lenScaled - 1.0f) * avg;
}

// Hit-test the active layer at (x, y); on hit, set g_selection. Returns
// true if a shape was selected, false if no shape was hit (and clears
// any prior selection). Searches in render order so the topmost shape
// wins on overlap.
bool hitTestActiveVectorLayer(float x, float y) {
    if (g_activeLayer >= g_layers.size() || !g_layers[g_activeLayer]) return false;
    Layer& layer = *g_layers[g_activeLayer];
    if (layer.type != LayerType::Vector) return false;

    ShapeKind hitKind = ShapeKind::None;
    size_t    hitIdx  = 0;
    float     pad     = hitThresholdPadDoc();

    for (size_t i = 0; i < layer.lines.size(); ++i) {
        const auto& l = layer.lines[i];
        float thr = l.width * 0.5f + pad;
        if (distToSegment(x, y, l.x0, l.y0, l.x1, l.y1) <= thr) {
            hitKind = ShapeKind::Line; hitIdx = i;
        }
    }
    for (size_t i = 0; i < layer.rects.size(); ++i) {
        const auto& r = layer.rects[i];
        float thr = r.width * 0.5f + pad;
        if (distToRectOutline(x, y, r.x0, r.y0, r.x1, r.y1) <= thr) {
            hitKind = ShapeKind::Rect; hitIdx = i;
        }
    }
    for (size_t i = 0; i < layer.ellipses.size(); ++i) {
        const auto& e = layer.ellipses[i];
        float thr = e.width * 0.5f + pad;
        if (distToEllipseOutline(x, y, e.cx, e.cy, e.rx, e.ry) <= thr) {
            hitKind = ShapeKind::Ellipse; hitIdx = i;
        }
    }
    for (size_t i = 0; i < layer.circles.size(); ++i) {
        const auto& c = layer.circles[i];
        float thr = c.width * 0.5f + pad;
        if (distToCircleOutline(x, y, c.cx, c.cy, c.radius) <= thr) {
            hitKind = ShapeKind::Circle; hitIdx = i;
        }
    }

    std::lock_guard<std::mutex> lock(g_selectionMutex);
    if (hitKind == ShapeKind::None) {
        g_selection = Selection{};
        return false;
    }
    g_selection.kind     = hitKind;
    g_selection.layerIdx = g_activeLayer;
    g_selection.shapeIdx = hitIdx;
    return true;
}

void compositeVectorLayer(JNIEnv* env, const Layer& layer, size_t layerIdx,
                          jint width, jint height, jfloatArray transform) {
    if (layer.lines.empty() && layer.rects.empty()
        && layer.ellipses.empty() && layer.circles.empty()) return;

    // Snapshot selection for this composite pass.
    Selection sel;
    {
        std::lock_guard<std::mutex> lock(g_selectionMutex);
        sel = g_selection;
    }

    glUseProgram(g_lineProg.program);
    glBindVertexArray(g_quadVao);
    uploadMat4(env, g_lineProg.uTransform, transform);
    glUniform2f(g_lineProg.uScreen, (float)width, (float)height);
    // Vector content gets the same page-clip treatment as raster strokes.
    PageClip pageClip = readPageClip();
    uploadPageClip(g_lineProg.uPageMin, g_lineProg.uPageMax,
                   g_lineProg.uPageActive, pageClip);

    for (size_t i = 0; i < layer.lines.size(); ++i) {
        const auto& l = layer.lines[i];
        if (isShapeSelected(sel, layerIdx, ShapeKind::Line, i)) {
            drawLineSegment(l.x0, l.y0, l.x1, l.y1,
                            kSelectionHaloColor, l.width + kSelectionHaloPad * 2.0f,
                            kSelectionHaloAlpha);
        }
        drawLineSegment(l.x0, l.y0, l.x1, l.y1, l.color, l.width, 1.0f);
    }
    for (size_t i = 0; i < layer.rects.size(); ++i) {
        const auto& r = layer.rects[i];
        if (isShapeSelected(sel, layerIdx, ShapeKind::Rect, i)) {
            drawRectangleAsLines(r.x0, r.y0, r.x1, r.y1, r.rotation,
                                 kSelectionHaloColor, r.width + kSelectionHaloPad * 2.0f,
                                 kSelectionHaloAlpha);
        }
        drawRectangleAsLines(r.x0, r.y0, r.x1, r.y1, r.rotation, r.color, r.width, 1.0f);
    }
    for (size_t i = 0; i < layer.ellipses.size(); ++i) {
        const auto& e = layer.ellipses[i];
        if (isShapeSelected(sel, layerIdx, ShapeKind::Ellipse, i)) {
            drawEllipseAsLines(e.cx, e.cy, e.rx, e.ry, e.rotation,
                               kSelectionHaloColor, e.width + kSelectionHaloPad * 2.0f,
                               kSelectionHaloAlpha);
        }
        drawEllipseAsLines(e.cx, e.cy, e.rx, e.ry, e.rotation, e.color, e.width, 1.0f);
    }
    for (size_t i = 0; i < layer.circles.size(); ++i) {
        const auto& c = layer.circles[i];
        if (isShapeSelected(sel, layerIdx, ShapeKind::Circle, i)) {
            drawEllipseAsLines(c.cx, c.cy, c.radius, c.radius, /*rotation*/ 0.0f,
                               kSelectionHaloColor, c.width + kSelectionHaloPad * 2.0f,
                               kSelectionHaloAlpha);
        }
        drawEllipseAsLines(c.cx, c.cy, c.radius, c.radius, /*rotation*/ 0.0f, c.color, c.width, 1.0f);
    }
}

void compositeAllLayers(JNIEnv* env, jint width, jint height,
                        jfloatArray transform) {
    glViewport(0, 0, width, height);

    PageClip pageClip = readPageClip();

    if (pageClip.active) {
        // Off-canvas background: light gray clear, then paint paper-white
        // over the page rectangle. With page disabled, fall back to a
        // single paper-white clear (the original behavior).
        glDisable(GL_BLEND);
        glClearColor(0.86f, 0.87f, 0.89f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);

        glUseProgram(g_fill.program);
        glBindVertexArray(g_quadVao);
        uploadMat4(env, g_fill.uTransform, transform);
        glUniform2f(g_fill.uScreen, (float)width, (float)height);
        glUniform2f(g_fill.uMin, pageClip.minX, pageClip.minY);
        glUniform2f(g_fill.uMax, pageClip.maxX, pageClip.maxY);
        glUniform4f(g_fill.uFillColor, 1.0f, 1.0f, 1.0f, 1.0f);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

        glEnable(GL_BLEND);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    } else {
        glClearColor(1.0f, 1.0f, 1.0f, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
    }

    // Grid is part of the page background — between the paper-white clear
    // and the layer tiles, so user strokes naturally occlude it. Grid
    // shader discards fragments outside the page when active.
    {
        glUseProgram(g_grid.program);
        uploadPageClip(g_grid.uPageMin, g_grid.uPageMax,
                       g_grid.uPageActive, pageClip);
    }
    renderGridOverlay(env, width, height, transform);

    // Page-boundary rectangle (anchor for the user when zoomed/rotated).
    // Drawn under the layers so strokes that cross the boundary occlude
    // it locally while the rest stays visible. The outline itself must
    // NOT be page-clipped — that would invisibly trim its own edges.
    if (pageClip.active) {
        glUseProgram(g_lineProg.program);
        glBindVertexArray(g_quadVao);
        uploadMat4(env, g_lineProg.uTransform, transform);
        glUniform2f(g_lineProg.uScreen, (float)width, (float)height);
        uploadPageClip(g_lineProg.uPageMin, g_lineProg.uPageMax,
                       g_lineProg.uPageActive,
                       PageClip{false, 0, 0, 0, 0});
        constexpr uint32_t kPageColor = 0x808890u;     // medium gray
        constexpr float    kPageAlpha = 0.85f;
        constexpr float    kPageWidthViewPx = 1.5f;
        float w = vpxToDoc(kPageWidthViewPx);
        drawLineSegment(pageClip.minX, pageClip.minY,
                        pageClip.maxX, pageClip.minY, kPageColor, w, kPageAlpha);
        drawLineSegment(pageClip.maxX, pageClip.minY,
                        pageClip.maxX, pageClip.maxY, kPageColor, w, kPageAlpha);
        drawLineSegment(pageClip.maxX, pageClip.maxY,
                        pageClip.minX, pageClip.maxY, kPageColor, w, kPageAlpha);
        drawLineSegment(pageClip.minX, pageClip.maxY,
                        pageClip.minX, pageClip.minY, kPageColor, w, kPageAlpha);
        glBindVertexArray(0);
    }

    if (g_layers.empty()) return;

    // Premultiplied blend is the global default; both raster tiles and
    // vector lines composite correctly under it.
    glEnable(GL_BLEND);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);

    bindRasterCompositePipeline(env, width, height, transform);

    for (size_t i = 0; i < g_layers.size(); ++i) {
        const auto& layer = g_layers[i];
        if (!layer) continue;
        if (layer->type == LayerType::Raster) {
            compositeRasterLayer(*layer);
        } else { // Vector
            compositeVectorLayer(env, *layer, i, width, height, transform);
            // Switch back to raster pipeline for the next raster layer.
            bindRasterCompositePipeline(env, width, height, transform);
        }
    }

    // Selection overlay (OBB + handles) — drawn on top of everything so
    // it's visible regardless of which layer the selected shape lives on.
    Selection sel;
    bool  snapActive = false;
    float snapMx = 0.0f, snapMy = 0.0f;
    {
        std::lock_guard<std::mutex> lock(g_selectionMutex);
        sel = g_selection;
        snapActive = g_drag.snapActive;
        snapMx = g_drag.snapX;
        snapMy = g_drag.snapY;
    }
    if (sel.kind != ShapeKind::None) {
        glUseProgram(g_lineProg.program);
        glBindVertexArray(g_quadVao);
        uploadMat4(env, g_lineProg.uTransform, transform);
        glUniform2f(g_lineProg.uScreen, (float)width, (float)height);
        // Selection handles & snap marker are UI affordances — must stay
        // visible even when the selected shape is right at the page edge.
        uploadPageClip(g_lineProg.uPageMin, g_lineProg.uPageMax,
                       g_lineProg.uPageActive,
                       PageClip{false, 0, 0, 0, 0});
        renderSelectionOverlay(sel);
        if (snapActive) {
            drawSnapMarker(snapMx, snapMy);
        }
    }

    glBindTexture(GL_TEXTURE_2D, 0);
    glBindVertexArray(0);
}

// Renders a shape preview into the currently-bound framebuffer (the
// front-buffered layer when called from the framework callback). Clears
// the buffer first so successive previews replace rather than accumulate.
//
// Shape types and their (x0, y0, x1, y1) interpretation:
//   0  Line:       endpoints
//   1  Rectangle:  bbox corners (any two opposite corners)
//   2  Circle:     p0 = center, p1 = point on circle (radius = distance)
//   3  Ellipse:    bbox corners (oval inscribed in the bbox)
void renderShapePreviewToFront(JNIEnv* env, jint width, jint height,
                               jfloatArray transform,
                               int shapeType,
                               float x0, float y0, float x1, float y1,
                               uint32_t rgb, float lineWidth, float alpha,
                               bool snapped) {
    glViewport(0, 0, width, height);
    glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    glEnable(GL_BLEND);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    glUseProgram(g_lineProg.program);
    glBindVertexArray(g_quadVao);
    uploadMat4(env, g_lineProg.uTransform, transform);
    glUniform2f(g_lineProg.uScreen, (float)width, (float)height);
    {
        PageClip pageClip = readPageClip();
        uploadPageClip(g_lineProg.uPageMin, g_lineProg.uPageMax,
                       g_lineProg.uPageActive, pageClip);
    }

    switch (shapeType) {
        case 0:
            drawLineSegment(x0, y0, x1, y1, rgb, lineWidth, alpha);
            break;
        case 1:
            drawRectangleAsLines(x0, y0, x1, y1, /*rotation*/ 0.0f,
                                 rgb, lineWidth, alpha);
            break;
        case 2: {
            float dx = x1 - x0;
            float dy = y1 - y0;
            float radius = std::sqrt(dx * dx + dy * dy);
            drawEllipseAsLines(x0, y0, radius, radius, /*rotation*/ 0.0f,
                               rgb, lineWidth, alpha);
            break;
        }
        case 3: {
            float cx = (x0 + x1) * 0.5f;
            float cy = (y0 + y1) * 0.5f;
            float rx = std::fabs(x1 - x0) * 0.5f;
            float ry = std::fabs(y1 - y0) * 0.5f;
            drawEllipseAsLines(cx, cy, rx, ry, /*rotation*/ 0.0f,
                               rgb, lineWidth, alpha);
            break;
        }
    }
    // If the dragged endpoint is currently snapped, draw the indicator
    // at that endpoint so the user can see what they snapped to.
    if (snapped) {
        drawSnapMarker(x1, y1);
    }
    glBindVertexArray(0);
}

// ---- Undo / redo apply ---------------------------------------------------

void insertShapeAt(Layer& layer, ShapeKind kind, size_t idx, const ShapeData& sd) {
    switch (kind) {
        case ShapeKind::Line:
            layer.lines.insert(layer.lines.begin()
                + std::min(idx, layer.lines.size()), sd.line);
            break;
        case ShapeKind::Rect:
            layer.rects.insert(layer.rects.begin()
                + std::min(idx, layer.rects.size()), sd.rect);
            break;
        case ShapeKind::Ellipse:
            layer.ellipses.insert(layer.ellipses.begin()
                + std::min(idx, layer.ellipses.size()), sd.ellipse);
            break;
        case ShapeKind::Circle:
            layer.circles.insert(layer.circles.begin()
                + std::min(idx, layer.circles.size()), sd.circle);
            break;
        case ShapeKind::None:
            break;
    }
}

void eraseShapeAt(Layer& layer, ShapeKind kind, size_t idx) {
    switch (kind) {
        case ShapeKind::Line:
            if (idx < layer.lines.size())
                layer.lines.erase(layer.lines.begin() + idx);
            break;
        case ShapeKind::Rect:
            if (idx < layer.rects.size())
                layer.rects.erase(layer.rects.begin() + idx);
            break;
        case ShapeKind::Ellipse:
            if (idx < layer.ellipses.size())
                layer.ellipses.erase(layer.ellipses.begin() + idx);
            break;
        case ShapeKind::Circle:
            if (idx < layer.circles.size())
                layer.circles.erase(layer.circles.begin() + idx);
            break;
        case ShapeKind::None:
            break;
    }
}

void assignShapeAt(Layer& layer, ShapeKind kind, size_t idx, const ShapeData& sd) {
    switch (kind) {
        case ShapeKind::Line:
            if (idx < layer.lines.size())    layer.lines[idx]    = sd.line;
            break;
        case ShapeKind::Rect:
            if (idx < layer.rects.size())    layer.rects[idx]    = sd.rect;
            break;
        case ShapeKind::Ellipse:
            if (idx < layer.ellipses.size()) layer.ellipses[idx] = sd.ellipse;
            break;
        case ShapeKind::Circle:
            if (idx < layer.circles.size())  layer.circles[idx]  = sd.circle;
            break;
        case ShapeKind::None:
            break;
    }
}

// Drop GL resources for every tile in a layer, clear the tile map. Used
// by both LayerClear redo and LayerAdd undo (defensive — added layers
// should be empty already, but safe to call regardless).
void dropAllTilesGl(Layer& layer) {
    for (auto& kv : layer.tiles) {
        if (kv.second.fbo)     glDeleteFramebuffers(1, &kv.second.fbo);
        if (kv.second.texture) glDeleteTextures(1, &kv.second.texture);
    }
    layer.tiles.clear();
}

// Wipe the on-disk contents of a layer dir (but leave the dir itself).
// Used by LayerClear redo to mirror the live clearActiveLayer path.
void clearLayerDirOnDisk(size_t layerIdx) {
    if (g_docDir.empty()) return;
    std::string layerDir = g_docDir + "/layer_" + std::to_string(layerIdx);
    DIR* d = opendir(layerDir.c_str());
    if (!d) return;
    struct dirent* dirEnt;
    while ((dirEnt = readdir(d)) != nullptr) {
        if (dirEnt->d_name[0] == '.') continue;
        std::string p = layerDir + "/" + dirEnt->d_name;
        unlink(p.c_str());
    }
    closedir(d);
}

// Reverse a previously-recorded action.
void applyEntryReverse(const UndoEntry& e) {
    switch (e.op) {
        case UndoOp::RasterStroke: {
            for (const auto& s : e.beforeTiles) applyTileSnap(e.layerIdx, s);
            break;
        }
        case UndoOp::VectorAdd: {
            if (e.layerIdx >= g_layers.size() || !g_layers[e.layerIdx]) break;
            Layer& layer = *g_layers[e.layerIdx];
            eraseShapeAt(layer, e.afterShape.kind, e.shapeIdx);
            {
                std::lock_guard<std::mutex> lock(g_selectionMutex);
                if (g_selection.kind == e.afterShape.kind
                    && g_selection.layerIdx == e.layerIdx
                    && g_selection.shapeIdx == e.shapeIdx) {
                    g_selection = Selection{};
                }
            }
            saveVectorLayer(e.layerIdx, layer);
            break;
        }
        case UndoOp::VectorDelete: {
            if (e.layerIdx >= g_layers.size() || !g_layers[e.layerIdx]) break;
            Layer& layer = *g_layers[e.layerIdx];
            insertShapeAt(layer, e.beforeShape.kind, e.shapeIdx, e.beforeShape);
            saveVectorLayer(e.layerIdx, layer);
            break;
        }
        case UndoOp::VectorMutate: {
            if (e.layerIdx >= g_layers.size() || !g_layers[e.layerIdx]) break;
            Layer& layer = *g_layers[e.layerIdx];
            assignShapeAt(layer, e.beforeShape.kind, e.shapeIdx, e.beforeShape);
            saveVectorLayer(e.layerIdx, layer);
            break;
        }
        case UndoOp::LayerClear: {
            if (e.layerIdx >= g_layers.size() || !g_layers[e.layerIdx]) break;
            Layer& layer = *g_layers[e.layerIdx];
            for (const auto& s : e.beforeTiles) applyTileSnap(e.layerIdx, s);
            layer.lines    = e.beforeLines;
            layer.rects    = e.beforeRects;
            layer.ellipses = e.beforeEllipses;
            layer.circles  = e.beforeCircles;
            if (layer.type == LayerType::Vector) {
                saveVectorLayer(e.layerIdx, layer);
            }
            break;
        }
        case UndoOp::LayerAdd: {
            // Layer should be the topmost (other entries were undone in
            // reverse). If not, something's gone wrong; bail safely.
            if (e.layerIdx >= g_layers.size()
                || e.layerIdx + 1 != g_layers.size()) {
                LOGE("undo LayerAdd: layer %zu isn't topmost (size=%zu)",
                     e.layerIdx, g_layers.size());
                break;
            }
            if (g_layers[e.layerIdx]) {
                dropAllTilesGl(*g_layers[e.layerIdx]);
            }
            g_layers.pop_back();
            deleteLayerDirIfExists(e.layerIdx);
            {
                std::lock_guard<std::mutex> lock(g_selectionMutex);
                if (g_selection.layerIdx == e.layerIdx) {
                    g_selection = Selection{};
                }
            }
            if (e.prevActiveLayer < g_layers.size()) {
                g_activeLayer = e.prevActiveLayer;
            } else if (!g_layers.empty()) {
                g_activeLayer = g_layers.size() - 1;
            } else {
                g_activeLayer = 0;
            }
            break;
        }
    }
}

// Re-apply a previously-undone action.
void applyEntryForward(const UndoEntry& e) {
    switch (e.op) {
        case UndoOp::RasterStroke: {
            for (const auto& s : e.afterTiles) applyTileSnap(e.layerIdx, s);
            break;
        }
        case UndoOp::VectorAdd: {
            if (e.layerIdx >= g_layers.size() || !g_layers[e.layerIdx]) break;
            Layer& layer = *g_layers[e.layerIdx];
            insertShapeAt(layer, e.afterShape.kind, e.shapeIdx, e.afterShape);
            saveVectorLayer(e.layerIdx, layer);
            break;
        }
        case UndoOp::VectorDelete: {
            if (e.layerIdx >= g_layers.size() || !g_layers[e.layerIdx]) break;
            Layer& layer = *g_layers[e.layerIdx];
            eraseShapeAt(layer, e.beforeShape.kind, e.shapeIdx);
            {
                std::lock_guard<std::mutex> lock(g_selectionMutex);
                if (g_selection.kind == e.beforeShape.kind
                    && g_selection.layerIdx == e.layerIdx
                    && g_selection.shapeIdx == e.shapeIdx) {
                    g_selection = Selection{};
                }
            }
            saveVectorLayer(e.layerIdx, layer);
            break;
        }
        case UndoOp::VectorMutate: {
            if (e.layerIdx >= g_layers.size() || !g_layers[e.layerIdx]) break;
            Layer& layer = *g_layers[e.layerIdx];
            assignShapeAt(layer, e.afterShape.kind, e.shapeIdx, e.afterShape);
            saveVectorLayer(e.layerIdx, layer);
            break;
        }
        case UndoOp::LayerClear: {
            if (e.layerIdx >= g_layers.size() || !g_layers[e.layerIdx]) break;
            Layer& layer = *g_layers[e.layerIdx];
            dropAllTilesGl(layer);
            layer.lines.clear();
            layer.rects.clear();
            layer.ellipses.clear();
            layer.circles.clear();
            clearLayerDirOnDisk(e.layerIdx);
            if (layer.type == LayerType::Vector) {
                saveVectorLayer(e.layerIdx, layer);
            }
            break;
        }
        case UndoOp::LayerAdd: {
            auto layer = std::make_unique<Layer>();
            layer->type = e.addedLayerType;
            g_layers.push_back(std::move(layer));
            g_activeLayer = g_layers.size() - 1;
            if (e.addedLayerType == LayerType::Vector) {
                saveVectorLayer(g_activeLayer, *g_layers[g_activeLayer]);
            }
            break;
        }
    }
}

// Pop the top of the undo stack, reverse it, push onto the redo stack.
// Caller is responsible for any subsequent re-render.
void applyUndo() {
    UndoEntry e;
    {
        std::lock_guard<std::mutex> lock(g_undoMutex);
        if (g_undoStack.empty()) return;
        e = std::move(g_undoStack.back());
        g_undoStack.pop_back();
        g_undoTotalBytes -= e.bytes;
    }
    applyEntryReverse(e);
    {
        std::lock_guard<std::mutex> lock(g_undoMutex);
        g_redoTotalBytes += e.bytes;
        g_redoStack.push_back(std::move(e));
    }
}

void applyRedo() {
    UndoEntry e;
    {
        std::lock_guard<std::mutex> lock(g_undoMutex);
        if (g_redoStack.empty()) return;
        e = std::move(g_redoStack.back());
        g_redoStack.pop_back();
        g_redoTotalBytes -= e.bytes;
    }
    applyEntryForward(e);
    {
        std::lock_guard<std::mutex> lock(g_undoMutex);
        g_undoTotalBytes += e.bytes;
        g_undoStack.push_back(std::move(e));
    }
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

// Undo / redo are queued through the same pending-action path so the
// inverse mutation (which can touch GL state and disk) runs on the GL
// thread. Caller should trigger a redraw afterward; the change won't be
// visible until the next composite.
JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_undo(JNIEnv*, jobject) {
    enqueuePendingAction(kActionUndo);
}

JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_redo(JNIEnv*, jobject) {
    enqueuePendingAction(kActionRedo);
}

JNIEXPORT jboolean JNICALL
Java_com_bk_drawing_NativeRenderer_canUndo(JNIEnv*, jobject) {
    std::lock_guard<std::mutex> lock(g_undoMutex);
    return g_undoStack.empty() ? JNI_FALSE : JNI_TRUE;
}

JNIEXPORT jboolean JNICALL
Java_com_bk_drawing_NativeRenderer_canRedo(JNIEnv*, jobject) {
    std::lock_guard<std::mutex> lock(g_undoMutex);
    return g_redoStack.empty() ? JNI_FALSE : JNI_TRUE;
}

// Each addXxx packs the user's drag into a shape struct, picks up the
// current brush color and a default line width, and queues it for the
// GL thread to apply on the next render.

JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_addLine(
        JNIEnv*, jobject,
        jfloat x0, jfloat y0, jfloat x1, jfloat y1) {
    Line l;
    l.x0 = x0; l.y0 = y0;
    l.x1 = x1; l.y1 = y1;
    l.color = g_currentBrushColor.load();
    l.width = kDefaultLineWidth;
    std::lock_guard<std::mutex> lock(g_pendingShapesMutex);
    g_pendingLines.push_back(l);
}

JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_addRectangle(
        JNIEnv*, jobject,
        jfloat x0, jfloat y0, jfloat x1, jfloat y1) {
    Rect r;
    r.x0 = x0; r.y0 = y0;
    r.x1 = x1; r.y1 = y1;
    r.rotation = 0.0f;
    r.color = g_currentBrushColor.load();
    r.width = kDefaultLineWidth;
    std::lock_guard<std::mutex> lock(g_pendingShapesMutex);
    g_pendingRects.push_back(r);
}

// Ellipse from bbox: center at midpoint, semi-axes from half-extents.
JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_addEllipse(
        JNIEnv*, jobject,
        jfloat x0, jfloat y0, jfloat x1, jfloat y1) {
    Ellipse e;
    e.cx = (x0 + x1) * 0.5f;
    e.cy = (y0 + y1) * 0.5f;
    e.rx = std::fabs(x1 - x0) * 0.5f;
    e.ry = std::fabs(y1 - y0) * 0.5f;
    e.rotation = 0.0f;
    e.color = g_currentBrushColor.load();
    e.width = kDefaultLineWidth;
    std::lock_guard<std::mutex> lock(g_pendingShapesMutex);
    g_pendingEllipses.push_back(e);
}

// Circle from center+radius: p0 is the center, p1 is a point on the
// circle. Radius = distance(p0, p1). Different gesture from ellipse/rect
// because dragging a circle from its center reads more naturally.
JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_addCircle(
        JNIEnv*, jobject,
        jfloat x0, jfloat y0, jfloat x1, jfloat y1) {
    Circle c;
    c.cx = x0;
    c.cy = y0;
    float dx = x1 - x0;
    float dy = y1 - y0;
    c.radius = std::sqrt(dx * dx + dy * dy);
    c.color = g_currentBrushColor.load();
    c.width = kDefaultLineWidth;
    std::lock_guard<std::mutex> lock(g_pendingShapesMutex);
    g_pendingCircles.push_back(c);
}

// Hit-test the active vector layer at (x, y); on hit, set g_selection
// and return true. On miss, clear any prior selection and return false.
JNIEXPORT jboolean JNICALL
Java_com_bk_drawing_NativeRenderer_selectShapeAt(
        JNIEnv*, jobject, jfloat x, jfloat y) {
    return hitTestActiveVectorLayer(x, y) ? JNI_TRUE : JNI_FALSE;
}

// Test if (x, y) hits any of the current selection's handles. Returns:
//   -2 = rotate handle
//   0..3 = scale handle (corner index)
//   -1 = no handle hit
int hitTestSelectionHandle(float x, float y) {
    Selection sel;
    {
        std::lock_guard<std::mutex> lock(g_selectionMutex);
        sel = g_selection;
    }
    if (sel.kind == ShapeKind::None) return -1;
    Obb obb;
    if (!obbForSelection(sel, obb)) return -1;

    // Rotate handle (skip for circles).
    if (sel.kind != ShapeKind::Circle) {
        float rhX, rhY;
        rotateHandlePosition(obb, rhX, rhY);
        float dx = x - rhX, dy = y - rhY;
        if (dx*dx + dy*dy <= vpxToDoc(kHandleHitRadiusViewPx) * vpxToDoc(kHandleHitRadiusViewPx)) {
            return -2;
        }
    }

    // Scale handles.
    int n = scaleHandleCount(sel.kind);
    for (int i = 0; i < n; ++i) {
        float hx, hy;
        scaleHandlePosition(obb, sel.kind, i, hx, hy);
        float dx = x - hx, dy = y - hy;
        if (dx*dx + dy*dy <= vpxToDoc(kHandleHitRadiusViewPx) * vpxToDoc(kHandleHitRadiusViewPx)) {
            return i;
        }
    }
    return -1;
}

bool isPointInsideObb(const Obb& o, float x, float y) {
    float lx, ly;
    rotateWorldToLocal(o, x, y, lx, ly);
    return std::fabs(lx) <= o.hw && std::fabs(ly) <= o.hh;
}

// Begin an interaction at (x, y). Tries handles first, then shape body
// (re-hit-test if no current selection or tap is outside selected OBB).
// Returns drag mode: 0=none, 1=move, 2=scale, 3=rotate.
JNIEXPORT jint JNICALL
Java_com_bk_drawing_NativeRenderer_beginInteractionAt(
        JNIEnv*, jobject, jfloat x, jfloat y) {
    int handleHit = hitTestSelectionHandle(x, y);

    if (handleHit == -2) {
        // Rotate handle. Capture initial state.
        Selection sel;
        Obb obb;
        {
            std::lock_guard<std::mutex> lock(g_selectionMutex);
            sel = g_selection;
        }
        if (!obbForSelection(sel, obb)) return 0;
        std::lock_guard<std::mutex> lock(g_selectionMutex);
        g_drag.mode = DragMode::Rotate;
        g_drag.centerX = obb.cx;
        g_drag.centerY = obb.cy;
        g_drag.initialPenAngle = std::atan2(y - obb.cy, x - obb.cx);
        g_drag.initialRotation = obb.rotation;
        // Lines don't have a rotation field; snapshot initial endpoints
        // so we can recompute from initial + delta on each update.
        if (sel.kind == ShapeKind::Line
            && sel.layerIdx < g_layers.size()
            && g_layers[sel.layerIdx]
            && sel.shapeIdx < g_layers[sel.layerIdx]->lines.size()) {
            g_drag.initialLine = g_layers[sel.layerIdx]->lines[sel.shapeIdx];
        }
        g_transformBeforeSel = sel;
        snapshotSelectionShape(sel, g_transformBeforeShape);
        return 3;
    }

    if (handleHit >= 0) {
        // Scale handle. Anchor = opposite handle's world position.
        Selection sel;
        Obb obb;
        {
            std::lock_guard<std::mutex> lock(g_selectionMutex);
            sel = g_selection;
        }
        if (!obbForSelection(sel, obb)) return 0;
        int anchorIdx;
        if (sel.kind == ShapeKind::Line) {
            anchorIdx = (handleHit == 0) ? 1 : 0;
        } else {
            anchorIdx = (handleHit + 2) % 4;   // diagonally opposite
        }
        float ax, ay;
        scaleHandlePosition(obb, sel.kind, anchorIdx, ax, ay);
        std::lock_guard<std::mutex> lock(g_selectionMutex);
        g_drag.mode = DragMode::Scale;
        g_drag.handleIdx = handleHit;
        g_drag.anchorX = ax;
        g_drag.anchorY = ay;
        g_drag.initialRotation = obb.rotation;
        g_transformBeforeSel = sel;
        snapshotSelectionShape(sel, g_transformBeforeShape);
        return 2;
    }

    // No handle hit. Decide between "move existing selection if tap is
    // inside its OBB" vs "re-hit-test for a new shape selection".
    {
        Selection sel;
        Obb obb;
        {
            std::lock_guard<std::mutex> lock(g_selectionMutex);
            sel = g_selection;
        }
        if (sel.kind != ShapeKind::None
            && obbForSelection(sel, obb)
            && isPointInsideObb(obb, x, y)) {
            std::lock_guard<std::mutex> lock(g_selectionMutex);
            g_drag.mode = DragMode::Move;
            g_drag.moveOffsetX = x - obb.cx;
            g_drag.moveOffsetY = y - obb.cy;
            g_transformBeforeSel = sel;
            snapshotSelectionShape(sel, g_transformBeforeShape);
            return 1;
        }
    }
    if (hitTestActiveVectorLayer(x, y)) {
        // Recover the new selection's center to capture the move offset.
        Selection sel;
        Obb obb;
        {
            std::lock_guard<std::mutex> lock(g_selectionMutex);
            sel = g_selection;
        }
        std::lock_guard<std::mutex> lock(g_selectionMutex);
        g_drag.mode = DragMode::Move;
        if (obbForSelection(sel, obb)) {
            g_drag.moveOffsetX = x - obb.cx;
            g_drag.moveOffsetY = y - obb.cy;
        } else {
            g_drag.moveOffsetX = 0.0f;
            g_drag.moveOffsetY = 0.0f;
        }
        g_transformBeforeSel = sel;
        snapshotSelectionShape(sel, g_transformBeforeShape);
        return 1;
    }
    // Empty tap — selection cleared by hitTestActiveVectorLayer.
    std::lock_guard<std::mutex> lock(g_selectionMutex);
    g_drag.mode = DragMode::None;
    return 0;
}

// Translate the given selection's shape by (dx, dy). Caller must hold
// any necessary locks and have validated layer/index. Used by both
// translateSelection (incremental) and applyMoveTo (snap-aware).
void translateShape(Layer& layer, const Selection& sel, float dx, float dy) {
    switch (sel.kind) {
        case ShapeKind::Line:
            if (sel.shapeIdx < layer.lines.size()) {
                auto& l = layer.lines[sel.shapeIdx];
                l.x0 += dx; l.y0 += dy;
                l.x1 += dx; l.y1 += dy;
            }
            break;
        case ShapeKind::Rect:
            if (sel.shapeIdx < layer.rects.size()) {
                auto& r = layer.rects[sel.shapeIdx];
                r.x0 += dx; r.y0 += dy;
                r.x1 += dx; r.y1 += dy;
            }
            break;
        case ShapeKind::Ellipse:
            if (sel.shapeIdx < layer.ellipses.size()) {
                auto& e = layer.ellipses[sel.shapeIdx];
                e.cx += dx; e.cy += dy;
            }
            break;
        case ShapeKind::Circle:
            if (sel.shapeIdx < layer.circles.size()) {
                auto& c = layer.circles[sel.shapeIdx];
                c.cx += dx; c.cy += dy;
            }
            break;
        case ShapeKind::None:
            break;
    }
}

// Apply a move interaction: snap-aware absolute drag. Computes the
// would-be center (penX − captured offset), snaps that against other
// shapes' targets (excluding self), then translates so the shape's
// center matches the snapped position.
void applyMoveTo(float x, float y) {
    Selection sel;
    DragState d;
    {
        std::lock_guard<std::mutex> lock(g_selectionMutex);
        sel = g_selection;
        d   = g_drag;
    }
    if (d.mode != DragMode::Move || sel.kind == ShapeKind::None) return;
    if (sel.layerIdx >= g_layers.size() || !g_layers[sel.layerIdx]) return;
    Layer& layer = *g_layers[sel.layerIdx];
    if (layer.type != LayerType::Vector) return;

    Obb obb;
    if (!obbForSelection(sel, obb)) return;

    float targetCx = x - d.moveOffsetX;
    float targetCy = y - d.moveOffsetY;

    SnapHit snap = findSnap(targetCx, targetCy, &sel);
    if (snap.found) {
        targetCx = snap.x;
        targetCy = snap.y;
    }

    float dx = targetCx - obb.cx;
    float dy = targetCy - obb.cy;
    translateShape(layer, sel, dx, dy);

    {
        std::lock_guard<std::mutex> lock(g_selectionMutex);
        g_drag.snapActive = snap.found;
        g_drag.snapX = snap.x;
        g_drag.snapY = snap.y;
    }
}

// Apply a scale interaction: drag of handle to (x, y). Anchor (opposite
// corner) stays fixed in world space. Computes new local extents from
// the (anchor → pen) vector rotated into shape-local frame.
void applyScaleTo(float x, float y) {
    Selection sel;
    DragState d;
    {
        std::lock_guard<std::mutex> lock(g_selectionMutex);
        sel = g_selection;
        d   = g_drag;
    }
    if (d.mode != DragMode::Scale || sel.kind == ShapeKind::None) return;
    if (sel.layerIdx >= g_layers.size() || !g_layers[sel.layerIdx]) return;
    Layer& layer = *g_layers[sel.layerIdx];

    // Snap the dragged handle's pen position against other shapes'
    // targets (excluding self) before recomputing extents.
    SnapHit snap = findSnap(x, y, &sel);
    if (snap.found) {
        x = snap.x;
        y = snap.y;
    }
    {
        std::lock_guard<std::mutex> lock(g_selectionMutex);
        g_drag.snapActive = snap.found;
        g_drag.snapX = snap.x;
        g_drag.snapY = snap.y;
    }

    // New center is midpoint of anchor and pen in world.
    float newCx = (d.anchorX + x) * 0.5f;
    float newCy = (d.anchorY + y) * 0.5f;
    // Diagonal vector in world, rotated into shape-local frame to recover
    // (full-)width and -height.
    float c = std::cos(-d.initialRotation), s = std::sin(-d.initialRotation);
    float wdx = x - d.anchorX;
    float wdy = y - d.anchorY;
    float ldx = wdx * c - wdy * s;
    float ldy = wdx * s + wdy * c;
    float newHw = std::fabs(ldx) * 0.5f;
    float newHh = std::fabs(ldy) * 0.5f;
    if (newHw < 0.5f) newHw = 0.5f;
    if (newHh < 0.5f) newHh = 0.5f;

    switch (sel.kind) {
        case ShapeKind::Rect:
            if (sel.shapeIdx < layer.rects.size()) {
                auto& r = layer.rects[sel.shapeIdx];
                r.x0 = newCx - newHw; r.y0 = newCy - newHh;
                r.x1 = newCx + newHw; r.y1 = newCy + newHh;
                // rotation unchanged
            }
            break;
        case ShapeKind::Ellipse:
            if (sel.shapeIdx < layer.ellipses.size()) {
                auto& e = layer.ellipses[sel.shapeIdx];
                e.cx = newCx; e.cy = newCy;
                e.rx = newHw; e.ry = newHh;
            }
            break;
        case ShapeKind::Circle:
            if (sel.shapeIdx < layer.circles.size()) {
                auto& cir = layer.circles[sel.shapeIdx];
                // For a circle, drag any handle = scale uniformly. Use
                // distance from anchor to pen as the diameter.
                float dx = x - d.anchorX, dy = y - d.anchorY;
                float diam = std::sqrt(dx*dx + dy*dy);
                cir.cx = newCx; cir.cy = newCy;
                cir.radius = std::max(diam * 0.5f, 0.5f);
            }
            break;
        case ShapeKind::Line:
            if (sel.shapeIdx < layer.lines.size()) {
                auto& l = layer.lines[sel.shapeIdx];
                // For Line, the dragged handle is one endpoint, the
                // anchor is the other. Just move that endpoint.
                if (d.handleIdx == 0) {
                    l.x0 = x; l.y0 = y;
                } else {
                    l.x1 = x; l.y1 = y;
                }
            }
            break;
        case ShapeKind::None:
            break;
    }
}

// Apply a rotate interaction: drag of rotate handle to (x, y). Computes
// new rotation = initialRotation + (current pen angle − initial pen angle).
void applyRotateTo(float x, float y) {
    Selection sel;
    DragState d;
    {
        std::lock_guard<std::mutex> lock(g_selectionMutex);
        sel = g_selection;
        d   = g_drag;
    }
    if (d.mode != DragMode::Rotate || sel.kind == ShapeKind::None) return;
    if (sel.layerIdx >= g_layers.size() || !g_layers[sel.layerIdx]) return;
    Layer& layer = *g_layers[sel.layerIdx];

    float curAngle = std::atan2(y - d.centerY, x - d.centerX);
    float delta = curAngle - d.initialPenAngle;
    float newRotation = d.initialRotation + delta;

    // Snap to multiples of 15 deg within a 5 deg window when snap is on.
    if (g_snapEnabled.load() != 0) {
        constexpr float kStep = 3.14159265358979323846f / 12.0f;  // 15 deg
        constexpr float kTol  = 5.0f * 3.14159265358979323846f / 180.0f;
        float k = std::round(newRotation / kStep);
        float snapped = k * kStep;
        if (std::fabs(newRotation - snapped) <= kTol) {
            // Re-derive delta so Line endpoints (which compute from
            // initialLine + delta) match the snapped rotation exactly.
            delta = snapped - d.initialRotation;
            newRotation = snapped;
        }
    }
    // Rotate has no on-canvas marker target, so no snapActive flag here.
    {
        std::lock_guard<std::mutex> lock(g_selectionMutex);
        g_drag.snapActive = false;
    }

    switch (sel.kind) {
        case ShapeKind::Rect:
            if (sel.shapeIdx < layer.rects.size())
                layer.rects[sel.shapeIdx].rotation = newRotation;
            break;
        case ShapeKind::Ellipse:
            if (sel.shapeIdx < layer.ellipses.size())
                layer.ellipses[sel.shapeIdx].rotation = newRotation;
            break;
        case ShapeKind::Line:
            if (sel.shapeIdx < layer.lines.size()) {
                // Rotate p0, p1 around the line's midpoint by `delta`
                // (relative to initial endpoints, so we don't accumulate
                // float drift across many move events).
                auto& l = layer.lines[sel.shapeIdx];
                float cx = (d.initialLine.x0 + d.initialLine.x1) * 0.5f;
                float cy = (d.initialLine.y0 + d.initialLine.y1) * 0.5f;
                float c = std::cos(delta), s = std::sin(delta);
                auto rot = [&](float px, float py, float& ox, float& oy) {
                    float dx = px - cx, dy = py - cy;
                    ox = cx + dx * c - dy * s;
                    oy = cy + dx * s + dy * c;
                };
                rot(d.initialLine.x0, d.initialLine.y0, l.x0, l.y0);
                rot(d.initialLine.x1, d.initialLine.y1, l.x1, l.y1);
            }
            break;
        case ShapeKind::Circle:
        case ShapeKind::None:
            break;
    }
}

JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_updateInteractionAt(
        JNIEnv*, jobject, jfloat x, jfloat y) {
    DragMode mode;
    {
        std::lock_guard<std::mutex> lock(g_selectionMutex);
        mode = g_drag.mode;
    }
    if (mode == DragMode::Scale) {
        applyScaleTo(x, y);
    } else if (mode == DragMode::Rotate) {
        applyRotateTo(x, y);
    } else if (mode == DragMode::Move) {
        applyMoveTo(x, y);
    }
}

JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_endInteraction(JNIEnv*, jobject) {
    DragMode  wasMode;
    Selection beforeSel;
    ShapeData beforeShape;
    {
        std::lock_guard<std::mutex> lock(g_selectionMutex);
        wasMode     = g_drag.mode;
        beforeSel   = g_transformBeforeSel;
        beforeShape = g_transformBeforeShape;
        g_drag.mode = DragMode::None;
        g_drag.snapActive = false;
        g_transformBeforeSel   = Selection{};
        g_transformBeforeShape = ShapeData{};
    }
    if (wasMode == DragMode::None || beforeSel.kind == ShapeKind::None) return;
    if (beforeShape.kind == ShapeKind::None) return;

    ShapeData afterShape;
    if (!snapshotSelectionShape(beforeSel, afterShape)) return;
    if (shapeDataEqual(beforeShape, afterShape)) return;

    UndoEntry entry;
    entry.op          = UndoOp::VectorMutate;
    entry.layerIdx    = beforeSel.layerIdx;
    entry.shapeIdx    = beforeSel.shapeIdx;
    entry.beforeShape = beforeShape;
    entry.afterShape  = afterShape;
    pushUndoEntry(std::move(entry));
}

JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_clearSelection(JNIEnv*, jobject) {
    std::lock_guard<std::mutex> lock(g_selectionMutex);
    g_selection = Selection{};
}

JNIEXPORT jboolean JNICALL
Java_com_bk_drawing_NativeRenderer_hasSelection(JNIEnv*, jobject) {
    std::lock_guard<std::mutex> lock(g_selectionMutex);
    return g_selection.kind != ShapeKind::None ? JNI_TRUE : JNI_FALSE;
}

// Translate the currently selected shape by (dx, dy) doc-pixels. No-op
// if there's no selection or the layer is gone.
JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_translateSelection(
        JNIEnv*, jobject, jfloat dx, jfloat dy) {
    Selection sel;
    {
        std::lock_guard<std::mutex> lock(g_selectionMutex);
        sel = g_selection;
    }
    if (sel.kind == ShapeKind::None) return;
    if (sel.layerIdx >= g_layers.size() || !g_layers[sel.layerIdx]) return;
    Layer& layer = *g_layers[sel.layerIdx];
    if (layer.type != LayerType::Vector) return;
    translateShape(layer, sel, dx, dy);
}

// Snap-aware absolute move: drives an in-progress Move drag with the
// pen's current position. Uses the captured moveOffset (snapshotted in
// beginInteractionAt) so the user's grab-point follows the pen, and
// snaps the would-be center against other shapes' targets / grid.
JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_moveSelectionTo(
        JNIEnv*, jobject, jfloat x, jfloat y) {
    applyMoveTo(x, y);
}

// Remove the currently selected shape from its layer. Clears selection.
JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_deleteSelection(JNIEnv*, jobject) {
    Selection sel;
    {
        std::lock_guard<std::mutex> lock(g_selectionMutex);
        sel = g_selection;
        g_selection = Selection{};
    }
    if (sel.kind == ShapeKind::None) return;
    if (sel.layerIdx >= g_layers.size() || !g_layers[sel.layerIdx]) return;
    Layer& layer = *g_layers[sel.layerIdx];
    if (layer.type != LayerType::Vector) return;

    // Snapshot the shape before erase, for undo.
    UndoEntry entry;
    entry.op = UndoOp::VectorDelete;
    entry.layerIdx = sel.layerIdx;
    entry.shapeIdx = sel.shapeIdx;
    bool captured = false;

    switch (sel.kind) {
        case ShapeKind::Line:
            if (sel.shapeIdx < layer.lines.size()) {
                entry.beforeShape.kind = ShapeKind::Line;
                entry.beforeShape.line = layer.lines[sel.shapeIdx];
                captured = true;
                layer.lines.erase(layer.lines.begin() + sel.shapeIdx);
            }
            break;
        case ShapeKind::Rect:
            if (sel.shapeIdx < layer.rects.size()) {
                entry.beforeShape.kind = ShapeKind::Rect;
                entry.beforeShape.rect = layer.rects[sel.shapeIdx];
                captured = true;
                layer.rects.erase(layer.rects.begin() + sel.shapeIdx);
            }
            break;
        case ShapeKind::Ellipse:
            if (sel.shapeIdx < layer.ellipses.size()) {
                entry.beforeShape.kind = ShapeKind::Ellipse;
                entry.beforeShape.ellipse = layer.ellipses[sel.shapeIdx];
                captured = true;
                layer.ellipses.erase(layer.ellipses.begin() + sel.shapeIdx);
            }
            break;
        case ShapeKind::Circle:
            if (sel.shapeIdx < layer.circles.size()) {
                entry.beforeShape.kind = ShapeKind::Circle;
                entry.beforeShape.circle = layer.circles[sel.shapeIdx];
                captured = true;
                layer.circles.erase(layer.circles.begin() + sel.shapeIdx);
            }
            break;
        case ShapeKind::None:
            break;
    }
    saveVectorLayer(sel.layerIdx, layer);
    if (captured) pushUndoEntry(std::move(entry));
}

// Persist the active vector layer to disk. Used after a transform-drag
// completes so the move/scale/rotate is durable.
JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_persistActiveVectorLayer(
        JNIEnv*, jobject) {
    if (g_activeLayer >= g_layers.size() || !g_layers[g_activeLayer]) return;
    if (g_layers[g_activeLayer]->type != LayerType::Vector) return;
    saveVectorLayer(g_activeLayer, *g_layers[g_activeLayer]);
}

// Live preview during shape-tool drag. Color follows the current brush
// color; width follows kDefaultLineWidth. shapeType matches the
// addXxx-call shape semantics in renderShapePreviewToFront. If
// `snapped` is true, also draws a snap-marker overlay at (x1, y1).
JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_renderShapePreview(
        JNIEnv* env, jobject,
        jint width, jint height,
        jfloatArray transform,
        jint shapeType,
        jfloat x0, jfloat y0, jfloat x1, jfloat y1,
        jboolean snapped) {
    ensureInited();
    uint32_t rgb = g_currentBrushColor.load();
    renderShapePreviewToFront(env, width, height, transform,
                              shapeType, x0, y0, x1, y1,
                              rgb, kDefaultLineWidth, /*alpha=*/0.7f,
                              snapped == JNI_TRUE);
}

// Find nearest snap target for (x, y); fills output[0..2] with
// [snapX, snapY, didSnap (1.0/0.0)]. If no target within range, output
// is (x, y, 0). Output array must have length >= 3.
JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_snapPoint(
        JNIEnv* env, jobject,
        jfloat x, jfloat y, jfloatArray output) {
    SnapHit h = findSnap(x, y);
    jfloat* arr = env->GetFloatArrayElements(output, nullptr);
    arr[0] = h.x;
    arr[1] = h.y;
    arr[2] = h.found ? 1.0f : 0.0f;
    env->ReleaseFloatArrayElements(output, arr, 0);
}

JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_setSnapEnabled(
        JNIEnv*, jobject, jboolean enabled) {
    g_snapEnabled.store(enabled == JNI_TRUE ? 1 : 0);
}

// Set the page bounds (in doc-pixels). Drawn during composite as a thin
// outlined rectangle so the user can see where the page edges are when
// zoomed/rotated. Pass any zero-size rect to disable the outline.
JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_setPageBounds(
        JNIEnv*, jobject,
        jfloat x0, jfloat y0, jfloat x1, jfloat y1) {
    std::lock_guard<std::mutex> lock(g_pageBoundsMutex);
    g_pageX0 = x0; g_pageY0 = y0;
    g_pageX1 = x1; g_pageY1 = y1;
}

// Update the cached view scale (doc-px per view-px). Read by snap/hit-
// test code and selection-overlay rendering to keep their effective
// radii / sizes constant in screen space across pan/zoom/rotate.
JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_setViewScale(
        JNIEnv*, jobject, jfloat scale) {
    if (!(scale > 1e-6f)) return;   // also rejects NaN
    uint32_t bits;
    std::memcpy(&bits, &scale, sizeof(bits));
    g_viewScaleBits.store(bits);
}

// Throw away an in-progress brush/eraser stroke without baking it into
// tiles. Called when a 2-finger gesture interrupts a stroke so the
// partial preview doesn't end up as an unwanted permanent mark.
JNIEXPORT void JNICALL
Java_com_bk_drawing_NativeRenderer_discardStroke(JNIEnv*, jobject) {
    g_current.samples.clear();
    g_liveEmitter.reset();
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
    applyPendingShapes();
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
    // Page-clip in doc-pixels: the live preview uses uTransform = doc→buffer
    // and uCenter is in doc-pixels, so the shader's vDocPos is doc-pixels
    // and the page rect goes in unmodified.
    {
        PageClip pageClip = readPageClip();
        uploadPageClip(g_dab.uPageMin, g_dab.uPageMax,
                       g_dab.uPageActive, pageClip);
    }
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
    applyPendingShapes();
    ensureAtLeastOneLayer();

    size_t layerIdx = g_strokeTarget < g_layers.size() ? g_strokeTarget
                                                       : g_layers.size() - 1;

    // Snapshot tiles in the stroke's bbox BEFORE bake (only meaningful
    // for raster layers; bake is a no-op for vector). Skip snapshot if
    // there are no samples — the bake is a no-op too.
    bool   snapForUndo = (layerIdx < g_layers.size()
                          && g_layers[layerIdx]
                          && g_layers[layerIdx]->type == LayerType::Raster);
    int    tx0 = 0, tx1 = 0, ty0 = 0, ty1 = 0;
    UndoEntry entry;
    if (snapForUndo && currentStrokeTileBbox(tx0, tx1, ty0, ty1)) {
        entry.op = UndoOp::RasterStroke;
        entry.layerIdx = layerIdx;
        snapshotTilesInBbox(layerIdx, tx0, tx1, ty0, ty1, entry.beforeTiles);
    } else {
        snapForUndo = false;
    }

    std::vector<int64_t> dirty;
    bakeCurrentStrokeIntoTiles(&dirty, layerIdx);

    if (snapForUndo) {
        // Combined pass: readback each bbox tile once and reuse the bytes
        // for both the undo's after-snapshot AND the on-disk save. This
        // avoids reading every dirty tile twice (once for save, once for
        // snapshot) — important because glReadPixels stalls the pipeline
        // and the front-buffered renderer's commit can otherwise overrun
        // a vsync, briefly double-rendering the stroke during the swap.
        Layer& layer = *g_layers[layerIdx];
        size_t cellCount = static_cast<size_t>((tx1 - tx0 + 1))
                         * static_cast<size_t>((ty1 - ty0 + 1));
        entry.afterTiles.reserve(cellCount);
        GLint prevFboInner = 0;
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prevFboInner);
        for (int ty = ty0; ty <= ty1; ++ty) {
            for (int tx = tx0; tx <= tx1; ++tx) {
                TileSnap snap;
                snap.tx = tx; snap.ty = ty;
                auto it = layer.tiles.find(tileKey(tx, ty));
                if (it != layer.tiles.end()) {
                    snap.existed = true;
                    snap.bytes.resize(kTileBytes);
                    glBindFramebuffer(GL_FRAMEBUFFER, it->second.fbo);
                    glReadPixels(0, 0, kTileSize, kTileSize,
                                 GL_RGBA, GL_UNSIGNED_BYTE, snap.bytes.data());
                    writeTileBytesToDisk(layerIdx, tx, ty, snap.bytes.data());
                }
                entry.afterTiles.push_back(std::move(snap));
            }
        }
        glBindFramebuffer(GL_FRAMEBUFFER, prevFboInner);

        bool changed = entry.beforeTiles.size() == entry.afterTiles.size();
        if (changed) {
            // Confirm at least one tile differs (avoids a useless entry
            // when, e.g., the stroke missed every pixel of every tile).
            changed = false;
            for (size_t i = 0; i < entry.beforeTiles.size(); ++i) {
                const auto& b = entry.beforeTiles[i];
                const auto& a = entry.afterTiles[i];
                if (b.existed != a.existed
                    || b.bytes.size() != a.bytes.size()
                    || (b.existed && std::memcmp(b.bytes.data(),
                                                  a.bytes.data(),
                                                  b.bytes.size()) != 0)) {
                    changed = true;
                    break;
                }
            }
        }
        if (changed) pushUndoEntry(std::move(entry));
    } else {
        for (int64_t k : dirty) {
            saveTileToDisk(layerIdx, k);
        }
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
    applyPendingShapes();
    compositeAllLayers(env, width, height, transform);
}

}  // extern "C"
