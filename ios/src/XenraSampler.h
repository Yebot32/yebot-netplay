/**
 ******************************************************************************
 * Xenra : iOS shell - where is every thread right now                        *
 ******************************************************************************
 *
 * For a hang, which leaves no crash report. Writes each thread's name, state,
 * program counter and a short stack to the app log. Safe from any thread except
 * that it must not be called from a signal handler.
 */

#import <Foundation/Foundation.h>

void XenraSamplerDump(NSString* reason);

// One line of the busiest threads and their CPU share, for telling a CPU-bound game
// from a GPU-bound one. Cheap: no thread is suspended.
void XenraSamplerLoad(void);

// A sampling profile of the emulated CPU's thread: its program counter about a
// thousand times a second for a few seconds, counted by function, generated code
// in one bucket. Says where a CPU-bound game spends its time.
void XenraSamplerProfile(double seconds);
