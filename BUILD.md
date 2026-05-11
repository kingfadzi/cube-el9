# cube-el9 — build & deploy

Prebuilt Cube.js for AlmaLinux 9 / RHEL 9.

Lab cuts a release tarball; on-prem rebuilds the runtime image against the
blessed RHEL UBI 9 base, pulling the same tarball from the GitHub release.

## Prereqs

**Lab** (this repo's working tree, AlmaLinux 9 + internet):
- `docker`, `pigz`, `gh` (`dnf -y install gh` if missing)
- `GITHUB_API_TOKEN` (or `GH_TOKEN`) with `repo` scope
- `docker login docker.butterflycluster.com`

**On-prem** (RHEL 9):
- `docker compose`
- Reachability to GitHub releases (the runtime image is built locally against the blessed RHEL UBI 9 base — the lab's AlmaLinux-based image is **not** consumed on-prem)
- Pull access to your on-prem registry for the RHEL UBI 9 base image
- Postgres reachable from the docker host

## Lab — cut a release

```bash
cd <this repo>
CUBE_VERSION=v1.6.44 ./build/build-release.sh
```

Takes ~10 min. Produces:
- GH release `cube-v1.6.44-el9` on `kingfadzi/cube-el9` with `cube-runtime-*.tar.gz`, `cubestored-*`, `SHA256SUMS` — **this is what on-prem consumes**.
- Image `docker.butterflycluster.com/cube/cube:v1.6.44-el9` pushed to your registry — lab convenience only (AlmaLinux 9 base; not for on-prem).

Useful flags:
```bash
SKIP_PUSH=1     CUBE_VERSION=v1.6.44 ./build/build-release.sh   # build, no registry push
SKIP_RELEASE=1  CUBE_VERSION=v1.6.44 ./build/build-release.sh   # build, no GH upload
```

## On-prem — first-time setup

```bash
git clone https://github.com/kingfadzi/cube-el9.git
cd cube-el9
cp .env.example .env
$EDITOR .env   # see below
```

Edit `.env`:
```ini
RUNTIME_BASE_IMAGE=registry.onprem.example.com/builder-images/rhel9-node:22
CUBE_VERSION=v1.6.44
RELEASE_BASE_URL=https://github.com/kingfadzi/cube-el9/releases/download

CUBEJS_API_SECRET=$(openssl rand -hex 32)   # paste real value
CUBEJS_DEV_MODE=false

CUBEJS_DB_TYPE=postgres
CUBEJS_DB_HOST=db.onprem.internal
CUBEJS_DB_PORT=5432
CUBEJS_DB_NAME=cube
CUBEJS_DB_USER=cube
CUBEJS_DB_PASS=...
CUBEJS_DB_SSL=false

CUBESTORE_DATA_DIR=/cube/.cubestore
```

## On-prem — start cube

Build the runtime image against the blessed RHEL UBI 9 base (curls the
release tarball from GitHub, sha-verifies, extracts), then bring it up:
```bash
docker compose build cube
docker compose up -d cube
```

**Verify**:
```bash
docker compose ps
docker compose logs --tail=30 cube
curl -sI http://localhost:4000/        # 200
curl -s  http://localhost:4000/livez   # ok
```

Cube ports: `4000` (API + Playground), `15432` (Postgres-wire SQL), `3030` (Cube Store HTTP).

## Add data models

Drop `*.cube.js` / `*.yml` files into `conf/model/`. Bind-mounted into the
container at `/cube/conf/model`. Reloaded on cube restart (or live in dev).

## Bump cube version

Lab:
```bash
CUBE_VERSION=v1.6.45 ./build/build-release.sh
```

On-prem:
```bash
sed -i 's/^CUBE_VERSION=.*/CUBE_VERSION=v1.6.45/' .env
docker compose build cube && docker compose up -d cube
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| `cubestored ... LOCK: Resource temporarily unavailable` | `docker compose down cube && docker volume rm webaapps_cubestore_data && docker compose up -d cube` |
| `pull access denied for local/cube` warning | Cosmetic. `docker compose up` tries pull before falling back to build. Run `docker compose build cube` first to silence it. |
| `Repository is empty` from `gh release create` | Script auto-seeds with a README if `AUTO_INIT_REPO=1` (default). Re-run. |
| Runtime image build hits HTTP 404 on tarball | Release didn't publish — check `gh release view cube-${CUBE_VERSION}-el9 --repo kingfadzi/cube-el9`. |
| Cube CLI says "Unavailable. Please run this command from project directory" | Container missing `CUBEJS_DOCKER_IMAGE_TAG`. Set in `.env` (already wired in `Dockerfile.runtime`). |

## File map

| Path | Used by | Notes |
|---|---|---|
| `Dockerfile` | lab | Passthrough from `cubejs/cube:${CUBE_VERSION}` — exposes `/cube-src` for `build-release.sh`. |
| `Dockerfile.runtime` | lab + on-prem | EL9 base + curl tarball from GH release + sha-verify against build-arg. |
| `build/build-release.sh` | lab | Orchestrates build → GH release → registry push. |
| `docker-compose.yml` | lab + on-prem | Service definition. |
| `.env.example` | each environment | Template; `.env` is per-environment and not committed. |
| `conf/` | each environment | Bind-mounted to `/cube/conf`; holds `cube.js` + `model/`. |
| `vendor/` | optional offline | Drop `cube-src.tar.gz` to skip GitHub fetch. |
