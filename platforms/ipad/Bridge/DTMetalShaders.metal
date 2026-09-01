#include <metal_stdlib>
using namespace metal;

struct DTMetalVertex {
    float2 position;
    float pressure;
    float predicted;
    float opacity;
    float eraser;
};

struct DTVertexOut {
    float4 position [[position]];
    float predicted;
    float opacity;
    float eraser;
};

vertex DTVertexOut dt_vertex(const device DTMetalVertex *vertices [[buffer(0)]],
                             constant float2 &viewport [[buffer(1)]],
                             uint vertexID [[vertex_id]]) {
    DTMetalVertex input = vertices[vertexID];
    float2 safeViewport = max(viewport, float2(1.0));
    float2 clip = float2((input.position.x / safeViewport.x) * 2.0 - 1.0,
                         1.0 - (input.position.y / safeViewport.y) * 2.0);
    return {float4(clip, 0.0, 1.0), input.predicted,
            saturate(input.opacity), input.eraser};
}

fragment float4 dt_fragment(DTVertexOut in [[stage_in]]) {
    // Real graphite is premultiplied and opaque at the configured brush
    // opacity. Predicted geometry fades to 30%; the same dark hue means a
    // prediction overlapping real ink never brightens it.
    const float prediction = mix(1.0, 0.30, saturate(in.predicted));
    float alpha = saturate(in.opacity) * prediction;
    const float3 graphite = float3(0.075, 0.080, 0.082);
    // The immediate eraser replays warm-paper color in retained stroke order.
    // Its alpha follows brush opacity, giving a soft eraser edge; a future
    // tile destination-out pass can replace this without changing geometry.
    const float3 paper = float3(0.965, 0.945, 0.900);
    const float3 color = mix(graphite, paper, step(0.5, in.eraser));
    return float4(color * alpha, alpha);
}
