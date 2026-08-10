# docker-deployment

A **Docker Compose** replica of the single-node **k3s** stack in
`../k3s-deployment`: the shared backing services (Postgres/pgvector, MySQL,
Redis, RabbitMQ, MinIO, Qdrant, Meilisearch) plus every application (Plane,
cybernetics, Ghost, Gitea, Twenty, Vaultwarden, draw.io, main-website).

Everything runs as **one Compose project (`platform`)** assembled from
`compose.yaml`, which `include:`s a self-contained stack per directory. Each
stack can also be run on its own.

> Faithful port-for-port to the k3s cluster: host ports preserve the k3s
> **NodePort** numbers (30898, 30808, 30820, …) so the existing host **Caddy**
> reverse proxy (`admin.avarile.com`, `projects.avarile.com`) keeps working
> unchanged.

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
├── Makefile                ← up / down / infra / ps / logs / bootstrap …
├── .env                    ← shared knobs: DATA_ROOT, PUBLIC_IP, TZ  (gitignored)
├── .env.example
├── scripts/                ← reusable idempotent provisioners
│   ├── provision-postgres.sh   provision-mysql.sh
│   ├── provision-minio.sh      provision-rabbitmq.sh
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
- Ports free on the host (see §6). **If the k3s cluster is still running on this
  box, its NodePorts will collide** — stop the k3s workloads (or this stack) so
  only one owns each port. This project is intended to *replace* the k3s stack,
  not run alongside it.

---

## 4. Quick start

```bash
cd /home/avarile/dev-ops/docker-deployment

# 1. Shared knobs — set DATA_ROOT (absolute) and PUBLIC_IP (this host's address)
cp .env.example .env && $EDITOR .env

# 2. Credentials — either keep the provided .env files (already populated from
#    the k3s secrets) OR recreate them from templates:
#      cp infra/.env.example infra/.env && $EDITOR infra/.env
#      for a in ghost gitea twenty cybernetics plane vaultwarden; do
#        cp apps/$a/.env.example apps/$a/.env; done

# 3. One-time bring-up: create network + data dirs + start everything
make bootstrap

# 4. Watch it settle
make ps
make logs S=api
```

Common targets (`make help` lists all):

| Command | Effect |
|---|---|
| `make bootstrap` | create `backbone` network + `${DATA_ROOT}` dirs + `up` |
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

## 5. How apps reach infra

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

## 6. Port map (preserved from k3s NodePorts)

| Service | Host port → container | Service | Host port → container |
|---|---|---|---|
| pgvector | 30898 → 5432 | Plane (proxy) | **30808** → 80 |
| mysql | 30306 → 3306 | cybernetics | 30300 / 30301 |
| redis | 30490 → 6379 | Twenty | 30310 → 3000 |
| rabbitmq | 30672 / 31672 | Ghost | 30368 → 2368 |
| minio | 30900 / 30901 | Gitea | 30380 / 30722 |
| qdrant | 30333 / 30334 | Vaultwarden | 30820 → 80 |
| meilisearch | 30770 → 7700 | draw.io | 30880 → 8080 |
| | | main-website | 30587 → 9587 |

The host **Caddy** (`../caddy/Caddyfile`) already targets `127.0.0.1:30820`
(admin.avarile.com) and `127.0.0.1:30808` (projects.avarile.com); those keep
working unchanged.

---

## 7. Locally-built images (not on any registry)

Three services use images the k3s node imported into containerd — they are **not
pullable** and must exist in this host's Docker engine:

| Service | Image | Provide it via |
|---|---|---|
| cybernetics | `cybernetics:release.2026-06-10T04-05-13Z.1` | `docker load -i cybernetics.tar` or `docker build …` |
| Plane `web` | `cybernetics-project-web:release.2026-07-29T12-56-03Z.1` | `docker load` / `docker build`, or swap to `makeplane/web-commercial:v2.6.3` |
| main-website | `main-website:latest` | `docker build -t main-website:latest …` / `docker load` |

They use `pull_policy: never`, so a missing image fails loudly instead of
hitting a registry (same intent as the k8s `imagePullPolicy: Never`). To pull
the images off the running k3s node:
`sudo k3s ctr images export <name>.tar <ref>` → `docker load -i <name>.tar`.

---

## 8. Data & backup

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

## 9. Secrets

- Real credentials live in **gitignored `.env` files** (`.gitignore` blocks
  every `.env`, keeps every `.env.example`). Verify before committing:
  ```bash
  git status --porcelain | grep -E '/\.env$' && echo "STOP: .env staged" || echo clean
  ```
- Cross-references must stay consistent: an app's copy of an infra credential
  (composite URLs, `PROVISION_*`) must equal the value in `infra/.env`. Each
  `.env.example` flags exactly which keys those are.
- The provided `.env` files were populated from the running k3s secrets; rotate
  anything that has been exposed.

---

## 10. Teardown

```bash
make down                       # stop/remove containers (keeps data + network)
docker network rm backbone      # remove the shared network
rm -rf ./data                   # delete all data (irreversible)
```

---

## 11. Mapping to the k3s repo

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
| NodePort Service | host `ports:` (same numbers) |
| kubelet http/exec probe | Compose `healthcheck` (where the image has the tool) |
```
