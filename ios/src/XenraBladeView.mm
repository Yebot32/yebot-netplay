#import "XenraBladeView.h"

#import <QuartzCore/QuartzCore.h>

#import "XenraTheme.h"

NSInteger XenraThemeMode = XenraThemeOG;

// dimens.xml: radius_s, blade_rail_width, blade_rail_width_active.
static const CGFloat kRadius = 8;
static const CGFloat kRail = 4;
static const CGFloat kRailActive = 6;
// The selector's enterFadeDuration and exitFadeDuration.
static const CFTimeInterval kEnterFade = 0.12;
static const CFTimeInterval kExitFade = 0.18;

// One layer-list of the drawables: a flat base, a gradient, a rail.
struct BladePaint {
  UIColor* base;
  UIColor* start;
  UIColor* center;
  UIColor* end;
  UIColor* rail;
  CGFloat railWidth;
};

static UIColor* Clear(void) { return [UIColor colorWithWhite:0 alpha:0]; }

static BladePaint DarkPlain(XenraBladeState state) {
  switch (state) {
    case XenraBladePressed:
      return {nil, XenraAccentAlpha(0xAA), XenraAccentAlpha(0x55),
              XenraAccentAlpha(0x14), XenraAccent(), kRailActive};
    case XenraBladeChosen:
      return {nil, XenraAccentAlpha(0x88), XenraAccentAlpha(0x4D),
              XenraAccentAlpha(0x14), XenraAccent(), kRailActive};
    case XenraBladeFocused:
      return {nil, XenraFocus38(), XenraFocus1F(), Clear(), XenraFocus(),
              kRailActive};
    case XenraBladeResting:
      break;
  }
  return {nil, XenraAccentAlpha(0x33), XenraAccentAlpha(0x1A), Clear(),
          XenraAccentAlpha(0xCC), kRail};
}

static BladePaint DarkPrimary(XenraBladeState state) {
  if (state == XenraBladePressed) {
    return {nil, XenraAccent(), XenraAccent(), XenraAccent(), XenraAccent(), 0.0};
  }
  return {nil, XenraAccent(), XenraAccentAlpha(0xCC), XenraAccentAlpha(0x88),
          state == XenraBladeFocused ? XenraFocus() : XenraText(), kRailActive};
}

static BladePaint DarkDestructive(XenraBladeState state) {
  UIColor* warning = XenraHex(0xFFFF6B6B);
  switch (state) {
    case XenraBladePressed:
      return {nil, XenraHex(0x66FF6B6B), XenraHex(0x33FF6B6B),
              XenraHex(0x0DFF6B6B), warning, kRailActive};
    case XenraBladeFocused:
    case XenraBladeChosen:
      return {nil, XenraHex(0x4DFF6B6B), XenraHex(0x26FF6B6B), Clear(), warning,
              kRailActive};
    case XenraBladeResting:
      break;
  }
  return {nil, XenraHex(0x26FF6B6B), XenraHex(0x14FF6B6B), Clear(), warning,
          kRail};
}

static BladePaint LightPlain(XenraBladeState state) {
  UIColor* fade = XenraHex(0x00FFFFFF);
  switch (state) {
    case XenraBladePressed:
      return {XenraHex(0xF2FFFFFF), XenraAccentAlpha(0x55),
              XenraAccentAlpha(0x22), fade, XenraAccent(), kRailActive};
    case XenraBladeChosen:
      return {XenraHex(0xEDFFFFFF), XenraAccentAlpha(0x33),
              XenraAccentAlpha(0x1A), fade, XenraAccent(), kRailActive};
    case XenraBladeFocused:
      return {XenraHex(0xEDFFFFFF), XenraFocus1F(), XenraFocus1F(), fade,
              XenraFocus(), kRailActive};
    case XenraBladeResting:
      break;
  }
  return {XenraHex(0xE0FFFFFF), XenraAccentAlpha(0x1A), XenraAccentAlpha(0x14),
          fade, XenraAccent(), kRail};
}

