# Code from Xendroid+

This 360 core includes GPU work ported from Xendroid+
(https://github.com/phforner0/Xendroid-Plus), licensed under the GNU Affero
General Public License v3.0 or later (see `LICENSE.AGPL-3.0`). Taken from its
history up to commit bb9f0751fc (2026-10-07), applied as one three-way merge of
its changes since its own import of XenDroid (de2221288a):

- `emulator-core/src/main/cpp/xenia/src/xenia/gpu/` (minus its vblank pacer and
  graphics system), `game_quirks.*`, `memory.{h,cc}` (heap region queries),
  `base/{cvar,frame_stats,shader_compile_counter,guest_gpu_progress}.h`,
  `ui/vulkan/{vulkan_instance,vulkan_device,vulkan_gpu_completion_timeline}.*`,
  `ui/vulkan/functions/device_1_0.inc`, `ui/gpu_completion_timeline.h` and
  `tools/build/gen_android_spirv.py`.

Not taken: its JIT, kernel, audio, presenter, frame generation, scaling
filters and app. Because the AGPL covers the combined work, anyone receiving a
build of this core is entitled to its complete corresponding source.
