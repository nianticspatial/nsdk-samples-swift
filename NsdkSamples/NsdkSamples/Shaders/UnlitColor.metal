#include <metal_stdlib>
using namespace metal;

// Simple shader to render any geometry with color
struct UnlitColorVertexIn {
    float3 position [[ attribute(0) ]];
    float3 color    [[ attribute(1) ]];
};

struct UnlitColorVertexOut {
    float4 position [[ position ]];
    float3 color;
};

vertex UnlitColorVertexOut unlitColorVertex(
    UnlitColorVertexIn in           [[ stage_in ]],
    constant float4x4 &mvp          [[ buffer(1) ]]
) {
    UnlitColorVertexOut out;
    out.position = mvp * float4(in.position, 1.0);
    out.color    = in.color;
    return out;
}

fragment float4 unlitColorFragment(UnlitColorVertexOut in [[ stage_in ]]) {
    return float4(in.color, 1.0);
}
