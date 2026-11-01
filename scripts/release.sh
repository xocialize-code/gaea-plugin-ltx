#!/bin/zsh
# Builds, signs, checks, notarizes and publishes a GitHub Release of the plugin:
#   <name>-<version>.gaeaplugin.zip, its .sha256, and manifest.json, tagged v<version>.
#
#   scripts/release.sh
#
# Environment (beyond scripts/build-plugin.sh's):
#   NOTARIZE        yes | no | auto (default). auto notarizes when the notary profile exists, and
#                   otherwise publishes a pre-release marked "signed, not notarized".
#   NOTARY_PROFILE  the notarytool keychain profile (default mlx-notary, the fleet's; see README "Notarization").
#   NOTARY_KEYCHAIN the keychain holding that profile (CI's temporary keychain); default: login.
#   PUBLISH         yes (default) | no: build and notarize only.
#   GH_TOKEN        for gh in CI.
set -euo pipefail
ROOT=${0:A:h:h}
cd $ROOT
NAME=${PLUGIN_BUNDLE_NAME:-ltx}
NOTARIZE=${NOTARIZE:-auto}
PROFILE=${NOTARY_PROFILE:-mlx-notary}
step() { print -P "%B==> $*%b" }

$ROOT/scripts/build-plugin.sh
DIST=$ROOT/dist
VERSION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' $DIST/manifest.json)
TAG=v$VERSION
B=$DIST/$NAME.gaeaplugin
ZIP=$DIST/$NAME-$VERSION.gaeaplugin.zip

if [[ -n ${GITHUB_REF_NAME:-} && ${GITHUB_REF_TYPE:-} == tag && $GITHUB_REF_NAME != $TAG ]]; then
  print -u2 "tag $GITHUB_REF_NAME doesn't match the manifest version $VERSION"; exit 1
fi

$ROOT/scripts/check-plugin.sh

notary=(--keychain-profile $PROFILE); [[ -n ${NOTARY_KEYCHAIN:-} ]] && notary+=(--keychain $NOTARY_KEYCHAIN)
if [[ $NOTARIZE == auto ]]; then
  if xcrun notarytool history $notary >/dev/null 2>&1; then NOTARIZE=yes; else NOTARIZE=no
    print "no notary profile \"$PROFILE\": publishing signed, not notarized (README, Notarization)"
  fi
fi

notarized=no
if [[ $NOTARIZE == yes ]]; then
  step "notarize ${ZIP:t}"
  xcrun notarytool submit $ZIP $notary --wait --output-format json | tee $DIST/notary.json
  notary_status=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' $DIST/notary.json)
  id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' $DIST/notary.json)
  [[ -n $id ]] && xcrun notarytool log $id $notary $DIST/notary-log.json || true
  [[ $notary_status == Accepted ]] || { print -u2 "notarization: $notary_status (see dist/notary-log.json)"; exit 1 }

  # A zip can't carry a ticket; the bundle inside can. stapler only takes some bundle types: where it
  # refuses, Gatekeeper fetches the ticket online instead.
  step "staple the bundle, where stapler takes it"
  if xcrun stapler staple $B; then
    xcrun stapler validate $B
    rm -f $ZIP && ditto -c -k --keepParent $B $ZIP
    (cd $DIST && shasum -a 256 ${ZIP:t} > ${ZIP:t}.sha256)
  else
    print "stapler: not applicable to this bundle; the ticket is served online"
  fi
  step "Gatekeeper: spctl --assess --type open --context context:primary-signature"
  spctl --assess --type open --context context:primary-signature -vv $B
  notarized=yes
fi

[[ ${PUBLISH:-yes} == yes ]] || { print "PUBLISH=no: done"; exit 0 }

step "GitHub Release $TAG"
assets=($ZIP $ZIP.sha256 $DIST/manifest.json)
sha=$(cut -d' ' -f1 $ZIP.sha256)
if [[ $notarized == yes ]]; then
  state="Signed with Developer ID (hardened runtime, secure timestamp) and notarized."
  pre=()
else
  state="Signed with Developer ID (hardened runtime, secure timestamp). **Not notarized yet**: Gaea's own install path doesn't need it (it verifies the signature and launches with a launch requirement), but a zip side-loaded through a browser will be stopped by Gatekeeper."
  pre=(--prerelease)
fi
notes="$state

- \`${ZIP:t}\` sha256 \`$sha\`
- \`manifest.json\`: the bundle's sealed manifest (GPP v1)

Checked before publishing: \`codesign --verify --strict --deep\`, the Developer ID requirement for team CFZS6RXUCP (the only team Gaea v1 trusts), and an MLX job on the GPU driven over GPP under \`Process.launchRequirement\` with every build folder hidden (\`scripts/check-plugin.sh\`)."
if gh release view $TAG >/dev/null 2>&1; then
  gh release upload $TAG $assets --clobber
  gh release edit $TAG --notes $notes ${pre:---prerelease=false}
else
  gh release create $TAG $assets --title "$NAME $VERSION" --notes $notes $pre
fi
gh release view $TAG --json url,isPrerelease,assets -q '.url, (.assets[] | .name)'
