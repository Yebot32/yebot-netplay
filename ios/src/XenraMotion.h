/**
 ******************************************************************************
 * Xenra : iOS shell - motion                                                 *
 ******************************************************************************
 *
 * The Android app's animation, with its durations and curves: main/res/anim,
 * the dashboard's entrance, ConsoleSwitchTransition and SetupHandoffTransition.
 */

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, XenraCurve) {
  XenraCurveStandard,    // fast_out_slow_in
  XenraCurveDecelerate,  // DecelerateInterpolator
  XenraCurveQuint,       // decelerate_quint
  XenraCurveEaseInOut,   // AccelerateDecelerateInterpolator
};

void XenraAnimate(NSTimeInterval duration, NSTimeInterval delay,
                  XenraCurve curve, void (^animations)(void),
                  void (^done)(void));

// Each view starts offset and clear, and settles in turn.
void XenraEnter(NSArray<UIView*>* views, CGFloat dx, CGFloat dy,
                NSTimeInterval delay, NSTimeInterval stagger,
                NSTimeInterval duration, XenraCurve curve);

// A photograph of the window, dissolving away over whatever change built.
void XenraCrossfade(UIWindow* window, NSTimeInterval duration,
                    void (^change)(void));

// The activity stack: Android's window transitions instead of UIKit's.
@interface XenraNavigationController : UINavigationController
@end

// button_press_spring: down to 92%, back with a slight overshoot.
void XenraAddSpring(UIControl* control);
