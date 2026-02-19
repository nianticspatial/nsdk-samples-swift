#include <metal_stdlib>
using namespace metal;

// MARK: - Structures

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

struct ScanningCompositeUniforms {
    uint stripeStride;      // e.g., 7 for 640 width, 3 for smaller
    uint stripeRedPixels;   // e.g., 5 for large, 2 for small
};

// MARK: - Vertex/Fragment Shaders for Display

vertex VertexOut scanningVertexShader(VertexIn in [[stage_in]],
                                      constant Uniforms& uniforms [[buffer(1)]]) {
    VertexOut out;

    // Forward vertex position
    out.position = float4(in.position, 0.0, 1.0);

    // Transform UVs
    float3 uvh = float3(in.texCoord, 1.0);
    out.texCoord = uniforms.uvTransform * uvh;

    return out;
}

fragment float4 scanningFragmentShader(VertexOut in [[stage_in]],
                                       texture2d<float> texture [[texture(0)]],
                                       constant Uniforms& uniforms [[buffer(1)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);

    // Sample the texture (already composited with stripes)
    float2 uv = in.texCoord.xy / in.texCoord.z;
    float4 color = texture.sample(textureSampler, uv);

    // Apply tint and opacity
    return float4(color.rgb * uniforms.tint.rgb, color.a * uniforms.tint.w);
}

// MARK: - Compute Kernel for Compositing

// Compute kernel to composite raycast texture with stripe pattern
// This renders the final visualization into an output texture
kernel void scanning_composite_kernel(
    texture2d<float, access::write> outputTexture [[texture(0)]],
    texture2d<float, access::sample> raycastTexture [[texture(1)]],
    constant ScanningCompositeUniforms& uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 gridSize [[threads_per_grid]])
{
    // Check bounds
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    // Calculate normalized UV coordinates
    float2 uv = (float2(gid) + 0.5) / float2(gridSize);

    // Sample the raycast texture (RGB = color, A = scanned/unscanned)
    float4 raycastColor = raycastTexture.sample(textureSampler, uv);

    float3 color = raycastColor.rgb;
    float raycastAlpha = raycastColor.a;

    // Generate diagonal stripe pattern for unscanned areas
    // Diagonal stripes: (x + height - y) creates diagonal lines
    uint stripeCoord = (gid.x + gridSize.y - gid.y) & uniforms.stripeStride;

    // Determine stripe color: red or white
    float3 stripeColor;
    if (stripeCoord < uniforms.stripeRedPixels) {
        stripeColor = float3(0.9, 0.0, 0.18);  // Red stripe
    } else {
        stripeColor = float3(1.0, 1.0, 1.0);   // White stripe
    }

    // Blend raycast color with stripe pattern based on raycast alpha
    // raycastAlpha = 1 means fully scanned (show raycast color)
    // raycastAlpha = 0 means unscanned (show stripe pattern)
    color = color * raycastAlpha + stripeColor * (1.0 - raycastAlpha);

    // Write the final composited color to output texture
    outputTexture.write(float4(color, 1.0), gid);
}
