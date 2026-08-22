#version 450
#extension GL_GOOGLE_include_directive : require
// The warp. Produces the invented frame.
#include "frame_gen_common.glsli"

layout(local_size_x = XE_FG_LOCAL_SIZE, local_size_y = XE_FG_LOCAL_SIZE) in;
layout(set = 0, binding = 3, rgba16f) uniform writeonly image2D xe_fg_dst;

void main() {
  ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
  if (any(greaterThanEqual(vec2(coord), xe_fg.dst_size))) {
    return;
  }
  vec2 uv = (vec2(coord) + 0.5) / xe_fg.dst_size;

  // The field is sampled with linear filtering, so the blocks it was computed
  // on do not appear as blocks in the output.
  vec2 mv = texture(xe_fg_src2, uv).xy * xe_fg.src_texel;
  vec3 a = texture(xe_fg_src0, uv - mv * xe_fg.t).rgb;
  vec3 b = texture(xe_fg_src1, uv + mv * (1.0 - xe_fg.t)).rgb;
  vec3 blended = mix(a, b, xe_fg.t);

  // Disocclusion guard. Where the two ends of the match disagree there is no
  // correct in-between pixel to find - this is the background emerging from
  // behind a moving object - and averaging produces the transparent double
  // image that gives frame generation its reputation. Committing to the nearer
  // frame is wrong for one frame; a ghost is wrong and also draws the eye.
  float disagree = length(a - b);
  float fallback = smoothstep(0.16, 0.42, disagree);
  vec3 nearer = (xe_fg.t < 0.5) ? a : b;

  imageStore(xe_fg_dst, coord, vec4(mix(blended, nearer, fallback), 1.0));
}
