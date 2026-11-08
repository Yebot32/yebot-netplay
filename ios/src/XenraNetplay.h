/**
 ******************************************************************************
 * Xenra : iOS shell - Xbox 360 System Link / profile bridge                  *
 ******************************************************************************
 *
 * The 360 core already owns the System Link transport, XNet/QoS, XSession and
 * UPnP. This is the small app-side bridge: create/sign in a standalone 360
 * profile, report the selected network adapter, and drive the UPnP diagnostic.
 * No protocol code lives here.
 */

#import <Foundation/Foundation.h>

// The first standalone profile's gamertag, or nil when there is none.
NSString* XenraNetplayProfileSummary(NSString* content_root);
// Sign the first profile in, creating one with |gamertag| when there is none.
// Returns the XUID, or nil if the gamertag is invalid or creation failed.
NSString* XenraNetplayEnsureProfile(NSString* content_root, NSString* gamertag);
// The core's own 1-15 character, starts-with-a-letter rule.
BOOL XenraNetplayGamertagValid(NSString* gamertag);

// "en0 (192.168.1.20, NAT)", or nil when no usable adapter exists.
NSString* XenraNetplayAdapterSummary(void);
// UPnPStatus ordinal; 3 is ready. Blocks for up to timeout_ms.
int XenraNetplayUPnPDiscover(int timeout_ms);
NSString* XenraNetplayUPnPStatus(void);
NSString* XenraNetplayUPnPLanAddress(void);
NSString* XenraNetplayUPnPExternalAddress(void);
// Map then immediately unmap a UDP port, proving the gateway accepts us.
BOOL XenraNetplayUPnPTestMapping(int port);

// Reaches the community session broker over HTTPS and reports the status. Any
// HTTP status counts as reachable - the server answering is what is tested, not
// which routes it exposes today. The completion runs on the main queue.
void XenraNetplayCheckServer(void (^done)(BOOL reachable, NSInteger status));
