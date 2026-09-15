# Woow_k3s_odoo — Odoo 18 Helm Chart for K3s/Kubernetes

[繁體中文](README_zh-TW.md)

Helm chart deploying [Odoo 18](https://www.odoo.com) Community Edition on
K3s/Kubernetes, backed by a PostgreSQL 16 with `pgvector` StatefulSet.

This chart is **not** currently used for any of WOOWTECH's live per-tenant
Odoo deployments — those stay on plain `kubectl apply` manifests. It is a
standalone chart for single-tenant Odoo installs.

> **Looking for another platform?**
> Docker/Podman Compose → [Woow_podman_odoo](https://github.com/WOOWTECH/Woow_podman_odoo) ·
> Home Assistant add-on → [Woow_ha_odoo](https://github.com/WOOWTECH/Woow_ha_odoo)

## Architecture

| Component | Image | Service | NodePort |
|---|---|---|---|
| Odoo | `odoo:18` | `odoo:8069` | `31806` |
| PostgreSQL | `pgvector/pgvector:pg16` | `db:5432` | (ClusterIP only) |

| Template | Objects | Toggle |
|---|---|---|
| `templates/namespace.yaml` | Namespace `namespace.name`, only when it differs from the release namespace | `namespace.create` |
| `templates/configmap.yaml` | ConfigMap `odoo-config` (HOST/PORT/odoo.conf — no admin_passwd) | always |
| `templates/secrets.yaml` | `odoo-db-secret`, `odoo-secrets` (admin_passwd) | `secrets.create` |
| `templates/pvc.yaml` | 4 PVCs (db data, web data, addons, unused config) | always |
| `templates/postgres-statefulset.yaml`, `postgres-service.yaml` | StatefulSet `db`, Service `db:5432` | always |
| `templates/odoo-deployment.yaml`, `odoo-service.yaml` | Deployment `odoo`, Service `odoo` | always |
| `templates/tests/smoke.yaml` | `helm test` pod | `tests.enabled` |

- Storage: four PVCs, default StorageClass `local-path` (odoo data 10Gi,
  addons 5Gi, unused config 100Mi, postgres data 10Gi)
- Odoo runs single-replica with `Recreate` strategy (the filestore is a
  `ReadWriteOnce` PVC)
- Odoo waits for PostgreSQL via an init container before starting; a second
  init container combines the non-secret `odoo.conf` with `admin_passwd` from
  a Secret before Odoo starts (see [Secrets](#secrets) below)
- Pod-level `fsGroup: 101` so the Odoo container (a fixed non-root user in the
  upstream image) can write its volumes on any StorageClass, not only
  `local-path` (which happens to create world-writable volumes)

## Secrets

Two Secrets, referenced by name and never derived from the release name:

| Secret | Keys | Used by |
|---|---|---|
| `odoo-db-secret` | `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB` | Postgres `envFrom`, Odoo `USER`/`PASSWORD` env |
| `odoo-secrets` | `ADMIN_PASSWD` (Odoo's database-manager master password) | the `render-odoo-conf` init container, which appends `admin_passwd = ...` to `odoo.conf` on an emptyDir before Odoo starts |

`secrets.create` defaults to **false**: the chart only references these two
Secrets by name, so `helm upgrade` can never overwrite a real password with an
empty one. Create them yourself first (see
[`examples/secrets.example.yaml`](examples/secrets.example.yaml)):

```bash
kubectl create namespace odoo
cp examples/secrets.example.yaml /secure/path/secrets.yaml   # fill every REPLACE_ME
kubectl apply -f /secure/path/secrets.yaml
helm install odoo . -n odoo
```

Neither `POSTGRES_PASSWORD` nor `ADMIN_PASSWD` ever has a default or a
placeholder value in `values.yaml`. With `secrets.create=true` (fresh installs
and tests), both are `required()` — the install fails loudly instead of
starting with a guessable password.

## Quick start

### A. Secrets managed outside Helm (default, recommended)

```bash
git clone https://github.com/WOOWTECH/Woow_k3s_odoo.git && cd Woow_k3s_odoo
kubectl create namespace odoo
cp examples/secrets.example.yaml /secure/path/secrets.yaml   # fill every REPLACE_ME
kubectl apply -f /secure/path/secrets.yaml
helm install odoo . -n odoo
```

### B. Let the chart create the Secrets

```bash
helm install odoo https://github.com/WOOWTECH/Woow_k3s_odoo/archive/refs/heads/main.tar.gz \
  -n odoo --create-namespace \
  --set secrets.create=true \
  --set secrets.postgresPassword="$(openssl rand -hex 24)" \
  --set secrets.adminPasswd="$(openssl rand -hex 24)"
```

Every later `helm upgrade` needs the same `--set secrets.create=true ...`
flags (or a values file with them). Without it, the `required()` checks stop
the upgrade; the passwords are never silently blanked.

### C. Test install (own namespace, disposable storage)

```bash
NS=ht-odoo
helm install odoo . -n $NS --create-namespace \
  --set namespace.name=$NS,namespace.create=false \
  --set odoo.persistence.data.storageClassName=longhorn-delete \
  --set odoo.persistence.addons.storageClassName=longhorn-delete \
  --set odoo.persistence.config.storageClassName=longhorn-delete \
  --set postgres.persistence.storageClassName=longhorn-delete \
  --set odoo.service.type=ClusterIP \
  --set secrets.create=true \
  --set secrets.postgresPassword="$(openssl rand -hex 16)" \
  --set secrets.adminPasswd="$(openssl rand -hex 16)"
```

### Then

```bash
kubectl -n odoo rollout status deploy/odoo --timeout=10m
helm test odoo -n odoo --logs
```

`helm test` creates a throwaway database (`smoketest`) through
`/web/database/create` using `ADMIN_PASSWD`, then confirms it is listed by
`/web/database/selector`. It can take a few minutes on modest hardware —
creating a database loads every base module.

## Key values

| Value | Default | Description |
|---|---|---|
| `namespace.create` / `namespace.name` | `true` / `odoo` | Target namespace; a Namespace equal to the release namespace (`-n`) is never rendered |
| `keepOnUninstall` | `true` | `helm.sh/resource-policy: keep` on the Namespace, every PVC and any chart-created Secret |
| `odoo.image.tag` | `18` | Odoo image tag |
| `odoo.service.type` / `nodePort` | `NodePort` / `31806` | How Odoo is exposed |
| `odoo.persistence.data.size` | `10Gi` | Filestore PVC size (`/var/lib/odoo`) |
| `odoo.persistence.addons.size` | `5Gi` | Custom addons PVC size |
| `odoo.config.odoo.conf` | see `values.yaml` | Non-secret contents of `/etc/odoo/odoo.conf` (no admin_passwd) |
| `odoo.podSecurityContext.fsGroup` | `101` | Lets the non-root Odoo user write PVCs on any StorageClass |
| `postgres.image.tag` | `pg16` | PostgreSQL + pgvector image tag |
| `postgres.persistence.size` | `10Gi` | Database data PVC size |
| `secrets.create` | `false` | Render `odoo-db-secret` / `odoo-secrets` from the values below instead of using existing ones |
| `secrets.postgresUser` / `postgresDb` | `odoo` / `postgres` | Not secret by themselves; live in the Secret with the password |
| `secrets.postgresPassword` / `adminPasswd` | `""` / `""` | Required when `secrets.create=true`; no default |
| `tests.enabled` | `true` | `helm test` smoke pod |

Full list: [`values.yaml`](values.yaml).

## Verify

```bash
kubectl get pods -n odoo                    # db and odoo pods Running/Ready
curl -sI http://<node-ip>:31806/web/login   # should return 200
helm test odoo -n odoo --logs
```

## Uninstall

```bash
helm uninstall odoo -n odoo
```

This removes the Deployment, StatefulSet, Services and ConfigMap. **Data
stays**: the Namespace, all 4 PVCs and any Secret this chart created carry
`helm.sh/resource-policy: keep` (`keepOnUninstall=true`). To really delete
everything, including the database and the filestore:

```bash
kubectl delete namespace odoo
```

## Migrating from the old Kustomize deployment

This repository replaces the `k3s` branch of the archived
[Woow_odoo_docker_compose_all](https://github.com/WOOWTECH/Woow_odoo_docker_compose_all)
repo (chart 1.0.0, rewritten 2026-08-05). Chart 1.1.0 additionally moves
`POSTGRES_PASSWORD` and `admin_passwd` out of ConfigMap/committed-values and
into Secrets, and adds the keep policy, `helm test` and CI. Rendered with
default values, chart 1.1.0 is **not** byte-identical to chart 1.0.0's
default render or to the original Kustomize manifests — see
[CHANGES.md](#changes-since-chart-100) below for the exact, reviewed diff.
There has never been a live deployment of this chart on any WOOWTECH cluster;
each per-tenant Odoo instance is a separate `kubectl apply` stack, untouched
by this chart.

### Changes since chart 1.0.0

Diffed with `helm template` on default values, object by object:

| Object | Change |
|---|---|
| `Secret/odoo-db-secret` | No longer rendered by default (`secrets.create=false`); create it yourself or set `secrets.create=true` with a real password |
| `ConfigMap/odoo-config` | The `admin_passwd = admin` line is gone (comment explains where it went) |
| `Deployment/odoo` | New `render-odoo-conf` init container and `fsGroup: 101`; the ConfigMap-mounted `odoo.conf` is now combined with `Secret/odoo-secrets` on an emptyDir instead of being mounted directly |
| `Pod/<release>-smoke` (new) | `helm test` smoke pod (`tests.enabled=true` by default) |
| `Namespace`, all 4 `PersistentVolumeClaim`s | Gained `helm.sh/resource-policy: keep` |
| `Service/odoo`, `Service/db`, `StatefulSet/db` | Unchanged |

## License

No LICENSE file is committed yet; treat this chart as an internal WoowTech
deployment configuration until one is added.
