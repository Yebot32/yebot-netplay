#import "XenraTouchPad.h"

#import <objc/runtime.h>

#include <algorithm>
#include <cmath>
#include <vector>

namespace {

// XInput button bits, as X_INPUT_GAMEPAD_* in xenia/hid/input.h.
enum : int {
  kUp = 0x0001, kDown = 0x0002, kLeft = 0x0004, kRight = 0x0008,
  kStart = 0x0010, kBack = 0x0020, kL3 = 0x0040, kR3 = 0x0080,
  kLB = 0x0100, kRB = 0x0200, kA = 0x1000, kB = 0x2000, kX = 0x4000,
  kY = 0x8000,
};
// Not XInput bits: the triggers are analog, and MENU never reaches the guest.
enum : int { kLT = 1 << 20, kRT = 1 << 21, kMenu = 1 << 22 };

enum class Shape { kCircle, kRoundedRect, kPill };

struct Control {
  int bit;
  const char* label;
  CGPoint center;
  CGFloat radius;
  Shape shape;
  CGFloat width, height;
  UIColor* ring;  // nil: the accent
  bool pressed;
  bool shown;
  CALayer* layer;
  UIImage* up;
  UIImage* down;
};

struct Stick {
  CGPoint center;
  CGFloat radius;
  CGPoint knob;  // -1..1
  // UIKit recycles UITouch objects, so holding the pointer past the end of a
  // gesture can silently start naming a different finger. A per-touch id that
  // is attached to the object itself cannot alias.
  long long touchId;  // 0: free
  CALayer* base;
  CALayer* knobLayer;
  UIImage* baseIdle;
  UIImage* baseActive;
  UIImage* knobIdle;
  UIImage* knobActive;
};

// OnScreenController.kt TABLET_GEOMETRY_CAP_DP. Points are its dp here.
constexpr CGFloat kTabletGeometryCap = 480;

UIColor* Rgb(int r, int g, int b, CGFloat a = 1) {
  return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a];
}

}  // namespace

@implementation XenraTouchPad {
  std::vector<Control> controls_;
  Stick left_, right_;
  CGSize laidOutFor_;
  int lastBits_;
  long long nextTouchId_;
  // The touches that were live on the last event, with their ids. Compared by
  // pointer only; never messaged.
  UITouch* __unsafe_unretained liveTouches_[16];
  long long liveIds_[16];
  int liveCount_;
}

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.backgroundColor = UIColor.clearColor;
    self.multipleTouchEnabled = YES;
    self.opaque = NO;
    _scaleFactor = 1;
    _hapticsEnabled = YES;
    nextTouchId_ = 1;
    liveCount_ = 0;
    left_.touchId = 0;
    right_.touchId = 0;
  }
  return self;
}

- (void)setX360Layout:(BOOL)x360Layout {
  _x360Layout = x360Layout;
  laidOutFor_ = CGSizeZero;
  [self setNeedsLayout];
}

- (void)setScaleFactor:(CGFloat)scaleFactor {
  _scaleFactor = std::clamp<CGFloat>(scaleFactor, 0.5, 2.0);
  laidOutFor_ = CGSizeZero;
  [self setNeedsLayout];
}

- (void)layoutSubviews {
  [super layoutSubviews];
  if (!CGSizeEqualToSize(laidOutFor_, self.bounds.size)) {
    [self initializeControls];
    [self buildLayers];
  }
}

