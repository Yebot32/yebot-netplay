/**
 ******************************************************************************
 * Xenra : iOS shell - settings model                                         *
 ******************************************************************************
 *
 * What the settings screens show and where each value goes. Rows with a cvar
 * reach the 360 core before boot; a per-game value overrides the global one,
 * the way Android's <TITLE_ID>.config.toml overlay does. Titles are Android's
 * strings.xml wording.
 */

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, XenraConsole) {
  XenraConsole360 = 0,
  XenraConsoleOG = 1,
};

typedef NS_ENUM(NSInteger, XenraRowKind) {
  XenraRowToggle,
  XenraRowChoice,
  XenraRowAction,
  XenraRowInfo,
};

@interface XenraSettingRow : NSObject
@property(nonatomic, copy) NSString* key;
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy) NSString* detail;
@property(nonatomic, assign) XenraRowKind kind;
@property(nonatomic, copy) NSArray<NSString*>* choiceTitles;
@property(nonatomic, copy) NSArray<NSString*>* choiceValues;
@property(nonatomic, copy) NSString* defaultValue;
// Core settings, as TOML values. Empty for app-side ones.
@property(nonatomic, copy) NSArray<NSString*>* cvars;
@property(nonatomic, assign) BOOL perGame;
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
+ (NSArray<XenraSettingTab*>*)tabs;
+ (NSArray<XenraSettingRow*>*)perGameRows;

+ (XenraConsole)console;
+ (void)setConsole:(XenraConsole)console;

// A nil game asks for the global value; a game with no override of its own
// falls back to it.
+ (NSString*)valueForRow:(XenraSettingRow*)row game:(NSString*)game;
+ (void)setValue:(NSString*)value row:(XenraSettingRow*)row game:(NSString*)game;
+ (void)clearOverridesForGame:(NSString*)game;
+ (NSString*)stringForKey:(NSString*)key fallback:(NSString*)fallback;
+ (void)setString:(NSString*)value forKey:(NSString*)key;

// Sets XenraThemeMode from the console and whether setup has finished.
+ (void)applyTheme;
+ (BOOL)setupComplete;
+ (void)setSetupComplete:(BOOL)complete;

// Files and folders picked in setup, kept across launches.
+ (void)storeBookmark:(NSURL*)url key:(NSString*)key;
+ (NSURL*)urlForBookmark:(NSString*)key;
// Opens the picked 360 folder for the life of the process, which a boot and a
// scan both need.
+ (void)holdGameFolder;
+ (NSArray<NSString*>*)gameFolders;

// Pushes every cvar row into the core. Call right before boot.
+ (void)applyForGame:(NSString*)game;
@end
