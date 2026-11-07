/**
 ******************************************************************************
 * Xenra : iOS shell - game library                                            *
 ******************************************************************************
 *
 * GameLibraryActivity, activity_game_library.xml. A list by default: a tap
 * selects and opens the detail panel, a second tap or A launches. The cover grid
 * has no selection, so a tap launches and holding a game gives its actions.
 *
 * The list on screen is the scanner's cached one, so coming back here shows at
 * once and changes nothing unless a background refresh found a difference.
 *
 * Cells lay themselves out by hand and draw through layers: a row is one shape
 * and a few labels, and a list of hundreds has to scroll without Auto Layout in
 * the way. Covers come from XenraCovers, decoded off the main thread at the size
 * shown.
 */

#import "XenraScreens.h"
#import "XenraStrings.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "XenraBladeView.h"
#import "XenraContentInstall.h"
#import "XenraCovers.h"
#import "XenraGameScanner.h"
#import "XenraMotion.h"
#import "XenraPadNav.h"
#import "XenraSettings.h"
#import "XenraTheme.h"
#import "XenraUI.h"
#import "XenraXemu.h"

#include <initializer_list>

namespace {

// xenraBladeSelected*. The end colour is amber on the original Xbox on Android
// too: res-green overrides the accent ramp and not this.
UIColor* SelectedEnd(void) { return XenraPick(0xFFA66B00, 0xFF4E7A12, 0xFFA66B00); }
UIColor* SelectedStroke(void) {
  return XenraPick(0xFFFFF0A0, 0xFF3F6410, 0xFFFFF0A0);
}
UIColor* SelectedText(void) {
  return XenraPick(0xFF120D00, 0xFFFBFEF4, 0xFF120D00);
}
UIColor* SelectedTextMuted(void) {
  return XenraPick(0xFF2A1A00, 0xFFDCEBBC, 0xFF2A1A00);
}
UIColor* PanelFillRaised(void) {
  return XenraPick(0xFF2A2108, 0xD4E9F4C6, 0xFF2A2108);
}
UIColor* SurfaceContainer(void) {
  return XenraPick(0xFF261F1A, 0xFFC2DA88, 0xFF261F1A);
}
UIColor* SurfaceContainerHigh(void) {
  return XenraPick(0xFF2E251E, 0xFFB0CE70, 0xFF2E251E);
}
UIColor* Scrim(void) { return XenraPick(0x55000000, 0x14000000, 0x55000000); }
UIColor* BarFill(void) { return XenraPick(0xE60D0A04, 0xC4E2EFB4, 0xE60B0B0C); }

// activity_game_library and GameBladeView, in points.
constexpr CGFloat kRowHeight = 74;
constexpr CGFloat kRowGap = 6;
constexpr CGFloat kRowCover = 48;
constexpr CGFloat kGridColumnGap = 8;
constexpr CGFloat kGridRowGap = 12;
constexpr CGFloat kTilePadding = 6;
constexpr CGFloat kTileTitleGap = 14;
constexpr CGFloat kTileTitleHeight = 40;  // two lines, always reserved
constexpr CGFloat kDetailWidth = 240;
constexpr CGFloat kDetailStrip = 200;

const CGSize kRowCoverSize = {48, 72};
const CGSize kDetailCoverSize = {100, 150};

NSAttributedString* Meta(NSString* text) {
  return [[NSAttributedString alloc]
      initWithString:text
          attributes:@{
            NSFontAttributeName : [UIFont systemFontOfSize:11],
            NSForegroundColorAttributeName : XenraTextTertiary(),
            NSKernAttributeName : @(XenraKern(1.1)),
          }];
}

UIImage* DrawnIcon(CGFloat viewport, void (^draw)(UIBezierPath* path)) {
  const CGFloat side = 24;
  UIGraphicsImageRenderer* renderer =
      [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
  UIImage* image =
      [renderer imageWithActions:^(UIGraphicsImageRendererContext* context) {
        UIBezierPath* path = [UIBezierPath bezierPath];
        draw(path);
        path.usesEvenOddFillRule = YES;
        [path applyTransform:CGAffineTransformMakeScale(side / viewport,
                                                        side / viewport)];
        [UIColor.blackColor setFill];
        [path fill];
      }];
  return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

// ic_xaniteog_view_list.
UIImage* ListIcon(void) {
  return DrawnIcon(960, ^(UIBezierPath* path) {
    [path appendPath:[UIBezierPath
                         bezierPathWithRoundedRect:CGRectMake(120, 200, 720, 560)
                                      cornerRadius:80]];
    for (const CGFloat y : {280.0, 440.0, 600.0}) {
      [path appendPath:[UIBezierPath bezierPathWithRect:CGRectMake(200, y, 80, 80)]];
      [path appendPath:[UIBezierPath bezierPathWithRect:CGRectMake(360, y, 400, 80)]];
    }
  });
}

// ic_xaniteog_grid_view.
UIImage* GridIcon(void) {
  return DrawnIcon(960, ^(UIBezierPath* path) {
    for (const CGFloat x : {120.0, 520.0}) {
      for (const CGFloat y : {120.0, 520.0}) {
        [path appendPath:[UIBezierPath
                             bezierPathWithRoundedRect:CGRectMake(x, y, 320, 320)
                                          cornerRadius:80]];
        [path appendPath:[UIBezierPath
                             bezierPathWithRect:CGRectMake(x + 80, y + 80, 160, 160)]];
      }
    }
  });
}

// ic_xaniteog_more_vert.
UIImage* MoreIcon(void) {
  return DrawnIcon(24, ^(UIBezierPath* path) {
    for (const CGFloat y : {6.0, 10.0, 14.0}) {
      [path appendPath:[UIBezierPath
                           bezierPathWithOvalInRect:CGRectMake(10, y, 4, 4)]];
    }
  });
}

// ic_xaniteog_cover_unknown, built once per size: every empty tile shows it.
UIImage* UnknownCover(CGFloat side) {
  static NSMutableDictionary<NSNumber*, UIImage*>* cache =
      [NSMutableDictionary dictionary];
  UIImage* image = cache[@(side)];
  if (!image) {
    image = XenraVectorImage(
        @[ [XenraVectorPath
            fill:@"M10.75,18.25h2.5v2.5h-2.5zM12,3C8.69,3 6,5.46 6,8.5h3C9,7.12 "
                  "10.35,6 12,6s3,1.12 3,2.5c0,1.06 -0.61,1.61 -1.65,2.33C11.91,"
                  "11.82 10.5,12.79 10.5,15h3c0,-0.64 0.34,-0.94 1.55,-1.78C16.36,"
                  "12.32 18,11.18 18,8.5 18,5.46 15.31,3 12,3z"] ],
        24, side);
    cache[@(side)] = image;
  }
  return image;
}

UIBezierPath* ChamferPath(CGSize s, CGFloat c) {
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
  return path;
}

void WithoutActions(void (^change)(void)) {
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  change();
  [CATransaction commit];
}

}  // namespace

// --- Cover ---------------------------------------------------------------------

// A cover and what stands in for it: the same "no art yet" mark as Android, over
// game_cover_image_background. Keeps its own request, so a reused cell can never
// be painted with the game it used to show.
@interface XenraCoverSlot : UIView
@property(nonatomic, assign) UIViewContentMode artMode;
- (void)showGame:(XenraGameEntry*)game size:(CGSize)size;
- (void)clear;
@end

@implementation XenraCoverSlot {
  CAGradientLayer* backing_;
  UIImageView* unknown_;
  UIImageView* art_;
  XenraCoverRequest* request_;
}

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    self.clipsToBounds = YES;
    backing_ = [CAGradientLayer layer];
    backing_.colors = @[
      (id)SurfaceContainerHigh().CGColor, (id)SurfaceContainer().CGColor
    ];
    [self.layer addSublayer:backing_];
    unknown_ = [[UIImageView alloc] init];
    unknown_.tintColor = XenraHex(0xFFD7B84B);
    unknown_.contentMode = UIViewContentModeScaleAspectFit;
    [self addSubview:unknown_];
    art_ = [[UIImageView alloc] init];
    art_.contentMode = UIViewContentModeScaleAspectFill;
    art_.clipsToBounds = YES;
    [self addSubview:art_];
  }
  return self;
}

- (void)setArtMode:(UIViewContentMode)artMode {
  _artMode = artMode;
  art_.contentMode = artMode;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  const CGRect bounds = self.bounds;
  WithoutActions(^{
    self->backing_.frame = bounds;
  });
  art_.frame = bounds;
  const CGFloat side = floor(MIN(bounds.size.width, bounds.size.height) * 0.72);
  if (side > 0) {
    unknown_.image = UnknownCover(side);
    unknown_.frame = CGRectMake((bounds.size.width - side) / 2,
                                (bounds.size.height - side) / 2, side, side);
  }
}