- (void)initializeControls {
  const CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
  laidOutFor_ = self.bounds.size;
  controls_.clear();
  const CGFloat baseUnit = std::min({w, h, kTabletGeometryCap});
  const CGFloat unit = baseUnit * _scaleFactor;

  const CGFloat xLeftEdge = std::min(w * 0.09, baseUnit * 0.20);
  const CGFloat xLeftStick = std::min(w * 0.13, baseUnit * 0.29);
  const CGFloat xDpad = std::min(w * 0.36, baseUnit * 0.80);
  const CGFloat xRightEdge = w - std::min(w * 0.09, baseUnit * 0.20);
  const CGFloat xRightStick = w - std::min(w * 0.33, baseUnit * 0.73);
  const CGFloat xFace = w - std::min(w * 0.12, baseUnit * 0.27);
  const CGFloat yTrigger = std::min(h * 0.105, baseUnit * 0.105);
  const CGFloat yUtility = std::min(h * 0.25, baseUnit * 0.25);
  const CGFloat yCluster = h - std::min(h * 0.30, baseUnit * 0.30);
  const CGFloat yPills = h - std::min(h * 0.10, baseUnit * 0.10);

  auto circle = [&](int bit, const char* label, CGFloat x, CGFloat y, CGFloat r,
                    UIColor* ring = nil) {
    controls_.push_back({bit, label, CGPointMake(x, y), r, Shape::kCircle, 0, 0,
                         ring, false});
  };
  auto box = [&](int bit, const char* label, CGFloat x, CGFloat y, CGFloat bw,
                 CGFloat bh, Shape shape) {
    controls_.push_back({bit, label, CGPointMake(x, y), bh / 2, shape, bw, bh,
                         nil, false});
  };

  const CGFloat triggerWidth = unit * 0.25, triggerHeight = unit * 0.095;
  box(kLT, "LT", xLeftEdge, yTrigger, triggerWidth, triggerHeight,
      Shape::kRoundedRect);
  box(kRT, "RT", xRightEdge, yTrigger, triggerWidth, triggerHeight,
      Shape::kRoundedRect);

  const CGFloat utilityRadius = unit * 0.052, gap = unit * 0.12;
  if (_x360Layout) {
    circle(kLB, "LB", xLeftEdge - gap / 2, yUtility, utilityRadius);
    circle(kL3, "L3", xLeftEdge + gap / 2, yUtility, utilityRadius);
    circle(kR3, "R3", xRightEdge - gap / 2, yUtility, utilityRadius);
    circle(kRB, "RB", xRightEdge + gap / 2, yUtility, utilityRadius);
  } else {
    // WHITE is L_SHOULDER and BLACK is R_SHOULDER on both consoles.
    circle(kRB, "BLK", xLeftEdge - gap / 2, yUtility, utilityRadius);
    circle(kLB, "WHT", xLeftEdge + gap / 2, yUtility, utilityRadius);
    circle(kL3, "L3", xRightEdge - gap / 2, yUtility, utilityRadius);
    circle(kR3, "R3", xRightEdge + gap / 2, yUtility, utilityRadius);
  }

  const CGFloat stickRadius = unit * 0.14;
  // A rebuild (rotation, scale change) must not drop a stick a thumb is
  // already holding: the finger only sends moved events after that, and
  // without its id it would never be re-claimed until lifted.
  const long long leftId = left_.touchId, rightId = right_.touchId;
  const CGPoint leftKnob = left_.knob, rightKnob = right_.knob;
  left_ = {CGPointMake(xLeftStick, yCluster), stickRadius, leftKnob, leftId};
  right_ = {CGPointMake(xRightStick, yCluster), stickRadius, rightKnob, rightId};

  const CGFloat dpadSpacing = unit * 0.098, dpadSize = unit * 0.105;
  box(kUp, "", xDpad, yCluster - dpadSpacing, dpadSize, dpadSize,
      Shape::kRoundedRect);
  box(kDown, "", xDpad, yCluster + dpadSpacing, dpadSize, dpadSize,
      Shape::kRoundedRect);
  box(kLeft, "", xDpad - dpadSpacing, yCluster, dpadSize, dpadSize,
      Shape::kRoundedRect);
  box(kRight, "", xDpad + dpadSpacing, yCluster, dpadSize, dpadSize,
      Shape::kRoundedRect);

  const CGFloat faceSpacing = unit * 0.115, faceRadius = unit * 0.064;
  circle(kA, "A", xFace, yCluster + faceSpacing, faceRadius, Rgb(55, 181, 92));
  circle(kB, "B", xFace + faceSpacing, yCluster, faceRadius, Rgb(222, 72, 72));
  circle(kX, "X", xFace - faceSpacing, yCluster, faceRadius, Rgb(67, 139, 222));
  circle(kY, "Y", xFace, yCluster - faceSpacing, faceRadius, Rgb(245, 193, 45));

  const CGFloat pillWidth = unit * 0.13, pillHeight = unit * 0.065;
  box(kBack, _x360Layout ? "BACK" : "SELECT", w * 0.5 - pillWidth * 1.15,
      yPills, pillWidth, pillHeight, Shape::kPill);
  box(kMenu, "MENU", w * 0.5, yPills, pillWidth, pillHeight, Shape::kPill);
  box(kStart, "START", w * 0.5 + pillWidth * 1.15, yPills, pillWidth,
      pillHeight, Shape::kPill);
}

