#import "XenraTouchPad.h"

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
};

struct Stick {
  CGPoint center;
  CGFloat radius;
  CGPoint knob;  // -1..1
  UITouch* __unsafe_unretained touch;
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
}

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.backgroundColor = UIColor.clearColor;
    self.multipleTouchEnabled = YES;
    self.opaque = NO;
    self.contentMode = UIViewContentModeRedraw;
    _scaleFactor = 1;
    _hapticsEnabled = YES;
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
    [self setNeedsDisplay];
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
  left_ = {CGPointMake(xLeftStick, yCluster), stickRadius, CGPointZero, nil};
  right_ = {CGPointMake(xRightStick, yCluster), stickRadius, CGPointZero, nil};

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

- (void)drawStick:(const Stick&)stick {
  const bool active = stick.touch != nil;
  UIColor* accent = Rgb(95, 211, 95, 0.92);
  CGRect outer = CGRectMake(stick.center.x - stick.radius,
                            stick.center.y - stick.radius, stick.radius * 2,
                            stick.radius * 2);
  UIBezierPath* ring = [UIBezierPath bezierPathWithOvalInRect:outer];
  [Rgb(18, 16, 10, active ? 0.8 : 0.59) setFill];
  [ring fill];
  [(active ? accent : Rgb(255, 248, 232, 0.47)) setStroke];
  ring.lineWidth = stick.radius * 0.035;
  [ring stroke];

  const CGFloat knobR = stick.radius * 0.34;
  const CGPoint at = CGPointMake(
      stick.center.x + stick.knob.x * stick.radius * 0.62,
      stick.center.y + stick.knob.y * stick.radius * 0.62);
  UIBezierPath* knob = [UIBezierPath
      bezierPathWithOvalInRect:CGRectMake(at.x - knobR, at.y - knobR, knobR * 2,
                                          knobR * 2)];
  [Rgb(225, 215, 190, active ? 0.9 : 0.6) setFill];
  [knob fill];
}

- (void)drawArrow:(int)bit in:(CGRect)rect {
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
  [Rgb(225, 215, 190, 0.8) setFill];
  [p fill];
}

- (void)drawRect:(CGRect)rect {
  [self drawStick:left_];
  [self drawStick:right_];
  for (const Control& c : controls_) {
    CGRect box;
    UIBezierPath* path;
    if (c.shape == Shape::kCircle) {
      box = CGRectMake(c.center.x - c.radius, c.center.y - c.radius,
                       c.radius * 2, c.radius * 2);
      path = [UIBezierPath bezierPathWithOvalInRect:box];
    } else {
      box = CGRectMake(c.center.x - c.width / 2, c.center.y - c.height / 2,
                       c.width, c.height);
      const CGFloat corner =
          c.shape == Shape::kPill ? c.height / 2 : c.height * 0.24;
      path = [UIBezierPath bezierPathWithRoundedRect:box cornerRadius:corner];
    }
    [Rgb(18, 16, 10, c.pressed ? 0.85 : 0.59) setFill];
    [path fill];
    [(c.ring ?: Rgb(255, 208, 38, c.pressed ? 1 : 0.7)) setStroke];
    path.lineWidth = 1.5;
    [path stroke];
    if (c.bit & (kUp | kDown | kLeft | kRight)) {
      [self drawArrow:c.bit in:box];
      continue;
    }
    NSString* text = @(c.label);
    const CGFloat size = c.shape == Shape::kPill ? c.height * 0.36
                         : c.shape == Shape::kCircle ? c.radius * 0.72
                                                     : c.height * 0.42;
    NSDictionary* attrs = @{
      NSFontAttributeName : [UIFont systemFontOfSize:size
                                              weight:UIFontWeightMedium],
      NSForegroundColorAttributeName : Rgb(255, 248, 232),
    };
    const CGSize t = [text sizeWithAttributes:attrs];
    [text drawAtPoint:CGPointMake(CGRectGetMidX(box) - t.width / 2,
                                  CGRectGetMidY(box) - t.height / 2)
        withAttributes:attrs];
  }
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
  for (UITouch* t in ended) {
    if (left_.touch == t) {
      left_.touch = nil;
      left_.knob = CGPointZero;
    }
    if (right_.touch == t) {
      right_.touch = nil;
      right_.knob = CGPointZero;
    }
  }
  int bits = 0;
  for (UITouch* t in all) {
    if ([ended containsObject:t]) continue;
    const CGPoint p = [t locationInView:self];
    if (left_.touch == t) {
      MoveStick(left_, p);
      continue;
    }
    if (right_.touch == t) {
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
      if (!left_.touch &&
          std::hypot(p.x - left_.center.x, p.y - left_.center.y) <=
              left_.radius * 1.3) {
        left_.touch = t;
        MoveStick(left_, p);
      } else if (!right_.touch &&
                 std::hypot(p.x - right_.center.x, p.y - right_.center.y) <=
                     right_.radius * 1.3) {
        right_.touch = t;
        MoveStick(right_, p);
      }
    }
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
  [self setNeedsDisplay];
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
