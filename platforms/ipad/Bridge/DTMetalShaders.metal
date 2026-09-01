#include <metal_stdlib>
using namespace metal;

struct DTMetalVertex {
    float2 position;
    float pressure;
    float predicted;
};

struct DTVertexOut {
    float4 position [[position]];
    float pressure;
    float predicted;
};

vertex DTVertexOut dt_vertex(const device DTMetalVertex *vertices [[buffer(0)]],
                             constant float2 &viewport [[buffer(1)]],
                             uint vertexID [[vertex_id]]) {
    DTMetalVertex input = vertices[vertexID];
    float2 safeViewport = max(viewport, float2(1.0));
    float2 clip = float2((input.position.x / safeViewport.x) * 2.0 - 1.0,
                         1.0 - (input.position.y / safeViewport.y) * 2.0);
    return {float4(clip, 0.0, 1.0), input.pressure, input.predicted};
}

fragment float4 dt_fragment(DTVertexOut in [[stage_in]]) {
    float alpha = (0.76 + 0.24 * saturate(in.pressure)) *
                  (in.predicted > 0.5 ? 0.30 : 1.0);
    // Graphite ink over warm paper. The pipeline uses source-alpha-one, so
    // return premultiplied RGB to avoid dark fringes at segment boundaries.
    const float3 color = in.predicted > 0.5
        ? float3(0.28, 0.30, 0.31)
        : float3(0.075, 0.080, 0.082);
    return float4(color * alpha, alpha);
}
