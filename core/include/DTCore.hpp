#pragma once

// Portable drawing primitives shared by the Android and iPad front ends.
//
// This header deliberately has no dependency on UIKit, Android, OpenGL,
// Metal, JNI, or a platform file format.  Platform renderers should consume
// the state exposed here rather than reaching into their own input structs.

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <limits>
#include <optional>
#include <span>
#include <unordered_map>
#include <utility>
#include <vector>

namespace drafting_table {

struct Vec2 {
    float x = 0.0f;
    float y = 0.0f;

    constexpr Vec2() = default;
    constexpr Vec2(float xValue, float yValue) : x(xValue), y(yValue) {}

    constexpr Vec2 operator+(Vec2 rhs) const { return {x + rhs.x, y + rhs.y}; }
    constexpr Vec2 operator-(Vec2 rhs) const { return {x - rhs.x, y - rhs.y}; }
    constexpr Vec2 operator-() const { return {-x, -y}; }
    constexpr Vec2 operator*(float scalar) const { return {x * scalar, y * scalar}; }
    constexpr Vec2 operator/(float scalar) const { return {x / scalar, y / scalar}; }
    constexpr Vec2& operator+=(Vec2 rhs) { x += rhs.x; y += rhs.y; return *this; }
    constexpr Vec2& operator-=(Vec2 rhs) { x -= rhs.x; y -= rhs.y; return *this; }
    constexpr Vec2& operator*=(float scalar) { x *= scalar; y *= scalar; return *this; }

    constexpr float dot(Vec2 rhs) const { return x * rhs.x + y * rhs.y; }
    constexpr float lengthSquared() const { return dot(*this); }
    float length() const { return std::sqrt(lengthSquared()); }
    Vec2 normalized(float epsilon = 1.0e-6f) const {
        const float len = length();
        return len <= epsilon ? Vec2{} : *this / len;
    }
};

constexpr Vec2 operator*(float scalar, Vec2 value) { return value * scalar; }

inline bool nearlyEqual(Vec2 lhs, Vec2 rhs, float epsilon = 1.0e-5f) {
    return std::fabs(lhs.x - rhs.x) <= epsilon &&
           std::fabs(lhs.y - rhs.y) <= epsilon;
}

// Canonical input sample.  Flags describe the lifecycle of a sample; a
// renderer must not bake PREDICTED samples into a document.
enum class SampleFlags : std::uint32_t {
    None              = 0,
    Real              = 1u << 0,
    Predicted         = 1u << 1,
    Coalesced         = 1u << 2,
    PressureEstimated = 1u << 3,
    AltitudeEstimated = 1u << 4,
    AzimuthEstimated  = 1u << 5,
    RollEstimated     = 1u << 6,
};

constexpr SampleFlags operator|(SampleFlags lhs, SampleFlags rhs) {
    return static_cast<SampleFlags>(static_cast<std::uint32_t>(lhs) |
                                    static_cast<std::uint32_t>(rhs));
}
constexpr SampleFlags operator&(SampleFlags lhs, SampleFlags rhs) {
    return static_cast<SampleFlags>(static_cast<std::uint32_t>(lhs) &
                                    static_cast<std::uint32_t>(rhs));
}
constexpr bool operator==(SampleFlags lhs, SampleFlags rhs) {
    return static_cast<std::uint32_t>(lhs) == static_cast<std::uint32_t>(rhs);
}
constexpr bool operator!=(SampleFlags lhs, SampleFlags rhs) { return !(lhs == rhs); }
constexpr SampleFlags operator~(SampleFlags value) {
    return static_cast<SampleFlags>(~static_cast<std::uint32_t>(value));
}
constexpr SampleFlags& operator|=(SampleFlags& lhs, SampleFlags rhs) {
    lhs = lhs | rhs;
    return lhs;
}
constexpr bool hasFlag(SampleFlags value, SampleFlags flag) {
    return (value & flag) != SampleFlags::None;
}

// Upper-case aliases mirror the event names used by UIKit and keep call
// sites concise (dt::REAL, dt::PREDICTED, ...).
inline constexpr SampleFlags REAL = SampleFlags::Real;
inline constexpr SampleFlags PREDICTED = SampleFlags::Predicted;
inline constexpr SampleFlags COALESCED = SampleFlags::Coalesced;
inline constexpr SampleFlags PRESSURE_ESTIMATED = SampleFlags::PressureEstimated;
inline constexpr SampleFlags ALTITUDE_ESTIMATED = SampleFlags::AltitudeEstimated;
inline constexpr SampleFlags AZIMUTH_ESTIMATED = SampleFlags::AzimuthEstimated;
inline constexpr SampleFlags ROLL_ESTIMATED = SampleFlags::RollEstimated;

struct PencilSample {
    using Flags = SampleFlags;
    static constexpr SampleFlags REAL = SampleFlags::Real;
    static constexpr SampleFlags PREDICTED = SampleFlags::Predicted;
    static constexpr SampleFlags COALESCED = SampleFlags::Coalesced;
    static constexpr SampleFlags PRESSURE_ESTIMATED = SampleFlags::PressureEstimated;
    static constexpr SampleFlags ALTITUDE_ESTIMATED = SampleFlags::AltitudeEstimated;
    static constexpr SampleFlags AZIMUTH_ESTIMATED = SampleFlags::AzimuthEstimated;
    static constexpr SampleFlags ROLL_ESTIMATED = SampleFlags::RollEstimated;

