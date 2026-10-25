#!/usr/bin/env bash
#
# Tests for cutlist: generates tiny clips with lavfi, writes specs, checks the printed
# command (and, for render cases, runs it and checks the result with ffprobe).
#
#   tests/run-tests.sh

export LC_ALL=C

readonly stitch="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/cutlist"
readonly work=$(mktemp -d "${TMPDIR:-/tmp}/stitch-tests.XXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT

passed=0
failed=0

pass() {
    printf 'ok    %s\n' "$1"
    ((passed++))
}

fail() {
    printf 'FAIL  %s\n      %s\n' "$1" "$2"
    ((failed++))
}

clip() {
    local name=$1 video=$2 audio=$3
    if [[ -n $audio ]]; then
        ffmpeg -hide_banner -loglevel error -y -f lavfi -i "$video" -f lavfi -i "$audio" \
            -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -shortest -- "$work/$name"
    else
        ffmpeg -hide_banner -loglevel error -y -f lavfi -i "$video" \
            -c:v libx264 -preset ultrafast -pix_fmt yuv420p -- "$work/$name"
    fi
}

# Clip with a keyframe every 15 frames, so the hybrid method has something to copy.
gop_clip() {
    local name=$1 video=$2 audio=$3 encoder=${4:-libx264}
    local params=(-g 15)
    [[ $encoder == libx265 ]] && params=(-x265-params log-level=error:keyint=15:min-keyint=15:open-gop=0)
    ffmpeg -hide_banner -loglevel error -y -f lavfi -i "$video" -f lavfi -i "$audio" \
        -c:v "$encoder" "${params[@]}" -preset ultrafast -pix_fmt yuv420p -c:a aac -shortest -- "$work/$name"
}

frame_md5() {
    ffmpeg -v error -i "$1" -map 0:v:0 -fps_mode passthrough -f framemd5 - | grep -v '^#' | awk -F, '{ gsub(/ /, "", $6); print $6 }'
}

# Checks that output frames [from, from+count) are bit-identical to source frames [src_from, ...).
expect_copied() {
    local name=$1 out=$2 from=$3 src=$4 src_from=$5 count=$6
    if cmp -s <(frame_md5 "$work/$out" | sed -n "$((from + 1)),$((from + count))p") \
        <(frame_md5 "$work/$src" | sed -n "$((src_from + 1)),$((src_from + count))p"); then
        pass "$name"
    else
        fail "$name" "frames differ from $src"
    fi
}

spec() {
    printf '%s\n' "$2" >"$work/$1.json"
}

probe() {
    ffprobe -v error -select_streams "$2" -show_entries "$3" -of csv=p=0 -- "$1" | head -1
}

# Runs cutlist on a spec, runs the printed command, and checks duration/frames/size/audio.
expect_render() {
    local name=$1 duration=$2 frames=$3 size=$4 audio=$5 command
    local out=$work/$name.mp4

    if ! command=$("$stitch" "$work/$name.json" 2>"$work/$name.err"); then
        fail "$name" "cutlist failed: $(tr '\n' ' ' <"$work/$name.err")"
        return
    fi
    if ! bash -c "$command" >/dev/null 2>"$work/$name.ffmpeg"; then
        fail "$name" "printed command failed: $(tail -2 "$work/$name.ffmpeg" | tr '\n' ' ')"
        return
    fi
    [[ ! -e $work/$name-p.mp4 ]] || {
        fail "$name" "temporary file left behind"
        return
    }

    local got_dur got_frames got_size got_audio
    got_dur=$(probe "$out" v:0 stream=duration)
    got_frames=$(probe "$out" v:0 stream=nb_frames)
    got_size=$(probe "$out" v:0 stream=width,height | tr ',' 'x')
    got_audio=$(probe "$out" a:0 stream=codec_type)

    if ! awk -v a="$got_dur" -v b="$duration" 'BEGIN { exit !(a - b < 0.05 && b - a < 0.05) }'; then
        fail "$name" "duration $got_dur, expected $duration"
    elif [[ -n $frames && $got_frames != "$frames" ]]; then
        fail "$name" "frames $got_frames, expected $frames"
    elif [[ $got_size != "$size" ]]; then
        fail "$name" "size $got_size, expected $size"
    elif [[ $audio == audio && $got_audio != audio ]] || [[ $audio == none && -n $got_audio ]]; then
        fail "$name" "audio stream: '${got_audio:-none}', expected $audio"
    else
        pass "$name"
    fi
}

# Runs cutlist on a spec that must fail; checks exit 1, empty stdout, and the message.
expect_error() {
    local name=$1 pattern=$2 stdout status
    stdout=$("$stitch" "$work/$name.json" 2>"$work/$name.err")
    status=$?
    if ((status != 1)); then
        fail "$name" "exit status $status, expected 1"
    elif [[ -n $stdout ]]; then
        fail "$name" "printed a command despite errors"
    elif ! grep -qF -- "$pattern" "$work/$name.err"; then
        fail "$name" "missing message '$pattern' in: $(tr '\n' ' ' <"$work/$name.err")"
    else
        pass "$name"
    fi
}

# Checks the printed command contains (or lacks) a fixed string.
expect_command() {
    local name=$1 mode=$2 needle=$3 command
    command=$("$stitch" "$work/$name.json" 2>/dev/null)
    if [[ $mode == has && $command != *"$needle"* ]]; then
        fail "$name: has '$needle'" "not found in the command"
    elif [[ $mode == lacks && $command == *"$needle"* ]]; then
        fail "$name: lacks '$needle'" "found in the command"
    else
        pass "$name: $mode '$needle'"
    fi
}

printf 'generating clips in %s\n' "$work"
clip a.mp4 'testsrc2=s=320x180:r=30:d=2' 'sine=f=440:r=48000:d=2'
clip b.mp4 'testsrc=s=320x180:r=30:d=1.5' 'sine=f=660:r=48000:d=1.5'
clip c.mp4 'smptebars=s=640x360:r=25:d=2' 'sine=f=330:r=44100:d=2'
clip silent.mp4 'rgbtestsrc=s=320x180:r=30:d=1' ''
clip short.mp4 'testsrc2=s=320x180:r=30:d=0.5' 'sine=f=220:r=48000:d=0.5'
cp -- "$work/a.mp4" "$work/a copy's.mp4"
gop_clip ga.mp4 'testsrc2=s=320x180:r=30:d=3' 'sine=f=440:r=48000:d=3'
gop_clip gb.mp4 'testsrc=s=320x180:r=30:d=2' 'sine=f=660:r=48000:d=2'
gop_clip ha.mp4 'testsrc2=s=320x180:r=30000/1001:d=3' 'sine=f=440:r=48000:d=3' libx265
gop_clip hb.mp4 'testsrc=s=320x180:r=30000/1001:d=2' 'sine=f=660:r=48000:d=2' libx265
mkdir -p -- "$work/sub"
cp -- "$work/b.mp4" "$work/sub/b.mp4"
mkdir -p -- "$work/amb"
touch -- "$work/amb/fade"
printf 'not a video\n' >"$work/junk.mp4"

# --- rendering --------------------------------------------------------------
# a(2) fade b(1.5) cut c(2, 640x360@25) wipeleft:0.5 silent(1) = 2+1.5-1+2+1-0.5 = 5.0
spec mixed '{"output":"mixed.mp4","preset":"ultrafast",
  "sequence":["a.mp4","fade","b.mp4","c.mp4","wipeleft:0.5","silent.mp4"]}'
