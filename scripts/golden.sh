#!/bin/zsh
# The plugin against in-process MLXServeEngine: seeded jobs called on the signed bundle the way Gaea calls them
# (gaea-plugin-check: launch under the launch requirement, configure, prepare, run) and through auk-inproc with the
# lane configuration, requests and seeding the worker uses. Each pair must be byte for byte the same WAVs.
#
#   scripts/golden.sh <out-dir>     (after scripts/build-plugin.sh)
#
# Cases on AuK-Flash int8 unless named:
# - speak: a clone with its transcript, a 4 s fit around a pause, a clone with an estimated length, and the int4 lane;
# - design: two samples;
# - edit: replace_text with its transcript, emotion, a hum at the start, speed (snapped), dereverb;
# - separate: the second speaker of scripts/fixtures/mix-two.wav by order, and by the words they say;
# - AuK Base: a clone, and every voice.
set -uo pipefail
ROOT=${0:A:h:h}
cd $ROOT
OUT=${1:?out dir}; mkdir -p $OUT
B=$ROOT/dist/auk.gaeaplugin
REF=$ROOT/scripts/fixtures/ref-en.wav
MIX=$ROOT/scripts/fixtures/mix-two.wav
REFTEXT='The morning train was late again, so I walked along the river and watched the boats come in.'
MODELS=${CHECK_MODELS_ROOT:-/Volumes/DEV_VOL1/Models/Models}
SWIFTPM=(-c release --build-system swiftbuild)
xcrun swift build $SWIFTPM --product auk-inproc > /dev/null && xcrun swift build -c release --product gaea-plugin-check > /dev/null
INPROC=$(xcrun swift build $SWIFTPM --show-bin-path)/auk-inproc; CHECK=$(xcrun swift build -c release --show-bin-path)/gaea-plugin-check
LOG=$OUT/golden.log; : > $LOG
pass=0; fail=0
say() { print -r -- "$*" | tee -a $LOG }
say "# AuK golden check $(date -u +%FT%TZ): $(python3 -c "import json; m=json.load(open('$B/Contents/Resources/manifest.json')); print(m['id'], m['version'])")"
same() { # name, gpp file, inproc file
  local a=$(shasum -a 256 $2 2>/dev/null | cut -c1-16) b=$(shasum -a 256 $3 2>/dev/null | cut -c1-16)
  if [[ -n $a && $a == $b ]]; then pass=$((pass+1)); say "PASS  $1: byte-identical, sha256 $a…"
  else fail=$((fail+1)); say "FAIL  $1: differs ($a… / $b…)"; fi
}
outputs() { grep -o '"path":"[^"]*"' $1 | sed 's/"path":"//; s/"$//; s/\\\//\//g' }
gpp() { # name, model, lane, operation, seed, params json, args… → the job's file outputs as <name>-gpp-<basename>
  local name=$1 model=$2 lane=$3 op=$4 seed=$5 params=$6; shift 6
  $CHECK $B --operation $op --model $model --lane $lane --params $params --seed $seed "$@" \
    --models-root "$MODELS" --budget 64000000000 --timeout 900 --session $OUT/$name.gpp > $OUT/$name-gpp.log 2>&1
  for f in $(outputs $OUT/$name-gpp.log); do [[ -f $f ]] && cp $f $OUT/$name-gpp-${f:t}; done
  say "      $name: over GPP $(grep -o 'ran in [0-9.]* s' $OUT/$name-gpp.log | head -1)"
}
inproc() { local name=$1; shift; $INPROC "$@" --models-root "$MODELS" 2>> $LOG | tail -1 > $OUT/$name-inproc.json; say "      $name in-process: $(cat $OUT/$name-inproc.json)" }

EN='Gaea speaks. This sentence came from a signed plugin, over its own protocol.'
# speak
gpp clone auk-flash int8 audio.speak 42 '{}' --text "text=$EN" --input "voice_ref=$REF" --text "voice_ref_text=$REFTEXT"
inproc clone speak --ref $REF --ref-text "$REFTEXT" --text "$EN" --seed 42 --out $OUT/clone-inproc.wav
same clone $OUT/clone-gpp-audio-0.wav $OUT/clone-inproc.wav
gpp fitted auk-flash int8 audio.speak 7 '{"target_duration_s":4.0}' --text "text=This line has to fit the cue. [pause 0.5s] Exactly." --input "voice_ref=$REF"
inproc fitted speak --ref $REF --text 'This line has to fit the cue. [pause 0.5s] Exactly.' --target-duration 4.0 --seed 7 --out $OUT/fitted-inproc.wav
same fitted $OUT/fitted-gpp-audio-0.wav $OUT/fitted-inproc.wav
gpp estimated auk-flash int8 audio.speak 8 '{}' --text "text=$EN" --input "voice_ref=$REF"
inproc estimated speak --ref $REF --text "$EN" --seed 8 --out $OUT/estimated-inproc.wav
same estimated $OUT/estimated-gpp-audio-0.wav $OUT/estimated-inproc.wav
gpp int4 auk-flash int4 audio.speak 42 '{}' --text "text=$EN" --input "voice_ref=$REF" --text "voice_ref_text=$REFTEXT"
inproc int4 speak --lane int4 --ref $REF --ref-text "$REFTEXT" --text "$EN" --seed 42 --out $OUT/int4-inproc.wav
same "int4 lane" $OUT/int4-gpp-audio-0.wav $OUT/int4-inproc.wav

