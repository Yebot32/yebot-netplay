# Building Xenra for iOS

Milestone 2. This builds **the full emulator**: the a64 CPU backend, the Metal
GPU backend, the kernel, and an iOS shell (`ios/src/ios_emu.mm`) that boots a
title from the library screen and presents through a CAMetalLayer. The
milestone-1 pipeline check lives on as the library screen's status readout.

Nothing here affects the Android build. `XenDroid/ios/`, `XenDroid/cmake/` and
this workflow are unreachable from Gradle: the Android native build
(`XenDroid/emulator-core/src/main/cpp/CMakeLists.txt`) lists every source
explicitly and globs nothing.

---

## JIT on iOS 26+: the universal (TXM/SPTM) protocol - READ THIS FIRST

The story the probe told in milestone 1 ("mprotect reported success but the
page faulted on execute", forever, even after re-test #7) is now explained
and fixed. Source: StikDebug/StikJIT INTEGRATION.md ("Part 1: Add iOS 26 JIT
support").

On devices where TXM/SPTM is present (iOS 26+ on supported hardware), **a
debugger attach alone no longer makes generated code executable**. Every
region that will hold generated code must be PREPARED through the debug
connection by the JIT enabler's script (StikDebug universal.js), via a
breakpoint handshake:

```c
// x16=1: prepare. x0 = address, x1 = length, returns prepared address in x0.
void* JIT26PrepareRegion(void* address, size_t length);
// x16=0: detach. Called once, after ALL regions are prepared.
void JIT26Detach(void);
// Both: mov x16, #N; brk #0xf00d; ret
```

That is why mprotect "succeeded" and execute faulted: the W^X permission
change goes through, but the code signing monitor still refuses to execute a
region the enabler never prepared. XeniOS works on the same device because
its JIT allocator implements the protocol; Xenra now does too.

What Xenra implements (`base/memory.cc`, iOS section):

- `Jit26PrepareRegion` / `Jit26Detach` - the naked brk handshakes, each
  wrapped in a SIGTRAP guard so an un-attached brk is reported, not fatal.
- `QueryJitSignatureState` - raw csops flags for the status screen
  (get-task-allow / cs_debugged), so a "no" says WHICH precondition failed.
- The probe runs the protocol after the plain W^X path faults (attach gate:
  never brks before CS_DEBUGGED). It deliberately does NOT detach - the
  emulator's own regions still need preparing at boot.
- The code cache (`code_cache_base.h`) prepares its whole execute
  reservation (one call covers every page it will ever commit), and the a64
  backend's guest trampoline region is prepared likewise - on iOS it is
  split into an execute view + a writable alias so lazily-built trampolines
  can still be written after the detach.
- The boot path detaches once, after `Emulator::SetupSubsystems()`.

**What the user must do (per launch of the emulator):**

1. Sign/install with a signature that has `get-task-allow` (eSign with its
   JIT option, or SideStore/StikStore). Without it the screen says so and
   stops - iOS would kill the process at the first execute.
2. LocalDevVPN connected, pairing file imported, DDI mounted (the standard
   StikDebug ritual; mount survives until reboot).
3. Launch Xenra, tap **Enable JIT via StikDebug** - the handoff URL opens
   StikDebug with `bundle-id=Ali.Xanite.green.ios`, the current `pid`, and
   `script-name=universal.js` (always on iOS 26+; the script is fixed in
   code, never a user setting).
4. In StikDebug, run Enable JIT for the app with the universal script. Then
   return to Xenra: the library screen flips to JIT ON (the 2 s re-probe
   catches the attach; the probe runs the protocol and stops the timer),
   and games boot.

The old "expected answers per install method" table still holds, with one
new row: development-signed + attached + universal script prepared the
region -> **ON** ("universal protocol: region prepared..."). Attached but no
script answering the brk -> OFF with a message saying exactly that.

---

## Layout

| Path | What it is |
| --- | --- |
| `XenDroid/cmake/ios.toolchain.cmake` | CMake toolchain, iOS arm64 device only |
| `XenDroid/CMakeLists.txt` | iOS entry point: xenia tree + miniupnpc + the app |
| `XenDroid/ios/CMakeLists.txt` | The `xenra-ios` app target (full engine link) |
| `XenDroid/ios/Info.plist` | Bundle metadata (file sharing, stikdebug scheme) |
| `XenDroid/ios/xenra.entitlements` | Input to `codesign --entitlements` |
| `XenDroid/ios/src/ios_emu.mm` | The native driver: context, window, boot thread, virtual pad |
| `XenDroid/ios/src/XenraAppDelegate.mm` | Library screen, JIT gate, game screen |
| `XenDroid/ios/system_ios.mm` | iOS replacement for `base/system_mac.cc` |
| `XenDroid/.github/workflows/xenra-ios.yml` | CI (two-stage: native shader tool, then iOS cross) |

`XenDroid/ios` is a **subdirectory** of the xenia CMake project, not a project
of its own — it defines `xenra-ios` and links the engine libraries. The CMake
source root is this repo's root.

### The Metal shader pipeline (two-stage CI)

Every built-in Metal shader is `.slang`, generated by `xenia-shader-cc
--slang-msl`: slangc emits `.metal` source, then `xcrun metal`/`metallib`
package it. Two consequences:

1. The tool must run on the BUILD machine even though the target is iOS - the
   CI builds xenia-shader-cc natively (macOS) in a first pass and the iOS
   configure picks it up via `XE_FORCE_HOST_SHADER_CC` +
   `XE_HOST_SHADER_CC_PATH`.
2. The metallib must target iOS. macOS AIR is rejected by the on-device
   loader, so the MSL invocations read `XE_METAL_TARGET_SDK` (and
   `XE_METAL_MIN_VERSION`) from the environment and emit `-sdk iphoneos`,
   `-std=ios-metal2.3`, `-mios-version-min=16.0` when it says `iphoneos`.
   Unset environment keeps the historical macOS behaviour byte-for-byte.

---

## Running it in CI

The workflow is `xenra-ios`. It runs on push/PR to `main` when iOS plumbing or
`src/xenia/base` changes, and is manually triggerable from the Actions tab
(**Run workflow**).

It always uploads `xenra-ios-unsigned-<sha>.ipa`. If the signing secrets are
configured it additionally uploads `xenra-ios-signed-<sha>.ipa`. **Missing
signing secrets never fail the build** — unsigned is the default and the
supported path.

Optional secrets:

| Secret | Meaning |
| --- | --- |
| `IOS_CERT_P12` | base64 of a `.p12` containing the signing certificate + private key |
| `IOS_CERT_PASSWORD` | password for that `.p12` |
| `IOS_PROVISIONING_PROFILE` | base64 of a `.mobileprovision` |
| `IOS_SIGNING_IDENTITY` | optional; identity name. Falls back to the first codesigning identity in the imported keychain |

### Cost

macOS runners bill at **10x** the Linux rate against private-repo minutes, and
`Yebot32/xenra...` is private. That is why the workflow has a `paths` filter, a
single arch, no matrix, and `-DXENIA_ENABLE_LTO=OFF`. If the minutes start to
hurt, delete the `push:` trigger and leave it on `workflow_dispatch` — nothing
else depends on it running automatically.

---

## Building locally on a Mac

You need **Xcode**, not just the Command Line Tools. CLT ships no iOS SDK, and
the toolchain file will tell you so at configure time.

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
brew install ninja

cd <repo>
cmake -G Ninja \
  -S XenDroid/emulator-core/src/main/cpp/xenia \
  -B build-ios \
  -DCMAKE_TOOLCHAIN_FILE="$PWD/XenDroid/cmake/ios.toolchain.cmake" \
  -DCMAKE_BUILD_TYPE=Release \
  -DXENIA_BUILD_TESTS=OFF -DXENIA_BUILD_MISC=OFF -DXENIA_ENABLE_LTO=OFF

cmake --build build-ios --target xenra-ios
```

Build **only** the `xenra-ios` target. The xenia root declares `xenia-app`, the
Vulkan backend, wxWidgets and much else; none of that links on iOS yet and none
of it is needed here.

To package by hand:

```sh
APP=$(find build-ios -maxdepth 5 -name 'xenra-ios.app' -type d | head -n 1)
rm -rf Payload && mkdir Payload && cp -R "$APP" Payload/
zip -qry xenra-ios.ipa Payload
```

The `Payload/` directory name is not a convention, it is a requirement.
Top-level, spelled exactly that way, with the `.app` as a direct child.

### Why iOS 16.0

`CMAKE_OSX_DEPLOYMENT_TARGET` is pinned to 16.0 in the toolchain file:

1. **MetalFX** (`-framework MetalFX`, linked by `src/xenia/ui/metal`) is iOS
   16.0+. Going lower means a runtime availability fork in milestone 2 for
   devices we do not intend to support.
2. `com.apple.developer.kernel.increased-memory-limit` only does anything from
   iOS 15, and pairs sanely with extended virtual addressing from 16 on A12+.
3. iOS 16 drops A9/A10. Those were never going to run a 360 emulator.

It is set as a `CACHE` entry deliberately —
`<XEN>/CMakeLists.txt:5-8` claims the same cache slot with `"15.0"` before
`project()`, and a plain variable would lose to it silently.

---

## Installing on a device from Windows

The CI artifact is unsigned. iOS will not install an unsigned app, so you sign
it yourself.

[**Sideloadly**](https://sideloadly.io/) is the usual tool. Download the
unsigned `.ipa` from the Actions run, plug the device in over USB (with iTunes
/ Apple Devices installed so Windows has the drivers), sign in with an Apple
ID, and install.

A free Apple ID gets you a 7-day certificate and a 3-app limit; a paid Apple
Developer account gets a year. Both are *development* certificates, which is
the part that matters — see below.

---

## JIT, `get-task-allow`, and why the signature is load-bearing

**Read this before concluding the JIT probe is broken.**

Xenia has no PowerPC interpreter. If `base/memory.cc`'s probe reports no JIT,
nothing further works — and on iOS the most common cause is the *signature*,
not the code.

The mechanics:

* On iOS, `mmap` with `MAP_JIT` giving you memory you can actually execute
  requires the process to be **debuggable**. Debuggability comes from the
  `com.apple.security.get-task-allow` entitlement being present in the app's
  code signature.
* `get-task-allow` is granted by the *signing flow*, not by our entitlements
  file. A **development**-signed app has it. An **ad-hoc** signature
  (`codesign -s -`) or a **distribution** signature does **not**, and a
  distribution signature actively strips it. So: an ad-hoc or App Store style
  signature will **not** enable JIT, no matter what else is configured.
* On iOS 14+ the entitlement alone is not sufficient at runtime either — a
  debugger has to attach at least once per launch to flip the process into the
  debuggable state. That is what tools like AltStore/SideStore's JIT enabler,
  StikDebug, or `debugserver` over USB are doing. This is a launch-time ritual,
  not a build-time setting.
* Apple has been tightening this. Reports from iOS 18.4 onward describe JIT for
  ordinary sideloaded apps being restricted further via private entitlements.
  Treat "JIT works on the current iOS release" as something to re-verify per
  release, not as a settled property.

### Does Sideloadly set/preserve `get-task-allow`?

**Honest answer: not authoritatively confirmed.** Sideloadly does not publish a
specification of the entitlements it writes, and I could not verify this from
primary documentation.

What is well-established in the sideloading community is the *mechanism*:
Sideloadly re-signs with a **development** certificate obtained from your Apple
ID, and development-signed apps carry `get-task-allow`. The JIT-enabler
ecosystem (SideStore, StikDebug) documents that an app must have been sideloaded
with `get-task-allow` in order to appear in their JIT activation list, and
treats Sideloadly-installed apps as a normal source for that. So the practical
expectation is yes — but do not take that as a guarantee, and do not design
around it.

**Verify it, do not assume it.** After installing, the signature is the only
authority:

```sh
# on a Mac, against the .app you are about to install
codesign -d --entitlements :- Payload/xenra-ios.app
```

Look for `com.apple.security.get-task-allow` = `true`. The CI signing step
prints exactly this, and also dumps the provisioning profile's entitlements
before signing. If the key is absent there, it will be absent on device.

### MEASURED on hardware: iPad Air M1, iPadOS 26.4.2 (2026-08-28)

The first on-device run, installed with eSign under a distribution-style
certificate:

- Install, home screen, launch: all fine. `MTLCreateSystemDefaultDevice()`
  succeeded before anything died.
- The process was killed ~70 ms after launch, before the first frame. The
  crash report: `EXC_BAD_ACCESS (SIGKILL)`, termination
  `CODESIGNING / "Invalid Page"`, faulting an `rw-/rwx` anonymous mapping -
  the probe's own step-1 RWX mapping, at the moment of its first execute.
- `codeSigningFlags` in the report have no `CS_GET_TASK_ALLOW` bit. The
  kernel was not guessing; it knew.

Why the signal guard did not save it: `CallProbeGuarded` catches SIGBUS,
SIGSEGV and SIGILL. The code signing monitor raises none of those for an
unentitled execute - it sends SIGKILL, which nothing in the process can
catch. The probe was engineered for the wrong killer.

`QueryJitStatus` therefore now asks the kernel first (`csops(CS_OPS_STATUS)`)
before mapping anything executable:

- **No `get-task-allow`** (eSign, enterprise and other distribution-style
  signing): reports `OFF` - "signature has no get-task-allow ... Re-sign with
  a development provisioning profile to test JIT." No executable mapping is
  attempted, so the status screen now renders on any signature.
- **`get-task-allow` present, no `CS_DEBUGGED`** (development-signed, JIT not
  yet activated this launch): the RWX attempt is skipped and the W^X path's
  `mprotect` refusal is the clean "no" it was always designed to be.
- **`CS_DEBUGGED` set** (a JIT enabler has attached this launch): both paths
  run, and ON is finally measurable.

Expected answers per install method: distribution signing → OFF (no
entitlement). Development-signed, no enabler → OFF (mprotect refusal).
Development-signed + SideStore/StikDebug activation → the real answer. The
third row is the one milestone 1 exists for.

### MEASURED, second run: eSign with JIT enabled, same device (2026-08-28)

The same `d4e0cec` build, reinstalled through eSign with its JIT option on,
changed the picture in three ways:

- The signature now carries `get-task-allow` - the csops gate passes. Whatever
  eSign's JIT mode signs with, it is not the distribution-style certificate of
  the first run.
- The W^X path ran, and `mprotect` to `PROT_EXEC` **succeeded** - where the
  note above predicts a refusal. The fault came one step later, at the first
  execute, and it was a catchable SIGSEGV that `CallProbeGuarded` handled: the
  screen read "mprotect reported success but the page faulted on execute". On
  26.4.2 the refusal has moved from the mprotect call to the instruction
  fetch. The correction stands: the probe must not execute unless the kernel
  says the signature is debuggable, because the failure mode is still a kill
  when the signature is not.
- What was missing at +70 ms was the attach itself (`CS_DEBUGGED`). The JIT
  enabler lands seconds after launch. XeniOS runs on this same device and
  signature because its first JIT need is at game start, minutes in - Xenra's
  probe lost a race, it did not find a missing capability.

`QueryJitStatusRefresh()` exists for exactly this, and the pipeline-check
screen now re-probes (2 s timer, tap to force). Expected readings: before the
enabler attaches - "mprotect reported success but the page faulted on
execute"; after it attaches - "W^X: page flipped from writable to executable
via mprotect". The emulator's own backend init must use the refresh variant
too, never the cached snapshot.

### What is *not* the answer

`<XEN>/xenia.entitlements` contains `com.apple.security.cs.allow-jit`. **That is
a macOS file.** The `cs.` prefix is macOS Hardened Runtime, which does not exist
on iOS. `com.apple.security.cs.allow-jit` does nothing on iOS — it is not
"harmless documentation", it is an active red herring that will send you looking
for the problem in the wrong place. Do not copy that file.

`XenDroid/ios/xenra.entitlements` is the iOS one. It carries only:

* `com.apple.developer.kernel.increased-memory-limit`
* `com.apple.developer.kernel.extended-virtual-addressing`

Both are **restricted** entitlements: they take effect only if Apple issued a
provisioning profile granting them to your team. Without that they are silently
ignored — installation still succeeds and the app just gets the default limits.
A successful install is not evidence that either is active; measure at runtime.

`get-task-allow` is deliberately **not** listed in that file, because it is not
ours to grant and listing it would create a false impression that it is handled.

---

## Existing files that still need editing

Milestone 1 does not build until these land. Each is a change to a file that
already exists.

1. **`<XEN>/CMakeLists.txt`** — add the app subdirectory at the end, next to
   `add_subdirectory(src/xenia)`:
   ```cmake
   if(IOS)
     add_subdirectory(${PROJECT_SOURCE_DIR}/../../../../../ios xenra-ios)
   endif()
   ```
   Without this there is no `xenra-ios` target and the CI `--target xenra-ios`
   fails immediately.

2. **`<XEN>/src/xenia/base/CMakeLists.txt`** — on iOS, drop `system_mac.cc` and
   add `XenDroid/ios/system_ios.mm` in its place. `system_mac.cc` calls
   `system()` for `open <url>` and `osascript`; `system()` is
   `__API_UNAVAILABLE(ios)`, so this is a hard compile error, not a runtime
   stub. It is the only `base` source that genuinely cannot cross.

3. **`<XEN>/src/xenia/ui/CMakeLists.txt:44-53`** — the `elseif(APPLE)` block
   adds `surface_mac.mm` + `windowed_app_wx_mac.mm` and links
   `-framework Cocoa`. AppKit/Cocoa do not exist on iOS. Needs to become
   `if(IOS) ... elseif(APPLE) ...`, with the iOS arm taking `surface_ios.mm`
   and `-framework UIKit`. Also relevant: the `if(NOT CMAKE_SYSTEM_NAME STREQUAL
   "Android")` guard at `:33-35` links `xe-wxWidgets` — that needs to exclude
   iOS too.

4. **`<XEN>/src/xenia/ui/metal/CMakeLists.txt:21`** — `-framework AppKit` must
   become `-framework UIKit` on iOS. (Milestone 2, but it is the same edit
   pass.)

5. **`<XEN>/cmake/XeniaHelpers.cmake:5-7`** — add `_ios` to
   `XE_PLATFORM_SUFFIXES`. Without it, any future `*_ios.h` / `*_ios.cc` is
   globbed into **every** platform's build, including Android.
   `src/xenia/ui/surface_ios.h` already exists and is being picked up by the
   Android build today. It is header-only so nothing has broken, but this is a
   live latent bug.

6. **`<XEN>/cmake/XeniaHelpers.cmake:276` and `:346`** — the
   `if(NOT APPLE) return()` guards on the MSL shader rules. `APPLE` is true on
   iOS, so these fire, and they run `xenia-shader-cc` with macOS SDK flags.
   Milestone 2 concern; see the next item.

7. **`<XEN>/tools/build/shader_cc.cc`** (~482-488, 518, 786-788, 796) — the
   Metal invocations hardcode `-sdk macosx`, `-std=macos-metal2.3` and
   `-mmacosx-version-min=`. For iOS these must be `iphoneos`,
   `ios-metal2.3` and `-mios-version-min=`. Milestone 2. Note that
   `xenia-shader-cc` is a **host** tool that runs on the build machine while
   producing **target** shaders, so the switch has to be driven by the target
   platform, not by whether the host is a Mac.

Deliberately **not** an edit: `<XEN>/CMakeLists.txt:49-61`'s FATAL_ERROR on
multi-arch `CMAKE_OSX_ARCHITECTURES`. The iOS toolchain sets a **single** arch
(`arm64`), so it does not trip, and the branch correctly sets
`XE_TARGET_AARCH64`.

---

## Known unknowns

Written on Windows with no Mac and no Xcode. Nothing below has been executed.

* **The whole configure has never been run for iOS.** The biggest single risk
  is `<XEN>/CMakeLists.txt`'s unconditional `add_subdirectory(third_party)`,
  which configures SDL3, wxWidgets, MoltenVK, glslang, SPIRV-Tools and FFmpeg.
  Building only `xenra-ios` keeps them out of the *build*, but they still get
  *configured*, and none has been tried against an iOS toolchain in this tree.
  If configure fails there, the fix is to gate those blocks on `NOT IOS` rather
  than to fight them — and if it turns into a swamp, the alternative is to give
  `XenDroid/ios` its own top-level project that pulls in only `xenia-base` and
  its two real dependencies (`fmt`, `boost_context`), skipping `third_party`
  entirely. `embedded_bundle.cc` is the only `base` source that needs zlib-ng.
* Which `base` sources beyond `system_mac.cc` the iOS SDK rejects. `xenia-base`
  compiles with `-Werror` (`xe_target_defaults`), so warnings are errors. The
  audit was static: `debugging_mac.cc` (sysctl) and `autorelease_pool_mac.cc`
  (Foundation) look clean, but "looks clean" is not "compiles".
* Whether Sideloadly sets `get-task-allow` — see above. Stated as unverified on
  purpose.
* Whether the restricted memory entitlements are granted for this team.
* Whether `Xcode_16.app` exists on the `macos-15` image under that exact path.
  The workflow warns and falls back rather than failing if it does not.

Sources for the JIT/entitlement claims:
[SideStore docs — Enabling JIT](https://docs.sidestore.io/docs/advanced/jit),
[StikDebug JIT guide](https://silisko.com/stikdebug-jit-ios-26-guide/),
[iDownloadBlog — iOS 18.4 and JIT in sideloaded apps](https://www.idownloadblog.com/2025/02/23/ios-18-4-jit-blocked-by-apple/),
[Apple Developer Forums — persistent get-task-allow after signing](https://developer.apple.com/forums/thread/776923).
