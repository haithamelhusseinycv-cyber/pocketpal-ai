#!/usr/bin/env bash
# regen-ray-patch.sh — re-cut the RAY overlay patch from a working tree.
#
# Run this after you have applied the patch onto a NEWER upstream base and
# resolved any 3-way conflicts, so the committed overlay reflects the new base.
#
# It writes:
#   ray/ray-build-full.patch   — binary-safe diff of (working tree) vs (base)
#   ray/BASE_COMMIT            — the upstream commit the patch was cut against
#
# Usage:
#   scripts/ray/regen-ray-patch.sh [--base COMMIT]
#
#   --base COMMIT  The pristine upstream commit RAY sits on top of. Defaults to
#                  the current contents of ray/BASE_COMMIT. The diff is taken
#                  against this commit, so it MUST be an ancestor reachable in
#                  this repo (it is, if you applied with --3way onto it).
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

BASE_FILE="ray/BASE_COMMIT"
OUT="ray/ray-build-full.patch"
BASE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) BASE="$2"; shift 2 ;;
    *) echo "regen-ray-patch: unknown arg '$1'" >&2; exit 64 ;;
  esac
done

if [[ -z "$BASE" && -f "$BASE_FILE" ]]; then
  BASE="$(tr -d '[:space:]' < "$BASE_FILE")"
fi
if [[ -z "$BASE" ]]; then
  echo "ERROR: no base commit. Pass --base COMMIT or populate $BASE_FILE." >&2
  exit 3
fi

# Resolve to a full SHA and confirm it exists.
if ! BASE_FULL="$(git rev-parse --verify "${BASE}^{commit}" 2>/dev/null)"; then
  echo "ERROR: base commit not found in this repo: $BASE" >&2
  exit 3
fi

mkdir -p ray

# Stage everything so untracked RAY source files are included, then cut a
# binary-safe diff against the base. --binary is essential: the Arabic font TTFs
# are binary and would be dropped otherwise.
#
# CRITICAL: exclude the overlay itself (ray/ and scripts/ray/) from the diff.
# Those files live on the rebasable branch natively — they are NOT part of what
# the patch applies onto upstream. Including them would embed the previous patch
# blob inside the new one (recursive growth) and try to re-create the applier.
git add -A
# The repo gitignores `workflows/` broadly (the upstream workflows are tracked
# only because they were force-added). `git add -A` therefore SKIPS our
# .github/workflows/ray-apk.yml — force-add it so the regenerated patch keeps
# that in-tree build workflow. (build-ray.yml is branch infra and stays OUT of
# the patch — see the exclude below.)
if [[ -f .github/workflows/ray-apk.yml ]]; then
  git add -f .github/workflows/ray-apk.yml
fi
# Branch-native overlay infra must NOT go into the patch:
#   ray/, scripts/ray/                — the overlay + applier/regenerator
#   .github/workflows/build-ray.yml   — the orchestrator that RUNS the applier.
#       It has to exist on the branch before apply (chicken-and-egg otherwise).
git reset -q -- ray scripts/ray .github/workflows/build-ray.yml

EXCLUDES=( ':(exclude)ray' ':(exclude)scripts/ray' ':(exclude).github/workflows/build-ray.yml' )

git diff --cached "$BASE_FULL" --binary -- . "${EXCLUDES[@]}" > "$OUT"

echo "$BASE_FULL" > "$BASE_FILE"

FILES="$(git diff --cached "$BASE_FULL" --name-only -- . "${EXCLUDES[@]}" | wc -l | tr -d ' ')"
BYTES="$(wc -c < "$OUT" | tr -d ' ')"
BINARY="$(git diff --cached "$BASE_FULL" --numstat -- . "${EXCLUDES[@]}" | awk '$1=="-"' | wc -l | tr -d ' ')"

echo "== RAY patch regenerated =="
echo "base:    $BASE_FULL"
echo "patch:   $OUT"
echo "files:   $FILES  (binary: $BINARY)"
echo "bytes:   $BYTES"
echo
echo "Next: commit ray/ (the overlay) on your rebasable branch:"
echo "  git reset            # unstage the source-tree changes"
echo "  git add ray/"
echo "  git commit -m 'ray: regenerate overlay against $BASE_FULL'"
