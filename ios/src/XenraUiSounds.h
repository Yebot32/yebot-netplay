/**
 ******************************************************************************
 * Xenra : iOS shell - menu feedback sounds                                   *
 ******************************************************************************
 *
 * Android's UiSounds.kt: one cue, synthesised, nothing on disk. It marks the
 * controller cursor moving and nothing else, because everything else a menu does
 * already shows on screen.
 */

#import <Foundation/Foundation.h>

// Plays the blip. The session is Ambient, so the mute switch silences it and it
// mixes under whatever is already playing.
void XenraUiSoundsMove(void);

// Hands the voices back. A game wants the audio hardware; the next move rebuilds
// them.
void XenraUiSoundsRelease(void);

#ifdef XENRA_UITEST
// How many blips were asked for, and what the rendered buffer came to.
int XenraUiSoundsTestCount(void);
NSString* XenraUiSoundsTestReport(void);
#endif
