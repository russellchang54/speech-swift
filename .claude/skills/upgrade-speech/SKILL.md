---
name: upgrade-speech
description: Upgrade this fork onto the newest upstream code — pull upstream into `main`, rebase the custom feature branch on top, rebuild with `make build`, then force-push after confirmation. Use this whenever the user wants to sync or upgrade against upstream soniqo/speech-swift, rebase a branch onto latest main, catch up with upstream, or says "upgrade speech". Trigger it even when they describe only one step — "pull latest and rebuild", "rebase my branch on main", "get me onto the newest upstream code" — because the steps only work as a sequence and doing a subset leaves the repo looking fine while being wrong.
disable-model-invocation: false
argument-hint: [branch-to-rebase]
allowed-tools: Bash
---

# Upgrade speech

Bring this fork up to the newest upstream code, replay the custom branch on top of it, and prove the
result still builds.

The order matters more than it looks. `main` mirrors upstream `soniqo/speech-swift`; the feature branch
is a stack of local commits sitting on `main`; the release build is the only thing that proves the
replay actually works. Pick up two of the three and you get a repo that looks healthy but isn't — a
rebase without a rebuild, or a build against a `main` that was never updated, both hand you a binary
that doesn't match the source you believe you're running.

## Preconditions

Check these before touching anything. If either fails, stop and say so rather than working around it.

**No tracked file may be modified.** Run `git status --porcelain --untracked-files=no` and require empty
output. Untracked files are fine — `git checkout` carries them across untouched, and this skill's own
file is untracked until someone commits it, so a blanket `--porcelain` check would block its own first
run. What actually gets stranded is an uncommitted edit to a *tracked* file.

The user's standing policy is to do work in an isolated git worktree, but this workflow deliberately
runs in the shared working copy — the existing `.build` directory is what keeps `make build` from
taking many extra minutes. That shortcut is only safe while no tracked file is modified. An uncommitted
change there means another agent's work-in-progress is sitting in the tree, and `git checkout` would
strand it silently.

**Resolve the branch to rebase.** Default `feature/phone-call-diarization`; if the skill was invoked
with an argument, use that instead. Confirm it exists with `git rev-parse --verify <branch>` before
relying on it. Note the bare name `phone-call-diarization` does not exist — only the `feature/`-prefixed
one — so a lookalike name will fail the check rather than doing something surprising.

## 1. Update main from upstream

```bash
git checkout main
git pull --ff-only upstream main
```

`main` is configured to track the `upstream` remote, so this pulls upstream directly. That is why
syncing the fork's own `origin/main` first is unnecessary here — the local rebase only needs the code,
and the daily sync workflow keeps `origin/main` current on its own schedule.

`--ff-only` is the substance of this step, not decoration. `main` is a pure mirror of upstream and is
never supposed to carry local commits. If this refuses to fast-forward, `main` has picked up a commit
it shouldn't have, and a silent merge would bury exactly the thing worth knowing.

**Worth checking while you're here:** the `upstream` remote points at a third-party mirror
(`git.cangqian.uk`), not at GitHub. Nothing guarantees that mirror stays current, and a stale one means
rebasing onto old code with no error anywhere to warn you. Compare `git rev-parse main` against
`gh api repos/soniqo/speech-swift/commits/main --jq .sha` — if they disagree, tell the user before
rebasing instead of after. Skip this only when `gh` isn't available.

## 2. Replay the feature branch

```bash
git checkout <branch>
git rebase main
```

If the rebase stops on a conflict, **stop there**. Report which files conflicted and how many commits
replayed cleanly before the stop. Don't auto-resolve: these are the user's own commits being replayed
onto upstream code that moved underneath them, and only they know which side is correct. `git rebase
--abort` restores the branch to exactly its prior state, so there's no cost to asking.

## 3. Rebuild

```bash
export https_proxy=http://127.0.0.1:7890
export http_proxy=http://127.0.0.1:7890
make build
```

**The proxy is not optional.** A rebase routinely rewrites `Package.swift` (upstream adds and removes
dependencies constantly), so the build re-resolves, and SwiftPM fetches inside `.build/repositories/*`
— clones that do *not* inherit this repo's `http.proxy` setting. Without the environment variables
above they dial github.com directly: each fetch stalls ~35 seconds, then the build dies with
`Couldn't fetch updates from remote repositories` and never reaches the compiler. That failure looks
like a broken merge but isn't, which is the expensive part. With the proxy the same fetches finish in
seconds. If 7890 isn't listening, try 7897.

That expands to `swift build -c release --disable-sandbox` followed by
`scripts/build_mlx_metallib.sh release`. Expect several minutes — that's a slow build, not a hang.

**Expect the dependency download to be the hard part — not the compile.** A rebase rewrites
`Package.swift`, so the build always re-resolves and re-downloads, and there are three separate
network channels with three different fixes: git fetches that need the environment proxy, large repos
that fail with `early EOF` unless the URL is repointed at the `git.cangqian.uk` mirror, and binary
artifacts that `URLSession` downloads while ignoring the proxy entirely. `/build` covers all three and
the log line that identifies each.

Budget your time accordingly. The 20802-task compile is the predictable part; the downloads are where
an upgrade actually stalls, and every failure presents as a hang rather than an error.

The metallib step is load-bearing, so don't skip or parallelise it away. It compiles the MLX Metal
shaders; without it inference falls back to JIT shader compilation and runs roughly 5x slower, which
is easy to mistake for a regression in the upgrade.

A build failure means the replay doesn't actually work. Report the compiler errors and stop — an
upgrade that doesn't compile is not partially successful.

## 4. Stop and ask before pushing

Summarise for the user, then wait:

- which upstream commit `main` landed on, and how many commits were replayed
- whether the build passed
- that the next step rewrites already-published history

The user's standing policy is that nothing is pushed without explicit confirmation. That matters more
than usual here: the rebase rewrote the branch, so publishing it takes a force push, and anyone who
has the branch fetched will have to reset. Whether that's acceptable today is their call.

## 5. Push

```bash
git push --force-with-lease origin <branch>
```

Only once the user has said go. Name both the remote and the branch explicitly — this branch has no
upstream tracking configured, so a bare `git push` fails.

Use `--force-with-lease` rather than `--force`. It refuses when `origin/<branch>` has moved since your
last fetch, which is precisely the case where someone else pushed to the branch while you were
rebuilding. Plain `--force` would throw their commits away without a word.
