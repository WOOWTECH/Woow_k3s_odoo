# odoo-tenant

Adopts an Odoo tenant that is **already running** on `woow-k3s`: Odoo with its
nginx sidecar, PostgreSQL, the Cloudflare tunnel and the nightly backup.

For a **fresh** Odoo install use [`../odoo`](../odoo) instead. This chart exists
to take over what was applied by hand with `kubectl`, without restarting it.

## Why an instance values file is long

The seventeen live tenants are not one shape. Eight of them alone came in six
different shapes, differing mainly in their **init containers** - each tenant's
own provisioning script, running anything from "wait for postgres" to cloning
module repos, seeding the database or patching a websocket origin check. The
longest is 7KB of shell.

So the chart supplies the structure - which objects exist, how they are named
and labelled, how they select each other - and the per-tenant specifics arrive
as values, carried verbatim. The length of an instance file is that tenant's
own logic, not chart boilerplate.

## Adopting a tenant

```sh
helm --kube-context woow-k3s upgrade --install odoo-tenant charts/odoo-tenant \
  -n <namespace> -f deploy/woow-k3s/<tenant>.yaml --take-ownership
```

Verify the render against the live objects field by field BEFORE running it.
Every tenant in `deploy/woow-k3s/` was adopted that way with zero pod restarts.

## Things that will bite you

**Names do not all follow the rule.** Most objects are `<tenant>-odoo`,
`<tenant>-postgres`, `<tenant>-cloudflared`. But `well-101`'s are just `odoo`,
`postgres` and `cloudflared`, and `apun`'s tunnel is called
`apporo-cloudflared`. Every derived name has an override for this reason.

**PostgreSQL is a Deployment, not a StatefulSet.** That is what every live
tenant runs. The distinction matters: a StatefulSet's `volumeClaimTemplates`
are immutable, so a takeover cannot convert one into the other.

**`spec.selector` is immutable.** It must match what is already running or the
upgrade is rejected outright, not merely restarted.

**Recreate, never RollingUpdate.** The data volume is ReadWriteOnce; a rolling
update surges a pod that waits forever for a volume the old one still holds,
and the rollout hangs with no way to self-heal.

**The tunnel token is a credential.** All eight adopted tenants read it from a
Secret, which is the shape to keep. If a tenant ever carries it as a plain
`--token` argument, the values file holds `__TUNNEL_TOKEN__` and the real value
is passed with `--set-string` at install time. CI fails if a real one is
committed.

## Environment variables from Secrets (`odoo.secretEnv`)

`odoo.env` stays verbatim. Variables that come from a Secret and belong to one
Odoo component go in `odoo.secretEnv`, which renders them as
`valueFrom.secretKeyRef` after `odoo.env`:

```yaml
odoo:
  secretEnv:
    both:                 # every Odoo container: web, and cron when enabled
      - {name: WOOW_LLM_SECRET_KEYS, secretName: apun-newapi-llm, key: fernet-keys}
    web:                  # the web container only
      - {name: WOOW_NEWAPI_PROXY_AUTH_WEB, secretName: apun-newapi-llm, key: proxy-auth-web}
    cron:                 # the cron container only (needs odoo.cron.enabled)
      - {name: WOOW_NEWAPI_PROXY_AUTH_CRON, secretName: apun-newapi-llm, key: proxy-auth-cron}
```

An entry takes `name`, `secretName`, `key` and optionally `optional` - nothing
else, so a literal value can never be committed through these lists. A name
that is already set in the same container is refused, and `secretEnv.cron`
without the cron Deployment is refused (it would reach no pod). Empty lists
render nothing: every tenant without them is byte-for-byte unchanged.

## Separate cron Deployment (`odoo.cron`, off by default)

Every tenant runs its crons inside the web pod. `odoo.cron.enabled: true` adds
a Deployment `<odoo name>-cron` that runs only Odoo's cron threads, so that a
credential used only by cron jobs (`odoo.secretEnv.cron`) never sits in the
internet-facing web pod. WOOW's platform Odoo runs the same split
(woow-odoo chart, `--workers=0 --max-cron-threads=3 --db_maxconn=16`).

What it renders:

