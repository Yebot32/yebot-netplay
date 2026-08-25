/**
 ******************************************************************************
 * Xenra : iOS shell                                                          *
 ******************************************************************************
 *
 * Milestone 1: prove the pipeline, not the emulator.
 *
 * This app deliberately does NOT boot a game. It links the real xenia-base,
 * runs the real JIT probe, and brings up a real MTLDevice through the real
 * IosUIViewSurface, then puts the answers on screen. The point is to settle -
 * on hardware, in one launch - the questions that decide whether the rest of
 * the port is worth building:
 *
 *   1. Does the iOS toolchain compile this tree at all?
 *   2. Does codesigning and sideloading survive it?
 *   3. Can this process execute generated code? (see the note below)
 *   4. Does Metal come up, and on which GPU family?
 *
 * Question 3 is the one that matters most. Xenia has no PowerPC interpreter -
 * cpu/backend/ holds x64, a64 and a null stub that cannot execute anything -
 * so a device that refuses executable memory cannot run the 360 core at all,
 * at any speed. That is worth knowing before a UI is built on top of it.
 */

#import "XenraAppDelegate.h"

#import <Metal/Metal.h>
#import <UIKit/UIKit.h>

#include <string>

#include "XenraMetalView.h"

#include "xenia/base/memory.h"
#include "xenia/ui/surface_ios.h"

namespace {

// Reads the same probe the emulator would, so what is displayed here is not a
// separate reimplementation that could drift from the real answer.
NSString* DescribeJitStatus() {
  const xe::memory::JitStatus& status = xe::memory::QueryJitStatus();
  const char* label =
      xe::memory::JitCapabilityToShortString(status.capability);
  NSString* detail = [NSString stringWithUTF8String:status.detail.c_str()];

  if (status.capability == xe::memory::JitCapability::kUnavailable) {
    return [NSString
        stringWithFormat:@"JIT: %s\n%@\n\nThe 360 core cannot run without it - "
                         @"there is no PowerPC interpreter to fall back on.",
                         label, detail];
  }
  return [NSString stringWithFormat:@"JIT: %s\n%@", label, detail];
}

NSString* DescribeMetal(id<MTLDevice> device) {
  if (!device) {
    return @"Metal: NO DEVICE";
  }
  // Apple7 is the M1 family. The Metal backend gates mesh shaders and a few
  // other paths on this, so it is worth reporting rather than inferring from
  // the model name.
  NSString* family = @"below Apple7";
  if ([device supportsFamily:MTLGPUFamilyApple9]) {
    family = @"Apple9+";
  } else if ([device supportsFamily:MTLGPUFamilyApple8]) {
    family = @"Apple8";
  } else if ([device supportsFamily:MTLGPUFamilyApple7]) {
    family = @"Apple7";
  }
  NSString* argbuf =
      device.argumentBuffersSupport >= MTLArgumentBuffersTier2 ? @"Tier2" : @"Tier1";
  return [NSString stringWithFormat:@"Metal: %@\nFamily: %@   ArgBuffers: %@",
                                    device.name, family, argbuf];
}

}  // namespace

@interface XenraAppDelegate ()
@property(nonatomic, strong) XenraMetalView* metalView;
@property(nonatomic, strong) UILabel* statusLabel;
@end

@implementation XenraAppDelegate

- (BOOL)application:(UIApplication*)application
    didFinishLaunchingWithOptions:(NSDictionary*)launchOptions {
  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];

  UIViewController* root = [[UIViewController alloc] init];
  root.view.backgroundColor = UIColor.blackColor;

  self.metalView = [[XenraMetalView alloc] initWithFrame:root.view.bounds];
  self.metalView.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [root.view addSubview:self.metalView];

  self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
  self.statusLabel.numberOfLines = 0;
  self.statusLabel.textColor = UIColor.whiteColor;
  self.statusLabel.font = [UIFont monospacedSystemFontOfSize:14.0
                                                      weight:UIFontWeightRegular];
  self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
  [root.view addSubview:self.statusLabel];

  UILayoutGuide* safe = root.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [self.statusLabel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor
                                                   constant:16.0],
    [self.statusLabel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor
                                                    constant:-16.0],
    [self.statusLabel.topAnchor constraintEqualToAnchor:safe.topAnchor
                                               constant:16.0],
  ]];

  self.window.rootViewController = root;
  [self.window makeKeyAndVisible];

  [self refreshStatus];
  return YES;
}

- (void)refreshStatus {
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();

  // Drive the real surface class rather than touching the layer directly, so
  // this exercises the code the presenter will use rather than something that
  // merely resembles it.
  xe::ui::IosUIViewSurface surface(self.metalView);
  CAMetalLayer* layer = surface.GetOrCreateMetalLayer();
  if (layer && device) {
    layer.device = device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
  }

  uint32_t width = 0, height = 0;
  const bool have_size = surface.GetSize(width, height);
  const double scale = surface.GetBackingScale();

  NSMutableString* text = [NSMutableString string];
  [text appendString:@"Xenra iOS - pipeline check\n\n"];
  [text appendFormat:@"%@\n\n", DescribeJitStatus()];
  [text appendFormat:@"%@\n\n", DescribeMetal(device)];
  [text appendFormat:@"Surface: %@  layer=%@\n",
                     have_size ? [NSString stringWithFormat:@"%ux%u @%.1fx",
                                                           width, height, scale]
                               : @"not ready",
                     layer ? @"ok" : @"NULL"];

  self.statusLabel.text = text;
}

@end