static BladePaint LightPrimary(XenraBladeState state) {
  if (state == XenraBladePressed) {
    return {nil, XenraAccent(), XenraAccent(), XenraAccent(),
            XenraHex(0xF2FFFFFF), kRailActive};
  }
  return {nil, XenraAccent(), XenraAccentAlpha(0xCC), XenraAccentAlpha(0xAA),
          state == XenraBladeFocused ? XenraFocus() : XenraHex(0xE6FFFFFF),
          kRailActive};
}

static BladePaint LightDestructive(XenraBladeState state) {
  UIColor* fade = XenraHex(0x00FFFFFF);
  UIColor* warning = XenraHex(0xFF8A4B0B);
  switch (state) {
    case XenraBladePressed:
      return {XenraHex(0xF2FFFFFF), XenraHex(0x4D8A4B0B), XenraHex(0x268A4B0B),
              fade, warning, kRailActive};
    case XenraBladeFocused:
    case XenraBladeChosen:
      return {XenraHex(0xF2FFFFFF), XenraHex(0x338A4B0B), XenraHex(0x1A8A4B0B),
              fade, warning, kRailActive};
    case XenraBladeResting:
      break;
  }
  return {XenraHex(0xE0FFFFFF), XenraHex(0x1A8A4B0B), XenraHex(0x0D8A4B0B),
          fade, warning, kRail};
}

@implementation XenraBladeView {
  CALayer* base_;
  CAGradientLayer* fill_;
  CALayer* rail_;
  CGFloat railWidth_;
}

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.backgroundColor = UIColor.clearColor;
    base_ = [CALayer layer];
    base_.cornerRadius = kRadius;
    [self.layer addSublayer:base_];
    fill_ = [CAGradientLayer layer];
    fill_.startPoint = CGPointMake(0, 0.5);
    fill_.endPoint = CGPointMake(1, 0.5);
    fill_.cornerRadius = kRadius;
    [self.layer addSublayer:fill_];
    rail_ = [CALayer layer];
    [self.layer addSublayer:rail_];
    [self applyWithoutAnimation];
  }
  return self;
}

- (void)apply {
  // The light console's compact rows are built differently, not recoloured.
  const BOOL light = _compact && XenraThemeMode == XenraThemeX360;
  BladePaint paint;
  switch (_kind) {
    case XenraBladeKindPrimary:
      paint = light ? LightPrimary(_state) : DarkPrimary(_state);
      break;
    case XenraBladeKindDestructive:
      paint = light ? LightDestructive(_state) : DarkDestructive(_state);
      break;
    case XenraBladeKindPlain:
      paint = light ? LightPlain(_state) : DarkPlain(_state);
      break;
  }
  base_.backgroundColor = paint.base.CGColor;
  fill_.colors = @[
    (id)paint.start.CGColor, (id)paint.center.CGColor, (id)paint.end.CGColor
  ];
  rail_.backgroundColor = paint.rail.CGColor;
  railWidth_ = paint.railWidth;
  [self placeRail];
}

// Built state is not a change of state: nothing fades in on a new screen.
- (void)applyWithoutAnimation {
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  [self apply];
  [CATransaction commit];
}

- (void)placeRail {
  rail_.frame = CGRectMake(0, 0, railWidth_, self.bounds.size.height);
}

- (void)setState:(XenraBladeState)state {
  if (state == _state) return;
  const BOOL lighting = state > _state;
  _state = state;
  [CATransaction begin];
  [CATransaction setAnimationDuration:lighting ? kEnterFade : kExitFade];
  [self apply];
  [CATransaction commit];
}

- (void)setKind:(XenraBladeKind)kind {
  _kind = kind;
  [self applyWithoutAnimation];
}

- (void)setCompact:(BOOL)compact {
  _compact = compact;
  [self applyWithoutAnimation];
}

- (BOOL)primary {
  return _kind == XenraBladeKindPrimary;
}

- (void)setPrimary:(BOOL)primary {
  self.kind = primary ? XenraBladeKindPrimary : XenraBladeKindPlain;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  base_.frame = self.bounds;
  fill_.frame = self.bounds;
  [self placeRail];
  [CATransaction commit];
}

