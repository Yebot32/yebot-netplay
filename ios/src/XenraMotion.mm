#import "XenraMotion.h"

#import <QuartzCore/QuartzCore.h>

#import "XenraAmbient.h"
#import "XenraPadNav.h"
#import "XenraScreens.h"
#import "XenraSettings.h"
#import "XenraTheme.h"
#import "XenraUI.h"
#import "XenraUiSounds.h"

void XenraAnimate(NSTimeInterval duration, NSTimeInterval delay,
                  XenraCurve curve, void (^animations)(void),
                  void (^done)(void)) {
  CGPoint first, second;
  switch (curve) {
    case XenraCurveStandard:
      first = CGPointMake(0.4, 0), second = CGPointMake(0.2, 1);
      break;
    case XenraCurveDecelerate:
      // Exact: 1 - (1 - t)^2 is this cubic with evenly spaced x.
      first = CGPointMake(1.0 / 3, 2.0 / 3), second = CGPointMake(2.0 / 3, 1);
      break;
    case XenraCurveDecelerate14:
      // 1 - (1 - t)^2.8 and ^3.2, matched at both ends.
      first = CGPointMake(1.0 / 3, 0.933), second = CGPointMake(2.0 / 3, 1);
      break;
    case XenraCurveDecelerate16:
      first = CGPointMake(1.0 / 3, 1.067), second = CGPointMake(2.0 / 3, 1);
      break;
    case XenraCurveQuint:
      first = CGPointMake(0.23, 1), second = CGPointMake(0.32, 1);
      break;
    case XenraCurveEaseInOut:
      first = CGPointMake(0.42, 0), second = CGPointMake(0.58, 1);
      break;
  }
  UIViewPropertyAnimator* animator =
      [[UIViewPropertyAnimator alloc] initWithDuration:duration
                                         controlPoint1:first
                                         controlPoint2:second
                                            animations:animations];
  if (done) {
    [animator addCompletion:^(UIViewAnimatingPosition) {
      done();
    }];
  }
  [animator startAnimationAfterDelay:delay];
}

void XenraEnter(NSArray<UIView*>* views, CGFloat dx, CGFloat dy,
                NSTimeInterval delay, NSTimeInterval stagger,
                NSTimeInterval duration, XenraCurve curve) {
  NSTimeInterval at = delay;
  for (UIView* view in views) {
    view.alpha = 0;
    view.transform = CGAffineTransformMakeTranslation(dx, dy);
    XenraAnimate(duration, at, curve,
                 ^{
                   view.alpha = 1;
                   view.transform = CGAffineTransformIdentity;
                 },
                 nil);
    at += stagger;
  }
}

void XenraEnterScale(NSArray<UIView*>* views, CGFloat scale,
                     NSTimeInterval delay, NSTimeInterval stagger,
                     NSTimeInterval duration, XenraCurve curve) {
  NSTimeInterval at = delay;
  for (UIView* view in views) {
    view.alpha = 0;
    view.transform = CGAffineTransformMakeScale(scale, scale);
    XenraAnimate(duration, at, curve,
                 ^{
                   view.alpha = 1;
                   view.transform = CGAffineTransformIdentity;
                 },
                 nil);
    at += stagger;
  }
}

void XenraCrossfade(UIWindow* window, NSTimeInterval duration,
                    void (^change)(void)) {
  UIView* cover = [window snapshotViewAfterScreenUpdates:NO];
  change();
  if (!cover) return;
  [window addSubview:cover];
  XenraAnimate(duration, 0, XenraCurveEaseInOut,
               ^{
                 cover.alpha = 0;
               },
               ^{
                 [cover removeFromSuperview];
               });
}

// OvershootInterpolator(2): past the end by a little, then back.
static double Overshoot(double t) {
  const double u = t - 1;
  return u * u * (3 * u + 2) + 1;
}

static CGFloat ShownScale(UIView* view) {
  CALayer* shown = view.layer.presentationLayer ?: view.layer;
  return [[shown valueForKeyPath:@"transform.scale"] doubleValue];
}

