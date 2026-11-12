// Copyright 2026 Niantic Spatial.

#include <metal_stdlib>
using namespace metal;

// Shaders for MeshRenderer. Textured chunks render as opaque depth-tested triangles;
// untextured chunks render as a see-through wireframe that self-occludes via a
// depth-only prepass.

struct MeshRendererUniforms {
    float4x4 modelView;
    float4x4 projection;
};

// NSDK mesh vertices are y/z-inverted relative to ARKit space. Chunk and
// camera transforms are ARKit-space, so flip each vertex before transforming.
static inline float3 flippedPosition(packed_float3 position) {
    float3 p = float3(position);
    p.y = -p.y;
    p.z = -p.z;
    return p;
}

// RealityKit's scene depth is reverse-Z, cleared to 0, and the camera background writes no
// depth, so any pixel with depth > 0 is covered by scene content: the mesh is discarded
// there. The mask flag disables the test when no scene depth is bound.
static inline bool coveredByScene(depth2d<float, access::read> sceneDepth,
                                  uint sceneDepthMask,
                                  float4 fragPosition) {
    return sceneDepthMask != 0 && sceneDepth.read(uint2(fragPosition.xy)) > 0.0;
}

// MARK: - Textured

struct MeshTexturedVSOut {
    float4 position [[position]];
    float2 uv;
};

vertex MeshTexturedVSOut meshRendererTexturedVertex(
    const device packed_float3* positions   [[buffer(0)]],
    const device packed_float2* uvs         [[buffer(1)]],
    constant MeshRendererUniforms& uniforms [[buffer(2)]],
    uint vid                                [[vertex_id]]
) {
    MeshTexturedVSOut out;
    float4 viewPos = uniforms.modelView * float4(flippedPosition(positions[vid]), 1.0);
    out.position = uniforms.projection * viewPos;
    // Mesh UVs use a bottom-left origin; Metal textures sample top-left.
    float2 uv = float2(uvs[vid]);
    out.uv = float2(uv.x, 1.0 - uv.y);
    return out;
}

fragment half4 meshRendererTexturedFragment(
    MeshTexturedVSOut in                    [[stage_in]],
    texture2d<half> colorTexture            [[texture(0)]],
    depth2d<float, access::read> sceneDepth [[texture(1)]],
    constant uint& sceneDepthMask           [[buffer(0)]]
) {
    if (coveredByScene(sceneDepth, sceneDepthMask, in.position)) {
        discard_fragment();
    }
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    return half4(colorTexture.sample(s, in.uv).rgb, 1.0h);
}

// MARK: - Wireframe

struct MeshWireframeVSOut {
    float4 position [[position]];
};

vertex MeshWireframeVSOut meshRendererWireframeVertex(
    const device packed_float3* positions   [[buffer(0)]],
    constant MeshRendererUniforms& uniforms [[buffer(2)]],
    uint vid                                [[vertex_id]]
) {
    MeshWireframeVSOut out;
    float4 viewPos = uniforms.modelView * float4(flippedPosition(positions[vid]), 1.0);
    out.position = uniforms.projection * viewPos;
    return out;
}

// Depth-only prepass: writes the solid mesh into the depth buffer so the
// wireframe draw can depth-test against its own faces. The pipeline masks
// all color writes, so nothing is returned.
fragment void meshRendererDepthOnlyFragment() {}

fragment half4 meshRendererWireframeFragment(
    MeshWireframeVSOut in                   [[stage_in]],
    float3 barycentric                      [[barycentric_coord]],
    depth2d<float, access::read> sceneDepth [[texture(1)]],
    constant uint& sceneDepthMask           [[buffer(0)]]
) {
    if (coveredByScene(sceneDepth, sceneDepthMask, in.position)) {
        discard_fragment();
    }

    // Near an edge one barycentric coordinate approaches 0. fwidth gives how much each
    // coordinate changes per pixel, so the line keeps a constant width in pixels whatever
    // the triangle's size or distance. Matches the Kotlin sample's wireframe.
    constexpr float lineWidthPixels = 1.5;
    float3 edgeWidth = fwidth(barycentric) * lineWidthPixels;
    float3 edgeFade = smoothstep(float3(0.0), edgeWidth, barycentric);
    half factor = half(1.0 - min(edgeFade.x, min(edgeFade.y, edgeFade.z)));

    // Drop interior fragments entirely so the fill stays see-through.
    if (factor <= 0.0h) {
        discard_fragment();
    }

    return half4(half3(0.0h, 1.0h, 1.0h), 0.95h * factor);
}

// Fallback for GPUs without barycentric coordinate support: the renderer
// draws the same triangles with a lines fill mode, so every rasterized
// fragment is already an edge and just needs the wireframe color.
fragment half4 meshRendererWireframeLineFragment(
    MeshWireframeVSOut in                   [[stage_in]],
    depth2d<float, access::read> sceneDepth [[texture(1)]],
    constant uint& sceneDepthMask           [[buffer(0)]]
) {
    if (coveredByScene(sceneDepth, sceneDepthMask, in.position)) {
        discard_fragment();
    }
    return half4(0.0h, 1.0h, 1.0h, 0.95h);
}
