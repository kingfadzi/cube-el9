#!/usr/bin/env bash
#
# Lab-side build & release script.
#
# Builds Cube.js from source on AlmaLinux 9 using the existing Dockerfile,
# extracts the prebuilt /cube-src tree (with native modules) plus the
# cubestored binary, publishes them as assets on a GitHub release, and pushes
# a slim runtime image to the configured registry.
#
# Required:
#   CUBE_VERSION      Cube.js git tag (e.g. v1.6.44). Required.
#   gh CLI on PATH; GitHub PAT in GITHUB_API_TOKEN (or GH_TOKEN / GITHUB_TOKEN)
#                     with `repo` scope.
#   docker logged in to $REGISTRY (SKIP_PUSH=1 to bypass).
#
# Optional env (defaults shown):
#   GH_REPO=kingfadzi/cube-el9
#   REGISTRY=docker.butterflycluster.com
#   REGISTRY_IMAGE=${REGISTRY}/cube/cube
#   BUILDER_IMAGE_NODE_22=docker.butterflycluster.com/builder-images/almalinux9-node:22
#   RUNTIME_BASE_IMAGE=${BUILDER_IMAGE_NODE_22}    # for the runtime image baked here
#   SKIP_PUSH=0                                     # set to 1 to skip docker push
#   SKIP_RELEASE=0                                  # set to 1 to skip gh release upload
#   AUTO_INIT_REPO=1                                # 0 to fail instead of seeding empty repo

set -euo pipefail

# --- env / defaults ---------------------------------------------------------

: "${CUBE_VERSION:?CUBE_VERSION is required (e.g. v1.6.44)}"
: "${GH_REPO:=kingfadzi/cube-el9}"
: "${REGISTRY:=docker.butterflycluster.com}"
: "${REGISTRY_IMAGE:=${REGISTRY}/cube/cube}"
: "${BUILDER_IMAGE_NODE_22:=docker.butterflycluster.com/builder-images/almalinux9-node:22}"
: "${RUNTIME_BASE_IMAGE:=${BUILDER_IMAGE_NODE_22}}"
: "${SKIP_PUSH:=0}"
: "${SKIP_RELEASE:=0}"
: "${AUTO_INIT_REPO:=1}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="${REPO_ROOT}/dist"

TAG="cube-${CUBE_VERSION}-el9"
RUNTIME_TAR="cube-runtime-${CUBE_VERSION}-el9.tar.gz"
CUBESTORED_BIN="cubestored-${CUBE_VERSION}-el9"
RUNTIME_IMAGE_TAG="${REGISTRY_IMAGE}:${CUBE_VERSION}-el9"
BUILDER_TAG="cube-builder:${CUBE_VERSION}"
RELEASE_BASE_URL="https://github.com/${GH_REPO}/releases/download"

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo ">>> $*"; }

# --- preflight (fail fast before the 30-min build) --------------------------

say "[0/6] Preflight"

[ -f "$REPO_ROOT/Dockerfile" ]         || die "missing $REPO_ROOT/Dockerfile"
[ -f "$REPO_ROOT/Dockerfile.runtime" ] || die "missing $REPO_ROOT/Dockerfile.runtime"
command -v docker >/dev/null           || die "docker not on PATH"
docker info >/dev/null 2>&1            || die "docker daemon unreachable"

if [ "$SKIP_RELEASE" != "1" ]; then
  command -v gh >/dev/null || die "gh CLI not on PATH (install or set SKIP_RELEASE=1)"
  export GH_TOKEN="${GH_TOKEN:-${GITHUB_API_TOKEN:-${GITHUB_TOKEN:-}}}"
  [ -n "$GH_TOKEN" ] || die "no GitHub token (set GITHUB_API_TOKEN, GH_TOKEN, or GITHUB_TOKEN)"

  # Repo must exist. Auto-seed if empty so `gh release create` works.
  if ! gh repo view "$GH_REPO" --json name >/dev/null 2>&1; then
    die "repo $GH_REPO not found or not accessible with this token"
  fi
  if ! gh api "/repos/${GH_REPO}/commits?per_page=1" >/dev/null 2>&1; then
    if [ "$AUTO_INIT_REPO" = "1" ]; then
      say "    repo $GH_REPO is empty, seeding with README to enable releases"
      readme=$(printf '# %s\n\nPrebuilt Cube.js artifacts (runtime tree + cubestored) for AlmaLinux 9 / RHEL 9. Releases are produced by build/build-release.sh.\n' "${GH_REPO##*/}" | base64 -w0)
      gh api -X PUT "/repos/${GH_REPO}/contents/README.md" \
        -f message="init: seed repo so releases can be created" \
        -f content="$readme" >/dev/null
    else
      die "repo $GH_REPO is empty — seed it with a commit, or set AUTO_INIT_REPO=1"
    fi
  fi
fi

