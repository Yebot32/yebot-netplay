#import "XenraPadNav.h"
#import "XenraStrings.h"

#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIGestureRecognizerSubclass.h>

#include <cmath>

#import "XenraScreens.h"
#import "XenraTheme.h"
#import "XenraUI.h"
#import "XenraUiSounds.h"

namespace {

// ControllerNavigator.kt.
constexpr float kStickEnter = 0.5f;
constexpr float kStickRelease = 0.3f;
constexpr float kAxisDominance = 1.5f;
constexpr CFTimeInterval kRepeatDelay = 0.450;
constexpr CFTimeInterval kRepeatInterval = 0.250;
constexpr CFTimeInterval kStepThrottle = 0.160;
// BaseActivity.bringIntoView.
constexpr CGFloat kScrollMargin = 16;

enum Direction { kNone, kUp, kDown, kLeft, kRight };

struct PadState {
  int dx = 0, dy = 0;
  float sx = 0, sy = 0;
  bool a = false, b = false, x = false, y = false, lb = false, rb = false;

  bool Neutral() const {
    return !dx && !dy && fabsf(sx) < kStickRelease && fabsf(sy) < kStickRelease &&
           !a && !b && !x && !y && !lb && !rb;
  }
};

PadState PollControllers(void) {
  PadState state;
  for (GCController* controller in GCController.controllers) {
    GCExtendedGamepad* pad = controller.extendedGamepad;
    if (!pad) continue;
    if (pad.dpad.left.pressed) state.dx = -1;
    if (pad.dpad.right.pressed) state.dx = 1;
    if (pad.dpad.up.pressed) state.dy = -1;
    if (pad.dpad.down.pressed) state.dy = 1;
    const float x = pad.leftThumbstick.xAxis.value;
    const float y = -pad.leftThumbstick.yAxis.value;  // up is positive there
    if (fabsf(x) > fabsf(state.sx)) state.sx = x;
    if (fabsf(y) > fabsf(state.sy)) state.sy = y;
    state.a = state.a || pad.buttonA.pressed;
    state.b = state.b || pad.buttonB.pressed;
    state.x = state.x || pad.buttonX.pressed;
    state.y = state.y || pad.buttonY.pressed;
    state.lb = state.lb || pad.leftShoulder.pressed;
    state.rb = state.rb || pad.rightShoulder.pressed;
  }
  return state;
}

Direction HatDirection(const PadState& state) {
  if (state.dy < 0) return kUp;
  if (state.dy > 0) return kDown;
  if (state.dx < 0) return kLeft;
  if (state.dx > 0) return kRight;
  return kNone;
}

// ControllerNavigator.StickState. Harder to enter a direction than to stay in it,
// and an axis has to beat the other clearly, so a diagonal does nothing.
Direction StickDirection(const PadState& state, Direction& held) {
  const float x = state.sx;
  const float y = state.sy;
  if (held != kNone) {
    const float travel = held == kUp     ? -y
                         : held == kDown ? y
                         : held == kLeft ? -x
                                         : x;
    if (travel >= kStickRelease) return held;
  }
  const bool vertical = fabsf(y) >= fabsf(x) * kAxisDominance;
  const bool horizontal = fabsf(x) >= fabsf(y) * kAxisDominance;
  if (vertical && y <= -kStickEnter) {
    held = kUp;
  } else if (vertical && y >= kStickEnter) {
    held = kDown;
  } else if (horizontal && x <= -kStickEnter) {
    held = kLeft;
  } else if (horizontal && x >= kStickEnter) {
    held = kRight;
  } else {
    held = kNone;
  }
  return held;
}

// android.view.FocusFinder, for the four directions.
bool IsCandidate(const CGRect& src, const CGRect& dest, Direction direction) {
  switch (direction) {
    case kLeft:
      return (CGRectGetMaxX(src) > CGRectGetMaxX(dest) ||
              CGRectGetMinX(src) >= CGRectGetMaxX(dest)) &&
             CGRectGetMinX(src) > CGRectGetMinX(dest);
    case kRight:
      return (CGRectGetMinX(src) < CGRectGetMinX(dest) ||
              CGRectGetMaxX(src) <= CGRectGetMinX(dest)) &&
             CGRectGetMaxX(src) < CGRectGetMaxX(dest);
    case kUp:
      return (CGRectGetMaxY(src) > CGRectGetMaxY(dest) ||
              CGRectGetMinY(src) >= CGRectGetMaxY(dest)) &&
             CGRectGetMinY(src) > CGRectGetMinY(dest);
    case kDown:
      return (CGRectGetMinY(src) < CGRectGetMinY(dest) ||
              CGRectGetMaxY(src) <= CGRectGetMinY(dest)) &&
             CGRectGetMaxY(src) < CGRectGetMaxY(dest);
    default:
      return false;
  }
}

bool BeamsOverlap(Direction direction, const CGRect& a, const CGRect& b) {
  if (direction == kLeft || direction == kRight) {
    return CGRectGetMaxY(b) > CGRectGetMinY(a) &&
           CGRectGetMinY(b) < CGRectGetMaxY(a);
  }
  return CGRectGetMaxX(b) > CGRectGetMinX(a) &&
         CGRectGetMinX(b) < CGRectGetMaxX(a);
}

bool IsToDirectionOf(Direction direction, const CGRect& src, const CGRect& dest) {
  switch (direction) {
    case kLeft:
      return CGRectGetMinX(src) >= CGRectGetMaxX(dest);
    case kRight:
      return CGRectGetMaxX(src) <= CGRectGetMinX(dest);
    case kUp:
      return CGRectGetMinY(src) >= CGRectGetMaxY(dest);
    default:
      return CGRectGetMaxY(src) <= CGRectGetMinY(dest);
  }
}

CGFloat MajorDistance(Direction direction, const CGRect& src, const CGRect& dest) {
  CGFloat distance;
  switch (direction) {
    case kLeft:
      distance = CGRectGetMinX(src) - CGRectGetMaxX(dest);
      break;
    case kRight:
      distance = CGRectGetMinX(dest) - CGRectGetMaxX(src);
      break;
    case kUp:
      distance = CGRectGetMinY(src) - CGRectGetMaxY(dest);
      break;
    default:
      distance = CGRectGetMinY(dest) - CGRectGetMaxY(src);
      break;
  }
  return distance > 0 ? distance : 0;
}

CGFloat MajorDistanceToFarEdge(Direction direction, const CGRect& src,
                               const CGRect& dest) {
  CGFloat distance;
  switch (direction) {
    case kLeft:
      distance = CGRectGetMinX(src) - CGRectGetMinX(dest);
      break;
    case kRight:
      distance = CGRectGetMaxX(dest) - CGRectGetMaxX(src);
      break;
    case kUp:
      distance = CGRectGetMinY(src) - CGRectGetMinY(dest);
      break;
    default:
      distance = CGRectGetMaxY(dest) - CGRectGetMaxY(src);
      break;
  }
  return distance > 1 ? distance : 1;
}

CGFloat MinorDistance(Direction direction, const CGRect& src, const CGRect& dest) {
  if (direction == kLeft || direction == kRight) {
    return fabs(CGRectGetMidY(src) - CGRectGetMidY(dest));
  }
  return fabs(CGRectGetMidX(src) - CGRectGetMidX(dest));
}

bool BeamBeats(Direction direction, const CGRect& src, const CGRect& a,
               const CGRect& b) {
  const bool aInBeam = BeamsOverlap(direction, src, a);
  const bool bInBeam = BeamsOverlap(direction, src, b);
  if (bInBeam || !aInBeam) return false;
  if (!IsToDirectionOf(direction, src, b)) return true;
  if (direction == kLeft || direction == kRight) return true;
  return MajorDistance(direction, src, a) <
         MajorDistanceToFarEdge(direction, src, b);
}

CGFloat Weighted(Direction direction, const CGRect& src, const CGRect& dest) {
  const CGFloat major = MajorDistance(direction, src, dest);
  const CGFloat minor = MinorDistance(direction, src, dest);
  return 13 * major * major + minor * minor;
}

bool IsBetter(Direction direction, const CGRect& src, const CGRect& a,
              const CGRect& b) {
  if (!IsCandidate(src, a, direction)) return false;
  if (!IsCandidate(src, b, direction)) return true;
  if (BeamBeats(direction, src, a, b)) return true;
  if (BeamBeats(direction, src, b, a)) return false;
  return Weighted(direction, src, a) < Weighted(direction, src, b);
}

}  // namespace

