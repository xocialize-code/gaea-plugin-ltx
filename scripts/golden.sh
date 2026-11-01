#!/bin/zsh
# The plugin against in-process MLXServeEngine: jobs run on the signed bundle the way Gaea runs them (gaea-plugin-check:
# launch under the launch requirement, configure, prepare, run) and through ltx-inproc with the tier's lane
# configuration and the request the worker builds (LTXPlugin's `call`), at the same seed. Each pair must decode to the
# same frames, byte for byte (ffmpeg's framemd5), at the size and frame count the plan reported, in H.264 with a 48 kHz
# stereo AAC track. max128 (bf16) must; the int8 tiers declare deterministic: false and pass within 25 dB on every frame
# when not identical. Gaea retimes and marks the output, and puts an edit's kept frames back (GaeaVideo), so none of
# that is checked here.
#
#   scripts/golden.sh <out-dir>     (after scripts/build-plugin.sh)
#
# Cases (seed 7, "A red kite flies over a green hill on a sunny day."):
#   generate 256×256, 9 frames on each tier; a first frame on compact24; a last frame on standard64 (two stages);
#   extend by 1/3 s and retake 0.4–0.7 s of Tests/Fixtures/clip.mp4 (128×96, 17 frames, with sound) on compact24.
# The weights are in CHECK_MODELS_ROOT (DEV_VOL1's models folder by default). GOLDEN_ONLY="<name> …" runs only those
# cases. Needs ffprobe.
set -uo pipefail
ROOT=${0:A:h:h}
cd $ROOT
OUT=${1:?out dir}; mkdir -p $OUT
B=$ROOT/dist/ltx.gaeaplugin
F=$ROOT/Tests/Fixtures
MODELS=${CHECK_MODELS_ROOT:-/Volumes/DEV_VOL1/Models/Models}
PROMPT="A red kite flies over a green hill on a sunny day."
SWIFTPM=(-c release --build-system swiftbuild)
xcrun swift build $SWIFTPM --product ltx-inproc > /dev/null && xcrun swift build -c release --product gaea-plugin-check > /dev/null
INPROC=$(xcrun swift build $SWIFTPM --show-bin-path)/ltx-inproc; CHECK=$(xcrun swift build -c release --show-bin-path)/gaea-plugin-check
LOG=$OUT/golden.log; : > $LOG
pass=0; fail=0
say() { print -r -- "$*" | tee -a $LOG }
say "# LTX golden check $(date -u +%FT%TZ): $(python3 -c "import json; m=json.load(open('$B/Contents/Resources/manifest.json')); print(m['id'], m['version'])")"
probe() { ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=codec_name,width,height,nb_read_frames -of csv=p=0 $1 }
sound() { ffprobe -v error -select_streams a:0 -show_entries stream=codec_name,sample_rate,channels -of csv=p=0 $1 }
frames() { ffmpeg -v error -i $1 -map 0:v -f framemd5 - | grep -v '^#' | awk -F', *' '{print $NF}' | shasum -a 256 | cut -c1-16 }
# The lowest per-frame PSNR between two clips (identical frames count as 99).
psnr() { ffmpeg -v error -i $1 -i $2 -lavfi '[0:v][1:v]psnr=stats_file=-' -f null - 2>&1 | awk '{split($6, v, ":"); x = (v[2] == "inf") ? 99 : v[2]; if (min == "" || x < min) min = x} END {printf "%d", min}' }
outputs() { grep -o '"path":"[^"]*"' $1 | sed 's/"path":"//; s/"$//; s/\\\//\//g' | awk '!seen[$0]++' }

# case <name> <tier> <operation> <params> <want "w,h,frames"> [<input name>=<path> ...]
case_() {
  local name=$1 tier=$2 op=$3 params=$4 want=$5; shift 5
  [[ -n ${GOLDEN_ONLY:-} && " $GOLDEN_ONLY " != *" $name "* ]] && return
  local lane=int8; [[ $tier == max128 ]] && lane=bf16
  local gin=() iin=()
  for i in "$@"; do gin+=(--input $i); iin+=(--input $i); done
  $CHECK $B --operation $op --model ltx-2.5-$tier --lane $lane --params $params --seed 7 --text "prompt=$PROMPT" $gin \
    --models-root "$MODELS" --budget 100000000000 --timeout 3600 --session $OUT/$name.gpp > $OUT/$name-gpp.log 2>&1
  local file=$(outputs $OUT/$name-gpp.log | head -1); [[ -f $file ]] && cp $file $OUT/$name-gpp.mp4
  $INPROC --tier $tier --operation $op --prompt $PROMPT --params $params --seed 7 $iin --models-root "$MODELS" \
    --out $OUT/$name-inproc.mp4 2>> $LOG | tail -1 > $OUT/$name-inproc.json
  say "      $name: over GPP $(grep -o 'ran in [0-9.]* s' $OUT/$name-gpp.log | head -1); in-process $(cat $OUT/$name-inproc.json)"
  local a=$(frames $OUT/$name-gpp.mp4 2>/dev/null) b=$(frames $OUT/$name-inproc.mp4 2>/dev/null)
  local got="$(probe $OUT/$name-gpp.mp4 2>/dev/null) $(sound $OUT/$name-gpp.mp4 2>/dev/null)"
  local low=$(psnr $OUT/$name-gpp.mp4 $OUT/$name-inproc.mp4)
  if [[ -n $a && $a == $b && $got == "h264,$want aac,48000,2" ]]; then pass=$((pass+1)); say "PASS  $name: the same decoded frames, $got, framemd5 sha256 $a…"
  elif [[ $tier != max128 && -n $a && $got == "h264,$want aac,48000,2" ]] && (( low >= 25 )); then
    pass=$((pass+1)); say "PASS  $name: within $low dB on every frame (int8, deterministic: false), $got"
  else fail=$((fail+1)); say "FAIL  $name: $a… / $b…, lowest $low dB, $got (want h264,$want aac,48000,2)"; fi
}

G='{"size":{"width":256,"height":256},"duration_s":0.375}'
case_ compact24 compact24 video.generate $G 256,256,9
case_ balanced32 balanced32 video.generate $G 256,256,9
case_ standard64 standard64 video.generate $G 256,256,9
case_ max128 max128 video.generate $G 256,256,9
case_ compact24-first compact24 video.generate $G 256,256,9 first_frame=$F/kite-first.png
case_ standard64-last standard64 video.generate '{"size":{"width":256,"height":256},"duration_s":0.7083}' 256,256,17 \
  first_frame=$F/kite-first.png last_frame=$F/kite-last.png
case_ compact24-extend compact24 video.extend '{"after_s":0.3333}' 128,96,25 video=$F/clip.mp4
case_ compact24-retake compact24 video.retake '{"start_s":0.4,"end_s":0.7}' 128,96,17 video=$F/clip.mp4

for s in $OUT/${GOLDEN_ONLY:+NONE}*.gpp; do
  if python3 ${GAEA_SPEC_ROOT:-$ROOT/../gaea-mes-media-server}/tools/validate.py --transcript $s >> $LOG 2>&1; then pass=$((pass+1)); say "PASS  ${s:t} passes validate.py"
  else fail=$((fail+1)); say "FAIL  ${s:t} fails validate.py"; fi
done
say "== $pass passed, $fail failed"
exit $(( fail > 0 ))
