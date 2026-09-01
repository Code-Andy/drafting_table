#pragma once

// A platform-neutral description of the Metal tile renderer.  This header is
// intentionally free of Objective-C, UIKit, Metal, and OpenGL types.  The
// implementation accepts opaque native handles so callers can keep those
// framework types at the iPad bridge boundary.

#include "DTCore.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <span>
#include <string>

namespace drafting_table::metal {

inline constexpr std::int32_t kTileSize = kDefaultTileSize;
inline constexpr std::int32_t kTileApron = 1;
inline constexpr std::int32_t kTileTextureExtent = kTileSize + 2 * kTileApron;

struct TileLayout {
    static constexpr std::int32_t tileSize = kTileSize;
    static constexpr std::int32_t apron = kTileApron;
    static constexpr std::int32_t textureExtent = kTileTextureExtent;

    static TileAddress addressFor(Vec2 documentPoint) {
        return TileAddress::fromDocument(documentPoint, tileSize);
    }
    static constexpr Vec2 localPoint(TileAddress tile, Vec2 documentPoint) {
        return {documentPoint.x - static_cast<float>(tile.x) * tileSize,
                documentPoint.y - static_cast<float>(tile.y) * tileSize};
    }
    // Texture-space coordinates include the one-pixel apron.  Dabs may be
    // supplied just outside [0, tileSize] so neighboring tiles can be baked
    // without a separate edge primitive.
    static constexpr Vec2 texturePoint(Vec2 tileLocalPoint) {
        return {tileLocalPoint.x + apron, tileLocalPoint.y + apron};
    }
};

struct PremultipliedColor {
    float r = 0.0f;
    float g = 0.0f;
    float b = 0.0f;
    float a = 0.0f;
};

// GPU instance layout: 48 bytes, matching the DTMetalDabInstance struct in
// DTMetalShaders.metal.  Color is premultiplied; the color pass uses OVER.
struct alignas(16) DabInstance {
    Vec2 center{};       // tile-local pixels; [0, 256] is the interior
    Vec2 radii{};        // oriented ellipse semi-axes; equal for round dabs
    float rotationRadians = 0.0f;
    float opacity = 1.0f;
    float hardness = 0.85f;
    float reserved = 0.0f;
    std::array<float, 4> colorPremultiplied{};

    constexpr DabInstance() = default;
    constexpr DabInstance(Vec2 centerPoint,
                          float radiusPixels,
                          float opacityValue,
                          float hardnessValue,
                          PremultipliedColor color)
        : center(centerPoint),
          radii{radiusPixels, radiusPixels},
          opacity(opacityValue),
          hardness(hardnessValue),
          colorPremultiplied{color.r, color.g, color.b, color.a} {}

    constexpr DabInstance(Vec2 centerPoint,
                          Vec2 radiusPixels,
                          float rotation,
                          float opacityValue,
                          float hardnessValue,
                          PremultipliedColor color)
        : center(centerPoint),
          radii(radiusPixels),
          rotationRadians(rotation),
          opacity(opacityValue),
          hardness(hardnessValue),
          colorPremultiplied{color.r, color.g, color.b, color.a} {}
};
static_assert(sizeof(DabInstance) == 48, "Metal dab instance layout changed");
static_assert(alignof(DabInstance) == 16, "Metal dab instance alignment changed");

struct TileDabBatch {
    TileAddress tile{};
    std::span<const DabInstance> dabs{};
};

struct CompositeParameters {
    // Document-to-view transform in the same form as CanvasTransform.  The
    // viewport is in drawable pixels, not UIKit points.
    float scale = 1.0f;
    float rotationRadians = 0.0f;
    Vec2 translation{};
    Vec2 viewportSize{};
    float opacity = 1.0f;
};

enum class BackendResult : std::uint8_t {
    ok = 0,
    invalidArgument,
    unsupported,
    resourceFailure,
    encodingFailure,
};

struct BackendOptions {
    // Zero means unlimited. A positive limit fails new allocation instead of
    // silently evicting dirty GPU state; persistence/restore hooks must exist
    // before an eviction policy can be safe.
    std::size_t maxResidentTiles = 0;
};

/// Objective-C++ implementation of a sparse tile backend.
///
/// `nativeDevice`, command buffers, and target textures are opaque pointers to
/// their corresponding Metal objects.  Under ARC, pass them as
/// `(__bridge void *)object`.  The C++ API can therefore remain usable by a
/// portable renderer boundary and does not force Metal headers into core.
class Backend final {
public:
    static std::unique_ptr<Backend> create(void* nativeDevice,
                                           BackendOptions options = {},
                                           std::string* error = nullptr);
    ~Backend();

    Backend(Backend&&) noexcept;
    Backend& operator=(Backend&&) noexcept;
    Backend(const Backend&) = delete;
    Backend& operator=(const Backend&) = delete;

    BackendResult encodeDabs(void* nativeCommandBuffer,
                             const TileDabBatch& batch);
    BackendResult encodeDabs(void* nativeCommandBuffer,
                             std::span<const TileDabBatch> batches);

    // Composite resident tile interiors into a drawable or offscreen target.
    // The target must be an MTLTexture with a color format supported by the
    // backend's composite pipeline cache.
    BackendResult encodeComposite(void* nativeCommandBuffer,
                                   void* nativeTargetTexture,
                                   std::span<const TileAddress> visibleTiles,
                                   const CompositeParameters& parameters);

    // Pulls edge/corner pixels from resident neighboring tiles into each
    // tile's one-pixel apron. Missing neighbors remain transparent. Call after
    // baking dabs and before linear-filtered or rotated compositing.
    BackendResult encodeApronResolve(void* nativeCommandBuffer);

    std::size_t residentTileCount() const noexcept;
    // Returns an unretained opaque MTLTexture pointer for read-only sampling
    // in a caller-owned pass.  The backend must outlive that pass.
    void* nativeCoverageTexture(TileAddress tile) const noexcept;
    void purgeTiles() noexcept;
    const std::string& lastError() const noexcept;

private:
    struct Impl;
    explicit Backend(std::unique_ptr<Impl> implementation) noexcept;
    std::unique_ptr<Impl> impl_;
};

} // namespace drafting_table::metal
