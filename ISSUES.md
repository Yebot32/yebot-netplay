# XENRA iOS — ISSUES (session 3 onward)

Format: ID | file | what's wrong/missing | why it matters | confidence.
H = high (verified by reading the actual current code), M = medium, L = low.
Prefix I- = iOS. Append new findings at the bottom; never delete history —
strike through / mark FIXED with the commit.

## Open

- I-2 | ios/src/ios_emu.mm | 360 no-JIT: no interpreter exists anywhere in
  xenia (cpu/backend holds x64 + a64 + null stub). Without JIT the guest
  cannot execute; the app must refuse cleanly and tell the user why.
  Currently DONE correctly (alert + status detail, no crash), but this is a
  physical limit of the codebase, not a completed fallback. Writing a PPC
  interpreter is out of session scope. | Documented decision point. | H

- I-3 | ios (whole shell) | UI is a diagnostic shell, not the Android UI.
  Android app has: library with covers/menu/settings, resume/saves handling,
  per-game settings, on-screen control editor, perf HUD, netplay UI. iOS has:
  status label + flat game list + hardcoded pad grid. | User requirement:
  exact replica of Android. | H

- I-4 | OG path entirely | OG (xemu/QEMU) not ported to iOS at all (handoff
  #33 milestone 3). Core lives in the app repo (main/cpp), built for Android
  with meson; renderer is Vulkan (needs MoltenVK or Metal work on iOS); JNI
  layer (xemu_android.cpp) needs an iOS counterpart; SDL needs iOS handling.
  No-JIT for OG is solvable via vendored TCI (tcg/tci + meson
  tcg_interpreter option) — a real interpreter fallback exists for OG. | The
  "both paths ported" goal. | H

- I-5 | ios/src/XenraAppDelegate.mm launchGame | Boot alert text says "Use
  the StikDebug button, attach with universal.js, then try again" — fine, but
  the alert does not re-open the handoff directly (user must back out to the
  library to find the button). Minor UX. | M

- I-6 | ios/src/XenraAppDelegate.mm ScanGames | Extensions list
  (.iso/.xex/.zar/.god/.con/.live/.pirs) — Android's scanner also takes
  .xbe? (OG titles) and .iso-containing folders; verify against Android's
  GameLibrary scan logic when the OG path lands. Also no thumbnail/cover
  art (Android shows covers). | UI parity + OG readiness. | M

## Fixed

- I-8 | ios/src/XenraAppDelegate.mm cellForRowAtIndexPath | Per-cell
  NSFileManager attributesOfItemAtPath on every visible row, every reload
  (the Android E-class main-thread I/O bug, re-created on iOS) + a flat
  non-Android UI. | H
  -> FIXED (session 3, UI pass 1): background scan (XenraGameScanner) feeds
  cached metadata + covers; library screen rebuilt as the Android dashboard
  (theme/blade/scanner files). Per-row disk I/O eliminated.

- I-7 | ios/src/XenraAppDelegate.mm exitGame | Exit tapped during boot
  (status==1, "Booting... can take a while" screen, Exit button visible)
  deadlocked: xe_ios_shutdown joins the boot thread from the main thread,
  while the boot thread can be parked in a synchronous CallInUIThread
  (Setup/GraphicsSystem::Setup and Emulator::CompleteLaunch both marshal to
  the UI thread) whose pump lives on the runloop the join is blocking. Every
  Exit during boot = frozen app until the watchdog kill. | H
  -> FIXED (session 3): status==1 now quick_exit(0)s — the engine's own
  teardown semantic (KernelState::TerminateTitle is std::quick_exit), safe
  because one boot per process and all state is on disk. Completed boots
  keep the orderly shutdown path (the emu thread has exited by then, join is
  instant).

- I-1 | ios/src/ios_emu.mm xe_ios_boot | Boot gate read the CACHED
  QueryJitStatus() — first answer cached for the process lifetime. Tapping a
  game before the StikDebug attach landed would cache kUnavailable and block
  every boot attempt forever after, even with JIT genuinely ON. Violated the
  documented rule (memory.h: "use the refresh variant, never the cached
  snapshot"). | Silently killed the whole JIT-ON path. | H
  -> FIXED (session 3, fix 1): xe_ios_boot now uses QueryJitStatusRefresh().
