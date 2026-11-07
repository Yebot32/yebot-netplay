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