- (void)setArt:(UIImage*)image animated:(BOOL)animated {
  art_.image = image;
  unknown_.hidden = image != nil;
  WithoutActions(^{
    self->backing_.hidden = image != nil;
  });
  if (animated && image) {
    art_.alpha = 0;
    [UIView animateWithDuration:0.2
                     animations:^{
                       self->art_.alpha = 1;
                     }];
  } else {
    [art_.layer removeAllAnimations];
    art_.alpha = 1;
  }
}

- (void)showGame:(XenraGameEntry*)game size:(CGSize)size {
  [request_ cancel];
  request_ = nil;
  XenraCovers* covers = XenraCovers.shared;
  UIImage* cached = [covers cachedCoverForGame:game pointSize:size];
  [self setArt:cached animated:NO];
  if (cached) return;
  __weak XenraCoverSlot* weak = self;
  request_ = [covers loadCoverForGame:game
                            pointSize:size
                           completion:^(UIImage* image) {
                             if (image) [weak setArt:image animated:YES];
                           }];
}

- (void)clear {
  [request_ cancel];
  request_ = nil;
  [self setArt:nil animated:NO];
}

@end

// --- List row ------------------------------------------------------------------

// GameBladeView: chamfer 10, 1.5 stroke, a 48 pt cover, the title, and the size in
// a 94 pt column on the right.
@interface XenraGameRowCell : UICollectionViewCell
@property(nonatomic, assign) BOOL chosen;
@property(nonatomic, copy) NSString* gamePath;
- (void)showGame:(XenraGameEntry*)game;
@end

@implementation XenraGameRowCell {
  CAGradientLayer* selectedFill_;
  CAShapeLayer* selectedMask_;
  CAShapeLayer* blade_;
  CAShapeLayer* press_;
  XenraCoverSlot* cover_;
  UILabel* title_;
  UILabel* size_;
  CGSize shaped_;
}

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    CALayer* base = self.contentView.layer;
    selectedFill_ = [CAGradientLayer layer];
    selectedFill_.startPoint = CGPointMake(0, 0.5);
    selectedFill_.endPoint = CGPointMake(1, 0.5);
    selectedFill_.colors = @[ (id)XenraAccent().CGColor, (id)SelectedEnd().CGColor ];
    selectedMask_ = [CAShapeLayer layer];
    selectedFill_.mask = selectedMask_;
    selectedFill_.hidden = YES;
    [base addSublayer:selectedFill_];
    blade_ = [CAShapeLayer layer];
    blade_.lineWidth = 1.5;
    [base addSublayer:blade_];
    press_ = [CAShapeLayer layer];
    press_.fillColor = XenraFocus1F().CGColor;
    press_.hidden = YES;
    [base addSublayer:press_];

    cover_ = [[XenraCoverSlot alloc] initWithFrame:CGRectZero];
    cover_.layer.cornerRadius = 6;
    [self.contentView addSubview:cover_];
    title_ = [[UILabel alloc] init];
    title_.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    title_.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.contentView addSubview:title_];
    size_ = [[UILabel alloc] init];
    size_.font = [UIFont systemFontOfSize:11];
    size_.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.contentView addSubview:size_];
    [self paint];
  }
  return self;
}

- (void)paint {
  WithoutActions(^{
    self->selectedFill_.hidden = !self->_chosen;
    self->blade_.fillColor =
        self->_chosen ? UIColor.clearColor.CGColor : XenraBladeFill().CGColor;
    self->blade_.strokeColor =
        self->_chosen ? SelectedStroke().CGColor : XenraAccentAlpha(0x55).CGColor;
  });
  title_.textColor = _chosen ? SelectedText() : XenraText();
  size_.textColor = _chosen ? SelectedTextMuted() : XenraTextMuted();
}

- (void)setChosen:(BOOL)chosen {
  if (_chosen == chosen) return;
  _chosen = chosen;
  [self paint];
}

- (void)layoutSubviews {
  [super layoutSubviews];
  const CGSize s = self.contentView.bounds.size;
  if (!CGSizeEqualToSize(s, shaped_)) {
    shaped_ = s;
    WithoutActions(^{
      UIBezierPath* path = ChamferPath(s, 10);
      self->selectedFill_.frame = CGRectMake(0, 0, s.width, s.height);
      self->selectedMask_.path = path.CGPath;
      self->blade_.path = path.CGPath;
      self->press_.path = path.CGPath;
    });
  }
  cover_.frame = CGRectMake(16, floor((s.height - kRowCover) / 2), kRowCover,
                            kRowCover);
  const CGFloat titleX = 16 + 58;
  title_.frame = CGRectMake(titleX, floor((s.height - 20) / 2),
                            MAX(0, s.width - titleX - 16 - 100), 20);
  size_.frame = CGRectMake(s.width - 16 - 94, floor((s.height - 16) / 2), 94, 16);
  if (XenraRightToLeft()) {
    for (UIView* view in @[ cover_, title_, size_ ]) {
      CGRect frame = view.frame;
      frame.origin.x = s.width - CGRectGetMaxX(frame);
      view.frame = frame;
    }
    size_.textAlignment = NSTextAlignmentLeft;
  }
}

- (void)showGame:(XenraGameEntry*)game {
  _gamePath = [game.path copy];
  title_.text = game.name;
  size_.text = game.subtitle;
  [cover_ showGame:game size:kRowCoverSize];
}

- (void)setHighlighted:(BOOL)highlighted {
  [super setHighlighted:highlighted];
  WithoutActions(^{
    self->press_.hidden = !highlighted;
  });
}

- (void)prepareForReuse {
  [super prepareForReuse];
  [cover_ clear];
  [self.contentView.layer removeAllAnimations];
  self.contentView.alpha = 1;
  self.contentView.transform = CGAffineTransformIdentity;
}

@end

// --- Grid tile -----------------------------------------------------------------

// item_game_cover.xml: padding 6, a radius 18 card with an elevation 14 shadow and
// a 1 pt accent66 stroke, then a title that always reserves two lines.
@interface XenraGameTileCell : UICollectionViewCell
- (void)showGame:(XenraGameEntry*)game coverSize:(CGSize)size;
@end

@implementation XenraGameTileCell {
  UIView* shadow_;
  UIView* card_;
  XenraCoverSlot* cover_;
  UILabel* title_;
  CGFloat cardHeight_;
}

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    shadow_ = [[UIView alloc] init];
    // Kept inside the tile's 6 pt padding, or the edge of the list cuts it off in
    // a straight line, which shows on the light console. Tinted there too: black
    // over pale green reads as grey.
    shadow_.layer.shadowColor =
        (XenraThemeMode == XenraThemeX360 ? XenraHex(0xFF313D14)
                                          : UIColor.blackColor)
            .CGColor;
    shadow_.layer.shadowOpacity =
        XenraThemeMode == XenraThemeX360 ? 0.22f : 0.5f;
    shadow_.layer.shadowRadius = 5;
    shadow_.layer.shadowOffset = CGSizeMake(0, 3);
    [self.contentView addSubview:shadow_];

    card_ = [[UIView alloc] init];
    card_.backgroundColor = XenraBladeFill();
    card_.layer.cornerRadius = 18;
    card_.layer.borderWidth = 1;
    card_.layer.borderColor = XenraAccentAlpha(0x66).CGColor;
    card_.clipsToBounds = YES;
    [self.contentView addSubview:card_];

    cover_ = [[XenraCoverSlot alloc] initWithFrame:CGRectZero];
    cover_.artMode = UIViewContentModeScaleAspectFit;
    [card_ addSubview:cover_];

    title_ = [[UILabel alloc] init];
    title_.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    title_.textColor = XenraText();
    title_.textAlignment = NSTextAlignmentCenter;
    title_.numberOfLines = 2;
    title_.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.contentView addSubview:title_];
  }
  return self;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  const CGSize s = self.contentView.bounds.size;
  const CGRect card = CGRectMake(kTilePadding, kTilePadding, s.width - kTilePadding * 2,
                                 cardHeight_);
  shadow_.frame = card;
  shadow_.layer.shadowPath =
      [UIBezierPath bezierPathWithRoundedRect:shadow_.bounds cornerRadius:18].CGPath;
  card_.frame = card;
  cover_.frame = card_.bounds;
  const CGFloat y = CGRectGetMaxY(card) + kTileTitleGap;
  const CGSize fit =
      [title_ sizeThatFits:CGSizeMake(card.size.width, kTileTitleHeight)];
  title_.frame = CGRectMake(kTilePadding, y, card.size.width,
                            MIN(ceil(fit.height), kTileTitleHeight));
}

- (void)showGame:(XenraGameEntry*)game coverSize:(CGSize)size {
  title_.text = game.name;
  if (cardHeight_ != size.height) {
    cardHeight_ = size.height;
    [self setNeedsLayout];
  }
  [cover_ showGame:game size:size];
}

// Android draws no dimming here. The stroke answers the touch, and a hold reads as
// a slow settle, 200 ms in, before the actions open.
- (void)setHighlighted:(BOOL)highlighted {
  [super setHighlighted:highlighted];
  card_.layer.borderColor =
      (highlighted ? XenraAccent() : XenraAccentAlpha(0x66)).CGColor;
  [UIView animateWithDuration:highlighted ? 0.25 : 0.12
                        delay:highlighted ? 0.2 : 0
                      options:UIViewAnimationOptionBeginFromCurrentState |
                              UIViewAnimationOptionAllowUserInteraction
                   animations:^{
                     self.contentView.transform =
                         highlighted ? CGAffineTransformMakeScale(0.97, 0.97)
                                     : CGAffineTransformIdentity;
                   }
                   completion:nil];
}

