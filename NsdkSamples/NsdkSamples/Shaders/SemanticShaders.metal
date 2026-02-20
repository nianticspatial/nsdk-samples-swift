#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float3 texCoord;
};

struct Uniforms {
    float3x3 uvTransform;
    float4 tint;
};

static inline float3 HSVtoRGB(float3 hsv)
{
    float4 K = float4(1.0, 2.0/3.0, 1.0/3.0, 3.0);
    float3 P = abs(fract(hsv.xxx + K.xyz) * 6.0 - K.www);
    return hsv.z * mix(K.xxx, saturate(P - K.xxx), hsv.y);
}

vertex VertexOut semanticVertexShader(VertexIn in [[stage_in]],
                                     constant Uniforms& uniforms [[buffer(1)]]) {
    VertexOut out;

    // Forward vertex position
    out.position = float4(in.position, 0.0, 1.0);
    
    // Transform UVs
    float3 uvh = float3(in.texCoord, 1.0);
    out.texCoord = uniforms.uvTransform * uvh;
    
    return out;
}

fragment float4 semanticFragmentShader(VertexOut in [[stage_in]],
                                      texture2d<float> confidenceTexture [[texture(0)]],
                                      constant Uniforms& uniforms [[buffer(1)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);

    // Sample the raw float confidence texture
    float2 uv = in.texCoord.xy / in.texCoord.z;
    float confidence = confidenceTexture.sample(textureSampler, uv).r;
    
    // Interpolate hue and clamp to [0,1]
    float hue = mix(0.70, -0.15, saturate(confidence));
    if (hue < 0.0) {
        hue += 1.0;
    }

    // Compose HSV color
    float3 hsv = float3(hue, 0.9, 0.6);
    float3 color = HSVtoRGB(hsv);

    // Apply alpha
    return float4(color, uniforms.tint.w);
}
