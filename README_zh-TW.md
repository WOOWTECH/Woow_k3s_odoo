# Woow_k3s_odoo — Odoo 18 的 K3s/Kubernetes Helm Chart

[English](README.md)

在 K3s/Kubernetes 上部署 [Odoo 18](https://www.odoo.com) Community Edition 的 Helm chart,
資料庫使用 PostgreSQL 16 with `pgvector` (StatefulSet)。

本 chart **目前不是**任何 WOOWTECH 正式客戶 Odoo 部署所使用的方式——那些仍是
純 `kubectl apply` 的架構。這是一份給單租戶 Odoo 安裝用的獨立 chart。

> **要用其他平台部署?**
> Docker/Podman Compose → [Woow_podman_odoo](https://github.com/WOOWTECH/Woow_podman_odoo) ·
> Home Assistant add-on → [Woow_ha_odoo](https://github.com/WOOWTECH/Woow_ha_odoo)

## 架構

| 元件 | 映像 | Service | NodePort |
|---|---|---|---|
| Odoo | `odoo:18` | `odoo:8069` | `31806` |
| PostgreSQL | `pgvector/pgvector:pg16` | `db:5432` | (僅 ClusterIP) |

| Template | 物件 | 開關 |
|---|---|---|
| `templates/namespace.yaml` | Namespace `namespace.name`,與 release namespace 相同時不渲染 | `namespace.create` |
| `templates/configmap.yaml` | ConfigMap `odoo-config`(HOST/PORT/odoo.conf,不含 admin_passwd) | 恆存在 |
| `templates/secrets.yaml` | `odoo-db-secret`、`odoo-secrets`(admin_passwd) | `secrets.create` |
| `templates/pvc.yaml` | 4 個 PVC(db data、web data、addons、未使用的 config) | 恆存在 |
| `templates/postgres-statefulset.yaml`、`postgres-service.yaml` | StatefulSet `db`、Service `db:5432` | 恆存在 |
| `templates/odoo-deployment.yaml`、`odoo-service.yaml` | Deployment `odoo`、Service `odoo` | 恆存在 |
| `templates/tests/smoke.yaml` | `helm test` pod | `tests.enabled` |

- 儲存:四個 PVC,預設 StorageClass 為 `local-path`(odoo data 10Gi、addons 5Gi、
  未使用的 config 100Mi、postgres data 10Gi)
- Odoo 單副本、`Recreate` 策略(檔案儲存為 `ReadWriteOnce` PVC)
- Odoo 透過 init container 等待 PostgreSQL 就緒後才啟動;第二個 init container
  會把不含密碼的 `odoo.conf` 與 Secret 裡的 `admin_passwd` 合併後才啟動 Odoo
  (見下方[密碼管理](#密碼管理))
- Pod 層級設定 `fsGroup: 101`,讓 Odoo 容器(上游映像固定的非 root 使用者)
  在任何 StorageClass 上都能寫入卷(不只是恰好給世界可寫的 `local-path`)

## 密碼管理

兩個 Secret,以固定名稱引用,不隨 release 名稱變動:

| Secret | 內容 | 用途 |
|---|---|---|
| `odoo-db-secret` | `POSTGRES_USER`、`POSTGRES_PASSWORD`、`POSTGRES_DB` | Postgres 的 `envFrom`、Odoo 的 `USER`/`PASSWORD` 環境變數 |
| `odoo-secrets` | `ADMIN_PASSWD`(Odoo 資料庫管理主密碼) | `render-odoo-conf` init container 會把 `admin_passwd = ...` 附加到 emptyDir 上的 `odoo.conf`,Odoo 啟動前完成 |

`secrets.create` 預設為 **false**:chart 只以名稱引用這兩個 Secret,所以
`helm upgrade` 不可能用空值蓋掉真正的密碼。請先自行建立(參考
[`examples/secrets.example.yaml`](examples/secrets.example.yaml)):

```bash
kubectl create namespace odoo
cp examples/secrets.example.yaml /secure/path/secrets.yaml   # 填入每個 REPLACE_ME
kubectl apply -f /secure/path/secrets.yaml
helm install odoo . -n odoo
```

`POSTGRES_PASSWORD` 與 `ADMIN_PASSWD` 在 `values.yaml` 裡永遠沒有預設值或佔位值。
`secrets.create=true`(僅用於全新安裝與測試)時兩者都是 `required()`——沒填就直接
安裝失敗,不會用可猜測的密碼啟動。

## 快速開始

### A. 密碼由 Helm 外部管理(預設、建議)

```bash
git clone https://github.com/WOOWTECH/Woow_k3s_odoo.git && cd Woow_k3s_odoo
kubectl create namespace odoo
cp examples/secrets.example.yaml /secure/path/secrets.yaml   # 填入每個 REPLACE_ME
kubectl apply -f /secure/path/secrets.yaml
helm install odoo . -n odoo
```

### B. 讓 chart 建立 Secret

```bash
helm install odoo https://github.com/WOOWTECH/Woow_k3s_odoo/archive/refs/heads/main.tar.gz \
  -n odoo --create-namespace \
  --set secrets.create=true \
  --set secrets.postgresPassword="$(openssl rand -hex 24)" \
  --set secrets.adminPasswd="$(openssl rand -hex 24)"
```

之後每次 `helm upgrade` 都要帶上同樣的 `--set secrets.create=true ...`(或寫在
values 檔裡)。沒帶的話 `required()` 會擋下 upgrade,密碼不會被靜默清空。

### C. 測試安裝(獨立 namespace、可拋棄的儲存)

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

### 完成後

```bash
kubectl -n odoo rollout status deploy/odoo --timeout=10m
helm test odoo -n odoo --logs
```

`helm test` 會透過 `/web/database/create` 用 `ADMIN_PASSWD` 建立一個拋棄式資料庫
(`smoketest`),再確認 `/web/database/selector` 列得出它。硬體資源有限時可能要
跑幾分鐘——建立資料庫要載入所有基礎模組。

## 主要設定值

| 設定 | 預設 | 說明 |
|---|---|---|
| `namespace.create` / `namespace.name` | `true` / `odoo` | 目標 namespace;與 release namespace(`-n`)相同時永不渲染 |
| `keepOnUninstall` | `true` | 為 Namespace、每個 PVC、chart 建立的 Secret 加上 `helm.sh/resource-policy: keep` |
| `odoo.image.tag` | `18` | Odoo 映像標籤 |
| `odoo.service.type` / `nodePort` | `NodePort` / `31806` | Odoo 對外方式 |
| `odoo.persistence.data.size` | `10Gi` | 檔案儲存 PVC 大小 (`/var/lib/odoo`) |
| `odoo.persistence.addons.size` | `5Gi` | 自訂 addons PVC 大小 |
| `odoo.config.odoo.conf` | 見 `values.yaml` | `/etc/odoo/odoo.conf` 不含密碼的內容 |
| `odoo.podSecurityContext.fsGroup` | `101` | 讓非 root 的 Odoo 使用者能在任何 StorageClass 上寫入 PVC |
| `postgres.image.tag` | `pg16` | PostgreSQL + pgvector 映像標籤 |
| `postgres.persistence.size` | `10Gi` | 資料庫 PVC 大小 |
| `secrets.create` | `false` | 從下列值渲染 `odoo-db-secret` / `odoo-secrets`,而非使用既有的 |
| `secrets.postgresUser` / `postgresDb` | `odoo` / `postgres` | 本身不是密碼,但和密碼放在同一個 Secret |
| `secrets.postgresPassword` / `adminPasswd` | `""` / `""` | `secrets.create=true` 時必填,無預設值 |
| `tests.enabled` | `true` | `helm test` smoke pod |

完整清單:[`values.yaml`](values.yaml)。

## 驗證

```bash
kubectl get pods -n odoo                    # db 和 odoo pod 均 Running/Ready
curl -sI http://<node-ip>:31806/web/login   # 應回傳 200
helm test odoo -n odoo --logs
```

## 移除

```bash
helm uninstall odoo -n odoo
```

這會移除 Deployment、StatefulSet、Service 與 ConfigMap。**資料會保留**:
Namespace、全部 4 個 PVC,以及 chart 建立的任何 Secret 都帶有
`helm.sh/resource-policy: keep`(`keepOnUninstall=true`)。要連資料庫和檔案儲存
一起刪除:

```bash
kubectl delete namespace odoo
```

## 從舊 Kustomize 部署遷移

本倉庫取代已封存的
[Woow_odoo_docker_compose_all](https://github.com/WOOWTECH/Woow_odoo_docker_compose_all)
`k3s` 分支(chart 1.0.0,2026-08-05 改寫)。Chart 1.1.0 進一步把
`POSTGRES_PASSWORD` 與 `admin_passwd` 從 ConfigMap/已提交的 values 移入 Secret,
並加上 keep 政策、`helm test` 與 CI。以預設值渲染,chart 1.1.0 **不會**與
chart 1.0.0 的預設渲染或原始 Kustomize manifests 逐位元組相同——確切、經檢視過的
差異見下方[自 1.0.0 起的變更](#自-100-起的變更)。這個 chart 從未在任何 WOOWTECH
叢集上有過正式部署;每個客戶的 Odoo 都是獨立的 `kubectl apply` 架構,不受本 chart
影響。

### 自 1.0.0 起的變更

以預設值 `helm template` 逐物件比對:

| 物件 | 變更 |
|---|---|
| `Secret/odoo-db-secret` | 預設不再渲染(`secrets.create=false`);請自行建立,或設定 `secrets.create=true` 並帶真實密碼 |
| `ConfigMap/odoo-config` | `admin_passwd = admin` 這行不見了(改成說明它去哪的註解) |
| `Deployment/odoo` | 新增 `render-odoo-conf` init container 與 `fsGroup: 101`;原本直接掛載的 `odoo.conf` 改成先在 emptyDir 上與 `Secret/odoo-secrets` 合併 |
| `Pod/<release>-smoke`(新增) | `helm test` smoke pod(預設 `tests.enabled=true`) |
| `Namespace`、全部 4 個 `PersistentVolumeClaim` | 新增 `helm.sh/resource-policy: keep` |
| `Service/odoo`、`Service/db`、`StatefulSet/db` | 無變化 |

## 授權

尚未附上 LICENSE 檔案;在補上之前請視為 WoowTech 內部部署設定。
