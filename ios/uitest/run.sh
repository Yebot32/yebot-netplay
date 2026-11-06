#!/bin/bash
# Builds the shell for the simulator with the cores stubbed out, walks it through
# every screen, and leaves a screenshot of each in $1. Run from the repo root.
set -uo pipefail
OUT="$1"
mkdir -p "$OUT"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
TARGET=arm64-apple-ios16.0-simulator
APP="$PWD/build-ui/Xenra.app"
rm -rf build-ui; mkdir -p "$APP/Frameworks" build-ui/obj

FLAGS="-target $TARGET -isysroot $SDK -std=c++20 -DXENRA_UITEST -Iios/src -Iios/uitest/stub -w"
cc() {  # source, extra flags
  clang++ -x objective-c++ $FLAGS $2 -c "$1" -o "build-ui/obj/$(basename "$1").o" || exit 1
}
for f in Ambient AppDelegate BladeView ContentInstall Covers DashboardController \
         GameController GameScanner JitProbe Sampler LibraryController Logs Motion Settings SettingsController \
         SetupController TouchPad UI Xemu; do
  cc "ios/src/Xenra$f.mm" -fobjc-arc &
done
cc ios/uitest/XenraTour.mm -fobjc-arc &
cc ios/src/XenraMetalView.mm -fno-objc-arc &
cc ios/src/main.mm -fno-objc-arc &
wait
ls build-ui/obj | wc -l

clang++ -target $TARGET -isysroot $SDK build-ui/obj/*.o -o "$APP/Xenra" \
  -framework UIKit -framework Foundation -framework QuartzCore \
  -framework GameController -framework AVFoundation -framework AudioToolbox \
  -framework UniformTypeIdentifiers -framework Metal -framework CoreGraphics \
  -framework ImageIO || exit 1

sed -e 's/${MACOSX_BUNDLE_SHORT_VERSION_STRING}/0.4.5/; s/${MACOSX_BUNDLE_BUNDLE_VERSION}/33/' \
    -e 's/${MACOSX_BUNDLE_EXECUTABLE_NAME}/Xenra/; s/${MACOSX_BUNDLE_GUI_IDENTIFIER}/Ali.Xanite.ui/' \
    -e 's/${MACOSX_BUNDLE_BUNDLE_NAME}/Xenra/; s/${EXECUTABLE_NAME}/Xenra/' \
    -e 's/$(EXECUTABLE_NAME)/Xenra/; s/$(PRODUCT_BUNDLE_IDENTIFIER)/Ali.Xanite.ui/' \
    ios/Info.plist > "$APP/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable Xenra' "$APP/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier Ali.Xanite.ui' "$APP/Info.plist"
cp ios/res/*.png ios/res/X1_Covers.txt "$APP/"
xcrun actool ios/res/Launch.xcassets --compile "$APP" --platform iphonesimulator \
  --minimum-deployment-target 16.0 --target-device iphone --target-device ipad \
  --output-format human-readable-text --notices --warnings --errors \
  --output-partial-info-plist build-ui/launch-assets.plist 2>&1 | tail -5
ls -la "$APP/Assets.car"
touch "$APP/Frameworks/libxemu-ios-core.dylib"
codesign --force --sign - "$APP"

DEVICE=$(xcrun simctl list devices available | grep -E 'iPad Air' | grep -v unavailable | tail -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
[ -n "$DEVICE" ] || DEVICE=$(xcrun simctl list devices available | grep -E 'iPad' | tail -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
echo "device $DEVICE"
xcrun simctl boot "$DEVICE"; xcrun simctl bootstatus "$DEVICE" -b
xcrun simctl install "$DEVICE" "$APP" || exit 1
xcrun simctl io "$DEVICE" recordVideo --codec=h264 "$OUT/tour.mp4" &
VIDEO=$!
xcrun simctl launch "$DEVICE" Ali.Xanite.ui
# The launch screen itself, which only the system can photograph. A simulator is
# in light mode, the case that used to come up white.
for i in 1 2 3 4; do
  xcrun simctl io "$DEVICE" screenshot "$OUT/000-launch-$i.png" >/dev/null 2>&1
done
sleep 3
DATA=$(xcrun simctl get_app_container "$DEVICE" Ali.Xanite.ui data)
TOUR="$DATA/Documents/tour"
# The app photographs itself; see XenraTour.mm for why.
for i in $(seq 1 1500); do
  [ -e "$TOUR/done" ] && break
  sleep 1
done
kill -INT $VIDEO; wait $VIDEO
cp "$TOUR"/*.png "$OUT/" 2>/dev/null
cp "$DATA/Documents/xenra-jit-log.txt" "$OUT/app-log.txt" 2>/dev/null
cp -R "$DATA/Documents/logs" "$OUT/logs" 2>/dev/null
xcrun simctl spawn "$DEVICE" log show --last 3m --predicate 'process == "Xenra"' --style compact 2>/dev/null | tail -200 > "$OUT/system-log.txt"
ls ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -i xenra | head
cp ~/Library/Logs/DiagnosticReports/Xenra* "$OUT/" 2>/dev/null
grep -c "tour: shot" "$OUT/app-log.txt" | sed 's/^/screens: /'
grep "NO SUCH CONTROL" "$OUT/app-log.txt" | head -20
grep "tour: press\|tour: early" "$OUT/app-log.txt" | sort | uniq -c
[ -e "$TOUR/done" ]
