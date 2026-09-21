#!/usr/bin/env bash
# apply-ray-patch.sh — apply the RAY overlay onto a pristine upstream checkout.
#
# This is what keeps the fork rebasable. The branch you push carries ONLY the
# thin ray/ overlay (this script + ray-build-full.patch + ray/BASE_COMMIT); the
# source tree itself stays exactly at upstream. CI checks out clean upstream at
# the pinned base commit, runs this script, and gets the full RAY tree. When
# upstream moves, you regenerate ONE patch file instead of resolving a hundred
# conflicting source files.
#
# Usage:
#   scripts/ray/apply-ray-patch.sh [--check] [--3way] [--patch PATH] [--base COMMIT]
#
# Flags:
#   --check    Verify the patch applies cleanly, then exit (do NOT modify tree).
#   --3way     Use `git apply --3way` so a drifted base produces merge conflicts
#              you can resolve, instead of a hard fail. Use this when rebasing
#              the patch onto a newer upstream commit.
#   --patch P  Path to the patch (default: ray/ray-build-full.patch).
#   --base C   Expected upstream base commit (default: contents of ray/BASE_COMMIT).
#              Pass --base "" to skip the base-commit guard.
#
# Exit codes:
#   0  success (or --check passed)
#   2  patch file missing
#   3  base-commit mismatch (tree is not at the pinned upstream commit)
#   4  patch does not apply cleanly (and --3way not requested)
#   5  post-apply verification failed (expected files missing)
#   6  --3way applied but left merge conflicts to resolve (normal rebase case)
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

PATCH="ray/ray-build-full.patch"
BASE_FILE="ray/BASE_COMMIT"
MODE="apply"      # apply | check
THREEWAY=""
EXPECTED_BASE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)  MODE="check"; shift ;;
    --3way)   THREEWAY="--3way"; shift ;;
    --patch)  PATCH="$2"; shift 2 ;;
    --base)   EXPECTED_BASE="$2"; shift 2 ;;
    *) echo "apply-ray-patch: unknown arg '$1'" >&2; exit 64 ;;
  esac
done

# Default expected base comes from the pinned file unless overridden on CLI.
if [[ -z "$EXPECTED_BASE" && -f "$BASE_FILE" ]]; then
  EXPECTED_BASE="$(tr -d '[:space:]' < "$BASE_FILE")"
fi

echo "== RAY overlay applier =="
echo "patch: $PATCH"
echo "mode:  $MODE ${THREEWAY:+(3way)}"

# --- Guard 1: patch must exist ---------------------------------------------
if [[ ! -f "$PATCH" ]]; then
  echo "ERROR: patch file not found: $PATCH" >&2
  exit 2
fi

# --- Guard 2: tree must be at the pinned upstream base ----------------------
ACTUAL_BASE="$(git rev-parse HEAD)"
if [[ -n "$EXPECTED_BASE" ]]; then
  # Compare full SHAs; allow the pinned value to be a prefix of HEAD or vice versa.
  if [[ "$ACTUAL_BASE" != "$EXPECTED_BASE" && "$ACTUAL_BASE" != "${EXPECTED_BASE}("* && "${ACTUAL_BASE:0:${#EXPECTED_BASE}}" != "$EXPECTED_BASE" ]]; then
    echo "ERROR: base-commit mismatch." >&2
    echo "  expected upstream base: $EXPECTED_BASE" >&2
    echo "  current HEAD:           $ACTUAL_BASE" >&2
    echo "  The patch was cut against a different upstream commit." >&2
    echo "  Either checkout the pinned base, or re-cut the patch and update $BASE_FILE," >&2
    echo "  or re-run with --3way to merge onto the drifted base." >&2
    exit 3
  fi
  echo "base:  $ACTUAL_BASE (matches pinned)"
else
  echo "base:  $ACTUAL_BASE (guard skipped)"
fi

# --- Guard 3: working tree must be clean (unless 3way, which may write) -----
if [[ "$MODE" == "apply" && -z "$THREEWAY" ]]; then
  if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "ERROR: working tree has uncommitted changes; apply would mix them in." >&2
    echo "  Commit/stash first, or re-run with --check to validate only." >&2
    exit 3
  fi
fi

# --- Verify it applies cleanly first (always, even in apply mode) ----------
echo "-- git apply --check"
if ! git apply --check "$PATCH" 2>/tmp/ray-apply-check.err; then
  echo "WARN: strict --check failed:" >&2
  cat /tmp/ray-apply-check.err >&2 || true
  if [[ -z "$THREEWAY" ]]; then
    echo "ERROR: patch does not apply cleanly to this tree." >&2
    echo "  If upstream drifted, re-run with --3way to get resolvable conflicts." >&2
    exit 4
  fi
  echo "  (--3way requested; will attempt a 3-way merge)"
fi

if [[ "$MODE" == "check" ]]; then
  echo "CHECK OK: patch applies cleanly to base $ACTUAL_BASE"
  exit 0
fi

# --- Apply ------------------------------------------------------------------
echo "-- applying"
# shellcheck disable=SC2086
if ! git apply $THREEWAY "$PATCH"; then
  if [[ -n "$THREEWAY" ]]; then
    # In 3-way mode a non-zero exit usually means "applied with conflicts to
    # resolve" — the normal rebase outcome, NOT a hard failure. Distinguish it
    # with its own exit code (6) so CI can branch on it.
    echo "MERGE CONFLICTS: 3-way apply left conflicts to resolve." >&2
    echo "  Resolve the <<<<<<< markers (git status shows unmerged files), then:" >&2
    echo "    git add -A && git commit" >&2
    echo "  Then re-cut the overlay: scripts/ray/regen-ray-patch.sh --base <new-upstream>" >&2
    exit 6
  fi
  echo "ERROR: git apply failed." >&2
  exit 4
fi

# --- Guard 4: post-apply verification (did the overlay actually land?) ------
echo "-- verifying overlay landed"
MISSING=0
for f in \
  src/utils/rayPersona.ts \
  src/utils/builtinRayPals.ts \
  src/services/talents/index.ts \
  src/services/talents/MemoryEngine.ts \
  src/services/talents/DeepSearchEngine.ts \
  src/services/talents/MicrosoftGraphEngine.ts \
  src/services/search/aggregate.ts \
  src/services/graph/auth.ts \
  src/services/stt/index.ts \
  src/services/tts/voiceLanguage.ts \
  src/services/talents/DictationEngine.ts \
  src/locales/ar.json \
  src/assets/fonts/NotoSansArabic-Regular.ttf \
  src/assets/fonts/Amiri-Regular.ttf \
  .github/workflows/ray-apk.yml ; do
  if [[ ! -e "$f" ]]; then
    echo "  MISSING: $f" >&2
    MISSING=1
  fi
done
if [[ "$MISSING" -ne 0 ]]; then
  echo "ERROR: patch applied but expected RAY files are absent — patch is stale." >&2
  exit 5
fi

# Talent count sanity: registry must declare 30 engines.
REG_COUNT="$(grep -c 'talentRegistry.register' src/services/talents/index.ts || true)"
echo "  registered talents: $REG_COUNT"
if [[ "$REG_COUNT" -lt 30 ]]; then
  echo "ERROR: expected >=30 registered talents, found $REG_COUNT." >&2
  exit 5
fi

echo "APPLY OK: RAY overlay landed on upstream base $ACTUAL_BASE"
