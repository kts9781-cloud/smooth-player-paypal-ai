#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

float4 enhancementWeights(float t) {
    float t2 = t * t, t3 = t2 * t;
    return float4(-0.5f*t+t2-0.5f*t3, 1.0f-2.5f*t2+1.5f*t3,
                  0.5f*t+2.0f*t2-1.5f*t3, -0.5f*t2+0.5f*t3);
}

// EASU direction/tap equations adapted from AMD FidelityFX FSR 1, commit
// a21ffb8f6c13233ba336352bdff293894c706575, Copyright (c) 2021 Advanced Micro
// Devices, Inc. MIT license: third_party/fidelityfx-fsr/LICENSE, bundled notices.
// This float port uses exact division/rsqrt, bounded individual samples rather
// than texture gathers, and conservative contour selection. No RCAS pass.
void enhancementEdgeSet(thread float2 &direction, thread float &length, float weight,
                        float a, float b, float c, float d, float e) {
    float2 gradient = float2(d-b, e-a);
    float2 maximum = max(abs(float2(d-c, e-c)), abs(float2(c-b, c-a)));
    float2 agreement = clamp(abs(gradient) / max(maximum, float2(1e-6f)), 0.0f, 1.0f);
    direction += gradient * weight;
    length += dot(agreement, agreement) * weight;
}

void enhancementEdgeTap(thread float3 &color, thread float &weight,
                        float2 offset, float2 direction, float2 stretch,
                        float lobe, float clip, float3 sample) {
    float2 v = float2(dot(offset, direction), dot(offset, float2(-direction.y, direction.x))) * stretch;
    float distance = min(dot(v,v), clip);
    float base = 0.4f * distance - 1.0f;
    float window = lobe * distance - 1.0f;
    float tap = (1.5625f * base * base - 0.5625f) * window * window;
    color += sample * tap;
    weight += tap;
}

float3 enhancementEdgeReconstruct(thread const float3 *samples, float2 f,
                                  float3 catmull, float3 lo, float3 hi) {
    float contrast = dot(hi-lo, float3(0.2126f,0.7152f,0.0722f));
    if (contrast <= 0.08f) return catmull;
    float luma[16];
    for (int i=0; i<16; ++i) luma[i] = dot(samples[i], float3(0.5f,1.0f,0.5f));
    float2 direction = 0.0f;
    float length = 0.0f;
    enhancementEdgeSet(direction,length,(1-f.x)*(1-f.y),luma[1],luma[4],luma[5],luma[6],luma[9]);
    enhancementEdgeSet(direction,length,f.x*(1-f.y),luma[2],luma[5],luma[6],luma[7],luma[10]);
    enhancementEdgeSet(direction,length,(1-f.x)*f.y,luma[5],luma[8],luma[9],luma[10],luma[13]);
    enhancementEdgeSet(direction,length,f.x*f.y,luma[6],luma[9],luma[10],luma[11],luma[14]);
    length = 0.25f * length * length;
    // Weak blocks, flat fields and incoherent texture retain the old reconstruction.
    float selection = smoothstep(0.08f,0.18f,contrast) * smoothstep(0.25f,0.65f,length);
    if (selection <= 0.0f) return catmull;
    float norm = dot(direction,direction);
    direction = norm < (1.0f/32768.0f) ? float2(1.0f,0.0f) : direction * rsqrt(norm);
    float stretch = dot(direction,direction) / max(abs(direction.x),abs(direction.y));
    float2 axes = float2(1.0f+(stretch-1.0f)*length,1.0f-0.5f*length);
    float lobe = 0.5f-0.29f*length;
    float clip = 1.0f/lobe;
    float3 color = 0.0f;
    float weight = 0.0f;
    for (int y=0; y<4; ++y) {
        for (int x=0; x<4; ++x) {
            if ((x==0 || x==3) && (y==0 || y==3)) continue;
            enhancementEdgeTap(color,weight,float2(x-1,y-1)-f,direction,axes,lobe,clip,samples[y*4+x]);
        }
    }
    if (weight <= 1e-6f) return catmull;
    return clamp(mix(catmull,clamp(color/weight,lo,hi),selection),lo,hi);
}

