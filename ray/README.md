# RAY overlay — the rebasable fork

This branch is **upstream PocketPal AI plus a thin overlay**. The source tree is
kept pristine; all of RAY's changes live as a single binary-safe patch that CI
applies at build time. When upstream moves, you re-cut **one file** instead of
resolving a hundred conflicting source files.

## What's on the branch (not in the patch)

```
ray/BASE_COMMIT                  the pristine upstream commit RAY was cut against
ray/ray-build-full.patch         the full RAY delta (111 files, 8 binary font TTFs)
ray/README.md                    this file
scripts/ray/apply-ray-patch.sh   lays the delta onto the tree, with guards
scripts/ray/regen-ray-patch.sh   re-cuts the delta from a working tree
.github/workflows/build-ray.yml  the orchestrator (runs the applier, then builds)
```

Everything else — the 30 talents, the Arabic locale + fonts, the persona, the
Graph/STT/search layers, `ray-apk.yml` — is *inside the patch* and lands when
the applier runs.

## Build it (GitHub Actions)

Push this branch to your fork, then **Actions → "RAY build (upstream + overlay)"
→ Run workflow**:

- `variant` = release (default) or debug
- `skip_apk` = true → apply + run the JS gates only (~2 min). Use this to
  validate a freshly re-cut patch before committing to a full native build.
- `three_way` = true → only if the base drifted and you want merge conflicts
  surfaced instead of a hard fail (see below).

The job applies the overlay, runs `verify-fonts` / `validate-l10n` /
`verify-android-payload`, then `./gradlew assemble<variant>` and uploads the APK.
No secrets required — the APK is debug-signed (installable, not Play-Store-able).

## Apply locally

```bash
git clone https://github.com/<you>/pocketpal-ai && cd pocketpal-ai
git checkout <this-branch>
scripts/ray/apply-ray-patch.sh            # apply + verify
# or validate without touching the tree:
scripts/ray/apply-ray-patch.sh --check
```

The applier guards, in order:
1. patch file exists (exit 2)
2. HEAD is at the pinned `ray/BASE_COMMIT` (exit 3 on mismatch)
3. working tree is clean (exit 3 if dirty)
4. `git apply --check` passes (exit 4 if not, unless `--3way`)
5. post-apply: the expected RAY files are present and the registry declares
   ≥30 talents (exit 5 if the patch is stale/incomplete)

Exit 6 = `--3way` applied but left conflicts to resolve (the normal rebase case).

## Move to a newer upstream (the rebase loop)

```bash
# 1. start from the NEW pristine upstream commit
git checkout <new-upstream-sha>
# 2. bring in just the overlay infra from this branch
git checkout <this-branch> -- ray scripts/ray .github/workflows/build-ray.yml
# 3. 3-way apply onto the new base
scripts/ray/apply-ray-patch.sh --3way
#    -> exit 6 means conflicts; resolve the <<<<<<< markers:
git status                       # unmerged files
#    edit, then:
git add -A
# 4. re-cut the overlay against the new base
scripts/ray/regen-ray-patch.sh --base <new-upstream-sha>
# 5. commit ONLY the overlay (the source tree stays upstream-clean)
git reset                        # unstage source-tree changes
git add ray scripts/ray .github/workflows/build-ray.yml
git commit -m "ray: regenerate overlay against <new-upstream-sha>"
```

After step 4, `ray/ray-build-full.patch` and `ray/BASE_COMMIT` are updated and
self-consistent: applying the regenerated patch to the new base reproduces the
full RAY tree (verified round-trip: apply → regen → re-apply on a fresh clone →
30 talents, fonts, ar.json parity, workflow all present).

## Why this shape

- **Rebasable**: the diff against upstream is one file. Quarterly upstream bumps
  are a re-cut, not a merge-conflict marathon.
- **Honest**: the applier never builds a half-patched app — it verifies the
  overlay actually landed (file presence + talent count) before exiting 0.
- **Self-reproducing**: `regen` excludes the overlay infra (`ray/`,
  `scripts/ray/`, and the `build-ray.yml` orchestrator) from the patch, so the
  patch never embeds itself and never tries to recreate the applier. The
  in-tree `ray-apk.yml` *is* included (force-added past the repo's `workflows/`
  gitignore) because it's part of the RAY feature set, not branch infra.