// One place the cursor can be: a control, or a cell by index path, since a cell
// is recycled from under anything that holds on to it.
@interface XenraPadSpot : NSObject
@property(nonatomic, weak) UIView* view;
@property(nonatomic, weak) UICollectionView* collection;
@property(nonatomic, strong) NSIndexPath* path;
@property(nonatomic, weak) UIScrollView* scroller;
@property(nonatomic, assign) CGRect frame;  // in the window
@property(nonatomic, assign) BOOL clipped;  // mostly scrolled out of sight
- (BOOL)isSameSpot:(XenraPadSpot*)other;
- (UIView*)shownView;  // nil for a cell that is off screen
- (CGRect)currentFrame;
@end

@implementation XenraPadSpot

- (BOOL)isSameSpot:(XenraPadSpot*)other {
  if (!other) return NO;
  if (_path) {
    return other.collection == _collection && [other.path isEqual:_path];
  }
  return _view && other.view == _view;
}

- (UIView*)shownView {
  if (_path) return [_collection cellForItemAtIndexPath:_path];
  return _view;
}

- (CGRect)currentFrame {
  if (_path) {
    UICollectionViewLayoutAttributes* attributes =
        [_collection.collectionViewLayout
            layoutAttributesForItemAtIndexPath:_path];
    if (!attributes) return _frame;
    return [_collection convertRect:attributes.frame toView:nil];
  }
  UIView* view = _view;
  return view ? [view convertRect:view.bounds toView:nil] : _frame;
}

@end

static UIScrollView* NearestScroller(UIView* view, UIView* root) {
  for (UIView* parent = view.superview; parent; parent = parent.superview) {
    if ([parent isKindOfClass:[UIScrollView class]]) return (UIScrollView*)parent;
    if (parent == root) break;
  }
  return nil;
}

// `from` included, for a cell, whose collection does the clipping.
static BOOL IsClipped(CGRect frame, UIView* from, UIView* root) {
  CGRect visible = frame;
  for (UIView* view = from; view; view = view.superview) {
    if ([view isKindOfClass:[UIScrollView class]]) {
      visible = CGRectIntersection(visible, [view convertRect:view.bounds
                                                       toView:nil]);
    }
    if (view == root) break;
  }
  if (CGRectIsNull(visible)) return YES;
  const CGFloat area = frame.size.width * frame.size.height;
  return visible.size.width * visible.size.height < area * 0.25;
}

static void AddControl(UIView* view, UIView* root, NSMutableArray* out) {
  if (view.bounds.size.width < 1 || view.bounds.size.height < 1) return;
  XenraPadSpot* spot = [[XenraPadSpot alloc] init];
  spot.view = view;
  spot.frame = [view convertRect:view.bounds toView:nil];
  spot.scroller = NearestScroller(view, root);
  spot.clipped = IsClipped(spot.frame, view.superview, root);
  [out addObject:spot];
}

