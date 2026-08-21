/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 */

#include "xenia/gpu/upstream_conformance.h"

#include <string>
#include <vector>

#include "third_party/fmt/include/fmt/format.h"
#include "xenia/base/cvar.h"
#include "xenia/base/logging.h"

DEFINE_int32(
    gpu_upstream_conformance, 14,
    "Force the GPU cvars that exist ONLY in this Android fork back to Xenia "
    "Edge's PC behaviour, and log every override.\n"
    "A BITMASK, so a fault can be narrowed to one group without a rebuild - "
    "each group is one config edit:\n"
    "  0  off, this fork's own behaviour everywhere\n"
    "  1  render targets: in-pass transfers and resolves, the "
    "resolve-to-texture fast paths, the ownership-claim memo\n"
    "  2  command stream: mid-frame submission splitting, bulk register "
    "ranges, the size cursor, redundant fetch-constant skipping\n"
    "  4  descriptors and pipelines: texture/sampler descriptor caching, "
    "dynamic pipeline state, don't-care key normalisation, pipeline "
    "pre-creation, async draw skipping\n"
    "  8  memory: host-visible shared memory, upload hoisting\n"
    "  16 precision and primitives: native unorm24 depth, reverse depth "
    "ranges, geometry-shader avoidance. These CAN legitimately change output "
    "and may render worse on some devices, which is why they are not in the "
    "default\n"
    "  14 (default) 2|4|8 - everything EXCEPT render targets, so this fork's "
    "in-pass transfer and resolve fast paths stay live\n"
    "  15 every group whose options exist purely for speed. This was the "
    "default until 2026-08-21 and is the fallback if a picture fault ever "
    "returns\n"
    "  31 all of the above\n"
    "Groups 1-8 cost frame rate; that is what those options were added to buy.\n"
    "*** WHY GROUP 1 LEFT THE DEFAULT. *** It was in it to mask a picture "
    "fault, not because the render-target fast paths are unsound: a resolve "
    "copied out a target whose queued EDRAM ownership transfers had never "
    "been encoded, so a strip of it held only its clear. Resolve() now drains "
    "that queue before it copies (f81171d13), the way the Metal backend this "
    "path was ported from always did, and the fault no longer reproduces at "
    "14 in the titles it was found in. What left the queue full is NOT "
    "established - no draw is ever skipped at this setting (measured: zero "
    "\"Draw skipped\" lines across five logged runs), so the skipped-draw "
    "path that guard was written for is not the answer. Forcing group 1 makes "
    "every "
    "transfer and resolve break the render pass, and on a tiler each break "
    "costs a full tile store and reload; that is where 216 render passes per "
    "frame came from. Putting it back to 15 buys nothing now and costs that.",
    "GPU");
// 15 -> 14 once the picture fault group 1 was masking stopped reproducing.
// Without this
// line the new default reaches nothing: SaveConfig() writes every cvar, so any
// device that has run this build once has 15 pinned in its TOML and a changed
// default is inert there. Only a config still sitting on the old default moves;
// anyone who picked a value deliberately keeps it.
UPDATE_from_int32(gpu_upstream_conformance, 2026, 8, 21, 12, 15);

// Fork-only, level 1: scheduling, caching and fast paths.
DECLARE_bool(vulkan_in_pass_transfers);
DECLARE_bool(vulkan_in_pass_resolve);
DECLARE_bool(vulkan_direct_host_resolve);
DECLARE_bool(vulkan_resolve_to_texture);
DECLARE_bool(vulkan_resolve_to_texture_promote);
DECLARE_bool(vulkan_resolve_to_texture_serve);
DECLARE_bool(rt_cache_ownership_claim_memo);
DECLARE_bool(render_area_dirty_extent);
DECLARE_int32(vulkan_mid_frame_submission_draws);
DECLARE_bool(vulkan_deferred_cmd_size_cursor);
DECLARE_bool(vulkan_fast_register_ranges);
DECLARE_bool(vulkan_skip_redundant_fetch_constant_writes);
DECLARE_bool(vulkan_cache_texture_descriptors);
DECLARE_bool(vulkan_texture_descriptor_reuse_edge);
DECLARE_bool(vulkan_cache_sampler_parameters);
DECLARE_bool(vulkan_fast_sampler_filterability);
DECLARE_bool(vulkan_dynamic_pipeline_state);
DECLARE_bool(vulkan_normalize_dontcare_keys);
DECLARE_bool(pipeline_storage_precreate);
DECLARE_bool(vulkan_placeholder_pipelines);
DECLARE_bool(vulkan_async_skip_draws);
DECLARE_bool(vulkan_hoist_shmem_uploads);
DECLARE_bool(vulkan_shared_memory_host_visible);

// Fork-only, level 2: paths that can legitimately change pixels.
DECLARE_bool(vulkan_depth_unorm24);
DECLARE_bool(vulkan_allow_reverse_z);
DECLARE_bool(vulkan_avoid_geometry_shaders);

