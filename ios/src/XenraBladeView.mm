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

@implementation XenraBladeView {
  CAGradientLayer* fill_;
  CALayer* rail_;
}

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.backgroundColor = UIColor.clearColor;
    fill_ = [CAGradientLayer layer];
    fill_.startPoint = CGPointMake(0, 0.5);
    fill_.endPoint = CGPointMake(1, 0.5);
    fill_.cornerRadius = kRadius;
    [self.layer addSublayer:fill_];
    rail_ = [CALayer layer];
    [self.layer addSublayer:rail_];
    [self apply];
  }
  return self;
}

- (void)apply {
  uint8_t start = 0x33, center = 0x1A, end = 0;
  if (_state == XenraBladePressed) {
    start = 0xAA, center = 0x55, end = 0x14;
  } else if (_state == XenraBladeChosen) {
    start = 0x88, center = 0x4D, end = 0x14;
  }
  if (_primary) {
    start = 0xFF, center = 0xCC, end = 0x88;
    if (_state == XenraBladePressed) center = end = 0xFF;
  }
  fill_.colors = @[
    (id)XenraAccentAlpha(start).CGColor, (id)XenraAccentAlpha(center).CGColor,
    (id)XenraAccentAlpha(end).CGColor
  ];
  rail_.backgroundColor =
      XenraAccentAlpha(_state == XenraBladeResting ? 0xCC : 0xFF).CGColor;
  [self placeRail];
}

- (void)placeRail {
  rail_.frame = CGRectMake(0, 0, _state == XenraBladeResting ? kRail : kRailActive,
                           self.bounds.size.height);
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

- (void)setPrimary:(BOOL)primary {
  _primary = primary;
  [self apply];
}

- (void)layoutSubviews {
  [super layoutSubviews];
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  fill_.frame = self.bounds;
  [self placeRail];
  [CATransaction commit];
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
