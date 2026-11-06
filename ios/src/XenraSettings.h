/**
 ******************************************************************************
 * Xenra : iOS shell - settings model                                         *
 ******************************************************************************
 *
 * What the settings screens show and where each value goes. The panes are per
 * console, as on Android, so a 360 row never appears in original Xbox mode. A row
 * reaches its core one of three ways:
 *
 *   cvars        pushed into Xenia by applyForGame just before boot
 *   configTable  a line of xemu-ios.toml, from xemuConfigForTable:game:
 *   anything else is read by name, by XenraXemu.mm or the game screen
 *
 * The original Xbox presenter takes its pacing, aspect and filter from the
 * environment, not the TOML: see xemuEnvironmentForGame:. A row whose value does
 * not reach anything has no place here, so before adding one check the core reads
 * it on this platform. Metal and MoltenVK skip a good many of Android's.
 *
 * A per-game value overrides the global one, the way Android's
 * <TITLE_ID>.config.toml overlay does. Titles are Android's strings.xml wording.
 */

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, XenraConsole) {
  XenraConsole360 = 0,
  XenraConsoleOG = 1,
};

typedef NS_ENUM(NSInteger, XenraRowKind) {
  XenraRowToggle,
  XenraRowChoice,   // a long list: the value beside the title, picked in a sheet
  XenraRowSegment,  // two to four values side by side
  XenraRowSlider,
  XenraRowText,
  XenraRowAction,
};

@interface XenraSettingRow : NSObject
@property(nonatomic, copy) NSString* key;
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy) NSString* detail;
@property(nonatomic, assign) XenraRowKind kind;
@property(nonatomic, copy) NSArray<NSString*>* choiceTitles;
@property(nonatomic, copy) NSArray<NSString*>* choiceValues;
@property(nonatomic, copy) NSString* defaultValue;
// Sliders. Stored as a whole number when the step is, otherwise to two places.
@property(nonatomic, assign) float minimum;
@property(nonatomic, assign) float maximum;
@property(nonatomic, assign) float step;
@property(nonatomic, copy) NSString* (^format)(float value);
// Xenia cvars this value goes to. Empty for everything else.
@property(nonatomic, copy) NSArray<NSString*>* cvars;
// xe_ios_set_cvar takes TOML, so a string cvar has to arrive in quotes.
@property(nonatomic, assign) BOOL cvarIsString;
// Where in xemu-ios.toml this goes: [configTable] configKey = value.
@property(nonatomic, copy) NSString* configTable;
@property(nonatomic, copy) NSString* configKey;
@property(nonatomic, assign) BOOL configIsString;
// The heading it sits under in per-game settings. Nil: global only.
@property(nonatomic, copy) NSString* perGameGroup;
@end

@interface XenraSettingSection : NSObject
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy) NSArray<XenraSettingRow*>* rows;
@end

@interface XenraSettingTab : NSObject
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy) NSArray<XenraSettingSection*>* sections;
@end

@interface XenraSettings : NSObject
// The panes of the console in use.
+ (NSArray<XenraSettingTab*>*)tabs;
+ (NSArray<XenraSettingTab*>*)tabsForConsole:(XenraConsole)console;
// Per-game rows of the console in use, under their headings.
+ (NSArray<XenraSettingSection*>*)perGameSections;

+ (XenraConsole)console;
+ (void)setConsole:(XenraConsole)console;

// A nil game asks for the global value; a game with no override of its own
// falls back to it.
+ (NSString*)valueForRow:(XenraSettingRow*)row game:(NSString*)game;
+ (void)setValue:(NSString*)value row:(XenraSettingRow*)row game:(NSString*)game;
// What this game sets for itself, or nil when the row is on Use Global.
+ (NSString*)overrideForRow:(XenraSettingRow*)row game:(NSString*)game;
+ (void)clearOverrideForRow:(XenraSettingRow*)row game:(NSString*)game;
+ (void)clearOverridesForGame:(NSString*)game;
// What a row's value reads as on screen.
+ (NSString*)titleForValue:(NSString*)value row:(XenraSettingRow*)row;
+ (NSString*)stringForKey:(NSString*)key fallback:(NSString*)fallback;
+ (void)setString:(NSString*)value forKey:(NSString*)key;

// The per-game value of a row, or the global one, by its key.
+ (NSString*)valueForKey:(NSString*)key
                    game:(NSString*)game
                fallback:(NSString*)fallback;

// Sets XenraThemeMode from the console and whether setup has finished.
+ (void)applyTheme;
+ (BOOL)setupComplete;
+ (void)setSetupComplete:(BOOL)complete;

// Files and folders picked in setup, kept across launches.
+ (void)storeBookmark:(NSURL*)url key:(NSString*)key;
+ (void)clearBookmark:(NSString*)key;
+ (NSURL*)urlForBookmark:(NSString*)key;
// Opens every picked file and folder for the life of the process, which a boot
// and a scan both need.
+ (void)holdPickedFiles;
+ (NSArray<NSString*>*)gameFolders;

// Pushes every cvar row into the core. Call right before boot.
+ (void)applyForGame:(NSString*)game;

// The lines of one table of xemu-ios.toml, each ending in a newline.
+ (NSString*)xemuConfigForTable:(NSString*)table game:(NSString*)game;
// The XEMU_IOS_* launch values that come from settings, over DukeX's defaults:
// present mode and rate, display sync, nominal rate, aspect, filter. A pacing mode
// is DukeX's four values as a set, because not every mix of them is sound.
+ (NSDictionary<NSString*, NSString*>*)xemuEnvironmentForGame:(NSString*)game;
@end