void XenraSpringPress(UIView* view, BOOL pressed) {
  const CGFloat from = ShownScale(view);
  const CGFloat to = pressed ? 0.92 : 1;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  view.transform = pressed ? CGAffineTransformMakeScale(to, to)
                           : CGAffineTransformIdentity;
  if (pressed) {
    CABasicAnimation* down =
        [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    down.fromValue = @(from);
    down.toValue = @(to);
    down.duration = 0.1;
    down.timingFunction =
        [CAMediaTimingFunction functionWithControlPoints:0.4:0:0.2:1];
    [view.layer addAnimation:down forKey:@"xenra.spring"];
  } else {
    // Sampled, because no timing function can pass its end value.
    CAKeyframeAnimation* back =
        [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
    NSMutableArray* values = [NSMutableArray array];
    for (int i = 0; i <= 24; i++) {
      [values addObject:@(from + (to - from) * Overshoot(i / 24.0))];
    }
    back.values = values;
    back.duration = 0.4;
    [view.layer addAnimation:back forKey:@"xenra.spring"];
  }
  [CATransaction commit];
}

void XenraAddSpring(UIControl* control) {
  __weak UIControl* weak = control;
  [control addAction:[UIAction actionWithHandler:^(UIAction*) {
             XenraSpringPress(weak, YES);
           }]
      forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
  [control addAction:[UIAction actionWithHandler:^(UIAction*) {
             XenraSpringPress(weak, NO);
           }]
      forControlEvents:UIControlEventTouchUpInside |
                       UIControlEventTouchUpOutside |
                       UIControlEventTouchDragExit |
                       UIControlEventTouchCancel];
}

@implementation UIViewController (XenraEdgeBack)
- (BOOL)xenraAllowsEdgeBack {
  // In a game the left edge is the stick's, and leaving is the game menu's job.
  return ![self isKindOfClass:[XenraGameController class]];
}
@end

// slide_in_right over fade_out going in, fade_in under slide_out_right coming
// back. A game has no page to slide: its screen is black until the first frame,
// so it fades in instead.
@interface XenraWindowTransition : NSObject <UIViewControllerAnimatedTransitioning>
@property(nonatomic, assign) BOOL push;
@property(nonatomic, assign) BOOL fade;
@end

@implementation XenraWindowTransition

- (NSTimeInterval)transitionDuration:
    (id<UIViewControllerContextTransitioning>)context {
  return _push ? 0.3 : 0.25;
}

- (void)animateTransition:(id<UIViewControllerContextTransitioning>)context {
  UIView* from = [context viewForKey:UITransitionContextFromViewKey];
  UIView* to = [context viewForKey:UITransitionContextToViewKey];
  UIViewController* target =
      [context viewControllerForKey:UITransitionContextToViewControllerKey];
  to.frame = [context finalFrameForViewController:target];
  UIView* container = context.containerView;
  // What shows through the fades. Left black, the light console dims as it moves.
  container.backgroundColor = XenraCharcoal();
  const BOOL rtl = container.effectiveUserInterfaceLayoutDirection ==
                   UIUserInterfaceLayoutDirectionRightToLeft;
  const CGFloat travel = container.bounds.size.width * (rtl ? -1 : 1);
  void (^finish)(void) = ^{
    from.alpha = 1;
    from.transform = CGAffineTransformIdentity;
    to.alpha = 1;
    to.transform = CGAffineTransformIdentity;
    [context completeTransition:!context.transitionWasCancelled];
  };
  if (context.isInteractive) {
    // UIPercentDrivenInteractiveTransition scrubs a plain animation of the
    // container's layers. Linear, so that the page stays under the finger; it
    // stays opaque too, since a page being held should not fade in the hand.
    [container insertSubview:to belowSubview:from];
    to.alpha = 0;
    [UIView animateWithDuration:[self transitionDuration:context]
        delay:0
        options:UIViewAnimationOptionCurveLinear
        animations:^{
          to.alpha = 1;
          from.transform = CGAffineTransformMakeTranslation(travel, 0);
        }
        completion:^(BOOL) {
          finish();
        }];
    return;
  }
  if (_push) {
    [container addSubview:to];
    to.alpha = 0;
    if (!_fade) to.transform = CGAffineTransformMakeTranslation(travel, 0);
    XenraAnimate(0.2, 0, XenraCurveStandard,
                 ^{
                   from.alpha = 0;
                 },
                 nil);
    XenraAnimate(0.3, 0, XenraCurveStandard,
                 ^{
                   to.alpha = 1;
                   to.transform = CGAffineTransformIdentity;
                 },
                 finish);
  } else {
    [container insertSubview:to belowSubview:from];
    to.alpha = 0;
    XenraAnimate(0.25, 0, XenraCurveStandard,
                 ^{
                   to.alpha = 1;
                   from.alpha = 0;
                   if (!_fade) {
                     from.transform = CGAffineTransformMakeTranslation(travel, 0);
                   }
                 },
                 finish);
  }
}

@end

@interface XenraNavigationController () <UINavigationControllerDelegate,
                                         UIGestureRecognizerDelegate>
@end

@implementation XenraNavigationController {
  UIScreenEdgePanGestureRecognizer* edge_;
  UIPercentDrivenInteractiveTransition* drag_;
}

#ifdef XENRA_UITEST
- (id)tourDrag {
  return drag_;
}
- (void)setTourDrag:(id)drag {
  drag_ = drag;
}
#endif

- (void)viewDidLoad {
  [super viewDidLoad];
  self.navigationBarHidden = YES;
  self.delegate = self;
  self.overrideUserInterfaceStyle = XenraInterfaceStyle();
  self.view.backgroundColor = XenraCharcoal();
  // UIKit's own swipe only drives its own transition.
  self.interactivePopGestureRecognizer.enabled = NO;
  const BOOL rtl = self.view.effectiveUserInterfaceLayoutDirection ==
                   UIUserInterfaceLayoutDirectionRightToLeft;
  edge_ = [[UIScreenEdgePanGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(edgeMoved:)];
  edge_.edges = rtl ? UIRectEdgeRight : UIRectEdgeLeft;
  edge_.delegate = self;
  [self.view addGestureRecognizer:edge_];
  XenraPadNavStart();
}

// The window carries the style, so that pickers and share sheets presented over
// the app get it too; a controller's override stops at its own children.
- (void)viewWillLayoutSubviews {
  [super viewWillLayoutSubviews];
  UIWindow* window = self.view.window;
  if (window.rootViewController != self) return;
  window.overrideUserInterfaceStyle = XenraInterfaceStyle();
  window.backgroundColor = XenraCharcoal();
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer*)recognizer {
  if (recognizer != edge_) return YES;
  UIViewController* top = self.topViewController;
  return self.viewControllers.count > 1 && !self.transitionCoordinator &&
         top.xenraAllowsEdgeBack && ![XenraBladeSheet topSheetIn:top.view];
}

// A swipe that starts at the very edge is the swipe, not a scroll.
- (BOOL)gestureRecognizer:(UIGestureRecognizer*)recognizer
    shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer*)other {
  return recognizer == edge_ && [other.view isKindOfClass:[UIScrollView class]];
}

- (void)edgeMoved:(UIScreenEdgePanGestureRecognizer*)pan {
  const CGFloat width = self.view.bounds.size.width;
  const CGFloat sign = edge_.edges == UIRectEdgeRight ? -1 : 1;
  const CGFloat moved = [pan translationInView:self.view].x * sign;
  const CGFloat speed = [pan velocityInView:self.view].x * sign;
  const CGFloat progress = MAX(0, MIN(1, moved / width));
  switch (pan.state) {
    case UIGestureRecognizerStateBegan:
      drag_ = [[UIPercentDrivenInteractiveTransition alloc] init];
      drag_.completionCurve = UIViewAnimationCurveEaseOut;
      [self popViewControllerAnimated:YES];
      break;
    case UIGestureRecognizerStateChanged:
      [drag_ updateInteractiveTransition:progress];
      break;
    case UIGestureRecognizerStateEnded:
      if ((progress > 0.35 && speed > -200) || speed > 600) {
        [drag_ finishInteractiveTransition];
      } else {
        [drag_ cancelInteractiveTransition];
      }
      drag_ = nil;
      break;
    default:
      [drag_ cancelInteractiveTransition];
      drag_ = nil;
      break;
  }
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
  NSString* lock = [XenraSettings stringForKey:@"ui.orientation"
                                      fallback:@"auto"];
  if ([lock isEqual:@"portrait"]) return UIInterfaceOrientationMaskPortrait;
  if ([lock isEqual:@"landscape"]) return UIInterfaceOrientationMaskLandscape;
  return UIInterfaceOrientationMaskAll;
}

// A game asks for the home bar to hide; without this nothing passes it up.
- (UIViewController*)childViewControllerForHomeIndicatorAutoHidden {
  return self.topViewController;
}

- (id<UIViewControllerAnimatedTransitioning>)
               navigationController:(UINavigationController*)navigation
    animationControllerForOperation:(UINavigationControllerOperation)operation
                 fromViewController:(UIViewController*)from
                   toViewController:(UIViewController*)to {
  XenraWindowTransition* transition = [[XenraWindowTransition alloc] init];
  transition.push = operation == UINavigationControllerOperationPush;
  transition.fade = [to isKindOfClass:[XenraGameController class]] ||
                    [from isKindOfClass:[XenraGameController class]];
  return transition;
}

- (id<UIViewControllerInteractiveTransitioning>)
                       navigationController:(UINavigationController*)navigation
    interactionControllerForAnimationController:
        (id<UIViewControllerAnimatedTransitioning>)animation {
  return drag_;
}

- (void)navigationController:(UINavigationController*)navigation
       didShowViewController:(UIViewController*)controller
                    animated:(BOOL)animated {
  XenraLog([NSString stringWithFormat:@"screen: %@", controller.class]);
  XenraPadNavScreenChanged();
  // The game wants the audio hardware to itself.
  if ([controller isKindOfClass:[XenraGameController class]]) {
    XenraUiSoundsRelease();
  }
  // The music belongs to the menus. Android stops it from onPause.
  // The free skin's wizard has none either.
  if ([controller isKindOfClass:[XenraGameController class]] ||
      [controller isKindOfClass:[XenraSetupController class]]) {
    XenraAmbientStop();
  } else {
    XenraAmbientStart();
  }
}

@end

#ifdef XENRA_UITEST
@implementation XenraNavigationController (Tour)
- (void)tourDragBegin {
  UIPercentDrivenInteractiveTransition* drag =
      [[UIPercentDrivenInteractiveTransition alloc] init];
  drag.completionCurve = UIViewAnimationCurveEaseOut;
  [self setValue:drag forKey:@"tourDrag"];
  [self popViewControllerAnimated:YES];
}
- (void)tourDragTo:(CGFloat)progress {
  [[self valueForKey:@"tourDrag"] updateInteractiveTransition:progress];
}
- (void)tourDragEnd:(BOOL)finish {
  id drag = [self valueForKey:@"tourDrag"];
  if (finish) {
    [drag finishInteractiveTransition];
  } else {
    [drag cancelInteractiveTransition];
  }
  [self setValue:nil forKey:@"tourDrag"];
}
@end
#endif