// --- Drawing ----------------------------------------------------------------
// Every control is a layer holding two pictures drawn once at layout. A press
// swaps a layer's contents and a stick moves its knob, so nothing is redrawn
// while playing. That matters more than it sounds: touches arrive on the main
// thread, which is also the thread xemu renders from.

static UIImage* Picture(CGSize size, void (^draw)(void)) {
  UIGraphicsImageRenderer* renderer =
      [[UIGraphicsImageRenderer alloc] initWithSize:size];
  return [renderer imageWithActions:^(UIGraphicsImageRendererContext*) {
    draw();
  }];
}

static CALayer* PadLayer(CGRect frame, UIImage* image, CGFloat scale) {
  CALayer* layer = [CALayer layer];
  layer.frame = frame;
  layer.contents = (id)image.CGImage;
  layer.contentsScale = scale;
  return layer;
}

- (void)drawArrow:(int)bit in:(CGRect)rect color:(UIColor*)color {
  const CGFloat s = rect.size.width * 0.24;
  const CGPoint c = CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect));
  UIBezierPath* p = [UIBezierPath bezierPath];
  if (bit == kUp || bit == kDown) {
    const CGFloat d = bit == kUp ? -1 : 1;
    [p moveToPoint:CGPointMake(c.x, c.y + d * s)];
    [p addLineToPoint:CGPointMake(c.x - s, c.y - d * s * 0.7)];
    [p addLineToPoint:CGPointMake(c.x + s, c.y - d * s * 0.7)];
  } else {
    const CGFloat d = bit == kLeft ? -1 : 1;
    [p moveToPoint:CGPointMake(c.x + d * s, c.y)];
    [p addLineToPoint:CGPointMake(c.x - d * s * 0.7, c.y - s)];
    [p addLineToPoint:CGPointMake(c.x - d * s * 0.7, c.y + s)];
  }
  [p closePath];
  [color setFill];
  [p fill];
}

- (void)drawControl:(const Control&)c in:(CGRect)box pressed:(bool)pressed {
  UIBezierPath* path;
  if (c.shape == Shape::kCircle) {
    path = [UIBezierPath bezierPathWithOvalInRect:box];
  } else {
    const CGFloat corner =
        c.shape == Shape::kPill ? c.height / 2 : c.height * 0.24;
    path = [UIBezierPath bezierPathWithRoundedRect:box cornerRadius:corner];
  }
  // Android fills a held control with its colour. The old pair of images only
  // shifted a near-black fill from 59% to 85% opacity, which over a game reads
  // as no response at all. The pad green is the controller's own, not the UI
  // skin's: the 360 accent ramp would read olive over a game.
  UIColor* accent = c.ring ?: Rgb(95, 211, 95);
  [(pressed ? [accent colorWithAlphaComponent:0.92] : Rgb(18, 16, 10, 0.65))
      setFill];
  [path fill];
  [[accent colorWithAlphaComponent:pressed ? 1 : 0.8] setStroke];
  const CGFloat unit = c.shape == Shape::kCircle ? c.radius : c.height * 0.5;
  path.lineWidth = MAX(2, unit * (pressed ? 0.10 : 0.05));
  [path stroke];
  if (c.bit & (kUp | kDown | kLeft | kRight)) {
    [self drawArrow:c.bit
                 in:box
              color:pressed ? Rgb(18, 16, 10, 0.95) : Rgb(225, 215, 190, 0.8)];
    return;
  }
  NSString* text = @(c.label);
  const CGFloat size = c.shape == Shape::kPill ? c.height * 0.36
                       : c.shape == Shape::kCircle ? c.radius * 0.72
                                                   : c.height * 0.42;
  NSDictionary* attrs = @{
    NSFontAttributeName : [UIFont systemFontOfSize:size
                                            weight:UIFontWeightMedium],
    NSForegroundColorAttributeName :
        pressed ? Rgb(18, 16, 10, 0.95) : Rgb(255, 248, 232),
  };
  const CGSize t = [text sizeWithAttributes:attrs];
  [text drawAtPoint:CGPointMake(CGRectGetMidX(box) - t.width / 2,
                                CGRectGetMidY(box) - t.height / 2)
      withAttributes:attrs];
}

