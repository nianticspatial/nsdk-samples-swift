#include <metal_stdlib>
using namespace metal;

struct OcclusionMeshUniforms {
    // The rendering camera's projection * view matrix
    float4x4 viewProj;
    
    // The camera intrinsics for the depth texture
    float3x3 intrinsics;
    
    // The camera pose associated with the depth texture
    float4x4 extrinsics;
    
    // The resolution of the depth texture
    float2 resolution;
};

struct OcclusionMeshVertexOut {
    float4 position [[ position ]];   // clip-space
    float4 color;                     // passthrough
};

vertex OcclusionMeshVertexOut occlusionMeshVertex(
    const device float2 *uvGrid          [[ buffer(0) ]],
    constant OcclusionMeshUniforms &u  [[ buffer(1) ]],
    texture2d<float> depthTexture        [[ texture(0) ]],
    uint vid                             [[ vertex_id ]]
)
{
    OcclusionMeshVertexOut out;
    out.color = float4(0, 0, 0, 1);
    
    // Acquire UVs
    float2 uv = uvGrid[vid];
    
    // Calculate pixel coordinates
    float px = uv.x * (u.resolution.x - 1.0);
    float py = uv.y * (u.resolution.y - 1.0);
    
    // Flip y-axis (image is mirrored)
    uv = float2(uv.x, 1.0 - uv.y);
    
    constexpr sampler depthSampler(address::clamp_to_edge,
                                   filter::linear,
                                   coord::normalized);
    
    // Real-world depth in meters (positive)
    float depth = depthTexture.sample(depthSampler, uv).r;
    
    // Extract intrinsics
    float fx = u.intrinsics[0][0];
    float fy = u.intrinsics[1][1];
    float cx = u.intrinsics[2][0];
    float cy = u.intrinsics[2][1];
    
    // Calculate view position
    float x_cam = (px - cx) * depth / fx;
    float y_cam = (py - cy) * depth / fy;
    float z_cam = -depth;
    
    float4 camPos = float4(x_cam, y_cam, z_cam, 1.0);
    
    // Calculate world position
    float4 worldPos = u.extrinsics * camPos;
    
    // Calculate clip space position
    out.position = u.viewProj * worldPos;
    out.color = float4(depth, 0, 0, 1);
    
    return out;
}

fragment float4 occlusionMeshFragment(OcclusionMeshVertexOut in [[ stage_in ]])
{
    // Draw color for debug purposes
    return float4(in.color.x, in.color.y, in.color.z, 1.0);
}
