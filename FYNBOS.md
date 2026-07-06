# Fynbos fork maintenance

This is a fork of TigerBeetle that adds an **in-process testing client** and publishes a Go client
we can consume from services like the tiger proxy. This document is the entry point for maintaining
it.

## What this fork adds

Pinned to the **0.16.62** release (the version we run in production), on top of upstream:

1. **In-memory testing client** — a `tb_client` that bundles the *real* state machine with an
   in-memory, hashmap-backed forest. No networking, consensus, or persistence: it runs
   prepare/prefetch/commit in-process. Exposed via a new C ABI export, `tb_client_init_testing`.
   - `src/testing/memory_forest.zig` — the in-memory `Backend` (groove API + undo-log scopes).
   - `src/clients/c/tb_client/testing_client.zig` — the client itself.
   - `src/state_machine.zig` — a comptime `Backend` seam (default-preserving; production is
     unchanged).
2. **Go binding** — `NewTestingClient` in `src/clients/go/tb_client.go`, wired to
   `tb_client_init_testing`.
3. **Publish tooling** — `src/scripts/publish_go_fork.sh` (see below).

## Branch strategy

| Branch | What it is |
| --- | --- |
| `main` | Mirrors upstream. **Do not put fork changes here.** |
| `fynbos-0.16.62` | The 0.16.62 tag + our patches. **This is our production line — build and deploy from here.** |

The same split exists in the Go module repo (`fynbosmoney/tigerbeetle-go`): its `main` tracks
upstream; our pinned client lives on a version branch + tag.

Do **not** merge `fynbos-0.16.62` into `main` — `main` is ~1600 commits ahead (a newer TigerBeetle),
and the patch only compiles against 0.16.62's APIs. See "Upgrading" below.

## Using the testing client

### From Go (what the proxy does)

The Go client is published as a standalone, `go get`-able module. Consume the pinned tag:

```sh
go get github.com/fynbosmoney/tigerbeetle-go@v0.16.62-fynbos.1
```

```go
import (
    tb "github.com/fynbosmoney/tigerbeetle-go"
    "github.com/fynbosmoney/tigerbeetle-go/pkg/types"
)

// Networking/consensus/persistence are absent; `addresses` is ignored but must be
// syntactically valid.
client, err := tb.NewTestingClient(types.ToUint128(0), []string{"3000"})
defer client.Close()
// Use client.CreateAccounts / CreateTransfers / LookupAccounts / ... as normal.
```

cgo links the correct per-architecture static library from the module automatically — there is no
need to vendor anything into the consumer.

### From Zig / C (in this repo)

See the end-to-end test `test "tb_client testing state machine"` in `src/clients/c/test.zig`, and
`tb_client_init_testing` in `src/clients/c/tb_client_header.zig`.

## Publishing the Go client to `fynbosmoney/tigerbeetle-go`

The monorepo keeps the compiled native libraries (`pkg/native/*.a`) **gitignored** — they are build
artifacts, so the monorepo is *not* directly `go get`-able. The consumable artifact is the separate
`tigerbeetle-go` repo, where those libraries are committed. To (re)publish:

```sh
# From the fynbos-0.16.62 branch, with SSH access to fynbosmoney/tigerbeetle-go:
src/scripts/publish_go_fork.sh v0.16.62-fynbos.2   # use the next tag
```

The script:

1. Runs `./zig/zig build clients:go`, cross-compiling **all** architectures
   (linux/macos × x64/arm64, plus windows) into `pkg/native/`.
2. Clones `fynbosmoney/tigerbeetle-go`, replaces its content with our client source + the compiled
   libraries, and rewrites the module path to `github.com/fynbosmoney/tigerbeetle-go`.
3. Force-pushes an **orphan version branch** (`fynbos-0.16.62`) and pushes the **tag** you passed.
   The repo's `main` is never touched.

Consumers pin the **tag**. Bump the tag suffix (`-fynbos.N`) for each new publish.

Overridable via env: `GO_FORK_REPO`, `GO_FORK_MODULE`, `GO_FORK_BRANCH`.

## Verifying

```sh
# The testing client, end-to-end through the C ABI:
./zig/zig build test:unit -- "tb_client testing state machine"

# The production state machine is unaffected by the Backend seam:
./zig/zig build test:unit -- "state_machine"

# The Go binding:
cd src/clients/go && CGO_ENABLED=1 go test -run TestTestingClient ./

# Lint + format (must pass before committing):
./zig/zig build test:unit -- tidy
./zig/zig fmt --check src
```

## Upgrading to a newer TigerBeetle version

The patch is pinned to 0.16.62 because the state machine and client APIs drift between releases
(that drift is exactly what the backport works around). To move to a newer release `X.Y.Z`:

1. Branch off the new tag: `git checkout -b fynbos-X.Y.Z X.Y.Z`.
2. Re-apply the three fork commits (testing client, Go binding, publish script). Expect to adapt
   them to the new APIs — cherry-pick, resolve conflicts, and fix compile errors. The architecture
   (the `Backend` seam, the echo-client shape, the `ContextType` contract) is stable across
   versions, so this is a port, not a rewrite.
   - The `testing-client-latest` branch holds a version built against a ~0.17.x base and is a useful
     reference for what the newer APIs look like.
3. Re-run the verification steps above.
4. Publish with a matching tag: `src/scripts/publish_go_fork.sh vX.Y.Z-fynbos.1`
   (set `GO_FORK_BRANCH=fynbos-X.Y.Z`).

## Not included

Bindings for Python, Java, .NET, and Rust are not wired on this branch (only C and Go). The
`restamp-solo` dev helper lives on `testing-client-latest`, not here. Add them with the same
pattern if needed.
