#import "XenraUI.h"

#import "XenraBladeView.h"
#import "XenraMotion.h"
#import "XenraScreens.h"
#import "XenraTheme.h"

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

NSAttributedString* XenraTracked(NSString* text, CGFloat size, UIColor* color) {
  return [[NSAttributedString alloc]
      initWithString:text.uppercaseString
          attributes:@{
            NSFontAttributeName : [UIFont systemFontOfSize:size
                                                    weight:UIFontWeightBold],
            NSForegroundColorAttributeName : color,
            NSKernAttributeName : @(size * 0.1),
          }];
}

@implementation XenraPanelView {
  CAShapeLayer* shape_;
}

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.backgroundColor = UIColor.clearColor;
    shape_ = [CAShapeLayer layer];
    [self.layer insertSublayer:shape_ atIndex:0];
    self.chamfer = 28;
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
      (rounded ? XenraAccent() : XenraAccentAlpha(0x55)).CGColor;
  shape_.lineWidth = rounded ? 2 : 1.5;
  [self setNeedsLayout];
}

- (void)setFill:(UIColor*)fill {
  shape_.fillColor = fill.CGColor;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  const CGSize s = self.bounds.size;
  if (_rounded) {
    shape_.path = [UIBezierPath bezierPathWithRoundedRect:self.bounds
                                             cornerRadius:24]
                      .CGPath;
  } else {
    const CGFloat c = MIN(_chamfer, MIN(s.width, s.height) / 2);
    UIBezierPath* path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(c, 0)];
    [path addLineToPoint:CGPointMake(s.width - c, 0)];
    [path addLineToPoint:CGPointMake(s.width, c)];
    [path addLineToPoint:CGPointMake(s.width, s.height - c)];
    [path addLineToPoint:CGPointMake(s.width - c, s.height)];
    [path addLineToPoint:CGPointMake(c, s.height)];
    [path addLineToPoint:CGPointMake(0, s.height - c)];
    [path addLineToPoint:CGPointMake(0, c)];
    [path closePath];
    shape_.path = path.CGPath;
  }
  shape_.frame = self.bounds;
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
    _action = [action copy];
    self.translatesAutoresizingMaskIntoConstraints = NO;
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
    caption_ = XenraMakeLabel(
        [NSString stringWithFormat:@" %@ ", title], 12, UIFontWeightRegular,
        XenraTextMuted());
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
    [self addTarget:self
                  action:@selector(fire)
        forControlEvents:UIControlEventTouchUpInside];
  }
  return self;
}

- (void)setValue:(NSString*)value {
  _value = [value copy];
  value_.text = value;
}

- (void)setDetail:(NSString*)detail {
  _detail = [detail copy];
  help_.text = detail;
}

- (void)setHighlighted:(BOOL)highlighted {
  [super setHighlighted:highlighted];
  box_.backgroundColor = highlighted ? XenraAccentAlpha(0x22) : nil;
}

- (void)fire {
  XenraLog([NSString stringWithFormat:@"tap: %@", caption_.text]);
  if (_action) _action();
}

@end

@implementation XenraBladeButton {
  XenraBladeView* blade_;
  UILabel* title_;
  UILabel* subtitle_;
}

