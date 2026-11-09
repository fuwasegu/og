#!/usr/bin/env bash
# Verify every FSL spec: requirements, design, and design-refines-requirements.
# Requires `fslc` (see .claude/skills/README.md for installation).
set -u
cd "$(dirname "$0")/.."

fail=0
result() { python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("result"))'; }
run() {
  local label="$1"; shift
  local r; r=$("$@" | result)
  printf '%-48s %s\n' "$label" "$r"
  case "$r" in ok|verified|proved|refines) ;; *) fail=1 ;; esac
}
depth_for() { case "$1" in *design/refactor.fsl) echo 12 ;; *) echo 8 ;; esac; }

for f in spec/req/*.fsl spec/design/*.fsl; do
  case "$f" in *_refines_*) continue ;; esac
  d=$(depth_for "$f")
  run "check     $f" fslc check "$f" --strict-tags
  run "verify    $f" fslc verify "$f" --depth "$d" --vacuity error
  run "induction $f" fslc verify "$f" --engine induction
done

for m in spec/design/*_refines_req.fsl; do
  name=$(basename "$m" _refines_req.fsl)
  d=$(depth_for "spec/design/$name.fsl")
  run "refine    $name" fslc refine "spec/design/$name.fsl" "spec/req/$name.fsl" "$m" --depth "$d"
done

exit $fail
