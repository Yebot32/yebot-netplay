/**
 ******************************************************************************
 * Xenra : iOS shell - blade surface + dashboard background (implementation)  *
 ******************************************************************************
 */

#import "XenraBladeView.h"

#import "XenraTheme.h"

@implementation XenraBladeView {
  UIBezierPath* path_;
}

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    path_ = [[UIBezierPath bezierPath] retain];
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
  }
  return self;
}

- (void)dealloc {
  [path_ release];
  [super dealloc];
}

- (void)layoutSubviews {
  [super layoutSubviews];
  // 10dp chamfer at the device scale, exactly like GameBladeView.
  CGFloat chamfer = 10.0 * self.traitCollection.displayScale;
  if (chamfer <= 0.0) {
    chamfer = 10.0;
  }
  XenraPathBlade(path_, self.bounds, chamfer);
  [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
  if (self.bladeSelected) {
    // The selected state on Android is a vertical gradient from the deep
    // selected-end colour up to the bright stroke colour.
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGFloat comps[2][4] = {
        {0xA6 / 255.0, 0x6B / 255.0, 0.0, 1.0},
        {0xFF / 255.0, 0xF0 / 255.0, 0xA0 / 255.0, 1.0},
    };
    CGFloat locations[2] = {0.0, 1.0};
    CGGradientRef gradient =
        CGGradientCreateWithColorComponents(space, &comps[0][0], locations, 2);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, path_.CGPath);
    CGContextClip(ctx);
    CGPoint top =
        CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMinY(self.bounds));
    CGPoint bottom =
        CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMaxY(self.bounds));
    CGContextDrawLinearGradient(ctx, gradient, top, bottom, 0);
    CGContextRestoreGState(ctx);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);
  } else {
    [XenraBladeFill() setFill];
    [path_ fill];
  }
  [XenraAccent55() setStroke];
  path_.lineWidth = 1.5;
  [path_ stroke];
}

@end

@implementation XenraDashboardBackground {
  CAGradientLayer* gradient_;
  CAGradientLayer* glow_;
}

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.backgroundColor = XenraBlack();

    gradient_ = [CAGradientLayer layer];
    gradient_.colors = @[ (id)XenraBgGradStart().CGColor,
                          (id)XenraBgGradCenter().CGColor,
                          (id)XenraBgGradEnd().CGColor ];
    gradient_.locations = @[ @0.0, @0.45, @1.0 ];
    [self.layer addSublayer:gradient_];

    // The radial gold glow sits behind the header, like the Android
    // dashboard's radial gold. Centered near the top, wide and soft.
    glow_ = [CAGradientLayer layer];
    glow_.type = kCAGradientLayerRadial;
    UIColor* clearStop = [XenraColor(0, 0, 0, 0) autorelease];
    glow_.colors = @[ (id)XenraGlowStrong().CGColor,
                      (id)XenraGlowSoft().CGColor,
                      (id)XenraGlowFloor().CGColor,
                      (id)clearStop.CGColor ];
    glow_.locations = @[ @0.0, @0.35, @0.7, @1.0 ];
    glow_.startPoint = CGPointMake(0.5, 0.5);
    glow_.endPoint = CGPointMake(0.5, 1.0);
    [self.layer addSublayer:glow_];
  }
  return self;
}

- (void)dealloc {
  [gradient_ release];
  [glow_ release];
  [super dealloc];
}

- (void)layoutSubviews {
  [super layoutSubviews];
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  gradient_.frame = self.bounds;
  CGFloat w = self.bounds.size.width;
  glow_.frame = CGRectMake(-w * 0.25, -w * 0.25, w * 1.5, w * 1.5);
  [CATransaction commit];
}

@end