    float x = 0.0f;
    float y = 0.0f;
    float pressure = 0.0f;
    float altitude = 0.0f;
    float azimuth = 0.0f;
    float roll = 0.0f;
    float hoverDistance = 0.0f;
    double timestamp = 0.0;
    std::uint64_t id = 0;
    // UIKit's estimationUpdateIndex is not guaranteed to be globally
    // unique.  estimationId is a stable optional application-level key.
    std::uint64_t estimationUpdateIndex = 0;
    std::uint64_t estimationId = 0;
    SampleFlags flags = SampleFlags::None;

    constexpr Vec2 position() const { return {x, y}; }
    constexpr bool isReal() const { return hasFlag(flags, SampleFlags::Real); }
    constexpr bool isPredicted() const { return hasFlag(flags, SampleFlags::Predicted); }
    constexpr bool isEstimated() const {
        return hasFlag(flags, SampleFlags::PressureEstimated) ||
               hasFlag(flags, SampleFlags::AltitudeEstimated) ||
               hasFlag(flags, SampleFlags::AzimuthEstimated) ||
               hasFlag(flags, SampleFlags::RollEstimated);
    }
};

struct PressureCurve {
    float deadZone = 0.0f;
    float saturation = 1.0f;
    float gamma = 1.0f;
};

class PressureMapper {
public:
    explicit PressureMapper(PressureCurve curve = {}) : curve_(sanitize(curve)) {}

    float map(float rawPressure) const;
    float operator()(float rawPressure) const { return map(rawPressure); }
    const PressureCurve& curve() const { return curve_; }
    void setCurve(PressureCurve curve) { curve_ = sanitize(curve); }

private:
    static PressureCurve sanitize(PressureCurve curve);
    PressureCurve curve_;
};

constexpr std::int32_t kDefaultTileSize = 256;

struct TileAddress {
    std::int32_t x = 0;
    std::int32_t y = 0;

    constexpr bool operator==(const TileAddress&) const = default;
    constexpr bool operator!=(const TileAddress& rhs) const { return !(*this == rhs); }

    static TileAddress fromDocument(Vec2 documentPoint,
                                    std::int32_t tileSize = kDefaultTileSize);
    constexpr Vec2 origin(std::int32_t tileSize = kDefaultTileSize) const {
        return {static_cast<float>(x) * tileSize,
                static_cast<float>(y) * tileSize};
    }
    Vec2 localPoint(Vec2 documentPoint,
                    std::int32_t tileSize = kDefaultTileSize) const;

