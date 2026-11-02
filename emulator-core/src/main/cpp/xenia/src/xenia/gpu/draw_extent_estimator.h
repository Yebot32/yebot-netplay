/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Copyright 2022 Ben Vanik. All rights reserved.                             *
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 */

#ifndef XENIA_GPU_DRAW_EXTENT_ESTIMATOR_H_
#define XENIA_GPU_DRAW_EXTENT_ESTIMATOR_H_

#include <cstdint>
#include <optional>
#include <string>

#include "xenia/gpu/register_file.h"
#include "xenia/gpu/shader.h"
#include "xenia/gpu/shader_interpreter.h"
#include "xenia/gpu/trace_writer.h"
#include "xenia/memory.h"

namespace xe {
namespace gpu {

class DrawExtentEstimator {
 public:
  DrawExtentEstimator(const RegisterFile& register_file, const Memory& memory,
                      TraceWriter* trace_writer)
      : register_file_(register_file),
        memory_(memory),
        trace_writer_(trace_writer),
        shader_interpreter_(register_file, memory) {
    shader_interpreter_.SetTraceWriter(trace_writer);
  }

  // The shader must have its ucode analyzed. y_scale is how many rows of the
  // surface the draw is rasterized into each guest pixel row covers (2 for
  // the samples of a 4x pixel drawn as 2x2 pixels) - the result is in those
  // rows, rounded like the surface (the current RB_SURFACE_INFO) does.
  uint32_t EstimateVertexMaxY(const Shader& vertex_shader,
                              uint32_t y_scale = 1);
  uint32_t EstimateMaxY(bool try_to_estimate_vertex_max_y,
                        const Shader& vertex_shader, uint32_t y_scale = 1);

  // For a draw of a single axis-aligned rectangle (a rectangle list of 3
  // vertices) with a vertex shader the CPU can run: the area it covers in
  // pixels of the render target - [left, right) x [top, bottom), pixel centers
  // at +0.5 - clipped to the viewport when clipping is enabled, before the
  // scissor. False for any other draw, or if the rectangle may be clipped by
  // depth - with why_not_out (if not null) set to the reason, for traces.
  bool EstimateRectangle(const Shader& vertex_shader, float& left_out,
                         float& top_out, float& right_out, float& bottom_out,
                         const char** why_not_out = nullptr);

  // Whether the host clamps the depth of draws without clipping (Vulkan
  // depthClampEnable) instead of clipping it - then a rectangle at any depth
  // is drawn whole.
  void SetUnclippedDepthClamped(bool clamped) {
    unclipped_depth_clamped_ = clamped;
  }

 private:
  class PositionYExportSink : public ShaderInterpreter::ExportSink {
   public:
    void Export(ucode::ExportRegister export_register, const float* value,
                uint32_t value_mask) override;

    void Reset() {
      position_x_.reset();
      position_y_.reset();
      position_z_.reset();
      position_w_.reset();
      point_size_.reset();
      vertex_kill_.reset();
    }

    const std::optional<float>& position_x() const { return position_x_; }
    const std::optional<float>& position_y() const { return position_y_; }
    const std::optional<float>& position_z() const { return position_z_; }
    const std::optional<float>& position_w() const { return position_w_; }
    const std::optional<float>& point_size() const { return point_size_; }
    const std::optional<uint32_t>& vertex_kill() const { return vertex_kill_; }

   private:
    std::optional<float> position_x_;
    std::optional<float> position_y_;
    std::optional<float> position_z_;
    std::optional<float> position_w_;
    std::optional<float> point_size_;
    std::optional<uint32_t> vertex_kill_;
  };

  const RegisterFile& register_file_;
  const Memory& memory_;
  TraceWriter* trace_writer_;
  bool unclipped_depth_clamped_ = false;
  // The reason EstimateRectangle returns with the vertices.
  std::string why_not_detail_;

  ShaderInterpreter shader_interpreter_;
};

}  // namespace gpu
}  // namespace xe

#endif  // XENIA_GPU_DRAW_EXTENT_ESTIMATOR_H_
