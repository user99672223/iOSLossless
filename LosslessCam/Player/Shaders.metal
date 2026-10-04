#include <metal_stdlib>
using namespace metal;

// Must match HDRRenderer.Uniforms in Swift (same field order, 16-byte aligned groups).
struct Uniforms {
    float3x3 transform;   // view uv -> texture uv
    uint mode;            // 0 single, 1 side-by-side, 2 A/B flip, 3 wipe, 4 difference
    uint showB;
    uint hasB;
    uint bitDepth;        // 8 or 10
    uint fullRange;
    uint colorspace;      // 0 = BT.709, 1 = BT.2020 NCL
    uint nearest;
    uint pad0;
    float divider;
    float gain;
    float sdrWhite;       // output level that maps to SDR white in the layer's colour space
    float pad1;
};

struct VSOut {
    float4 position [[position]];
    float2 uv;
};

vertex VSOut fullscreenVertex(uint vid [[vertex_id]])
{
    float2 pos[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    VSOut o;
    o.position = float4(pos[vid], 0, 1);
    o.uv = float2((pos[vid].x + 1) * 0.5, 1.0 - (pos[vid].y + 1) * 0.5);
    return o;
}

static inline float3 ycc_to_rgb(float3 ycc, constant Uniforms &u)
{
    // Texture values are unorm: 16-bit words carry the 10-bit code in the MSBs.
    float scale = (u.bitDepth == 10) ? (65535.0 / 64.0) : 255.0;
    float maxv = (u.bitDepth == 10) ? 1023.0 : 255.0;
    float3 code = ycc * scale;
    float ymin = u.fullRange ? 0.0 : ((u.bitDepth == 10) ? 64.0 : 16.0);
    float yrange = u.fullRange ? maxv : ((u.bitDepth == 10) ? 876.0 : 219.0);
    float crange = u.fullRange ? maxv : ((u.bitDepth == 10) ? 896.0 : 224.0);
    float mid = (u.bitDepth == 10) ? 512.0 : 128.0;
    float y = (code.x - ymin) / yrange;
    float cb = (code.y - mid) / crange;
    float cr = (code.z - mid) / crange;
    float3 rgb;
    if (u.colorspace == 1) {
        rgb = float3(y + 1.4746 * cr,
                     y - 0.164553 * cb - 0.571353 * cr,
                     y + 1.8814 * cb);
    } else {
        rgb = float3(y + 1.5748 * cr,
                     y - 0.187324 * cb - 0.468124 * cr,
                     y + 1.8556 * cb);
    }
    return clamp(rgb, 0.0, 1.0);
}

static inline float luma_norm(float yUnorm, constant Uniforms &u)
{
    float scale = (u.bitDepth == 10) ? (65535.0 / 64.0) : 255.0;
    float maxv = (u.bitDepth == 10) ? 1023.0 : 255.0;
    float ymin = u.fullRange ? 0.0 : ((u.bitDepth == 10) ? 64.0 : 16.0);
    float yrange = u.fullRange ? maxv : ((u.bitDepth == 10) ? 876.0 : 219.0);
    return (yUnorm * scale - ymin) / yrange;
}

static inline float3 heat(float d)
{
    // black -> blue -> cyan -> green -> yellow -> red -> white
    d = clamp(d, 0.0, 1.0);
    float3 c;
    if (d < 0.2)      c = mix(float3(0, 0, 0), float3(0, 0, 1), d / 0.2);
    else if (d < 0.4) c = mix(float3(0, 0, 1), float3(0, 1, 1), (d - 0.2) / 0.2);
    else if (d < 0.6) c = mix(float3(0, 1, 1), float3(0, 1, 0), (d - 0.4) / 0.2);
    else if (d < 0.8) c = mix(float3(0, 1, 0), float3(1, 1, 0), (d - 0.6) / 0.2);
    else if (d < 0.9) c = mix(float3(1, 1, 0), float3(1, 0, 0), (d - 0.8) / 0.1);
    else              c = mix(float3(1, 0, 0), float3(1, 1, 1), (d - 0.9) / 0.1);
    return c;
}

static inline float3 sampleYCC(texture2d<float> yTex, texture2d<float> cTex, sampler s, float2 uv)
{
    float y = yTex.sample(s, uv).r;
    float2 c = cTex.sample(s, uv).rg;
    return float3(y, c.x, c.y);
}

fragment half4 compareFragment(VSOut in [[stage_in]],
                               constant Uniforms &u [[buffer(0)]],
                               texture2d<float> yA [[texture(0)]],
                               texture2d<float> cA [[texture(1)]],
                               texture2d<float> yB [[texture(2)]],
                               texture2d<float> cB [[texture(3)]])
{
    constexpr sampler linearS(filter::linear, address::clamp_to_edge);
    constexpr sampler nearestS(filter::nearest, address::clamp_to_edge);
    float2 uv = in.uv;
    bool useB = false;
    if (u.mode == 1) {               // side by side: left A, right B
        if (abs(uv.x - 0.5) < 0.0015) return half4(0.3, 0.3, 0.3, 1);
        useB = uv.x >= 0.5;
        uv.x = useB ? (uv.x - 0.5) * 2.0 : uv.x * 2.0;
    } else if (u.mode == 2) {        // A/B flip
        useB = u.showB != 0;
    } else if (u.mode == 3) {        // wipe
        if (abs(uv.x - u.divider) < 0.002) return half4(1.0, 0.85, 0.2, 1);
        useB = uv.x >= u.divider;
    }
    if (useB && u.hasB == 0) useB = false;

    float3 t = u.transform * float3(uv, 1.0);
    float2 tex = t.xy;
    if (tex.x < 0.0 || tex.x > 1.0 || tex.y < 0.0 || tex.y > 1.0) {
        return half4(0.02, 0.02, 0.02, 1);
    }
    float3 yccA = u.nearest ? sampleYCC(yA, cA, nearestS, tex) : sampleYCC(yA, cA, linearS, tex);

    if (u.mode == 4) {               // amplified luma difference heat map
        if (u.hasB == 0) return half4(0, 0, 0, 1);
        float3 yccB = u.nearest ? sampleYCC(yB, cB, nearestS, tex) : sampleYCC(yB, cB, linearS, tex);
        float d = abs(luma_norm(yccA.x, u) - luma_norm(yccB.x, u)) * u.gain;
        float3 c = heat(d) * u.sdrWhite;
        return half4(half3(c), 1);
    }
    float3 ycc = yccA;
    if (useB) ycc = u.nearest ? sampleYCC(yB, cB, nearestS, tex) : sampleYCC(yB, cB, linearS, tex);
    float3 rgb = ycc_to_rgb(ycc, u);
    return half4(half3(rgb), 1);
}