@end

// dashboard_vignette: clear in the middle, the edge colour from the radius on.
// Drawn rather than a CAGradientLayer, because the Android radius is 90% of the
// SHORT side and everything past it keeps the edge colour, which on a tall screen
// is a large part of the view and a gradient layer has no way to fill.
@interface XenraVignetteView : UIView
@end

@implementation XenraVignetteView

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.userInteractionEnabled = NO;
    self.contentMode = UIViewContentModeRedraw;
  }
  return self;
}

- (void)drawRect:(CGRect)rect {
  const CGSize size = self.bounds.size;
  CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
  NSArray* colors = @[
    (id)[XenraVignetteMid() colorWithAlphaComponent:0].CGColor,
    (id)XenraVignetteMid().CGColor, (id)XenraVignetteEdge().CGColor
  ];
  const CGFloat stops[] = {0, 0.5, 1};
  CGGradientRef gradient =
      CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, stops);
  const CGPoint center = CGPointMake(size.width / 2, size.height / 2);
  CGContextDrawRadialGradient(UIGraphicsGetCurrentContext(), gradient, center, 0,
                              center, MIN(size.width, size.height) * 0.9,
                              kCGGradientDrawsAfterEndLocation);
  CGGradientRelease(gradient);
  CGColorSpaceRelease(space);
}

@end

// A radial gradient is drawn in a square layer, so that its circle stays one.
static CAGradientLayer* Bloom(NSArray* colors) {
  CAGradientLayer* layer = [CAGradientLayer layer];
  layer.type = kCAGradientLayerRadial;
  layer.colors = colors;
  layer.startPoint = CGPointMake(0.5, 0.5);
  layer.endPoint = CGPointMake(1, 1);
  return layer;
}

@implementation XenraDashboardBackground {
  CAGradientLayer* across_;
  CAGradientLayer* vignette_;
  CAGradientLayer* bloom_;
  CAGradientLayer* floor_;
}

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.backgroundColor = XenraCharcoal();
    self.clipsToBounds = YES;
    id clear = (id)XenraAccentAlpha(0).CGColor;
    bloom_ = Bloom(@[
      (id)XenraAccentAlpha(0x4D).CGColor, (id)XenraAccentAlpha(0x1A).CGColor,
      clear
    ]);
    floor_ = Bloom(@[ (id)XenraAccentAlpha(0x14).CGColor, clear ]);
    [self.layer addSublayer:bloom_];
    [self.layer addSublayer:floor_];
  }
  return self;
}

- (instancetype)initForDashboardWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.backgroundColor = XenraBgGradStart();
    across_ = [CAGradientLayer layer];
    across_.colors = @[
      (id)XenraBgGradStart().CGColor, (id)XenraBgGradCenter().CGColor,
      (id)XenraBgGradEnd().CGColor
    ];
    across_.startPoint = CGPointMake(0, 0.5);
    across_.endPoint = CGPointMake(1, 0.5);
    [self.layer addSublayer:across_];
    vignette_ = [CAGradientLayer layer];
    vignette_.colors = @[
      (id)XenraVignetteBottom().CGColor, (id)UIColor.clearColor.CGColor,
      (id)XenraVignetteTop().CGColor
    ];
    [self.layer addSublayer:vignette_];
    XenraVignetteView* radial =
        [[XenraVignetteView alloc] initWithFrame:self.bounds];
    radial.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:radial];
  }
  return self;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  across_.frame = self.bounds;
  vignette_.frame = self.bounds;
  const CGSize size = self.bounds.size;
  // gradientRadius 115%p and 95%p, around y = 0.18 and y = 1.05.
  const CGFloat side = MIN(size.width, size.height);
  const CGFloat bloom = side * 2.3, floor = side * 1.9;
  bloom_.frame = CGRectMake(size.width / 2 - bloom / 2,
                            size.height * 0.18 - bloom / 2, bloom, bloom);
  floor_.frame = CGRectMake(size.width / 2 - floor / 2,
                            size.height * 1.05 - floor / 2, floor, floor);
  [CATransaction commit];
}

@end
