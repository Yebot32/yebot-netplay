/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 */

#ifndef XENIA_GPU_UPSTREAM_CONFORMANCE_H_
#define XENIA_GPU_UPSTREAM_CONFORMANCE_H_

namespace xe {
namespace gpu {

// Forces the GPU cvars that exist ONLY in this Android fork back to the
// behaviour Xenia Edge has on PC, so one run can say whether a rendering fault
// lives in this fork's own optimisation layer or in the emulator both share.
//
// WHY THIS EXISTS. The Vulkan backend here carries about thirty behaviour
// changes that upstream Edge does not have, and most of them default to ON:
// ownership transfers executed inside the render pass, three resolve fast
// paths, descriptor and sampler caching, dynamic pipeline state, register-range
// bulk writes, host-visible shared memory, mid-frame submission splitting, and
// more. Every one of them is a plausible cause of a rendering artifact, and
// chasing them one at a time costs a device run each. This turns the whole
// group into a single A/B: if the artifact survives with conformance on, the
// entire layer is excluded in one run; if it disappears, bisecting the group is
// a handful of runs instead of thirty.
//
// It is a DIAGNOSTIC, not a fix. Expect it to be slower - that is the point,
// the speed is what these cvars were added for.
//
// Must be called after the config is loaded and before anything reads a GPU
// cvar. On Android that is EmulatorApp::OnInitialize, right after
// config::SetupConfig and the per-game overlay.
void ApplyGpuUpstreamConformance();

}  // namespace gpu
}  // namespace xe

#endif  // XENIA_GPU_UPSTREAM_CONFORMANCE_H_