// A screen's worth either side, so the cursor can step onto a row that has not
// been built yet, and the scroll then brings it.
static void AddCells(UICollectionView* collection, UIView* root,
                     NSMutableArray* out) {
  const CGRect bounds = collection.bounds;
  const CGRect reach =
      CGRectInset(bounds, -bounds.size.width, -bounds.size.height);
  NSArray<UICollectionViewLayoutAttributes*>* elements =
      [collection.collectionViewLayout layoutAttributesForElementsInRect:reach];
  NSMutableArray<UICollectionViewLayoutAttributes*>* cells = [NSMutableArray array];
  for (UICollectionViewLayoutAttributes* element in elements) {
    if (element.representedElementCategory == UICollectionElementCategoryCell &&
        !element.hidden) {
      [cells addObject:element];
    }
  }
  [cells sortUsingComparator:^NSComparisonResult(
             UICollectionViewLayoutAttributes* a,
             UICollectionViewLayoutAttributes* b) {
    return [a.indexPath compare:b.indexPath];
  }];
  for (UICollectionViewLayoutAttributes* cell in cells) {
    XenraPadSpot* spot = [[XenraPadSpot alloc] init];
    spot.collection = collection;
    spot.path = cell.indexPath;
    spot.scroller = collection;
    spot.frame = [collection convertRect:cell.frame toView:nil];
    spot.clipped = IsClipped(spot.frame, collection, root);
    [out addObject:spot];
  }
}

// `fading` counts what is clear for now: a pane that was just rebuilt starts at
// nothing and fades in.
static void Walk(UIView* view, UIView* root, BOOL fading, NSMutableArray* out) {
  if (view.hidden || !view.userInteractionEnabled) return;
  if (!fading && view.alpha < 0.01) return;
  if ([view isKindOfClass:[UIControl class]]) {
    if (!((UIControl*)view).enabled) return;
    if ([view isKindOfClass:[XenraPressControl class]] &&
        ((XenraPressControl*)view).padSkipped) {
      return;
    }
    AddControl(view, root, out);
    return;
  }
  if ([view isKindOfClass:[UICollectionView class]]) {
    AddCells((UICollectionView*)view, root, out);
    // Headers are subviews too, and may hold controls.
    for (UIView* child in view.subviews) {
      if (![child isKindOfClass:[UICollectionViewCell class]]) {
        Walk(child, root, fading, out);
      }
    }
    return;
  }
  for (UIView* child in view.subviews) Walk(child, root, fading, out);
}

static NSArray<XenraPadSpot*>* Collect(UIView* root, BOOL fading = NO) {
  NSMutableArray<XenraPadSpot*>* spots = [NSMutableArray array];
  if (root) Walk(root, root, fading, spots);
  return spots;
}

// Still somewhere the cursor can sit. Not alpha: a pane fades in around it.
static BOOL IsAlive(XenraPadSpot* spot, UIView* root) {
  UICollectionView* collection = spot.collection;
  UIView* view = spot.path ? collection : spot.view;
  if (!view.window) return NO;
  if ([view isKindOfClass:[UIControl class]] && !((UIControl*)view).enabled) {
    return NO;
  }
  if (spot.path) {
    if (spot.path.section >= collection.numberOfSections ||
        spot.path.item >= [collection numberOfItemsInSection:spot.path.section]) {
      return NO;
    }
  }
  for (; view; view = view.superview) {
    if (view.hidden || !view.userInteractionEnabled) return NO;
    if (view == root) return YES;
  }
  return NO;
}

static XenraBladeSheet* FindSheet(UIView* view, int depth) {
  for (UIView* child in view.subviews.reverseObjectEnumerator) {
    if ([child isKindOfClass:[XenraBladeSheet class]]) {
      // It says whether this one is on its way out.
      XenraBladeSheet* sheet = [XenraBladeSheet topSheetIn:view];
      if (sheet) return sheet;
      continue;
    }
    if (depth <= 0 || [child isKindOfClass:[UIScrollView class]] ||
        [child isKindOfClass:[UIControl class]]) {
      continue;
    }
    XenraBladeSheet* sheet = FindSheet(child, depth - 1);
    if (sheet) return sheet;
  }
  return nil;
}

static XenraHintBar* FindHintBar(UIView* view) {
  if (view.hidden) return nil;
  if ([view isKindOfClass:[XenraHintBar class]]) return (XenraHintBar*)view;
  if ([view isKindOfClass:[UIScrollView class]] ||
      [view isKindOfClass:[UIControl class]]) {
    return nil;
  }
  for (UIView* child in view.subviews) {
    XenraHintBar* bar = FindHintBar(child);
    if (bar) return bar;
  }
  return nil;
}

// Any press control with a `chosen` property, which is what a tab is.
static XenraPressControl* FindChosenBlade(UIView* view) {
  if (view.hidden) return nil;
  if ([view isKindOfClass:[XenraPressControl class]]) {
    const BOOL tab = [view respondsToSelector:@selector(chosen)];
    return tab && [(XenraBladeButton*)view chosen] ? (XenraPressControl*)view : nil;
  }
  for (UIView* child in view.subviews) {
    XenraPressControl* blade = FindChosenBlade(child);
    if (blade) return blade;
  }
  return nil;
}

static UIWindow* MainWindow(void) {
  return UIApplication.sharedApplication.delegate.window;
}

static UINavigationController* MainStack(UIWindow* window) {
  UIViewController* root = window.rootViewController;
  if ([root isKindOfClass:[UINavigationController class]]) {
    return (UINavigationController*)root;
  }
  return nil;
}

