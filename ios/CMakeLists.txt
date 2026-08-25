# =============================================================================
# Xenra iOS shell - Milestone 1
# =============================================================================
# A deliberately small app whose job is to prove the pipeline, not to run a
# game. It links the REAL xenia-base, so the JIT probe and platform detection
# on screen are the emulator's own, not a reimplementation that could drift.
#
# Note what it does NOT link: xenia-ui. That target pulls the vendored
# wxWidgets desktop shell on every platform that is not Android or iOS, and
# Surface is header-only (surface.h defines GetSize inline and leaves
# GetSizeImpl pure virtual), so surface_ios.mm can be compiled straight into
# the app with no library dependency at all. Milestone 2 - the one that
# actually renders - is where xenia-ui-metal and xenia-gpu-metal come in.

set(_xe_ios_dir "${CMAKE_CURRENT_SOURCE_DIR}")
set(_xe_root "${CMAKE_CURRENT_SOURCE_DIR}/../emulator-core/src/main/cpp/xenia")

add_executable(xenra-ios MACOSX_BUNDLE
  "${_xe_ios_dir}/src/main.mm"
  "${_xe_ios_dir}/src/XenraAppDelegate.h"
  "${_xe_ios_dir}/src/XenraAppDelegate.mm"
  "${_xe_ios_dir}/src/XenraMetalView.h"
  "${_xe_ios_dir}/src/XenraMetalView.mm"
  # Compiled in directly rather than via xenia-ui - see the note above.
  "${_xe_root}/src/xenia/ui/surface_ios.mm"
)

target_include_directories(xenra-ios PRIVATE
  "${_xe_ios_dir}/src"
  "${_xe_root}/src"
  "${_xe_root}"
)

target_link_libraries(xenra-ios PRIVATE xenia-base)

target_link_libraries(xenra-ios PRIVATE
  "-framework UIKit"
  "-framework Metal"
  "-framework QuartzCore"
  "-framework Foundation"
)

# ARC is off across the xenia tree (metal-cpp does its own retain/release and
# the .mm files here are written for manual management). Keeping the app
# consistent with that avoids a per-file exception and the ownership confusion
# that comes with mixing the two in one binary.
target_compile_options(xenra-ios PRIVATE
  "$<$<COMPILE_LANGUAGE:OBJC,OBJCXX>:-fno-objc-arc>"
)

set_target_properties(xenra-ios PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST "${_xe_ios_dir}/Info.plist"
  XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "Ali.Xanite.green.ios"
  # A device build only. The simulator has no JIT story worth testing and no
  # real GPU, which are the two things this milestone exists to measure.
  XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
)
