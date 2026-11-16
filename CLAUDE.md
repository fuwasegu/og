@AGENTS.md

## Changes always go through a pull request

- Every change, however small (code, docs, specs, `VERSION`), reaches `main` through a GitHub pull request. Never commit to `main` or push to it directly, and never `git push --force` to `main`.
- Create the branch and the PR with the `create-pr` skill (`.claude/skills/create-pr/SKILL.md`). It covers the branch, the checks, the commit, the PR body, and waiting for CI.
- Merge only after CI passes. Another agent may be working on `main` at the same time (Fleet), so rebase onto the latest `origin/main` before you merge.
