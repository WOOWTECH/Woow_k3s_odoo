# Woow_k3s_odoo — Odoo 18 Helm Chart for K3s/Kubernetes

[繁體中文](README_zh-TW.md)

Helm chart deploying [Odoo 18](https://www.odoo.com) Community Edition on
K3s/Kubernetes, backed by a PostgreSQL 16 with `pgvector` StatefulSet.

> **Looking for another platform?**
> Docker/Podman Compose → [Woow_podman_odoo](https://github.com/WOOWTECH/Woow_podman_odoo) ·
> Home Assistant add-on → [Woow_ha_odoo](https://github.com/WOOWTECH/Woow_ha_odoo)

## Architecture

| Component | Image | Service | NodePort |
|---|---|---|---|
| Odoo | `odoo:18` | `odoo:8069` | `31806` |
| PostgreSQL | `pgvector/pgvector:pg16` | `db:5432` | (ClusterIP only) |

- Storage: three PVCs on `local-path` (odoo data 10Gi, addons 5Gi, config 100Mi)
  plus one for PostgreSQL data (10Gi)
- Odoo runs single-replica with `Recreate` strategy (SQLite-style single writer
  semantics — the filestore is a `ReadWriteOnce` PVC)
- Odoo waits for PostgreSQL via an init container before starting

## Quick start

```bash
# Install straight from the repo tarball (no clone needed)
helm install odoo https://github.com/WOOWTECH/Woow_k3s_odoo/archive/refs/heads/main.tar.gz

# Or from a local clone
git clone https://github.com/WOOWTECH/Woow_k3s_odoo.git
cd Woow_k3s_odoo
helm install odoo .
```

> **Change the PostgreSQL password before any non-test deployment:**
>
> ```bash
> helm install odoo . \
>   --set secrets.postgresPassword="$(openssl rand -base64 24)"
> ```

Then open `http://<node-ip>:31806` and create your first database.

## Key values

| Value | Default | Description |
|---|---|---|
| `namespace.create` / `namespace.name` | `true` / `odoo` | Target namespace |
| `odoo.image.tag` | `18` | Odoo image tag |
| `odoo.service.type` / `nodePort` | `NodePort` / `31806` | How Odoo is exposed |
| `odoo.persistence.data.size` | `10Gi` | Filestore PVC size (`/var/lib/odoo`) |
| `odoo.persistence.addons.size` | `5Gi` | Custom addons PVC size |
| `odoo.config.odoo.conf` | see `values.yaml` | Contents of `/etc/odoo/odoo.conf` |
| `postgres.image.tag` | `pg16` | PostgreSQL + pgvector image tag |
| `postgres.persistence.size` | `10Gi` | Database data PVC size |
| `secrets.postgresUser` / `postgresPassword` / `postgresDb` | `odoo` / `changeme-…` / `postgres` | Database credentials |

Full list: [`values.yaml`](values.yaml)

## Verify

```bash
kubectl get pods -n odoo          # db and odoo pods Running/Ready
curl -sI http://<node-ip>:31806/web/login   # should return 200 / 303
```

## Uninstall

```bash
helm uninstall odoo
# Helm keeps PVCs; remove them (and your data!) with:
kubectl delete pvc -n odoo odoo-db-data odoo-web-data odoo-addons odoo-config
```

## Migrating from the old Kustomize deployment

This repository replaces the `k3s` branch of the archived
[Woow_odoo_docker_compose_all](https://github.com/WOOWTECH/Woow_odoo_docker_compose_all)
repo. The chart's default rendering is resource-equivalent to those manifests
(same names, namespace, labels, ports, PVCs), so an existing deployment can be
adopted by Helm or simply left as-is; the original Kustomize files remain
available in this repo's git history.

## License

LGPL-3.0
