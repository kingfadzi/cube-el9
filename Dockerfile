# LAB-ONLY: extract prebuilt /cube from the official cubejs/cube image,
# then rebuild EL9-incompatible native modules in an AL9 builder.
#
# Invoked exclusively by build/build-release.sh in the lab. The script does
# `docker build --target builder` then `docker create` + `docker cp` to pull
# `/cube-src` out, packages it as a GitHub release asset, and bakes the
# on-prem image from Dockerfile.runtime.
#
# Why two stages: upstream cubejs/cube ships /cube prebuilt on Debian.
# Most native modules (libc-only) work on EL9 (glibc 2.34 covers Debian
# baseline), but `duckdb.node` links GLIBCXX_3.4.30 (gcc 12+), which EL9
# base libstdc++ (gcc 11.5 / 6.0.29) does not provide. We rebuild duckdb
# from source on AL9 so it links against EL9 libstdc++. Other native
# modules link only against glibc and keep working unchanged.
#
# Build (lab):
#   CUBE_VERSION=v1.6.44 ./build/build-release.sh

ARG CUBE_VERSION=v1.6.44
ARG BUILDER_IMAGE_NODE_22

# ---------- upstream tree ----------
FROM cubejs/cube:${CUBE_VERSION} AS upstream

# ---------- builder: rebuild EL9-incompatible native modules ----------
FROM ${BUILDER_IMAGE_NODE_22} AS builder
COPY --from=upstream /cube /cube-src

# duckdb is the only known offender today. Add others here if found.
# The build-time guard fails the release if duckdb still emits a
# GLIBCXX_3.4.30+ symbol -- catches regressions in the lab, not on prem.
RUN dnf -y install --setopt=install_weak_deps=False gcc-c++ make python3 \
 && dnf clean all \
 && cd /cube-src/node_modules/duckdb \
 && rm -rf lib/binding build \
 && npm_config_build_from_source=true npm rebuild \
 && if strings -a lib/binding/duckdb.node | grep -qE '^GLIBCXX_3\.4\.3[0-9]'; then \
      echo "duckdb.node still requires GLIBCXX_3.4.30+ after rebuild" >&2; \
      strings -a lib/binding/duckdb.node | grep '^GLIBCXX' | sort -u >&2; \
      exit 1; \
    fi
CMD ["true"]

# ---------- runtime ----------
# Not used by the on-prem flow (Dockerfile.runtime handles that). Present so
# `docker build` without --target produces a valid image.
FROM cubejs/cube:${CUBE_VERSION}
