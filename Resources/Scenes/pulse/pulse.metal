// Pulse: rings and petals driven by the Mac's audio (bass = rings, mid = petals, treble = sparkles).
// A slow idle motion keeps it alive in silence.

fragment float4 pulse(LDVertexOut in [[stage_in]],
                      constant LDUniforms& u [[buffer(0)]],
                      array<texture2d<float>, 8> passes [[texture(0)]],
                      sampler smp [[sampler(0)]]) {
    float2 res = u.resolution.xy;
    float2 p = (in.uv - 0.5) * float2(res.x / res.y, 1.0);
    float r = length(p);
    float a = atan2(p.y, p.x);
    float t = u.timeInfo.x;
    float bass = u.audio.x;
    float mid = u.audio.y;
    float treble = u.audio.z;

    float idle = 0.15 + 0.1 * sin(t * 0.8);
    float energy = max(bass, idle);

    float rings = sin(r * 40.0 - t * 3.0 - energy * 6.0) * 0.5 + 0.5;
    rings = pow(rings, 8.0) * exp(-r * (2.5 - energy));
    float petals = 0.5 + 0.5 * sin(a * 6.0 + t * 0.7 + mid * 4.0);
    float core = exp(-r * (9.0 - energy * 5.0));

    float3 base = 0.5 + 0.5 * cos(float3(0.0, 2.1, 4.2) + t * 0.2 + r * 3.0);
    float3 col = base * (rings * (0.6 + petals * 0.8) + core * (0.6 + bass));

    float2 cell = floor(in.uv * res / 3.0);
    float sparkle = step(0.995, fract(sin(dot(cell + floor(t * 8.0), float2(12.9898, 78.233))) * 43758.5453));
    col += float3(0.8, 0.9, 1.0) * treble * 0.25 * sparkle;
    col *= smoothstep(1.2, 0.2, r);
    return float4(col, 1.0);
}
