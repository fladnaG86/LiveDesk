// Silk: dozens of fine luminous threads flowing like fabric in a breeze.

fragment float4 silk(LDVertexOut in [[stage_in]],
                     constant LDUniforms& u [[buffer(0)]],
                     array<texture2d<float>, 8> passes [[texture(0)]],
                     sampler smp [[sampler(0)]]) {
    float2 uv = in.uv;
    float aspect = u.resolution.x / u.resolution.y;
    float t = u.timeInfo.x * 0.25;
    float px = u.resolution.w;

    float3 col = mix(float3(0.01, 0.02, 0.05), float3(0.03, 0.02, 0.08), uv.y);
    for (int i = 0; i < 28; i++) {
        float fi = float(i) / 28.0;
        float x = uv.x * aspect;
        float y = 0.5
            + 0.22 * sin(x * 1.3 + t + fi * 2.4)
            + 0.08 * sin(x * 3.1 - t * 1.4 + fi * 6.0)
            + (fi - 0.5) * 0.35 * (0.6 + 0.4 * sin(t * 0.7 + x));
        float d = abs(uv.y - y);
        float width = px * (1.2 + 2.5 * fi);
        float glow = exp(-d / (width * 6.0)) * 0.12 + smoothstep(width, 0.0, d) * 0.5;
        float3 tint = mix(float3(0.25, 0.55, 1.0), float3(0.95, 0.40, 0.85), fi);
        col += tint * glow;
    }
    return float4(1.0 - exp(-col * 1.4), 1.0);
}
