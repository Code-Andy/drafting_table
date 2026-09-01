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
    // Real graphite is intentionally opaque.  Segment quads and the round
    // join dabs overlap by design; alpha below one would accumulate and make
    // curved lines visibly darker than straight ones.  Predicted samples are
    // still rendered as a lighter tail until UIKit replaces them with real
    // samples.
    float alpha = in.predicted > 0.5 ? 0.30 : 1.0;
    // Graphite ink over warm paper. The pipeline uses source-alpha-one, so
    // return premultiplied RGB to avoid dark fringes at segment boundaries.
    // Use the same graphite hue for prediction. Lower alpha makes it lighter
    // on paper without brightening an already-rendered real segment where the
    // prediction tail overlaps the last real sample.
    const float3 color = float3(0.075, 0.080, 0.082);
    return float4(color * alpha, alpha);
}
