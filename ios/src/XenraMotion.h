/**
 ******************************************************************************
 * Xenra : iOS shell - motion                                                 *
 ******************************************************************************
 *
 * The Android app's animation, with its durations and curves: main/res/anim,
 * the dashboard's entrance, ConsoleSwitchTransition and SetupHandoffTransition.
 *
 * Android's entrance distances are in raw pixels, so they shrink with screen
 * density. The constants below are what they come to on the phones and tablets
 * the app was tuned on: 150 px is 50 dp at density 3 and 75 dp on the Tab.
 */

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, XenraCurve) {
  XenraCurveStandard,      // fast_out_slow_in
  XenraCurveDecelerate,    // DecelerateInterpolator(), exactly 1 - (1 - t)^2
  XenraCurveDecelerate14,  // DecelerateInterpolator(1.4)
  XenraCurveDecelerate16,  // DecelerateInterpolator(1.6)
  XenraCurveQuint,         // decelerate_quint
  XenraCurveEaseInOut,     // AccelerateDecelerateInterpolator
};

// Dashboard blades: 150 px, stagger 100 ms, 350 ms, Decelerate.
static const CGFloat XenraTravelDashboard = 60;
// Library list rows: 120 px, stagger 40 ms, 350 ms, Decelerate. The grid does not
// travel: scale 0.92 with XenraEnterScale, stagger 30 ms, 350 ms, Decelerate.
static const CGFloat XenraTravelLibraryRow = 48;
// Settings pane on a tab change, as one piece: 20 px up, 250 ms, Decelerate.
static const CGFloat XenraTravelSettingsPane = 8;

void XenraAnimate(NSTimeInterval duration, NSTimeInterval delay,
                  XenraCurve curve, void (^animations)(void),
                  void (^done)(void));

// Each view starts offset and clear, and settles in turn.
void XenraEnter(NSArray<UIView*>* views, CGFloat dx, CGFloat dy,
                NSTimeInterval delay, NSTimeInterval stagger,
                NSTimeInterval duration, XenraCurve curve);

// The same, starting from a smaller size instead of an offset.
void XenraEnterScale(NSArray<UIView*>* views, CGFloat scale,
                     NSTimeInterval delay, NSTimeInterval stagger,
                     NSTimeInterval duration, XenraCurve curve);

// A photograph of the window, dissolving away over whatever change built.
void XenraCrossfade(UIWindow* window, NSTimeInterval duration,
                    void (^change)(void));

// The activity stack: Android's window transitions instead of UIKit's, an edge
// swipe that follows the finger back, and the interface style of the theme. The
// swipe works on any pushed screen except a game, and not over an open sheet. A
// controller can refuse it by answering NO to xenraAllowsEdgeBack.
@interface XenraNavigationController : UINavigationController
@end

@interface UIViewController (XenraEdgeBack)
- (BOOL)xenraAllowsEdgeBack;
@end

// button_press_spring on any view: down to 92% in 100 ms, back in 400 ms through
// OvershootInterpolator. Call it with YES on press and NO on release.
void XenraSpringPress(UIView* view, BOOL pressed);

// The same, hooked to a control's touch events. XenraPillButton has its own.
void XenraAddSpring(UIControl* control);

#ifdef XENRA_UITEST
// The simulator tour cannot make a real edge swipe, so it drives the same
// transition the swipe does.
@interface XenraNavigationController (Tour)
- (void)tourDragBegin;
- (void)tourDragTo:(CGFloat)progress;
- (void)tourDragEnd:(BOOL)finish;
@end
#endif
