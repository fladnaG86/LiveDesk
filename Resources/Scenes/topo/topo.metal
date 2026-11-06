// Topo: slowly morphing topographic contour lines on a deep teal background.

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
    for (int i = 0; i < 5; i++) {
        v += a * vnoise(p);
        p = p * 2.0 + 5.3;
        a *= 0.5;
    }
    return v;
}

fragment float4 topo(LDVertexOut in [[stage_in]],
                     constant LDUniforms& u [[buffer(0)]],
                     array<texture2d<float>, 8> passes [[texture(0)]],
                     sampler smp [[sampler(0)]]) {
    float aspect = u.resolution.x / u.resolution.y;
    float2 p = float2(in.uv.x * aspect, in.uv.y) * 1.6;
    float t = u.timeInfo.x * 0.03;

    float h = fbm(p + float2(t, -t * 0.7)) + 0.35 * fbm(p * 2.3 - float2(t * 0.5, t));
    float levels = h * 18.0;
    float d = abs(fract(levels) - 0.5);
    float fw = fwidth(levels);
    float line = smoothstep(fw * 1.2, 0.0, 0.5 - d);
    float d5 = abs(fract(levels / 5.0) - 0.5);
    float major = smoothstep(fw * 0.2 * 1.8, 0.0, 0.5 - d5);

    float3 bg = mix(float3(0.02, 0.07, 0.09), float3(0.03, 0.12, 0.14), h);
    float3 col = bg + float3(0.25, 0.85, 0.80) * line * 0.45 + float3(0.5, 1.0, 0.95) * major * 0.35;
    return float4(col, 1.0);
}
