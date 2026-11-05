/**
 ******************************************************************************
 * Xenra : iOS native driver                                                  *
 ******************************************************************************
 *
 * The iOS counterpart of the Android JNI layer (emulator-core/src/main/cpp/
 * xendroid_emu.*): an IosWindowedAppContext + IosWindow + boot thread driving
 * the real xe::Emulator with the Metal GPU backend and the a64 CPU backend,
 * plus a C API the UIKit shell talks to.
 *
 * Everything outside this file is platform-neutral xenia code; everything the
 * shell sees is the extern "C" API at the bottom.
 */

#ifndef XENRA_IOS_EMU_H_
#define XENRA_IOS_EMU_H_

#include <cstddef>
#include <cstdint>

#ifdef __OBJC__
@class UIView;
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Called once on the main thread before anything else. documents_dir is the
// app's Documents directory (storage root); caches_dir the app's Caches
// directory; log_path where the core log goes. Returns 0 on success.
int xe_ios_initialize(const char* documents_dir, const char* caches_dir,
                      const char* log_path);

// Points the emulator's surface at the game view (the CAMetalLayer-backed
// UIView). Call on the main thread before xe_ios_boot.
void xe_ios_set_game_view(UIView* view);

// Boots a title from an absolute host path (.iso / .xex / STFS container).
// Returns 0 if the boot thread was started; the real result arrives through
// xe_ios_status. Call from the main thread.
int xe_ios_boot(const char* path);

// Main-thread pump. Drains the WindowedAppContext queue and paints one frame
// when the presenter has asked for one. Drive it from a CADisplayLink (or a
// timer); safe to call redundantly.
void xe_ios_pump(void);

// Virtual gamepad, slot 0. buttons is an X_INPUT_GAMEPAD_BUTTON bitmask;
// sticks are -32768..32767; triggers 0..255.
void xe_ios_input_set(int buttons, short lx, short ly, short rx, short ry,
                      unsigned char lt, unsigned char rt);

// 0 = idle, 1 = booting, 2 = running, negative = failed (see the log, which
// is written next to the storage root).
int xe_ios_status(void);
const char* xe_ios_status_detail(void);

// Sets a core setting by name; value is TOML, so strings carry their quotes.
// Takes effect on the next boot. Unknown names are logged and ignored.
void xe_ios_set_cvar(const char* name, const char* value);

// Shuts the emulator down and releases the window. Call on the main thread.
void xe_ios_shutdown(void);

// 1 stops the guest, 0 carries on. For the game menu.
void xe_ios_set_paused(int paused);

// Frames per second reaching the screen, or 0 before the first.
float xe_ios_fps(void);

// Puts everything logged so far on disk. Safe before init and after shutdown.
void xe_ios_flush_log(void);

#ifdef __cplusplus
}
#endif

#endif  // XENRA_IOS_EMU_H_
