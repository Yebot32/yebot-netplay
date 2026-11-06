#import "XenraLanguage.h"

#import "XenraStrings.h"
#import "XenraTheme.h"

// ic_xaniteog_language and ic_xaniteog_check_circle.
static NSString* const kIconGlobe =
    @"M480-80q-83 0-156-31.5T197-197q-54-54-85.5-127T80-480q0-83 31.5-156T197-763q54"
     "-54 127-85.5T480-880q83 0 156 31.5T763-763q54 54 85.5 127T880-480q0 83-31.5 156"
     "T763-197q-54 54-127 85.5T480-80Zm0-82q26-36 45-75t31-83H404q12 44 31 83t45 75Zm"
     "-104-16q-18-33-31.5-68.5T322-320H204q29 50 72.5 87t99.5 55Zm208 0q56-18 99.5-55"
     "t72.5-87H638q-9 38-22.5 73.5T584-178ZM170-400h136q-3-20-4.5-39.5T300-480q0-21 1"
     ".5-40.5T306-560H170q-5 20-7.5 39.5T160-480q0 21 2.5 40.5T170-400Zm216 0h188q3-2"
     "0 4.5-39.5T580-480q0-21-1.5-40.5T574-560H386q-3 20-4.5 39.5T380-480q0 21 1.5 40"
     ".5T386-400Zm268 0h136q5-20 7.5-39.5T800-480q0-21-2.5-40.5T790-560H654q3 20 4.5 "
     "39.5T660-480q0 21-1.5 40.5T654-400Zm-16-240h118q-29-50-72.5-87T584-782q18 33 31"
     ".5 68.5T638-640Zm-234 0h152q-12-44-31-83t-45-75q-26 36-45 75t-31 83Zm-200 0h118"
     "q9-38 22.5-73.5T376-782q-56 18-99.5 55T204-640Z";
static NSString* const kIconCheck =
    @"m424-408-86-86q-11-11-28-11t-28 11q-11 11-11 28t11 28l114 114q12 12 28 12t28-1"
     "2l226-226q11-11 11-28t-11-28q-11-11-28-11t-28 11L424-408ZM480-80q-83 0-156-31.5"
     "T197-197q-54-54-85.5-127T80-480q0-83 31.5-156T197-763q54-54 127-85.5T480-880q83"
     " 0 156 31.5T763-763q54 54 85.5 127T880-480q0 83-31.5 156T763-197q-54 54-127 85."
     "5T480-80Z";

// LocaleHelper.supportedLocales, in its order. The second name stays English on
// purpose: it is the way back for someone who picked a script they cannot read.
struct Language {
  NSString* code;
  NSString* badge;
  NSString* name;
  NSString* english;
};

static const Language kLanguages[] = {
    {@"en", @"EN", @"English", @"English"},
    {@"ru", @"RU", @"Русский", @"Russian"},
    {@"es", @"ES", @"Español", @"Spanish"},
    {@"zh-Hans", @"ZH", @"中文", @"Chinese"},
    {@"ar", @"AR", @"العربية", @"Arabic"},
    {@"pt-BR", @"PT", @"Português (Brasil)", @"Portuguese (Brazil)"},
    {@"de", @"DE", @"Deutsch", @"German"},
    {@"fr", @"FR", @"Français", @"French"},
    {@"ja", @"JA", @"日本語", @"Japanese"},
};

// Picked in this run, so the wizard's badge does not go on showing the old one.
static NSString* g_pending;

static const Language& Current(void) {
  NSString* code = g_pending ?: NSBundle.mainBundle.preferredLocalizations.firstObject;
  for (const Language& language : kLanguages) {
    if ([language.code isEqual:code]) return language;
  }
  return kLanguages[0];
}

NSString* XenraLanguageBadge(void) { return Current().badge; }

NSString* XenraLanguageName(void) { return Current().name; }

// The note about a language is in that language: the running one may be the one
// its reader could not read.
static NSString* TextIn(NSString* code, NSString* english) {
  NSString* path = [NSBundle.mainBundle pathForResource:code ofType:@"lproj"];
  NSBundle* bundle = path ? [NSBundle bundleWithPath:path] : nil;
  return bundle ? [bundle localizedStringForKey:english value:english table:nil]
                : english;
}