namespace xe {
namespace gpu {

namespace {

// Bits of gpu_upstream_conformance. Grouped by subsystem rather than by
// suspicion, so a bisect is four config edits and no rebuilds.
constexpr int32_t kGroupRenderTargets = 1;
constexpr int32_t kGroupCommandStream = 2;
constexpr int32_t kGroupDescriptors = 4;
constexpr int32_t kGroupMemory = 8;
constexpr int32_t kGroupPrecision = 16;

// Collected rather than logged inline so the whole set lands as one block that
// is trivially greppable, and so a run with conformance ON but nothing
// overridden (everything already at the upstream value) is still visible.
std::vector<std::string> g_overrides;

void ForceBool(const char* name, bool& value, bool upstream) {
  if (value == upstream) {
    return;
  }
  g_overrides.push_back(fmt::format("{}: {} -> {}", name, value, upstream));
  value = upstream;
}

void ForceInt(const char* name, int32_t& value, int32_t upstream) {
  if (value == upstream) {
    return;
  }
  g_overrides.push_back(fmt::format("{}: {} -> {}", name, value, upstream));
  value = upstream;
}

}  // namespace

void ApplyGpuUpstreamConformance() {
  const int32_t groups = cvars::gpu_upstream_conformance;
  if (groups <= 0) {
    return;
  }
  g_overrides.clear();

  // Every one of these is a fork-only option: upstream Edge has no such cvar
  // and always behaves as the "upstream" value given here.

  // 1 - the render-target path, which is where a strip artifact lives:
  // ownership transfers and resolves.
  if (groups & kGroupRenderTargets) {
    ForceBool("vulkan_in_pass_transfers", cvars::vulkan_in_pass_transfers,
              false);
    ForceBool("vulkan_in_pass_resolve", cvars::vulkan_in_pass_resolve, false);
    ForceBool("vulkan_direct_host_resolve", cvars::vulkan_direct_host_resolve,
              false);
    ForceBool("vulkan_resolve_to_texture", cvars::vulkan_resolve_to_texture,
              false);
    ForceBool("vulkan_resolve_to_texture_promote",
              cvars::vulkan_resolve_to_texture_promote, false);
    ForceBool("vulkan_resolve_to_texture_serve",
              cvars::vulkan_resolve_to_texture_serve, false);
    ForceBool("rt_cache_ownership_claim_memo",
              cvars::rt_cache_ownership_claim_memo, false);
    ForceBool("render_area_dirty_extent", cvars::render_area_dirty_extent,
              false);
  }

  // 2 - the command stream: when the buffer is closed, how register writes are
  // decoded, and how its length is tracked.
  if (groups & kGroupCommandStream) {
    ForceInt("vulkan_mid_frame_submission_draws",
             cvars::vulkan_mid_frame_submission_draws, 0);
    ForceBool("vulkan_deferred_cmd_size_cursor",
              cvars::vulkan_deferred_cmd_size_cursor, false);
    ForceBool("vulkan_fast_register_ranges", cvars::vulkan_fast_register_ranges,
              false);
    ForceBool("vulkan_skip_redundant_fetch_constant_writes",
              cvars::vulkan_skip_redundant_fetch_constant_writes, false);
  }

  // 4 - descriptors, samplers and pipelines: the reuse gates that decide
  // whether a draw re-binds what it needs.
  if (groups & kGroupDescriptors) {
    ForceBool("vulkan_cache_texture_descriptors",
              cvars::vulkan_cache_texture_descriptors, false);
    ForceBool("vulkan_texture_descriptor_reuse_edge",
              cvars::vulkan_texture_descriptor_reuse_edge, false);
    ForceBool("vulkan_cache_sampler_parameters",
              cvars::vulkan_cache_sampler_parameters, false);
    ForceBool("vulkan_fast_sampler_filterability",
              cvars::vulkan_fast_sampler_filterability, false);
    ForceBool("vulkan_dynamic_pipeline_state",
              cvars::vulkan_dynamic_pipeline_state, false);
    ForceBool("vulkan_normalize_dontcare_keys",
              cvars::vulkan_normalize_dontcare_keys, false);
    ForceBool("pipeline_storage_precreate", cvars::pipeline_storage_precreate,
              false);
    ForceBool("vulkan_placeholder_pipelines",
              cvars::vulkan_placeholder_pipelines, false);
    ForceBool("vulkan_async_skip_draws", cvars::vulkan_async_skip_draws, false);
  }

  // 8 - memory.
  if (groups & kGroupMemory) {
    ForceBool("vulkan_hoist_shmem_uploads", cvars::vulkan_hoist_shmem_uploads,
              false);
    ForceBool("vulkan_shared_memory_host_visible",
              cvars::vulkan_shared_memory_host_visible, false);
  }

  // 16 - can legitimately change what is drawn, and on a device without a
  // usable alternative may render worse rather than better, which is why it is
  // not in the default set.
  if (groups & kGroupPrecision) {
    ForceBool("vulkan_depth_unorm24", cvars::vulkan_depth_unorm24, false);
    ForceBool("vulkan_allow_reverse_z", cvars::vulkan_allow_reverse_z, false);
    ForceBool("vulkan_avoid_geometry_shaders",
              cvars::vulkan_avoid_geometry_shaders, false);
  }

  // Written unconditionally, including when nothing needed changing: a
  // diagnostic that is silent when it did nothing is indistinguishable from one
  // that never ran, which is how a whole family of earlier GPU results ended up
  // unprovable.
  XELOGI("GpuConformance: groups 0x{:X} applied, {} cvar(s) overridden", groups,
         g_overrides.size());
  for (const std::string& line : g_overrides) {
    XELOGI("GpuConformance:   {}", line);
  }
}

}  // namespace gpu
}  // namespace xe
