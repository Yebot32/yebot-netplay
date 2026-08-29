# =============================================================================
# Xenra - iOS entry point
# =============================================================================
# This file exists ONLY for the iOS build. Android does not use it and cannot
# reach it: Gradle's externalNativeBuild points directly at
# emulator-core/src/main/cpp/CMakeLists.txt, so a CMakeLists at the repository
# root is inert for the APK. Keeping the two entry points separate is the whole
# reason the iOS work cannot regress the Android build by accident.
#
# Configure with the toolchain in cmake/ios.toolchain.cmake; see
# docs/ios-build.md for the CI and local invocations.

cmake_minimum_required(VERSION 3.20)

# Cheap pre-check on the one thing that IS knowable this early. A toolchain
# file is only read during project(), so CMAKE_SYSTEM_NAME is still empty here
# - testing it before project() is a guard that can never pass, which is
# exactly the mistake this replaced.
if(NOT CMAKE_TOOLCHAIN_FILE)
  message(FATAL_ERROR
    "This CMakeLists is the iOS entry point and needs the iOS toolchain:
"
    "  -DCMAKE_TOOLCHAIN_FILE=cmake/ios.toolchain.cmake
"
    "For Android, build the APK with Gradle, which uses "
    "emulator-core/src/main/cpp/CMakeLists.txt and never reads this file.")
endif()

project(xenra-ios-shell LANGUAGES C CXX OBJC OBJCXX)

# The authoritative check, now that the toolchain has actually been processed.
if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
  message(FATAL_ERROR
    "Expected CMAKE_SYSTEM_NAME=iOS after project(), got "
    "'${CMAKE_SYSTEM_NAME}'. The toolchain file at ${CMAKE_TOOLCHAIN_FILE} is "
    "not the iOS one.")
endif()

# EXCLUDE_FROM_ALL so `--build . --target xenra-ios` pulls in only what the app
# actually needs. The xenia tree defines a great many targets that have no
# meaning on iOS, and configuring them is cheap only as long as nothing tries
# to build them.
#
# The fork's own overrides gate on XE_PLATFORM_xendroid (defined for Android in
# base/platform.h). iOS is the same fork: the a64 unwind bump buffer in
# a64_code_cache_posix.cc, the fixed guest-memory window in memory.cc and the
# kernel/xam forks all take that path - the non-xendroid branches have never
# compiled anywhere. Define it before the xenia tree is added.
add_compile_definitions(XE_PLATFORM_xendroid=1)
add_subdirectory(emulator-core/src/main/cpp/xenia EXCLUDE_FROM_ALL)

# -----------------------------------------------------------------------------
# xenia-base source fixup for iOS
# -----------------------------------------------------------------------------
# xe_platform_sources() globs *_posix.* + *_mac.* for any APPLE target, and one
# of those files does not compile for iOS: base/system_mac.cc implements
# LaunchWebBrowser and ShowSimpleMessageBox by shelling out through system(),
# which the iOS SDK marks __API_UNAVAILABLE(ios) - a compile error, not a
# runtime stub - and by driving osascript, which has never existed on iOS.
#
# The other two Mac files are fine unchanged: autorelease_pool_mac.cc is plain
# Foundation, and debugging_mac.cc's sysctl is-debugger-attached probe works on
# iOS (and is directly interesting there, since the debugger being attached is
# exactly what grants JIT).
#
# Swapped here rather than by teaching XeniaHelpers.cmake an `_ios` suffix, so
# the vendored xenia tree stays byte-identical to upstream and keeps merging
# cleanly - the same reason the Android platform layer lives outside it. This
# whole block is unreachable from the Android build, which never parses this
# file.
get_target_property(_xe_base_srcs xenia-base SOURCES)
set(_xe_base_mac_system
    "${CMAKE_CURRENT_SOURCE_DIR}/emulator-core/src/main/cpp/xenia/src/xenia/base/system_mac.cc")
if(NOT _xe_base_mac_system IN_LIST _xe_base_srcs)
  message(FATAL_ERROR
    "iOS: expected to replace base/system_mac.cc in xenia-base but it is not "
    "in the source list. The glob in cmake/XeniaHelpers.cmake has changed - "
    "re-check what *_mac.* files iOS now inherits before building.")
endif()
list(REMOVE_ITEM _xe_base_srcs "${_xe_base_mac_system}")
list(APPEND _xe_base_srcs "${CMAKE_CURRENT_SOURCE_DIR}/ios/system_ios.mm")
set_target_properties(xenia-base PROPERTIES SOURCES "${_xe_base_srcs}")

# -----------------------------------------------------------------------------
# miniupnpc + the netplay kernel sources, wired from HERE exactly as the
# Android outer build does (emulator-core/src/main/cpp/CMakeLists.txt), so the
# vendored xenia tree stays byte-identical to upstream and keeps merging
# cleanly. Static only; the samples pull in a main().
# -----------------------------------------------------------------------------
set(UPNPC_BUILD_SHARED OFF CACHE BOOL "" FORCE)
set(UPNPC_BUILD_STATIC ON  CACHE BOOL "" FORCE)
set(UPNPC_BUILD_TESTS  OFF CACHE BOOL "" FORCE)
set(UPNPC_BUILD_SAMPLE OFF CACHE BOOL "" FORCE)
add_subdirectory(emulator-core/src/main/cpp/xenia/third_party/miniupnpc EXCLUDE_FROM_ALL)

target_include_directories(xenia-kernel PRIVATE
    emulator-core/src/main/cpp/xenia/third_party/miniupnpc/include
)
target_link_libraries(xenia-kernel PRIVATE libminiupnpc-static)
target_sources(xenia-kernel PRIVATE
    emulator-core/src/main/cpp/xenia/src/xenia/kernel/upnp.cc
    emulator-core/src/main/cpp/xenia/src/xenia/kernel/util/net_utils.cc
    emulator-core/src/main/cpp/xenia/src/xenia/kernel/util/network_adapter_manager.cc
)

add_subdirectory(ios)
