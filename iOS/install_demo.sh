#!/bin/zsh
#
# Build the CMIICollector demo and install it on the iPad.
#
# RUN THIS FROM YOUR OWN TERMINAL, not from an automation/SSH context. Signing
# needs the private key in your login keychain, and macOS asks permission with a
# GUI dialog the first time. Click "Always Allow" and every later build is
# unattended. (That prompt is the only reason this is not fully automated.)
#
# Requirements: iPad connected by USB and UNLOCKED.
#
set -e
cd "$(dirname "$0")"

DEVICE=C10E284A-C3F4-5369-82E9-2440B2543238        # "tina yan"
IDENTITY=2F32B6529E2C295E4D0EC144B74CA580F4A77FC1  # Apple Development: Zifei Zhong
PROFILE_UUID=f5d6e57d-f4da-4d4c-a52b-b2111eff2fc2
PROFILE="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/${PROFILE_UUID}.mobileprovision"
DD=/tmp/cmii_demo_build

echo "==> 1/4 build"
xcodebuild -project CMIICollector.xcodeproj -scheme CMIICollector \
  -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
  PRODUCT_BUNDLE_IDENTIFIER=zhongz.appTrackTest \
  DEVELOPMENT_TEAM=ZFS9QR7REV \
  CODE_SIGN_STYLE=Automatic \
  build > /tmp/cmii_demo_build.log 2>&1 || { tail -20 /tmp/cmii_demo_build.log; exit 1; }

APP="$DD/Build/Products/Debug-iphoneos/CMIICollector.app"
[ -d "$APP" ] || { echo "no app bundle produced"; exit 1; }

echo "==> 2/4 embed profile + entitlements"
cp "$PROFILE" "$APP/embedded.mobileprovision"
security cms -D -i "$PROFILE" > /tmp/cmii_prof.plist 2>/dev/null
/usr/bin/python3 - <<'PY'
import plistlib
d = plistlib.load(open('/tmp/cmii_prof.plist','rb'))
plistlib.dump(d['Entitlements'], open('/tmp/cmii_ent.plist','wb'))
PY

echo "==> 3/4 sign  (click 'Always Allow' if macOS asks for the signing key)"
# Nested code first, then the bundle.
for f in "$APP"/*.dylib(N) "$APP"/Frameworks/*(N); do
  codesign -f -s "$IDENTITY" --generate-entitlement-der "$f"
done
codesign -f -s "$IDENTITY" --entitlements /tmp/cmii_ent.plist --generate-entitlement-der "$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Identifier=|TeamIdentifier' || true

echo "==> 4/4 install to iPad (must be unlocked)"
xcrun devicectl device install app --device "$DEVICE" "$APP"

echo
echo "Done. Launch 'CMIICollector' on the iPad."
echo "Note: this demo build uses bundle id zhongz.appTrackTest, because that is the"
echo "provisioning profile already cached on this Mac. To ship it as com.cmii.collector,"
echo "open CMIICollector.xcodeproj in Xcode once, make sure your Apple ID is in"
echo "Xcode > Settings > Accounts, and press Run - Xcode will create the right profile."
