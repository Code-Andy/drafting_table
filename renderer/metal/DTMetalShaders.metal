#include <metal_stdlib>
using namespace metal;

// Keep this layout in lockstep with drafting_table::metal::DabInstance.  The
// explicit scalar padding avoids relying on platform-specific float3 packing.
struct DTMetalDabInstance {
    float2 center;
    float2 radii;
    float rotationRadians;
    float opacity;
    float hardness;
    float reserved;
    float4 colorPremultiplied;
};

struct DTDabUniforms {
    float2 textureExtent;
    float apron;
    float reserved;
};

struct DTDabVertexOut {
    float4 position [[position]];
    float2 unit;
    float opacity;
    float hardness;
    float4 colorPremultiplied;
};

constant float2 kDabCorners[6] = {
    float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0),
    float2(-1.0, 1.0), float2(1.0, -1.0), float2(1.0, 1.0)
};

vertex DTDabVertexOut dt_metal_dab_vertex(
    const device DTMetalDabInstance* dabs [[buffer(0)]],
    constant DTDabUniforms& uniforms [[buffer(1)]],
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]]) {
    const DTMetalDabInstance dab = dabs[instanceID];
    const float2 unit = kDabCorners[vertexID];
    // A center of (0, 0) maps to texel (1, 1), leaving the apron available for
    // a radius that crosses an interior tile edge.
    const float2 local = unit * max(dab.radii, float2(0.0));
    const float c = cos(dab.rotationRadians);
    const float s = sin(dab.rotationRadians);
    const float2 rotated = float2(c * local.x - s * local.y,
                                  s * local.x + c * local.y);
    const float2 texturePoint = dab.center + rotated + uniforms.apron;
    const float2 extent = max(uniforms.textureExtent, float2(1.0));
    const float2 clip = float2(texturePoint.x / extent.x * 2.0 - 1.0,
                               1.0 - texturePoint.y / extent.y * 2.0);
    DTDabVertexOut out;
    out.position = float4(clip, 0.0, 1.0);
    out.unit = unit;
    out.opacity = saturate(dab.opacity);
    out.hardness = clamp(dab.hardness, 0.0, 1.0);
    out.colorPremultiplied = dab.colorPremultiplied;
    return out;
}

inline float dt_dab_coverage(DTDabVertexOut in) {
    const float distanceFromCenter = length(in.unit);
    if (distanceFromCenter >= 1.0) return 0.0;
    if (in.hardness >= 1.0 || distanceFromCenter <= in.hardness) {
        return saturate(in.opacity);
    }
    // Match the Android dab shader's quartic soft edge exactly.
    const float t = (1.0 - distanceFromCenter) / (1.0 - in.hardness);
    const float t2 = t * t;
    const float coverage = t2 * t2;
    return saturate(coverage * in.opacity);
}

fragment float4 dt_metal_dab_color(DTDabVertexOut in [[stage_in]]) {
    const float coverage = dt_dab_coverage(in);
    // Inputs are premultiplied; multiply both RGB and A by dab coverage so
    // the render target can use sourceRGB = ONE for OVER compositing.
    return float4(in.colorPremultiplied.rgb * coverage,
                  in.colorPremultiplied.a * coverage);
}

fragment float4 dt_metal_dab_coverage(DTDabVertexOut in [[stage_in]]) {
    const float coverage = dt_dab_coverage(in);
    // The R8 pipeline reads only red.  Source-over/destination-out blend
    // factors use the same scalar for source color and source alpha.
    // Destination-out therefore removes only the covered amount instead of
    // clearing the entire mask.
    return float4(coverage, 0.0, 0.0, coverage);
}

struct DTCompositeUniforms {
    float scale;
    float rotationRadians;
    float2 translation;
    float2 viewportSize;
    float opacity;
    float2 tileOrigin;
};

struct DTTileVertexOut {
    float4 position [[position]];
    float2 uv;
};

constant float2 kTileCorners[4] = {
    float2(0.0, 0.0), float2(1.0, 0.0),
    float2(0.0, 1.0), float2(1.0, 1.0)
};

vertex DTTileVertexOut dt_metal_tile_vertex(
    constant DTCompositeUniforms& uniforms [[buffer(0)]],
    uint vertexID [[vertex_id]]) {
    const float2 local = kTileCorners[vertexID] * 256.0;
    const float2 document = uniforms.tileOrigin + local;
    const float c = cos(uniforms.rotationRadians);
    const float s = sin(uniforms.rotationRadians);
    const float2 rotated = float2(c * document.x - s * document.y,
                                  s * document.x + c * document.y);
    const float2 view = rotated * uniforms.scale + uniforms.translation;
    const float2 viewport = max(uniforms.viewportSize, float2(1.0));
    DTTileVertexOut out;
    out.position = float4(view.x / viewport.x * 2.0 - 1.0,
                          1.0 - view.y / viewport.y * 2.0,
                          0.0, 1.0);
    // Sample the interior endpoints (1..256) while retaining the apron for
    // linear filtering near an edge.
    out.uv = (local + 1.0) / 258.0;
    return out;
}

fragment float4 dt_metal_tile_fragment(
    DTTileVertexOut in [[stage_in]],
    texture2d<float> tile [[texture(0)]],
    sampler tileSampler [[sampler(0)]],
    constant DTCompositeUniforms& uniforms [[buffer(0)]]) {
    const float4 color = tile.sample(tileSampler, in.uv);
    return color * saturate(uniforms.opacity);
}