// Core Image's default linear-sRGB working space is converted to display RGB for
// the same contrast gate and luma thresholds as Android's SDR video shader.
template <bool encodedSRGB>
float3 enhancementSample(coreimage::sampler image, float2 point, float2 sourceSize) {
    point = clamp(point, float2(0.5f), sourceSize - 0.5f);
    float4 sample = image.sample(image.transform(point));
    if (encodedSRGB) return sample.rgb;
    return coreimage::linear_to_srgb(sample).rgb;
}

template <bool encodedSRGB, bool edgeAdaptive>
float4 enhancementFromSamples(thread const float3 *samples, float2 position, float detail, float cleanup) {
    float4 wx = enhancementWeights(fract(position.x)), wy = enhancementWeights(fract(position.y));
    float3 value = 0.0f, lo = 1.0f, hi = 0.0f;
    for (int y = 0; y < 4; ++y) {
        for (int x = 0; x < 4; ++x) {
            float3 sample = samples[y * 4 + x];
            value += sample * wx[x] * wy[y];
            if (x >= 1 && x <= 2 && y >= 1 && y <= 2) { lo = min(lo, sample); hi = max(hi, sample); }
        }
    }
    value = clamp(value, lo, hi);
    if (edgeAdaptive) value = enhancementEdgeReconstruct(samples,fract(position),value,lo,hi);
    if (detail > 0.0f || cleanup > 0.0f) {
        // Reuse the 16 samples for gamma-domain bilinear detail (no further texture reads).
        float2 f = fract(position);
        float3 center = mix(mix(samples[5], samples[6], f.x), mix(samples[9], samples[10], f.x), f.y);
        float3 left = mix(mix(samples[4], samples[5], f.x), mix(samples[8], samples[9], f.x), f.y);
        float3 right = mix(mix(samples[6], samples[7], f.x), mix(samples[10], samples[11], f.x), f.y);
        float3 down = mix(mix(samples[1], samples[2], f.x), mix(samples[5], samples[6], f.x), f.y);
        float3 up = mix(mix(samples[9], samples[10], f.x), mix(samples[13], samples[14], f.x), f.y);
        float3 blur = (left + right + down + up) * 0.25f;
        const float3 luma = float3(0.2126f, 0.7152f, 0.0722f);
        float amount = dot(center - blur, luma) * detail * 0.65f * smoothstep(0.015f, 0.08f, dot(hi - lo, luma));
        if (cleanup > 0.0f) {
            // Edge-aware spatial cleanup: average only similar neighbours. Real
            // high-contrast contours remain intact; weak block boundaries soften.
            float3 neighbours[4] = { left, right, down, up };
            float centerWeight = 2.0f;
            float3 total = center * centerWeight;
            float weight = centerWeight;
            for (int i = 0; i < 4; ++i) {
                float3 delta = abs(neighbours[i] - center);
                float difference = max(delta.r, max(delta.g, delta.b));
                float w = 1.0f - smoothstep(0.025f, 0.12f, difference);
                total += neighbours[i] * w; weight += w;
            }
            float contrast = dot(hi - lo, luma);
            value = mix(value, total / weight, 0.85f * (1.0f - smoothstep(0.06f, 0.18f, contrast)));
            amount *= smoothstep(0.06f, 0.14f, contrast);
        }
        float limit = 0.045f;
        value = clamp(value + clamp(amount, -limit, limit), lo, hi);
    }
    float4 result = float4(clamp(value, 0.0f, 1.0f), 1.0f);
    if (encodedSRGB) return result;
    return coreimage::srgb_to_linear(result);
}

template <bool encodedSRGB, bool edgeAdaptive>
float4 enhancementReconstruct(coreimage::sampler image, float2 sourceSize,
                                       float2 outputSize, float detail, float cleanup,
                                       coreimage::destination destination) {
    const float2 outputPoint = destination.coord();
    // A downstream transform/composite may evaluate this kernel beyond its
    // declared extent. Edge sampling is valid inside the video only: outside
    // must be transparent so the presenter's black letterbox remains visible.
    if (any(outputPoint < float2(0.0f)) || any(outputPoint >= outputSize)) {
        return float4(0.0f);
    }
    float2 point = outputPoint * sourceSize / outputSize;
    float2 position = point - 0.5f;
    float2 base = floor(position);
    float3 samples[16];
    for (int y = 0; y < 4; ++y) {
        for (int x = 0; x < 4; ++x) {
            samples[y * 4 + x] = enhancementSample<encodedSRGB>(image, base + float2(x - 1, y - 1) + 0.5f, sourceSize);
        }
    }
    return enhancementFromSamples<encodedSRGB, edgeAdaptive>(samples, position, detail, cleanup);
}

