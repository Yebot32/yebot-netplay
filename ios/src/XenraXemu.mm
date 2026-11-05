#import "XenraXemu.h"

#include <cstdlib>
#include <dlfcn.h>
#import <AVFoundation/AVFoundation.h>
#import <GameController/GameController.h>
#include <initializer_list>
#include <sys/sysctl.h>
#include <unistd.h>
#include <vector>

#import "XenraJitProbe.h"
#import "XenraScreens.h"
#import "XenraSettings.h"

static void* g_core;
static void (*g_set_touch)(int, uint32_t, int16_t, int16_t, int16_t, int16_t,
                           int16_t, int16_t);
static void (*g_shutdown)(void);
static void (*g_reset)(int);

static NSString* CorePath(void) {
  return [NSBundle.mainBundle.privateFrameworksPath
      stringByAppendingPathComponent:@"libxemu-ios-core.dylib"];
}


BOOL XenraXemuAvailable(void) {
  return [NSFileManager.defaultManager fileExistsAtPath:CorePath()];
}

NSString* XenraXemuMissingFiles(void) {
  NSMutableArray* missing = [NSMutableArray array];
  NSDictionary* names = @{
    @"mcpx" : @"MCPX Boot ROM",
    @"flash" : @"Flash ROM (BIOS)",
    @"hdd" : @"Hard Disk",
  };
  for (NSString* key in @[ @"mcpx", @"flash", @"hdd" ]) {
    if (![XenraSettings urlForBookmark:key]) [missing addObject:names[key]];
  }
  return missing.count ? [missing componentsJoinedByString:@", "] : nil;
}


