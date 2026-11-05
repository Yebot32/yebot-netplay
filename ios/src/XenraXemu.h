/**
 ******************************************************************************
 * Xenra : iOS shell - the original Xbox core                                 *
 ******************************************************************************
 *
 * xemu, built from DukeX's tree, ships as a dylib in the bundle and is loaded
 * only for an original Xbox game. The 360 core is linked into the app, and the
 * two never run in one launch.
 */

#import <UIKit/UIKit.h>

BOOL XenraXemuAvailable(void);

// What the user still has to pick before a game can boot, or nil.
NSString* XenraXemuMissingFiles(void);

// Loads the core and fills its coroutine pool. Worth doing before JIT is
// enabled: new coroutine stacks are made by signalling this thread, and an
// attached debugger may eat that signal. Returns an error, or nil.
NSString* XenraXemuPrepare(void);


// A reason this launch cannot work, in words for the user, or nil. Logs the sizes.
NSString* XenraXemuFileProblem(void);

// Stops and restarts the guest, for the game menu.
void XenraXemuSetPaused(BOOL paused);

// Runs the game to the end, on the main thread, pumping the run loop itself.
// Call from a timer rather than a dispatch block: the main queue does not drain
// inside a block, and the app's own dispatches would wait until the game quit.
int XenraXemuRun(NSString* game, NSString* name, CALayer* layer);

// Takes the on-screen pad's XInput bits and axes. active NO hands the port back
// to any physical controller.
void XenraXemuSetPad(BOOL active, int buttons, short lx, short ly, short rx,
                     short ry, unsigned char lt, unsigned char rt);

void XenraXemuReset(void);
void XenraXemuShutdown(void);

// SDL opens a window of its own over the app and takes every touch. The core
// draws to our layer, so that window only has to stay out of the way, and SDL
// may show it again at any moment.
void XenraXemuHideSdlWindows(UIWindow* ours);

// One line for the on-screen counter, or nil before the first frame.
NSString* XenraXemuStatsLine(void);