- (void)prepareForReuse {
  [super prepareForReuse];
  [cover_ clear];
  [self.contentView.layer removeAllAnimations];
  self.contentView.alpha = 1;
  self.contentView.transform = CGAffineTransformIdentity;
}

@end

// --- Flow layout ---------------------------------------------------------------

// A plain flow layout spreads a short last row and centres a lone tile. Android's
// fillers keep every tile in its column, so this does.
@interface XenraColumnLayout : UICollectionViewFlowLayout
@property(nonatomic, assign) NSInteger columns;  // 0 for the list
@end

@implementation XenraColumnLayout

// Flow layout redoes itself when its width changes but keeps the item sizes it
// asked for before, which left rows at their old width, cut off at both ends.
- (UICollectionViewLayoutInvalidationContext*)invalidationContextForBoundsChange:
    (CGRect)bounds {
  UICollectionViewFlowLayoutInvalidationContext* context =
      (UICollectionViewFlowLayoutInvalidationContext*)
          [super invalidationContextForBoundsChange:bounds];
  context.invalidateFlowLayoutDelegateMetrics =
      bounds.size.width != self.collectionView.bounds.size.width;
  return context;
}

- (UICollectionViewLayoutAttributes*)placed:(UICollectionViewLayoutAttributes*)source {
  UICollectionViewLayoutAttributes* attributes = [source copy];
  CGRect frame = attributes.frame;
  frame.origin.x =
      (attributes.indexPath.item % _columns) * (frame.size.width + kGridColumnGap);
  attributes.frame = frame;
  return attributes;
}

- (NSArray<UICollectionViewLayoutAttributes*>*)layoutAttributesForElementsInRect:
    (CGRect)rect {
  NSArray<UICollectionViewLayoutAttributes*>* all =
      [super layoutAttributesForElementsInRect:rect];
  if (_columns < 1) return all;
  NSMutableArray* placed = [NSMutableArray arrayWithCapacity:all.count];
  for (UICollectionViewLayoutAttributes* item in all) {
    [placed addObject:item.representedElementCategory ==
                              UICollectionElementCategoryCell
                          ? [self placed:item]
                          : item];
  }
  return placed;
}

- (UICollectionViewLayoutAttributes*)layoutAttributesForItemAtIndexPath:
    (NSIndexPath*)path {
  UICollectionViewLayoutAttributes* item =
      [super layoutAttributesForItemAtIndexPath:path];
  return _columns < 1 || !item ? item : [self placed:item];
}

@end

// --- Header tools --------------------------------------------------------------

// The 36 dp outlined icon buttons of the header, at a touch size. Android's
// game_library_view_toggle colours: checked is filled with the accent.
@interface XenraToolButton : XenraPressControl
@property(nonatomic, assign) BOOL checked;
- (instancetype)initWithIcon:(UIImage*)icon
                       title:(NSString*)title
                      action:(void (^)(void))action;
@end

@implementation XenraToolButton {
  UIImageView* icon_;
}

- (instancetype)initWithIcon:(UIImage*)icon
                       title:(NSString*)title
                      action:(void (^)(void))action {
  self = [super initWithFrame:CGRectZero];
  if (self) {
    self.title = title;
    self.action = action;
    self.accessibilityLabel = title;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.layer.cornerRadius = 15;
    self.layer.borderWidth = 1.5;
    self.layer.borderColor = XenraAccentDark().CGColor;
    icon_ = [[UIImageView alloc] initWithImage:icon];
    icon_.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:icon_];
    [NSLayoutConstraint activateConstraints:@[
      [self.widthAnchor constraintEqualToConstant:44],
      [self.heightAnchor constraintEqualToConstant:44],
      [icon_.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
      [icon_.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];
    [self paint];
  }
  return self;
}

- (void)paint {
  self.backgroundColor = _checked          ? XenraAccent()
                         : self.pressed    ? XenraAccentAlpha(0x33)
                                           : UIColor.clearColor;
  icon_.tintColor = _checked ? XenraBg() : XenraText();
}

- (void)setChecked:(BOOL)checked {
  _checked = checked;
  [self paint];
}

- (void)pressedChanged {
  [self paint];
}

@end

// --- Overflow menu -------------------------------------------------------------

// Android's PopupMenu: a small panel hanging off the button, not a sheet in the
// middle of the screen. Any tap outside closes it.
@interface XenraAnchorMenu : UIView
@property(nonatomic, copy) void (^onClose)(void);
+ (instancetype)showIn:(UIView*)host
                anchor:(UIView*)anchor
                 items:(NSArray<XenraBladeItem*>*)items;
- (void)dismiss;
@end

@implementation XenraAnchorMenu {
  XenraPanelView* panel_;
  BOOL leaving_;
}

+ (instancetype)showIn:(UIView*)host
                anchor:(UIView*)anchor
                 items:(NSArray<XenraBladeItem*>*)items {
  XenraAnchorMenu* menu = [[XenraAnchorMenu alloc] initWithFrame:host.bounds];
  menu.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [menu addTap];
  [menu buildWithItems:items anchor:anchor host:host];
  [host addSubview:menu];
  menu->panel_.alpha = 0;
  menu->panel_.transform = CGAffineTransformMakeScale(0.96, 0.96);
  XenraAnimate(0.12, 0, XenraCurveStandard,
               ^{
                 menu->panel_.alpha = 1;
                 menu->panel_.transform = CGAffineTransformIdentity;
               },
               nil);
  return menu;
}

- (void)addTap {
  UITapGestureRecognizer* tap =
      [[UITapGestureRecognizer alloc] initWithTarget:self
                                              action:@selector(tappedOutside:)];
  // The rows inside still get their touch up.
  tap.cancelsTouchesInView = NO;
  [self addGestureRecognizer:tap];
}

- (void)tappedOutside:(UITapGestureRecognizer*)tap {
  const CGPoint point = [tap locationInView:self];
  if (!CGRectContainsPoint(panel_.frame, point)) [self dismiss];
}

- (void)buildWithItems:(NSArray<XenraBladeItem*>*)items
                anchor:(UIView*)anchor
                  host:(UIView*)host {
  const CGFloat width = 264;
  const CGFloat rowGap = 6;
  const CGFloat padding = 8;
  const CGFloat height =
      items.count * 48 + (items.count - 1) * rowGap + padding * 2;
  const CGRect button = [anchor convertRect:anchor.bounds toView:host];
  const CGFloat x =
      MAX(8, MIN(CGRectGetMaxX(button) - width, host.bounds.size.width - width - 8));
  panel_ = [[XenraPanelView alloc]
      initWithFrame:CGRectMake(x, CGRectGetMaxY(button) + 6, width, height)];
  panel_.chamfer = 8;  // the rows sit 8 in, clear of the cut
  [panel_ setFill:XenraDialogFill()];
  panel_.layer.shadowColor = XenraShadow().CGColor;
  panel_.layer.shadowOpacity = 0.5;
  panel_.layer.shadowRadius = 12;
  panel_.layer.shadowOffset = CGSizeMake(0, 6);
  panel_.layer.anchorPoint = CGPointMake(1, 0);
  panel_.frame = CGRectMake(x, CGRectGetMaxY(button) + 6, width, height);
  [self addSubview:panel_];

  UIStackView* rows = [[UIStackView alloc] init];
  rows.axis = UILayoutConstraintAxisVertical;
  rows.spacing = rowGap;
  rows.translatesAutoresizingMaskIntoConstraints = NO;
  [panel_ addSubview:rows];
  [NSLayoutConstraint activateConstraints:@[
    [rows.leadingAnchor constraintEqualToAnchor:panel_.leadingAnchor constant:padding],
    [rows.trailingAnchor constraintEqualToAnchor:panel_.trailingAnchor
                                        constant:-padding],
    [rows.topAnchor constraintEqualToAnchor:panel_.topAnchor constant:padding],
  ]];
  __weak XenraAnchorMenu* weak = self;
  for (XenraBladeItem* item in items) {
    void (^act)(void) = item.action;
    XenraBladeButton* row =
        [[XenraBladeButton alloc] initWithTitle:item.title
                                         action:^{
                                           [weak dismiss];
                                           if (act) act();
                                         }];
    row.compact = YES;
    [rows addArrangedSubview:row];
  }
}

- (void)dismiss {
  if (leaving_) return;
  leaving_ = YES;
  self.userInteractionEnabled = NO;
  if (_onClose) _onClose();
  XenraAnimate(0.1, 0, XenraCurveStandard,
               ^{
                 self.alpha = 0;
               },
               ^{
                 [self removeFromSuperview];
               });
}

@end

// --- Selected game's icon ------------------------------------------------------

// GlowingCircleView: the cover cut to a circle inside a ring, on a slow glow.
@interface XenraGlowCircle : UIView
@property(nonatomic, readonly) XenraCoverSlot* cover;
- (void)startPulse;
@end

@implementation XenraGlowCircle {
  CAGradientLayer* glow_;
  CAShapeLayer* fill_;
  CAShapeLayer* ring_;
}

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    glow_ = [CAGradientLayer layer];
    glow_.type = kCAGradientLayerRadial;
    glow_.startPoint = CGPointMake(0.5, 0.5);
    glow_.endPoint = CGPointMake(1, 1);
    glow_.colors = @[
      (id)XenraAccentAlpha(0x64).CGColor, (id)XenraAccentAlpha(0x64).CGColor,
      (id)XenraAccentAlpha(0).CGColor
    ];
    glow_.locations = @[ @0, @0.78, @1 ];
    [self.layer addSublayer:glow_];
    fill_ = [CAShapeLayer layer];
    fill_.fillColor = XenraCardFill().CGColor;
    [self.layer addSublayer:fill_];
    _cover = [[XenraCoverSlot alloc] initWithFrame:CGRectZero];
    [self addSubview:_cover];
    ring_ = [CAShapeLayer layer];
    ring_.fillColor = UIColor.clearColor.CGColor;
    ring_.strokeColor = XenraAccent().CGColor;
    ring_.lineWidth = 2;
    [self.layer addSublayer:ring_];
  }
  return self;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  const CGRect bounds = self.bounds;
  WithoutActions(^{
    self->glow_.frame = CGRectInset(bounds, -12, -12);
    UIBezierPath* circle = [UIBezierPath bezierPathWithOvalInRect:bounds];
    self->fill_.path = circle.CGPath;
    self->ring_.path =
        [UIBezierPath bezierPathWithOvalInRect:CGRectInset(bounds, 1, 1)].CGPath;
  });
  _cover.frame = CGRectInset(bounds, 2, 2);
  _cover.layer.cornerRadius = _cover.bounds.size.width / 2;
}

