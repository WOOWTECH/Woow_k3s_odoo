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
