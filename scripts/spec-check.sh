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
depth_for() { case "$1" in *design/refactor.fsl|*design/research.fsl|*docs_deps.fsl) echo 12 ;; *) echo 8 ;; esac; }
# fslc refine has a fixed 50,000-state correspondence budget (not configurable via CLI):
# docs_deps explores 29,381 states at depth 8 (refines) and hits the 50,000-state unknown_budget at depth 9+
# due to the 2-module x 2-version (ModSlot 0..3) product domain; both req and design still verify at depth 12
# and prove all invariants by unbounded induction.
refine_depth_for() { case "$1" in docs_deps) echo 8 ;; *) depth_for "spec/design/$1.fsl" ;; esac; }

for f in spec/req/*.fsl spec/design/*.fsl; do
  case "$f" in *_refines_*) continue ;; esac
  d=$(depth_for "$f")
  run "check     $f" fslc check "$f" --strict-tags
  run "verify    $f" fslc verify "$f" --depth "$d" --vacuity error
  run "induction $f" fslc verify "$f" --engine induction
done

for m in spec/design/*_refines_req.fsl; do
  name=$(basename "$m" _refines_req.fsl)
  d=$(refine_depth_for "$name")
  run "refine    $name" fslc refine "spec/design/$name.fsl" "spec/req/$name.fsl" "$m" --depth "$d"
done

exit $fail
