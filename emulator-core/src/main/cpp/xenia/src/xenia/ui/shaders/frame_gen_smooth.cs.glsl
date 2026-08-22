#version 450
#extension GL_GOOGLE_include_directive : require
// Vector field smoothing.
//
// Neighbours are weighted by how much they agree with the centre. A plain blur
// would drag a genuine motion boundary across the silhouette it belongs to;
// this lets blocks that agree average together while a block sitting on a real
// edge keeps its own answer.
#include "frame_gen_common.glsli"

layout(local_size_x = XE_FG_LOCAL_SIZE, local_size_y = XE_FG_LOCAL_SIZE) in;
layout(set = 0, binding = 3, rg32f) uniform writeonly image2D xe_fg_dst;

void main() {
  ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
  if (any(greaterThanEqual(vec2(coord), xe_fg.dst_size))) {
    return;
  }
  vec2 uv = (vec2(coord) + 0.5) / xe_fg.dst_size;

  vec2 centre = texture(xe_fg_src0, uv).xy;
  vec2 acc = vec2(0.0);
  float wsum = 0.0;
  for (int y = -1; y <= 1; ++y) {
    for (int x = -1; x <= 1; ++x) {
      vec2 m =
          texture(xe_fg_src0, uv + vec2(float(x), float(y)) * xe_fg.src_texel)
              .xy;
      float w = 1.0 / (1.0 + length(m - centre) * 0.25);
      acc += m * w;
      wsum += w;
    }
  }
  imageStore(xe_fg_dst, coord, vec4(acc / wsum, 0.0, 0.0));
}
