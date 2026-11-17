#!/bin/bash
set -euo pipefail

binary="${1:?Usage: bash scripts/test-batch-resume.sh PATH_TO_SHIFTDROP_BINARY}"
work="$(mktemp -d "${TMPDIR:-/tmp}/shiftdrop-resume-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

printf '1\n00:00:01,007 --> 00:00:02,999\nFirst sample\n' > "$work/first.srt"
printf '1\n00:00:01,007 --> 00:00:02,999\nSecond sample\n' > "$work/second.srt"
"$binary" --batch-new "$work/queue" "$work/output" vtt \
  "$work/first.srt" "$work/second.srt" > "$work/new.stdout"
first_id="$(awk '$1 == "complete" && /\/first\.vtt$/ {print $2}' "$work/new.stdout")"
second_id="$(awk '$1 == "complete" && /\/second\.vtt$/ {print $2}' "$work/new.stdout")"
test -n "$first_id"
test -n "$second_id"
grep -q '^WEBVTT$' "$work/output/first.vtt"
grep -q '^WEBVTT$' "$work/output/second.vtt"
cp "$work/output/second.vtt" "$work/expected-second.vtt"
printf 'Replacement output\n' > "$work/replacement.vtt"
cp "$work/replacement.vtt" "$work/expected-first.vtt"
mv -f "$work/replacement.vtt" "$work/output/first.vtt"

status=0
"$binary" --batch-resume "$work/queue" "$work/output" \
  > "$work/resume.stdout" 2> "$work/resume.stderr" || status="$?"
if [[ "$status" != 1 ]]; then
  echo "Expected per-job failure exit status 1, got $status." >&2
  cat "$work/resume.stderr" >&2
  exit 1
fi
grep -F "ShiftDrop batch $first_id:" "$work/resume.stderr"
grep -Fx "complete $second_id" "$work/resume.stdout"
cmp "$work/expected-first.vtt" "$work/output/first.vtt"
cmp "$work/expected-second.vtt" "$work/output/second.vtt"
outputs=("$work/output/"*)
test "${#outputs[@]}" -eq 2
