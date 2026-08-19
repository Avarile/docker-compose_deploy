# docker-deployment

A **Docker Compose** replica of the single-node **k3s** stack in
`../k3s-deployment`: the shared backing services (Postgres/pgvector, MySQL,
Redis, RabbitMQ, MinIO, Qdrant, Meilisearch) plus every application (Plane,
cybernetics, Ghost, Gitea, Twenty, Vaultwarden, draw.io, main-website).

Everything runs as **one Compose project (`platform`)** assembled from
`compose.yaml`, which `include:`s a self-contained stack per directory. Each
stack can also be run on its own.

> Faithful port-for-port to the k3s cluster: host ports preserve the k3s
> **NodePort** numbers (30898, 30808, 30820, …), and every one of them is
> **loopback-only** (`127.0.0.1:<port>`) except Gitea SSH and the MinIO API
> (see §7) — a host **Caddy** reverse proxy is the only intended public
> entrypoint, same as the source k3s cluster's Caddyfile.

---

## 1. Architecture

```
                         ┌──────────── docker network: backbone ────────────┐
   Internet / LAN  ───►  │  (external, shared by every stack)                │
   (host Caddy →         │                                                   │
    127.0.0.1:30xxx)     │  ┌─ infra ─────────────────────────────────────┐ │
                         │  │ pgvector  mysql  redis  rabbitmq             │ │
                         │  │ minio     qdrant meilisearch                 │ │
                         │  │ aliases: plane-db/redis/mq/minio ────────────┤ │
                         │  └───────────────────▲──────────────────────────┘ │
                         │   apps reach infra by service name / alias         │
                         │  ┌─ plane (13 svc + init + migrator, :30808) ─┐    │
                         │  ┌─ cybernetics :30300/30301 ┐ ┌─ twenty :30310 ┐  │
                         │  ┌─ ghost :30368 ┐ ┌─ gitea :30380/30722 ┐         │
                         │  ┌─ vaultwarden :30820 ┐ ┌─ drawio :30880 ┐        │
                         │  └─ main-website :30587 ┘                          │
                         └────────────────────────────────────────────────────┘
```

- **Networking:** one **external** bridge network `backbone`. Service names
  match the k8s Service names, so app connection strings line up. Plane's stock
  hostnames (`plane-db`, `plane-redis`, `plane-mq`, `plane-minio`) are **network
  aliases** on the infra services — the Compose equivalent of the k8s
  `ExternalName` services.
