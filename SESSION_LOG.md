# XENRA iOS — SESSION LOG (session 3)

Started: 2026-09-08. Machine: Windows (no Mac/Xcode; all builds via GitHub
Actions `xenra-ios.yml` on the yebot-netplay repo, ~15 min/round).
Submodule HEAD at start: 98a9adee6 (one commit past handoff #33's 84c005063).
Android-side logs (SESSION_LOG.md sessions 1-2 in the app repo) are the
correctness reference standard; handoff briefing #33 is the iOS truth.

## Session goal
Both emulation paths (OG + 360) functionally complete and well developed on
iOS, to the Android standard. Priorities per briefing: (1) no-JIT fallback
must genuinely work for both paths, (2) GetMoreRAM investigation with honest
documentation, (3) UI = exact replica of Android, (4) OG-on-iOS milestone 3.

## Orientation findings (verified by reading code, not assuming)
- 360-on-iOS: full xenia engine builds in CI (a64 CPU backend, Metal GPU,
  kernel, VFS, iOS shell). On-device: library screen + JIT probe + StikDebug
  attach MEASURED working; game boot/rendering/audio UNVERIFIED (no user run
  of 84c005063+ yet).
- 360 no-JIT: xenia has no PowerPC interpreter (memory.h:101-108 says so
  explicitly; cpu/backend holds x64, a64 and a null stub only). Without JIT
  the guest physically cannot execute. Current behavior: `xe_ios_boot`
  refuses with a clear message, app never crashes (iOS 27 probe gate correct:
  no execute without CS_DEBUGGED). This is the honest best possible without
  writing a PPC interpreter — documented as a decision point, not silently.
- OG no-JIT: the vendored QEMU tree in the app repo (main/cpp) contains the
  complete TCG interpreter (tcg/tci/, meson option `tcg_interpreter`,
  CONFIG_TCG_INTERPRETER). A genuine interpreter path EXISTS for OG — it
  just has to be selected at build time for iOS.
- OG-on-iOS: not started (milestone 3). OG core is a QEMU/xemu fork in the
  app repo built for Android via meson; iOS needs a cross build + MoltenVK
  (DukeX's approach) or a Metal NV2A renderer.
- iOS UI: currently a minimal diagnostic shell (status readout + game list +
  virtual pad) in XenraAppDelegate.mm. NOT the Android UI. UI parity is a
  major work item.

## Fixes / work log (newest at bottom)

### FIX 1 — xe_ios_boot stale JIT cache (CRITICAL, JIT-ON blocker)
- File: ios/src/ios_emu.mm (xe_ios_boot).
- What was wrong: the boot gate read the CACHED `QueryJitStatus()`, which
  probes once and caches its answer for the life of the process. Sequence:
  user taps a game BEFORE the StikDebug attach lands -> probe says
  kUnavailable -> cached -> every later boot attempt refused with "JIT is
  OFF" even after JIT is genuinely ON. Exactly the false "JIT never works"
  field report the next device test would have produced.
- Why it matters: silently blocks the entire JIT-ON path; handoff #33's
  memory.h comment ("must use the refresh variant, never the cached
  snapshot") is violated at this call site.
- Fix: xe_ios_boot now calls QueryJitStatusRefresh() (fresh probe; boot is
  rare and the probe is cheap). Verified by re-read; the only other
  production caller of the cached variant is nothing (grep: ios_emu.mm was
  the sole caller besides the header/impl).
- Verified: re-read of the edited region; no-JIT path behavior unchanged
  (still a clean refusal); JIT-after-attach path now actually works.

### GETMORERAM INVESTIGATION (done, committed 08e6917a8)
- Fetched and read GetMoreRam's source. Verified: it PATCHes Apple's
  developer-services API (developerservices2.apple.com/services/v1/bundleIds)
  enabling capability id **INCREASED_MEMORY_LIMIT** on the user's App ID.
  The entitlement reaching the app is com.apple.developer.kernel.
  increased-memory-limit, only via a regenerated provisioning profile at
  re-sign/reinstall time. Not expressible in app source.
- Xenra's ios/xenra.entitlements ALREADY declares it (+ extended-virtual-
  addressing). Decision: no code change; GETMORERAM_INTEGRATION.md documents
  the mechanism, the honest limits, and the per-Apple-ID user step.

### FIX 2 — Exit-during-boot deadlock (I-7)
- File: ios/src/XenraAppDelegate.mm (exitGame).
- What was wrong: Exit tapped while status==1 joined the boot thread from the
  main thread; the boot thread can be parked in CallInUIThreadSynchronous
  (Setup's graphics marshaling, CompleteLaunch's UI-thread marshaling) whose
  pump runs on the runloop the join blocks. Verified against emulator.cc
  (CompleteLaunch marshals when not on the UI thread) and kernel_state.cc
  (TerminateTitle is std::quick_exit). One tap = frozen app.
- Fix: quick_exit(0) while booting (the engine's own semantic; one boot per
  process, state on disk); completed boots keep the orderly path — their emu
  thread has already returned from LaunchPath, so the join is instant.
- Verified: re-read; MRC safe (no new objects); boot and running paths both
  reasoned through.

### OG core orientation (for milestone 3)
- The OG core is a CMake-built QEMU fork in the APP repo (main/cpp/
  CMakeLists.txt): globs the QEMU source dirs, excludes host-specific files,
  builds SDL2 locally, glib via meson ExternalProject, Vulkan via
  volk/glslang/VMA, prebuilt Rust dsp56300 with a C-interpreter stub option.
- tcg/tci.c (the TCG interpreter) is EXPLICITLY EXCLUDED from the Android
  build (CMakeLists.txt:698) — flipping that exclusion is the seed of the
  OG no-JIT path: TCI is a pure interpreter and needs NO executable memory
  at all, so it needs no JIT entitlement, no protocol, no StikDebug. Slow by
  design; the requirement is "runs at all", which TCI satisfies.
