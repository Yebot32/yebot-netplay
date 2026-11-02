/**
 ******************************************************************************
 * Xenia : Xbox 360 Emulator Research Project                                 *
 ******************************************************************************
 * Copyright 2022 Ben Vanik. All rights reserved.                             *
 * Released under the BSD license - see LICENSE in the root for more details. *
 ******************************************************************************
 */

#include "xenia/gpu/draw_extent_estimator.h"

#include <cfloat>
#include <cmath>

#include "third_party/fmt/include/fmt/format.h"

#include "xenia/base/assert.h"
#include "xenia/base/cvar.h"
#include "xenia/base/memory.h"
#include "xenia/base/profiling.h"
#include "xenia/gpu/registers.h"
#include "xenia/gpu/ucode.h"
#include "xenia/gpu/xenos.h"
#include "xenia/ui/graphics_util.h"

DEFINE_bool(
    execute_unclipped_draw_vs_on_cpu, true,
    "Execute the vertex shader for draws with clipping disabled, primarily "
    "screen-space draws (such as clears), on the CPU when possible to estimate "
    "the extent of the EDRAM involved in the draw.\n"
    "Enabling this may significantly improve GPU performance as otherwise up "
    "to the entire EDRAM may be considered used in draws without clipping, "
    "potentially resulting in spurious EDRAM range ownership transfer round "
    "trips between host render targets.\n"
    "Also, on hosts where certain render target formats have to be emulated in "
    "a lossy way (for instance, 16-bit fixed-point via 16-bit floating-point), "
    "this prevents corruption of other render targets located after the "
    "current ones in the EDRAM by lossy range ownership transfers done for "
    "those draws.",
    "GPU");
DEFINE_bool(
    execute_unclipped_draw_vs_on_cpu_with_scissor, false,
    "Don't restrict the usage of execute_unclipped_draw_vs_on_cpu to only "
    "non-scissored draws (with the right and the bottom sides of the scissor "
    "rectangle at 8192 or beyond) even though if the scissor rectangle is "
    "present, it's usually sufficient for esimating the height of the render "
    "target.\n"
    "Enabling this may cause excessive processing of vertices on the CPU, as "
    "some games draw rectangles (for their UI, for instance) without clipping, "
    "but with a proper scissor rectangle.",
    "GPU");