- (void)startPulse {
  [glow_ removeAllAnimations];
  CABasicAnimation* pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
  pulse.fromValue = @0.15;
  pulse.toValue = @1;
  pulse.duration = 1;
  pulse.autoreverses = YES;
  pulse.repeatCount = HUGE_VALF;
  pulse.timingFunction =
      [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
  [glow_ addAnimation:pulse forKey:@"pulse"];
}

- (void)didMoveToWindow {
  [super didMoveToWindow];
  if (self.window) {
    [self startPulse];
  } else {
    [glow_ removeAllAnimations];
  }
}

@end

// --- The screen ----------------------------------------------------------------

typedef NS_ENUM(NSInteger, XenraLibraryPick) {
  XenraLibraryPickFolder,
  XenraLibraryPickContent,
  XenraLibraryPickCover,
};

@interface XenraLibraryController () <UICollectionViewDataSource,
                                      UICollectionViewDataSourcePrefetching,
                                      UICollectionViewDelegateFlowLayout,
                                      UIDocumentPickerDelegate,
                                      XenraPadScreen>
@end

// Outlives the screen: the installer's progress is one shared thing, and the
// library can be left and opened again while it runs.
static BOOL g_installing;

@implementation XenraLibraryController {
  XenraGameScanner* scanner_;
  NSArray<XenraGameEntry*>* games_;
  XenraGameEntry* selected_;
  BOOL gridMode_;
  BOOL rendered_;
  BOOL arranged_;
  BOOL detailPortrait_;
  BOOL detailShown_;
  CGFloat laidOutWidth_;

  XenraPanelView* panel_;
  UICollectionView* collection_;
  XenraColumnLayout* layout_;
  UILabel* stats_;
  XenraToolButton* listButton_;
  XenraToolButton* gridButton_;
  XenraToolButton* moreButton_;
  XenraAnchorMenu* menu_;
  UIView* loadingRow_;
  UIActivityIndicatorView* spinner_;
  UIProgressView* progress_;
  UILabel* loadingText_;
  UIView* emptyCard_;
  UILabel* emptyText_;
  UIStackView* emptyActions_;
  UILabel* gridHint_;
  XenraHintBar* hints_;
  NSLayoutConstraint* hintsBottom_;

  XenraPanelView* detail_;
  UIStackView* detailStack_;
  XenraGlowCircle* icon_;
  NSLayoutConstraint* iconWidth_;
  NSLayoutConstraint* iconHeight_;
  NSLayoutConstraint* infoWidth_;
  UILabel* detailTitle_;
  UILabel* detailSaves_;
  UILabel* detailContent_;
  UILabel* detailSize_;

  NSLayoutConstraint* panelTop_;
  NSLayoutConstraint* panelLeading_;
  NSArray<NSLayoutConstraint*>* plainLayout_;
  NSArray<NSLayoutConstraint*>* sideLayout_;
  NSArray<NSLayoutConstraint*>* stripLayout_;

  NSMutableDictionary<NSIndexPath*, XenraCoverRequest*>* prefetches_;
  XenraLibraryPick picking_;
  XenraGameEntry* coverTarget_;
}

- (BOOL)noCore {
  return [XenraSettings console] == XenraConsoleOG && !XenraXemuAvailable();
}

// --- Building ------------------------------------------------------------------

- (void)viewDidLoad {
  [super viewDidLoad];
  XenraDashboardBackground* background =
      [[XenraDashboardBackground alloc] initForDashboardWithFrame:self.view.bounds];
  background.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.view addSubview:background];
  UIView* scrim = [[UIView alloc] initWithFrame:self.view.bounds];
  scrim.backgroundColor = Scrim();
  scrim.autoresizingMask = background.autoresizingMask;
  [self.view addSubview:scrim];

  gridMode_ = [[XenraSettings stringForKey:@"library.view" fallback:@"list"]
      isEqualToString:@"grid"];
  prefetches_ = [NSMutableDictionary dictionary];
  scanner_ = XenraGameScanner.shared;
  games_ = self.noCore ? @[] : scanner_.cachedGames;

  [self buildPanel];
  [self buildDetail];
  [self buildBar];
  [self buildConstraints];
  [self showDisplayMode];
  [self updateHeader];
}