- (instancetype)initWithTitle:(NSString*)title action:(void (^)(void))action {
  self = [super initWithFrame:CGRectZero];
  if (self) {
    self.translatesAutoresizingMaskIntoConstraints = NO;
    blade_ = [[XenraBladeView alloc] initWithFrame:CGRectZero];
    blade_.userInteractionEnabled = NO;
    blade_.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:blade_];
    title_ = XenraMakeLabel(nil, 17, UIFontWeightSemibold, XenraText());
    subtitle_ = XenraMakeLabel(nil, 12, UIFontWeightRegular, XenraTextMuted());
    subtitle_.numberOfLines = 2;
    UIStackView* stack =
        [[UIStackView alloc] initWithArrangedSubviews:@[ title_, subtitle_ ]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 2;
    stack.userInteractionEnabled = NO;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
      [blade_.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
      [blade_.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
      [blade_.topAnchor constraintEqualToAnchor:self.topAnchor],
      [blade_.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
      [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                          constant:24],
      [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                           constant:-24],
      [stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [self.heightAnchor constraintGreaterThanOrEqualToConstant:64],
    ]];
    self.title = title;
    _action = [action copy];
    [self addTarget:self
                  action:@selector(fire)
        forControlEvents:UIControlEventTouchUpInside];
  }
  return self;
}

- (void)setTitle:(NSString*)title {
  _title = [title copy];
  title_.attributedText = XenraTracked(title ?: @"", 16, [self titleColor]);
}

- (void)setSubtitle:(NSString*)subtitle {
  _subtitle = [subtitle copy];
  subtitle_.text = subtitle;
  subtitle_.hidden = subtitle.length == 0;
}

- (UIColor*)titleColor {
  if (_primary) return XenraOnAccent();
  if (_destructive) return XenraError();
  return _dimmed ? XenraTextMuted() : XenraText();
}

- (void)refresh {
  blade_.state = self.isHighlighted ? XenraBladePressed
                 : _chosen          ? XenraBladeChosen
                                    : XenraBladeResting;
  blade_.primary = _primary;
  self.title = _title;
  subtitle_.textColor = _primary ? XenraOnAccent() : XenraTextMuted();
}

- (void)setPrimary:(BOOL)primary {
  _primary = primary;
  [self refresh];
}

- (void)setHighlighted:(BOOL)highlighted {
  [super setHighlighted:highlighted];
  [self refresh];
}
- (void)setChosen:(BOOL)chosen {
  _chosen = chosen;
  [self refresh];
}
- (void)setDestructive:(BOOL)destructive {
  _destructive = destructive;
  [self refresh];
}
- (void)setDimmed:(BOOL)dimmed {
  _dimmed = dimmed;
  [self refresh];
}

- (void)fire {
  XenraLog([NSString stringWithFormat:@"tap: %@", _title]);
  if (_action) _action();
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

@implementation XenraBladeSheet

+ (void)showIn:(UIView*)host
         title:(NSString*)title
       message:(NSString*)message
         items:(NSArray<XenraBladeItem*>*)items {
  XenraBladeSheet* sheet = [[XenraBladeSheet alloc] initWithFrame:host.bounds];
  sheet.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  sheet.backgroundColor = [UIColor colorWithWhite:0 alpha:0.53];
  [sheet addGestureRecognizer:[[UITapGestureRecognizer alloc]
                                  initWithTarget:sheet
                                          action:@selector(dismiss)]];

  XenraPanelView* panel = [[XenraPanelView alloc] initWithFrame:CGRectZero];
  panel.translatesAutoresizingMaskIntoConstraints = NO;
  [sheet addSubview:panel];

  UIStackView* stack = [[UIStackView alloc] init];
  stack.axis = UILayoutConstraintAxisVertical;
  stack.spacing = 8;
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  if (title.length) {
    UILabel* header = XenraMakeLabel(nil, 15, UIFontWeightBold, XenraAccent());
    header.attributedText = XenraTracked(title, 15, XenraAccent());
    header.numberOfLines = 2;
    [stack addArrangedSubview:header];
  }
  if (message.length) {
    UILabel* body =
        XenraMakeLabel(message, 13, UIFontWeightRegular, XenraTextMuted());
    body.numberOfLines = 0;
    [stack addArrangedSubview:body];
  }
  __weak XenraBladeSheet* weak = sheet;
  for (XenraBladeItem* item in items) {
    void (^action)(void) = item.action;
    XenraBladeButton* blade = [[XenraBladeButton alloc]
        initWithTitle:item.title
               action:^{
                 [weak dismiss];
                 if (action) action();
               }];
    blade.subtitle = item.subtitle;
    blade.destructive = item.destructive;
    blade.dimmed = item.dimmed;
    [stack addArrangedSubview:blade];
  }

  UIScrollView* scroll = [[UIScrollView alloc] init];
  scroll.translatesAutoresizingMaskIntoConstraints = NO;
  [scroll addSubview:stack];
  [panel addSubview:scroll];

  NSLayoutConstraint* fit =
      [scroll.heightAnchor constraintEqualToAnchor:stack.heightAnchor];
  fit.priority = UILayoutPriorityDefaultHigh;
  NSLayoutConstraint* preferred = [panel.widthAnchor constraintEqualToConstant:440];
  preferred.priority = UILayoutPriorityDefaultHigh;
  [NSLayoutConstraint activateConstraints:@[
    [panel.centerXAnchor constraintEqualToAnchor:sheet.centerXAnchor],
    [panel.centerYAnchor constraintEqualToAnchor:sheet.centerYAnchor],
    [panel.widthAnchor constraintLessThanOrEqualToAnchor:sheet.widthAnchor
                                                constant:-32],
    [panel.heightAnchor constraintLessThanOrEqualToAnchor:sheet.heightAnchor
                                                 constant:-40],
    [scroll.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor
                                         constant:18],
    [scroll.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor
                                          constant:-18],
    [scroll.topAnchor constraintEqualToAnchor:panel.topAnchor constant:18],
    [scroll.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor
                                        constant:-18],
    [stack.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor],
    [stack.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor],
    [stack.topAnchor constraintEqualToAnchor:scroll.topAnchor],
    [stack.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor],
    [stack.widthAnchor constraintEqualToAnchor:scroll.widthAnchor],
    fit,
    preferred,
  ]];

  sheet.alpha = 0;
  panel.transform = CGAffineTransformMakeScale(0.94, 0.94);
  [host addSubview:sheet];
  XenraAnimate(0.22, 0, XenraCurveDecelerate,
               ^{
                 sheet.alpha = 1;
                 panel.transform = CGAffineTransformIdentity;
               },
               nil);
}

- (void)dismiss {
  self.userInteractionEnabled = NO;
  XenraAnimate(0.15, 0, XenraCurveStandard,
               ^{
                 self.alpha = 0;
               },
               ^{
                 [self removeFromSuperview];
               });
}

@end

@implementation XenraHintBar {
  UIButton* back_;
}

static UIView* HintPill(NSString* letter, NSString* text, UIColor* color) {
  UILabel* badge = XenraMakeLabel(letter, 14, UIFontWeightBold, XenraOnAccent());
  badge.textAlignment = NSTextAlignmentCenter;
  badge.backgroundColor = color;
  badge.layer.cornerRadius = 15;
  badge.layer.masksToBounds = YES;
  [NSLayoutConstraint activateConstraints:@[
    [badge.widthAnchor constraintEqualToConstant:30],
    [badge.heightAnchor constraintEqualToConstant:30],
  ]];
  UILabel* label = XenraMakeLabel(nil, 13, UIFontWeightBold, XenraTextMuted());
  label.attributedText = XenraTracked(text, 13, XenraTextMuted());
  UIStackView* stack =
      [[UIStackView alloc] initWithArrangedSubviews:@[ badge, label ]];
  stack.spacing = 8;
  stack.alignment = UIStackViewAlignmentCenter;
  stack.userInteractionEnabled = NO;
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  return stack;
}

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.translatesAutoresizingMaskIntoConstraints = NO;
    back_ = [UIButton buttonWithType:UIButtonTypeCustom];
    back_.translatesAutoresizingMaskIntoConstraints = NO;
    [back_ addTarget:self
                  action:@selector(backTapped)
        forControlEvents:UIControlEventTouchUpInside];
    UIView* b = HintPill(@"B", @"Back", XenraAccent());
    [back_ addSubview:b];
    self.backgroundColor = XenraPick(0xCC0A0A06, 0x66E2EFB4, 0xCC0A0A0B);
    UIView* a = HintPill(@"A", @"Select", XenraAccent());
    [self addSubview:back_];
    [self addSubview:a];
    [NSLayoutConstraint activateConstraints:@[
      [back_.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                          constant:24],
      [back_.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [b.leadingAnchor constraintEqualToAnchor:back_.leadingAnchor],
      [b.trailingAnchor constraintEqualToAnchor:back_.trailingAnchor],
      [b.topAnchor constraintEqualToAnchor:back_.topAnchor],
      [b.bottomAnchor constraintEqualToAnchor:back_.bottomAnchor],
      [a.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                       constant:-24],
      [a.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [self.heightAnchor constraintEqualToConstant:48],
    ]];
  }
  return self;
}

- (void)backTapped {
  if (_onBack) _onBack();
}

@end
