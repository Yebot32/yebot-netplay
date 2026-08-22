#version 450
#extension GL_GOOGLE_include_directive : require
// Captures the current guest image into the history the NEXT generated frame
// will interpolate from.
//
// A compute copy rather than vkCmdCopyImage because the guest output image is
// left in SHADER_READ_ONLY_OPTIMAL by the refresher and is sampled in this same
// command buffer - a transfer copy would mean transitioning it to
// TRANSFER_SRC_OPTIMAL and back, in the middle of someone else's paint. It also
// lands both ends of the eventual match in one format, so the warp samples them
// identically.
#include "frame_gen_common.glsli"

layout(local_size_x = XE_FG_LOCAL_SIZE, local_size_y = XE_FG_LOCAL_SIZE) in;
layout(set = 0, binding = 3, rgba16f) uniform writeonly image2D xe_fg_dst;

void main() {
  ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
  if (any(greaterThanEqual(vec2(coord), xe_fg.dst_size))) {
    return;
  }
  vec2 uv = (vec2(coord) + 0.5) / xe_fg.dst_size;
  imageStore(xe_fg_dst, coord, vec4(texture(xe_fg_src0, uv).rgb, 1.0));
}
