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

if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
  message(FATAL_ERROR
    "This CMakeLists is the iOS entry point. Configure it with "
    "-DCMAKE_TOOLCHAIN_FILE=cmake/ios.toolchain.cmake. For Android, build the "
    "APK with Gradle, which uses emulator-core/src/main/cpp/CMakeLists.txt.")
endif()

project(xenra-ios-shell LANGUAGES C CXX OBJC OBJCXX)

# EXCLUDE_FROM_ALL so `--build . --target xenra-ios` pulls in only what the app
# actually needs. The xenia tree defines a great many targets that have no
# meaning on iOS, and configuring them is cheap only as long as nothing tries
# to build them.
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

add_subdirectory(ios)