expect_render mixed 5.0 150 320x180 audio

spec spec_duration '{"output":"spec_duration.mp4","preset":"ultrafast","duration":0.25,
  "sequence":["a.mp4","fade","b.mp4","fadeblack:0.5","a.mp4"]}'
expect_render spec_duration 4.75 '' 320x180 audio # 2+1.5-0.25+2-0.5

spec resized '{"output":"resized.mp4","preset":"ultrafast","size":"641x361","fps":"30000/1001",
  "sequence":["a.mp4","circleopen","c.mp4"]}'
expect_render resized 3.0 '' 640x360 audio

spec no_audio '{"output":"no_audio.mp4","preset":"ultrafast","audio":false,
  "sequence":["a.mp4","b.mp4"]}'
expect_render no_audio 3.5 105 320x180 none

spec all_silent '{"output":"all_silent.mp4","preset":"ultrafast",
  "sequence":["silent.mp4","dissolve:0.5","silent.mp4"]}'
expect_render all_silent 1.5 45 320x180 none

spec single '{"output":"single.mp4","preset":"ultrafast","sequence":["c.mp4"]}'
expect_render single 2.0 50 640x360 audio

spec copy '{"output":"copy.mp4","sequence":["a.mp4","a copy'"'"'s.mp4","a.mp4"]}'
expect_render copy 6.0 180 320x180 audio
expect_command copy has '-c copy'
expect_command copy lacks 'filter_complex'

spec subdir '{"output":"subdir.mp4","preset":"ultrafast","sequence":["./a.mp4","slideup","sub/b.mp4"]}'
expect_render subdir 2.5 75 320x180 audio

spec repeated_cache '{"output":"repeated_cache.mp4","preset":"ultrafast",
  "sequence":["a.mp4","fade:0.5","a.mp4","fade:0.5","a.mp4"]}'
expect_render repeated_cache 5.0 150 320x180 audio

# --- hybrid: copy around the transitions -------------------------------------
# ga(3) fade:0.5 gb(2) cut ga(3) wipeleft gb(2) = 3+2-0.5+3+2-1 = 8.5
spec hybrid '{"output":"hybrid.mp4","preset":"ultrafast",
  "sequence":["ga.mp4","fade:0.5","gb.mp4","ga.mp4","wipeleft","gb.mp4"]}'
mkdir -p -- "$work/tmp"
TMPDIR=$work/tmp expect_render hybrid 8.5 255 320x180 audio
if [[ -z $(ls -A -- "$work/tmp") ]]; then
    pass "hybrid: temp dir removed"