- **Exposure:** every published port binds to `127.0.0.1` — nothing is reachable
  off-host except through the host Caddy — with exactly two exceptions: Gitea
  SSH (`30722`, git+ssh doesn't route through Caddy) and the MinIO API
  (`30900`, cybernetics hands out presigned URLs built from it directly to
  browsers). See §7.
- **Storage:** every stateful service **bind-mounts** a directory under
  `${DATA_ROOT}` (default `./data`), mirroring the k3s `~/k3s-data/<svc>` layout
  so the same backup/rsync workflow applies.
- **Provisioning:** per-app one-shot `*-init` services create the dedicated
  databases / buckets / vhosts (idempotent), replacing the k8s init-Jobs. Apps
  `depends_on` their init completing.

---

## 2. Layout

```
docker-deployment/
├── compose.yaml            ← root: include: every stack (one `platform` project)
├── Makefile                ← up / down / infra / ps / logs / bootstrap / secrets …
├── .env                    ← shared knobs: DATA_ROOT, PUBLIC_IP, TZ  (gitignored)
├── .env.example
├── scripts/
│   ├── provision-postgres.sh   provision-mysql.sh      ← idempotent DB/bucket provisioners
│   ├── provision-minio.sh      provision-rabbitmq.sh
│   ├── generate-secrets.sh     ← fresh random .env files for a NEW deployment
│   └── publish-custom-images.sh ← one-time: push the 3 custom images to the registry
├── infra/
│   ├── compose.yaml        ← the 7 backing services (+ plane-* aliases)
│   ├── .env  / .env.example ← infra credentials
└── apps/
    ├── vaultwarden/  drawio/  main-website/
    ├── ghost/  gitea/            ← MySQL-backed (init creates db + user)
    ├── twenty/  cybernetics/     ← pgvector + redis + minio (init db + bucket)
    └── plane/                    ← 13 svc + init + migrator (plane-config.env + .env)
```

Each stack has: `compose.yaml`, a **gitignored `.env`** with real credentials,
and a tracked **`.env.example`** template. Plane additionally has a tracked,
non-secret `plane-config.env` (the old ConfigMap).

---

## 3. Prerequisites

- Docker Engine + Compose v2 (**v2.20+**, for `include:`).
- Ports free on the host (see §7). **If a k3s cluster serving the same apps is
  running on this box, its NodePorts will collide** — stop the k3s workloads
  (or this stack) so only one owns each port. This project is intended to
  *replace* a k3s deployment on a given host, not run alongside it there.
- One-time `docker login gitea.avarile.com -u registry-bot` on any host that
  will `docker compose pull` — three images (cybernetics, Plane's `web`,
  main-website) live only on the private Gitea registry, not a public one
  (see §8).

---

## 4. Quick start (this host)

```bash
cd /home/avarile/dev-ops/docker-deployment

# 1. Shared knobs — set DATA_ROOT (absolute) and PUBLIC_IP (this host's address)
cp .env.example .env && $EDITOR .env

# 2. Registry login (needed to pull the 3 custom images — see §8)
docker login gitea.avarile.com -u registry-bot

# 3. Credentials — the provided .env files already work (copied from the k3s
#    secrets this stack replicates). For a genuinely new deployment, generate
#    an independent set instead — see §5.

# 4. One-time bring-up: create network + data dirs + start everything
make bootstrap

# 5. Watch it settle
make ps
make logs S=api
```

Common targets (`make help` lists all):

| Command | Effect |
|---|---|
| `make bootstrap` | create `backbone` network + `${DATA_ROOT}` dirs + `up` |
| `make secrets` | generate fresh `.env` files for a new deployment (§5) |
| `make up` / `make down` | start / stop the whole platform |
| `make infra` | bring up only the 7 backing services |
| `make ps` | status of every service |
| `make logs [S=<svc>]` | follow logs (all, or one service) |
| `make config` | validate the merged Compose model |
| `make pull` | pull all registry images |

Run a single stack standalone (advanced):

```bash
docker compose -f infra/compose.yaml --env-file .env --env-file infra/.env up -d
```

---

## 5. Deploying to a new host

This repo's real `.env` files are copies of this host's live production
credentials (see §9) — reusing those exact secrets on a separate machine
isn't good practice. For a new deployment:

```bash
git clone <this-repo> && cd docker-deployment

# registry login — required to pull cybernetics / Plane web / main-website
docker login gitea.avarile.com -u registry-bot

# shared knobs for the NEW host
cp .env.example .env && $EDITOR .env      # set DATA_ROOT, PUBLIC_IP, TZ

# fresh, independent secrets — resolves every infra cross-reference
# automatically (see the header of scripts/generate-secrets.sh)
make secrets

# review what got generated, then bring it up
make bootstrap
```

`make secrets` refuses to overwrite an existing `.env` — pass `FORCE=1` to
regenerate everything from scratch (`make secrets FORCE=1`).

---

## 6. How apps reach infra

| App | Database | Cache | Object store | Search |
|---|---|---|---|---|
| **Plane** | pgvector: role/db `plane` (via `plane-db`) | redis DB **1** (`plane-redis`) | minio bucket `plane-uploads` (`plane-minio`) | — |
| **Twenty** | pgvector: db `twenty` | redis DB **3** | minio bucket `twenty` | — |
| **cybernetics** | pgvector: db `cybernetics` + `cybernetics_embedding` | redis DB **0** | minio buckets `public` + `private` | — |
| **Ghost** | mysql: db `ghost` | — | — | — |
| **Gitea** | mysql: db `gitea` | — | — | — |

All dedicated databases / buckets / vhosts are created automatically by the
`*-init` services on first `up` (idempotent — safe to re-run).

---

## 7. Port map (preserved from k3s NodePorts)

| Service | Host port → container | Exposure | Service | Host port → container | Exposure |
|---|---|---|---|---|---|
| pgvector | 30898 → 5432 | loopback | Plane (proxy) | **30808** → 80 | loopback |
| mysql | 30306 → 3306 | loopback | cybernetics | 30300 / 30301 | loopback |
| redis | 30490 → 6379 | loopback | Twenty | 30310 → 3000 | loopback |
| rabbitmq | 30672 / 31672 | loopback | Ghost | 30368 → 2368 | loopback |
| minio | 30900 (API) | **public** | Gitea | 30380 → 3000 | loopback |
| minio | 30901 (console) | loopback | Gitea SSH | 30722 → 22 | **public** |
| qdrant | 30333 / 30334 | loopback | Vaultwarden | 30820 → 80 | loopback |
| meilisearch | 30770 → 7700 | loopback | draw.io | 30880 → 8080 | loopback |
| | | | main-website | 30587 → 9587 | loopback |

Everything marked **loopback** binds `127.0.0.1:<port>:<container-port>` — only
processes on this host (namely Caddy) can reach it. The two **public**
exceptions: Gitea's SSH port (git+ssh doesn't go through Caddy) and MinIO's
API port (cybernetics builds browser-facing presigned URLs from
`${PUBLIC_IP}:30900`, so it must be reachable from outside the host).

