#include <metal_stdlib>
using namespace metal;

struct WarpSize { uint outputWidth; uint outputHeight; uint proxyWidth; uint proxyHeight; };
// Separate buffer preserves WarpSize ABI. Swift supplies six Float and two UInt32 (32 bytes).
struct WarpProtection { float top; float bottom; float yFromX; float yFromY; float yOffset; float feather; uint staticDetails; uint reserved; };

float planeSample(device const float *data, uint channel, float2 point, uint2 contentSize) {
    constexpr uint width = 256, height = 192;
    float2 p = clamp(point, float2(0), float2(contentSize - 1));
    uint2 a = uint2(floor(p));
    uint2 b = min(a + 1, contentSize - 1);
    float2 f = fract(p);
    uint base = channel * width * height;
    float top = mix(data[base + a.y * width + a.x], data[base + a.y * width + b.x], f.x);
    float bottom = mix(data[base + b.y * width + a.x], data[base + b.y * width + b.x], f.x);
    return mix(top, bottom, f.y);
}

float detailDistance(float3 a, float3 b) { return max(max(abs(a.r - b.r), abs(a.g - b.g)), abs(a.b - b.b)); }

float stationaryDetail(texture2d<float, access::sample> first, texture2d<float, access::sample> second,
                       uint2 gid, uint2 size, float3 a, float3 b, float refinement) {
    float error = detailDistance(a, b);
    float tolerance = mix(0.035f, 0.065f, refinement);
    if (error >= tolerance) return 0.0f;
    float matches = 0.0f, contrast = 0.0f;
    float patchError = error;
    const int2 offsets[8] = { int2(-2, 0), int2(2, 0), int2(0, -2), int2(0, 2),
                              int2(-4, 0), int2(4, 0), int2(0, -4), int2(0, 4) };
    for (uint i = 0; i < 8; ++i) {
        if (i == 4 && refinement == 0.0f) break;
        uint2 p = uint2(clamp(int2(gid) + offsets[i], int2(0), int2(size) - 1));
        float3 na = first.read(p).rgb, nb = second.read(p).rgb;
        patchError = max(patchError, detailDistance(na, nb));
        float match = 1.0f - smoothstep(mix(0.012f, 0.030f, refinement), tolerance, detailDistance(na, nb));
        if (i < 4) matches += match;
        float persistent = mix(detailDistance(a, na), min(detailDistance(a, na), detailDistance(b, nb)), refinement);
        contrast = max(contrast, persistent * match * (i < 4 ? 1.0f : refinement));
    }
    // Tolerate bounded encoding noise, require a persistent edge in both frames,
    // and extend support across thick strokes without accepting moving contours.
    float existing = (1.0f - smoothstep(mix(0.012f, 0.025f, refinement), tolerance, error)) * smoothstep(1.5f, 2.5f, matches) *
           smoothstep(mix(0.10f, 0.12f, refinement), mix(0.22f, 0.24f, refinement), contrast);
    // Dim stationary reflections need a lower contrast threshold, but NOT the
    // text guard's compression tolerance: every sampled neighbour must agree
    // to less than one 8-bit code value. Moving/fading reflections keep flow.
    // Reuse the existing stencil; no extra texture reads or temporal state.
    float exactPatch = 1.0f - smoothstep(0.001f, 0.003f, patchError);
    return max(existing, exactPatch * smoothstep(0.015f, 0.045f, contrast) * refinement);
}

kernel void flowWarpBlend(texture2d<float, access::sample> first [[texture(0)]],
                          texture2d<float, access::sample> second [[texture(1)]],
                          texture2d<float, access::write> output [[texture(2)]],
                          device const float *flow [[buffer(0)]],
                          device const float *mask [[buffer(1)]],
                          constant WarpSize &size [[buffer(2)]],
                          constant WarpProtection &protection [[buffer(3)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= size.outputWidth || gid.y >= size.outputHeight) return;
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 imageSize = float2(size.outputWidth, size.outputHeight);
    float2 proxySize = float2(size.proxyWidth, size.proxyHeight);
    float2 uv = (float2(gid) + 0.5f) / imageSize;
    float3 originalA = first.read(gid).rgb;
    float displayY = protection.yFromX * uv.x + protection.yFromY * uv.y + protection.yOffset;
    bool band = protection.top >= 0.0f && protection.bottom > protection.top;
    if (band && displayY >= protection.top && displayY <= protection.bottom) {
        output.write(float4(originalA, 1.0f), gid);
        return;
    }
    float2 proxyPoint = uv * proxySize - 0.5f;
    uint2 contentSize = uint2(size.proxyWidth, size.proxyHeight);
    float2 flowA = float2(planeSample(flow, 0, proxyPoint, contentSize), planeSample(flow, 1, proxyPoint, contentSize));
    float2 flowB = float2(planeSample(flow, 2, proxyPoint, contentSize), planeSample(flow, 3, proxyPoint, contentSize));
    float blend = clamp(planeSample(mask, 0, proxyPoint, contentSize), 0.0f, 1.0f);
    float4 a = first.sample(linearSampler, uv + flowA / proxySize);
    float4 b = second.sample(linearSampler, uv + flowB / proxySize);
    float3 result = mix(b.rgb, a.rgb, blend);
    if (protection.staticDetails) {
        float3 originalB = second.read(gid).rgb;
        // Wider support is unreliable for fast moving contours; retain the strict guard.
        float motion = max(length(flowA * imageSize / proxySize), length(flowB * imageSize / proxySize));
        float refinement = 1.0f - smoothstep(6.0f, 10.0f, motion);
        // Mask is an occlusion weight, not subtitle time. Avoid mask-driven noise.
        float3 unwarped = mix(mix(originalB, originalA, blend), originalA, refinement);
        if (detailDistance(result, unwarped) > 0.004f) {
            result = mix(result, unwarped, stationaryDetail(first, second, gid, uint2(size.outputWidth, size.outputHeight), originalA, originalB, refinement));
        }
    }
    if (band && protection.feather > 0.0f) {
        float distance = max(protection.top - displayY, displayY - protection.bottom);
        result = mix(result, originalA, 1.0f - smoothstep(0.0f, protection.feather, distance));
    }
    output.write(float4(result, 1.0f), gid);
}