// Nil while a system picker or share sheet is up. Those run out of process, and
// nothing here can reach into them.
static UIViewController* TopController(UIWindow* window) {
  UIViewController* root = window.rootViewController;
  if (root.presentedViewController) return nil;
  UINavigationController* stack = MainStack(window);
  if (stack) return stack.topViewController;
  return root;
}

static BOOL DrawsOwnFocus(UIView* view) {
  return ![view isKindOfClass:[XenraPressControl class]] &&
         [view respondsToSelector:@selector(setPadFocused:)];
}

static void Light(UIView* view, BOOL on) {
  if (!view) return;
  if ([view isKindOfClass:[XenraPressControl class]] || DrawsOwnFocus(view)) {
    [(XenraPressControl*)view setPadFocused:on];
  } else {
    XenraPadRing(view, on);
  }
}

static void ScrollInto(UIView* view, CGRect rect) {
  for (UIView* parent = view; parent; parent = parent.superview) {
    if (![parent isKindOfClass:[UIScrollView class]]) continue;
    UIScrollView* scroller = (UIScrollView*)parent;
    CGRect wanted = CGRectInset([view convertRect:rect toView:scroller],
                                -kScrollMargin, -kScrollMargin);
    const CGSize content = scroller.contentSize;
    wanted = CGRectIntersection(wanted,
                                CGRectMake(0, 0, content.width, content.height));
    if (!CGRectIsNull(wanted)) [scroller scrollRectToVisible:wanted animated:YES];
  }
}

static void BringIntoView(XenraPadSpot* spot) {
  if (spot.path) {
    UICollectionView* collection = spot.collection;
    UICollectionViewLayoutAttributes* attributes =
        [collection.collectionViewLayout
            layoutAttributesForItemAtIndexPath:spot.path];
    if (attributes) ScrollInto(collection, attributes.frame);
    return;
  }
  UIView* view = spot.view;
  if (view) ScrollInto(view, view.bounds);
}

// A touch tells the cursor to go and takes no further part: failing at once, it
// holds nothing up and cancels nothing.
@interface XenraPadTouchWatch : UIGestureRecognizer
@end

@implementation XenraPadTouchWatch

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  XenraPadNavTouched();
  self.state = UIGestureRecognizerStateFailed;
}

@end

@interface XenraPadEngine : NSObject
+ (instancetype)shared;
- (void)start;
- (void)updatePolling;
- (void)clearCursor;
- (UIView*)focusedView;
#ifdef XENRA_UITEST
- (NSString*)focusName;
- (BOOL)polling;
#endif
@end

@implementation XenraPadEngine {
  CADisplayLink* link_;
  __weak UIWindow* watched_;
  __weak UIView* root_;
  __weak UIView* lit_;
  XenraPadSpot* focused_;
  XenraPadSpot* pressing_;                      // A is down on it
  NSMapTable<UIView*, XenraPadSpot*>* memory_;  // where the cursor was, per root
  PadState previous_;
  Direction stickHeld_;
  Direction moving_;
  CFTimeInterval nextStep_;
  CFTimeInterval lastStep_;
  BOOL waitForNeutral_;  // what is held from before does not count as a press
#ifdef XENRA_UITEST
 @public
  BOOL testing_;
  PadState testState_;
#endif
}

+ (instancetype)shared {
  static XenraPadEngine* engine;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    engine = [[XenraPadEngine alloc] init];
  });
  return engine;
}

- (void)start {
  if (link_) return;
  memory_ = [NSMapTable weakToStrongObjectsMapTable];
  link_ = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
  link_.preferredFramesPerSecond = 60;
  link_.paused = YES;
  // Common modes: a scroll under way must not stop the pad.
  [link_ addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
  for (NSNotificationName name in @[
         GCControllerDidConnectNotification, GCControllerDidDisconnectNotification
       ]) {
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(updatePolling)
                                               name:name
                                             object:nil];
  }
  [self updatePolling];
}

- (BOOL)hasInput {
#ifdef XENRA_UITEST
  if (testing_) return YES;
#endif
  return GCController.controllers.count > 0;
}

// The game has the controller, unless a sheet is up on its screen: the menu and the
// failure notice need the cursor, and the guest is paused or never ran under them.
- (BOOL)gameOwnsController {
  UIWindow* window = MainWindow();
  UIViewController* top = TopController(window);
  if (![top isKindOfClass:[XenraGameController class]]) return NO;
  return !FindSheet(top.view, 5);
}

- (void)updatePolling {
  const BOOL poll = [self hasInput] && ![self gameOwnsController];
  if (!poll) [self standDown];
  link_.paused = !poll;
}

- (PadState)readState {
#ifdef XENRA_UITEST
  if (testing_) return testState_;
#endif
  return PollControllers();
}

// Nothing carries over from before: not the cursor, and not a press.
- (void)standDown {
  [self cancelPress];
  [self clearCursor];
  root_ = nil;
  moving_ = kNone;
  stickHeld_ = kNone;
  waitForNeutral_ = YES;
}