- Same image, same `odoo.conf`, same data: the cron container mounts what the
  web's `odoo` container mounts, and the pod gets only the `odoo.volumes`
  entries those mounts name (the nginx sidecar's volumes stay out).
- `odoo --config=<configPath> --workers=0 --max-cron-threads=N
  [--db_maxconn=M] [--no-http] <extraArgs>` as the container `command` (not
  `args`: the image entrypoint would put the database credentials from the
  environment on the command line). Threaded mode: one process.
- Labels: the web selector with `app.kubernetes.io/component: cron`. No
  Service, and the web Service (component of the web) never selects it.
- Init containers are NOT inherited (they are provisioning scripts); list what
  the cron pod needs in `odoo.cron.initContainers`.

Render-time guards (each is a configuration that would otherwise deploy and
misbehave quietly): the web's `odoo.command` must pass `--max-cron-threads=0`
or the web keeps running cron jobs that then fail for lack of the cron-only
credential; the web selector must have `app.kubernetes.io/component` plus one
more label; `dbMaxconn >= 3 x maxCronThreads` (each threaded cron thread holds
a LISTEN connection plus `cron_cr` and `job_cr`); `replicas` 0 or 1; no
`httpGet` probe with `noHttp`.

**Threaded mode uses the per-worker memory limits for the whole process.**
`limit_memory_soft` (over it the server re-executes itself) and
`limit_memory_hard` (the process's `RLIMIT_AS`) are written for one prefork
worker but are measured against the VMS of the single cron process. Raise them
for the cron pod with `extraArgs` if `odoo.conf` sizes them for a worker.

### The two pods and ReadWriteOnce volumes

The filestore and the other data volumes are Longhorn ReadWriteOnce: attached
to one node at a time, shareable by any number of pods on that node. So the
two pods must always be scheduled onto the same node:

- The cron pod has a required podAffinity to the web pod's node.
- While the cron Deployment exists, the web pod has a required podAffinity to
  "the web pod or the cron pod" (`component In [<web>, cron]`). That matters
  for a **web-only restart**: the cron pod keeps running and keeps the volume
  attached to its node, so a web pod placed anywhere else would hang in
  `ContainerCreating` with `Multi-Attach error ... Volume is already used by
  pod(s) <cron pod>`, and nothing would ever move the cron pod. The term sends
  the new web pod to the cron pod's node instead. Because the web pod matches
  the term itself, it still schedules when neither pod exists (the scheduler
  admits the first pod of a self-affine group), so the two rules never
  deadlock.
- Both strategies are Recreate: the old pod is gone before its replacement
  exists, so a Deployment never competes with its own previous pod.

Rollout order this gives you:

| What changes | What happens |
|---|---|
| web only | new web pod goes to the running cron pod's node |
| cron only | new cron pod goes to the web pod's node |
| both in one `helm upgrade` | each new pod is placed next to whichever pod of the pair exists; the cron pod waits (Pending) while no web pod does |
| both scaled to 0, then `helm upgrade` (outage window) | web schedules first, cron follows |
| web at 0, cron still running | the cron pod keeps running and holds the volume - see below |

**Stopping Odoo now means both Deployments.** `kubectl scale --replicas=0` on
the web alone leaves the cron pod running crons against the database and
holding the data volume - wrong for a `-u` Job or a restore. Scale the cron
Deployment to 0 first, then the web; bring them back with `helm upgrade`
(which sets both) or web first, then cron.

**Node failure.** Pods on a node that went away stay `Terminating` until they
are force-deleted, and the volume stays attached to that node until then -
the same as with a single pod. Force-delete both old pods; the replacements
then schedule together.

**Rollback** of the switch: scale the cron Deployment to 0 first, then
`helm rollback`. Rolling back without that still converges, but the web pod
may wait briefly for the volume while the deleted cron pod terminates.

Verified 2026-11-17 in a `dev-sandbox-*` namespace on woow-k3s (three
schedulable nodes, a Longhorn RWO volume shared by both pods, then stock Odoo
18 running this rendered cron command): see the pull request that added this
section.

## Objects this chart references but never creates

The ConfigMaps holding `odoo.conf` and `nginx.conf`, the Secrets holding the
database credentials and the tunnel token, and the PersistentVolumeClaims. They
hold live state and predate the charts.

## pgPassword

Six tenants - bnidistrict, evergreen, mujimed, puhsu, wassa and well-101 - run an
`init-db` init container whose script opens its own psycopg2 connection, so the
database password sits in the script text rather than behind a `secretKeyRef`.
The values file holds `__PGPASSWORD__` there; the chart substitutes the real value
at render time. Rendering without it fails, on purpose - a placeholder must never
reach a running pod.

The password of record is the one in the cluster, so read it from there:

```sh
kubectl -n <ns> get secret <ns-prefix>-postgres-secret \
  -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d
```

(well-101's Secret is just `postgres-secret`.) Then:

```sh
helm upgrade odoo-tenant charts/odoo-tenant -n <ns> \
  -f deploy/woow-k3s/<ns>.yaml --set-string pgPassword="$PW"
```

Never put the value in a file under this repo. CI rejects a literal password in
`deploy/woow-k3s/`, and `pgPassword` must stay `""` in values.yaml.

These six passwords were rotated on 2026-09-15 because the earlier, unredacted
instance files had been pushed to this public repository. A rotation touches four
places, and all four have to move together: the database itself (`ALTER USER`),
the `POSTGRES_PASSWORD` Secret, the `db_password` line in the `odoo.conf`
ConfigMap - which is NOT managed by this chart, and for well-101 is the only place
the Odoo container reads the password from - and this `pgPassword` at upgrade time.
