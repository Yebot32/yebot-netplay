#import "XenraUI.h"

#import <GameController/GameController.h>

#include <cmath>
#include <cstdlib>
#include <cstring>

#import "XenraBladeView.h"
#import "XenraMotion.h"
#import "XenraScreens.h"
#import "XenraTheme.h"

const NSTimeInterval XenraPressDelay = 0.08;

// How long a tap shorter than the press delay stays lit. Android's
// PRESSED_STATE_DURATION.
static const NSTimeInterval kTapFlash = 0.064;

UIImage* XenraBundleImage(NSString* name) {
  NSString* root = NSBundle.mainBundle.bundlePath;
  for (NSString* dir in @[ @"", @"Resources" ]) {
    NSString* path = [[root stringByAppendingPathComponent:dir]
        stringByAppendingPathComponent:name];
    if (UIImage* image = [UIImage imageWithContentsOfFile:path]) {
      return image;
    }
  }
  return nil;
}

UILabel* XenraMakeLabel(NSString* text, CGFloat size, UIFontWeight weight,
                        UIColor* color) {
  UILabel* label = [[UILabel alloc] init];
  label.text = text;
  label.font = [UIFont systemFontOfSize:size weight:weight];
  label.textColor = color;
  label.translatesAutoresizingMaskIntoConstraints = NO;
  return label;
}

NSAttributedString* XenraTrackedSpacing(NSString* text, CGFloat size,
                                        UIColor* color, CGFloat spacing) {
  return [[NSAttributedString alloc]
      initWithString:[text uppercaseStringWithLocale:NSLocale.currentLocale]
          attributes:@{
            NSFontAttributeName : [UIFont systemFontOfSize:size
                                                    weight:UIFontWeightBold],
            NSForegroundColorAttributeName : color,
            NSKernAttributeName : @(size * spacing),
          }];
}

NSAttributedString* XenraTracked(NSString* text, CGFloat size, UIColor* color) {
  return XenraTrackedSpacing(text, size, color, 0.1);
}

NSAttributedString* XenraScreenTitle(NSString* text) {
  return XenraTrackedSpacing(text, 18, XenraAccent(), 0.15);
}

NSAttributedString* XenraBodyText(NSString* text, CGFloat size, UIColor* color) {
  NSMutableParagraphStyle* paragraph = [[NSMutableParagraphStyle alloc] init];
  paragraph.lineHeightMultiple = 1.25;
  return [[NSAttributedString alloc]
      initWithString:text ?: @""
          attributes:@{
            NSFontAttributeName : [UIFont systemFontOfSize:size],
            NSForegroundColorAttributeName : color,
            NSParagraphStyleAttributeName : paragraph,
          }];
}

CGFloat XenraHintBarInset(UIView* view) {
  return MAX(0, view.safeAreaInsets.bottom - 20);
}

@implementation XenraScrollView

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    // Stock behaviour holds every touch back for 150 ms in case it is a scroll,
    // and refuses to scroll a drag that begins on a control, which on these
    // screens is nearly every drag. So touches go straight through, and
    // XenraPressControl is what holds the pressed look back.
    self.delaysContentTouches = NO;
    self.canCancelContentTouches = YES;
  }
  return self;
}

- (BOOL)touchesShouldCancelInContentView:(UIView*)view {
  return ![view isKindOfClass:[UISlider class]];
}

@end

@implementation XenraPressControl {
  BOOL waiting_;  // down, in a scroller, and not yet shown as pressed
}

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.translatesAutoresizingMaskIntoConstraints = NO;
    [self addTarget:self
                  action:@selector(fire)
        forControlEvents:UIControlEventTouchUpInside];
  }
  return self;
}

- (void)fire {
  XenraLog([NSString stringWithFormat:@"tap: %@", _title]);
  if (_action) _action();
}

// Only a scroller that can actually move has a reason to wait. A sheet whose rows
// all fit answers at once.
- (BOOL)mightBecomeScroll {
  for (UIView* view = self.superview; view; view = view.superview) {
    if (![view isKindOfClass:[UIScrollView class]]) continue;
    UIScrollView* scroll = (UIScrollView*)view;
    if (!scroll.scrollEnabled) continue;
    const CGSize content = scroll.contentSize;
    const CGSize bounds = scroll.bounds.size;
    if (content.height > bounds.height + 1 || content.width > bounds.width + 1 ||
        scroll.alwaysBounceVertical || scroll.alwaysBounceHorizontal) {
      return YES;
    }
  }
  return NO;
}

- (void)showPressed:(BOOL)pressed {
  if (pressed == _pressed) return;
  _pressed = pressed;
  [self pressedChanged];
}

- (void)delayPassed {
  waiting_ = NO;
  [self showPressed:YES];
}

- (void)stopWaiting {
  if (!waiting_) return;
  waiting_ = NO;
  [NSObject cancelPreviousPerformRequestsWithTarget:self
                                           selector:@selector(delayPassed)
                                             object:nil];
}

- (void)setHighlighted:(BOOL)highlighted {
  [super setHighlighted:highlighted];
  if (!highlighted) {
    [self stopWaiting];
    [self showPressed:NO];
  } else if (!_pressed && !waiting_) {
    if ([self mightBecomeScroll]) {
      waiting_ = YES;
      [self performSelector:@selector(delayPassed)
                 withObject:nil
                 afterDelay:XenraPressDelay];
    } else {
      [self showPressed:YES];
    }
  }
}

// A tap that ended inside the delay never lit up. It answers on release anyway,
// so the row shows it was touched.
- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  const BOOL flash = waiting_ && self.touchInside;
  [super touchesEnded:touches withEvent:event];
  if (!flash) return;
  [self showPressed:YES];
  __weak XenraPressControl* weak = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                               (int64_t)(kTapFlash * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   XenraPressControl* control = weak;
                   if (control && !control.highlighted) [control showPressed:NO];
                 });
}

- (void)pressedChanged {
}

@end

@implementation XenraPanelView {
  CAShapeLayer* shape_;
}

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.backgroundColor = UIColor.clearColor;
    shape_ = [CAShapeLayer layer];
    [self.layer insertSublayer:shape_ atIndex:0];
    self.chamfer = 20;
    self.rounded = NO;
  }
  return self;
}

// ChamferedPanelView for the library and dialogs; the rounded card with a solid
// outline is the settings screens' panel.
- (void)setRounded:(BOOL)rounded {
  _rounded = rounded;
  shape_.fillColor =
      (rounded ? XenraPanelFill()
               : XenraPick(0xE60D0A04, 0xC4E2EFB4, 0xE60B0B0C))
          .CGColor;
  shape_.strokeColor =
      (rounded ? XenraAccent() : XenraAccentAlpha(0x66)).CGColor;
  shape_.lineWidth = rounded ? 2 : 1.5;
  [self setNeedsLayout];
}

- (void)setFill:(UIColor*)fill {
  shape_.fillColor = fill.CGColor;
}

- (void)setStroke:(UIColor*)stroke width:(CGFloat)width {
  shape_.strokeColor = stroke.CGColor;
  shape_.lineWidth = width;
}

- (void)setChamfer:(CGFloat)chamfer {
  _chamfer = chamfer;
  [self setNeedsLayout];
}

- (void)layoutSubviews {
  [super layoutSubviews];
  const CGSize s = self.bounds.size;
  UIBezierPath* path;
  if (_rounded) {
    path = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:24];
  } else {
    const CGFloat c = MIN(_chamfer, MIN(s.width, s.height) / 2);
    path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(c, 0)];
    [path addLineToPoint:CGPointMake(s.width - c, 0)];
    [path addLineToPoint:CGPointMake(s.width, c)];
    [path addLineToPoint:CGPointMake(s.width, s.height - c)];
    [path addLineToPoint:CGPointMake(s.width - c, s.height)];
    [path addLineToPoint:CGPointMake(c, s.height)];
    [path addLineToPoint:CGPointMake(0, s.height - c)];
    [path addLineToPoint:CGPointMake(0, c)];
    [path closePath];
  }
  // A stray implicit animation here shows up as the outline lagging the panel
  // through a rotation.
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  shape_.path = path.CGPath;
  shape_.frame = self.bounds;
  [CATransaction commit];
}