- (void)tick {
  UIWindow* window = MainWindow();
  if (window != watched_) {
    watched_ = window;
    XenraPadTouchWatch* watch = [[XenraPadTouchWatch alloc] init];
    watch.cancelsTouchesInView = NO;
    watch.delaysTouchesBegan = NO;
    watch.delaysTouchesEnded = NO;
    [window addGestureRecognizer:watch];
  }

  UIViewController* top = TopController(window);
  if ([self gameOwnsController]) {
    // didShowViewController, or a sheet going up, wakes this again.
    [self standDown];
    link_.paused = YES;
    return;
  }
  if (!top || UIApplication.sharedApplication.applicationState !=
                  UIApplicationStateActive) {
    [self standDown];
    return;
  }

  UIView* root = [self rootFor:top inWindow:window];
  if (root != root_) [self moveToRoot:root];

  const PadState state = [self readState];
  if (MainStack(window).transitionCoordinator) {
    [self cancelPress];
    moving_ = kNone;
    previous_ = state;
    return;
  }
  if (focused_ && !IsAlive(focused_, root_)) [self recoverCursor];
  [self keepLit];

  if (waitForNeutral_) {
    if (state.Neutral()) waitForNeutral_ = NO;
    previous_ = state;
    return;
  }
  [self handleButtons:state on:top inWindow:window];
  [self handleDirection:state on:top];
  previous_ = state;
}

- (UIView*)rootFor:(UIViewController*)top inWindow:(UIWindow*)window {
  // A screen's sheets sit in its view, the odd one in the window.
  XenraBladeSheet* sheet = FindSheet(top.view, 5);
  if (!sheet) sheet = FindSheet(window, 0);
  if (sheet) return sheet;
  return top.view;
}

// The cursor belongs to one root. Coming back to one it was on puts it back, as
// Android's focus stays with a window; a new one waits for the first input.
- (void)moveToRoot:(UIView*)root {
  const BOOL shown = focused_ != nil;
  [self cancelPress];
  [self clearCursor];
  root_ = root;
  if (shown && [memory_ objectForKey:root]) [self placeCursorWithSound:NO];
}

// The row it was on was rebuilt or went away. The nearest one takes over, in the
// same scroller if it can: a row of a rebuilt pane can be further off than the
// close arrow beside it, and the cursor should not leave the pane.
- (void)recoverCursor {
  const CGRect was = focused_.frame;
  UIScrollView* scroller = focused_.scroller;
  [self clearCursor];
  NSArray<XenraPadSpot*>* spots = Collect(root_, YES);
  NSMutableArray<XenraPadSpot*>* neighbours = [NSMutableArray array];
  for (XenraPadSpot* spot in spots) {
    if (scroller && spot.scroller == scroller) [neighbours addObject:spot];
  }
  XenraPadSpot* nearest =
      [self nearestIn:neighbours.count ? neighbours : spots to:was];
  if (nearest) [self moveCursorTo:nearest sound:NO scroll:NO];
}

- (XenraPadSpot*)nearestIn:(NSArray<XenraPadSpot*>*)spots to:(CGRect)frame {
  XenraPadSpot* best = nil;
  CGFloat bestDistance = CGFLOAT_MAX;
  for (XenraPadSpot* spot in spots) {
    if (spot.clipped) continue;
    const CGFloat dx = CGRectGetMidX(spot.frame) - CGRectGetMidX(frame);
    const CGFloat dy = CGRectGetMidY(spot.frame) - CGRectGetMidY(frame);
    const CGFloat distance = dx * dx + dy * dy;
    if (distance < bestDistance) {
      bestDistance = distance;
      best = spot;
    }
  }
  return best;
}

- (UIView*)focusedView {
  return focused_.view;
}

- (void)clearCursor {
  [self cancelPress];
  Light(lit_, NO);
  lit_ = nil;
  focused_ = nil;
}

- (void)moveCursorTo:(XenraPadSpot*)spot sound:(BOOL)sound scroll:(BOOL)scroll {
  [self cancelPress];
  Light(lit_, NO);
  lit_ = nil;
  focused_ = spot;
  UIView* root = root_;
  if (root) [memory_ setObject:spot forKey:root];
  [self keepLit];
  if (scroll) BringIntoView(spot);
  if (sound) XenraUiSoundsMove();
}

// A cell comes and goes as it scrolls, and a rotation resizes whatever has a ring.
- (void)keepLit {
  if (!focused_) return;
  UIView* view = focused_.shownView;
  UIView* lit = lit_;
  if (view != lit) {
    Light(lit, NO);
    lit_ = view;
    Light(view, YES);
  } else if (view && !DrawsOwnFocus(view)) {
    XenraPadRing(view, YES);
  }
}

- (BOOL)placeCursorWithSound:(BOOL)sound {
  NSArray<XenraPadSpot*>* spots = Collect(root_);
  if (!spots.count) return NO;
  XenraPadSpot* pick = nil;
  UIView* root = root_;
  XenraPadSpot* remembered = root ? [memory_ objectForKey:root] : nil;
  if (remembered) {
    for (XenraPadSpot* spot in spots) {
      if ([spot isSameSpot:remembered]) pick = spot;
    }
    if (!pick) pick = [self nearestIn:spots to:remembered.frame];
  }
  // A screen with tabs starts on the current one, not on what comes first, which
  // in settings is the close arrow: one A from leaving.
  if (!pick) {
    UIView* tab = FindChosenBlade(root);
    for (XenraPadSpot* spot in spots) {
      if (tab && spot.view == tab) pick = spot;
    }
  }
  if (!pick) {
    for (XenraPadSpot* spot in spots) {
      if (!spot.clipped) {
        pick = spot;
        break;
      }
    }
  }
  if (!pick) pick = spots.firstObject;
  [self moveCursorTo:pick sound:sound scroll:YES];
  return YES;
}

