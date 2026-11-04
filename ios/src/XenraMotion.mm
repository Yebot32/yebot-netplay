#import "XenraMotion.h"

#import "XenraAmbient.h"
#import "XenraScreens.h"
#import "XenraSettings.h"

void XenraAnimate(NSTimeInterval duration, NSTimeInterval delay,
                  XenraCurve curve, void (^animations)(void),
                  void (^done)(void)) {
  CGPoint first, second;
  switch (curve) {
    case XenraCurveStandard:
      first = CGPointMake(0.4, 0), second = CGPointMake(0.2, 1);
      break;
    case XenraCurveDecelerate:
      first = CGPointMake(0, 0), second = CGPointMake(0.2, 1);
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

void XenraAddSpring(UIControl* control) {
  __weak UIControl* weak = control;
  [control addAction:[UIAction actionWithHandler:^(UIAction*) {
             XenraAnimate(0.1, 0, XenraCurveStandard,
                          ^{
                            weak.transform =
                                CGAffineTransformMakeScale(0.92, 0.92);
                          },
                          nil);
           }]
      forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
  [control addAction:[UIAction actionWithHandler:^(UIAction*) {
             [UIView animateWithDuration:0.3
                                   delay:0
                  usingSpringWithDamping:0.55
                   initialSpringVelocity:0
                                 options:UIViewAnimationOptionAllowUserInteraction
                              animations:^{
                                weak.transform = CGAffineTransformIdentity;
                              }
                              completion:nil];
           }]
      forControlEvents:UIControlEventTouchUpInside |
                       UIControlEventTouchUpOutside |
                       UIControlEventTouchDragExit |
                       UIControlEventTouchCancel];
}

// slide_in_right over fade_out going in, fade_in under slide_out_right coming
// back.
@interface XenraWindowTransition : NSObject <UIViewControllerAnimatedTransitioning>
@property(nonatomic, assign) BOOL push;
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
  const CGFloat width = context.containerView.bounds.size.width;
  void (^finish)(void) = ^{
    from.alpha = 1;
    from.transform = CGAffineTransformIdentity;
    [context completeTransition:!context.transitionWasCancelled];
  };
  if (_push) {
    [context.containerView addSubview:to];
    to.alpha = 0;
    to.transform = CGAffineTransformMakeTranslation(width, 0);
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
    [context.containerView insertSubview:to belowSubview:from];
    to.alpha = 0;
    XenraAnimate(0.25, 0, XenraCurveStandard,
                 ^{
                   to.alpha = 1;
                   from.alpha = 0;
                   from.transform = CGAffineTransformMakeTranslation(width, 0);
                 },
                 finish);
  }
}

@end

@interface XenraNavigationController () <UINavigationControllerDelegate>
@end

@implementation XenraNavigationController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.navigationBarHidden = YES;
  self.delegate = self;
  // Custom transitions cannot follow a finger, and an edge swipe that does
  // nothing is better than one that half works. B goes back, as on Android.
  self.interactivePopGestureRecognizer.enabled = NO;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
  NSString* lock = [XenraSettings stringForKey:@"ui.orientation"
                                      fallback:@"auto"];
  if ([lock isEqual:@"portrait"]) return UIInterfaceOrientationMaskPortrait;
  if ([lock isEqual:@"landscape"]) return UIInterfaceOrientationMaskLandscape;
  return UIInterfaceOrientationMaskAll;
}

- (id<UIViewControllerAnimatedTransitioning>)
               navigationController:(UINavigationController*)navigation
    animationControllerForOperation:(UINavigationControllerOperation)operation
                 fromViewController:(UIViewController*)from
                   toViewController:(UIViewController*)to {
  XenraWindowTransition* transition = [[XenraWindowTransition alloc] init];
  transition.push = operation == UINavigationControllerOperationPush;
  return transition;
}

- (void)navigationController:(UINavigationController*)navigation
       didShowViewController:(UIViewController*)controller
                    animated:(BOOL)animated {
  XenraLog([NSString stringWithFormat:@"screen: %@", controller.class]);
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
