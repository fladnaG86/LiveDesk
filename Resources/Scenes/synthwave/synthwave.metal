// Synthwave: striped sun, mountain silhouettes and an endless neon grid rolling toward the viewer.

static float hash11(float p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}

static float noise1(float x) {
    float i = floor(x);
    float f = fract(x);
    return mix(hash11(i), hash11(i + 1.0), f * f * (3.0 - 2.0 * f));
}

static float ridge(float x) {
    return 0.55 * noise1(x * 3.0) + 0.3 * noise1(x * 7.0 + 4.0) + 0.15 * noise1(x * 17.0 + 9.0);
}

fragment float4 synthwave(LDVertexOut in [[stage_in]],
                          constant LDUniforms& u [[buffer(0)]],
                          array<texture2d<float>, 8> passes [[texture(0)]],
                          sampler smp [[sampler(0)]]) {
    float2 uv = in.uv;
    float aspect = u.resolution.x / u.resolution.y;
    float t = u.timeInfo.x;
    const float horizon = 0.38;
    float3 col;

    if (uv.y > horizon) {
        float h = (uv.y - horizon) / (1.0 - horizon);
        col = mix(float3(0.95, 0.35, 0.45), float3(0.10, 0.03, 0.22), pow(h, 0.7));

        float2 sp = float2((uv.x - 0.5) * aspect, uv.y - (horizon + 0.2));
        float r = length(sp);
        float sun = smoothstep(0.205, 0.2, r);
        float bands = step(0.0, sp.y) + step(0.35, fract((sp.y + 0.2) * 28.0 + t * 0.4));
        sun *= clamp(bands, 0.0, 1.0);
        float3 sunCol = mix(float3(1.0, 0.25, 0.55), float3(1.0, 0.85, 0.35), clamp(sp.y * 3.0 + 0.6, 0.0, 1.0));
        col = mix(col, sunCol, sun);
        col += float3(1.0, 0.4, 0.6) * exp(-r * 6.0) * 0.25;

        float m1 = horizon + 0.10 * ridge(uv.x * 1.3 + 2.0);
        float m2 = horizon + 0.05 * ridge(uv.x * 2.1 + 7.0);
        col = mix(col, float3(0.16, 0.04, 0.26), step(uv.y, m1));
        col = mix(col, float3(0.07, 0.02, 0.13), step(uv.y, m2));
    } else {
        float depth = horizon - uv.y;
        float z = 0.25 / (depth + 0.002);
        float x = (uv.x - 0.5) * aspect * z;
        float zz = z + t * 1.6;
        float2 g = abs(fract(float2(x, zz)) - 0.5);
        float2 fw = fwidth(float2(x, zz));
        float line = max(smoothstep(0.5 - fw.x * 1.5, 0.5, 0.5 - g.x), smoothstep(0.5 - fw.y * 1.5, 0.5, 0.5 - g.y));
        float fade = exp(-z * 0.08);
        col = mix(float3(0.04, 0.0, 0.09), float3(0.10, 0.0, 0.18), depth * 2.0);
        col += float3(1.0, 0.2, 0.85) * line * fade * 1.4;
        col += float3(0.9, 0.3, 0.6) * exp(-depth * 18.0) * 0.5;
    }
    return float4(col, 1.0);
}
