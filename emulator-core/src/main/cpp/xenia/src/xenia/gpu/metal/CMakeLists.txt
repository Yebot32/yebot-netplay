add_library(xenia-gpu-metal STATIC
  metal_command_processor.cc
  metal_command_processor.h
  metal_graphics_system.cc
  metal_graphics_system.h
  metal_heap_pool.cc
  metal_heap_pool.h
  metal_primitive_processor.cc
  metal_primitive_processor.h
  metal_render_target_cache.cc
  metal_render_target_cache.h
  metal_shader_cache.cc
  metal_shader_cache.h
  metal_shared_memory.cc
  metal_shared_memory.h
  metal_texture_cache.cc
  metal_texture_cache.h
  metal_upload_buffer_pool.cc
  metal_upload_buffer_pool.h
  msl_bindings.h
  msl_shader.cc
  msl_shader.h
  msl_tess_factor_kernels.h
)
target_include_directories(xenia-gpu-metal PRIVATE
  ${PROJECT_SOURCE_DIR}/third_party/glslang
)
target_link_libraries(xenia-gpu-metal PUBLIC
  xenia-base
  xenia-gpu
  xenia-ui-metal
  spirv-cross
  "-framework Foundation"
  "-framework Metal"
  "-framework MetalKit"
)
target_link_libraries(xenia-gpu-metal PRIVATE glslang-spirv)
# The shader pipeline runs the host tool xenia-shader-cc (and slangc), which
# must execute on the build machine even though the TARGET here is iOS. The
# iOS CI therefore builds the host tool in a first, native pass and points
# this configure at it via XE_FORCE_HOST_SHADER_CC + XE_HOST_SHADER_CC_PATH
# (see third_party/CMakeLists.txt). The rules target iOS by env: the tool
# reads XE_METAL_TARGET_SDK to emit -sdk iphoneos / -std=ios-metal2.3 AIR,
# which the on-device loader accepts (macOS AIR is rejected there).
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
  set(XE_METAL_TARGET_SDK "iphoneos")
  set(XE_METAL_MIN_VERSION "16.0")
endif()
xe_shader_rules_metal(xenia-gpu-metal ${CMAKE_CURRENT_SOURCE_DIR}/../shaders)
xe_shader_rules_slang(xenia-gpu-metal ${CMAKE_CURRENT_SOURCE_DIR}/../shaders
                      TARGET msl)
xe_target_defaults(xenia-gpu-metal)
