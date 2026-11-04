#import "XenraScreens.h"

#import "XenraAmbient.h"
#import "XenraBladeView.h"
#import "XenraLogs.h"
#import "XenraMotion.h"
#import "XenraSettings.h"
#import "XenraTheme.h"
#import "XenraUI.h"

// Android keeps blades for the tabs in landscape and chips in portrait, on
// purpose. One stack does both by switching axis.
@implementation XenraSettingsController {
  UIStackView* root_;
  UIScrollView* tabScroll_;
  UIStackView* tabStack_;
  NSLayoutConstraint* tabWidth_;
  NSLayoutConstraint* tabHeight_;
  NSLayoutConstraint* tabFill_;
  UIStackView* content_;
  NSArray<XenraSettingTab*>* tabs_;
  NSInteger current_;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  XenraDashboardBackground* background =
      [[XenraDashboardBackground alloc] initWithFrame:self.view.bounds];
  background.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.view addSubview:background];

  if (_game) {
    XenraSettingSection* section = [[XenraSettingSection alloc] init];
    section.title = _game;
    section.rows = [XenraSettings perGameRows];
    XenraSettingTab* tab = [[XenraSettingTab alloc] init];
    tab.title = @"This game";
    tab.sections = @[ section ];
    tabs_ = @[ tab ];
  } else {
    tabs_ = [XenraSettings tabs];
  }

  tabStack_ = [[UIStackView alloc] init];
  tabStack_.spacing = 8;
  tabStack_.translatesAutoresizingMaskIntoConstraints = NO;
  tabScroll_ = [[UIScrollView alloc] init];
  tabScroll_.showsHorizontalScrollIndicator = NO;
  tabScroll_.translatesAutoresizingMaskIntoConstraints = NO;
  [tabScroll_ addSubview:tabStack_];

  __weak XenraSettingsController* weak = self;
  for (NSUInteger i = 0; i < tabs_.count; i++) {
    XenraBladeButton* blade =
        [[XenraBladeButton alloc] initWithTitle:tabs_[i].title
                                         action:^{
                                           [weak selectTab:(NSInteger)i];
                                         }];
    [tabStack_ addArrangedSubview:blade];
  }

  XenraPanelView* panel = [[XenraPanelView alloc] initWithFrame:CGRectZero];
  panel.translatesAutoresizingMaskIntoConstraints = NO;
  UIScrollView* scroll = [[UIScrollView alloc] init];
  scroll.translatesAutoresizingMaskIntoConstraints = NO;
  [panel addSubview:scroll];
  content_ = [[UIStackView alloc] init];
  content_.axis = UILayoutConstraintAxisVertical;
  content_.spacing = 10;
  content_.translatesAutoresizingMaskIntoConstraints = NO;
  [scroll addSubview:content_];

  root_ = [[UIStackView alloc] initWithArrangedSubviews:@[ tabScroll_, panel ]];
  root_.spacing = 12;
  root_.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:root_];

  XenraHintBar* hints = [[XenraHintBar alloc] initWithFrame:CGRectZero];
  hints.onBack = ^{
    [weak.navigationController popViewControllerAnimated:YES];
  };
  [self.view addSubview:hints];

  tabWidth_ = [tabScroll_.widthAnchor constraintEqualToConstant:230];
  tabHeight_ = [tabScroll_.heightAnchor constraintEqualToConstant:56];
  tabFill_ = [tabStack_.widthAnchor constraintEqualToAnchor:tabScroll_.widthAnchor];
  UILayoutGuide* safe = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [root_.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
    [root_.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor
                                         constant:-12],
    [root_.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
    [root_.bottomAnchor constraintEqualToAnchor:hints.topAnchor constant:-4],
    [hints.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
    [hints.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
    [hints.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
    [tabStack_.leadingAnchor constraintEqualToAnchor:tabScroll_.leadingAnchor],
    [tabStack_.trailingAnchor constraintEqualToAnchor:tabScroll_.trailingAnchor],
    [tabStack_.topAnchor constraintEqualToAnchor:tabScroll_.topAnchor],
    [tabStack_.bottomAnchor constraintEqualToAnchor:tabScroll_.bottomAnchor],
    [scroll.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:18],
    [scroll.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor
                                          constant:-18],
    [scroll.topAnchor constraintEqualToAnchor:panel.topAnchor constant:18],
    [scroll.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-18],
    [content_.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor],
    [content_.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor],
    [content_.topAnchor constraintEqualToAnchor:scroll.topAnchor],
    [content_.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor],
    [content_.widthAnchor constraintEqualToAnchor:scroll.widthAnchor],
  ]];
  [self selectTab:0];
}

- (void)viewWillLayoutSubviews {
  [super viewWillLayoutSubviews];
  const BOOL landscape = self.view.bounds.size.width > self.view.bounds.size.height;
  root_.axis = landscape ? UILayoutConstraintAxisHorizontal
                         : UILayoutConstraintAxisVertical;
  tabStack_.axis = landscape ? UILayoutConstraintAxisVertical
                             : UILayoutConstraintAxisHorizontal;
  tabWidth_.active = landscape;
  tabHeight_.active = !landscape;
  tabFill_.active = landscape;
}

- (void)selectTab:(NSInteger)index {
  current_ = index;
  [tabStack_.arrangedSubviews
      enumerateObjectsUsingBlock:^(UIView* view, NSUInteger i, BOOL*) {
        ((XenraBladeButton*)view).chosen = (NSInteger)i == index;
      }];
  [self rebuild];
}

- (void)rebuild {
  for (UIView* view in content_.arrangedSubviews) {
    [view removeFromSuperview];
  }
  for (XenraSettingSection* section in tabs_[current_].sections) {
    UILabel* header = XenraMakeLabel(nil, 13, UIFontWeightBold, XenraAccent());
    header.attributedText = XenraTracked(section.title, 13, XenraAccent());
    [content_ addArrangedSubview:header];
    for (XenraSettingRow* row in section.rows) {
      [content_ addArrangedSubview:[self viewForRow:row]];
    }
  }
  if (_game) {
    __weak XenraSettingsController* weak = self;
    XenraBladeButton* clear = [[XenraBladeButton alloc]
        initWithTitle:@"Use global settings"
               action:^{
                 [weak clearOverrides];
               }];
    [content_ addArrangedSubview:clear];
  }
  // layout_anim_cards: a short rise, staggered down the list.
  XenraEnter(content_.arrangedSubviews, 0, 14, 0, 0.018, 0.22, XenraCurveQuint);
}

- (void)clearOverrides {
  [XenraSettings clearOverridesForGame:_game];
  [self rebuild];
}

- (NSString*)titleForValue:(NSString*)value row:(XenraSettingRow*)row {
  const NSUInteger i = [row.choiceValues indexOfObject:value];
  return i == NSNotFound ? value : row.choiceTitles[i];
}

- (UIView*)viewForRow:(XenraSettingRow*)row {
  __weak XenraSettingsController* weak = self;
  if (row.kind == XenraRowToggle) {
    UILabel* title = XenraMakeLabel(row.title, 15, UIFontWeightMedium, XenraText());
    UILabel* detail =
        XenraMakeLabel(row.detail, 12, UIFontWeightRegular, XenraTextMuted());
    detail.numberOfLines = 0;
    detail.hidden = row.detail.length == 0;
    UIStackView* text =
        [[UIStackView alloc] initWithArrangedSubviews:@[ title, detail ]];
    text.axis = UILayoutConstraintAxisVertical;
    UISwitch* toggle = [[UISwitch alloc] init];
    toggle.onTintColor = XenraAccent();
    toggle.on = [[XenraSettings valueForRow:row game:_game] isEqual:@"true"];
    [toggle addAction:[UIAction actionWithHandler:^(UIAction* action) {
              [XenraSettings setValue:((UISwitch*)action.sender).on ? @"true"
                                                                    : @"false"
                                  row:row
                                 game:nil];
              if ([row.key hasPrefix:@"music."]) XenraAmbientStart();
            }]
        forControlEvents:UIControlEventValueChanged];
    UIStackView* line =
        [[UIStackView alloc] initWithArrangedSubviews:@[ text, toggle ]];
    line.alignment = UIStackViewAlignmentCenter;
    line.spacing = 12;
    return line;
  }
  XenraBladeButton* blade = [[XenraBladeButton alloc]
      initWithTitle:row.title
             action:^{
               [weak tapped:row];
             }];
  if (row.kind == XenraRowChoice) {
    NSString* value = [self titleForValue:[XenraSettings valueForRow:row game:_game]
                                      row:row];
    blade.subtitle = row.detail.length
                         ? [NSString stringWithFormat:@"%@\n%@", value, row.detail]
                         : value;
  } else {
    blade.subtitle = row.detail;
  }
  return blade;
}

- (void)tapped:(XenraSettingRow*)row {
  if (row.kind == XenraRowChoice) {
    NSMutableArray* items = [NSMutableArray array];
    __weak XenraSettingsController* weak = self;
    NSString* game = _game;
    for (NSUInteger i = 0; i < row.choiceValues.count; i++) {
      NSString* value = row.choiceValues[i];
      [items addObject:[XenraBladeItem title:row.choiceTitles[i]
                                      action:^{
                                        [XenraSettings setValue:value
                                                            row:row
                                                           game:game];
                                        if ([row.key hasPrefix:@"music."]) {
                                          XenraAmbientStart();
                                        }
                                        [weak rebuild];
                                      }]];
    }
    [XenraBladeSheet showIn:self.view title:row.title message:nil items:items];
    return;
  }
  if ([row.key isEqual:@"setup.rerun"]) {
    XenraRestartSetup(self.view.window);
  } else if ([row.key isEqual:@"privacy"]) {
    XenraShowPrivacyPolicy(self.view);
  } else if ([row.key isEqual:@"jit.enable"]) {
    XenraOpenJitEnabler();
  } else if ([row.key isEqual:@"log.share"]) {
    XenraShareLogs(self, nil);
  } else if ([row.key isEqual:@"cache.clear"]) {
    NSString* caches = NSSearchPathForDirectoriesInDomains(
                           NSCachesDirectory, NSUserDomainMask, YES)
                           .firstObject;
    NSFileManager* files = NSFileManager.defaultManager;
    for (NSString* name in [files contentsOfDirectoryAtPath:caches error:nil]) {
      [files removeItemAtPath:[caches stringByAppendingPathComponent:name]
                        error:nil];
    }
    [XenraBladeSheet showIn:self.view
                      title:row.title
                    message:@"Done."
                      items:@[]];
  }
}

@end
