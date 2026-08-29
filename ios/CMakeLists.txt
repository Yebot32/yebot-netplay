# =============================================================================
# Xenra iOS - the full emulator target
# =============================================================================
# What links here: the whole xenia engine - a64 CPU backend, Metal GPU
# backend, Metal UI layer, kernel, VFS, patcher - plus the iOS shell that
# replaces the Android JNI layer (ios_emu.mm: IosWindowedAppContext,
# IosWindow, boot thread, virtual-gamepad input driver) and the UIKit
# screens (XenraAppDelegate.mm).
#
# Milestone 1 linked only xenia-base. Everything below that is new is the
# milestone-2 renderer/engine wiring the milestone-1 doc promised.
#
# Known runtime gap, deliberate for this build: gpu/metal and ui/metal consume
# the committed bytecode headers (see the MILESTONE 2 MUST REVISIT notes in
# their CMakeLists) - those were generated with the macOS SDK. The two-stage
# host-tool shader build that regenerates them with -sdk iphoneos is the next
# commit; until then the engine boots with a renderer that may refuse its
# metallibs on device. JIT and the pipeline are unaffected.

set(_xe_ios_dir "${CMAKE_CURRENT_SOURCE_DIR}")
set(_xe_root "${CMAKE_CURRENT_SOURCE_DIR}/../emulator-core/src/main/cpp/xenia")

add_executable(xenra-ios MACOSX_BUNDLE
  "${_xe_ios_dir}/src/main.mm"
  "${_xe_ios_dir}/src/XenraAppDelegate.h"
  "${_xe_ios_dir}/src/XenraAppDelegate.mm"
  "${_xe_ios_dir}/src/XenraMetalView.h"
  "${_xe_ios_dir}/src/XenraMetalView.mm"
  "${_xe_ios_dir}/src/ios_emu.h"
  "${_xe_ios_dir}/src/ios_emu.mm"
  # Compiled in directly rather than via xenia-ui - see the note in the
  # milestone-1 version of this file; xenia-ui excludes *_ios.* by glob and
  # .mm sources need explicit listing everywhere.
  "${_xe_root}/src/xenia/ui/surface_ios.mm"
)

target_include_directories(xenra-ios PRIVATE
  "${_xe_ios_dir}/src"
  "${_xe_root}/src"
  "${_xe_root}"
)

# The engine, in the same shape the Android `emu` library links it (see
# emulator-core/src/main/cpp/CMakeLists.txt), minus everything Android-only:
# no Vulkan (XE_ENABLE_VULKAN is FALSE on iOS, Metal is the backend), no
# adrenotools, no OpenSLES/AAudio (nop audio for now), no Discord RPC.
set(_xe_ios_engine_libs
  xenia-apu
  xenia-apu-nop
  xenia-base
  xenia-core
  xenia-cpu
  xenia-cpu-backend-a64
  xenia-gpu
  xenia-gpu-metal
  xenia-gpu-null
  xenia-hid
  xenia-hid-nop
  xenia-kernel
  xenia-ui
  xenia-ui-metal
  xenia-vfs
  xenia-patcher
)
foreach(_lib IN LISTS _xe_ios_engine_libs)
  target_link_libraries(xenra-ios PRIVATE ${_lib})
endforeach()

# Third-party statics the engine targets do not carry PUBLICly but the final
# binary needs (same list the Android `emu` target closes over).
target_link_libraries(xenra-ios PRIVATE
  aes_128
  capstone
  fmt
  dxbc
  glslang-spirv
  imgui
  libavcodec
  libavutil
  libavformat
  mspack
  snappy
  xxhash
  pugixml
  spirv-cross
  libminiupnpc-static
  z
)

target_link_libraries(xenra-ios PRIVATE
  "-framework UIKit"
  "-framework Metal"
  "-framework MetalKit"
  "-framework MetalFX"
  "-framework QuartzCore"
  "-framework Foundation"
  "-framework CoreGraphics"
  "-framework GameController"
  "-framework AudioToolbox"
  "-framework AVFoundation"
  "-framework CoreMedia"
  "-framework Security"
  "-framework CoreVideo"
  "-framework CoreHaptics"
  "-framework CoreBluetooth"
  z
  "-lz"
)

# ARC is off across the xenia tree (metal-cpp does its own retain/release and
# the .mm files here are written for manual management). Keeping the app
# consistent with that avoids a per-file exception and the ownership confusion
# that comes with mixing the two in one binary.
target_compile_options(xenra-ios PRIVATE
  "$<$<COMPILE_LANGUAGE:OBJC,OBJCXX>:-fno-objc-arc>"
)

# The xenia tree sets CMAKE_OBJCXX_STANDARD 20 inside its own project() scope,
# and a set() in a subdirectory does not reach a sibling one - so this target
# was compiling the very same xenia headers under the compiler's default
# dialect. Set it on the target so it cannot drift from whatever the xenia
# subdirectory decides.
set_target_properties(xenra-ios PROPERTIES
  CXX_STANDARD 20
  CXX_STANDARD_REQUIRED ON
  OBJCXX_STANDARD 20
  OBJCXX_STANDARD_REQUIRED ON
)

set_target_properties(xenra-ios PROPERTIES
  MACOSX_BUNDLE_INFO_PLIST "${_xe_ios_dir}/Info.plist"
  XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "Ali.Xanite.green.ios"
  # A device build only. The simulator has no JIT story worth testing and no
  # real GPU, which are the two things this app exists to measure.
  XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
  XCODE_ATTRIBUTE_ENABLE_BITCODE "NO"
)
