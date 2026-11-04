#import "XenraUI.h"

#import "XenraBladeView.h"
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
    shape_.fillColor = XenraPanelFill().CGColor;
    shape_.strokeColor = [XenraAccent() colorWithAlphaComponent:0.4].CGColor;
    shape_.lineWidth = 1;
    [self.layer insertSublayer:shape_ atIndex:0];
  }
  return self;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  UIBezierPath* path = [UIBezierPath bezierPath];
  XenraPathBlade(path, self.bounds, 20);
  shape_.path = path.CGPath;
  shape_.frame = self.bounds;
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
    title_ = XenraMakeLabel(nil, 16, UIFontWeightSemibold, XenraText());
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
                                          constant:22],
      [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                           constant:-22],
      [stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [self.heightAnchor constraintGreaterThanOrEqualToConstant:56],
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
  title_.attributedText = XenraTracked(title ?: @"", 15, [self titleColor]);
}

- (void)setSubtitle:(NSString*)subtitle {
  _subtitle = [subtitle copy];
  subtitle_.text = subtitle;
  subtitle_.hidden = subtitle.length == 0;
}

- (UIColor*)titleColor {
  const BOOL lit = self.isHighlighted || _chosen;
  if (lit) return XenraBladeSelectedText();
  if (_destructive) return XenraError();
  return _dimmed ? XenraTextMuted() : XenraText();
}

- (void)refresh {
  blade_.bladeSelected = self.isHighlighted || _chosen;
  [blade_ setNeedsDisplay];
  self.title = _title;
  subtitle_.textColor = blade_.bladeSelected ? XenraBladeSelectedText()
                                             : XenraTextMuted();
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
  [host addSubview:sheet];
  [UIView animateWithDuration:0.15 animations:^{ sheet.alpha = 1; }];
}

- (void)dismiss {
  [UIView animateWithDuration:0.12
      animations:^{ self.alpha = 0; }
      completion:^(BOOL) { [self removeFromSuperview]; }];
}

@end

@implementation XenraHintBar {
  UIButton* back_;
}

static UIView* HintPill(NSString* letter, NSString* text, UIColor* color) {
  UILabel* badge = XenraMakeLabel(letter, 14, UIFontWeightBold, UIColor.blackColor);
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
