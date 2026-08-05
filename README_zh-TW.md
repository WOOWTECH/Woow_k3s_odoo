# Woow_k3s_odoo — Odoo 18 的 K3s/Kubernetes Helm Chart

[English](README.md)

在 K3s/Kubernetes 上部署 [Odoo 18](https://www.odoo.com) Community Edition 的 Helm chart,
資料庫使用 PostgreSQL 16 with `pgvector` (StatefulSet)。

> **要用其他平台部署?**
> Docker/Podman Compose → [Woow_podman_odoo](https://github.com/WOOWTECH/Woow_podman_odoo) ·
> Home Assistant add-on → [Woow_ha_odoo](https://github.com/WOOWTECH/Woow_ha_odoo)

## 架構

| 元件 | 映像 | Service | NodePort |
|---|---|---|---|
| Odoo | `odoo:18` | `odoo:8069` | `31806` |
| PostgreSQL | `pgvector/pgvector:pg16` | `db:5432` | (僅 ClusterIP) |

- 儲存:三個 `local-path` PVC (odoo data 10Gi、addons 5Gi、config 100Mi),
  以及 PostgreSQL data 一個 (10Gi)
- Odoo 單副本、`Recreate` 策略(檔案儲存為 `ReadWriteOnce` PVC,單寫者語意)
- Odoo 透過 init container 等待 PostgreSQL 就緒後才啟動

## 快速開始

```bash
# 直接以倉庫 tarball 安裝(免 clone)
helm install odoo https://github.com/WOOWTECH/Woow_k3s_odoo/archive/refs/heads/main.tar.gz

# 或 clone 後安裝
git clone https://github.com/WOOWTECH/Woow_k3s_odoo.git
cd Woow_k3s_odoo
helm install odoo .
```

> **非測試環境部署前務必更換 PostgreSQL 密碼:**
>
> ```bash
> helm install odoo . \
>   --set secrets.postgresPassword="$(openssl rand -base64 24)"
> ```

完成後開啟 `http://<node-ip>:31806` 建立第一個資料庫。

## 主要設定值

| 設定 | 預設 | 說明 |
|---|---|---|
| `namespace.create` / `namespace.name` | `true` / `odoo` | 目標 namespace |
| `odoo.image.tag` | `18` | Odoo 映像標籤 |
| `odoo.service.type` / `nodePort` | `NodePort` / `31806` | Odoo 對外方式 |
| `odoo.persistence.data.size` | `10Gi` | 檔案儲存 PVC 大小 (`/var/lib/odoo`) |
| `odoo.persistence.addons.size` | `5Gi` | 自訂 addons PVC 大小 |
| `odoo.config.odoo.conf` | 見 `values.yaml` | `/etc/odoo/odoo.conf` 內容 |
| `postgres.image.tag` | `pg16` | PostgreSQL + pgvector 映像標籤 |
| `postgres.persistence.size` | `10Gi` | 資料庫 PVC 大小 |
| `secrets.postgresUser` / `postgresPassword` / `postgresDb` | `odoo` / `changeme-…` / `postgres` | 資料庫憑證 |

完整清單:[`values.yaml`](values.yaml)

## 驗證

```bash
kubectl get pods -n odoo          # db 和 odoo pod 均 Running/Ready
curl -sI http://<node-ip>:31806/web/login   # 應回傳 200 / 303
```

## 移除

```bash
helm uninstall odoo
# Helm 會保留 PVC;確定不要資料後再刪:
kubectl delete pvc -n odoo odoo-db-data odoo-web-data odoo-addons odoo-config
```

## 從舊 Kustomize 部署遷移

本倉庫取代已封存的
[Woow_odoo_docker_compose_all](https://github.com/WOOWTECH/Woow_odoo_docker_compose_all)
`k3s` 分支。Chart 預設渲染結果與原 manifests 資源等價
(名稱、namespace、標籤、埠、PVC 皆相同),既有部署可交由 Helm 接管或維持原狀;
原始 Kustomize 檔案保留在本倉庫的 git 歷史中。

## 授權

LGPL-3.0
