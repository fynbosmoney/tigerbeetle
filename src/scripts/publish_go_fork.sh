#!/usr/bin/env bash
#
# Publish the Go client from this monorepo fork to a standalone, `go get`-able module repo
# (default: fynbosmoney/tigerbeetle-go), with the compiled per-arch native libraries committed.
#
# The monorepo keeps `pkg/native/*.a` gitignored (they are build artifacts), so the monorepo is
# NOT consumable by Go directly. This script builds all architectures, assembles the client into
# the standalone repo, rewrites the module path to the fork, force-adds the native blobs, and
# tags + pushes. Consumers then `require` the tag.
#
# Usage:
#   src/scripts/publish_go_fork.sh <tag>
# Example:
#   src/scripts/publish_go_fork.sh v0.16.62-fynbos.1
#
# The published module's `main` is left untouched (it tracks upstream and is a newer version).
# The pinned 0.16.62 content goes on its own branch + tag; consumers pin the tag. The branch is an
# orphan (clean, single commit) and is force-pushed since it is regenerated on every publish.
#
# Environment overrides:
#   GO_FORK_REPO      push target      (default: the fynbosmoney/tigerbeetle-go SSH remote)
#   GO_FORK_MODULE    go module path   (default: github.com/fynbosmoney/tigerbeetle-go)
#   GO_FORK_BRANCH    branch to push   (default: fynbos-0.16.62)

set -euo pipefail

TAG="${1:?usage: publish_go_fork.sh <tag>  (e.g. v0.16.62-fynbos.1)}"
REPO="${GO_FORK_REPO:-git@github.com:fynbosmoney/tigerbeetle-go.git}"
MODULE="${GO_FORK_MODULE:-github.com/fynbosmoney/tigerbeetle-go}"
BRANCH="${GO_FORK_BRANCH:-fynbos-0.16.62}"
UPSTREAM_MODULE="github.com/tigerbeetle/tigerbeetle-go"

monorepo_root="$(git rev-parse --show-toplevel)"
go_client="$monorepo_root/src/clients/go"
sha="$(git -C "$monorepo_root" rev-parse --short HEAD)"

# 1. Cross-compile every architecture into pkg/native (also regenerates the header and bindings).
echo "==> Building Go client for all architectures..."
(cd "$monorepo_root" && ./zig/zig build clients:go)

# 2. Clone the target repo into a scratch dir.
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
dest="$workdir/repo"
echo "==> Cloning $REPO..."
git clone --depth 1 "$REPO" "$dest"

# 3. Replace the repo's content (keeping .git) with the tracked client source + native blobs.
echo "==> Assembling module contents..."
find "$dest" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
(cd "$go_client" && git ls-files) | while read -r file; do
  mkdir -p "$dest/$(dirname "$file")"
  cp "$go_client/$file" "$dest/$file"
done
mkdir -p "$dest/pkg/native"
cp "$go_client"/pkg/native/*.a "$go_client"/pkg/native/*.lib "$dest/pkg/native/"

# 4. Rewrite the module path from the upstream path to the fork path, everywhere it appears.
echo "==> Rewriting module path to $MODULE..."
grep -rl "$UPSTREAM_MODULE" "$dest" | while read -r file; do
  sed -i "s|$UPSTREAM_MODULE|$MODULE|g" "$file"
done

cat >"$dest/README.md" <<EOF
# tigerbeetle-go (fynbos fork)

Auto-generated from fynbosmoney/tigerbeetle@$sha. Do not edit by hand; run
\`src/scripts/publish_go_fork.sh\` in the monorepo fork instead.
EOF

# 5. Commit to an orphan branch, tag, and push. `main` on the remote is not touched.
echo "==> Committing and pushing $BRANCH + $TAG..."
cd "$dest"
git checkout --orphan "$BRANCH"
git add -A
git add --force pkg/native # Native libs are gitignored but must ship in the published module.
git commit -m "Release $TAG (from fynbosmoney/tigerbeetle@$sha)"
git tag "$TAG"
git push --force origin "$BRANCH"
git push origin "$TAG"

echo "==> Published $MODULE@$TAG"
echo "    Consume it with: go get $MODULE@$TAG"