// Android's search, but a control scrolled out of sight only counts from inside
// its own scroller. From the tabs, Right means what can be seen.
- (XenraPadSpot*)searchFrom:(XenraPadSpot*)from direction:(Direction)direction {
  const CGRect source = [from currentFrame];
  CGRect best = source;
  switch (direction) {
    case kLeft:
      best = CGRectOffset(source, source.size.width + 1, 0);
      break;
    case kRight:
      best = CGRectOffset(source, -(source.size.width + 1), 0);
      break;
    case kUp:
      best = CGRectOffset(source, 0, source.size.height + 1);
      break;
    default:
      best = CGRectOffset(source, 0, -(source.size.height + 1));
      break;
  }
  XenraPadSpot* winner = nil;
  for (XenraPadSpot* spot in Collect(root_)) {
    if ([spot isSameSpot:from]) continue;
    if (spot.clipped && spot.scroller != from.scroller) continue;
    if (IsBetter(direction, source, spot.frame, best)) {
      best = spot.frame;
      winner = spot;
    }
  }
  return winner;
}

// Left and Right belong to a slider until it has nowhere left to go, as they do
// to Android's SeekBar. No cue: the thumb moving is the feedback.
- (BOOL)adjustFocused:(Direction)direction {
  if (direction != kLeft && direction != kRight) return NO;
  const int sign = direction == kRight ? 1 : -1;
  UIView* view = focused_.view;
  if ([view isKindOfClass:[UISlider class]]) {
    UISlider* slider = (UISlider*)view;
    float step = 0;
    for (UIView* parent = slider.superview; parent; parent = parent.superview) {
      if ([parent isKindOfClass:[XenraSliderRow class]]) {
        step = ((XenraSliderRow*)parent).step;
        break;
      }
    }
    if (step <= 0) step = (slider.maximumValue - slider.minimumValue) / 20;
    // A mirrored slider grows to the left, and the thumb should follow the press.
    const BOOL mirrored = slider.effectiveUserInterfaceLayoutDirection ==
                          UIUserInterfaceLayoutDirectionRightToLeft;
    const float next = fmaxf(slider.minimumValue,
                             fminf(slider.maximumValue,
                                   slider.value + (mirrored ? -sign : sign) * step));
    if (next == slider.value) return NO;
    slider.value = next;
    [slider sendActionsForControlEvents:UIControlEventValueChanged];
    [slider sendActionsForControlEvents:UIControlEventTouchUpInside];
    return YES;
  }
  if ([view isKindOfClass:[UISegmentedControl class]]) {
    UISegmentedControl* segments = (UISegmentedControl*)view;
    const NSInteger next = segments.selectedSegmentIndex + sign;
    if (next < 0 || next >= (NSInteger)segments.numberOfSegments) return NO;
    segments.selectedSegmentIndex = next;
    [segments sendActionsForControlEvents:UIControlEventValueChanged];
    return YES;
  }
  return NO;
}

// Nothing to step to, so the page itself moves, half a page at a time like
// Android's ScrollView. Text with no controls in it is reached this way.
- (void)scrollPage:(Direction)direction {
  UIScrollView* scroller = focused_.scroller;
  if (!scroller) scroller = [self biggestScrollerIn:root_];
  if (!scroller) return;
  const CGSize size = scroller.bounds.size;
  const UIEdgeInsets inset = scroller.adjustedContentInset;
  const CGSize content = scroller.contentSize;
  CGPoint offset = scroller.contentOffset;
  switch (direction) {
    case kUp:
      offset.y -= size.height / 2;
      break;
    case kDown:
      offset.y += size.height / 2;
      break;
    case kLeft:
      offset.x -= size.width / 2;
      break;
    default:
      offset.x += size.width / 2;
      break;
  }
  const CGFloat maxX = fmax(-inset.left, content.width + inset.right - size.width);
  const CGFloat maxY = fmax(-inset.top, content.height + inset.bottom - size.height);
  offset.x = fmax(-inset.left, fmin(offset.x, maxX));
  offset.y = fmax(-inset.top, fmin(offset.y, maxY));
  if (!CGPointEqualToPoint(offset, scroller.contentOffset)) {
    [scroller setContentOffset:offset animated:YES];
  }
}

- (UIScrollView*)biggestScrollerIn:(UIView*)view {
  if (view.hidden) return nil;
  UIScrollView* best = nil;
  if ([view isKindOfClass:[UIScrollView class]]) {
    UIScrollView* scroller = (UIScrollView*)view;
    if (scroller.contentSize.height > scroller.bounds.size.height + 1 ||
        scroller.contentSize.width > scroller.bounds.size.width + 1) {
      best = scroller;
    }
  }
  for (UIView* child in view.subviews) {
    UIScrollView* found = [self biggestScrollerIn:child];
    if (found && (!best || found.bounds.size.height * found.bounds.size.width >
                               best.bounds.size.height * best.bounds.size.width)) {
      best = found;
    }
  }
  return best;
}

- (void)navigate:(Direction)direction on:(UIViewController*)top {
  static const XenraPadButton kButtons[] = {
      XenraPadButtonUp, XenraPadButtonUp, XenraPadButtonDown, XenraPadButtonLeft,
      XenraPadButtonRight};
  if ([self offer:kButtons[direction] to:top]) return;
  if (!focused_) {
    if (![self placeCursorWithSound:YES]) [self scrollPage:direction];
    return;
  }
  if ([self adjustFocused:direction]) return;
  XenraPadSpot* next = [self searchFrom:focused_ direction:direction];
  if (next) {
    [self moveCursorTo:next sound:YES scroll:YES];
  } else {
    [self scrollPage:direction];
  }
}

