#include <metal_stdlib>
#include <RealityKit/RealityKit.h>
using namespace metal;

[[visible]]
void normalSurfaceShader(realitykit::surface_parameters params) {

    // Get the interpolated/shading normal provided by RealityKit
    float3 interpNormal = normalize(params.surface().normal());

    // Compute a face (flat) normal using derivatives. This effectively gives
    // each triangle a constant color instead of a smoothly interpolated one.
    // Use dfdx/dfdy on the position to get the geometric normal of the surface
    // in the current coordinate space.
    float3 pos = params.geometry().model_position();
    float3 dpdx = dfdx(pos);
    float3 dpdy = dfdy(pos);

    float3 faceNormal = normalize(cross(dpdx, dpdy));

    // If derivatives produce a degenerate normal (e.g. zero-length), fall back
    // to the interpolated normal. Use absolute value so negative components
    // don't get clipped to black when remapped to color space.
    bool validFace = all(isfinite(faceNormal)) && length(faceNormal) > 1e-6;
    float3 chosen = validFace ? faceNormal : interpNormal;

    // Map from [-1, 1] to [0, 1] for display
    half3 color = half3(abs(chosen) * 0.5 + 0.5);

    // Set the base color to the mapped normal color
    params.surface().set_base_color(color);
}
