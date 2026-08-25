# CMake toolchain: iOS arm64, device only.
#
# Deliberately hand-written and small. The popular third-party
# leetal/ios-cmake toolchain is ~1000 lines that exists to cover simulator,
# tvOS/watchOS/visionOS, Catalyst, universal slices, bitcode and Xcode-generator
# bundle plumbing. We need exactly one of those combinations, and a file this
# size is one you can actually read when a configure fails at 2am. If we ever
# need the matrix, swap this out then - not pre-emptively.
#
# WHAT THIS DELIBERATELY DOES NOT HANDLE:
#   * Simulator (iphonesimulator SDK, x86_64/arm64-sim). The whole point of the
#     iOS port is the arm64 JIT; the simulator runs x86_64-on-Intel or
#     arm64-with-no-MAP_JIT-semantics, so it cannot prove anything we care
#     about. Adding it later means a second sysroot + a CMAKE_OSX_SYSROOT
#     switch, nothing structural.
#   * Mac Catalyst. Different platform triple entirely; xenia already has a
#     real macOS build, so Catalyst buys nothing.
#   * Bitcode. Deprecated since Xcode 14 and removed in Xcode 16. Not coming
#     back.
#   * Universal / multi-arch. <XEN>/CMakeLists.txt FATAL_ERRORs on a
#     CMAKE_OSX_ARCHITECTURES list longer than one entry, because the CPU
#     backend is picked once at configure time. arm64 alone is correct here and
#     does NOT trip that check.
#
# Usage:
#   cmake -G Ninja -S XenDroid/ios -B build-ios \
#         -DCMAKE_TOOLCHAIN_FILE=XenDroid/cmake/ios.toolchain.cmake

# A toolchain file is re-read for every try_compile(); guard the expensive bits.
if(XENRA_IOS_TOOLCHAIN_INCLUDED)
  return()
endif()
set(XENRA_IOS_TOOLCHAIN_INCLUDED TRUE)

set(CMAKE_SYSTEM_NAME iOS)

# Belt and braces. CMAKE_OSX_ARCHITECTURES is what <XEN>/CMakeLists.txt:49-61
# reads to set XE_TARGET_AARCH64, but plenty of third_party CMakeLists sniff
# CMAKE_SYSTEM_PROCESSOR instead, so set both to the same answer.
set(CMAKE_SYSTEM_PROCESSOR arm64)
set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "iOS device arch" FORCE)

# Deployment target: iOS 16.0.
#
# Three reasons, in order of how much they bind us:
#   1. MetalFX. <XEN>/src/xenia/ui/metal/CMakeLists.txt links -framework
#      MetalFX for the upscaler. MetalFX is iOS 16.0+. Anything lower and the
#      renderer work in milestone 2 has to grow a runtime availability fork for
#      devices we do not intend to support anyway.
#   2. com.apple.developer.kernel.increased-memory-limit only does anything
#      from iOS 15, and the extended-virtual-addressing pairing that the guest
#      address space needs is only well-behaved from 16 on A12+.
#   3. Device floor. iOS 16 drops the A9/A10 devices, which is fine - they were
#      never going to run a 360 emulator, and every iOS 16 device is A12+ with
#      the 4GB+ of RAM the guest heap wants.
#
# MUST be a CACHE entry, not a plain variable. <XEN>/CMakeLists.txt:5-8 runs
# `set(CMAKE_OSX_DEPLOYMENT_TARGET "15.0" CACHE STRING ...)` before project().
# A non-FORCE set(CACHE) is a no-op if the cache entry already exists, so
# claiming the cache slot here is what makes 16.0 stick; setting a normal
# variable would get dropped on the floor by CMP0126's OLD behaviour and we
# would silently build against 15.0 with a MetalFX link error much later.
set(CMAKE_OSX_DEPLOYMENT_TARGET "16.0" CACHE STRING "Minimum iOS version" FORCE)

# Sysroot. Resolve the concrete path rather than leaving the string "iphoneos":
# the Ninja generator does not expand SDK aliases the way the Xcode generator
# does, and a bare alias shows up later as a mountain of "file not found" on
# system headers.
if(NOT DEFINED CMAKE_OSX_SYSROOT)
  execute_process(
    COMMAND xcrun --sdk iphoneos --show-sdk-path
    OUTPUT_VARIABLE _xenra_ios_sysroot
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
    RESULT_VARIABLE _xenra_ios_sysroot_result)
  if(NOT _xenra_ios_sysroot_result EQUAL 0 OR NOT _xenra_ios_sysroot)
    message(FATAL_ERROR
      "Could not locate the iphoneos SDK.\n"
      "  `xcrun --sdk iphoneos --show-sdk-path` failed.\n"
      "  Install Xcode (not just the Command Line Tools - CLT has no iOS SDK)\n"
      "  and point xcode-select at it:\n"
      "    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer")
  endif()
  set(CMAKE_OSX_SYSROOT "${_xenra_ios_sysroot}" CACHE PATH "iOS device SDK" FORCE)
endif()

# try_compile() on iOS: link an executable and the toolchain wants a valid
# signing identity and a bundle, which CI does not have when producing an
# unsigned build. Restricting compiler-id / feature probes to static libraries
# makes them stop at the archive step, which is all a probe actually needs.
# This is the standard workaround for every cross-compile-to-Apple setup.
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

# Find-root behaviour. Programs must come from the HOST (we run xcrun, metal,
# python3, ninja - all host binaries). Libraries, headers and packages must
# come from the SDK ONLY, or CMake will happily hand an arm64-macOS .dylib from
# /opt/homebrew to an iOS link and the error you get names a missing symbol
# rather than the wrong architecture.
set(CMAKE_FIND_ROOT_PATH "${CMAKE_OSX_SYSROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM BOTH)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# Signing is a packaging concern, not a build concern. CI produces an UNSIGNED
# .app and either signs it in a later step (when secrets exist) or ships it
# unsigned for the user to sign with their own certificate. Forcing empty
# identity + no automatic signing here keeps `cmake --build` from failing on a
# machine with no keychain, which is exactly the state of a fresh runner.
# See XenDroid/docs/ios-build.md for why the signature is load-bearing for JIT.
set(CMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO)
set(CMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED NO)
set(CMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY "")
