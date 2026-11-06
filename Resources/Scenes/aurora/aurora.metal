// Aurora: layered noise ribbons over a starfield. The cursor gently bends the ribbons.

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 w = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1));
    float d = hash21(i + float2(1, 1));
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

static float fbm(float2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 5; i++) {
        v += a * vnoise(p);
        p = p * 2.03 + 17.1;
        a *= 0.5;
    }
    return v;
}

fragment float4 aurora(LDVertexOut in [[stage_in]],
                       constant LDUniforms& u [[buffer(0)]],
                       array<texture2d<float>, 8> passes [[texture(0)]],
                       sampler smp [[sampler(0)]]) {
    float2 uv = in.uv;
    float aspect = u.resolution.x / u.resolution.y;
    float2 p = float2(uv.x * aspect, uv.y);
    float t = u.timeInfo.x * 0.05;
    float2 m = u.mouse.z > 0.5 ? (u.mouse.xy - 0.5) * 0.25 : float2(0.0);

    float3 col = mix(float3(0.01, 0.02, 0.06), float3(0.03, 0.0, 0.09), uv.y);
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float n = fbm(float2(p.x * 1.2 + t * (1.0 + fi * 0.3) + m.x, fi * 3.7 + t));
        float band = uv.y - (0.45 + fi * 0.09 + (n - 0.5) * 0.5 + m.y);
        float glow = exp(-abs(band) * (14.0 - fi * 3.0));
        float3 tint = mix(float3(0.1, 0.9, 0.6), float3(0.55, 0.2, 0.95), fi / 2.0);
        col += tint * glow * (0.55 + 0.45 * fbm(p * 3.0 + t * 4.0));
    }

    float2 cell = floor(p * 220.0);
    float s = hash21(cell);
    float twinkle = 0.5 + 0.5 * sin(u.timeInfo.x * 2.0 + s * 50.0);
    col += step(0.997, s) * twinkle * (1.0 - uv.y * 0.3) * 0.6;
    return float4(col, 1.0);
}
