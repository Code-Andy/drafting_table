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

// Must remain layout-compatible with DTMetalUniforms in DTMetalRenderer.mm:
// two tightly packed float4 values (32 bytes total).
struct DTMetalUniforms {
    float4 viewportScaleRotation;
    float4 translation;
};

struct DTMetalFragmentUniforms {
    float4 color;
    float4 style;
};

vertex DTVertexOut dt_vertex(const device DTMetalVertex *vertices [[buffer(0)]],
                             constant DTMetalUniforms &uniforms [[buffer(1)]],
                             uint vertexID [[vertex_id]]) {
    DTMetalVertex input = vertices[vertexID];
    float2 safeViewport = max(uniforms.viewportScaleRotation.xy, float2(1.0));
    float scale = max(uniforms.viewportScaleRotation.z, 0.01);
    float rotation = uniforms.viewportScaleRotation.w;
    float2 translation = uniforms.translation.xy;
    float sine = sin(rotation);
    float cosine = cos(rotation);
    float2 transformed = float2(
        scale * (cosine * input.position.x - sine * input.position.y),
        scale * (sine * input.position.x + cosine * input.position.y)
    ) + translation;
    float2 clip = float2((transformed.x / safeViewport.x) * 2.0 - 1.0,
                         1.0 - (transformed.y / safeViewport.y) * 2.0);
    return {float4(clip, 0.0, 1.0), input.predicted,
            saturate(input.opacity), input.eraser};
}

fragment float4 dt_fragment(DTVertexOut in [[stage_in]],
                            constant DTMetalFragmentUniforms &uniforms [[buffer(0)]]) {
    // Real graphite is premultiplied and opaque at the configured brush
    // opacity. Predicted geometry fades to 30%; the same dark hue means a
    // prediction overlapping real ink never brightens it.
    const float prediction = mix(1.0, 0.30, saturate(in.predicted));
    float alpha = saturate(in.opacity) * prediction;
    // The immediate eraser replays warm-paper color in retained stroke order.
    // Brush color is supplied as straight RGBA and is premultiplied here.
    // Hardness controls the edge contribution of the fringe pass; the core
    // remains opaque while a softer brush retains a visible feather.
    float edge = mix(0.72, 1.0, saturate(uniforms.style.x));
    alpha *= edge;
    float4 color = uniforms.color;
    color.a *= alpha;
    return float4(color.rgb * color.a, color.a);
}

// Lightweight paper/grid pass used by the tile renderer. Artwork itself is
// composited by renderer/metal/DTMetalShaders.metal.
struct DTOverlayVertex {
    float2 documentPosition;
    float4 premultipliedColor;
};

struct DTOverlayUniforms {
    float2 viewportSize;
    float scale;
    float rotation;
    float2 translation;
    float2 reserved;
};

struct DTOverlayVertexOut {
    float4 position [[position]];
    float4 color;
};

vertex DTOverlayVertexOut dt_overlay_vertex(
    const device DTOverlayVertex* vertices [[buffer(0)]],
    constant DTOverlayUniforms& uniforms [[buffer(1)]],
    uint vertexID [[vertex_id]]) {
    const DTOverlayVertex input = vertices[vertexID];
    const float c = cos(uniforms.rotation);
    const float s = sin(uniforms.rotation);
    const float2 rotated = float2(
        c * input.documentPosition.x - s * input.documentPosition.y,
        s * input.documentPosition.x + c * input.documentPosition.y);
    const float2 view = rotated * uniforms.scale + uniforms.translation;
    const float2 viewport = max(uniforms.viewportSize, float2(1.0));
    DTOverlayVertexOut out;
    out.position = float4(view.x / viewport.x * 2.0 - 1.0,
                          1.0 - view.y / viewport.y * 2.0,
                          0.0, 1.0);
    out.color = input.premultipliedColor;
    return out;
}

fragment float4 dt_overlay_fragment(DTOverlayVertexOut in [[stage_in]]) {
    return in.color;
}
