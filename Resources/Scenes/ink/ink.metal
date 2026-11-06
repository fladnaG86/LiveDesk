// Ink: two passes. ink_sim advects its own previous frame through a swirling flow field and
// injects colour from drifting emitters and the cursor; ink_color tone-maps the result.

static float2 swirl(float2 uv, float t) {
    float2 q = uv * 3.0;
    return float2(sin(q.y * 1.7 + t * 0.6) + 0.5 * sin(q.y * 3.1 - t * 0.4),
                  cos(q.x * 1.9 - t * 0.5) + 0.5 * cos(q.x * 2.7 + t * 0.3));
}

fragment float4 ink_sim(LDVertexOut in [[stage_in]],
                        constant LDUniforms& u [[buffer(0)]],
                        array<texture2d<float>, 8> passes [[texture(0)]],
                        sampler smp [[sampler(0)]]) {
    float2 uv = in.uv;
    float t = u.timeInfo.x;
    float aspect = u.resolution.x / u.resolution.y;

    float2 vel = swirl(uv, t) * 0.0009;
    float4 c = passes[0].sample(smp, ld_tc(uv - vel)) * 0.992;

    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float2 e = 0.5 + 0.32 * float2(cos(t * 0.21 * (fi + 1.0) + fi * 2.0), sin(t * 0.17 * (fi + 1.0) + fi));
        float d = length((uv - e) * float2(aspect, 1.0));
        float3 tint = 0.5 + 0.5 * cos(float3(0.0, 2.0, 4.0) + fi * 2.0 + t * 0.1);
        c.rgb += tint * exp(-d * d * 900.0) * 0.08;
    }
    if (u.mouse.z > 0.5) {
        float d = length((uv - u.mouse.xy) * float2(aspect, 1.0));
        c.rgb += float3(0.9, 0.6, 1.0) * exp(-d * d * 1500.0) * 0.12;
    }
    return clamp(c, 0.0, 4.0);
}

fragment float4 ink_color(LDVertexOut in [[stage_in]],
                          constant LDUniforms& u [[buffer(0)]],
                          array<texture2d<float>, 8> passes [[texture(0)]],
                          sampler smp [[sampler(0)]]) {
    float3 v = passes[0].sample(smp, ld_tc(in.uv)).rgb;
    float3 col = 1.0 - exp(-v * 1.6);
    return float4(col + float3(0.015, 0.015, 0.03), 1.0);
}
