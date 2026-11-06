// Lava: glowing metaballs rising and merging, like a lava lamp.

fragment float4 lava(LDVertexOut in [[stage_in]],
                     constant LDUniforms& u [[buffer(0)]],
                     array<texture2d<float>, 8> passes [[texture(0)]],
                     sampler smp [[sampler(0)]]) {
    float aspect = u.resolution.x / u.resolution.y;
    float2 p = float2(in.uv.x * aspect, in.uv.y);
    float t = u.timeInfo.x * 0.18;

    float field = 0.0;
    for (int i = 0; i < 8; i++) {
        float fi = float(i);
        float speed = 0.35 + 0.12 * fract(fi * 0.618);
        float y = fract(t * speed * 0.35 + fi * 0.137) * 1.6 - 0.3;
        float x = aspect * (0.15 + 0.7 * fract(fi * 0.381)) + 0.12 * sin(t * (0.8 + fi * 0.2) + fi * 2.0);
        float r = 0.10 + 0.07 * fract(fi * 0.733);
        float2 d = p - float2(x, y);
        field += r * r / dot(d, d);
    }

    float3 bg = mix(float3(0.10, 0.02, 0.10), float3(0.25, 0.04, 0.18), in.uv.y);
    float body = smoothstep(0.9, 1.1, field);
    float rim = smoothstep(0.6, 1.0, field) - body;
    float3 lavaCol = mix(float3(1.0, 0.25, 0.05), float3(1.0, 0.75, 0.25), clamp((field - 1.0) * 0.25, 0.0, 1.0));
    float3 col = bg + float3(0.9, 0.2, 0.3) * clamp(field * 0.12, 0.0, 0.4);
    col = mix(col, lavaCol, body);
    col += float3(1.0, 0.45, 0.2) * rim * 0.6;
    return float4(col, 1.0);
}
