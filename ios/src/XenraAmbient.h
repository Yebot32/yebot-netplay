/**
 ******************************************************************************
 * Xenra : iOS shell - menu ambience                                          *
 ******************************************************************************
 *
 * Android's AmbientMusic.kt: nothing on disk, the pad is synthesised live.
 */

// Fades in, or changes palette, per the console and the music settings.
// The session the menus' sound shares: the music and the cursor's blip.
void XenraMenuAudioSession(void);
void XenraAmbientStart(void);
void XenraAmbientStop(void);