# design
DESC='A warm, low voice of a woman in her forties, unhurried, with a slight rasp.'
gpp design auk-flash int8 audio.design_voice 7 '{"count":2,"language":"en"}' --text "description=$DESC"
inproc design design --description "$DESC" --count 2 --language en --seed 7 --out-dir $OUT/design-inproc
same "design sample 0" $OUT/design-gpp-samples-0.wav $OUT/design-inproc/samples-0.wav
same "design sample 1" $OUT/design-gpp-samples-1.wav $OUT/design-inproc/samples-1.wav

# edit
edit() { # name, seed, edit json, [transcript]
  local name=$1 seed=$2 e=$3 t=${4:-}
  if [[ -n $t ]]; then
    gpp $name auk-flash int8 audio.edit_speech $seed "{\"edit\":$e}" --input "audio=$REF" --text "transcript=$t"
    inproc $name edit --take $REF --edit $e --transcript "$t" --seed $seed --out $OUT/$name-inproc.wav
  else
    gpp $name auk-flash int8 audio.edit_speech $seed "{\"edit\":$e}" --input "audio=$REF"
    inproc $name edit --take $REF --edit $e --seed $seed --out $OUT/$name-inproc.wav
  fi
  same $name $OUT/$name-gpp-audio-0.wav $OUT/$name-inproc.wav
}
edit replace 3 '{"kind":"replace_text","text":"river","with":"harbour"}' "$REFTEXT"
grep -q 'along the harbour' $OUT/replace-gpp.log && { pass=$((pass+1)); say "PASS  replace returns the edited transcript"; } || { fail=$((fail+1)); say "FAIL  replace returned no edited transcript"; }
edit happy 3 '{"kind":"emotion","emotion":"happy"}'
edit hum 4 '{"kind":"add_cue","cue":"hum","at":"start"}'
edit speed 5 '{"kind":"speed","factor":1.4}'
grep -q 'param_adjusted' $OUT/speed-gpp.log && { pass=$((pass+1)); say "PASS  speed 1.4 is snapped with param_adjusted"; } || { fail=$((fail+1)); say "FAIL  speed 1.4 wasn't snapped with a warning"; }
edit dereverb 6 '{"kind":"dereverb"}'

# separate
gpp ordinal auk-flash int8 audio.separate 5 '{"stems":["speaker"],"speaker":{"ordinal":2}}' --input "audio=$MIX"
inproc ordinal separate --mixture $MIX --ordinal 2 --seed 5 --out-dir $OUT/ordinal-inproc
same "separate: the second speaker" $OUT/ordinal-gpp-speaker.wav $OUT/ordinal-inproc/speaker.wav
gpp saying auk-flash int8 audio.separate 5 '{"stems":["speaker"],"speaker":{"saying":"coat pocket"}}' --input "audio=$MIX"
inproc saying separate --mixture $MIX --saying 'coat pocket' --seed 5 --out-dir $OUT/saying-inproc
same "separate: the speaker who says coat pocket" $OUT/saying-gpp-speaker.wav $OUT/saying-inproc/speaker.wav

# AuK Base
gpp base-clone auk int8 audio.speak 42 '{}' --text "text=$EN" --input "voice_ref=$REF" --text "voice_ref_text=$REFTEXT"
inproc base-clone speak --model auk --ref $REF --ref-text "$REFTEXT" --text "$EN" --seed 42 --out $OUT/base-clone-inproc.wav
same "AuK Base clone" $OUT/base-clone-gpp-audio-0.wav $OUT/base-clone-inproc.wav
gpp base-voices auk int8 audio.separate 9 '{"stems":["voices"]}' --input "audio=$MIX"
inproc base-voices separate --model auk --mixture $MIX --stems voices --seed 9 --out-dir $OUT/base-voices-inproc
same "AuK Base: every voice" $OUT/base-voices-gpp-voices.wav $OUT/base-voices-inproc/voices.wav

for s in $OUT/*.gpp; do
  if python3 ${GAEA_SPEC_ROOT:-$ROOT/../gaea-mes-media-server}/tools/validate.py --transcript $s >> $LOG 2>&1; then pass=$((pass+1)); say "PASS  ${s:t} passes validate.py"
  else fail=$((fail+1)); say "FAIL  ${s:t} fails validate.py"; fi
done
say "== $pass passed, $fail failed"
exit $(( fail > 0 ))
