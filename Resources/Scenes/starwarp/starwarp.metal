// Star Warp: layers of stars streaming toward the viewer through a faint blue haze.

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float starLayer(float2 p, float scale, float seed) {
    float2 q = p * scale;
    float2 id = floor(q);
    float2 f = fract(q) - 0.5;
    float h = hash21(id + seed);
    float2 offset = (float2(hash21(id + seed + 3.1), hash21(id + seed + 7.7)) - 0.5) * 0.8;
    float d = length(f - offset);
    float size = mix(0.015, 0.06, h * h);
    return smoothstep(size, 0.0, d) * step(0.75, h) * (0.5 + h);
}

fragment float4 starwarp(LDVertexOut in [[stage_in]],
                         constant LDUniforms& u [[buffer(0)]],
                         array<texture2d<float>, 8> passes [[texture(0)]],
                         sampler smp [[sampler(0)]]) {
    float aspect = u.resolution.x / u.resolution.y;
    float2 p = (in.uv - 0.5) * float2(aspect, 1.0);
    float t = u.timeInfo.x * 0.08;

    float3 col = float3(0.01, 0.015, 0.04) + float3(0.05, 0.08, 0.18) * exp(-length(p) * 2.2);
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float depth = fract(t + fi / 6.0);
        float scale = mix(24.0, 0.8, depth);
        float fade = smoothstep(0.0, 0.25, depth) * smoothstep(1.0, 0.85, depth);
        float s = starLayer(p, scale, fi * 17.0);
        float3 tint = mix(float3(0.7, 0.8, 1.0), float3(1.0, 0.85, 0.7), hash21(float2(fi, 1.0)));
        col += tint * s * fade * 1.6;
    }
    return float4(col, 1.0);
}