// BaseActivity.startNavRepeat: the D-pad and the stick share one cadence.
- (void)handleDirection:(const PadState&)state on:(UIViewController*)top {
  Direction direction = HatDirection(state);
  if (direction == kNone) direction = StickDirection(state, stickHeld_);
  const CFTimeInterval now = CACurrentMediaTime();
  if (direction == kNone) {
    moving_ = kNone;
  } else if (direction != moving_) {
    moving_ = direction;
    nextStep_ = now + kRepeatDelay;
    if (now - lastStep_ >= kStepThrottle) {
      lastStep_ = now;
      [self navigate:direction on:top];
    }
  } else if (now >= nextStep_) {
    nextStep_ = now + kRepeatInterval;
    [self navigate:direction on:top];
  }
}

// The hook is for a screen; an open sheet is not the screen.
- (BOOL)offer:(XenraPadButton)button to:(UIViewController*)top {
  if (root_ != top.view) return NO;
  if (![top conformsToProtocol:@protocol(XenraPadScreen)]) return NO;
  return [(id<XenraPadScreen>)top xenraPadButton:button];
}

- (void)handleButtons:(const PadState&)state
                   on:(UIViewController*)top
             inWindow:(UIWindow*)window {
  if (state.b && !previous_.b) [self back:top inWindow:window];
  if (state.lb && !previous_.lb && ![self offer:XenraPadButtonLB to:top]) {
    [self shiftTab:-1];
  }
  if (state.rb && !previous_.rb && ![self offer:XenraPadButtonRB to:top]) {
    [self shiftTab:1];
  }
  if (state.x && !previous_.x) [self offer:XenraPadButtonX to:top];
  if (state.y && !previous_.y) [self offer:XenraPadButtonY to:top];

  if (state.a && !previous_.a) {
    if ([self offer:XenraPadButtonA to:top]) return;
    if (!focused_) {
      // Only places it: acting as well would feel like a skipped input.
      [self placeCursorWithSound:YES];
    } else {
      [self beginPress];
    }
  } else if (!state.a && previous_.a) {
    [self finishPress];
  }
}

// Android presses on the way down and clicks on the way up, and acting on release
// also means a new screen never sees A already held.
- (void)beginPress {
  pressing_ = focused_;
  UIView* view = [focused_ shownView];
  if (![view isKindOfClass:[UIControl class]]) return;
  UIControl* control = (UIControl*)view;
  control.highlighted = YES;
  [control sendActionsForControlEvents:UIControlEventTouchDown];
}

- (void)releasePress:(BOOL)cancelled {
  XenraPadSpot* spot = pressing_;
  pressing_ = nil;
  UIView* view = [spot shownView];
  if (![view isKindOfClass:[UIControl class]]) return;
  UIControl* control = (UIControl*)view;
  control.highlighted = NO;
  if (cancelled) [control sendActionsForControlEvents:UIControlEventTouchCancel];
}

- (void)cancelPress {
  if (pressing_) [self releasePress:YES];
}

- (void)finishPress {
  XenraPadSpot* spot = pressing_;
  if (!spot) return;
  [self releasePress:NO];
  [self activate:spot];
}

- (void)activate:(XenraPadSpot*)spot {
  if (spot.path) {
    UICollectionView* collection = spot.collection;
    id<UICollectionViewDelegate> delegate = collection.delegate;
    if ([delegate respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)]) {
      [delegate collectionView:collection didSelectItemAtIndexPath:spot.path];
    }
    return;
  }
  UIView* view = spot.view;
  if ([view isKindOfClass:[UISwitch class]]) {
    UISwitch* toggle = (UISwitch*)view;
    [toggle setOn:!toggle.on animated:YES];
    [toggle sendActionsForControlEvents:UIControlEventValueChanged];
  } else if ([view isKindOfClass:[UITextField class]]) {
    [view becomeFirstResponder];
  } else if ([view isKindOfClass:[UISlider class]] ||
             [view isKindOfClass:[UISegmentedControl class]]) {
    // Left and Right do these.
  } else if ([view isKindOfClass:[UIControl class]]) {
    [(UIControl*)view sendActionsForControlEvents:UIControlEventTouchUpInside];
  }
}

// In the order a finger would find them: the sheet's B, then the screen's.
- (void)back:(UIViewController*)top inWindow:(UIWindow*)window {
  UIView* field = focused_.view;
  if ([field isKindOfClass:[UITextField class]] && [field isFirstResponder]) {
    [field resignFirstResponder];
    return;
  }
  UIView* root = root_;
  if ([root isKindOfClass:[XenraBladeSheet class]]) {
    [(XenraBladeSheet*)root dismiss];
    return;
  }
  if ([self offer:XenraPadButtonB to:top]) return;
  XenraHintBar* hints = FindHintBar(top.view);
  if (hints.onBack) {
    hints.onBack();
    return;
  }
  // The setup wizard has no hint bar, but its pages have a Back pill.
  for (XenraPadSpot* spot in Collect(root)) {
    UIView* view = spot.view;
    if ([view isKindOfClass:[XenraPressControl class]] &&
        [((XenraPressControl*)view).title caseInsensitiveCompare:XS(@"Back")] ==
            NSOrderedSame) {
      [(XenraPressControl*)view
          sendActionsForControlEvents:UIControlEventTouchUpInside];
      return;
    }
  }
  UINavigationController* stack = MainStack(window);
  if (stack.viewControllers.count > 1) [stack popViewControllerAnimated:YES];
}