static void Choose(UIView* host, NSString* code, void (^changed)(void)) {
  g_pending = code;
  [NSUserDefaults.standardUserDefaults setObject:@[ code ] forKey:@"AppleLanguages"];
  [NSUserDefaults.standardUserDefaults synchronize];
  if (changed) changed();
  [XenraBladeSheet
      showConfirmIn:host
              title:TextIn(code, XSKey(@"App Language"))
            message:TextIn(code, XSKey(@"Language changed. Please restart the app "
                                        "for full effect."))
            leading:[XenraBladeItem title:TextIn(code, XSKey(@"Not Now")) action:nil]
           trailing:[XenraBladeItem title:TextIn(code, XSKey(@"Close App"))
                                   action:^{
                                     exit(0);
                                   }]];
}

// item_language_option: the code badge, the name over its English name, a check on
// the one in use. Its title is the English name, for the tour.
@interface XenraLanguageRow : XenraPressControl
- (instancetype)initWithLanguage:(const Language&)language
                         current:(BOOL)current
                          action:(void (^)(void))action;
@end

@implementation XenraLanguageRow {
  UIView* wash_;
}

- (instancetype)initWithLanguage:(const Language&)language
                         current:(BOOL)current
                          action:(void (^)(void))action {
  self = [super initWithFrame:CGRectZero];
  if (self) {
    self.title = language.english;
    self.action = action;
    self.accessibilityLabel = language.name;
    self.accessibilityValue = current ? XS(@"Currently selected") : nil;

    wash_ = [[UIView alloc] init];
    wash_.alpha = 0;
    wash_.backgroundColor = XenraAccentAlpha(0x22);
    wash_.layer.cornerRadius = 8;
    wash_.userInteractionEnabled = NO;
    wash_.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:wash_];

    UIView* badge = [[UIView alloc] init];
    badge.backgroundColor = XenraAccentAlpha(0x1A);
    badge.layer.cornerRadius = 8;
    badge.layer.borderWidth = 1;
    badge.layer.borderColor = XenraAccentAlpha(0x33).CGColor;
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel* code =
        XenraMakeLabel(language.badge, 12, UIFontWeightBold, XenraAccentText());
    code.textAlignment = NSTextAlignmentCenter;
    code.translatesAutoresizingMaskIntoConstraints = NO;
    [badge addSubview:code];

    UILabel* name = XenraMakeLabel(language.name, 16, UIFontWeightRegular, XenraText());
    UILabel* english =
        XenraMakeLabel(language.english, 12, UIFontWeightRegular, XenraTextMuted());
    UIStackView* names =
        [[UIStackView alloc] initWithArrangedSubviews:@[ name, english ]];
    names.axis = UILayoutConstraintAxisVertical;

    UIImageView* check =
        [[UIImageView alloc] initWithImage:XenraMaterialIcon(kIconCheck, 22)];
    check.tintColor = XenraAccent();
    check.alpha = current ? 1 : 0;
    check.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView* line =
        [[UIStackView alloc] initWithArrangedSubviews:@[ badge, names, check ]];
    line.alignment = UIStackViewAlignmentCenter;
    line.spacing = 14;
    line.userInteractionEnabled = NO;
    line.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:line];

    [NSLayoutConstraint activateConstraints:@[
      [wash_.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
      [wash_.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
      [wash_.topAnchor constraintEqualToAnchor:self.topAnchor],
      [wash_.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
      [badge.widthAnchor constraintEqualToConstant:42],
      [badge.heightAnchor constraintEqualToConstant:30],
      [code.centerXAnchor constraintEqualToAnchor:badge.centerXAnchor],
      [code.centerYAnchor constraintEqualToAnchor:badge.centerYAnchor],
      [check.widthAnchor constraintEqualToConstant:22],
      [check.heightAnchor constraintEqualToConstant:22],
      [line.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],
      [line.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
      [line.topAnchor constraintGreaterThanOrEqualToAnchor:self.topAnchor constant:8],
      [line.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [self.heightAnchor constraintGreaterThanOrEqualToConstant:60],
    ]];
  }
  return self;
}

- (void)pressedChanged {
  const BOOL pressed = self.pressed;
  [UIView animateWithDuration:pressed ? 0.12 : 0.18
                   animations:^{
                     self->wash_.alpha = pressed ? 1 : 0;
                   }];
}

@end

// The header of dialog_language_picker: globe, title, subtitle, and the divider.
// Kept clear of the sheet's close control at the end.
static UIView* Heading(void) {
  UIImageView* globe =
      [[UIImageView alloc] initWithImage:XenraMaterialIcon(kIconGlobe, 26)];
  globe.tintColor = XenraAccent();
  globe.translatesAutoresizingMaskIntoConstraints = NO;
  UILabel* title =
      XenraMakeLabel(XS(@"App Language"), 16, UIFontWeightBold, XenraText());
  UILabel* subtitle = XenraMakeLabel(XS(@"Choose the language for the interface"), 12,
                                     UIFontWeightRegular, XenraTextMuted());
  subtitle.numberOfLines = 2;
  UIStackView* words =
      [[UIStackView alloc] initWithArrangedSubviews:@[ title, subtitle ]];
  words.axis = UILayoutConstraintAxisVertical;
  UIStackView* line = [[UIStackView alloc] initWithArrangedSubviews:@[ globe, words ]];
  line.alignment = UIStackViewAlignmentCenter;
  line.spacing = 12;
  line.translatesAutoresizingMaskIntoConstraints = NO;
  UIView* divider = [[UIView alloc] init];
  divider.backgroundColor = XenraOutlineVariant();
  divider.translatesAutoresizingMaskIntoConstraints = NO;
  UIView* box = [[UIView alloc] init];
  [box addSubview:line];
  [box addSubview:divider];
  [NSLayoutConstraint activateConstraints:@[
    [globe.widthAnchor constraintEqualToConstant:26],
    [globe.heightAnchor constraintEqualToConstant:26],
    [line.leadingAnchor constraintEqualToAnchor:box.leadingAnchor],
    [line.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-28],
    [line.topAnchor constraintEqualToAnchor:box.topAnchor],
    [divider.topAnchor constraintEqualToAnchor:line.bottomAnchor constant:12],
    [divider.leadingAnchor constraintEqualToAnchor:box.leadingAnchor],
    [divider.trailingAnchor constraintEqualToAnchor:box.trailingAnchor],
    [divider.heightAnchor constraintEqualToConstant:1],
    [divider.bottomAnchor constraintEqualToAnchor:box.bottomAnchor],
  ]];
  return box;
}

void XenraShowLanguagePicker(UIView* host, void (^changed)(void)) {
  NSString* current = Current().code;
  NSMutableArray<XenraPressControl*>* rows = [NSMutableArray array];
  __weak UIView* weak = host;
  for (const Language& language : kLanguages) {
    NSString* code = language.code;
    const BOOL same = [code isEqual:current];
    [rows addObject:[[XenraLanguageRow alloc] initWithLanguage:language
                                                       current:same
                                                        action:^{
                                                          if (!same && weak) {
                                                            Choose(weak, code, changed);
                                                          }
                                                        }]];
  }
  [XenraBladeSheet showIn:host heading:Heading() rows:rows];
}

@implementation XenraLanguageButton {
  UILabel* label_;
  UIView* wash_;
}

- (instancetype)initWithAction:(void (^)(void))action {
  self = [super initWithFrame:CGRectZero];
  if (self) {
    self.title = XS(@"App Language");
    self.accessibilityLabel = self.title;
    self.action = action;
    self.backgroundColor = XenraSurface();
    self.clipsToBounds = YES;
    self.layer.cornerRadius = 16;
    self.layer.borderWidth = 1.5;
    self.layer.borderColor = XenraAccentDark().CGColor;
    wash_ = [[UIView alloc] init];
    wash_.alpha = 0;
    wash_.backgroundColor = XenraAccentAlpha(0x33);
    wash_.userInteractionEnabled = NO;
    wash_.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:wash_];
    UIImageView* globe =
        [[UIImageView alloc] initWithImage:XenraMaterialIcon(kIconGlobe, 18)];
    globe.tintColor = XenraAccentLight();
    globe.translatesAutoresizingMaskIntoConstraints = NO;
    label_ = XenraMakeLabel(nil, 14, UIFontWeightBold, XenraAccentLight());
    UIStackView* line = [[UIStackView alloc] initWithArrangedSubviews:@[ globe, label_ ]];
    line.alignment = UIStackViewAlignmentCenter;
    line.spacing = 6;
    line.userInteractionEnabled = NO;
    line.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:line];
    [NSLayoutConstraint activateConstraints:@[
      [wash_.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
      [wash_.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
      [wash_.topAnchor constraintEqualToAnchor:self.topAnchor],
      [wash_.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
      [globe.widthAnchor constraintEqualToConstant:18],
      [globe.heightAnchor constraintEqualToConstant:18],
      [line.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
      [line.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-14],
      [line.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [self.heightAnchor constraintEqualToConstant:44],
    ]];
    [self refresh];
  }
  return self;
}

- (void)refresh {
  label_.text = XenraLanguageBadge();
}

- (void)pressedChanged {
  const BOOL pressed = self.pressed;
  [UIView animateWithDuration:pressed ? 0.12 : 0.18
                   animations:^{
                     self->wash_.alpha = pressed ? 1 : 0;
                   }];
}

@end