NSString* XenraXemuPrepare(void) {
  if (g_core) return nil;
  g_core = dlopen(CorePath().fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
  if (!g_core) return @(dlerror());
  g_set_touch = reinterpret_cast<decltype(g_set_touch)>(
      dlsym(g_core, "xemu_ios_set_touch_controller_state"));
  g_shutdown = reinterpret_cast<decltype(g_shutdown)>(
      dlsym(g_core, "xemu_ios_request_shutdown"));
  g_reset = reinterpret_cast<decltype(g_reset)>(
      dlsym(g_core, "qemu_system_reset_request"));
  auto prime = reinterpret_cast<void (*)(unsigned)>(
      dlsym(g_core, "xemu_ios_coroutine_prime_global_pool"));
  if (prime) prime(640);
  return nil;
}

// StikDebug runs Universal.js only on TXM devices, and that script stays attached
// to answer the brk. Without TXM nothing is attached, and a brk would be a SIGTRAP.
static BOOL DebuggerAttached(void) {
  struct kinfo_proc info = {};
  size_t size = sizeof(info);
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
  if (sysctl(mib, 4, &info, &size, nullptr, 0) != 0) return YES;
  return (info.kp_proc.p_flag & P_TRACED) != 0;
}

static BOOL NeedsUniversalJit(void) {
  return NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 &&
         DebuggerAttached();
}

static NSString* Quoted(NSString* value) {
  NSString* escaped =
      [[value stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
          stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
  return [NSString stringWithFormat:@"\"%@\"", escaped];
}

static NSString* WriteConfig(NSString* game, NSString* name) {
  NSString* docs = NSSearchPathForDirectoriesInDomains(
                       NSDocumentDirectory, NSUserDomainMask, YES)
                       .firstObject;
  NSString* dir = [docs stringByAppendingPathComponent:@"xemu"];
  [NSFileManager.defaultManager createDirectoryAtPath:dir
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:nil];
  NSString* config =
      [NSString stringWithFormat:
                    @"[general]\nshow_welcome = false\nskip_boot_anim = false\n"
                     "games_dir = %@\n\n"
                     "[display]\nrenderer = \"VULKAN\"\n\n"
                     "[display.quality]\nsurface_scale = %@\n\n"
                     "[display.ui]\nshow_menubar = false\n"
                     "show_notifications = false\nhide_cursor = true\n\n"
                     "[perf]\ncache_shaders = true\n\n"
                     "[input]\nauto_bind = true\n"
                     "background_input_capture = true\n\n"
                     "[sys]\nmem_limit = \"64\"\navpack = \"hdtv\"\n\n"
                     "[sys.files]\nbootrom_path = %@\nflashrom_path = %@\n"
                     "hdd_path = %@\ndvd_path = %@\n",
                    Quoted(game.stringByDeletingLastPathComponent),
                    [XenraSettings valueForKey:@"og.scale"
                                          game:name
                                      fallback:@"1"],
                    Quoted([XenraSettings urlForBookmark:@"mcpx"].path),
                    Quoted([XenraSettings urlForBookmark:@"flash"].path),
                    Quoted([XenraSettings urlForBookmark:@"hdd"].path),
                    Quoted(game)];
  NSString* path = [dir stringByAppendingPathComponent:@"xemu-ios.toml"];
  [config writeToFile:path
           atomically:YES
             encoding:NSUTF8StringEncoding
                error:nil];
  return path;
}

// The core reads neither of these from the environment: DukeX sets them on the
// layer itself, through selectors the public header does not declare.
static void ApplyPacing(CALayer* layer) {
  SEL sync = NSSelectorFromString(@"setDisplaySyncEnabled:");
  if ([layer respondsToSelector:sync]) {
    reinterpret_cast<void (*)(id, SEL, BOOL)>(
        [layer methodForSelector:sync])(layer, sync, YES);
  }
  SEL nominal = NSSelectorFromString(@"setNominalFramesPerSecond:");
  if ([layer respondsToSelector:nominal]) {
    reinterpret_cast<void (*)(id, SEL, NSInteger)>(
        [layer methodForSelector:nominal])(layer, nominal, 60);
  }
}

NSString* XenraXemuFileProblem(void) {
  // A wrong MCPX is the one mistake the core reports only to a menu we do not
  // show: it carries on from the flash image and the guest never starts.
  NSURL* mcpx = [XenraSettings urlForBookmark:@"mcpx"];
  NSURL* flash = [XenraSettings urlForBookmark:@"flash"];
  NSURL* hdd = [XenraSettings urlForBookmark:@"hdd"];
  NSMutableString* sizes = [NSMutableString stringWithString:@"system files:"];
  NSString* problem = nil;
  NSDictionary* names = @{@"MCPX" : mcpx ?: NSNull.null,
                          @"Flash" : flash ?: NSNull.null,
                          @"HDD" : hdd ?: NSNull.null};
  for (NSString* name in names) {
    NSURL* url = names[name];
    if ((id)url == NSNull.null) continue;
    NSNumber* size = nil;
    [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    [sizes appendFormat:@" %@=%@ %@", name, size ?: @"unreadable",
                        url.lastPathComponent];
    if (!size) {
      problem = [NSString stringWithFormat:@"%@ cannot be read. It may have "
                                            "moved. Choose it again in the "
                                            "Setup Wizard.",
                                           url.lastPathComponent];
    } else if ([name isEqual:@"MCPX"] && size.longLongValue != 512) {
      problem = [NSString stringWithFormat:@"%@ is not an MCPX boot ROM, which "
                                            "is exactly 512 bytes. Choose "
                                            "mcpx_1.0.bin in the Setup Wizard.",
                                           url.lastPathComponent];
    }
  }
  XenraLog(sizes);
  return problem;
}

void XenraXemuSetPaused(BOOL paused) {
  static auto lock =
      reinterpret_cast<void (*)(void)>(dlsym(g_core, "xemu_main_loop_lock"));
  static auto unlock =
      reinterpret_cast<void (*)(void)>(dlsym(g_core, "xemu_main_loop_unlock"));
  static auto stop = reinterpret_cast<int (*)(int)>(dlsym(g_core, "vm_stop"));
  static auto start = reinterpret_cast<void (*)(void)>(dlsym(g_core, "vm_start"));
  static auto running =
      reinterpret_cast<bool (*)(void)>(dlsym(g_core, "runstate_is_running"));
  if (!lock || !unlock || !stop || !start || !running) return;
  // RUN_STATE_PAUSED, as xemu's own pause action does it.
  constexpr int kRunStatePaused = 4;
  lock();
  if (paused && running()) {
    stop(kRunStatePaused);
  } else if (!paused && !running()) {
    start();
  }
  unlock();
}

int XenraXemuRun(NSString* game, NSString* name, CALayer* layer) {
  auto main = reinterpret_cast<int (*)(int, char**)>(
      dlsym(g_core, "xemu_ios_main"));
  auto set_layer = reinterpret_cast<void (*)(void*)>(
      dlsym(g_core, "xemu_ios_set_external_metal_layer"));
  if (!main) return -1;

  const BOOL universal = NeedsUniversalJit();
  const XenraJitScheme scheme =
      universal ? XenraJitRxFirst : XenraJitChooseScheme();
  NSString* docs = NSSearchPathForDirectoriesInDomains(
                       NSDocumentDirectory, NSUserDomainMask, YES)
                       .firstObject;
  NSString* shaders = [docs stringByAppendingPathComponent:@"xemu/shaders"];
  [NSFileManager.defaultManager createDirectoryAtPath:shaders
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:nil];
  // DukeX's launch values, unchanged unless Xenra has a reason.
  NSDictionary* environment = @{
    @"XEMU_IOS_JIT_MODE" : universal ? @"universal-js" : @"wx-reprotection",
    @"XEMU_IOS_UNIVERSAL_JIT" : universal ? @"1" : @"0",
    @"XEMU_IOS_VK_PIPELINE_CACHE_PATH" : [shaders
        stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%lx-vulkan-pipeline.bin",
                                       (unsigned long)name.hash]],
    @"XEMU_IOS_VK_SWAPCHAIN" : @"1",
    @"XEMU_IOS_NATIVE_METAL_PRESENTER" : @"1",
    @"XEMU_IOS_PRESENTER_PORTRAIT_SCALE" : @"1.0",
    @"XEMU_IOS_PRESENTER_PORTRAIT_ALIGN_X" : @"0.5",
    @"XEMU_IOS_PRESENTER_PORTRAIT_ALIGN_Y" : @"0.5",
    @"XEMU_IOS_PRESENTER_LANDSCAPE_SCALE" : @"1.0",
    @"XEMU_IOS_PRESENTER_LANDSCAPE_ALIGN_X" : @"0.5",
    @"XEMU_IOS_PRESENTER_LANDSCAPE_ALIGN_Y" : @"0.5",
    @"XEMU_IOS_PRESENTER_ASPECT" : @"auto",
    @"XEMU_IOS_PRESENTER_LINEAR_FILTER" : @"1",
    @"XEMU_IOS_PRESENTER_FLIP_X" : @"0",
    @"XEMU_IOS_PRESENTER_FLIP_Y" : @"1",
    @"XEMU_IOS_VK_PRESENT_FPS" : @"60",
    @"XEMU_IOS_NOMINAL_FPS" : @"60",
    @"XEMU_IOS_VK_PRESENT_MODE" : @"fifo",
    @"XEMU_IOS_DISPLAY_SYNC" : @"1",
    @"MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS" : @"0",
    @"XEMU_IOS_HOST_DEPTH_INTERPOLATION" : @"0",
    @"XEMU_IOS_HOST_DEPTH_INTERPOLATION_MODE" : @"perspective",
    @"XEMU_IOS_DEPTH_CLAMP" : @"1",
    @"XEMU_IOS_DISABLE_SHADER_DEPTH" : @"1",
    @"XEMU_IOS_STRICT_SURFACE_TEXTURE_FORMATS" : @"0",
    @"XEMU_IOS_FALLBACK_GENERATION_FILTER" : @"1",
    @"XEMU_IOS_SKIP_GL_FINISH" : @"1",
    @"XEMU_IOS_TCG_WATCHDOG" : @"log",
    @"XEMU_IOS_SYNC_RAW" : @"0",
    @"XEMU_IOS_SYNC_DMA" : @"0",
    @"XEMU_IOS_COROUTINE_PRIME_COUNT" : @"640",
    @"XEMU_IOS_DISPLAY_PERF_STATS" : @"0",
  };
  for (NSString* name in environment) {
    setenv(name.UTF8String, [environment[name] UTF8String], 1);
  }
  // The core's own traces. The CPU heartbeat is once a second; the rest fire on
  // events. They answer whether the guest is running and how far it has got
  // when nothing has reached the screen.
  if ([[XenraSettings stringForKey:@"core.trace" fallback:@"true"]
          isEqual:@"true"]) {
    for (const char* name :
         {"XEMU_IOS_TCG_TRACE", "XEMU_IOS_RR_RETURN_TRACE",
          "XEMU_IOS_FRAMEBUFFER_TRACE"}) {
      setenv(name, "1", 1);
    }
  }
  if (!universal && scheme == XenraJitRxFirst) setenv("XEMU_IOS_RX_FIRST", "1", 1);
  ApplyPacing(layer);
  // Sound through the mute switch, and pads that keep working with our window
  // key rather than SDL's.
  [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback
                                       error:nil];
  [AVAudioSession.sharedInstance setActive:YES error:nil];
  GCController.shouldMonitorBackgroundEvents = YES;
  if (set_layer) set_layer((__bridge void*)layer);

  NSString* accel = [NSString
      stringWithFormat:@"tcg,thread=single,tb-size=%@%@",
                       [XenraSettings stringForKey:@"og.tb" fallback:@"64"],
                       scheme == XenraJitRwFirst ? @",split-wx=on" : @""];
  NSArray<NSString*>* arguments =
      @[ @"xemu-ios", @"-accel", accel, @"-config_path", WriteConfig(game, name) ];
  XenraLog([NSString stringWithFormat:@"xemu: %@ universal=%d traced=%d scheme=%d", accel,
                                      universal, DebuggerAttached(), int(scheme)]);
  std::vector<char*> argv;
  for (NSString* argument in arguments) {
    argv.push_back(strdup(argument.UTF8String));
  }
  argv.push_back(nullptr);
  return main(int(arguments.count), argv.data());
}

void XenraXemuSetPad(BOOL active, int buttons, short lx, short ly, short rx,
                     short ry, unsigned char lt, unsigned char rt) {
  if (!g_set_touch) return;
  // XInput bits to xemu's ControllerState. White and Black have no XInput
  // equivalent, so the original Xbox pad's bumpers stand in as Android's do.
  static const struct {
    int from;
    uint32_t to;
  } kMap[] = {
      {0x1000, 1 << 0},  {0x2000, 1 << 1},  {0x4000, 1 << 2},
      {0x8000, 1 << 3},  {0x0004, 1 << 4},  {0x0001, 1 << 5},
      {0x0008, 1 << 6},  {0x0002, 1 << 7},  {0x0020, 1 << 8},
      {0x0010, 1 << 9},  {0x0100, 1 << 10}, {0x0200, 1 << 11},
      {0x0040, 1 << 12}, {0x0080, 1 << 13},
  };
  uint32_t bits = 0;
  for (const auto& entry : kMap) {
    if (buttons & entry.from) bits |= entry.to;
  }
  g_set_touch(active, bits, int16_t(lt * 128), int16_t(rt * 128), lx, ly, rx, ry);
}

void XenraXemuReset(void) {
  // SHUTDOWN_CAUSE_GUEST_RESET.
  if (g_reset) g_reset(7);
}

void XenraXemuShutdown(void) {
  if (g_shutdown) g_shutdown();
}

void XenraXemuHideSdlWindows(UIWindow* ours) {
  BOOL found = NO;
  for (UIWindow* window in ours.windowScene.windows) {
    if (window == ours) continue;
    if (![NSStringFromClass(window.rootViewController.class)
            containsString:@"SDL_uikitviewcontroller"]) {
      continue;
    }
    found = YES;
    window.hidden = YES;
    window.userInteractionEnabled = NO;
    window.windowLevel = UIWindowLevelNormal - 1;
  }
  if (found && !ours.isKeyWindow) [ours makeKeyAndVisible];
}

// DukeXDisplayStats, up to the fields read here.
struct XemuStats {
  uint64_t sample_id;
  double presenter_fps;
  uint32_t nv2a_fps;
  int32_t mspf;
  uint64_t frames;
  uint64_t present_ready_frames;
  uint64_t present_missed_frames;
  uint64_t native_present_frames;
  uint64_t pvideo_frames;
  uint64_t surface_upload_pending_frames;
  uint64_t finish_presenting_frames;
  int64_t avg_total_us;
  int64_t avg_wait_present_us;
  int64_t avg_submit_us;
  int64_t avg_present_us;
  int32_t tail[16];
};

NSString* XenraXemuStatsLine(void) {
  static auto copy = reinterpret_cast<int (*)(XemuStats*)>(
      g_core ? dlsym(g_core, "xemu_ios_copy_display_stats") : nullptr);
  XemuStats stats = {};
  if (!copy || !copy(&stats)) return nil;
  return [NSString stringWithFormat:@"%u FPS  ·  present %.0f  ·  %d ms",
                                    stats.nv2a_fps, stats.presenter_fps,
                                    stats.mspf];
}
