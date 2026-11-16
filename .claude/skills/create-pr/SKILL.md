---
name: create-pr
description: Create a GitHub pull request for og. Use for every change to this repository (code, docs, specs, VERSION), whenever work is ready to commit, or when the user asks to open a PR. Branches from origin/main, runs og's checks, commits with attribution, pushes, opens the PR with gh, and waits for CI. og never commits to main directly.
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

## 3. Commit

- Stage only the files of this change (`git add <paths>`). Run `git status` again before committing.
- Subject: imperative and at most 72 characters. When `VERSION` changed, start with it: `og 0.5.0: New Project`.
- Body: what changed and why, wrapped at 72 characters.
- End the message with the attribution line from the session's system reminder, for example:

```text
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
```

## 4. Push and open the PR

1. `git push -u origin <topic>`
2. `gh pr create --base main --title "<subject>" --body "<body>"`, with a body in this shape:

```markdown
- **<Area>:** what changed, in one or two sentences.
- **<Area>:** …

Checked: what you ran and what it showed (driver output, snapshots, tests). Say what was not checked.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
```

Write `@name` only for a real GitHub login you mean to notify.

## 5. Wait for CI

1. `gh pr checks <number> --watch --interval 30`
2. If CI fails, read the log (`gh run view <id> --log-failed`), fix the cause on the same branch, and push again. Do not merge a red PR.
3. Report the PR URL and the CI result to the user.

## 6. Merge (only when asked or when releasing)

- Merge when the user asks, or as part of a release (a `VERSION` bump means a full release: merge, tag, release workflow, cask).
- Before merging, check that the branch is current: if `origin/main` moved, `git rebase origin/main`, rerun the checks, push with `--force-with-lease` (to the topic branch only), and wait for CI again.
- `gh pr merge <number> --squash --delete-branch`, then `git switch main && git pull`.