- (void)buildPanel {
  panel_ = [[XenraPanelView alloc] initWithFrame:CGRectZero];
  panel_.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:panel_];

  UILabel* title = [[UILabel alloc] init];
  title.attributedText = XenraScreenTitle(XS(@"Game Library"));
  stats_ = [[UILabel alloc] init];
  stats_.textAlignment = XenraEndAlignment();
  UIStackView* header =
      [[UIStackView alloc] initWithArrangedSubviews:@[ title, [UIView new], stats_ ]];
  header.alignment = UIStackViewAlignmentCenter;
  header.spacing = 10;
  [title setContentCompressionResistancePriority:UILayoutPriorityRequired
                                         forAxis:UILayoutConstraintAxisHorizontal];
  [title setContentHuggingPriority:UILayoutPriorityRequired
                           forAxis:UILayoutConstraintAxisHorizontal];
  [stats_ setContentHuggingPriority:UILayoutPriorityRequired
                            forAxis:UILayoutConstraintAxisHorizontal];

  __weak XenraLibraryController* weak = self;
  UILabel* display = [[UILabel alloc] init];
  display.attributedText = XenraTrackedSpacing(XS(@"Display"), 10, XenraTextMuted(), 0.12);
  listButton_ = [[XenraToolButton alloc] initWithIcon:ListIcon()
                                                title:XS(@"List")
                                               action:^{
                                                 [weak setGridMode:NO];
                                               }];
  gridButton_ = [[XenraToolButton alloc] initWithIcon:GridIcon()
                                                title:XS(@"Covers")
                                               action:^{
                                                 [weak setGridMode:YES];
                                               }];
  moreButton_ = [[XenraToolButton alloc] initWithIcon:MoreIcon()
                                                title:XS(@"More")
                                               action:^{
                                                 [weak showOverflow];
                                               }];
  [display setContentHuggingPriority:UILayoutPriorityRequired
                             forAxis:UILayoutConstraintAxisHorizontal];
  UIStackView* tools = [[UIStackView alloc] initWithArrangedSubviews:@[
    display, [UIView new], listButton_, gridButton_, moreButton_
  ]];
  tools.alignment = UIStackViewAlignmentCenter;
  tools.spacing = 6;

  spinner_ = [[UIActivityIndicatorView alloc]
      initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
  spinner_.color = XenraAccent();
  spinner_.transform = CGAffineTransformMakeScale(0.8, 0.8);
  progress_ = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
  progress_.progressTintColor = XenraAccent();
  progress_.trackTintColor = XenraAccentAlpha(0x22);
  progress_.hidden = YES;
  loadingText_ = XenraMakeLabel(nil, 14, UIFontWeightRegular, XenraTextMuted());
  UIStackView* loading = [[UIStackView alloc]
      initWithArrangedSubviews:@[ spinner_, loadingText_, progress_ ]];
  loading.alignment = UIStackViewAlignmentCenter;
  loading.spacing = 8;
  loading.hidden = YES;
  loadingRow_ = loading;
  [loadingText_ setContentHuggingPriority:UILayoutPriorityRequired
                                  forAxis:UILayoutConstraintAxisHorizontal];

  [self buildEmptyCard];

  gridHint_ = [[UILabel alloc] init];
  gridHint_.attributedText = Meta(XS(@"Hold a game for options"));

  UIStackView* top = [[UIStackView alloc] initWithArrangedSubviews:@[
    header, tools, loadingRow_, emptyCard_, gridHint_
  ]];
  top.axis = UILayoutConstraintAxisVertical;
  top.spacing = 6;
  [top setCustomSpacing:12 afterView:header];
  [top setCustomSpacing:16 afterView:tools];
  top.translatesAutoresizingMaskIntoConstraints = NO;
  [panel_ addSubview:top];

  layout_ = [[XenraColumnLayout alloc] init];
  layout_.minimumInteritemSpacing = 0;
  collection_ = [[UICollectionView alloc] initWithFrame:CGRectZero
                                   collectionViewLayout:layout_];
  collection_.backgroundColor = UIColor.clearColor;
  collection_.alwaysBounceVertical = YES;
  collection_.indicatorStyle = XenraThemeMode == XenraThemeX360
                                   ? UIScrollViewIndicatorStyleBlack
                                   : UIScrollViewIndicatorStyleWhite;
  // Touches are held back while a drag might start, so a scroll never lights the
  // row under the finger, and a tap still flashes it (A10).
  collection_.delaysContentTouches = YES;
  collection_.dataSource = self;
  collection_.prefetchDataSource = self;
  collection_.delegate = self;
  [collection_ registerClass:[XenraGameRowCell class]
      forCellWithReuseIdentifier:@"row"];
  [collection_ registerClass:[XenraGameTileCell class]
      forCellWithReuseIdentifier:@"tile"];
  collection_.translatesAutoresizingMaskIntoConstraints = NO;
  [panel_ addSubview:collection_];
  [collection_ addGestureRecognizer:[[UILongPressGestureRecognizer alloc]
                                        initWithTarget:self
                                                action:@selector(heldGame:)]];

  [NSLayoutConstraint activateConstraints:@[
    [top.leadingAnchor constraintEqualToAnchor:panel_.leadingAnchor constant:18],
    [top.trailingAnchor constraintEqualToAnchor:panel_.trailingAnchor constant:-18],
    [top.topAnchor constraintEqualToAnchor:panel_.topAnchor constant:18],
    [collection_.leadingAnchor constraintEqualToAnchor:panel_.leadingAnchor
                                              constant:18],
    [collection_.trailingAnchor constraintEqualToAnchor:panel_.trailingAnchor
                                               constant:-18],
    [collection_.topAnchor constraintEqualToAnchor:top.bottomAnchor constant:6],
    [collection_.bottomAnchor constraintEqualToAnchor:panel_.bottomAnchor
                                             constant:-14],
  ]];
}

