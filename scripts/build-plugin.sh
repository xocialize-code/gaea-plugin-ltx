#!/bin/zsh
# Builds the worker, writes and validates manifest.json, assembles the .gaeaplugin bundle, signs it
# (Developer ID, hardened runtime, secure timestamp), verifies the signature, and zips it.
#
#   scripts/build-plugin.sh
#
# Environment:
#   GAEA_SPEC_ROOT     checkout of xocialize-code/gaea, for tools/validate.py (default: ../gaea-mes-media-server)
#   SIGN_IDENTITY      default "Developer ID Application: Dustin Nielson (CFZS6RXUCP)"
#   SIGN_KEYCHAIN      a keychain to sign from (CI's temporary keychain); default: the search list
#   GAEA_PLUGIN_KIT_PATH  build against a local GaeaPluginKit checkout
#
# Output in dist/: <name>.gaeaplugin, <name>-<version>.gaeaplugin.zip, its .sha256, and manifest.json.
#
# Bundle layout (GPP-1 §4):
#   <name>.gaeaplugin/Contents/Info.plist                         CFBundleIdentifier = manifest id
#   <name>.gaeaplugin/Contents/MacOS/<executable>                 the worker, MLX linked statically
#   <name>.gaeaplugin/Contents/Resources/manifest.json            sealed by the signature
#   <name>.gaeaplugin/Contents/Resources/mlx-swift_Cmlx.bundle    default.metallib; MLX finds it through
#                                                                 the worker's main bundle
#   <name>.gaeaplugin/Contents/Resources/<other>.bundle           every other SwiftPM resource bundle (Bundle.module)
set -euo pipefail
ROOT=${0:A:h:h}
cd $ROOT
PRODUCT=gaea-ltx-worker
NAME=${PLUGIN_BUNDLE_NAME:-ltx}
SPEC=${GAEA_SPEC_ROOT:-$ROOT/../gaea-mes-media-server}
IDENTITY=${SIGN_IDENTITY:-"Developer ID Application: Dustin Nielson (CFZS6RXUCP)"}
# The one team Gaea v1 trusts (G-22, AB-D-0184); not configurable.
TEAM=CFZS6RXUCP
DIST=$ROOT/dist
REQUIREMENT="anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"$TEAM\""

step() { print -P "%B==> $*%b" }

# The worker builds in a scratch folder of its own, so its bin folder holds only the resource bundles it links, not
# the in-process reference's or the check tool's.
SCRATCH=$ROOT/.build/plugin
# Swift Build, named explicitly: it compiles mlx-swift's .metal kernels into default.metallib. It is the default from
# Swift 6.4 (Xcode 27); Xcode 26's SwiftPM defaults to the native build system, which skips them silently (AB-T-0382).
SWIFTPM=(-c release --arch arm64 --scratch-path $SCRATCH --build-system swiftbuild)
step "build $PRODUCT (release, arm64, swiftbuild)"
xcrun swift build $SWIFTPM --product $PRODUCT
BIN=$(xcrun swift build $SWIFTPM --show-bin-path)

rm -rf $DIST && mkdir -p $DIST
step "generate manifest.json from the plugin's code"
$BIN/$PRODUCT --manifest $DIST/manifest.json

step "validate manifest.json (tools/validate.py --manifest)"
[[ -f $SPEC/tools/validate.py ]] || { print -u2 "no validator at $SPEC/tools/validate.py; set GAEA_SPEC_ROOT"; exit 1 }
python3 $SPEC/tools/validate.py --manifest $DIST/manifest.json

field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' $DIST/manifest.json $1 }
ID=$(field id); VERSION=$(field version); EXE=$(field executable)
[[ $EXE == $PRODUCT ]] || { print -u2 "manifest executable $EXE is not the product $PRODUCT"; exit 1 }

step "assemble $NAME.gaeaplugin ($ID $VERSION)"
B=$DIST/$NAME.gaeaplugin
mkdir -p $B/Contents/MacOS $B/Contents/Resources
cp $BIN/$PRODUCT $B/Contents/MacOS/$EXE
[[ -f $BIN/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib ]] || { print -u2 "no metallib in $BIN/mlx-swift_Cmlx.bundle"; exit 1 }
# Every SwiftPM resource bundle, not only MLX's: Bundle.module looks in the main bundle's Resources, and with the
# build folder gone a missing one is a crash, not an error (AB-L-0318).
for bundle in $BIN/*.bundle(N); do ditto $bundle $B/Contents/Resources/${bundle:t}; done
cp $DIST/manifest.json $B/Contents/Resources/manifest.json
cat > $B/Contents/Info.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$ID</string>
  <key>CFBundleExecutable</key><string>$EXE</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
</dict></plist>
EOF

step "sign: $IDENTITY, hardened runtime, timestamp"
keychain=(); [[ -n ${SIGN_KEYCHAIN:-} ]] && keychain=(--keychain $SIGN_KEYCHAIN)
codesign --force --sign $IDENTITY $keychain --options runtime --timestamp --identifier $ID $B

step "verify: codesign --verify --strict --deep, and the Developer ID requirement for team $TEAM"
codesign --verify --strict --deep --verbose=2 $B
codesign --verify --strict --deep --verbose=1 -R "=$REQUIREMENT" $B
codesign -dv --verbose=2 $B 2>&1 | grep -E "^(Identifier|Authority=Developer ID Application|TeamIdentifier|Timestamp|Runtime Version|CodeDirectory)"

step "zip"
ZIP=$DIST/$NAME-$VERSION.gaeaplugin.zip
ditto -c -k --keepParent $B $ZIP
(cd $DIST && shasum -a 256 ${ZIP:t} > ${ZIP:t}.sha256)
cat $DIST/${ZIP:t}.sha256
print "$ZIP"
