---
name: create-pr
description: Create a GitHub pull request for og. Use for every change to this repository (code, docs, specs, VERSION), whenever work is ready to commit, or when the user asks to open a PR. Branches from origin/main, runs og's checks, self-reviews the diff, commits with attribution, pushes, opens the PR with gh, and waits for CI. og never commits to main directly.
---

# Create a pull request (og)

Every change reaches `main` through a PR (see `CLAUDE.md`). Follow these steps in order. Stop and tell the user when a step fails; do not work around it.

## 1. Branch

1. `git fetch origin` and look at `git status`. Leave unrelated changes you did not make alone, and do not commit them.
2. If you are on `main`, create a branch from the latest `origin/main`: `git switch -c <topic> origin/main`. Name it after the change in kebab-case (`split-panes`, `new-project`). Never commit on `main`.
3. If another PR is open on a related branch, ask the user whether to build on it or stay separate.

## 2. Check

Run these from the repository root. Every one must pass with 0 errors and 0 warnings.

1. `make check` (guardrails, debug build, tests, release build). If SwiftPM is broken on the machine (a dyld error from `swift build`), use `scripts/dev-build.sh` and `scripts/dev-build.sh release` instead, and say in the PR that CI runs the tests.
2. `make spec` when anything under `spec/` changed, or when behavior changed (AGENTS.md §1).
3. For UI changes, check with the headless driver (`OG_DEBUG_SCRIPT`, AGENTS.md §2) and `snap`. Never capture the user's screen.

## 3. Self-review

Before committing, read the whole diff as a reviewer would: `git diff origin/main` (with `--stat` first). Fix every problem you find, rerun step 2, and review again. Do not open the PR with a known problem in it.

- **Scope:** only the change you meant. No stray files, debug prints, commented-out code, or unrelated edits.
- **Correctness:** edge cases (empty input, missing files, cancellation, errors). Callers of anything whose behavior changed.
- **og's invariants** (AGENTS.md §4): no WebKit, UTF-16 ranges through `TextLines`, no silent data loss, version-safe LSP, loopback-only AI, and no `as!` or `try!` in `Sources/`.
- **Concurrency:** `@MainActor` closures that a system queue may call, and `Sendable` captures.
- **Tests and docs:** new OgCore logic has tests in `Tests/OgCoreTests/`. User-visible changes update `README.md` and `README.en.md`, and their shortcuts tables. Behavior changes update `spec/`.
- **Secrets:** no tokens, keys, or personal paths in the diff.

For a large or risky change, also run the `code-review` skill on the branch and handle its findings.

## 4. Commit

- Stage only the files of this change (`git add <paths>`). Run `git status` again before committing.
- Subject: imperative and at most 72 characters. When `VERSION` changed, start with it: `og 0.5.0: New Project`.
- Body: what changed and why, wrapped at 72 characters.
- End the message with the attribution line from the session's system reminder, for example:

```text
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
```

## 5. Push and open the PR

1. `git push -u origin <topic>`
2. `gh pr create --base main --title "<subject>" --body "<body>"`, with a body in this shape:

```markdown
- **<Area>:** what changed, in one or two sentences.
- **<Area>:** …

Checked: what you ran and what it showed (driver output, snapshots, tests). Say what was not checked.

Self-review: what you looked at and what you fixed because of it.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

Write `@name` only for a real GitHub login you mean to notify.

## 6. Wait for CI

1. `gh pr checks <number> --watch --interval 30`. A PR that only changes `*.md` files or `.claude/` runs no CI (`paths-ignore` in `.github/workflows/ci.yml`); `gh pr checks` then reports no checks, and that is expected.
2. If CI fails, read the log (`gh run view <id> --log-failed`), fix the cause on the same branch, and push again. Do not merge a red PR.
3. Report the PR URL and the CI result to the user.

## 7. Merge (only when asked or when releasing)

- Merge when the user asks, or as part of a release (a `VERSION` bump means a full release: merge, tag, release workflow, cask).
- Before merging, check that the branch is current: if `origin/main` moved, `git rebase origin/main`, rerun the checks, push with `--force-with-lease` (to the topic branch only), and wait for CI again.
- `gh pr merge <number> --squash --delete-branch`, then `git switch main && git pull`.