// library_empty_text on game_list_item_background, with a way forward under it.
- (void)buildEmptyCard {
  emptyText_ = XenraMakeLabel(nil, 14, UIFontWeightRegular, XenraTextMuted());
  emptyText_.numberOfLines = 0;
  emptyText_.textAlignment = NSTextAlignmentCenter;

  __weak XenraLibraryController* weak = self;
  XenraPillButton* folder =
      [[XenraPillButton alloc] initWithTitle:XS(@"Set game folder")
                                       style:XenraPillFilled
                                      action:^{
                                        [weak pickFolder];
                                      }];
  XenraPillButton* install =
      [[XenraPillButton alloc] initWithTitle:XS(@"Install content")
                                       style:XenraPillOutlined
                                      action:^{
                                        [weak pickContent];
                                      }];
  emptyActions_ = [[UIStackView alloc] initWithArrangedSubviews:@[ install, folder ]];
  emptyActions_.spacing = 10;

  UIStackView* stack =
      [[UIStackView alloc] initWithArrangedSubviews:@[ emptyText_, emptyActions_ ]];
  stack.axis = UILayoutConstraintAxisVertical;
  stack.alignment = UIStackViewAlignmentCenter;
  stack.spacing = 10;
  stack.translatesAutoresizingMaskIntoConstraints = NO;

  emptyCard_ = [[UIView alloc] init];
  emptyCard_.backgroundColor = SurfaceContainer();
  emptyCard_.layer.cornerRadius = 15;
  emptyCard_.layer.borderWidth = 1;
  emptyCard_.layer.borderColor = XenraOutlineVariant().CGColor;
  emptyCard_.hidden = YES;
  [emptyCard_ addSubview:stack];
  [NSLayoutConstraint activateConstraints:@[
    [stack.leadingAnchor constraintEqualToAnchor:emptyCard_.leadingAnchor constant:16],
    [stack.trailingAnchor constraintEqualToAnchor:emptyCard_.trailingAnchor
                                         constant:-16],
    [stack.topAnchor constraintEqualToAnchor:emptyCard_.topAnchor constant:16],
    [stack.bottomAnchor constraintEqualToAnchor:emptyCard_.bottomAnchor constant:-16],
    [emptyText_.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
  ]];
}

- (void)buildDetail {
  detail_ = [[XenraPanelView alloc] initWithFrame:CGRectZero];
  detail_.chamfer = 16;
  detail_.translatesAutoresizingMaskIntoConstraints = NO;
  detail_.hidden = YES;
  [self.view addSubview:detail_];

  icon_ = [[XenraGlowCircle alloc] initWithFrame:CGRectZero];
  icon_.translatesAutoresizingMaskIntoConstraints = NO;

  detailTitle_ = XenraMakeLabel(nil, 13, UIFontWeightBold, XenraText());
  detailTitle_.numberOfLines = 2;
  detailSaves_ = XenraMakeLabel(nil, 11, UIFontWeightRegular, XenraTextMuted());
  detailContent_ = XenraMakeLabel(nil, 11, UIFontWeightRegular, XenraTextMuted());
  detailSize_ = XenraMakeLabel(nil, 11, UIFontWeightRegular, XenraTextMuted());
  __weak XenraLibraryController* weak = self;
  XenraPillButton* actions =
      [[XenraPillButton alloc] initWithTitle:XS(@"Actions")
                                       style:XenraPillOutlined
                                      action:^{
                                        [weak showActionsForSelected];
                                      }];
  UIStackView* lines = [[UIStackView alloc] initWithArrangedSubviews:@[
    detailTitle_, detailSaves_, detailContent_, detailSize_, actions
  ]];
  lines.axis = UILayoutConstraintAxisVertical;
  lines.alignment = UIStackViewAlignmentFill;
  [lines setCustomSpacing:6 afterView:detailTitle_];
  [lines setCustomSpacing:6 afterView:detailSize_];
  lines.translatesAutoresizingMaskIntoConstraints = NO;

  XenraPanelView* info = [[XenraPanelView alloc] initWithFrame:CGRectZero];
  info.chamfer = 10;
  [info setFill:PanelFillRaised()];
  info.translatesAutoresizingMaskIntoConstraints = NO;
  [info addSubview:lines];
  [NSLayoutConstraint activateConstraints:@[
    [lines.leadingAnchor constraintEqualToAnchor:info.leadingAnchor constant:12],
    [lines.trailingAnchor constraintEqualToAnchor:info.trailingAnchor constant:-12],
    [lines.topAnchor constraintEqualToAnchor:info.topAnchor constant:12],
    [lines.bottomAnchor constraintEqualToAnchor:info.bottomAnchor constant:-8],
  ]];

  detailStack_ = [[UIStackView alloc] initWithArrangedSubviews:@[ icon_, info ]];
  detailStack_.alignment = UIStackViewAlignmentCenter;
  detailStack_.translatesAutoresizingMaskIntoConstraints = NO;
  [detail_ addSubview:detailStack_];
  iconWidth_ = [icon_.widthAnchor constraintEqualToConstant:100];
  iconHeight_ = [icon_.heightAnchor constraintEqualToConstant:100];
  infoWidth_ = [info.widthAnchor constraintEqualToAnchor:detailStack_.widthAnchor];
  [NSLayoutConstraint activateConstraints:@[
    iconWidth_,
    iconHeight_,
    [detailStack_.leadingAnchor constraintEqualToAnchor:detail_.leadingAnchor
                                               constant:16],
    [detailStack_.trailingAnchor constraintEqualToAnchor:detail_.trailingAnchor
                                                constant:-16],
    [detailStack_.centerYAnchor constraintEqualToAnchor:detail_.centerYAnchor],
  ]];
}

- (void)buildBar {
  hints_ = [[XenraHintBar alloc] initWithFrame:CGRectZero];
  hints_.panelStyle = YES;
  hints_.backTitle = XS(@"Back");
  hints_.selectTitle = XS(@"Open");
  __weak XenraLibraryController* weak = self;
  hints_.onBack = ^{
    [weak goBack];
  };
  hints_.onSelect = ^{
    [weak openSelected];
  };
  [self.view addSubview:hints_];
}

- (void)buildConstraints {
  UIView* view = self.view;
  UILayoutGuide* safe = view.safeAreaLayoutGuide;
  // On a phone the bar sits above the home indicator, with its fill carried on
  // down to the edge of the screen.
  UIView* under = [[UIView alloc] init];
  under.backgroundColor = BarFill();
  under.translatesAutoresizingMaskIntoConstraints = NO;
  [view insertSubview:under belowSubview:hints_];

  hintsBottom_ = [hints_.bottomAnchor constraintEqualToAnchor:view.bottomAnchor];
  panelTop_ = [panel_.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12];
  panelLeading_ = [panel_.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor
                                                       constant:12];
  [NSLayoutConstraint activateConstraints:@[
    hintsBottom_,
    panelTop_,
    panelLeading_,
    [hints_.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
    [hints_.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
    [under.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
    [under.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
    [under.topAnchor constraintEqualToAnchor:hints_.bottomAnchor],
    [under.bottomAnchor constraintEqualToAnchor:view.bottomAnchor],
  ]];

  plainLayout_ = @[
    [panel_.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
    [panel_.bottomAnchor constraintEqualToAnchor:hints_.topAnchor constant:-8],
  ];
  sideLayout_ = @[
    [panel_.trailingAnchor constraintEqualToAnchor:detail_.leadingAnchor constant:-12],
    [panel_.bottomAnchor constraintEqualToAnchor:hints_.topAnchor constant:-8],
    [detail_.widthAnchor constraintEqualToConstant:kDetailWidth],
    [detail_.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-10],
    [detail_.topAnchor constraintEqualToAnchor:safe.topAnchor constant:10],
    [detail_.bottomAnchor constraintEqualToAnchor:hints_.topAnchor constant:-6],
  ];
  stripLayout_ = @[
    [panel_.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-10],
    [panel_.bottomAnchor constraintEqualToAnchor:detail_.topAnchor constant:-8],
    [detail_.heightAnchor constraintEqualToConstant:kDetailStrip],
    [detail_.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:10],
    [detail_.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-10],
    [detail_.bottomAnchor constraintEqualToAnchor:hints_.topAnchor constant:-8],
  ];
  [NSLayoutConstraint activateConstraints:plainLayout_];
}

// adaptLayoutForOrientation: beside the list in landscape, a strip under it in
// portrait, where 240 pt would leave the list too little.
- (void)arrangeDetail {
  const CGSize size = self.view.bounds.size;
  const BOOL portrait = size.height > size.width;
  const BOOL shown = selected_ != nil;
  if (arranged_ && portrait == detailPortrait_ && shown == detailShown_) return;
  arranged_ = YES;
  detailPortrait_ = portrait;
  detailShown_ = shown;

  [NSLayoutConstraint deactivateConstraints:plainLayout_];
  [NSLayoutConstraint deactivateConstraints:sideLayout_];
  [NSLayoutConstraint deactivateConstraints:stripLayout_];
  [NSLayoutConstraint activateConstraints:!shown     ? plainLayout_
                                          : portrait ? stripLayout_
                                                     : sideLayout_];
  const BOOL strip = shown && portrait;
  panelTop_.constant = strip ? 10 : 12;
  panelLeading_.constant = strip ? 10 : 12;
  detail_.hidden = !shown;

  detailStack_.axis = portrait ? UILayoutConstraintAxisHorizontal
                               : UILayoutConstraintAxisVertical;
  detailStack_.spacing = portrait ? 18 : 16;
  infoWidth_.active = !portrait;
  iconWidth_.constant = portrait ? 84 : 100;
  iconHeight_.constant = iconWidth_.constant;
}

// --- Appearing -----------------------------------------------------------------

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self refresh];
}

- (void)viewSafeAreaInsetsDidChange {
  [super viewSafeAreaInsetsDidChange];
  hintsBottom_.constant = -XenraHintBarInset(self.view);
}

- (void)viewWillLayoutSubviews {
  [super viewWillLayoutSubviews];
  [self arrangeDetail];
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  // The list is the panel's child, and the panel has not laid out yet here.
  [panel_ layoutIfNeeded];
  const CGFloat width = collection_.bounds.size.width;
  if (width <= 0 || width == laidOutWidth_) return;
  laidOutWidth_ = width;
  if (!rendered_) {
    rendered_ = YES;
    [self renderWithEntrance];
    return;
  }
  // A tile has a new cover size too. Everything comes from the cover cache, so
  // this draws nothing different but the size.
  [self applyGridMetrics];
  [collection_ reloadData];
  [collection_ layoutIfNeeded];
}

- (void)viewWillTransitionToSize:(CGSize)size
       withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
  [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
  [menu_ dismiss];
  [coordinator
      animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext> c) {
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
      }
                      completion:nil];
}

// --- The list ------------------------------------------------------------------

- (void)refresh {
  if (self.noCore) {
    [self updateHeader];
    return;
  }
  __weak XenraLibraryController* weak = self;
  [scanner_ refreshWithCompletion:^(NSArray<XenraGameEntry*>* games, BOOL changed) {
    [weak scanned:games changed:changed];
  }];
  [self updateHeader];
}

- (void)scanned:(NSArray<XenraGameEntry*>*)games changed:(BOOL)changed {
  if (changed) {
    [self applyGames:games];
  } else {
    [self updateHeader];
  }
}

- (void)applyGames:(NSArray<XenraGameEntry*>*)games {
  const BOOL wasEmpty = games_.count == 0;
  games_ = games;
  if (selected_) {
    XenraGameEntry* kept = nil;
    for (XenraGameEntry* game in games) {
      if ([game.path isEqualToString:selected_.path]) kept = game;
    }
    if (kept) {
      selected_ = kept;
    } else {
      [self clearSelection];
    }
  }
  [self updateHeader];
  if (!rendered_) return;
  if (wasEmpty) {
    [self renderWithEntrance];
  } else {
    [self cancelPrefetches];
    [collection_ reloadData];
  }
}

// What is around the list: counts, the scanning line, the empty card.
- (void)updateHeader {
  const unsigned long count = games_.count;
  stats_.attributedText =
      Meta([NSString stringWithFormat:XS(@"TOTAL: %lu   AVAILABLE: %lu"), count, count]);

  const BOOL noCore = self.noCore;
  const BOOL scanning = !noCore && scanner_.scanning;
  [self showBusy:g_installing || (scanning && count == 0)
         message:g_installing ? nil : XS(@"Scanning games...")];

  const BOOL empty = count == 0 && !scanning;
  emptyCard_.hidden = !empty;
  collection_.hidden = count == 0;
  gridHint_.hidden = !gridMode_ || count == 0;
  if (!empty) return;
  emptyActions_.hidden = noCore;
  if (noCore) {
    emptyText_.text = XS(@"This build has no original Xbox core. Switch the console "
                       "to Xbox 360 on the dashboard.");
  } else if (scanner_.unreadableFolders.count) {
    emptyText_.text = XS(@"The games folder could not be read. It may have been "
                       "moved or deleted.");
  } else {
    emptyText_.text = [XenraSettings console] == XenraConsole360
                          ? XS(@"No Xbox 360 games found in this folder.")
                          : XS(@"No supported games found in this folder.");
  }
}

- (void)showBusy:(BOOL)busy message:(NSString*)message {
  if (message) loadingText_.text = message;
  if (busy) {
    [spinner_ startAnimating];
  } else {
    [spinner_ stopAnimating];
  }
  spinner_.hidden = !busy;
  loadingRow_.hidden = !busy;
}

- (void)cancelPrefetches {
  for (XenraCoverRequest* request in prefetches_.allValues) [request cancel];
  [prefetches_ removeAllObjects];
}

// layout_anim_cards. List rows slide in, tiles grow in; neither replays on scroll.
- (void)renderWithEntrance {
  [self cancelPrefetches];
  [self applyGridMetrics];
  [collection_ reloadData];
  [collection_ layoutIfNeeded];
  NSArray<UICollectionViewCell*>* cells = [collection_.visibleCells
      sortedArrayUsingComparator:^NSComparisonResult(UICollectionViewCell* a,
                                                     UICollectionViewCell* b) {
        return [[self->collection_ indexPathForCell:a]
            compare:[self->collection_ indexPathForCell:b]];
      }];
  NSArray<UIView*>* views = [cells valueForKey:@"contentView"];
  if (gridMode_) {
    XenraEnterScale(views, 0.92, 0, 0.03, 0.35, XenraCurveDecelerate);
  } else {
    XenraEnter(views, XenraTravelLibraryRow, 0, 0, 0.04, 0.35,
               XenraCurveDecelerate);
  }
}

// --- Display mode --------------------------------------------------------------

- (void)showDisplayMode {
  listButton_.checked = !gridMode_;
  gridButton_.checked = gridMode_;
  gridHint_.hidden = !gridMode_ || games_.count == 0;
}

- (void)setGridMode:(BOOL)grid {
  if (grid == gridMode_) return;
  gridMode_ = grid;
  [XenraSettings setString:grid ? @"grid" : @"list" forKey:@"library.view"];
  // The grid has no selection, so nothing should stay lit for a row that left.
  if (grid) [self clearSelection];
  [self showDisplayMode];
  [self.view layoutIfNeeded];
  [collection_ setContentOffset:CGPointZero animated:NO];
  [self renderWithEntrance];
}

// resolveCoverGridColumns: by the screen, not by the panel.
- (NSInteger)gridColumns {
  const CGSize size = self.view.bounds.size;
  const NSInteger suggested = MIN(4, MAX(2, (NSInteger)(size.width / 180)));
  return size.width > size.height ? MAX(3, suggested) : suggested;
}

- (void)applyGridMetrics {
  layout_.columns = gridMode_ ? self.gridColumns : 0;
  layout_.minimumLineSpacing = gridMode_ ? kGridRowGap : kRowGap;
  layout_.minimumInteritemSpacing = gridMode_ ? kGridColumnGap : 0;
}

- (CGSize)tileCoverSize {
  const CGFloat card = self.tileWidth - kTilePadding * 2;
  const BOOL x360 = [XenraSettings console] == XenraConsole360;
  return CGSizeMake(card, x360 ? card : ceil(card * 1.5));
}

- (CGFloat)tileWidth {
  const NSInteger columns = self.gridColumns;
  return floor((collection_.bounds.size.width - kGridColumnGap * (columns - 1)) /
               columns);
}

// --- Data source ---------------------------------------------------------------

- (NSInteger)collectionView:(UICollectionView*)view
     numberOfItemsInSection:(NSInteger)section {
  return games_.count;
}

- (UICollectionViewCell*)collectionView:(UICollectionView*)view
                 cellForItemAtIndexPath:(NSIndexPath*)path {
  XenraGameEntry* game = games_[path.item];
  if (gridMode_) {
    XenraGameTileCell* cell =
        [view dequeueReusableCellWithReuseIdentifier:@"tile" forIndexPath:path];
    [cell showGame:game coverSize:self.tileCoverSize];
    return cell;
  }
  XenraGameRowCell* cell =
      [view dequeueReusableCellWithReuseIdentifier:@"row" forIndexPath:path];
  [cell showGame:game];
  cell.chosen = selected_ && [selected_.path isEqualToString:game.path];
  return cell;
}

- (CGSize)collectionView:(UICollectionView*)view
                    layout:(UICollectionViewLayout*)layout
    sizeForItemAtIndexPath:(NSIndexPath*)path {
  if (!gridMode_) return CGSizeMake(view.bounds.size.width, kRowHeight);
  return CGSizeMake(self.tileWidth, kTilePadding * 2 + self.tileCoverSize.height +
                                        kTileTitleGap + kTileTitleHeight);
}

// Covers a little ahead of the scroll, so a tile usually has its art on arrival.
- (void)collectionView:(UICollectionView*)view
    prefetchItemsAtIndexPaths:(NSArray<NSIndexPath*>*)paths {
  XenraCovers* covers = XenraCovers.shared;
  const CGSize size = gridMode_ ? self.tileCoverSize : kRowCoverSize;
  for (NSIndexPath* path in paths) {
    if (path.item >= (NSInteger)games_.count || prefetches_[path]) continue;
    XenraGameEntry* game = games_[path.item];
    if ([covers cachedCoverForGame:game pointSize:size]) continue;
    prefetches_[path] = [covers loadCoverForGame:game
                                       pointSize:size
                                      completion:^(UIImage* image){
                                      }];
  }
}

- (void)collectionView:(UICollectionView*)view
    cancelPrefetchingForItemsAtIndexPaths:(NSArray<NSIndexPath*>*)paths {
  for (NSIndexPath* path in paths) {
    [prefetches_[path] cancel];
    [prefetches_ removeObjectForKey:path];
  }
}

// --- Selecting and launching ---------------------------------------------------

- (void)collectionView:(UICollectionView*)view
    didSelectItemAtIndexPath:(NSIndexPath*)path {
  [view deselectItemAtIndexPath:path animated:NO];
  if (path.item >= (NSInteger)games_.count) return;
  XenraGameEntry* game = games_[path.item];
  if (gridMode_ || [selected_.path isEqualToString:game.path]) {
    [self launch:game];
  } else {
    [self selectGame:game at:path];
  }
}

- (void)paintRows {
  for (UICollectionViewCell* cell in collection_.visibleCells) {
    if (![cell isKindOfClass:XenraGameRowCell.class]) continue;
    XenraGameRowCell* row = (XenraGameRowCell*)cell;
    row.chosen = selected_ && [selected_.path isEqualToString:row.gamePath];
  }
}

- (void)selectGame:(XenraGameEntry*)game at:(NSIndexPath*)path {
  selected_ = game;
  [self paintRows];

  detailTitle_.text = game.name;
  // Save states do not exist on this port, and nothing counts content yet: the
  // same two lines Android shows for a game with none.
  detailSaves_.text = XS(@"0 saves");
  detailContent_.text = XS(@"0 content items");
  detailSize_.text =
      game.fileSize
          ? [NSString stringWithFormat:@"%llu MB", game.fileSize / 1024 / 1024]
          : game.subtitle;
  [icon_.cover showGame:game size:kDetailCoverSize];

  [self.view setNeedsLayout];
  [self.view layoutIfNeeded];
  // The strip in portrait can land on top of the row just tapped.
  UICollectionViewLayoutAttributes* row =
      [layout_ layoutAttributesForItemAtIndexPath:path];
  const CGRect visible = {collection_.contentOffset, collection_.bounds.size};
  if (row && !CGRectContainsRect(visible, row.frame)) {
    [collection_ scrollToItemAtIndexPath:path
                        atScrollPosition:UICollectionViewScrollPositionNone
                                animated:YES];
  }
  detail_.alpha = 0;
  XenraAnimate(0.2, 0, XenraCurveStandard,
               ^{
                 self->detail_.alpha = 1;
               },
               nil);
  [icon_ startPulse];
}

- (void)clearSelection {
  if (!selected_) return;
  selected_ = nil;
  [self paintRows];
  [self.view setNeedsLayout];
}

- (void)goBack {
  if (menu_) {
    [menu_ dismiss];
  } else if (selected_) {
    [self clearSelection];
    [self.view layoutIfNeeded];
  } else {
    [self.navigationController popViewControllerAnimated:YES];
  }
}

- (void)openSelected {
  if (selected_) [self launch:selected_];
}

- (void)launch:(XenraGameEntry*)game {
  [self.navigationController
      pushViewController:[[XenraGameController alloc] initWithPath:game.path
                                                              name:game.name]
                animated:YES];
}

// --- Controller ----------------------------------------------------------------

// The game under the cursor, whichever way the library is drawn.
- (XenraGameEntry*)gameUnderCursor {
  for (UIView* view = XenraPadNavFocusedView(); view; view = view.superview) {
    if (![view isKindOfClass:UICollectionViewCell.class]) continue;
    NSIndexPath* path = [collection_ indexPathForCell:(UICollectionViewCell*)view];
    if (path && path.item < (NSInteger)games_.count) return games_[path.item];
    return nil;
  }
  return nil;
}

// Android's onKeyDown: Y opens what a long press opens, and left clears the
// selection. Left only counts from the list, because from the detail panel it is
// the way back to the list.
- (BOOL)xenraPadButton:(XenraPadButton)button {
  if (menu_) return NO;
  XenraGameEntry* cursor = [self gameUnderCursor];
  if (button == XenraPadButtonY) {
    XenraGameEntry* game = cursor ?: selected_;
    if (game) [self showActions:game];
    return game != nil;
  }
  // Away from the detail panel, which Arabic puts on the other side.
  const BOOL mirrored = self.view.effectiveUserInterfaceLayoutDirection ==
                        UIUserInterfaceLayoutDirectionRightToLeft;
  const XenraPadButton away = mirrored ? XenraPadButtonRight : XenraPadButtonLeft;
  if (button == away && selected_ && !gridMode_ && cursor) {
    [self clearSelection];
    return YES;
  }
  return NO;
}

// --- Per-game actions ----------------------------------------------------------

- (void)heldGame:(UILongPressGestureRecognizer*)press {
  if (press.state != UIGestureRecognizerStateBegan) return;
  NSIndexPath* path =
      [collection_ indexPathForItemAtPoint:[press locationInView:collection_]];
  if (path && path.item < (NSInteger)games_.count) {
    [self showActions:games_[path.item]];
  }
}

- (void)showActionsForSelected {
  if (selected_) [self showActions:selected_];
}

// showGameContextMenu, with the entries this port can do. Game data, save states,
// shortcuts and the core switch have nothing behind them on iOS yet.
- (void)showActions:(XenraGameEntry*)game {
  __weak XenraLibraryController* weak = self;
  NSMutableArray<XenraBladeItem*>* items = [NSMutableArray array];
  [items addObject:[XenraBladeItem
                       title:XS(@"Per-Game Settings")
                      action:^{
                        XenraSettingsController* perGame =
                            [[XenraSettingsController alloc] init];
                        perGame.game = game.name;
                        perGame.gameFile = game.fileName;
                        [weak.navigationController pushViewController:perGame
                                                             animated:YES];
                      }]];
  [items addObject:[XenraBladeItem title:XS(@"Set Custom Cover")
                                  action:^{
                                    [weak pickCoverFor:game];
                                  }]];
  if ([XenraCovers.shared hasCustomCoverForGame:game]) {
    [items addObject:[XenraBladeItem title:XS(@"Remove Custom Cover")
                                    action:^{
                                      [weak removeCoverFor:game];
                                    }]];
  }
  XenraBladeItem* remove = [XenraBladeItem title:XS(@"Delete Game")
                                          action:^{
                                            [weak confirmDelete:game];
                                          }];
  remove.destructive = YES;
  [items addObject:remove];
  [XenraBladeSheet showIn:self.view title:game.name message:nil items:items];
}

- (void)confirmDelete:(XenraGameEntry*)game {
  __weak XenraLibraryController* weak = self;
  XenraBladeItem* yes = [XenraBladeItem title:XS(@"Delete")
                                       action:^{
                                         [weak deleteGame:game];
                                       }];
  yes.destructive = YES;
  [XenraBladeSheet
      showConfirmIn:self.view
              title:XS(@"Delete Game")
            message:[NSString
                        stringWithFormat:XS(@"Are you sure you want to delete %@?"),
                                         game.name]
            leading:[XenraBladeItem title:XS(@"Cancel") action:nil]
           trailing:yes];
}

- (void)deleteGame:(XenraGameEntry*)game {
  __weak XenraLibraryController* weak = self;
  [scanner_ deleteGame:game
            completion:^(BOOL deleted) {
              [weak gameDeleted:game ok:deleted];
            }];
}

- (void)gameDeleted:(XenraGameEntry*)game ok:(BOOL)ok {
  XenraToast(self.view,
             [NSString stringWithFormat:ok ? XS(@"Deleted %@") : XS(@"Failed to delete %@"),
                                        game.name]);
  if (ok) [self applyGames:scanner_.cachedGames];
}

- (void)coverChangedFor:(XenraGameEntry*)game {
  [self cancelPrefetches];
  [collection_ reloadData];
  if ([selected_.path isEqualToString:game.path]) {
    [icon_.cover showGame:game size:kDetailCoverSize];
  }
}

- (void)removeCoverFor:(XenraGameEntry*)game {
  __weak XenraLibraryController* weak = self;
  [XenraCovers.shared removeCustomCoverForGame:game
                                    completion:^(BOOL ok) {
                                      XenraLibraryController* strong = weak;
                                      if (!ok || !strong) return;
                                      [strong coverChangedFor:game];
                                      XenraToast(strong.view,
                                                 XS(@"Custom cover removed"));
                                    }];
}

// --- Overflow ------------------------------------------------------------------

- (void)showOverflow {
  if (menu_) {
    [menu_ dismiss];
    return;
  }
  __weak XenraLibraryController* weak = self;
  NSMutableArray<XenraBladeItem*>* items = [NSMutableArray array];
  [items addObject:[XenraBladeItem title:XS(@"Set game folder")
                                  action:^{
                                    [weak pickFolder];
                                  }]];
  [items addObject:[XenraBladeItem title:XS(@"Install content")
                                  action:^{
                                    [weak pickContent];
                                  }]];
  if ([XenraSettings console] == XenraConsole360) {
    [items addObject:[XenraBladeItem title:XS(@"Profiles")
                                    action:^{
                                      [weak showProfilesNotice];
                                    }]];
    [items addObject:[XenraBladeItem title:XS(@"Open user data")
                                    action:^{
                                      [weak showUserDataPath];
                                    }]];
  }
  menu_ = [XenraAnchorMenu showIn:self.view anchor:moreButton_ items:items];
  menu_.onClose = ^{
    XenraLibraryController* strong = weak;
    if (strong) strong->menu_ = nil;
  };
}

- (void)showProfilesNotice {
  [XenraBladeSheet showIn:self.view
                    title:XS(@"Profiles")
                  message:XS(@"Profiles aren't available on iPad and iPhone yet.")
                    items:@[]];
}

- (void)showUserDataPath {
  [XenraBladeSheet showIn:self.view
                    title:XS(@"Open user data")
                  message:XS(@"In the Files app: On My iPad, then Xenra. Saves, "
                          "content and logs are all there.")
                    items:@[]];
}

// --- Picking -------------------------------------------------------------------

- (void)present:(UIDocumentPickerViewController*)picker {
  picker.delegate = self;
  picker.overrideUserInterfaceStyle = XenraInterfaceStyle();
  [self presentViewController:picker animated:YES completion:nil];
}

- (void)pickFolder {
  picking_ = XenraLibraryPickFolder;
  [self present:[[UIDocumentPickerViewController alloc]
                    initForOpeningContentTypes:@[ UTTypeFolder ]]];
}

// Any file: a package has no extension to match on. In place rather than copied,
// because a disc image is gigabytes and the installer only needs to read it.
- (void)pickContent {
  if (g_installing) {
    XenraToast(self.view, XS(@"An install is already running."));
    return;
  }
  picking_ = XenraLibraryPickContent;
  [self present:[[UIDocumentPickerViewController alloc]
                    initForOpeningContentTypes:@[ UTTypeData ]]];
}

- (void)pickCoverFor:(XenraGameEntry*)game {
  picking_ = XenraLibraryPickCover;
  coverTarget_ = game;
  [self present:[[UIDocumentPickerViewController alloc]
                    initForOpeningContentTypes:@[ UTTypeImage ]]];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController*)controller {
  coverTarget_ = nil;
}

- (void)documentPicker:(UIDocumentPickerViewController*)controller
    didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
  NSURL* url = urls.firstObject;
  if (!url) return;
  switch (picking_) {
    case XenraLibraryPickFolder:
      [self useFolder:url];
      break;
    case XenraLibraryPickContent:
      [self installFrom:url];
      break;
    case XenraLibraryPickCover:
      [self useCover:url];
      break;
  }
}

- (void)useFolder:(NSURL*)url {
  const BOOL x360 = [XenraSettings console] == XenraConsole360;
  [url startAccessingSecurityScopedResource];
  [XenraSettings storeBookmark:url key:x360 ? @"games.360" : @"games.og"];
  [url stopAccessingSecurityScopedResource];
  [XenraSettings holdPickedFiles];
  [self refresh];
  [self showBusy:YES message:XS(@"Scanning games...")];
}

- (void)useCover:(NSURL*)url {
  XenraGameEntry* game = coverTarget_;
  coverTarget_ = nil;
  if (!game) return;
  __weak XenraLibraryController* weak = self;
  [XenraCovers.shared setCustomCoverFromURL:url
                                    forGame:game
                                 completion:^(BOOL ok) {
                                   XenraLibraryController* strong = weak;
                                   if (!strong) return;
                                   if (ok) [strong coverChangedFor:game];
                                   XenraToast(strong.view,
                                              ok ? XS(@"Custom cover saved")
                                                 : XS(@"Failed to save custom cover"));
                                 }];
}

- (void)installFrom:(NSURL*)url {
  g_installing = YES;
  [self showBusy:YES message:XS(@"Reading the package…")];
  __weak XenraLibraryController* weak = self;
  XenraInstallFromURL(
      url, [XenraSettings console],
      ^(NSString* message, float fraction) {
        [weak installStep:message fraction:fraction];
      },
      ^(XenraInstallOutcome outcome, NSString* message) {
        g_installing = NO;
        XenraLibraryController* library = weak;
        if (library) {
          [library installDone:outcome message:message];
        } else {
          // The user left this screen; the result still has to reach them.
          UIWindow* window = UIApplication.sharedApplication.delegate.window;
          XenraToast(window.rootViewController.view, message);
        }
      });
}

- (void)installStep:(NSString*)message fraction:(float)fraction {
  [self showBusy:YES message:message];
  progress_.hidden = fraction < 0;
  if (fraction >= 0) progress_.progress = fraction;
}

- (void)installDone:(XenraInstallOutcome)outcome message:(NSString*)message {
  progress_.hidden = YES;
  [self updateHeader];
  [XenraBladeSheet showIn:self.view
                    title:XS(@"Install content")
                  message:message
                    items:@[]];
  if (outcome == XenraInstallGame) [self refresh];
}

#ifdef XENRA_UITEST
// There is no way to photograph the empty card on a tour with games in it.
- (void)tourEmpty:(NSNumber*)empty {
  if (empty.boolValue) {
    games_ = @[];
    [self updateHeader];
    [collection_ reloadData];
  } else {
    [self applyGames:scanner_.cachedGames];
  }
}

// The tour taps by control title, and a cell has none.
- (void)tourTapItem:(NSNumber*)item {
  if (item.integerValue >= (NSInteger)games_.count) return;
  [self collectionView:collection_
      didSelectItemAtIndexPath:[NSIndexPath indexPathForItem:item.integerValue
                                                   inSection:0]];
}
#endif

@end