    // Same signed 32-bit packing used by the existing renderer.  Casting
    // through uint32_t makes negative coordinates round-trip losslessly.
    constexpr std::int64_t key() const {
        const auto ux = static_cast<std::uint32_t>(x);
        const auto uy = static_cast<std::uint32_t>(y);
        return static_cast<std::int64_t>(static_cast<std::uint64_t>(ux) |
                                         (static_cast<std::uint64_t>(uy) << 32));
    }
    static constexpr TileAddress fromKey(std::int64_t packed) {
        const auto bits = static_cast<std::uint64_t>(packed);
        return {static_cast<std::int32_t>(static_cast<std::uint32_t>(bits)),
                static_cast<std::int32_t>(static_cast<std::uint32_t>(bits >> 32))};
    }
};

inline constexpr std::int64_t tileKey(std::int32_t x, std::int32_t y) {
    return TileAddress{x, y}.key();
}
inline constexpr TileAddress tileAddressFromKey(std::int64_t key) {
    return TileAddress::fromKey(key);
}
inline TileAddress tileAddress(Vec2 documentPoint,
                               std::int32_t tileSize = kDefaultTileSize) {
    return TileAddress::fromDocument(documentPoint, tileSize);
}

struct CanvasTransform {
    float scale = 1.0f;
    float rotationRadians = 0.0f;
    Vec2 translation{};

    constexpr CanvasTransform() = default;
    constexpr CanvasTransform(float scaleValue, float rotation, Vec2 offset)
        : scale(scaleValue), rotationRadians(rotation), translation(offset) {}

    Vec2 documentToView(Vec2 documentPoint) const;
    Vec2 viewToDocument(Vec2 viewPoint) const;
    Vec2 apply(Vec2 documentPoint) const { return documentToView(documentPoint); }
    Vec2 inverseApply(Vec2 viewPoint) const { return viewToDocument(viewPoint); }
    CanvasTransform inverse() const;
    // Row-major 3x3 affine matrix, suitable for a platform bridge.
    std::array<float, 9> matrix() const;
};

struct StrokeConfig {
    PressureMapper pressureMapper{};
    float brushSize = 1.0f;
};

class DrawingEngine {
public:
    void beginStroke(const StrokeConfig& config = {});
    void appendSamples(std::span<const PencilSample> real,
                       std::span<const PencilSample> predicted = {});
    bool updateEstimatedSample(std::uint64_t sampleId,
                               const PencilSample& replacement);
    bool updateEstimatedSampleByIndex(std::uint64_t estimationUpdateIndex,
                                      const PencilSample& replacement);
    void endStroke();
    void cancelStroke();

    bool strokeActive() const { return strokeActive_; }
    const StrokeConfig& strokeConfig() const { return config_; }
    const std::vector<PencilSample>& realSamples() const { return realSamples_; }
    const std::vector<PencilSample>& predictedSamples() const { return predictedSamples_; }
    const std::vector<PencilSample>& committedSamples() const { return committedSamples_; }
    void clearCommittedSamples() { committedSamples_.clear(); }

private:
    bool replaceIn(std::vector<PencilSample>& samples,
                   std::uint64_t sampleId,
                   const PencilSample& replacement);
    void indexSample(const PencilSample& sample);

    bool strokeActive_ = false;
    StrokeConfig config_{};
    std::vector<PencilSample> realSamples_;
    std::vector<PencilSample> predictedSamples_;
    std::vector<PencilSample> committedSamples_;
    std::unordered_map<std::uint64_t, std::uint64_t> estimationToSample_;
};

} // namespace drafting_table

// Short namespace used by the platform bridges and examples.
namespace dt = drafting_table;
