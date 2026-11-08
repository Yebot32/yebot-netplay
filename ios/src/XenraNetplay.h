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
// The same profile's XUID as 16 uppercase hex digits, or nil.
NSString* XenraNetplayProfileXuid(NSString* content_root);
// Sign the first profile in, creating one with |gamertag| when there is none.
// Returns the XUID, or nil if the gamertag is invalid or creation failed.
NSString* XenraNetplayEnsureProfile(NSString* content_root, NSString* gamertag);
// Create another profile and sign it in. Returns its XUID, or nil.
NSString* XenraNetplayCreateProfile(NSString* content_root, NSString* gamertag);
// Rename the profile with |xuid|. Returns YES on success.
BOOL XenraNetplayRenameProfile(NSString* content_root, NSString* xuid,
                               NSString* gamertag);

// "en0 (192.168.1.20, NAT)", or nil when no usable adapter exists.
NSString* XenraNetplayAdapterSummary(void);
// UPnPStatus ordinal; 3 is ready. Blocks for up to timeout_ms.
int XenraNetplayUPnPDiscover(int timeout_ms);
NSString* XenraNetplayUPnPStatus(void);
NSString* XenraNetplayUPnPLanAddress(void);
NSString* XenraNetplayUPnPExternalAddress(void);
// Map then immediately unmap a UDP port, proving the gateway accepts us.
BOOL XenraNetplayUPnPTestMapping(int port);