- (void)buildStick:(Stick&)stick scale:(CGFloat)scale {
  const CGFloat r = stick.radius, side = r * 2 + 4;
  const CGRect ring = CGRectMake(2, 2, r * 2, r * 2);
  auto base = [&](bool active) {
    return Picture(CGSizeMake(side, side), ^{
      UIBezierPath* path = [UIBezierPath bezierPathWithOvalInRect:ring];
      [Rgb(18, 16, 10, active ? 0.8 : 0.59) setFill];
      [path fill];
      [(active ? Rgb(95, 211, 95, 0.92) : Rgb(255, 248, 232, 0.47))
          setStroke];
      path.lineWidth = r * 0.035;
      [path stroke];
    });
  };
  const CGFloat knobR = r * 0.34;
  auto knob = [&](bool active) {
    return Picture(CGSizeMake(knobR * 2, knobR * 2), ^{
      [(active ? Rgb(95, 211, 95) : Rgb(225, 215, 190, 0.6)) setFill];
      [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, knobR * 2,
                                                         knobR * 2)] fill];
    });
  };
  stick.baseIdle = base(false);
  stick.baseActive = base(true);
  stick.knobIdle = knob(false);
  stick.knobActive = knob(true);
  stick.base = PadLayer(CGRectMake(stick.center.x - side / 2,
                                   stick.center.y - side / 2, side, side),
                        stick.baseIdle, scale);
  stick.knobLayer =
      PadLayer(CGRectMake(stick.center.x - knobR, stick.center.y - knobR,
                          knobR * 2, knobR * 2),
               stick.knobIdle, scale);
  [self.layer addSublayer:stick.base];
  [self.layer addSublayer:stick.knobLayer];
}

- (void)buildLayers {
  self.layer.sublayers = nil;
  const CGFloat scale = self.traitCollection.displayScale ?: 2;
  [self buildStick:left_ scale:scale];
  [self buildStick:right_ scale:scale];
  for (Control& c : controls_) {
    const CGFloat w = c.shape == Shape::kCircle ? c.radius * 2 : c.width;
    const CGFloat h = c.shape == Shape::kCircle ? c.radius * 2 : c.height;
    const CGRect box = CGRectMake(2, 2, w, h);
    const CGSize size = CGSizeMake(w + 4, h + 4);
    const Control* control = &c;
    __weak XenraTouchPad* weak = self;
    c.up = Picture(size, ^{
      [weak drawControl:*control in:box pressed:false];
    });
    c.down = Picture(size, ^{
      [weak drawControl:*control in:box pressed:true];
    });
    c.layer = PadLayer(CGRectMake(c.center.x - size.width / 2,
                                  c.center.y - size.height / 2, size.width,
                                  size.height),
                       c.up, scale);
    [self.layer addSublayer:c.layer];
  }
  // A rebuild can happen while a thumb is down (rotation, scale change); paint
  // that state straight away instead of leaving the knob centred until the
  // next touch event.
  [self showState];
}

- (void)showStick:(Stick&)stick {
  const bool active = stick.touchId != 0;
  stick.base.contents =
      (id)(active ? stick.baseActive : stick.baseIdle).CGImage;
  stick.knobLayer.contents =
      (id)(active ? stick.knobActive : stick.knobIdle).CGImage;
  stick.knobLayer.position =
      CGPointMake(stick.center.x + stick.knob.x * stick.radius * 0.62,
                  stick.center.y + stick.knob.y * stick.radius * 0.62);
}

- (void)showState {
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  [self showStick:left_];
  [self showStick:right_];
  for (Control& c : controls_) {
    if (c.pressed == c.shown) continue;
    c.shown = c.pressed;
    c.layer.contents = (id)(c.pressed ? c.down : c.up).CGImage;
    // Android shrinks a held button to 91%. The fill swap alone is easy to
    // miss under a thumb, which is what "it does not darken" was.
    const CGFloat scale = c.pressed ? 0.91 : 1;
    c.layer.transform = CATransform3DMakeScale(scale, scale, 1);
  }
  [CATransaction commit];
}

// --- Touches ----------------------------------------------------------------

static bool Hit(const Control& c, CGPoint p) {
  // A little slack, as a thumb is wider than the ring it is aiming at.
  if (c.shape == Shape::kCircle) {
    return std::hypot(p.x - c.center.x, p.y - c.center.y) <= c.radius * 1.2;
  }
  return std::abs(p.x - c.center.x) <= c.width * 0.6 &&
         std::abs(p.y - c.center.y) <= c.height * 0.6;
}

