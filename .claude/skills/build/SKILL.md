---
name: build
description: Build the speech-swift package (release or debug). Use when preparing for testing, benchmarking, or running demos.
disable-model-invocation: false
argument-hint: [release|debug]
allowed-tools: Bash
---

# Build

Build the package in the specified configuration. Default: release.

```bash
config="${ARGUMENTS:-release}"
export https_proxy=http://127.0.0.1:7890
export http_proxy=http://127.0.0.1:7890
if [ "$config" = "debug" ]; then
  make debug
else
  make build
fi
```

The metallib step compiles MLX Metal shaders. Without it, inference runs ~5x slower due to JIT compilation. `make build` handles this automatically.

## Network: three separate channels, three different fixes

A rebase rewrites `Package.swift`, so the build re-resolves dependencies and downloads. Three distinct
mechanisms are involved and they do **not** share proxy settings — fixing one does nothing for the
others. Each has cost real hours here, so check them in this order.

### 1. Dependency fetches (git) — needs the environment variables

SwiftPM fetches inside `.build/repositories/*`. Those clones carry their own git config and do **not**
inherit this repo's `http.proxy`, so they dial github.com directly. Every fetch then stalls about 35
seconds and the build dies with `Couldn't fetch updates from remote repositories` — before compiling
anything, which makes it look like a broken merge rather than a network problem.

The `export` lines above fix it. A `git config --global http.proxy http://127.0.0.1:7890` also works
and is more durable, since it reaches every clone no matter how it was spawned.

### 2. Large repositories — use the mirror, not the proxy

A working proxy is still not enough for big repositories; transfers die mid-pack:

```
fatal: early EOF
```

Measured on `ml-explore/mlx-swift-lm`: direct through the proxy hung indefinitely and eventually
failed; through the mirror it resolved in **0.62s**. Prefix the github URL with `https://git.cangqian.uk/`:

```bash
# repoint every cached dependency clone at the mirror
for d in ~/Library/Caches/org.swift.swiftpm/repositories/*/; do
  url=$(git -C "$d" remote get-url origin 2>/dev/null) || continue
  case "$url" in
    https://git.cangqian.uk/*) ;;
    https://github.com/*) git -C "$d" remote set-url origin "https://git.cangqian.uk/$url" ;;
  esac
done
```

### 3. Binary artifacts — the proxy does not apply at all

`.binaryTarget` entries declared with a `url:` (here, `SpeechCore.xcframework.zip`) are downloaded by
SwiftPM through `URLSession`, which reads **only the macOS system proxy** — never `https_proxy` or
`http_proxy`. When system proxies are off (`scutil --proxy` shows `HTTPSEnable 0`), it connects
directly and the build parks on `Downloading binary artifact …` with no error and no progress. The
git settings from 1 and 2 are irrelevant to this step, which is what makes it confusing: those fix
the earlier failures, then the build advances and wedges somewhere new.

Don't fight the downloader — fetch the file yourself and drop it into the artifacts cache:

```bash
U="https://github.com/OWNER/REPO/releases/download/TAG/FILE.zip"       # from Package.swift
DEST=~/Library/Caches/org.swift.swiftpm/artifacts/$(printf '%s' "$U" | tr -c 'A-Za-z0-9' '_')
curl -sSL -x http://127.0.0.1:7890 -o "$DEST" "https://git.cangqian.uk/$U"
shasum -a 256 "$DEST"                                                   # must match checksum: in Package.swift
```

The cache filename is the URL with every non-alphanumeric character replaced by `_` (use `printf`,
not `echo` — a trailing newline becomes a trailing `_` and the file is ignored). Always verify the
SHA-256 against the `checksum:` in the `.binaryTarget`; on a mismatch SwiftPM silently re-downloads
and you are back where you started.

### Diagnosing a stall

All three look alike from the outside — near-zero CPU, no progress — but the last log line identifies
which one you have:

| Last log line | Cause |
|---|---|
| `Couldn't fetch updates from remote repositories` | git fetch, no proxy (1) |
| Hangs after `Updated …`, no `[N/M]` markers | large repo, `early EOF` (2) |
| `Downloading binary artifact …`, no progress | URLSession, system proxy off (3) |

A stalled SwiftPM process never recovers on its own. Kill it before retrying.
