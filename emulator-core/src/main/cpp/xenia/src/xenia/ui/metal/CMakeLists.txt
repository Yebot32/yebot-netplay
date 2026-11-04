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
# Same host-tool story as gpu/metal above: on iOS the rules run with the
# prebuilt native xenia-shader-cc (XE_FORCE_HOST_SHADER_CC) and emit
# iphoneos-targeted AIR via XE_METAL_TARGET_SDK.
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
  set(XE_METAL_TARGET_SDK "iphoneos")
  set(XE_METAL_MIN_VERSION "16.0")
endif()
xe_shader_rules_metal(xenia-ui-metal ${CMAKE_CURRENT_SOURCE_DIR}/../shaders)
xe_shader_rules_slang(xenia-ui-metal ${CMAKE_CURRENT_SOURCE_DIR}/../shaders
                      TARGET msl)
xe_target_defaults(xenia-ui-metal)