// What is marked chosen is the tab, and its stack holds the others.
- (void)shiftTab:(int)delta {
  UIView* root = root_;
  if ([root isKindOfClass:[XenraBladeSheet class]]) return;
  XenraPressControl* chosen = FindChosenBlade(root);
  if (![chosen.superview isKindOfClass:[UIStackView class]]) return;
  NSMutableArray<XenraPressControl*>* tabs = [NSMutableArray array];
  for (UIView* view in ((UIStackView*)chosen.superview).arrangedSubviews) {
    if (!view.hidden && [view isKindOfClass:[XenraPressControl class]]) {
      [tabs addObject:(XenraPressControl*)view];
    }
  }
  if (tabs.count < 2) return;
  const NSInteger count = (NSInteger)tabs.count;
  const NSInteger index = (NSInteger)[tabs indexOfObject:chosen];
  XenraPressControl* next = tabs[(index + delta + count) % count];
  const BOOL followed = focused_.view && focused_.view.superview == chosen.superview;
  [next sendActionsForControlEvents:UIControlEventTouchUpInside];
  if (followed) {
    for (XenraPadSpot* spot in Collect(root)) {
      if (spot.view == next) [self moveCursorTo:spot sound:YES scroll:YES];
    }
  } else {
    ScrollInto(next, next.bounds);
  }
}

#ifdef XENRA_UITEST
- (NSString*)focusName {
  if (!focused_) return nil;
  if (focused_.path) {
    return [NSString stringWithFormat:@"cell %ld", (long)focused_.path.item];
  }
  UIView* view = focused_.view;
  if ([view isKindOfClass:[XenraPressControl class]]) {
    NSString* title = ((XenraPressControl*)view).title;
    if (title) return title;
  }
  return NSStringFromClass(view.class);
}

- (BOOL)polling {
  return link_ && !link_.paused;
}
#endif

@end

void XenraPadNavStart(void) { [XenraPadEngine.shared start]; }

void XenraPadNavScreenChanged(void) { [XenraPadEngine.shared updatePolling]; }

void XenraPadNavTouched(void) { [XenraPadEngine.shared clearCursor]; }

UIView* XenraPadNavFocusedView(void) { return XenraPadEngine.shared.focusedView; }

// The ring of a control that has to stand outside its scroller. One cursor, so one.
static __weak CAShapeLayer* g_outerRing;

static CAShapeLayer* MakeRing(CALayer* host) {
  CAShapeLayer* ring = [CAShapeLayer layer];
  ring.fillColor = UIColor.clearColor.CGColor;
  ring.strokeColor = XenraFocus().CGColor;
  ring.lineWidth = 2;
  ring.zPosition = 1000;
  [host addSublayer:ring];
  return ring;
}

static void ShapeRing(CAShapeLayer* ring, CGRect frame, CGRect rect) {
  if (ring.path && CGRectEqualToRect(ring.frame, frame) &&
      CGRectEqualToRect(CGPathGetPathBoundingBox(ring.path), rect)) {
    return;
  }
  ring.frame = frame;
  ring.path = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:8].CGPath;
}

void XenraPadRing(UIView* view, BOOL on) {
  static NSString* const kName = @"xenra.pad.ring";
  CAShapeLayer* ring = nil;
  for (CALayer* layer in view.layer.sublayers) {
    if ([layer.name isEqual:kName]) ring = (CAShapeLayer*)layer;
  }
  CAShapeLayer* outer = g_outerRing;
  if (!on) {
    [ring removeFromSuperlayer];
    [outer removeFromSuperlayer];
    return;
  }
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  // Inside the bounds, as a foreground drawable is. A switch or a slider has no
  // padding of its own to sit in, so there the ring stands off. A row runs right up
  // to the sides of its scroller, which would cut the ring, so then it goes on what
  // holds the scroller and follows along from there.
  const BOOL standsOff = [view isKindOfClass:[UISwitch class]] ||
                         [view isKindOfClass:[UISlider class]] ||
                         [view isKindOfClass:[UISegmentedControl class]];
  if (standsOff) {
    // A slider's bounds are already taller than its thumb.
    const CGFloat dy = [view isKindOfClass:[UISlider class]] ? 0 : -5;
    const CGRect rect = CGRectInset(view.bounds, -5, dy);
    UIScrollView* scroller = NearestScroller(view, nil);
    const CGRect room =
        scroller ? [scroller convertRect:scroller.bounds toView:view] : rect;
    UIView* host = scroller.superview;
    if (host && (CGRectGetMinX(rect) < CGRectGetMinX(room) ||
                 CGRectGetMaxX(rect) > CGRectGetMaxX(room))) {
      [ring removeFromSuperlayer];
      if (!outer) {
        outer = MakeRing(host.layer);
        g_outerRing = outer;
      }
      ShapeRing(outer, host.bounds, [view convertRect:rect toView:host]);
      [CATransaction commit];
      return;
    }
    if (!ring) {
      ring = MakeRing(view.layer);
      ring.name = kName;
    }
    ShapeRing(ring, view.bounds, rect);
  } else {
    if (!ring) {
      ring = MakeRing(view.layer);
      ring.name = kName;
    }
    ShapeRing(ring, view.bounds, CGRectInset(view.bounds, 1, 1));
  }
  [CATransaction commit];
}

#ifdef XENRA_UITEST
void XenraPadNavTestSet(const XenraPadTestState* state) {
  XenraPadEngine* engine = XenraPadEngine.shared;
  engine->testing_ = state != nullptr;
  if (state) {
    PadState pad;
    pad.dx = state->dx;
    pad.dy = state->dy;
    pad.sx = state->sx;
    pad.sy = state->sy;
    pad.a = state->a;
    pad.b = state->b;
    pad.x = state->x;
    pad.y = state->y;
    pad.lb = state->lb;
    pad.rb = state->rb;
    engine->testState_ = pad;
  }
  [engine updatePolling];
}

NSString* XenraPadNavTestFocus(void) { return [XenraPadEngine.shared focusName]; }

BOOL XenraPadNavTestPolling(void) { return [XenraPadEngine.shared polling]; }
#endif
