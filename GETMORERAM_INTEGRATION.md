# GetMoreRAM ("Increased Memory Limit") — what Xenra can and cannot do

Written 2026-09-08 (iOS session 3) from the actual GetMoreRam source, not from
community lore. GetMoreRam: github.com/hugeBlack/GetMoreRam, a thin SwiftUI
wrapper around StosSign's Apple-API code (StosSign_API_NoCertificate /
StosSign_Auth).

## What GetMoreRam actually does (verified from its code)

`GetMoreRam/AppIDViewModel.swift`, `addIncreasedMemory()`:

1. You sign into the **same Apple ID that signs the target app** (StosSign
   session + anisette data, SideStore-style).
2. It lists that account's registered App IDs
   (`AppleAPI.shared.fetchAppIDsForTeam`).
3. For the app you pick it sends an authenticated PATCH to

   `https://developerservices2.apple.com/services/v1/bundleIds/{appID.identifier}`

   whose body enables the App-ID capability with the exact identifier

   **`INCREASED_MEMORY_LIMIT`**

   (`{"capability":{"data":{"id":"INCREASED_MEMORY_LIMIT",...}},"enabled":true}`).

That is the whole trick: it flips a switch on the **App ID record held by
Apple's developer services**, for the team that owns your (free or paid)
signing identity. It does not touch any app binary, Info.plist or entitlements
file.

## Why that only takes effect after re-signing + reinstalling

Capabilities live on the App ID; what an installed app actually gets is
whatever the **provisioning profile embedded at signing time** granted.
SideStore/AltStore regenerate the profile at each install, so only after the
app is re-signed (which happens on every 7-day free-account refresh anyway)
does the new profile carry the capability. That is why GetMoreRam's own README
ends with "Reinstall the app from SideStore/AltStore".

The corresponding entitlement that appears in the profile — and the only
string that ever means anything inside an installed app — is:

**`com.apple.developer.kernel.increased-memory-limit`** (= true)

Related, often wanted alongside it on 16 GB-class devices:
**`com.apple.developer.kernel.extended-virtual-addressing`** (= true).

Both are **restricted** entitlements: Apple's signing services only embed them
in a profile if the App ID has the capability, which is exactly the switch
GetMoreRam flips.

## What Xenra does on its own (already implemented)

`XenDroid/ios/xenra.entitlements` — the file the CI packages into the
ad-hoc signature, and which every re-signing tool (eSign, Sideloadly,
SideStore, AltStore) preserves through re-signing — already declares:

- `com.apple.developer.kernel.increased-memory-limit` = true
- `com.apple.developer.kernel.extended-virtual-addressing` = true

So Xenra is **already asking for the right thing**. The declaration travels
with every build. There is nothing further to add to the app's source: the
capability is not expressible in app source, period.

## The honest outcome (the part that cannot be built into Xenra)

| Scenario | Result |
| --- | --- |
| Xenra signed with a profile whose App ID has `INCREASED_MEMORY_LIMIT` enabled (Xcode, or GetMoreRam/StosSign + SideStore/AltStore) | Entitlement honored; jetsam limit raised toward the physical RAM ceiling |
| Xenra signed with a plain free-account profile (no capability on the App ID) | Entitlement present in the signature but **silently ignored**; app runs at the default per-device jetsam cap |
| Someone claims "built into the app, always on" | False for every signing path, by Apple's design — the capability is bound to the App ID + profile, not to app source |

Concretely, for the 360 core this matters: a title's 512 MB guest RAM + JIT
code cache + texture staging exceeds the default jetsam cap on most devices,
and exceeding it is an instant kill with no catchable signal. OG titles
(64 MB guest) fit under the default cap on M1-class hardware.

**What the user must do (once per Apple ID):** run GetMoreRam (or Xcode),
sign in with the Apple ID that signs Xenra, select Xenra's App ID, enable
"Increased Memory Limit", then reinstall Xenra through the same signing flow.
After that, every future install of Xenra signed by that identity carries it.

**How to verify it took effect (do not trust the install):** on-device,
Settings → the app is not authoritative; the reliable check is the
provisioning profile of the installed build
(`codesign -d --entitlements :-` on a Mac, or a profile dump tool) showing
`com.apple.developer.kernel.increased-memory-limit`, plus a runtime memory
ceiling measurement in Xenra's own diagnostics (candidate follow-up: report
the current jetsam limit on the status screen via `task_info`, so a silent
ignore is visible instead of guessed at).

## Decision

No code change ships from this investigation. Xenra's entitlements already
declare the correct keys (verified against GetMoreRam's `INCREASED_MEMORY_LIMIT`
capability id — the entitlement spelled `com.apple.developer.kernel.
increased-memory-limit` is the standard projection of that capability).
GETMORERAM_INTEGRATION.md (this file) is the deliverable, and the status
screen already shows the data a user needs to debug the "did it take effect"
question via their own tools.
