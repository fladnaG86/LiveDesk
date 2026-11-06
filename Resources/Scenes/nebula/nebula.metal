// Nebula: domain-warped fractal noise in violet, blue and amber, with a faint starfield.

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 w = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + float2(1, 0)), w.x),
               mix(hash21(i + float2(0, 1)), hash21(i + float2(1, 1)), w.x), w.y);
}

static float fbm(float2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 6; i++) {
        v += a * vnoise(p);
        p = p * 2.02 + 11.7;
        a *= 0.5;
    }
    return v;
}

fragment float4 nebula(LDVertexOut in [[stage_in]],
                       constant LDUniforms& u [[buffer(0)]],
                       array<texture2d<float>, 8> passes [[texture(0)]],
                       sampler smp [[sampler(0)]]) {
    float aspect = u.resolution.x / u.resolution.y;
    float2 p = float2(in.uv.x * aspect, in.uv.y) * 2.2;
    float t = u.timeInfo.x * 0.025;

    float2 q = float2(fbm(p + float2(0.0, t)), fbm(p + float2(5.2, 1.3) - t));
    float2 r = float2(fbm(p + 4.0 * q + float2(1.7, 9.2) + t * 0.6),
                      fbm(p + 4.0 * q + float2(8.3, 2.8) - t * 0.5));
    float f = fbm(p + 4.0 * r);

    float3 col = mix(float3(0.03, 0.01, 0.08), float3(0.50, 0.12, 0.58), clamp(f * f * 2.2, 0.0, 1.0));
    col = mix(col, float3(0.08, 0.32, 0.78), clamp(length(q) * 0.9, 0.0, 1.0) * 0.55);
    col = mix(col, float3(1.0, 0.72, 0.45), clamp(r.x * r.x * 1.2, 0.0, 1.0) * 0.45);
    col *= 0.55 + 0.9 * f;

    float2 cell = floor(in.uv * u.resolution.xy / 3.0);
    float s = hash21(cell);
    col += step(0.9985, s) * (0.6 + 0.4 * sin(u.timeInfo.x * 1.5 + s * 80.0));
    return float4(col, 1.0);
}