namespace xe {
namespace gpu {

void DrawExtentEstimator::PositionYExportSink::Export(
    ucode::ExportRegister export_register, const float* value,
    uint32_t value_mask) {
  if (export_register == ucode::ExportRegister::kVSPosition) {
    if (value_mask & 0b0001) {
      position_x_ = value[0];
    }
    if (value_mask & 0b0010) {
      position_y_ = value[1];
    }
    if (value_mask & 0b0100) {
      position_z_ = value[2];
    }
    if (value_mask & 0b1000) {
      position_w_ = value[3];
    }
  } else if (export_register ==
             ucode::ExportRegister::kVSPointSizeEdgeFlagKillVertex) {
    if (value_mask & 0b0001) {
      point_size_ = value[0];
    }
    if (value_mask & 0b0100) {
      vertex_kill_ = xe::memory::Reinterpret<uint32_t>(value[2]);
    }
  }
}

uint32_t DrawExtentEstimator::EstimateVertexMaxY(const Shader& vertex_shader,
                                                 uint32_t y_scale) {
  SCOPE_profile_cpu_f("gpu");

  const RegisterFile& regs = register_file_;

  auto vgt_draw_initiator = regs.Get<reg::VGT_DRAW_INITIATOR>();
  if (!vgt_draw_initiator.num_indices) {
    return 0;
  }
  if (vgt_draw_initiator.source_select != xenos::SourceSelect::kDMA &&
      vgt_draw_initiator.source_select != xenos::SourceSelect::kAutoIndex) {
    // TODO(Triang3l): Support immediate indices.
    return xenos::kTexture2DCubeMaxWidthHeight;
  }

  // Not reproducing tessellation.
  if (xenos::IsMajorModeExplicit(vgt_draw_initiator.major_mode,
                                 vgt_draw_initiator.prim_type) &&
      regs.Get<reg::VGT_OUTPUT_PATH_CNTL>().path_select ==
          xenos::VGTOutputPath::kTessellationEnable) {
    return xenos::kTexture2DCubeMaxWidthHeight;
  }

  assert_true(vertex_shader.type() == xenos::ShaderType::kVertex);
  assert_true(vertex_shader.is_ucode_analyzed());
  if (!ShaderInterpreter::CanInterpretShader(vertex_shader)) {
    return xenos::kTexture2DCubeMaxWidthHeight;
  }

  auto vgt_dma_size = regs.Get<reg::VGT_DMA_SIZE>();
  union {
    const void* index_buffer;
    const uint16_t* index_buffer_16;
    const uint32_t* index_buffer_32;
  };
  xenos::Endian index_endian = vgt_dma_size.swap_mode;
  if (vgt_draw_initiator.source_select == xenos::SourceSelect::kDMA) {
    xenos::IndexFormat index_format = vgt_draw_initiator.index_size;
    uint32_t index_buffer_base = regs[XE_GPU_REG_VGT_DMA_BASE];
    uint32_t index_buffer_read_count =
        std::min(uint32_t(vgt_draw_initiator.num_indices),
                 uint32_t(vgt_dma_size.num_words));
    if (vgt_draw_initiator.index_size == xenos::IndexFormat::kInt16) {
      // Handle the index endianness to same way as the PrimitiveProcessor.
      if (index_endian == xenos::Endian::k8in32) {
        index_endian = xenos::Endian::k8in16;
      } else if (index_endian == xenos::Endian::k16in32) {
        index_endian = xenos::Endian::kNone;
      }
      index_buffer_base &= ~uint32_t(sizeof(uint16_t) - 1);
      if (trace_writer_) {
        trace_writer_->WriteMemoryRead(
            index_buffer_base, sizeof(uint16_t) * index_buffer_read_count);
      }
    } else {
      assert_true(vgt_draw_initiator.index_size == xenos::IndexFormat::kInt32);
      index_buffer_base &= ~uint32_t(sizeof(uint32_t) - 1);
      if (trace_writer_) {
        trace_writer_->WriteMemoryRead(
            index_buffer_base, sizeof(uint32_t) * index_buffer_read_count);
      }
    }
    index_buffer = memory_.TranslatePhysical(index_buffer_base);
  }
  auto pa_su_sc_mode_cntl = regs.Get<reg::PA_SU_SC_MODE_CNTL>();
  uint32_t reset_index =
      regs.Get<reg::VGT_MULTI_PRIM_IB_RESET_INDX>().reset_indx;
  uint32_t index_offset = regs.Get<reg::VGT_INDX_OFFSET>().indx_offset;
  uint32_t min_index = regs.Get<reg::VGT_MIN_VTX_INDX>().min_indx;
  uint32_t max_index = regs.Get<reg::VGT_MAX_VTX_INDX>().max_indx;

  auto pa_cl_vte_cntl = regs.Get<reg::PA_CL_VTE_CNTL>();
  float viewport_y_scale = pa_cl_vte_cntl.vport_y_scale_ena
                               ? regs.Get<float>(XE_GPU_REG_PA_CL_VPORT_YSCALE)
                               : 1.0f;
  float viewport_y_offset =
      pa_cl_vte_cntl.vport_y_offset_ena
          ? regs.Get<float>(XE_GPU_REG_PA_CL_VPORT_YOFFSET)
          : 0.0f;

  int32_t point_vertex_min_diameter_float = 0;
  int32_t point_vertex_max_diameter_float = 0;
  float point_constant_radius_y = 0.0f;
  if (vgt_draw_initiator.prim_type == xenos::PrimitiveType::kPointList) {
    auto pa_su_point_minmax = regs.Get<reg::PA_SU_POINT_MINMAX>();
    point_vertex_min_diameter_float = xe::memory::Reinterpret<int32_t>(
        float(pa_su_point_minmax.min_size) * (2.0f / 16.0f));
    point_vertex_max_diameter_float = xe::memory::Reinterpret<int32_t>(
        float(pa_su_point_minmax.max_size) * (2.0f / 16.0f));
    point_constant_radius_y =
        float(regs.Get<reg::PA_SU_POINT_SIZE>().height) * (1.0f / 16.0f);
  }

  float max_y = -FLT_MAX;

  shader_interpreter_.SetShader(vertex_shader);

  PositionYExportSink position_y_export_sink;
  shader_interpreter_.SetExportSink(&position_y_export_sink);
  for (uint32_t i = 0; i < vgt_draw_initiator.num_indices; ++i) {
    uint32_t vertex_index;
    if (vgt_draw_initiator.source_select == xenos::SourceSelect::kDMA) {
      if (i < vgt_dma_size.num_words) {
        if (vgt_draw_initiator.index_size == xenos::IndexFormat::kInt16) {
          vertex_index = index_buffer_16[i];
        } else {
          vertex_index = index_buffer_32[i];
        }
        // The Xenos only uses 24 bits of the index (reset_indx is 24-bit).
        vertex_index = xenos::GpuSwap(vertex_index, index_endian) & 0xFFFFFF;
      } else {
        vertex_index = 0;
      }
      if (pa_su_sc_mode_cntl.multi_prim_ib_ena && vertex_index == reset_index) {
        continue;
      }
    } else {
      assert_true(vgt_draw_initiator.source_select ==
                  xenos::SourceSelect::kAutoIndex);
      vertex_index = i;
    }
    vertex_index =
        std::min(max_index,
                 std::max(min_index, (vertex_index + index_offset) & 0xFFFFFF));

    position_y_export_sink.Reset();

    shader_interpreter_.temp_registers()[0] = float(vertex_index);
    shader_interpreter_.Execute();

    if (position_y_export_sink.vertex_kill().has_value() &&
        (position_y_export_sink.vertex_kill().value() & ~(UINT32_C(1) << 31))) {
      continue;
    }
    if (!position_y_export_sink.position_y().has_value()) {
      continue;
    }
    float vertex_y = position_y_export_sink.position_y().value();
    if (!pa_cl_vte_cntl.vtx_xy_fmt) {
      if (!position_y_export_sink.position_w().has_value()) {
        continue;
      }
      vertex_y /= position_y_export_sink.position_w().value();
    }

    vertex_y = vertex_y * viewport_y_scale + viewport_y_offset;

    if (vgt_draw_initiator.prim_type == xenos::PrimitiveType::kPointList) {
      float point_radius_y;
      if (position_y_export_sink.point_size().has_value()) {
        // Vertex-specified diameter. Clamped effectively as a signed integer in
        // the hardware, -NaN, -Infinity ... -0 to the minimum, +Infinity, +NaN
        // to the maximum.
        point_radius_y =
            0.5f *
            xe::memory::Reinterpret<float>(std::min(
                point_vertex_max_diameter_float,
                std::max(point_vertex_min_diameter_float,
                         xe::memory::Reinterpret<int32_t>(
                             position_y_export_sink.point_size().value()))));
      } else {
        // Constant radius.
        point_radius_y = point_constant_radius_y;
      }
      vertex_y += point_radius_y;
    }

    // std::max is `a < b ? b : a`, thus in case of NaN, the first argument is
    // always returned - max_y, which is initialized to a normalized value.
    max_y = std::max(max_y, vertex_y);
  }
  shader_interpreter_.SetExportSink(nullptr);

  // In the rows of the surface the draw is rasterized into, y_scale per guest
  // pixel (the samples of a 4x pixel drawn as 2x2 pixels).
  int32_t max_y_24p8 = ui::FloatToD3D11Fixed16p8(max_y * float(y_scale));
  // 16p8 range is -32768 to 32767+255/256, but it's stored as uint32_t here,
  // as 24p8, so overflowing up to -8388608 to 8388608+255/256 is safe. The
  // range of the window offset plus the half-pixel offset is -16384 to 16384.5,
  // so it's safe to add both - adding it will neither move the 16p8 clamping
  // bounds -32768 and 32767+255/256 into the 0...8192 screen space range, nor
  // cause 24p8 overflow.
  if (regs.Get<reg::PA_SU_VTX_CNTL>().pix_center ==
      xenos::PixelCenter::kD3DZero) {
    max_y_24p8 += 128 * int32_t(y_scale);
  }
  if (pa_su_sc_mode_cntl.vtx_window_offset_enable) {
    max_y_24p8 += regs.Get<reg::PA_SC_WINDOW_OFFSET>().window_y_offset * 256 *
                  int32_t(y_scale);
  }
  // Top-left rule - .5 exclusive without MSAA, 1. exclusive with MSAA.
  auto rb_surface_info = regs.Get<reg::RB_SURFACE_INFO>();
  return (uint32_t(std::max(int32_t(0), max_y_24p8)) +
          ((rb_surface_info.msaa_samples == xenos::MsaaSamples::k1X) ? 127
                                                                     : 255)) >>
         8;
}

bool DrawExtentEstimator::EstimateRectangle(const Shader& vertex_shader,
                                            float& left_out, float& top_out,
                                            float& right_out, float& bottom_out,
                                            const char** why_not_out) {
  SCOPE_profile_cpu_f("gpu");

  const RegisterFile& regs = register_file_;
  auto why_not = [&](const char* reason) {
    if (why_not_out) {
      *why_not_out = reason;
    }
    return false;
  };

  auto vgt_draw_initiator = regs.Get<reg::VGT_DRAW_INITIATOR>();
  if (vgt_draw_initiator.prim_type != xenos::PrimitiveType::kRectangleList ||
      vgt_draw_initiator.num_indices != 3 ||
      (vgt_draw_initiator.source_select != xenos::SourceSelect::kDMA &&
       vgt_draw_initiator.source_select != xenos::SourceSelect::kAutoIndex)) {
    return why_not("not a rectangle list of 3 indices");
  }
  if (xenos::IsMajorModeExplicit(vgt_draw_initiator.major_mode,
                                 vgt_draw_initiator.prim_type) &&
      regs.Get<reg::VGT_OUTPUT_PATH_CNTL>().path_select ==
          xenos::VGTOutputPath::kTessellationEnable) {
    return why_not("tessellated");
  }
  assert_true(vertex_shader.type() == xenos::ShaderType::kVertex);
  if (!vertex_shader.is_ucode_analyzed() ||
      !ShaderInterpreter::CanInterpretShader(vertex_shader)) {
    return why_not("the vertex shader fetches textures");
  }

  uint32_t vertex_indices[3] = {0, 1, 2};
  if (vgt_draw_initiator.source_select == xenos::SourceSelect::kDMA) {
    // The same index handling as in EstimateVertexMaxY.
    auto vgt_dma_size = regs.Get<reg::VGT_DMA_SIZE>();
    if (vgt_dma_size.num_words < 3) {
      return why_not("fewer than 3 indices in the buffer");
    }
    xenos::Endian index_endian = vgt_dma_size.swap_mode;
    uint32_t index_buffer_base = regs[XE_GPU_REG_VGT_DMA_BASE];
    if (vgt_draw_initiator.index_size == xenos::IndexFormat::kInt16) {
      if (index_endian == xenos::Endian::k8in32) {
        index_endian = xenos::Endian::k8in16;
      } else if (index_endian == xenos::Endian::k16in32) {
        index_endian = xenos::Endian::kNone;
      }
      index_buffer_base &= ~uint32_t(sizeof(uint16_t) - 1);
      if (trace_writer_) {
        trace_writer_->WriteMemoryRead(index_buffer_base,
                                       sizeof(uint16_t) * 3);
      }
      const uint16_t* index_buffer_16 =
          memory_.TranslatePhysical<const uint16_t*>(index_buffer_base);
      for (uint32_t i = 0; i < 3; ++i) {
        vertex_indices[i] =
            xenos::GpuSwap(uint32_t(index_buffer_16[i]), index_endian) &
            0xFFFFFF;
      }
    } else {
      index_buffer_base &= ~uint32_t(sizeof(uint32_t) - 1);
      if (trace_writer_) {
        trace_writer_->WriteMemoryRead(index_buffer_base,
                                       sizeof(uint32_t) * 3);
      }
      const uint32_t* index_buffer_32 =
          memory_.TranslatePhysical<const uint32_t*>(index_buffer_base);
      for (uint32_t i = 0; i < 3; ++i) {
        vertex_indices[i] =
            xenos::GpuSwap(index_buffer_32[i], index_endian) & 0xFFFFFF;
      }
    }
    if (regs.Get<reg::PA_SU_SC_MODE_CNTL>().multi_prim_ib_ena) {
      uint32_t reset_index =
          regs.Get<reg::VGT_MULTI_PRIM_IB_RESET_INDX>().reset_indx;
      for (uint32_t i = 0; i < 3; ++i) {
        if (vertex_indices[i] == reset_index) {
          return why_not("a primitive reset index");
        }
      }
    }
  }
  uint32_t index_offset = regs.Get<reg::VGT_INDX_OFFSET>().indx_offset;
  uint32_t min_index = regs.Get<reg::VGT_MIN_VTX_INDX>().min_indx;
  uint32_t max_index = regs.Get<reg::VGT_MAX_VTX_INDX>().max_indx;

  auto pa_cl_vte_cntl = regs.Get<reg::PA_CL_VTE_CNTL>();
  const bool clip = !regs.Get<reg::PA_CL_CLIP_CNTL>().clip_disable;
  if (clip && pa_cl_vte_cntl.vtx_xy_fmt) {
    // Screen-space positions clipped against the clip space - unusual.
    return why_not("screen-space positions with clipping");
  }
  float viewport_scale_x = pa_cl_vte_cntl.vport_x_scale_ena
                               ? regs.Get<float>(XE_GPU_REG_PA_CL_VPORT_XSCALE)
                               : 1.0f;
  float viewport_offset_x =
      pa_cl_vte_cntl.vport_x_offset_ena
          ? regs.Get<float>(XE_GPU_REG_PA_CL_VPORT_XOFFSET)
          : 0.0f;
  float viewport_scale_y = pa_cl_vte_cntl.vport_y_scale_ena
                               ? regs.Get<float>(XE_GPU_REG_PA_CL_VPORT_YSCALE)
                               : 1.0f;
  float viewport_offset_y =
      pa_cl_vte_cntl.vport_y_offset_ena
          ? regs.Get<float>(XE_GPU_REG_PA_CL_VPORT_YOFFSET)
          : 0.0f;

  float x[3], y[3];
  const char* invalid_reason = nullptr;
  shader_interpreter_.SetShader(vertex_shader);
  PositionYExportSink position_export_sink;
  shader_interpreter_.SetExportSink(&position_export_sink);
  for (uint32_t i = 0; i < 3; ++i) {
    uint32_t vertex_index = std::min(
        max_index,
        std::max(min_index, (vertex_indices[i] + index_offset) & 0xFFFFFF));
    position_export_sink.Reset();
    shader_interpreter_.temp_registers()[0] = float(vertex_index);
    shader_interpreter_.Execute();
    if ((position_export_sink.vertex_kill().has_value() &&
         (position_export_sink.vertex_kill().value() &
          ~(UINT32_C(1) << 31))) ||
        !position_export_sink.position_x().has_value() ||
        !position_export_sink.position_y().has_value() ||
        !position_export_sink.position_z().has_value()) {
      invalid_reason = "a vertex killed or without a position";
      break;
    }
    float vertex_x = position_export_sink.position_x().value();
    float vertex_y = position_export_sink.position_y().value();
    float vertex_z = position_export_sink.position_z().value();
    if (!pa_cl_vte_cntl.vtx_xy_fmt || !pa_cl_vte_cntl.vtx_z_fmt) {
      if (!position_export_sink.position_w().has_value() ||
          !(position_export_sink.position_w().value() > 0.0f)) {
        invalid_reason = "a vertex without a positive W";
        break;
      }
      float vertex_w = position_export_sink.position_w().value();
      if (!pa_cl_vte_cntl.vtx_xy_fmt) {
        vertex_x /= vertex_w;
        vertex_y /= vertex_w;
      }
      if (!pa_cl_vte_cntl.vtx_z_fmt) {
        vertex_z /= vertex_w;
      }
    }
    // Outside the depth range, depth clipping may drop it - unless the host
    // clamps the depth of draws without clipping (NaN is never safe).
    if (!(vertex_z >= 0.0f && vertex_z <= 1.0f) &&
        (clip || !unclipped_depth_clamped_ || std::isnan(vertex_z))) {
      invalid_reason = "a vertex Z outside 0...1";
      break;
    }
    if (clip) {
      // Clipped to the viewport. NaN fails the checks below.
      vertex_x = std::min(std::max(vertex_x, -1.0f), 1.0f);
      vertex_y = std::min(std::max(vertex_y, -1.0f), 1.0f);
    }
    x[i] = vertex_x * viewport_scale_x + viewport_offset_x;
    y[i] = vertex_y * viewport_scale_y + viewport_offset_y;
  }
  shader_interpreter_.SetExportSink(nullptr);
  if (invalid_reason) {
    return why_not(invalid_reason);
  }

  // Three distinct corners of an axis-aligned rectangle.
  float left = std::min(std::min(x[0], x[1]), x[2]);
  float right = std::max(std::max(x[0], x[1]), x[2]);
  float top = std::min(std::min(y[0], y[1]), y[2]);
  float bottom = std::max(std::max(y[0], y[1]), y[2]);
  // With the vertices, for traces.
  auto why_not_vertices = [&](const char* reason) {
    if (why_not_out) {
      why_not_detail_ = fmt::format(
          "{} ({},{} {},{} {},{}; viewport scale {} {} offset {} {}, clip {}, "
          "xy/z formats {}{})",
          reason, x[0], y[0], x[1], y[1], x[2], y[2], viewport_scale_x,
          viewport_scale_y, viewport_offset_x, viewport_offset_y,
          uint32_t(clip), uint32_t(pa_cl_vte_cntl.vtx_xy_fmt),
          uint32_t(pa_cl_vte_cntl.vtx_z_fmt));
      *why_not_out = why_not_detail_.c_str();
    }
    return false;
  };
  if (!(right > left) || !(bottom > top)) {
    return why_not_vertices("an empty rectangle");
  }
  for (uint32_t i = 0; i < 3; ++i) {
    if ((x[i] != left && x[i] != right) || (y[i] != top && y[i] != bottom)) {
      return why_not_vertices("vertices not at the corners of a rectangle");
    }
    for (uint32_t j = i + 1; j < 3; ++j) {
      if (x[i] == x[j] && y[i] == y[j]) {
        return why_not("two vertices at one corner");
      }
    }
  }

  // Window offset, and the pixel centers at +0.5 like in EstimateVertexMaxY.
  float offset_x = 0.0f, offset_y = 0.0f;
  if (regs.Get<reg::PA_SU_SC_MODE_CNTL>().vtx_window_offset_enable) {
    auto pa_sc_window_offset = regs.Get<reg::PA_SC_WINDOW_OFFSET>();
    offset_x += float(pa_sc_window_offset.window_x_offset);
    offset_y += float(pa_sc_window_offset.window_y_offset);
  }
  if (regs.Get<reg::PA_SU_VTX_CNTL>().pix_center ==
      xenos::PixelCenter::kD3DZero) {
    offset_x += 0.5f;
    offset_y += 0.5f;
  }
  left_out = left + offset_x;
  right_out = right + offset_x;
  top_out = top + offset_y;
  bottom_out = bottom + offset_y;
  return true;
}

uint32_t DrawExtentEstimator::EstimateMaxY(bool try_to_estimate_vertex_max_y,
                                           const Shader& vertex_shader,
                                           uint32_t y_scale) {
  SCOPE_profile_cpu_f("gpu");

  const RegisterFile& regs = register_file_;

  auto pa_sc_window_offset = regs.Get<reg::PA_SC_WINDOW_OFFSET>();
  int32_t window_y_offset = pa_sc_window_offset.window_y_offset;

  // Scissor.
  auto pa_sc_window_scissor_br = regs.Get<reg::PA_SC_WINDOW_SCISSOR_BR>();
  int32_t scissor_bottom = int32_t(pa_sc_window_scissor_br.br_y);
  bool scissor_window_offset =
      !regs.Get<reg::PA_SC_WINDOW_SCISSOR_TL>().window_offset_disable;
  if (scissor_window_offset) {
    scissor_bottom += window_y_offset;
  }
  auto pa_sc_screen_scissor_br = regs.Get<reg::PA_SC_SCREEN_SCISSOR_BR>();
  scissor_bottom =
      std::min(scissor_bottom, int32_t(pa_sc_screen_scissor_br.br_y));
  uint32_t max_y = uint32_t(std::max(scissor_bottom, int32_t(0))) * y_scale;

  if (regs.Get<reg::PA_CL_CLIP_CNTL>().clip_disable) {
    // Actual extent from the vertices.
    if (try_to_estimate_vertex_max_y &&
        cvars::execute_unclipped_draw_vs_on_cpu) {
      bool estimate_vertex_max_y;
      if (cvars::execute_unclipped_draw_vs_on_cpu_with_scissor) {
        estimate_vertex_max_y = true;
      } else {
        estimate_vertex_max_y = false;
        if (scissor_bottom >= xenos::kTexture2DCubeMaxWidthHeight) {
          // Handle just the usual special 8192x8192 case in Direct3D 9 - 8192
          // may be a normal render target height (80x8192 is well within the
          // EDRAM size, for instance), no need to process the vertices on the
          // CPU in this case.
          int32_t scissor_right = int32_t(pa_sc_window_scissor_br.br_x);
          if (scissor_window_offset) {
            scissor_right += pa_sc_window_offset.window_x_offset;
          }
          scissor_right =
              std::min(scissor_right, int32_t(pa_sc_screen_scissor_br.br_x));
          if (scissor_right >= xenos::kTexture2DCubeMaxWidthHeight) {
            estimate_vertex_max_y = true;
          }
        }
      }
      if (estimate_vertex_max_y) {
        max_y = std::min(max_y, EstimateVertexMaxY(vertex_shader, y_scale));
      }
    }
  } else {
    // Viewport. Though the Xenos itself doesn't have an implicit viewport
    // scissor (it's set by Direct3D 9 when a viewport is used), on hosts, it
    // usually exists and can't be disabled.
    auto pa_cl_vte_cntl = regs.Get<reg::PA_CL_VTE_CNTL>();
    float viewport_bottom = 0.0f;
    // First calculate all the integer.0 or integer.5 offsetting exactly at full
    // precision.
    if (regs.Get<reg::PA_SU_SC_MODE_CNTL>().vtx_window_offset_enable) {
      viewport_bottom += float(window_y_offset);
    }
    if (regs.Get<reg::PA_SU_VTX_CNTL>().pix_center ==
        xenos::PixelCenter::kD3DZero) {
      viewport_bottom += 0.5f;
    }
    // Then apply the floating-point viewport offset.
    if (pa_cl_vte_cntl.vport_y_offset_ena) {
      viewport_bottom += regs.Get<float>(XE_GPU_REG_PA_CL_VPORT_YOFFSET);
    }
    viewport_bottom +=
        pa_cl_vte_cntl.vport_y_scale_ena
            ? std::abs(regs.Get<float>(XE_GPU_REG_PA_CL_VPORT_YSCALE))
            : 1.0f;
    // Using floor, or, rather, truncation (because maxing with zero anyway)
    // similar to how viewport scissoring behaves on real AMD, Intel and Nvidia
    // GPUs on Direct3D 12 (but not WARP), also like in
    // draw_util::GetHostViewportInfo.
    // max(0.0f, viewport_bottom) to drop NaN and < 0 - max picks the first
    // argument in the !(a < b) case (always for NaN), min as float (max_y is
    // well below 2^24) to safely drop very large values.
    max_y = uint32_t(std::min(
        float(max_y), std::max(0.0f, viewport_bottom * float(y_scale))));
  }

  return max_y;
}

}  // namespace gpu
}  // namespace xe
