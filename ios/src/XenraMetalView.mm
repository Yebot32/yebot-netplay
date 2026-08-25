/**
 ******************************************************************************
 * Xenra : iOS shell                                                          *
 ******************************************************************************
 */

#import "XenraMetalView.h"

#import <QuartzCore/QuartzCore.h>

@implementation XenraMetalView

+ (Class)layerClass {
  return [CAMetalLayer class];
}

- (void)didMoveToWindow {
  [super didMoveToWindow];
  // Match the drawable to the screen this view actually landed on. Doing this
  // here rather than at init is deliberate: before the view is in a window
  // there is no window scene to ask, and guessing the main screen's scale is
  // wrong on an external display or in a resized split-view scene.
  UIScreen* screen = self.window.windowScene.screen ?: self.window.screen;
  if (screen) {
    self.contentScaleFactor = screen.scale;
    self.layer.contentsScale = screen.scale;
  }
}

@end
