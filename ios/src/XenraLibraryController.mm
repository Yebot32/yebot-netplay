#import "XenraScreens.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "XenraBladeView.h"
#import "XenraGameScanner.h"
#import "XenraMotion.h"
#import "XenraSettings.h"
#import "XenraTheme.h"
#import "XenraUI.h"
#import "XenraXemu.h"

// item_game_cover.xml: a card, then a title that always reserves two lines.
@interface XenraGameCell : UICollectionViewCell
@property(nonatomic, strong) UIImageView* cover;
@property(nonatomic, strong) UILabel* name;
@property(nonatomic, strong) UILabel* detail;
- (void)useListLayout:(BOOL)list;
- (void)setCoverImage:(UIImage*)image;
@end

@implementation XenraGameCell {
  UIView* card_;
  XenraPanelView* row_;
  UILabel* unknown_;
  NSArray<NSLayoutConstraint*>* gridConstraints_;
  NSArray<NSLayoutConstraint*>* listConstraints_;
}

- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    row_ = [[XenraPanelView alloc] initWithFrame:CGRectZero];
    row_.chamfer = 14;
    [row_ setFill:XenraPick(0xFF241D0B, 0xA0D8E8A4, 0xFF171719)];
    row_.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:row_];

    card_ = [[UIView alloc] init];
    card_.backgroundColor = XenraBladeFill();
    card_.layer.cornerRadius = 18;
    card_.layer.borderWidth = 1;
    card_.layer.borderColor = XenraAccentAlpha(0x66).CGColor;
    card_.clipsToBounds = YES;
    card_.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:card_];

    // The same "no art yet" mark as Android's list.
    unknown_ = XenraMakeLabel(@"?", 34, UIFontWeightBold, XenraAccent());
    unknown_.textAlignment = NSTextAlignmentCenter;
    [card_ addSubview:unknown_];

    _cover = [[UIImageView alloc] init];
    _cover.contentMode = UIViewContentModeScaleAspectFit;
    _cover.translatesAutoresizingMaskIntoConstraints = NO;
    [card_ addSubview:_cover];

    _name = XenraMakeLabel(nil, 14, UIFontWeightMedium, XenraText());
    _name.numberOfLines = 2;
    [self.contentView addSubview:_name];
    _detail = XenraMakeLabel(nil, 12, UIFontWeightRegular, XenraTextMuted());
    [self.contentView addSubview:_detail];

    [NSLayoutConstraint activateConstraints:@[
      [unknown_.centerXAnchor constraintEqualToAnchor:card_.centerXAnchor],
      [unknown_.centerYAnchor constraintEqualToAnchor:card_.centerYAnchor],
      [row_.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
      [row_.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
      [row_.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
      [row_.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
      [_cover.leadingAnchor constraintEqualToAnchor:card_.leadingAnchor],
      [_cover.trailingAnchor constraintEqualToAnchor:card_.trailingAnchor],
      [_cover.topAnchor constraintEqualToAnchor:card_.topAnchor],
      [_cover.bottomAnchor constraintEqualToAnchor:card_.bottomAnchor],
    ]];
    UIView* content = self.contentView;
    gridConstraints_ = @[
      [card_.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
      [card_.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
      [card_.topAnchor constraintEqualToAnchor:content.topAnchor],
      [card_.heightAnchor constraintEqualToAnchor:card_.widthAnchor],
      [_name.topAnchor constraintEqualToAnchor:card_.bottomAnchor constant:10],
      [_name.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
      [_name.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
    ];
    listConstraints_ = @[
      [card_.leadingAnchor constraintEqualToAnchor:content.leadingAnchor
                                          constant:16],
      [card_.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
      [card_.widthAnchor constraintEqualToConstant:60],
      [card_.heightAnchor constraintEqualToConstant:60],
      [_name.leadingAnchor constraintEqualToAnchor:card_.trailingAnchor
                                          constant:14],
      [_name.trailingAnchor constraintLessThanOrEqualToAnchor:_detail.leadingAnchor
                                                     constant:-12],
      [_name.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
      [_detail.trailingAnchor constraintEqualToAnchor:content.trailingAnchor
                                             constant:-24],
      [_detail.centerYAnchor constraintEqualToAnchor:content.centerYAnchor],
    ];
  }
  return self;
}

- (void)setHighlighted:(BOOL)highlighted {
  [super setHighlighted:highlighted];
  [UIView animateWithDuration:highlighted ? 0.08 : 0.16
                        delay:0
                      options:UIViewAnimationOptionBeginFromCurrentState |
                              UIViewAnimationOptionAllowUserInteraction
                   animations:^{
                     self.contentView.transform =
                         highlighted ? CGAffineTransformMakeScale(0.97, 0.97)
                                     : CGAffineTransformIdentity;
                     self.contentView.alpha = highlighted ? 0.75 : 1;
                   }
                   completion:nil];
}

- (void)setCoverImage:(UIImage*)image {
  _cover.image = image;
  unknown_.hidden = image != nil;
}

- (void)useListLayout:(BOOL)list {
  [NSLayoutConstraint deactivateConstraints:gridConstraints_];
  [NSLayoutConstraint deactivateConstraints:listConstraints_];
  [NSLayoutConstraint activateConstraints:list ? listConstraints_
                                               : gridConstraints_];
  _detail.hidden = !list;
  row_.hidden = !list;
  card_.layer.borderWidth = list ? 0 : 1;
  _name.textAlignment = list ? NSTextAlignmentLeft : NSTextAlignmentCenter;
  _name.numberOfLines = list ? 1 : 2;
}

@end

@interface XenraLibraryController () <UICollectionViewDataSource,
                                      UICollectionViewDelegateFlowLayout,
                                      UIDocumentPickerDelegate>
@end

@implementation XenraLibraryController {
  UICollectionView* collection_;
  UILabel* stats_;
  UIButton* listButton_;
  UIButton* gridButton_;
  UILabel* empty_;
  UIActivityIndicatorView* spinner_;
  XenraGameScanner* scanner_;
  NSArray<XenraGameEntry*>* games_;
  BOOL listMode_;
  BOOL entering_;
}

static NSString* GamesDir(void) {
  return [XenraSettings gameFolders].firstObject;
}

static UIButton* ToolButton(NSString* symbol, id target, SEL action) {
  UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
  [button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
  button.tintColor = XenraAccent();
  button.layer.cornerRadius = 22;
  button.layer.borderWidth = 2;
  button.layer.borderColor = XenraAccent().CGColor;
  [button addTarget:target
                action:action
      forControlEvents:UIControlEventTouchUpInside];
  button.translatesAutoresizingMaskIntoConstraints = NO;
  [NSLayoutConstraint activateConstraints:@[
    [button.widthAnchor constraintEqualToConstant:44],
    [button.heightAnchor constraintEqualToConstant:44],
  ]];
  return button;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  XenraDashboardBackground* background =
      [[XenraDashboardBackground alloc] initWithFrame:self.view.bounds];
  background.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.view addSubview:background];

  listMode_ = [[XenraSettings stringForKey:@"library.view" fallback:@"grid"]
      isEqualToString:@"list"];

  XenraPanelView* panel = [[XenraPanelView alloc] initWithFrame:CGRectZero];
  panel.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:panel];

  UILabel* title = XenraMakeLabel(nil, 24, UIFontWeightBold, XenraAccent());
  title.attributedText = XenraTracked(@"Game Library", 22, XenraAccent());
  stats_ = XenraMakeLabel(nil, 12, UIFontWeightRegular, XenraTextMuted());
  spinner_ = [[UIActivityIndicatorView alloc]
      initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
  spinner_.color = XenraAccent();
  spinner_.hidesWhenStopped = YES;

  UILabel* display = XenraMakeLabel(nil, 12, UIFontWeightBold, XenraTextMuted());
  display.attributedText = XenraTracked(@"Display", 12, XenraTextMuted());
  UIView* spring = [[UIView alloc] init];
  UIView* spring2 = [[UIView alloc] init];

  UIStackView* header = [[UIStackView alloc]
      initWithArrangedSubviews:@[ title, spring, spinner_, stats_ ]];
  header.spacing = 10;
  header.alignment = UIStackViewAlignmentCenter;
  listButton_ = ToolButton(@"list.bullet", self, @selector(showList));
  gridButton_ = ToolButton(@"square.grid.2x2", self, @selector(showGrid));
  [self updateViewButtons];
  UIStackView* tools = [[UIStackView alloc] initWithArrangedSubviews:@[
    display, spring2,
    listButton_,
    gridButton_,
    ToolButton(@"ellipsis", self, @selector(showOverflow)),
  ]];
  tools.spacing = 8;
  tools.alignment = UIStackViewAlignmentCenter;
  UIStackView* top =
      [[UIStackView alloc] initWithArrangedSubviews:@[ header, tools ]];
  top.axis = UILayoutConstraintAxisVertical;
  top.spacing = 8;
  top.translatesAutoresizingMaskIntoConstraints = NO;
  [panel addSubview:top];

  UICollectionViewFlowLayout* layout = [[UICollectionViewFlowLayout alloc] init];
  layout.minimumInteritemSpacing = 14;
  layout.minimumLineSpacing = 18;
  collection_ = [[UICollectionView alloc] initWithFrame:CGRectZero
                                   collectionViewLayout:layout];
  collection_.backgroundColor = UIColor.clearColor;
  collection_.delaysContentTouches = NO;
  collection_.dataSource = self;
  collection_.delegate = self;
  [collection_ registerClass:[XenraGameCell class]
      forCellWithReuseIdentifier:@"game"];
  collection_.translatesAutoresizingMaskIntoConstraints = NO;
  [panel addSubview:collection_];
  [collection_ addGestureRecognizer:[[UILongPressGestureRecognizer alloc]
                                        initWithTarget:self
                                                action:@selector(heldGame:)]];

  empty_ = XenraMakeLabel(nil, 14, UIFontWeightRegular, XenraTextMuted());
  empty_.numberOfLines = 0;
  empty_.textAlignment = NSTextAlignmentCenter;
  [panel addSubview:empty_];

  XenraHintBar* hints = [[XenraHintBar alloc] initWithFrame:CGRectZero];
  __weak XenraLibraryController* weak = self;
  hints.onBack = ^{
    [weak.navigationController popViewControllerAnimated:YES];
  };
  [self.view addSubview:hints];

  UILayoutGuide* safe = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [panel.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
    [panel.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor
                                         constant:-12],
    [panel.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
    [panel.bottomAnchor constraintEqualToAnchor:hints.topAnchor constant:-4],
    [hints.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
    [hints.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
    [hints.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
    [top.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:18],
    [top.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-18],
    [top.topAnchor constraintEqualToAnchor:panel.topAnchor constant:18],
    [collection_.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor
                                              constant:18],
    [collection_.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor
                                               constant:-18],
    [collection_.topAnchor constraintEqualToAnchor:top.bottomAnchor constant:12],
    [collection_.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor
                                             constant:-12],
    [empty_.centerXAnchor constraintEqualToAnchor:panel.centerXAnchor],
    [empty_.centerYAnchor constraintEqualToAnchor:panel.centerYAnchor],
    [empty_.widthAnchor constraintEqualToAnchor:panel.widthAnchor
                                     multiplier:0.75],
  ]];

  [[NSFileManager defaultManager] createDirectoryAtPath:GamesDir()
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
  scanner_ = [[XenraGameScanner alloc] init];
  entering_ = YES;
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self rescan];
}

- (void)rescan {
  if ([XenraSettings console] == XenraConsoleOG && !XenraXemuAvailable()) {
    games_ = @[];
    stats_.text = nil;
    empty_.text = @"This build has no original Xbox core. Switch the console "
                   "to Xbox 360 on the dashboard.";
    empty_.hidden = NO;
    [collection_ reloadData];
    return;
  }
  [spinner_ startAnimating];
  __weak XenraLibraryController* weak = self;
  [scanner_ scanWithCompletion:^(NSArray<XenraGameEntry*>* games) {
    [weak gamesScanned:games];
  }];
}

- (void)gamesScanned:(NSArray<XenraGameEntry*>*)games {
  [spinner_ stopAnimating];
  games_ = games;
  stats_.text = [NSString stringWithFormat:@"TOTAL: %lu   AVAILABLE: %lu",
                                           (unsigned long)games.count,
                                           (unsigned long)games.count];
  empty_.hidden = games.count > 0;
  empty_.text = @"No supported games found in this folder.\n\nAdd them to "
                 "Xenra in the Files app, or use Install content "
                 "from the … menu.";
  [collection_ reloadData];
  [collection_ layoutIfNeeded];
  entering_ = NO;
}

// --- View modes -------------------------------------------------------------

- (void)updateViewButtons {
  for (UIButton* button in @[ listButton_, gridButton_ ]) {
    const BOOL chosen = (button == listButton_) == listMode_;
    button.backgroundColor = chosen ? XenraAccent() : UIColor.clearColor;
    button.tintColor = chosen ? XenraOnAccent() : XenraAccent();
  }
}

- (void)setListMode:(BOOL)list {
  listMode_ = list;
  [XenraSettings setString:list ? @"list" : @"grid" forKey:@"library.view"];
  [self updateViewButtons];
  [collection_ reloadData];
}
- (void)showList {
  [self setListMode:YES];
}
- (void)showGrid {
  [self setListMode:NO];
}

- (void)showOverflow {
  __weak XenraLibraryController* weak = self;
  XenraBladeItem* install =
      [XenraBladeItem title:@"Install content"
                     action:^{
                       [weak pickContent];
                     }];
  XenraBladeItem* rescan = [XenraBladeItem title:@"Rescan folder"
                                          action:^{
                                            [weak rescan];
                                          }];
  XenraBladeItem* data = [XenraBladeItem title:@"Open user data"
                                        action:^{
                                          [weak showUserDataPath];
                                        }];
  [XenraBladeSheet showIn:self.view
                    title:@"More"
                  message:nil
                    items:@[ install, rescan, data ]];
}

- (void)showUserDataPath {
  [XenraBladeSheet showIn:self.view
                    title:@"Open user data"
                  message:@"In the Files app: On My iPad, then Xenra. Saves, "
                          "content and logs are all there."
                    items:@[]];
}

- (void)pickContent {
  UIDocumentPickerViewController* picker = [[UIDocumentPickerViewController alloc]
      initForOpeningContentTypes:@[ UTTypeData ]
                          asCopy:YES];
  picker.delegate = self;
  [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController*)controller
    didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
  NSFileManager* files = NSFileManager.defaultManager;
  for (NSURL* url in urls) {
    NSString* target =
        [GamesDir() stringByAppendingPathComponent:url.lastPathComponent];
    [files moveItemAtPath:url.path toPath:target error:nil];
  }
  [self rescan];
}

// --- Grid -------------------------------------------------------------------

- (NSInteger)collectionView:(UICollectionView*)view
     numberOfItemsInSection:(NSInteger)section {
  return games_.count;
}

- (UICollectionViewCell*)collectionView:(UICollectionView*)view
                 cellForItemAtIndexPath:(NSIndexPath*)path {
  XenraGameCell* cell =
      [view dequeueReusableCellWithReuseIdentifier:@"game" forIndexPath:path];
  XenraGameEntry* game = games_[path.item];
  [cell useListLayout:listMode_];
  cell.name.text = game.name;
  cell.detail.text = game.subtitle;
  [cell setCoverImage:[scanner_ coverForEntryNamed:game.name]];
  return cell;
}

// layout_anim_cards, for the first fill only: scrolling must not replay it.
- (void)collectionView:(UICollectionView*)view
       willDisplayCell:(UICollectionViewCell*)cell
    forItemAtIndexPath:(NSIndexPath*)path {
  if (!entering_) return;
  XenraEnter(@[ cell ], 0, 14, path.item * 0.018, 0, 0.22, XenraCurveQuint);
}

- (CGSize)collectionView:(UICollectionView*)view
                    layout:(UICollectionViewLayout*)layout
    sizeForItemAtIndexPath:(NSIndexPath*)path {
  const CGFloat width = view.bounds.size.width;
  if (listMode_) return CGSizeMake(width, 84);
  const NSInteger columns = MAX(2, (NSInteger)(width / 170));
  const CGFloat side = floor((width - 14 * (columns - 1)) / columns);
  return CGSizeMake(side, side + 52);
}

- (void)launch:(XenraGameEntry*)game {
  [self.navigationController
      pushViewController:[[XenraGameController alloc] initWithPath:game.path
                                                              name:game.name]
                animated:YES];
}

- (void)collectionView:(UICollectionView*)view
    didSelectItemAtIndexPath:(NSIndexPath*)path {
  [self launch:games_[path.item]];
}

- (void)heldGame:(UILongPressGestureRecognizer*)press {
  if (press.state != UIGestureRecognizerStateBegan) return;
  NSIndexPath* path =
      [collection_ indexPathForItemAtPoint:[press locationInView:collection_]];
  if (!path) return;
  XenraGameEntry* game = games_[path.item];
  __weak XenraLibraryController* weak = self;
  XenraBladeItem* play = [XenraBladeItem title:@"Play"
                                        action:^{
                                          [weak launch:game];
                                        }];
  XenraBladeItem* settings = [XenraBladeItem
      title:@"Game settings"
      action:^{
        XenraSettingsController* perGame = [[XenraSettingsController alloc] init];
        perGame.game = game.name;
        [weak.navigationController pushViewController:perGame animated:YES];
      }];
  XenraBladeItem* remove = [XenraBladeItem title:@"Delete game"
                                          action:^{
                                            [weak confirmDelete:game];
                                          }];
  remove.destructive = YES;
  [XenraBladeSheet showIn:self.view
                    title:game.name
                  message:game.subtitle
                    items:@[ play, settings, remove ]];
}

- (void)confirmDelete:(XenraGameEntry*)game {
  __weak XenraLibraryController* weak = self;
  XenraBladeItem* yes = [XenraBladeItem
      title:@"Delete"
      action:^{
        [NSFileManager.defaultManager removeItemAtPath:game.path error:nil];
        [weak rescan];
      }];
  yes.destructive = YES;
  [XenraBladeSheet showIn:self.view
                    title:@"Delete game"
                  message:[NSString stringWithFormat:@"%@ will be removed from "
                                                      "this iPad.",
                                                     game.name]
                    items:@[ yes, [XenraBladeItem title:@"Cancel" action:nil] ]];
}

@end
