#import "XenraXemu.h"

#include <cstdlib>
#include <dlfcn.h>
#include <sys/sysctl.h>
#include <vector>

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

// M1 and older have no TXM: generated code runs from a plain second mapping, and
// the debugger's brk handshake does not exist there at all. hw.cpufamily is the
// same list XeniOS keeps; anything newer on iOS 26+ needs Universal.js.
static BOOL NeedsUniversalJit(void) {
  if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26) {
    return NO;
  }
  uint32_t family = 0;
  size_t size = sizeof(family);
  if (sysctlbyname("hw.cpufamily", &family, &size, nullptr, 0) != 0) return YES;
  switch (family) {
    case 0x67ceee93u:  // A10
    case 0xe81e7ef6u:  // A11
    case 0x07d34b9fu:  // A12
    case 0x462504d2u:  // A13
    case 0x1b588bb3u:  // A14, M1
      return NO;
  }
  return YES;
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
                    @"[general]\nshow_welcome = false\nskip_boot_anim = true\n"
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

int XenraXemuRun(NSString* game, NSString* name, CALayer* layer) {
  auto main = reinterpret_cast<int (*)(int, char**)>(
      dlsym(g_core, "xemu_ios_main"));
  auto set_layer = reinterpret_cast<void (*)(void*)>(
      dlsym(g_core, "xemu_ios_set_external_metal_layer"));
  if (!main) return -1;

  const BOOL universal = NeedsUniversalJit();
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
    @"XEMU_IOS_VK_PIPELINE_CACHE_PATH" : shaders,
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
    @"XEMU_IOS_TCG_WATCHDOG" : @"off",
    @"XEMU_IOS_COROUTINE_PRIME_COUNT" : @"640",
  };
  for (NSString* name in environment) {
    setenv(name.UTF8String, [environment[name] UTF8String], 1);
  }
  if (set_layer) set_layer((__bridge void*)layer);

  NSString* accel = [NSString
      stringWithFormat:@"tcg,thread=single,tb-size=%@%@",
                       [XenraSettings stringForKey:@"og.tb" fallback:@"64"],
                       universal ? @"" : @",split-wx=on"];
  NSArray<NSString*>* arguments =
      @[ @"xemu-ios", @"-accel", accel, @"-config_path", WriteConfig(game, name) ];
  XenraLog([NSString stringWithFormat:@"xemu: %@ universal=%d", accel, universal]);
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