The host **Caddy** (`../caddy/Caddyfile`) already targets `127.0.0.1:30820`
(admin.avarile.com), `127.0.0.1:30808` (projects.avarile.com), and the rest of
the app domains at their respective loopback ports; those keep working
unchanged.

---

## 8. Images & the private registry

Every image is pinned to a specific tag and pullable — either from its public
registry (Docker Hub, etc.) or from the private Gitea registry
(`gitea.avarile.com/registry-bot/`, see `../k3s-deployment/supports/25-image-registry/`),
which mirrors every image this stack uses, including three **custom-built**
ones that don't exist anywhere public:

| Service | Image |
|---|---|
| cybernetics | `gitea.avarile.com/registry-bot/cybernetics:release.2026-06-10T04-05-13Z.1` |
| Plane `web` | `gitea.avarile.com/registry-bot/cybernetics-project-web:release.2026-07-29T12-56-03Z.1` |
| main-website | `gitea.avarile.com/registry-bot/main-website:latest` |

A fresh host just needs `docker login gitea.avarile.com -u registry-bot` (see
§3) before `docker compose pull` / `make pull` — no local `docker build` or
`docker load` required.

If any of these three images needs to be (re-)published — e.g. after a new
release — run `scripts/publish-custom-images.sh` **on the k3s node** (it
exports images from k3s's containerd where needed, tags them, and pushes to
the registry). It needs interactive sudo + the `registry-bot` push token, so
it's meant to be run by hand, not automated.

---

## 9. Data & backup

All persistent data lives under `${DATA_ROOT}` (default `./data`), one
subdirectory per service — the same shape as `~/k3s-data`. Back up / migrate by
`rsync`-ing that tree while the stack is stopped:

```bash
make down
rsync -avz ./data/  user@newhost:/path/to/docker-deployment/data/
```

To seed from the existing k3s volumes, copy each `~/k3s-data/<svc>` into the
matching `data/<svc>` before the first `up`.

---

## 10. Secrets

- Real credentials live in **gitignored `.env` files** (`.gitignore` blocks
  every `.env`, keeps every `.env.example`). Verify before committing:
  ```bash
  git status --porcelain | grep -E '/\.env$' && echo "STOP: .env staged" || echo clean
  ```
- Cross-references must stay consistent: an app's copy of an infra credential
  (composite URLs, `PROVISION_*`) must equal the value in `infra/.env`. Every
  such key in every `.env.example` is tagged `CHANGE_ME_equals_infra_<KEY>`.
  `scripts/generate-secrets.sh` (`make secrets`) resolves these automatically
  — prefer it over hand-filling.
- The provided `.env` files in this repo were populated from the running k3s
  secrets. For a deployment on a different host, generate independent secrets
  instead — see §5.

---

## 11. Teardown

```bash
make down                       # stop/remove containers (keeps data + network)
docker network rm backbone      # remove the shared network
rm -rf ./data                   # delete all data (irreversible)
```

---

## 12. Mapping to the k3s repo

| k3s concept | here |
|---|---|
| namespace `infra` | `infra/compose.yaml` |
| namespace per app | `apps/<name>/compose.yaml` |
| Secret (`secret.yaml`) | gitignored `.env` |
| ConfigMap | `environment:` / `plane-config.env` |
| `ExternalName` alias | network `aliases:` on the infra service |
| init-Job | `*-init` one-shot service + `scripts/provision-*.sh` |
| Plane migrator Job | `migrator` service (`restart: "no"`) |
| hostPath PV/PVC | bind mount under `${DATA_ROOT}` |
| NodePort Service | host `ports:` (same numbers, now loopback-bound — see §7) |
| kubelet http/exec probe | Compose `healthcheck` (where the image has the tool) |
