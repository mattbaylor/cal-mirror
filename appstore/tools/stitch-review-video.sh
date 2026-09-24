#!/usr/bin/env bash
# Join screen recordings into the one silent file App Review is given.
#
# WHY THIS EXISTS
# ---------------
# The recording Apple asked for covers a fresh install, three purchases and the
# page that results, which is more than anyone wants to get right in one take.
# Three takes joined is the same evidence and a great deal less swearing.
#
# It always re-encodes rather than stream-copying, which is the slower and the
# correct choice here: takes shot on different devices, or before and after a
# rotation, differ in dimensions and frame rate, and a concat that copies
# streams either refuses them or produces a file that plays for one second and
# freezes. Every input is scaled into the first one's frame, padded rather than
# cropped so nothing is cut off, and given a common frame rate.
#
# Audio is dropped outright (-an). A screen recording picks up the room, and
# the room is not evidence.
#
#   appstore/tools/stitch-review-video.sh take1.mov take2.mov take3.mov
#   OUT=/tmp/review.mp4 CRF=30 appstore/tools/stitch-review-video.sh *.mov
#
# A clip may carry a range in seconds, and the same file may appear twice —
# which is how you cut something out of the middle of a take rather than
# reshooting it:
#
#   stitch-review-video.sh take.mov@0-41 take.mov@52
#
# 0-41 is the first 41 seconds, 52 is from 52 seconds to the end, and what
# happened in between is not in the file. Typing an Apple Account password is
# the reason this exists: iOS shows dots rather than characters, but a password
# is not something to hand to App Review on the strength of that.
#
# The default CRF is chosen for App Store Connect's attachment field rather
# than for archival: legible text at phone scale, and a file small enough to
# upload. Raise CRF to shrink it further; the script prints the size it made.
set -euo pipefail

OUT="${OUT:-dist/review-recording.mp4}"
CRF="${CRF:-28}"

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <clip> [clip ...]   (in the order they should play)" >&2
  exit 2
fi

command -v ffmpeg >/dev/null || { echo "ffmpeg not on PATH — brew install ffmpeg" >&2; exit 1; }
command -v ffprobe >/dev/null || { echo "ffprobe not on PATH — brew install ffmpeg" >&2; exit 1; }

# Split "path@start-end" into the three. The path is taken from the left of the
# LAST "@" so a filename containing one still works.
clip_path() { case "$1" in *@*) echo "${1%@*}";; *) echo "$1";; esac; }
clip_start() { case "$1" in *@*) r="${1##*@}"; echo "${r%%-*}";; *) echo "";; esac; }
clip_end()   { case "$1" in *@*-*) r="${1##*@}"; echo "${r#*-}";; *) echo "";; esac; }

for spec in "$@"; do
  f=$(clip_path "$spec")
  [ -f "$f" ] || { echo "no such file: $f" >&2; exit 1; }
done

# The first clip sets the frame. Everything else is fitted into it, so shoot
# the takes the same way up and this stays a no-op.
# `-of csv=p=0` on a container that carries more than one video track (a
# QuickTime screen recording does) yields "884," with a trailing field, which
# reads as a syntax error the moment it reaches arithmetic. Take the first
# value and nothing else.
probe() { ffprobe -v error -select_streams v:0 -show_entries "stream=$1" \
  -of default=noprint_wrappers=1:nokey=1 "$2" | head -1; }

first=$(clip_path "$1")
W=$(probe width  "$first")
H=$(probe height "$first")
# H.264 wants even dimensions; a phone capture is already even, but a clip
# scaled from one is not reliably so.
W=$(( (W / 2) * 2 ))
H=$(( (H / 2) * 2 ))

echo "==> Output frame ${W}x${H}, from $(basename "$first")"

inputs=()
filter=""
i=0
for spec in "$@"; do
  f=$(clip_path "$spec")
  ss=$(clip_start "$spec")
  to=$(clip_end "$spec")
  dims="$(probe width "$f")x$(probe height "$f")"
  dur=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$f" | head -1)
  range=""
  [ -n "$ss" ] && range=" from ${ss}s"
  [ -n "$to" ] && range="${range} to ${to}s"
  printf '    %-40s %s  %.1fs%s\n' "$(basename "$f")" "$dims" "$dur" "$range"
  # -ss and -to belong BEFORE -i: after it they seek the output, which for a
  # concat means decoding the whole clip and throwing most of it away.
  [ -n "$ss" ] && inputs+=(-ss "$ss")
  [ -n "$to" ] && inputs+=(-to "$to")
  inputs+=(-i "$f")
  # scale keeps the aspect ratio, pad fills the rest — a take shot in a
  # different aspect is letterboxed, never cropped. setsar keeps the concat
  # filter from refusing mismatched sample aspect ratios.
  filter+="[${i}:v]scale=${W}:${H}:force_original_aspect_ratio=decrease,"
  filter+="pad=${W}:${H}:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30[v${i}];"
  i=$((i + 1))
done

for ((j = 0; j < i; j++)); do filter+="[v${j}]"; done
filter+="concat=n=${i}:v=1:a=0[out]"

mkdir -p "$(dirname "$OUT")"

echo "==> Encoding ${i} clip(s), no audio, crf ${CRF}"
ffmpeg -y -loglevel error -stats "${inputs[@]}" \
  -filter_complex "$filter" -map "[out]" \
  -an \
  -c:v libx264 -preset slow -crf "$CRF" -pix_fmt yuv420p -movflags +faststart \
  "$OUT"

secs=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$OUT" | head -1)
bytes=$(wc -c < "$OUT" | tr -d ' ')
printf '==> %s — %.1fs, %s\n' "$OUT" "$secs" "$(du -h "$OUT" | cut -f1)"

# Said rather than assumed: the attachment field's ceiling is not documented,
# and a file that has to be re-made after a failed upload is worth warning
# about before the upload rather than after.
if [ "$bytes" -gt $((45 * 1024 * 1024)) ]; then
  echo "==> That is large for App Store Connect's attachment field."
  echo "    Re-run with a higher CRF (CRF=32) or host it and put the link in Review Notes."
fi
if ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$OUT" | grep -q .; then
  echo "!!! output still has an audio stream — that is a bug in this script" >&2
  exit 1
fi
echo "==> No audio stream, as intended"
