# iCall — iOS

SwiftUI SIP/VoIP dialer for iOS, built on **PJSIP 2.17** (pjsua2) via an
Objective-C++ bridge.

## License

This project is released under the **GNU General Public License v2** (see
[`LICENSE`](LICENSE)). It links PJSIP, which is dual-licensed GPLv2 / commercial;
this repository uses PJSIP under its **GPLv2** terms, so the application as a
whole is GPLv2. See [`NOTICE`](NOTICE) for third-party attributions.

## Configuration (required before building)

Server endpoints and API keys have been removed from this public source. Provide
your own values (search for `REPLACE_WITH_` and `example.com`):

- `iCall/Sip/IcallApi.swift` — balance/rates/OTP API keys + `mobileapi` host
- `iCall/Sip/GatewayClient.swift`, `iCall/Sip/SipEngine.swift` — push gateway host
- `iCall/Sip/PjsipBridge.mm` — default video/MOH SIP domains
- `project.yml` — `YOUR_APPLE_TEAM_ID`

## Build

```bash
# 1. Build the PJSIP xcframework (downloads PJSIP 2.17 + libvpx, ~15 min)
./build-vp9-h264-ios.sh

# 2. Generate the Xcode project and build
brew install xcodegen
xcodegen generate
open iCall.xcodeproj
```

Requires Xcode 15+, an Apple developer account for device builds.

## Video codecs

VP8 (default) and VP9 only. H.264/OpenH264 is deliberately excluded to keep the
build royalty-free.

## Distribution & licensing (GPLv2)

This application is licensed under **GPLv2** because it links GPLv2 PJSIP.

- **Google Play (Android):** GPLv2 apps are permitted on Google Play, so this
  app may be distributed there under GPLv2.
- **Apple App Store (iOS):** GPLv2 is generally regarded as **incompatible with
  the App Store Terms of Service** (which impose usage/copy restrictions that
  GPLv2 forbids — see the 2011 removal of VLC). Shipping a GPLv2 build on the
  public App Store may therefore require a different license for the binary
  (e.g. a PJSIP commercial license) or legal review.

This is a licensing summary, not legal advice — the distributor should confirm
with counsel before any public release.
