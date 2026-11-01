#!/bin/zsh
# Drives the signed bundle over GPP the way Gaea does, with every .build folder hidden, so MLX can
# only find its metallib inside the bundle:
#
#   1. gaea-plugin-check (GaeaPluginKit's tiny host): static signature check against the team's
#      Developer ID requirement, launch with Process.launchRequirement, hello against the manifest,
#      configure → prepare LTX 2.5 max128 → video.generate (256×256, 9 frames, a prompt) →
#      memory.query →
#      shutdown, against the weights already in MLXEngine's store (CHECK_MODELS_ROOT);
#   2. tools/validate.py --transcript on the session it wrote;
#   3. a control: the same worker binary outside its bundle must NOT find a metallib.
#
#   scripts/check-plugin.sh            (after scripts/build-plugin.sh)
#
# On a machine with no Metal device (some CI runners) only the signature, the launch and hello are
# checked, and the script says so; the GPU half must then be run on a Mac (CHECK_GPU=required forces it).
set -euo pipefail
ROOT=${0:A:h:h}
cd $ROOT
NAME=${PLUGIN_BUNDLE_NAME:-ltx}
SPEC=${GAEA_SPEC_ROOT:-$ROOT/../gaea-mes-media-server}
B=$ROOT/dist/$NAME.gaeaplugin
PARAMS=${CHECK_PARAMS:-'{"size":{"width":256,"height":256},"duration_s":0.375}'}
# The weights: no download in a check. DEV_VOL1's models folder holds LTX 2.5's components and granules on this Mac.
MODELS=${CHECK_MODELS_ROOT:-/Volumes/DEV_VOL1/Models/Models}
step() { print -P "%B==> $*%b" }

step "build gaea-plugin-check"
xcrun swift build -c release --product gaea-plugin-check
TOOLS=$(mktemp -d)
cp "$(xcrun swift build -c release --show-bin-path)/gaea-plugin-check" $TOOLS/
EXE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["executable"])' $B/Contents/Resources/manifest.json)
# The control's copy: outside the bundle its Developer ID seal no longer holds (the kernel kills it
# at exec), so it is re-signed ad hoc. What's left to differ is only where the metallib can come from.
mkdir -p $TOOLS/bare && cp $B/Contents/MacOS/$EXE $TOOLS/bare/ && codesign -f -s - $TOOLS/bare/$EXE

# Hide every build folder the worker could fall back to. Restored on exit, whatever happens.
hidden=()
for dir in $ROOT/.build ${GAEA_PLUGIN_KIT_PATH:+${GAEA_PLUGIN_KIT_PATH:A}/.build}; do
  [[ -d $dir ]] || continue
  mv $dir $dir.hidden-$$ && hidden+=($dir)
done
restore() { for dir in $hidden; do [[ -d $dir.hidden-$$ ]] && mv $dir.hidden-$$ $dir; done }
trap restore EXIT INT TERM
step "hidden: ${hidden:-none}"

gpu=yes
system_profiler SPDisplaysDataType 2>/dev/null | grep -q "Metal Support" || gpu=no
if [[ $gpu == no ]]; then
  [[ ${CHECK_GPU:-auto} == required ]] && { print -u2 "no Metal device, and CHECK_GPU=required"; exit 1 }
  step "no Metal device here: checking signature, launch and hello only (run scripts/check-plugin.sh on a Mac for the GPU half)"
  $TOOLS/gaea-plugin-check $B --no-run --models-root "$MODELS" --session $ROOT/dist/check-session.gpp | tee $ROOT/dist/check.log
  python3 $SPEC/tools/validate.py --transcript $ROOT/dist/check-session.gpp
  step "check passed WITHOUT the GPU job"
  exit 0
fi

step "drive $NAME.gaeaplugin over GPP"
$TOOLS/gaea-plugin-check $B --operation video.generate --model ltx-2.5-max128 --lane bf16 --params $PARAMS --seed 7 \
  --text "prompt=A red kite flies over a green hill on a sunny day." \
  --models-root "$MODELS" --budget ${CHECK_BUDGET:-100000000000} --timeout 1800 --session $ROOT/dist/check-session.gpp | tee $ROOT/dist/check.log
grep -q '"media_type":"video/mp4"' $ROOT/dist/check.log || { print -u2 "the job returned no MP4"; exit 1 }

step "validate the session (tools/validate.py --transcript)"
python3 $SPEC/tools/validate.py --transcript $ROOT/dist/check-session.gpp

step "control: the bare worker, outside its bundle, must not find a metallib"
cache=$TOOLS/cache; mkdir -p $cache
# Preparing the model is its first GPU work; without the bundle's metallib it must fail there.
( print '{"type":"configure","id":"h1","budget":{"ceilingBytes":100000000000,"wiresWeights":false},"models_root":"'$MODELS'","cache_root":"'$cache'","settings":{}}'
  print '{"type":"prepare","id":"h2","model":"ltx-2.5-max128","lane":"bf16"}'
  sleep 60 ) | (cd $TOOLS/bare && ./$EXE > $TOOLS/control.out 2> $TOOLS/control.err) || true
grep -q '"type":"hello"' $TOOLS/control.out || { print -u2 "control: the bare worker never started"; exit 1 }
if grep -q '"type":"prepared"' $TOOLS/control.out; then
  print -u2 "control FAILED: the bare worker ran a kernel, so a metallib outside the bundle is reachable"; exit 1
fi
grep -q 'Failed to load the default metallib' $TOOLS/control.err || { print -u2 "control: failed for another reason:"; cat $TOOLS/control.err >&2; exit 1 }
print "control: the bare worker said hello, then: $(grep -o 'Failed to load the default metallib' $TOOLS/control.err | head -1)"
step "check passed"
