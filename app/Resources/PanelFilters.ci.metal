/*
 * Period Mac display emulation, as a Core Image kernel.
 *
 * Ported from PocketShaver's compositor_shaders.metal (apply_panel_filter),
 * which is where these panels were worked out; the maths is unchanged, only
 * the plumbing differs.  Core Image gives us destination coordinates in
 * pixels and a sampler over the guest's framebuffer, where the original had
 * fragment window coordinates and a texture.
 *
 * Built with `xcrun metal -fcikernel`, so it is a supported CIKernel rather
 * than the deprecated Core Image Kernel Language.  See scripts/build-app.sh.
 */
#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

static inline float panel_lum(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }

static inline float3 tone_grayscale(float3 rgb) {
    float l = panel_lum(rgb);
    l = mix(0.05, 0.95, l);
    l = floor(l * 15.0 + 0.5) / 15.0;                  /* 16 grays */
    return clamp(l * float3(0.92, 1.0, 0.94), 0.0, 1.0);
}

static inline float3 tone_passive(float3 rgb) {
    float l = panel_lum(rgb);
    float3 c = mix(float3(l), rgb, 0.55);              /* desaturate ~45% */
    c = mix(float3(0.10, 0.10, 0.14), float3(0.86, 0.86, 0.92), c);
    return clamp(c, 0.0, 1.0);
}

static inline float3 tone_active(float3 rgb) {
    float l = panel_lum(rgb);
    float3 c = mix(float3(l), rgb, 1.18);              /* +18% saturation */
    return clamp(c * float3(0.99, 1.0, 1.02), 0.0, 1.0);
}

static inline float3 posterize_4bit(float3 c) {
    return floor(c * 3.0 + 0.5) / 3.0;                 /* 4 levels a channel */
}

static inline float mono_dither(float l, float2 pos) {
    /* 4x4 Bayer ordered dither -> the classic 1-bit Mac look */
    const float bayer[16] = {  0.0,  8.0,  2.0, 10.0,
                              12.0,  4.0, 14.0,  6.0,
                               3.0, 11.0,  1.0,  9.0,
                              15.0,  7.0, 13.0,  5.0 };
    uint ix = uint(pos.x) % 4u;
    uint iy = uint(pos.y) % 4u;
    float t = (bayer[iy * 4u + ix] + 0.5) / 16.0;
    return (l > t) ? 1.0 : 0.0;
}

static inline float3 crt_effect(float3 rgb, float2 pos, float2 uv, bool colorMask) {
    float scan = 0.78 + 0.22 * (0.5 + 0.5 * cos(pos.y * 3.14159265));
    float3 mask = float3(1.0);
    if (colorMask) {
        uint col = uint(pos.x) % 3u;
        mask = (col == 0u) ? float3(1.0, 0.72, 0.72)
             : (col == 1u) ? float3(0.72, 1.0, 0.72)
                           : float3(0.72, 0.72, 1.0);
    }
    float2 d = uv - 0.5;
    float vig = clamp(1.0 - dot(d, d) * 0.7, 0.0, 1.0);
    float3 c = rgb * scan * mix(float3(1.0), mask, 0.22) * vig;
    return clamp(c * 1.18, 0.0, 1.0);                  /* offset the darkening */
}

extern "C" float4 panelFilter(coreimage::sample_t s,
                              float mode, float w, float h,
                              coreimage::destination dest)
{
    float3 rgb = float3(s.r, s.g, s.b);
    float2 pos = dest.coord();
    float2 uv  = float2(pos.x / max(w, 1.0), pos.y / max(h, 1.0));
    uint m = uint(mode + 0.5);

    float3 o = rgb;
    if (m == 1u)      { o = tone_grayscale(rgb); }
    else if (m == 2u) { o = tone_passive(rgb); }
    else if (m == 3u) { o = tone_active(rgb); }
    else if (m == 4u) { o = crt_effect(rgb, pos, uv, true); }
    else if (m == 5u) { o = crt_effect(float3(panel_lum(rgb)), pos, uv, false); }
    else if (m == 6u) { o = posterize_4bit(tone_passive(rgb)); }
    else if (m == 7u) { o = crt_effect(float3(mono_dither(panel_lum(rgb), pos)), pos, uv, false); }
    return float4(o, s.a);
}