else
    fail "hybrid: temp dir removed" "$(ls -- "$work/tmp")"
fi
expect_copied 'hybrid: ga head copied' hybrid.mp4 0 ga.mp4 0 75     # ga up to its keyframe at 2.5s
expect_copied 'hybrid: gb middle copied' hybrid.mp4 90 gb.mp4 15 45 # gb from 0.5s, then a cut
expect_copied 'hybrid: ga middle copied' hybrid.mp4 135 ga.mp4 0 60 # ga up to 2.0s
expect_copied 'hybrid: gb tail copied' hybrid.mp4 225 gb.mp4 30 30  # gb from 1.0s
expect_command hybrid has '-segment_frames 75'
expect_command hybrid has '-c:v libx264 -crf 23 -preset ultrafast -bf 0'
expect_command hybrid has '-map 0:v:0 -map '"'"'[aout]'"'"' -c:v copy'
expect_command hybrid lacks 'hvc1'

spec hybrid_hevc '{"output":"hybrid_hevc.mp4","preset":"ultrafast",
  "sequence":["ha.mp4","circleopen","hb.mp4"]}'
expect_render hybrid_hevc 3.937 118 320x180 audio # 89+59-30 frames at 29.97
expect_copied 'hybrid_hevc: ha head copied' hybrid_hevc.mp4 0 ha.mp4 0 45
expect_command hybrid_hevc has '-c:v libx265'
expect_command hybrid_hevc has '-tag:v hev1'

spec codec_mismatch '{"output":"codec_mismatch.mp4","codec":"libx265",
  "sequence":["ga.mp4","fade","gb.mp4"]}'
expect_command codec_mismatch lacks 'segment_frames'
expect_command codec_mismatch has '-tag:v hvc1'

# --- command details ---------------------------------------------------------
expect_command mixed has '-c:v libx265 -crf 23 -preset ultrafast'
expect_command mixed has '-tag:v hvc1'
expect_command mixed has '-movflags +faststart'
expect_command mixed has '[c2]settb=AVTB[x2]'
expect_command mixed has 'anullsrc=r=48000:cl=stereo'
expect_command mixed has '&& mv -f --'

spec encoder '{"output":"encoder.mkv","codec":"libx264","crf":18,"preset":"fast","audio_bitrate":"192k",
  "sequence":["a.mp4","fade","b.mp4"]}'
expect_command encoder has '-c:v libx264 -crf 18 -preset fast'
expect_command encoder has '-b:a 192k'
expect_command encoder lacks 'hvc1'
expect_command encoder lacks 'faststart'

# --- errors (nothing printed on stdout) -------------------------------------
spec unknown_key '{"duraton":1,"sequence":["a.mp4"]}'
expect_error unknown_key "unknown key 'duraton' — did you mean 'duration'?"

spec unknown_transition '{"sequence":["a.mp4","wipelft","b.mp4"]}'
expect_error unknown_transition "unknown transition 'wipelft' — did you mean 'wipeleft'?"

spec too_long '{"sequence":["a.mp4","fade","short.mp4"]}'
expect_error too_long 'transition too long: join 1  a.mp4 → short.mp4  fade 1.00s  max 0.50s'

spec both_sides '{"sequence":["a.mp4","fade:0.5","b.mp4","fade:1.2","a.mp4"]}'
expect_error both_sides 'b.mp4 is 1.50s; needs 0.50s in + 1.20s out'

spec zero '{"sequence":["a.mp4","fade:0","b.mp4"]}'
expect_error zero "transition 'fade:0': duration must be greater than 0"

spec bad_duration '{"duration":0,"sequence":["a.mp4"]}'
expect_error bad_duration "'duration' must be greater than 0"

spec missing '{"sequence":["a.mp4","nope.mp4"]}'
expect_error missing 'file not found:'

spec junk '{"sequence":["a.mp4","junk.mp4"]}'
expect_error junk 'cannot read junk.mp4'

spec leading '{"sequence":["fade","a.mp4"]}'
expect_error leading "transition 'fade' must come after a clip"

spec trailing '{"sequence":["a.mp4","fade"]}'
expect_error trailing "the sequence ends with transition 'fade'"

spec double '{"sequence":["a.mp4","fade","wipeleft","b.mp4"]}'
expect_error double 'only one transition is allowed per join'

spec amb/ambiguous '{"sequence":["../a.mp4","fade","../b.mp4"]}'
expect_error amb/ambiguous "'fade' is both a transition and a file; write the file as './fade'"

spec no_ext '{"output":"result","sequence":["a.mp4"]}'
expect_error no_ext 'needs a file extension'

spec bad_size '{"size":"big","sequence":["a.mp4"]}'
expect_error bad_size "'size' must be"

spec many '{"duraton":1,"sequence":["a.mp4","wipelft","nope.mp4","fade:9","b.mp4"]}'
expect_error many '3 problems found'

printf '\n%d passed, %d failed\n' "$passed" "$failed"
((failed == 0))