if [ "$SKIP_PUSH" != "1" ]; then
  # Cheap auth probe: HEAD a non-existent manifest. 401/403 = not logged in,
  # 404 = logged in (or anonymous-readable). Anything else = registry up.
  reg_host="${REGISTRY_IMAGE%%/*}"
  if ! docker pull --quiet "${reg_host}/__preflight_does_not_exist__:nope" 2>&1 \
      | grep -qE "manifest unknown|not found|denied|repository does not exist"; then
    : # any of those responses prove auth works; other failures are fine to surface during push
  fi
fi

# --- prepare dist -----------------------------------------------------------

rm -rf "$DIST"
mkdir -p "$DIST"

# --- build ------------------------------------------------------------------

say "[1/6] Building builder stage ($BUILDER_TAG)"
docker build \
  --target builder \
  --build-arg BUILDER_IMAGE_NODE_22="$BUILDER_IMAGE_NODE_22" \
  --build-arg CUBE_VERSION="$CUBE_VERSION" \
  -f "$REPO_ROOT/Dockerfile" \
  -t "$BUILDER_TAG" \
  "$REPO_ROOT"

say "[2/6] Extracting /cube-src + cubestored"
CID=$(docker create "$BUILDER_TAG")
trap 'docker rm -f "$CID" >/dev/null 2>&1 || true' EXIT
docker cp "$CID:/cube-src" "$DIST/cube-src"

CUBESTORED_PATH="$DIST/cube-src/node_modules/@cubejs-backend/cubestore/downloaded/latest/bin/cubestored"
[ -f "$CUBESTORED_PATH" ] || die "cubestored not found at $CUBESTORED_PATH (Dockerfile cubestored fetch failed?)"
cp "$CUBESTORED_PATH" "$DIST/$CUBESTORED_BIN"
chmod +x "$DIST/$CUBESTORED_BIN"

say "[3/6] Packaging runtime tarball ($RUNTIME_TAR)"
# pigz parallelises gzip across cores; falls back to gzip if not installed.
if command -v pigz >/dev/null; then
  COMPRESS=(--use-compress-program "pigz -p $(nproc)")
else
  COMPRESS=(-z)
fi
tar "${COMPRESS[@]}" -cf "$DIST/$RUNTIME_TAR" -C "$DIST/cube-src" .
rm -rf "$DIST/cube-src"

say "[4/6] Generating SHA256SUMS"
( cd "$DIST" && sha256sum "$RUNTIME_TAR" "$CUBESTORED_BIN" > SHA256SUMS )
cat "$DIST/SHA256SUMS"

# --- release ----------------------------------------------------------------

if [ "$SKIP_RELEASE" = "1" ]; then
  say "[5/6] SKIP_RELEASE=1, skipping gh release upload"
else
  say "[5/6] Publishing GitHub release $TAG to $GH_REPO"
  if gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then
    echo "    release $TAG exists, reusing"
  else
    gh release create "$TAG" \
      --repo "$GH_REPO" \
      --title "Cube ${CUBE_VERSION} (EL9 prebuilt)" \
      --notes "Prebuilt Cube.js ${CUBE_VERSION} runtime tree and cubestored binary, compiled on AlmaLinux 9 / glibc 2.34. Binary-compatible with RHEL 9."
  fi
  gh release upload "$TAG" \
    --repo "$GH_REPO" \
    --clobber \
    "$DIST/$RUNTIME_TAR" \
    "$DIST/$CUBESTORED_BIN" \
    "$DIST/SHA256SUMS"
fi

# --- runtime image ----------------------------------------------------------

say "[6/6] Building runtime image $RUNTIME_IMAGE_TAG (pulls from $RELEASE_BASE_URL)"
# Pass the tarball sha to bust BuildKit's cache when the asset content
# changes under an unchanged URL, and to verify the download in-image.
TARBALL_SHA256=$(awk -v t="$RUNTIME_TAR" '$2 == t {print $1}' "$DIST/SHA256SUMS")
[ -n "$TARBALL_SHA256" ] || die "could not extract sha for $RUNTIME_TAR from SHA256SUMS"
docker build \
  -f "$REPO_ROOT/Dockerfile.runtime" \
  --build-arg RUNTIME_BASE_IMAGE="$RUNTIME_BASE_IMAGE" \
  --build-arg CUBE_VERSION="$CUBE_VERSION" \
  --build-arg RELEASE_BASE_URL="$RELEASE_BASE_URL" \
  --build-arg RUNTIME_TARBALL_SHA256="$TARBALL_SHA256" \
  -t "$RUNTIME_IMAGE_TAG" \
  "$REPO_ROOT"

if [ "$SKIP_PUSH" = "1" ]; then
  say "SKIP_PUSH=1, skipping docker push"
else
  say "Pushing $RUNTIME_IMAGE_TAG"
  docker push "$RUNTIME_IMAGE_TAG"
fi

say "Done."
echo "    Release : https://github.com/${GH_REPO}/releases/tag/${TAG}"
echo "    Image   : ${RUNTIME_IMAGE_TAG}"
