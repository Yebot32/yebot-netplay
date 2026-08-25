add_library(xenia-ui-metal STATIC
  metal_api.cc
  metal_api.h
  metal_gpu_completion_timeline.cc
  metal_gpu_completion_timeline.h
  metal_immediate_drawer.h
  metal_immediate_drawer.mm
  metal_presenter.h
  metal_presenter.mm
  metal_provider.cc
  metal_provider.h
)
target_link_libraries(xenia-ui-metal PUBLIC
  xenia-base
  xenia-ui
  "-framework Foundation"
  "-framework Metal"
  "-framework MetalKit"
  "-framework MetalFX"
  "-framework QuartzCore"
)
# AppKit is macOS-only; UIKit is its iOS counterpart. metal_presenter.mm
# imports the matching header behind the same condition.
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
  target_link_libraries(xenia-ui-metal PUBLIC "-framework UIKit")
else()
  target_link_libraries(xenia-ui-metal PUBLIC "-framework AppKit")
endif()
# iOS, exactly as Android does above in gpu/vulkan: the shader pipeline runs
# the host tool xenia-shader-cc (and slangc), and neither can run in a
# cross-compile - building xenia-shader-cc under the iOS toolchain produces an
# arm64-iOS binary the build machine cannot execute. Consume the committed
# bytecode headers under ../shaders/bytecode/metal/ instead.
#
# MILESTONE 2 MUST REVISIT THIS. Those committed metallibs were generated with
# `-sdk macosx`, and the iOS Metal loader rejects macOS AIR at runtime. Nothing
# links these targets yet, so it does not bite today; it will the moment the
# renderer is wired up. The fix is a two-stage build (host tool first, then
# cross) or committed iOS-SDK bytecode, not a flag.
if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
  xe_shader_rules_metal(xenia-ui-metal ${CMAKE_CURRENT_SOURCE_DIR}/../shaders)
  xe_shader_rules_slang(xenia-ui-metal ${CMAKE_CURRENT_SOURCE_DIR}/../shaders
                        TARGET msl)
endif()
xe_target_defaults(xenia-ui-metal)