@end

// An outlined field with its label cut into the border, Android's exposed
// dropdown. The label's own background is what makes the gap in the outline.
@implementation XenraFieldButton {
  UIView* box_;
  UILabel* caption_;
  UILabel* value_;
  UILabel* help_;
}

- (instancetype)initWithTitle:(NSString*)title action:(void (^)(void))action {
  self = [super initWithFrame:CGRectZero];
  if (self) {
    self.action = action;
    box_ = [[UIView alloc] init];
    box_.userInteractionEnabled = NO;
    box_.layer.cornerRadius = 8;
    box_.layer.borderWidth = 1.5;
    box_.layer.borderColor = XenraAccent().CGColor;
    box_.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:box_];
    value_ = XenraMakeLabel(nil, 17, UIFontWeightRegular, XenraText());
    [box_ addSubview:value_];
    UIImageView* chevron = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:@"arrowtriangle.down.fill"]];
    chevron.tintColor = XenraTextMuted();
    chevron.contentMode = UIViewContentModeScaleAspectFit;
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    [box_ addSubview:chevron];
    caption_ = XenraMakeLabel(nil, 12, UIFontWeightRegular, XenraTextMuted());
    caption_.backgroundColor = XenraPanelFill();
    [self addSubview:caption_];
    help_ = XenraMakeLabel(nil, 12, UIFontWeightRegular, XenraTextMuted());
    help_.numberOfLines = 0;
    [self addSubview:help_];
    [NSLayoutConstraint activateConstraints:@[
      [box_.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
      [box_.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
      [box_.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
      [box_.heightAnchor constraintEqualToConstant:56],
      [caption_.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                             constant:12],
      [caption_.centerYAnchor constraintEqualToAnchor:box_.topAnchor],
      [value_.leadingAnchor constraintEqualToAnchor:box_.leadingAnchor
                                           constant:16],
      [value_.centerYAnchor constraintEqualToAnchor:box_.centerYAnchor],
      [value_.trailingAnchor constraintLessThanOrEqualToAnchor:chevron.leadingAnchor
                                                      constant:-8],
      [chevron.trailingAnchor constraintEqualToAnchor:box_.trailingAnchor
                                             constant:-16],
      [chevron.centerYAnchor constraintEqualToAnchor:box_.centerYAnchor],
      [chevron.widthAnchor constraintEqualToConstant:12],
      [chevron.heightAnchor constraintEqualToConstant:12],
      [help_.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
      [help_.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                           constant:-16],
      [help_.topAnchor constraintEqualToAnchor:box_.bottomAnchor constant:6],
      [help_.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];
    self.title = title;
  }
  return self;
}

- (void)setTitle:(NSString*)title {
  [super setTitle:title];
  caption_.text = [NSString stringWithFormat:@" %@ ", title];
}

- (void)setValue:(NSString*)value {
  _value = [value copy];
  value_.text = value;
}

- (void)setDetail:(NSString*)detail {
  _detail = [detail copy];
  help_.text = detail;
}

- (void)setCaptionFill:(UIColor*)fill {
  caption_.backgroundColor = fill;
}

- (void)pressedChanged {
  box_.backgroundColor = self.pressed ? XenraAccentAlpha(0x22) : nil;
}

@end

@implementation XenraBladeButton {
  XenraBladeView* blade_;
  UILabel* title_;
  UILabel* subtitle_;
  NSLayoutConstraint* minimum_;
}

- (instancetype)initWithTitle:(NSString*)title action:(void (^)(void))action {
  self = [super initWithFrame:CGRectZero];
  if (self) {
    blade_ = [[XenraBladeView alloc] initWithFrame:CGRectZero];
    blade_.userInteractionEnabled = NO;
    blade_.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:blade_];
    title_ = XenraMakeLabel(nil, 17, UIFontWeightBold, XenraTextSecondary());
    // Android's blades are one line. Long German and Russian labels shrink a
    // little before they cut.
    title_.adjustsFontSizeToFitWidth = YES;
    title_.minimumScaleFactor = 0.8;
    subtitle_ = XenraMakeLabel(nil, 12, UIFontWeightRegular, XenraTextTertiary());
    subtitle_.numberOfLines = 2;
    subtitle_.hidden = YES;
    UIStackView* stack =
        [[UIStackView alloc] initWithArrangedSubviews:@[ title_, subtitle_ ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 2;
    stack.userInteractionEnabled = NO;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:stack];
    minimum_ = [self.heightAnchor constraintGreaterThanOrEqualToConstant:64];
    // The dashboard gives way a little on a phone in landscape.
    minimum_.priority = UILayoutPriorityRequired - 1;
    [NSLayoutConstraint activateConstraints:@[
      [blade_.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
      [blade_.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
      [blade_.topAnchor constraintEqualToAnchor:self.topAnchor],
      [blade_.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
      [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                          constant:24],
      [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                           constant:-16],
      [stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [stack.topAnchor constraintGreaterThanOrEqualToAnchor:self.topAnchor
                                                   constant:6],
      minimum_,
    ]];
    self.action = action;
    self.title = title;
  }
  return self;
}

- (UIColor*)titleColor {
  if (_primary) return _compact ? XenraOnAccent() : XenraBg();
  if (_destructive) return XenraWarning();
  return _dimmed ? XenraTextTertiary() : XenraTextSecondary();
}

- (void)paintTitle {
  title_.attributedText = XenraTrackedSpacing(
      self.title ?: @"", _compact ? 14 : 17, [self titleColor], 0.12);
  subtitle_.textColor = _primary ? XenraOnAccent() : XenraTextTertiary();
}

- (void)setTitle:(NSString*)title {
  [super setTitle:title];
  [self paintTitle];
}

- (void)setSubtitle:(NSString*)subtitle {
  _subtitle = [subtitle copy];
  subtitle_.text = subtitle;
  subtitle_.hidden = subtitle.length == 0;
}

- (void)paintBlade {
  blade_.state = self.pressed ? XenraBladePressed
                 : _chosen    ? XenraBladeChosen
                 : _padFocused ? XenraBladeFocused
                              : XenraBladeResting;
}

- (void)pressedChanged {
  [self paintBlade];
}

- (void)paintKind {
  blade_.kind = _primary       ? XenraBladeKindPrimary
                : _destructive ? XenraBladeKindDestructive
                               : XenraBladeKindPlain;
  [self paintTitle];
}

- (void)setPrimary:(BOOL)primary {
  _primary = primary;
  [self paintKind];
}

- (void)setDestructive:(BOOL)destructive {
  _destructive = destructive;
  [self paintKind];
}

- (void)setDimmed:(BOOL)dimmed {
  _dimmed = dimmed;
  [self paintTitle];
}

- (void)setCompact:(BOOL)compact {
  _compact = compact;
  blade_.compact = compact;
  minimum_.constant = compact ? 48 : 64;
  [self paintTitle];
}

- (void)setChosen:(BOOL)chosen {
  _chosen = chosen;
  [self paintBlade];
}

- (void)setPadFocused:(BOOL)padFocused {
  _padFocused = padFocused;
  [self paintBlade];
}

@end

@implementation XenraPillButton {
  UIView* shape_;
  UIView* wash_;
  UILabel* label_;
  UIImageView* iconView_;
  UIStackView* row_;
}

- (instancetype)initWithTitle:(NSString*)title
                        style:(XenraPillStyle)style
                       action:(void (^)(void))action {
  self = [super initWithFrame:CGRectZero];
  if (self) {
    _style = style;
    self.action = action;
    shape_ = [[UIView alloc] init];
    shape_.userInteractionEnabled = NO;
    shape_.clipsToBounds = YES;
    shape_.layer.cornerRadius = 22;
    shape_.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:shape_];
    wash_ = [[UIView alloc] init];
    wash_.alpha = 0;
    wash_.translatesAutoresizingMaskIntoConstraints = NO;
    [shape_ addSubview:wash_];
    label_ = XenraMakeLabel(nil, 14, UIFontWeightMedium, XenraText());
    label_.textAlignment = NSTextAlignmentCenter;
    label_.adjustsFontSizeToFitWidth = YES;
    label_.minimumScaleFactor = 0.8;
    iconView_ = [[UIImageView alloc] init];
    iconView_.contentMode = UIViewContentModeScaleAspectFit;
    iconView_.hidden = YES;
    [iconView_.widthAnchor constraintEqualToConstant:22].active = YES;
    [iconView_.heightAnchor constraintEqualToConstant:22].active = YES;
    row_ = [[UIStackView alloc] initWithArrangedSubviews:@[ iconView_, label_ ]];
    row_.spacing = 8;
    row_.alignment = UIStackViewAlignmentCenter;
    row_.userInteractionEnabled = NO;
    row_.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:row_];
    const CGFloat padding = style == XenraPillText ? 12 : 24;
    NSLayoutConstraint* hug = [self.widthAnchor constraintEqualToConstant:0];
    hug.priority = UILayoutPriorityDefaultLow - 1;
    [NSLayoutConstraint activateConstraints:@[
      [shape_.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
      [shape_.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
      [shape_.topAnchor constraintEqualToAnchor:self.topAnchor constant:4],
      [shape_.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-4],
      [wash_.leadingAnchor constraintEqualToAnchor:shape_.leadingAnchor],
      [wash_.trailingAnchor constraintEqualToAnchor:shape_.trailingAnchor],
      [wash_.topAnchor constraintEqualToAnchor:shape_.topAnchor],
      [wash_.bottomAnchor constraintEqualToAnchor:shape_.bottomAnchor],
      [row_.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
      [row_.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [row_.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.leadingAnchor
                                                      constant:padding],
      [row_.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor
                                                    constant:-padding],
      [self.heightAnchor constraintEqualToConstant:52],
      hug,
    ]];
    self.title = title;
    [self paint];
  }
  return self;
}

- (void)setTitle:(NSString*)title {
  [super setTitle:title];
  label_.text = title;
}

- (void)setIcon:(UIImage*)icon {
  _icon = icon;
  iconView_.image = [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
  iconView_.hidden = icon == nil;
}

- (void)setIconAtEnd:(BOOL)iconAtEnd {
  _iconAtEnd = iconAtEnd;
  [row_ removeArrangedSubview:iconView_];
  [row_ insertArrangedSubview:iconView_ atIndex:iconAtEnd ? 1 : 0];
}

- (void)setContentColor:(UIColor*)contentColor {
  _contentColor = contentColor;
  [self paint];
}

- (void)setStyle:(XenraPillStyle)style {
  _style = style;
  [self paint];
}

- (void)setDestructive:(BOOL)destructive {
  _destructive = destructive;
  [self paint];
}

- (void)setEnabled:(BOOL)enabled {
  [super setEnabled:enabled];
  [self paint];
}

- (void)paint {
  UIColor* fill = UIColor.clearColor;
  UIColor* stroke = nil;
  UIColor* content;
  UIColor* wash;
  if (_style == XenraPillFilled) {
    fill = _destructive ? XenraError() : XenraAccent();
    content = XenraBg();
    wash = XenraAccentLight();
  } else {
    content = _destructive ? XenraError() : XenraAccentLight();
    wash = _destructive ? [XenraError() colorWithAlphaComponent:0.2]
                        : XenraAccentAlpha(0x33);
    if (_style == XenraPillOutlined) {
      stroke = _destructive ? XenraError() : XenraAccentDark();
    }
  }
  if (_contentColor) content = _contentColor;
  if (!self.enabled) {
    content = [XenraTextMuted() colorWithAlphaComponent:0.5];
    if (_style == XenraPillFilled) fill = XenraOutlineVariant();
    if (_style == XenraPillOutlined) stroke = XenraOutlineVariant();
  }
  shape_.backgroundColor = fill;
  shape_.layer.borderWidth = stroke ? 1.5 : 0;
  shape_.layer.borderColor = stroke.CGColor;
  wash_.backgroundColor = wash;
  label_.textColor = content;
  iconView_.tintColor = content;
}

- (void)pressedChanged {
  const BOOL pressed = self.pressed;
  if (_style != XenraPillText) XenraSpringPress(self, pressed);
  [UIView animateWithDuration:pressed ? 0.12 : 0.18
                   animations:^{
                     self->wash_.alpha = pressed ? 1 : 0;
                   }];
}

@end

@implementation XenraChromeButton {
  UIView* shape_;
  UIView* wash_;
  UIImageView* iconView_;
  UILabel* label_;
}

- (instancetype)initWithTitle:(NSString*)title
                         icon:(UIImage*)icon
                       action:(void (^)(void))action {
  self = [super initWithFrame:CGRectZero];
  if (self) {
    self.action = action;
    shape_ = [[UIView alloc] init];
    shape_.userInteractionEnabled = NO;
    shape_.backgroundColor = XenraSurface();
    shape_.layer.cornerRadius = 8;
    shape_.layer.borderWidth = 1;
    shape_.layer.borderColor = XenraAccentAlpha(0x99).CGColor;
    shape_.layer.shadowColor = XenraShadow().CGColor;
    shape_.layer.shadowOpacity = XenraThemeMode == XenraThemeX360 ? 1 : 0.45;
    shape_.layer.shadowRadius = 12;
    shape_.layer.shadowOffset = CGSizeMake(0, 6);
    shape_.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:shape_];
    wash_ = [[UIView alloc] init];
    wash_.alpha = 0;
    wash_.backgroundColor = XenraAccentAlpha(0x33);
    wash_.layer.cornerRadius = 8;
    wash_.translatesAutoresizingMaskIntoConstraints = NO;
    [shape_ addSubview:wash_];
    iconView_ = [[UIImageView alloc] init];
    iconView_.tintColor = XenraAccent();
    iconView_.contentMode = UIViewContentModeScaleAspectFit;
    iconView_.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:iconView_];
    label_ = XenraMakeLabel(nil, 13, UIFontWeightBold, XenraAccent());
    [self addSubview:label_];
    [NSLayoutConstraint activateConstraints:@[
      [shape_.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
      [shape_.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
      [shape_.topAnchor constraintEqualToAnchor:self.topAnchor constant:6],
      [shape_.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-6],
      [wash_.leadingAnchor constraintEqualToAnchor:shape_.leadingAnchor],
      [wash_.trailingAnchor constraintEqualToAnchor:shape_.trailingAnchor],
      [wash_.topAnchor constraintEqualToAnchor:shape_.topAnchor],
      [wash_.bottomAnchor constraintEqualToAnchor:shape_.bottomAnchor],
      [iconView_.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                              constant:24],
      [iconView_.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [iconView_.widthAnchor constraintEqualToConstant:24],
      [iconView_.heightAnchor constraintEqualToConstant:24],
      [label_.leadingAnchor constraintEqualToAnchor:iconView_.trailingAnchor
                                           constant:8],
      [label_.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                            constant:-24],
      [label_.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [self.heightAnchor constraintEqualToConstant:44],
    ]];
    self.icon = icon;
    self.title = title;
  }
  return self;
}

- (void)setTitle:(NSString*)title {
  [super setTitle:title];
  label_.attributedText = XenraTrackedSpacing(title ?: @"", 13, XenraAccent(), 0.05);
}

- (void)setIcon:(UIImage*)icon {
  _icon = icon;
  iconView_.image = [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

- (void)layoutSubviews {
  [super layoutSubviews];
  shape_.layer.shadowPath =
      [UIBezierPath bezierPathWithRoundedRect:shape_.bounds cornerRadius:8].CGPath;
}

- (void)pressedChanged {
  const BOOL pressed = self.pressed;
  [UIView animateWithDuration:pressed ? 0.12 : 0.18
                   animations:^{
                     self->wash_.alpha = pressed ? 1 : 0;
                   }];
}

@end

// A cell of a toggle group or a segment row. Both are one frame with dividers, and
// differ only in what the cell holds.
@interface XenraGroupCell : XenraPressControl
@property(nonatomic, assign) BOOL selectedCell;
@property(nonatomic, strong) UIView* wash;
@property(nonatomic, copy) void (^paintContent)(BOOL selected);
@end

@implementation XenraGroupCell

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    _wash = [[UIView alloc] init];
    _wash.alpha = 0;
    _wash.userInteractionEnabled = NO;
    _wash.backgroundColor = XenraAccentAlpha(0x33);
    _wash.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_wash];
    [NSLayoutConstraint activateConstraints:@[
      [_wash.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
      [_wash.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
      [_wash.topAnchor constraintEqualToAnchor:self.topAnchor],
      [_wash.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];
  }
  return self;
}

- (void)setSelectedCell:(BOOL)selected {
  _selectedCell = selected;
  if (_paintContent) _paintContent(selected);
}

- (void)pressedChanged {
  const BOOL pressed = self.pressed;
  [UIView animateWithDuration:pressed ? 0.12 : 0.18
                   animations:^{
                     self.wash.alpha = pressed ? 1 : 0;
                   }];
}

@end

// The frame shared by the two groups: a clipped row of equal cells.
static UIStackView* GroupRow(UIView* owner, CGFloat radius, CGFloat stroke,
                             UIColor* strokeColor) {
  owner.translatesAutoresizingMaskIntoConstraints = NO;
  owner.clipsToBounds = YES;
  owner.layer.cornerRadius = radius;
  owner.layer.borderWidth = stroke;
  owner.layer.borderColor = strokeColor.CGColor;
  UIStackView* row = [[UIStackView alloc] init];
  row.distribution = UIStackViewDistributionFillEqually;
  row.spacing = stroke;
  row.translatesAutoresizingMaskIntoConstraints = NO;
  [owner addSubview:row];
  [NSLayoutConstraint activateConstraints:@[
    [row.leadingAnchor constraintEqualToAnchor:owner.leadingAnchor],
    [row.trailingAnchor constraintEqualToAnchor:owner.trailingAnchor],
    [row.topAnchor constraintEqualToAnchor:owner.topAnchor],
    [row.bottomAnchor constraintEqualToAnchor:owner.bottomAnchor],
    [owner.heightAnchor constraintEqualToConstant:44],
  ]];
  return row;
}

@implementation XenraIconToggleGroup {
  NSMutableArray<XenraGroupCell*>* cells_;
}

- (instancetype)initWithIcons:(NSArray<UIImage*>*)icons
                       titles:(NSArray<NSString*>*)titles {
  self = [super initWithFrame:CGRectZero];
  if (self) {
    UIStackView* row = GroupRow(self, 16, 1.5, XenraAccentDark());
    self.backgroundColor = XenraAccentDark();  // shows as the dividers
    cells_ = [NSMutableArray array];
    __weak XenraIconToggleGroup* weak = self;
    for (NSUInteger i = 0; i < icons.count; i++) {
      XenraGroupCell* cell = [[XenraGroupCell alloc] initWithFrame:CGRectZero];
      cell.title = i < titles.count ? titles[i] : nil;
      cell.accessibilityLabel = cell.title;
      UIImageView* image = [[UIImageView alloc]
          initWithImage:[icons[i]
                            imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
      image.contentMode = UIViewContentModeScaleAspectFit;
      image.translatesAutoresizingMaskIntoConstraints = NO;
      [cell addSubview:image];
      [NSLayoutConstraint activateConstraints:@[
        [image.centerXAnchor constraintEqualToAnchor:cell.centerXAnchor],
        [image.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        [image.widthAnchor constraintEqualToConstant:22],
        [image.heightAnchor constraintEqualToConstant:22],
        [cell.widthAnchor constraintEqualToConstant:44],
      ]];
      __weak XenraGroupCell* weakCell = cell;
      cell.paintContent = ^(BOOL selected) {
        weakCell.backgroundColor = selected ? XenraAccent() : XenraSurface();
        image.tintColor = selected ? XenraBg() : XenraAccentLight();
      };
      cell.action = ^{
        [weak tapped:(NSInteger)i];
      };
      [row addArrangedSubview:cell];
      [cells_ addObject:cell];
    }
    self.selectedIndex = -1;
  }
  return self;
}

- (void)setSelectedIndex:(NSInteger)index {
  _selectedIndex = index;
  for (NSUInteger i = 0; i < cells_.count; i++) {
    cells_[i].selectedCell = (NSInteger)i == index;
  }
}

- (void)tapped:(NSInteger)index {
  if (index == _selectedIndex) return;
  self.selectedIndex = index;
  if (_onChange) _onChange(index);
}

@end

@implementation XenraSegmentView {
  NSMutableArray<XenraGroupCell*>* cells_;
}

- (instancetype)initWithTitles:(NSArray<NSString*>*)titles {
  self = [super initWithFrame:CGRectZero];
  if (self) {
    UIStackView* row = GroupRow(self, 4, 1, XenraAccent());
    self.backgroundColor = XenraAccent();  // shows as the dividers
    cells_ = [NSMutableArray array];
    __weak XenraSegmentView* weak = self;
    for (NSUInteger i = 0; i < titles.count; i++) {
      XenraGroupCell* cell = [[XenraGroupCell alloc] initWithFrame:CGRectZero];
      cell.title = titles[i];
      UILabel* label = XenraMakeLabel(titles[i], 13, UIFontWeightBold, XenraAccent());
      label.textAlignment = NSTextAlignmentCenter;
      label.adjustsFontSizeToFitWidth = YES;
      label.minimumScaleFactor = 0.8;
      [cell addSubview:label];
      [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:6],
        [label.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor
                                             constant:-6],
        [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
      ]];
      __weak XenraGroupCell* weakCell = cell;
      cell.paintContent = ^(BOOL selected) {
        weakCell.backgroundColor = selected ? XenraAccent() : XenraSurfaceVariant();
        label.textColor = selected ? UIColor.blackColor : XenraAccent();
      };
      cell.action = ^{
        [weak tapped:(NSInteger)i];
      };
      [row addArrangedSubview:cell];
      [cells_ addObject:cell];
    }
    self.selectedIndex = 0;
  }
  return self;
}

- (void)setSelectedIndex:(NSInteger)index {
  _selectedIndex = index;
  for (NSUInteger i = 0; i < cells_.count; i++) {
    cells_[i].selectedCell = (NSInteger)i == index;
  }
}

- (void)tapped:(NSInteger)index {
  if (index == _selectedIndex) return;
  self.selectedIndex = index;
  if (_onChange) _onChange(index);
}

@end

@implementation XenraCardView {
  NSArray<NSLayoutConstraint*>* inset_;
}

- (void)setPadding:(CGFloat)padding {
  _padding = padding;
  inset_[0].constant = padding;
  inset_[1].constant = -padding;
  inset_[2].constant = padding;
  inset_[3].constant = -padding;
}

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.backgroundColor = XenraCardFill();
    self.layer.cornerRadius = 12;
    self.layer.borderWidth = 1;
    self.layer.borderColor = XenraAccentAlpha(0x33).CGColor;
    _body = [[UIStackView alloc] init];
    _body.axis = UILayoutConstraintAxisVertical;
    _body.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_body];
    _padding = 16;
    inset_ = @[
      [_body.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
      [_body.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                           constant:-16],
      [_body.topAnchor constraintEqualToAnchor:self.topAnchor constant:16],
      [_body.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-16],
    ];
    [NSLayoutConstraint activateConstraints:inset_];
  }
  return self;
}

@end

@implementation XenraSectionHeader

- (instancetype)initWithTitle:(NSString*)title style:(XenraSectionStyle)style {
  self = [super initWithFrame:CGRectZero];
  if (self) {
    self.translatesAutoresizingMaskIntoConstraints = NO;
    const BOOL pill = style == XenraSectionPill;
    UILabel* label = XenraMakeLabel(title, 14, UIFontWeightMedium, XenraAccentLight());
    if (!pill) label.attributedText = XenraTrackedSpacing(title, 12, XenraAccent(), 0.12);
    UIView* chip = [[UIView alloc] init];
    chip.translatesAutoresizingMaskIntoConstraints = NO;
    if (pill) {
      chip.backgroundColor = XenraAccentContainer();
      chip.layer.cornerRadius = 8;
    }
    [self addSubview:chip];
    [chip addSubview:label];
    const CGFloat h = pill ? 10 : 0, v = pill ? 4 : 0;
    [NSLayoutConstraint activateConstraints:@[
      [chip.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
      [chip.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor],
      [chip.topAnchor constraintEqualToAnchor:self.topAnchor],
      [chip.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
      [label.leadingAnchor constraintEqualToAnchor:chip.leadingAnchor constant:h],
      [label.trailingAnchor constraintEqualToAnchor:chip.trailingAnchor
                                           constant:-h],
      [label.topAnchor constraintEqualToAnchor:chip.topAnchor constant:v],
      [label.bottomAnchor constraintEqualToAnchor:chip.bottomAnchor constant:-v],
    ]];
  }
  return self;
}

@end

@implementation XenraSliderRow {
  UISlider* slider_;
  UILabel* readout_;
  float step_;
}

- (instancetype)initWithTitle:(NSString*)title
                       detail:(NSString*)detail
                      minimum:(float)minimum
                      maximum:(float)maximum
                         step:(float)step {
  self = [super initWithFrame:CGRectZero];
  if (self) {
    step_ = step;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel* name = XenraMakeLabel(title, 14, UIFontWeightRegular, XenraTextPrimary());
    name.numberOfLines = 0;
    UIStackView* stack = [[UIStackView alloc] initWithArrangedSubviews:@[ name ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    if (detail.length) {
      UILabel* hint = XenraMakeLabel(nil, 12, UIFontWeightRegular, XenraTextTertiary());
      hint.numberOfLines = 0;
      hint.attributedText = XenraBodyText(detail, 12, XenraTextTertiary());
      [stack addArrangedSubview:hint];
      [stack setCustomSpacing:8 afterView:name];
    }
    slider_ = [[UISlider alloc] init];
    slider_.minimumValue = minimum;
    slider_.maximumValue = maximum;
    slider_.minimumTrackTintColor = XenraAccent();
    slider_.maximumTrackTintColor = XenraAccentAlpha(0x33);
    slider_.thumbTintColor = XenraAccent();
    slider_.translatesAutoresizingMaskIntoConstraints = NO;
    [slider_ addTarget:self
                  action:@selector(moved)
        forControlEvents:UIControlEventValueChanged];
    [slider_ addTarget:self
                  action:@selector(released)
        forControlEvents:UIControlEventTouchUpInside |
                         UIControlEventTouchUpOutside |
                         UIControlEventTouchCancel];
    readout_ = XenraMakeLabel(nil, 13, UIFontWeightBold, XenraAccent());
    readout_.textAlignment = NSTextAlignmentRight;
    readout_.adjustsFontSizeToFitWidth = YES;
    readout_.minimumScaleFactor = 0.8;
    UIStackView* line =
        [[UIStackView alloc] initWithArrangedSubviews:@[ slider_, readout_ ]];
    line.spacing = 8;
    line.alignment = UIStackViewAlignmentCenter;
    [readout_.widthAnchor constraintEqualToConstant:52].active = YES;
    [stack addArrangedSubview:line];
    [stack setCustomSpacing:4 afterView:stack.arrangedSubviews[stack.arrangedSubviews.count - 2]];
    [self addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
      [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
      [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
      [stack.topAnchor constraintEqualToAnchor:self.topAnchor],
      [stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];
    [self updateReadout];
  }
  return self;
}

- (float)snapped:(float)value {
  return step_ > 0 ? roundf(value / step_) * step_ : value;
}

- (float)value {
  return [self snapped:slider_.value];
}

- (void)setValue:(float)value {
  slider_.value = value;
  [self updateReadout];
}

- (void)setFormat:(NSString* (^)(float))format {
  _format = [format copy];
  [self updateReadout];
}

- (void)updateReadout {
  const float value = self.value;
  readout_.text = _format ? _format(value)
                          : [NSString stringWithFormat:@"%d", (int)lroundf(value)];
}

- (void)moved {
  [self updateReadout];
  if (_onChange) _onChange(self.value);
}

- (void)released {
  slider_.value = self.value;
  if (_onCommit) _onCommit(self.value);
}

@end

@implementation XenraBladeItem
+ (instancetype)title:(NSString*)title action:(void (^)(void))action {
  XenraBladeItem* item = [[XenraBladeItem alloc] init];
  item.title = title;
  item.action = action;
  return item;
}
@end

@implementation XenraHintButton {
  UIView* wash_;
  UILabel* label_;
}

- (instancetype)initWithLetter:(NSString*)letter
                         title:(NSString*)title
                        action:(void (^)(void))action {
  self = [super initWithFrame:CGRectZero];
  if (self) {
    wash_ = [[UIView alloc] init];
    wash_.alpha = 0;
    wash_.userInteractionEnabled = NO;
    wash_.backgroundColor = XenraAccentAlpha(0x33);
    wash_.layer.cornerRadius = 20;
    wash_.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:wash_];
    UILabel* badge = XenraMakeLabel(letter, 14, UIFontWeightBold, XenraBg());
    badge.textAlignment = NSTextAlignmentCenter;
    badge.backgroundColor = XenraAccent();
    badge.layer.cornerRadius = 16;
    badge.layer.masksToBounds = YES;
    [self addSubview:badge];
    label_ = XenraMakeLabel(nil, 13, UIFontWeightBold, XenraTextTertiary());
    [self addSubview:label_];
    [NSLayoutConstraint activateConstraints:@[
      [wash_.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:-4],
      [wash_.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:12],
      [wash_.topAnchor constraintEqualToAnchor:self.topAnchor constant:-4],
      [wash_.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:4],
      [badge.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
      [badge.topAnchor constraintEqualToAnchor:self.topAnchor],
      [badge.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
      [badge.widthAnchor constraintEqualToConstant:32],
      [badge.heightAnchor constraintEqualToConstant:32],
      [label_.leadingAnchor constraintEqualToAnchor:badge.trailingAnchor constant:8],
      [label_.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
      [label_.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
    self.action = action;
    self.userInteractionEnabled = action != nil;
    self.title = title;
  }
  return self;
}

- (void)setAction:(void (^)(void))action {
  [super setAction:action];
  self.userInteractionEnabled = action != nil;
}

- (void)setTitle:(NSString*)title {
  [super setTitle:title];
  label_.attributedText =
      XenraTrackedSpacing(title ?: @"", 13, XenraTextTertiary(), 0.15);
}

// The badge is 32 pt. A thumb is not.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent*)event {
  return CGRectContainsPoint(CGRectInset(self.bounds, -12, -12), point);
}

- (void)pressedChanged {
  const BOOL pressed = self.pressed;
  [UIView animateWithDuration:pressed ? 0.12 : 0.18
                   animations:^{
                     self->wash_.alpha = pressed ? 1 : 0;
                   }];
}

@end

@implementation XenraBladeSheet {
  UIView* panel_;
  NSMutableArray<UIView*>* rows_;
  BOOL leaving_;
}

// Rows and the footer's right-hand side are what differ between the two kinds.
- (instancetype)initInHost:(UIView*)host
                     title:(NSString*)title
                  centered:(BOOL)centered {
  self = [super initWithFrame:host.bounds];
  if (self) {
    rows_ = [NSMutableArray array];
    self.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // Material's dialog dim.
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.32];
    // Outside the panel only. Left on the whole sheet, this recognizer won every
    // tap and cancelled the blade under the finger: the dialog closed and its
    // action never ran.
    UITapGestureRecognizer* outside =
        [[UITapGestureRecognizer alloc] initWithTarget:self
                                                action:@selector(dismiss)];
    outside.delegate = self;
    [self addGestureRecognizer:outside];
  }
  return self;
}

- (void)buildTitle:(NSString*)title
          centered:(BOOL)centered
              body:(UIView*)body
            footer:(UIView*)footer {
  XenraPanelView* panel = [[XenraPanelView alloc] initWithFrame:CGRectZero];
  panel.chamfer = 20;
  [panel setFill:XenraDialogFill()];
  panel.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:panel];
  panel_ = panel;

  UIStackView* column = [[UIStackView alloc] init];
  column.axis = UILayoutConstraintAxisVertical;
  column.translatesAutoresizingMaskIntoConstraints = NO;
  [panel addSubview:column];

  __weak XenraBladeSheet* weak = self;
  if (title.length) {
    UILabel* header = XenraMakeLabel(nil, 18, UIFontWeightBold, XenraAccent());
    header.attributedText = XenraScreenTitle(title);
    header.numberOfLines = 2;
    header.lineBreakMode = NSLineBreakByTruncatingTail;
    if (centered) header.textAlignment = NSTextAlignmentCenter;
    [header setContentCompressionResistancePriority:UILayoutPriorityRequired
                                            forAxis:UILayoutConstraintAxisVertical];
    // Kept clear of the close control, on both sides when it is centred.
    UIView* box = [[UIView alloc] init];
    [box addSubview:header];
    [NSLayoutConstraint activateConstraints:@[
      [header.leadingAnchor constraintEqualToAnchor:box.leadingAnchor
                                           constant:centered ? 28 : 0],
      [header.trailingAnchor constraintEqualToAnchor:box.trailingAnchor
                                            constant:-28],
      [header.topAnchor constraintEqualToAnchor:box.topAnchor],
      [header.bottomAnchor constraintEqualToAnchor:box.bottomAnchor],
      [box.heightAnchor constraintGreaterThanOrEqualToConstant:24],
    ]];
    [column addArrangedSubview:box];
    [column setCustomSpacing:centered ? 24 : 16 afterView:box];
  }

  UIScrollView* scroll = [[XenraScrollView alloc] init];
  scroll.translatesAutoresizingMaskIntoConstraints = NO;
  scroll.clipsToBounds = YES;
  [scroll addSubview:body];
  [column addArrangedSubview:scroll];
  [column setCustomSpacing:16 afterView:scroll];
  [column addArrangedSubview:footer];
  [footer setContentCompressionResistancePriority:UILayoutPriorityRequired
                                          forAxis:UILayoutConstraintAxisVertical];

  // The cut corners leave the top right free, and 24 pt of padding keeps the
  // glyph inside the panel's line.
  XenraPressControl* close = [[XenraPressControl alloc] initWithFrame:CGRectZero];
  close.title = @"Close";
  close.accessibilityLabel = @"Close";
  close.hidden = title.length == 0;
  close.action = ^{
    [weak dismiss];
  };
  UIImageView* glyph = [[UIImageView alloc]
      initWithImage:[UIImage
                        systemImageNamed:@"xmark"
                       withConfiguration:[UIImageSymbolConfiguration
                                             configurationWithPointSize:14
                                                                 weight:
                                                                     UIImageSymbolWeightSemibold]]];
  glyph.tintColor = XenraTextTertiary();
  glyph.translatesAutoresizingMaskIntoConstraints = NO;
  [close addSubview:glyph];
  [panel addSubview:close];

  NSLayoutConstraint* fit =
      [scroll.heightAnchor constraintEqualToAnchor:body.heightAnchor];
  fit.priority = UILayoutPriorityDefaultHigh;
  NSLayoutConstraint* preferred = [panel.widthAnchor constraintEqualToConstant:440];
  preferred.priority = UILayoutPriorityDefaultHigh;
  [NSLayoutConstraint activateConstraints:@[
    [panel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
    [panel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    [panel.widthAnchor constraintLessThanOrEqualToAnchor:self.widthAnchor
                                                constant:-32],
    [panel.heightAnchor constraintLessThanOrEqualToAnchor:self.heightAnchor
                                                 constant:-40],
    [column.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:24],
    [column.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor
                                          constant:-24],
    [column.topAnchor constraintEqualToAnchor:panel.topAnchor constant:24],
    [column.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-24],
    [body.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor],
    [body.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor],
    [body.topAnchor constraintEqualToAnchor:scroll.topAnchor],
    [body.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor],
    [body.widthAnchor constraintEqualToAnchor:scroll.widthAnchor],
    [close.topAnchor constraintEqualToAnchor:panel.topAnchor constant:12],
    [close.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-12],
    [close.widthAnchor constraintEqualToConstant:44],
    [close.heightAnchor constraintEqualToConstant:44],
    [glyph.centerXAnchor constraintEqualToAnchor:close.centerXAnchor],
    [glyph.centerYAnchor constraintEqualToAnchor:close.centerYAnchor],
    fit,
    preferred,
  ]];
}

// The B hint, and on the far side the A legend or whatever the sheet needs there.
- (UIView*)footerWithTrailing:(UIView*)trailing {
  __weak XenraBladeSheet* weak = self;
  XenraHintButton* back = [[XenraHintButton alloc] initWithLetter:@"B"
                                                            title:@"Back"
                                                           action:^{
                                                             [weak dismiss];
                                                           }];
  UIView* spacer = [[UIView alloc] init];
  UIStackView* footer = [[UIStackView alloc] initWithArrangedSubviews:@[ back, spacer ]];
  footer.alignment = UIStackViewAlignmentCenter;
  if (trailing) [footer addArrangedSubview:trailing];
  return footer;
}

- (void)appear {
  UIView* panel = panel_;
  self.alpha = 0;
  panel.transform = CGAffineTransformMakeScale(0.94, 0.94);
  [self layoutIfNeeded];
  XenraAnimate(0.22, 0, XenraCurveDecelerate,
               ^{
                 self.alpha = 1;
                 panel.transform = CGAffineTransformIdentity;
               },
               nil);
  // blade_enter through layout_anim_blades: 8% of the width, a 12% stagger.
  if (rows_.count) {
    XenraEnter(rows_, -0.08 * rows_.firstObject.bounds.size.width, 0, 0, 0.26 * 0.12,
               0.26, XenraCurveQuint);
  }
}

+ (instancetype)showIn:(UIView*)host
                 title:(NSString*)title
               message:(NSString*)message
                 items:(NSArray<XenraBladeItem*>*)items {
  XenraBladeSheet* sheet = [[XenraBladeSheet alloc] initInHost:host
                                                         title:title
                                                      centered:NO];
  __weak XenraBladeSheet* weak = sheet;

  UIStackView* body = [[UIStackView alloc] init];
  body.axis = UILayoutConstraintAxisVertical;
  body.spacing = 8;
  body.translatesAutoresizingMaskIntoConstraints = NO;
  if (message.length) {
    UILabel* text = XenraMakeLabel(nil, 14, UIFontWeightRegular, XenraTextSecondary());
    text.numberOfLines = 0;
    text.attributedText = XenraBodyText(message, 14, XenraTextSecondary());
    [body addArrangedSubview:text];
    if (items.count) [body setCustomSpacing:16 afterView:text];
  }
  for (XenraBladeItem* item in items) {
    void (^action)(void) = item.action;
    XenraBladeButton* blade =
        [[XenraBladeButton alloc] initWithTitle:item.title
                                         action:^{
                                           [weak dismiss];
                                           if (action) action();
                                         }];
    blade.compact = YES;
    blade.subtitle = item.subtitle;
    blade.destructive = item.destructive;
    blade.dimmed = item.dimmed;
    blade.primary = item.primary;
    [body addArrangedSubview:blade];
    [sheet->rows_ addObject:blade];
  }

  UIView* trailing;
  if (!items.count) {
    trailing = [[XenraPillButton alloc] initWithTitle:@"OK"
                                                style:XenraPillFilled
                                               action:^{
                                                 [weak dismiss];
                                               }];
  } else if (GCController.controllers.count) {
    trailing = [[XenraHintButton alloc] initWithLetter:@"A"
                                                 title:@"Select"
                                                action:nil];
  }
  [sheet buildTitle:title
           centered:NO
               body:body
             footer:[sheet footerWithTrailing:trailing]];
  [host addSubview:sheet];
  [sheet appear];
  return sheet;
}

+ (instancetype)showConfirmIn:(UIView*)host
                        title:(NSString*)title
                      message:(NSString*)message
                      leading:(XenraBladeItem*)leading
                     trailing:(XenraBladeItem*)trailing {
  XenraBladeSheet* sheet = [[XenraBladeSheet alloc] initInHost:host
                                                         title:title
                                                      centered:YES];
  __weak XenraBladeSheet* weak = sheet;
  XenraPillButton* (^pill)(XenraBladeItem*, XenraPillStyle) =
      ^XenraPillButton*(XenraBladeItem* item, XenraPillStyle style) {
        void (^action)(void) = item.action;
        XenraPillButton* button =
            [[XenraPillButton alloc] initWithTitle:item.title
                                             style:style
                                            action:^{
                                              [weak dismiss];
                                              if (action) action();
                                            }];
        button.destructive = item.destructive;
        return button;
      };
  UIStackView* pair = [[UIStackView alloc] initWithArrangedSubviews:@[
    pill(leading, XenraPillOutlined), pill(trailing, XenraPillFilled)
  ]];
  pair.spacing = 12;
  pair.distribution = UIStackViewDistributionFillEqually;

  UIStackView* body = [[UIStackView alloc] init];
  body.axis = UILayoutConstraintAxisVertical;
  body.translatesAutoresizingMaskIntoConstraints = NO;
  if (message.length) {
    UILabel* text = XenraMakeLabel(nil, 14, UIFontWeightRegular, XenraTextSecondary());
    text.numberOfLines = 0;
    text.textAlignment = NSTextAlignmentCenter;
    text.attributedText = XenraBodyText(message, 14, XenraTextSecondary());
    [body addArrangedSubview:text];
    [body setCustomSpacing:24 afterView:text];
  }
  [body addArrangedSubview:pair];

  [sheet buildTitle:title
           centered:YES
               body:body
             footer:[sheet footerWithTrailing:nil]];
  [host addSubview:sheet];
  [sheet appear];
  return sheet;
}

+ (instancetype)topSheetIn:(UIView*)host {
  for (UIView* view in host.subviews.reverseObjectEnumerator) {
    if ([view isKindOfClass:[XenraBladeSheet class]]) {
      XenraBladeSheet* sheet = (XenraBladeSheet*)view;
      if (!sheet->leaving_) return sheet;
    }
  }
  return nil;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer*)recognizer
       shouldReceiveTouch:(UITouch*)touch {
  return touch.view == self;
}

- (void)dismiss {
  if (leaving_) return;
  leaving_ = YES;
  self.userInteractionEnabled = NO;
  XenraAnimate(0.15, 0, XenraCurveStandard,
               ^{
                 self.alpha = 0;
               },
               ^{
                 [self removeFromSuperview];
               });
  if (_onDismiss) _onDismiss();
}

@end

@implementation XenraHintBar {
  XenraHintButton* back_;
  XenraHintButton* select_;
  NSLayoutConstraint* height_;
  NSLayoutConstraint* leading_;
  NSLayoutConstraint* trailing_;
  NSLayoutConstraint* center_;
}

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.translatesAutoresizingMaskIntoConstraints = NO;
    __weak XenraHintBar* weak = self;
    back_ = [[XenraHintButton alloc] initWithLetter:@"B"
                                              title:@"Back"
                                             action:^{
                                               XenraHintBar* bar = weak;
                                               if (bar.onBack) bar.onBack();
                                             }];
    select_ = [[XenraHintButton alloc] initWithLetter:@"A"
                                                title:@"Select"
                                               action:nil];
    [self addSubview:back_];
    [self addSubview:select_];
    leading_ = [back_.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                                   constant:24];
    trailing_ = [select_.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                       constant:-24];
    center_ = [back_.centerYAnchor constraintEqualToAnchor:self.centerYAnchor];
    height_ = [self.heightAnchor constraintEqualToConstant:80];
    [NSLayoutConstraint activateConstraints:@[
      leading_,
      trailing_,
      center_,
      [select_.centerYAnchor constraintEqualToAnchor:back_.centerYAnchor],
      height_,
    ]];
    _showsSelect = YES;
  }
  return self;
}

- (void)setPanelStyle:(BOOL)panelStyle {
  _panelStyle = panelStyle;
  // Padding 16 at the sides, 4 above and 12 below the badge.
  self.backgroundColor = panelStyle ? XenraPick(0xE60D0A04, 0xC4E2EFB4, 0xE60B0B0C)
                                    : nil;
  leading_.constant = panelStyle ? 16 : 24;
  trailing_.constant = panelStyle ? -16 : -24;
  height_.constant = panelStyle ? 48 : 80;
  center_.constant = panelStyle ? -4 : 0;
}

- (void)setOnSelect:(void (^)(void))onSelect {
  _onSelect = [onSelect copy];
  __weak XenraHintBar* weak = self;
  if (!onSelect) {
    select_.action = nil;
    return;
  }
  select_.action = ^{
    XenraHintBar* bar = weak;
    if (bar.onSelect) bar.onSelect();
  };
}

- (void)setBackTitle:(NSString*)title {
  _backTitle = [title copy];
  back_.title = title;
}

- (void)setSelectTitle:(NSString*)title {
  _selectTitle = [title copy];
  select_.title = title;
}

- (void)setShowsSelect:(BOOL)shows {
  _showsSelect = shows;
  select_.hidden = !shows;
}

@end

void XenraToast(UIView* host, NSString* text) {
  UIView* toast = [[UIView alloc] init];
  toast.backgroundColor = XenraSurface();
  toast.layer.cornerRadius = 8;
  toast.layer.borderWidth = 1;
  toast.layer.borderColor = XenraAccentAlpha(0x66).CGColor;
  toast.userInteractionEnabled = NO;
  toast.translatesAutoresizingMaskIntoConstraints = NO;
  UILabel* label = XenraMakeLabel(text, 14, UIFontWeightRegular, XenraTextPrimary());
  label.numberOfLines = 0;
  label.textAlignment = NSTextAlignmentCenter;
  [toast addSubview:label];
  [host addSubview:toast];
  [NSLayoutConstraint activateConstraints:@[
    [label.leadingAnchor constraintEqualToAnchor:toast.leadingAnchor constant:16],
    [label.trailingAnchor constraintEqualToAnchor:toast.trailingAnchor constant:-16],
    [label.topAnchor constraintEqualToAnchor:toast.topAnchor constant:10],
    [label.bottomAnchor constraintEqualToAnchor:toast.bottomAnchor constant:-10],
    [toast.centerXAnchor constraintEqualToAnchor:host.centerXAnchor],
    [toast.bottomAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.bottomAnchor
                                       constant:-72],
    [toast.widthAnchor constraintLessThanOrEqualToAnchor:host.widthAnchor
                                                constant:-48],
  ]];
  toast.alpha = 0;
  XenraAnimate(0.2, 0, XenraCurveStandard,
               ^{
                 toast.alpha = 1;
               },
               nil);
  XenraAnimate(0.25, 2.2, XenraCurveStandard,
               ^{
                 toast.alpha = 0;
               },
               ^{
                 [toast removeFromSuperview];
               });
}

@interface XenraVectorPath ()
@property(nonatomic, strong) UIBezierPath* path;
@property(nonatomic, assign) CGFloat strokeWidth;  // 0 fills
@end

namespace {

// Reads pathData, which is SVG's path grammar.
class PathReader {
 public:
  explicit PathReader(const char* text) : p_(text) {}

  UIBezierPath* Read() {
    UIBezierPath* path = [UIBezierPath bezierPath];
    CGPoint at = CGPointZero, start = CGPointZero, control = CGPointZero;
    char command = 0, last = 0;
    while (true) {
      SkipSeparators();
      if (!*p_) break;
      if ((*p_ >= 'a' && *p_ <= 'z') || (*p_ >= 'A' && *p_ <= 'Z')) command = *p_++;
      const BOOL relative = command >= 'a';
      const CGPoint origin = relative ? at : CGPointZero;
      switch (command | 0x20) {
        case 'm': {
          at = Point(origin);
          [path moveToPoint:at];
          start = at;
          // Further pairs after a move are lines.
          command = relative ? 'l' : 'L';
          break;
        }
        case 'l':
          at = Point(origin);
          [path addLineToPoint:at];
          break;
        case 'h':
          at.x = origin.x + Number();
          [path addLineToPoint:at];
          break;
        case 'v':
          at.y = origin.y + Number();
          [path addLineToPoint:at];
          break;
        case 'c': {
          const CGPoint c1 = Point(origin);
          control = Point(origin);
          at = Point(origin);
          [path addCurveToPoint:at controlPoint1:c1 controlPoint2:control];
          break;
        }
        case 's': {
          const char kind = last | 0x20;
          const CGPoint c1 =
              kind == 'c' || kind == 's'
                  ? CGPointMake(2 * at.x - control.x, 2 * at.y - control.y)
                  : at;
          control = Point(origin);
          at = Point(origin);
          [path addCurveToPoint:at controlPoint1:c1 controlPoint2:control];
          break;
        }
        case 'q': {
          control = Point(origin);
          at = Point(origin);
          [path addQuadCurveToPoint:at controlPoint:control];
          break;
        }
        case 't': {
          const char kind = last | 0x20;
          control = kind == 'q' || kind == 't'
                        ? CGPointMake(2 * at.x - control.x, 2 * at.y - control.y)
                        : at;
          at = Point(origin);
          [path addQuadCurveToPoint:at controlPoint:control];
          break;
        }
        case 'a': {
          const CGFloat rx = Number(), ry = Number(), angle = Number();
          const BOOL large = Flag(), sweep = Flag();
          const CGPoint end = Point(origin);
          Arc(path, at, rx, ry, angle, large, sweep, end);
          at = end;
          break;
        }
        case 'z':
          [path closePath];
          at = start;
          command = 0;  // Takes no numbers: anything but a command ends the path.
          break;
        default:
          return path;  // Not pathData: stop rather than spin.
      }
      last = command;
    }
    return path;
  }

 private:
  void SkipSeparators() {
    while (*p_ == ' ' || *p_ == ',' || *p_ == '\n' || *p_ == '\t' || *p_ == '\r') {
      p_++;
    }
  }

  CGFloat Number() {
    SkipSeparators();
    char* end = nullptr;
    const double value = strtod(p_, &end);
    if (end == p_) {
      // Malformed: finish the path here.
      p_ += strlen(p_);
      return 0;
    }
    p_ = end;
    return value;
  }

  BOOL Flag() {
    SkipSeparators();
    return *p_ ? *p_++ == '1' : NO;
  }

  CGPoint Point(CGPoint origin) {
    const CGFloat x = Number();
    const CGFloat y = Number();
    return CGPointMake(origin.x + x, origin.y + y);
  }

  // The SVG endpoint form to centre form, then a cubic per quarter turn.
  static void Arc(UIBezierPath* path, CGPoint from, CGFloat rx, CGFloat ry,
                  CGFloat degrees, BOOL large, BOOL sweep, CGPoint to) {
    rx = fabs(rx);
    ry = fabs(ry);
    if (rx == 0 || ry == 0) {
      [path addLineToPoint:to];
      return;
    }
    const double phi = degrees * M_PI / 180;
    const double cosPhi = cos(phi), sinPhi = sin(phi);
    const double dx = (from.x - to.x) / 2, dy = (from.y - to.y) / 2;
    const double x1 = cosPhi * dx + sinPhi * dy;
    const double y1 = -sinPhi * dx + cosPhi * dy;
    const double lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry);
    if (lambda > 1) {
      rx *= sqrt(lambda);
      ry *= sqrt(lambda);
    }
    const double numerator =
        rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1;
    const double denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1;
    double scale = denominator > 0 ? sqrt(fmax(0, numerator / denominator)) : 0;
    if (large == sweep) scale = -scale;
    const double cx1 = scale * rx * y1 / ry;
    const double cy1 = -scale * ry * x1 / rx;
    const double cx = cosPhi * cx1 - sinPhi * cy1 + (from.x + to.x) / 2;
    const double cy = sinPhi * cx1 + cosPhi * cy1 + (from.y + to.y) / 2;
    const double theta = atan2((y1 - cy1) / ry, (x1 - cx1) / rx);
    double delta = atan2((-y1 - cy1) / ry, (-x1 - cx1) / rx) - theta;
    if (sweep && delta < 0) delta += 2 * M_PI;
    if (!sweep && delta > 0) delta -= 2 * M_PI;
    const int segments = (int)ceil(fabs(delta) / (M_PI / 2) - 1e-9);
    const double step = delta / MAX(segments, 1);
    const double t = 4.0 / 3.0 * tan(step / 4);
    double a = theta;
    for (int i = 0; i < segments; i++) {
      const double b = a + step;
      auto place = [&](double ux, double uy) {
        return CGPointMake(cx + cosPhi * rx * ux - sinPhi * ry * uy,
                           cy + sinPhi * rx * ux + cosPhi * ry * uy);
      };
      const CGPoint c1 = place(cos(a) - t * sin(a), sin(a) + t * cos(a));
      const CGPoint c2 = place(cos(b) + t * sin(b), sin(b) - t * cos(b));
      const CGPoint end = i == segments - 1 ? to : place(cos(b), sin(b));
      [path addCurveToPoint:end controlPoint1:c1 controlPoint2:c2];
      a = b;
    }
  }

  const char* p_;
};

}  // namespace

@implementation XenraVectorPath

+ (instancetype)fill:(NSString*)data {
  XenraVectorPath* vector = [[XenraVectorPath alloc] init];
  vector.path = PathReader(data.UTF8String).Read();
  return vector;
}

+ (instancetype)stroke:(NSString*)data width:(CGFloat)width {
  XenraVectorPath* vector = [self fill:data];
  vector.strokeWidth = width;
  return vector;
}

@end

UIImage* XenraVectorImage(NSArray<XenraVectorPath*>* paths, CGFloat viewport,
                          CGFloat size) {
  UIGraphicsImageRenderer* renderer =
      [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size)];
  UIImage* image =
      [renderer imageWithActions:^(UIGraphicsImageRendererContext* context) {
        CGContextRef cg = context.CGContext;
        CGContextScaleCTM(cg, size / viewport, size / viewport);
        CGContextSetLineCap(cg, kCGLineCapRound);
        CGContextSetLineJoin(cg, kCGLineJoinRound);
        CGContextSetFillColorWithColor(cg, UIColor.blackColor.CGColor);
        CGContextSetStrokeColorWithColor(cg, UIColor.blackColor.CGColor);
        for (XenraVectorPath* vector in paths) {
          CGContextAddPath(cg, vector.path.CGPath);
          if (vector.strokeWidth > 0) {
            CGContextSetLineWidth(cg, vector.strokeWidth);
            CGContextStrokePath(cg);
          } else {
            CGContextFillPath(cg);
          }
        }
      }];
  return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

UIImage* XenraMaterialIcon(NSString* data, CGFloat size) {
  XenraVectorPath* vector = [XenraVectorPath fill:data];
  [vector.path applyTransform:CGAffineTransformMakeTranslation(0, 960)];
  return XenraVectorImage(@[ vector ], 960, size);
}

UIImage* XenraOrientationIcon(NSString* orientation, CGFloat size) {
  if ([orientation isEqual:@"portrait"]) {
    return XenraVectorImage(
        @[
          [XenraVectorPath stroke:@"M388,140 H572 A92,92 0 0 1 664,232 V728 "
                                   "A92,92 0 0 1 572,820 H388 "
                                   "A92,92 0 0 1 296,728 V232 "
                                   "A92,92 0 0 1 388,140 Z"
                            width:52],
          [XenraVectorPath fill:@"M430,748 H530 A20,20 0 0 1 530,788 H430 "
                                 "A20,20 0 0 1 430,748 Z"],
        ],
        960, size);
  }
  if ([orientation isEqual:@"landscape"]) {
    return XenraVectorImage(
        @[
          [XenraVectorPath stroke:@"M232,296 H728 A92,92 0 0 1 820,388 V572 "
                                   "A92,92 0 0 1 728,664 H232 "
                                   "A92,92 0 0 1 140,572 V388 "
                                   "A92,92 0 0 1 232,296 Z"
                            width:52],
          [XenraVectorPath fill:@"M748,430 V530 A20,20 0 0 1 708,530 V430 "
                                 "A20,20 0 0 1 748,430 Z"],
        ],
        960, size);
  }
  return XenraVectorImage(
      @[
        [XenraVectorPath stroke:@"M7,3h10a2,2 0,0 1,2 2v14a2,2 0,0 1,-2 2H7"
                                 "a2,2 0,0 1,-2 -2V5a2,2 0,0 1,2 -2M9,18h6"
                          width:1.8],
        [XenraVectorPath stroke:@"M3.2,9.2A9,9 0,0 1,8.3 2.3M2.7,5.2l0.5,4 3.8,-1.1"
                                 "M20.8,14.8a9,9 0,0 1,-5.1 6.9"
                                 "M21.3,18.8l-0.5,-4 -3.8,1.1"
                          width:1.5],
      ],
      24, size);
}
