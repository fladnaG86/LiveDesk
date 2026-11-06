// Ocean: a calm sea at sunset with rolling swell and a shimmering reflection of the sun.

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

fragment float4 ocean(LDVertexOut in [[stage_in]],
                      constant LDUniforms& u [[buffer(0)]],
                      array<texture2d<float>, 8> passes [[texture(0)]],
                      sampler smp [[sampler(0)]]) {
    float2 uv = in.uv;
    float aspect = u.resolution.x / u.resolution.y;
    float t = u.timeInfo.x;
    const float horizon = 0.42;
    float sunX = 0.5;
    float sunY = horizon + 0.07;
    float3 col;

    if (uv.y > horizon) {
        float h = (uv.y - horizon) / (1.0 - horizon);
        col = mix(float3(1.0, 0.55, 0.30), float3(0.20, 0.25, 0.55), pow(h, 0.55));
        float2 sp = float2((uv.x - sunX) * aspect, uv.y - sunY);
        float r = length(sp);
        col = mix(col, float3(1.0, 0.92, 0.70), smoothstep(0.055, 0.05, r));
        col += float3(1.0, 0.6, 0.3) * exp(-r * 5.0) * 0.45;
        float clouds = vnoise(float2(uv.x * aspect * 3.0 + t * 0.01, uv.y * 12.0));
        col = mix(col, col * float3(0.85, 0.7, 0.75), smoothstep(0.55, 0.8, clouds) * h * 0.6);
    } else {
        float depth = horizon - uv.y;
        float z = 0.1 / (depth + 0.01);
        float2 wp = float2((uv.x - 0.5) * aspect * z, z);
        float waves = vnoise(wp * float2(3.0, 6.0) + float2(t * 0.15, t * 0.4))
                    + 0.5 * vnoise(wp * float2(7.0, 14.0) - float2(t * 0.2, t * 0.6));
        col = mix(float3(0.55, 0.30, 0.30), float3(0.06, 0.08, 0.20), clamp(depth * 3.0, 0.0, 1.0));
        float column = exp(-abs((uv.x - sunX) * aspect) * mix(30.0, 6.0, clamp(depth * 2.5, 0.0, 1.0)));
        float glint = smoothstep(0.85, 1.25, waves);
        col += float3(1.0, 0.75, 0.45) * column * (0.25 + glint * 1.2);
        col += float3(0.9, 0.5, 0.4) * smoothstep(1.1, 1.4, waves) * 0.12 * (1.0 - depth * 2.0);
        col *= 0.85 + 0.15 * waves;
    }
    return float4(col, 1.0);
}
