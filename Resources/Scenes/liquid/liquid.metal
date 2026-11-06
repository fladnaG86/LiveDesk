// Liquid: a soft mesh gradient. Five colour points drift on slow Lissajous paths; light film grain.

static float hash21(float2 p) {
    p = fract(p * float2(233.34, 851.73));
    p += dot(p, p + 23.45);
    return fract(p.x * p.y);
}

fragment float4 liquid(LDVertexOut in [[stage_in]],
                       constant LDUniforms& u [[buffer(0)]],
                       array<texture2d<float>, 8> passes [[texture(0)]],
                       sampler smp [[sampler(0)]]) {
    float aspect = u.resolution.x / u.resolution.y;
    float2 p = float2(in.uv.x * aspect, in.uv.y);
    float t = u.timeInfo.x * 0.12;

    float3 colors[5] = {
        float3(0.98, 0.42, 0.45),
        float3(0.99, 0.75, 0.38),
        float3(0.36, 0.48, 0.98),
        float3(0.62, 0.32, 0.92),
        float3(0.20, 0.80, 0.78)
    };

    float3 acc = float3(0.0);
    float wsum = 0.0;
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        float2 c = float2(0.5 * aspect + 0.42 * aspect * sin(t * (0.7 + fi * 0.13) + fi * 1.9),
                          0.5 + 0.40 * cos(t * (0.9 + fi * 0.11) + fi * 2.7));
        float d = length(p - c);
        float w = 1.0 / pow(d * d + 0.02, 1.6);
        acc += colors[i] * w;
        wsum += w;
    }
    float3 col = acc / wsum;

    // gentle swirl of brightness
    col *= 0.92 + 0.08 * sin(p.x * 3.0 + p.y * 2.0 + t * 2.0);
    col += (hash21(in.uv * u.resolution.xy + floor(u.timeInfo.x * 24.0)) - 0.5) * 0.025;
    return float4(col, 1.0);
}