static void MoveStick(Stick& s, CGPoint p) {
  CGFloat dx = (p.x - s.center.x) / s.radius, dy = (p.y - s.center.y) / s.radius;
  const CGFloat len = std::hypot(dx, dy);
  if (len > 1) {
    dx /= len;
    dy /= len;
  }
  s.knob = CGPointMake(dx, dy);
}

- (void)evaluateTouches:(NSSet<UITouch*>*)all ended:(NSSet<UITouch*>*)ended {
  // The pad used to remember the UITouch object itself. UIKit recycles those
  // objects, and a touch can also end without touchesEnded or touchesCancelled
  // ever arriving (the app going to the background is the usual one), so the
  // stored pointer could name a dead object - or, once recycled, a different
  // finger. The stick then stayed lit with its knob frozen and ignored the
  // thumb until the view was rebuilt: the "sticks stop holding after a while"
  // report. An id assigned to each touch while it is live cannot alias, and a
  // stick whose finger is missing from this event is released here, so a
  // dropped callback costs one frame instead of the rest of the session.
  UITouch* __unsafe_unretained liveTouches[16];
  long long liveIds[16];
  int liveCount = 0;
  for (UITouch* t in all) {
    if ([ended containsObject:t] || liveCount == 16) continue;
    long long ident = 0;
    for (int i = 0; i < liveCount_; i++) {
      if (liveTouches_[i] == t) {
        ident = liveIds_[i];
        break;
      }
    }
    if (!ident) ident = nextTouchId_++;
    liveTouches[liveCount] = t;
    liveIds[liveCount] = ident;
    ++liveCount;
  }
  const auto isLive = [&](long long ident) {
    for (int i = 0; i < liveCount; i++) {
      if (liveIds[i] == ident) return true;
    }
    return false;
  };
  if (left_.touchId && !isLive(left_.touchId)) {
    left_.touchId = 0;
    left_.knob = CGPointZero;
  }
  if (right_.touchId && !isLive(right_.touchId)) {
    right_.touchId = 0;
    right_.knob = CGPointZero;
  }

  int bits = 0;
  for (int i = 0; i < liveCount; i++) {
    UITouch* t = liveTouches[i];
    const long long ident = liveIds[i];
    const CGPoint p = [t locationInView:self];
    if (left_.touchId == ident) {
      MoveStick(left_, p);
      continue;
    }
    if (right_.touchId == ident) {
      MoveStick(right_, p);
      continue;
    }
    bool hit = false;
    for (const Control& c : controls_) {
      if (Hit(c, p)) {
        bits |= c.bit;
        hit = true;
      }
    }
    if (hit) continue;
    if (t.phase == UITouchPhaseBegan) {
      if (!left_.touchId &&
          std::hypot(p.x - left_.center.x, p.y - left_.center.y) <=
              left_.radius * 1.3) {
        left_.touchId = ident;
        MoveStick(left_, p);
      } else if (!right_.touchId &&
                 std::hypot(p.x - right_.center.x, p.y - right_.center.y) <=
                     right_.radius * 1.3) {
        right_.touchId = ident;
        MoveStick(right_, p);
      }
    }
  }
  liveCount_ = liveCount;
  for (int i = 0; i < liveCount; i++) {
    liveTouches_[i] = liveTouches[i];
    liveIds_[i] = liveIds[i];
  }
  for (Control& c : controls_) c.pressed = (bits & c.bit) != 0;

  const int newlyDown = bits & ~lastBits_;
  if (newlyDown && _hapticsEnabled) {
    static UIImpactFeedbackGenerator* haptic = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleLight];
    [haptic impactOccurred];
  }
  if ((newlyDown & kMenu) && _onMenu) _onMenu();
  lastBits_ = bits;

  if (_onChange) {
    const auto axis = [](CGFloat v) { return short(v * 32767); };
    // Screen y grows down, an XInput stick's grows up.
    _onChange(bits & 0xFFFF, axis(left_.knob.x), axis(-left_.knob.y),
              axis(right_.knob.x), axis(-right_.knob.y),
              (bits & kLT) ? 255 : 0, (bits & kRT) ? 255 : 0);
  }
  [self showState];
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  [self evaluateTouches:[event touchesForView:self] ended:[NSSet set]];
}
- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  [self evaluateTouches:[event touchesForView:self] ended:[NSSet set]];
}
- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  [self evaluateTouches:[event touchesForView:self] ended:touches];
}
- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  [self evaluateTouches:[event touchesForView:self] ended:touches];
}

@end