// The specialization selects conversions at compile time, not per sampled pixel.
[[stitchable]] float4 smoothVideoEnhance(coreimage::sampler image, float2 sourceSize,
                                       float2 outputSize, float detail, float cleanup, coreimage::destination destination) {
    return enhancementReconstruct<false, false>(image, sourceSize, outputSize, detail, cleanup, destination);
}
[[stitchable]] float4 smoothVideoEnhanceSRGB(coreimage::sampler image, float2 sourceSize,
                                           float2 outputSize, float detail, float cleanup, coreimage::destination destination) {
    return enhancementReconstruct<true, false>(image, sourceSize, outputSize, detail, cleanup, destination);
}

// Separate entry points remove all EASU arithmetic from the established default path.
[[stitchable]] float4 smoothVideoEnhanceEdge(coreimage::sampler image, float2 sourceSize,
                                            float2 outputSize, float detail, float cleanup, coreimage::destination destination) {
    return enhancementReconstruct<false, true>(image, sourceSize, outputSize, detail, cleanup, destination);
}
[[stitchable]] float4 smoothVideoEnhanceSRGBEdge(coreimage::sampler image, float2 sourceSize,
                                                float2 outputSize, float detail, float cleanup, coreimage::destination destination) {
    return enhancementReconstruct<true, true>(image, sourceSize, outputSize, detail, cleanup, destination);
}

// Compose in destination pixels so sampler interpolation never extends video into bars.
[[stitchable]] float4 smoothVideoCanvas(coreimage::sampler image, float4 rectangle,
                                        coreimage::destination destination) {
    float2 point = destination.coord();
    if (any(point < rectangle.xy) || any(point >= rectangle.xy + rectangle.zw)) return float4(0.0f, 0.0f, 0.0f, 1.0f);
    float4 sample = image.sample(image.transform(point));
    return float4(sample.rgb, 1.0f);
}

// The local presenter has an explicit sRGB source texture. Read its texels once;
// share all reconstruction, cleanup and edge arithmetic with the CI/TV path.
vertex float4 smoothEnhancementVertex(uint index [[vertex_id]]) {
    float2 p = float2(float((index << 1) & 2), float(index & 2));
    return float4(p * 2.0f - 1.0f, 0.0f, 1.0f);
}

template <bool edgeAdaptive>
float4 enhancementTexture(texture2d<float, access::read> image, float2 outputPoint,
                          float4 rectangle, float2 detailCleanup) {
    if (any(outputPoint < rectangle.xy) || any(outputPoint >= rectangle.xy + rectangle.zw))
        return float4(0.0f, 0.0f, 0.0f, 1.0f);
    int2 size = int2(image.get_width(), image.get_height());
    float2 position = (outputPoint - rectangle.xy) * float2(size) / rectangle.zw - 0.5f;
    int2 base = int2(floor(position));
    float3 samples[16];
    for (int y = 0; y < 4; ++y) {
        for (int x = 0; x < 4; ++x) {
            samples[y * 4 + x] = image.read(uint2(clamp(base + int2(x-1, y-1), int2(0), size-1))).rgb;
        }
    }
    return enhancementFromSamples<true, edgeAdaptive>(samples, position, detailCleanup.x, detailCleanup.y);
}
fragment float4 smoothEnhancementFragment(float4 point [[position]],
        texture2d<float, access::read> image [[texture(0)]],
        constant float4 &rectangle [[buffer(0)]], constant float2 &detailCleanup [[buffer(1)]],
        constant float &flippedHeight [[buffer(2)]]) {
    float2 outputPoint = float2(point.x, flippedHeight > 0.0f ? flippedHeight - point.y : point.y);
    return enhancementTexture<false>(image, outputPoint, rectangle, detailCleanup);
}
fragment float4 smoothEnhancementEdgeFragment(float4 point [[position]],
        texture2d<float, access::read> image [[texture(0)]],
        constant float4 &rectangle [[buffer(0)]], constant float2 &detailCleanup [[buffer(1)]],
        constant float &flippedHeight [[buffer(2)]]) {
    float2 outputPoint = float2(point.x, flippedHeight > 0.0f ? flippedHeight - point.y : point.y);
    return enhancementTexture<true>(image, outputPoint, rectangle, detailCleanup);
}
