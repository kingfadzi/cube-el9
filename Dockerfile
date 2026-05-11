# LAB-ONLY: extract prebuilt /cube from the official cubejs/cube image.
#
# Invoked exclusively by build/build-release.sh in the lab. The script does
# `docker build --target builder` then `docker create` + `docker cp` to pull
# `/cube-src` out, packages it as a GitHub release asset, and bakes the
# on-prem image from Dockerfile.runtime.
#
# We use the upstream image as the source of truth so the workspace
# TypeScript packages are already compiled (the from-source / yarn install
# --prod path skips that). Native modules are compiled against Debian glibc
# 2.36; verified to also load on AlmaLinux 9 / RHEL 9 (glibc 2.34).
#
# Build (lab):
#   CUBE_VERSION=v1.6.44 ./build/build-release.sh

ARG CUBE_VERSION=v1.6.44

# ---------- builder ----------
# Rename /cube → /cube-src to keep the contract build-release.sh expects.
FROM cubejs/cube:${CUBE_VERSION} AS builder
RUN mv /cube /cube-src
CMD ["true"]

# ---------- runtime ----------
# Not used by the on-prem flow (Dockerfile.runtime handles that). Present so
# `docker build` without --target produces a valid image.
FROM cubejs/cube:${CUBE_VERSION}
