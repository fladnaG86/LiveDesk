// Bokeh: out-of-focus city lights drifting slowly upward over a warm dusk gradient.

static float hash11(float p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}

fragment float4 bokeh(LDVertexOut in [[stage_in]],
                      constant LDUniforms& u [[buffer(0)]],
                      array<texture2d<float>, 8> passes [[texture(0)]],
                      sampler smp [[sampler(0)]]) {
    float aspect = u.resolution.x / u.resolution.y;
    float2 p = float2(in.uv.x * aspect, in.uv.y);
    float t = u.timeInfo.x * 0.02;

    float3 col = mix(float3(0.10, 0.04, 0.10), float3(0.02, 0.03, 0.10), in.uv.y);
    for (int i = 0; i < 48; i++) {
        float fi = float(i);
        float size = mix(0.03, 0.14, hash11(fi * 3.7));
        float speed = mix(0.4, 1.2, hash11(fi * 9.1));
        float2 c = float2(hash11(fi * 1.3) * (aspect + 0.4) - 0.2,
                          fract(hash11(fi * 5.9) + t * speed) * 1.4 - 0.2);
        c.x += 0.03 * sin(u.timeInfo.x * 0.3 + fi);
        float d = length(p - c);
        float disc = smoothstep(size, size * 0.85, d);
        float ring = smoothstep(size * 0.8, size, d) * disc;
        float3 tint = mix(float3(1.0, 0.65, 0.30), float3(1.0, 0.35, 0.45), hash11(fi * 7.3));
        tint = mix(tint, float3(0.45, 0.65, 1.0), step(0.75, hash11(fi * 2.1)));
        float a = mix(0.10, 0.28, hash11(fi * 4.4));
        col += tint * (disc * a + ring * a * 0.8);
    }
    return float4(col, 1.0);
}
