# apun: changing the Odoo image

Every change of `odoo.image` in [`deploy/woow-k3s/apun.yaml`](../../deploy/woow-k3s/apun.yaml)
(www.apporo.ai, namespace `apun`) follows this runbook. The site is down for a
couple of minutes: on 2026-11-18 the stop took 2 min 7 s, of which the module
upgrade was 32 s. Everything that can run before the stop does.

The steps are those of the image changes of 2026-11-18 (helm revisions 14 and
15), written for reuse; only step 1's check pod is new (see there). The
manifests are templates next to this file; their placeholders (`__IMAGE__`,
`__NODE__`, `__STAMP__`, ...) are filled by the `fill` function below.

## Why apun needs a runbook

- **No upgrade gate.** WOOW's platform Odoo (`paas-odoo-platform`) has an
  `upgrade-gate` init container that upgrades the modules whenever the image
  digest changes, and its cron pod waits for it (`cron-wait`). The
  `odoo-tenant` chart has neither: `helm upgrade` with a new image starts the
  new code on the database as it is. So a one-off `-u` Job for every module
  whose version changed runs **before** the `helm upgrade`. Skip it and the
  new code runs on tables and data that were never upgraded; the scheduled
  jobs that bill and provision every minute fail or stall, and nothing stops
  the pods.
- **Two pods, one data volume.** Since 2026-11-18 apun runs a web pod
  (`apun-odoo`) and a cron pod (`apun-odoo-cron`) that share ReadWriteOnce
  volumes. Stopping Odoo is cron first, then web. Nothing but the `-u` Job may
  hold the data volume while it runs.
- **Every Odoo process needs the deploy-level env.** The `-u` Job carries
  apun.yaml's `odoo.env` (database, the four `WOOW_LLM_EXTRA_*` endpoints)
  and the Fernet key from `odoo.secretEnv.both`. CI checks the template
  against apun.yaml, so use the template from the same checkout as the values
  file.
- **`odoo.conf` is a Secret.** It holds the database and master passwords, so
  every Odoo process mounts the Secret `apun-odoo-conf` (key `odoo.conf`, mode
  0440, group 101), which this chart does not manage. The ConfigMap
  `apun-odoo-config` it replaced must not be mounted again: its database
  password no longer works.

## 0. Before you start

- **Nobody else is changing apun.** Several lines of work deploy to apun. Look
  for open pull requests that touch `deploy/woow-k3s/apun.yaml` and for
  running Jobs in the namespace (`kubectl -n apun get jobs,pods`).
- **The image.** The image repository's publish job pushes the image by
  digest, checks the pushed layers against the ones its smoke test ran, and
  only then tags it with `docker buildx imagetools create`. Pin
  `<image>:<tag>@<digest>` with the digest from that job's **`DIGEST:`**
  line (it is also the `digest=` of the layer check, and the run summary
  prints the whole reference). The tag step prints its own
  `pushing sha256:... to <image>:<tag>` line: that is the manifest the tag
  step wrote, a different digest. Do not pin it. The registry needs
  credentials to look the digest up (the package is private), so the job log
  is the place to read it.
- **The pull request** changing `odoo.image` in apun.yaml, green in CI. The
  `helm upgrade` runs from its branch; merge it right after the change, so
  that `main` matches what runs.
- **Tell the site owner** when the stop will be, and pause anything that
  restarts or scales apun's pods on its own (monitoring scripts) until the
  end.

Set up a shell in the repository checkout of that branch. First the
definitions; run them in every shell you use for this change:

```sh
KC="kubectl --context woow-k3s"   # plus whatever connection flags your kubeconfig needs
K="$KC -n apun"
L="$KC -n longhorn-system"
H="helm --kube-context woow-k3s -n apun"   # the same flags, in helm's spelling
D=docs/apun-image-change
fill() {  # fill <template> [sed -e expressions, applied first]: prints the manifest
  t=$1; shift
  sed "$@" -e "s|__IMAGE__|$IMAGE|g" -e "s|__NODE__|$NODE|g" -e "s|__STAMP__|$STAMP|g" \
    -e "s|__MODULES__|$MODULES|g" "$D/$t"
}
job_wait() {  # job_wait <job>: returns 0 once it succeeded, 1 once it failed
  while :; do
    case "$($K get job "$1" -o jsonpath='{.status.succeeded}/{.status.failed}')" in
      1/*) return 0 ;; */1) return 1 ;;
    esac
    sleep 3
  done
}
```

Then this change's values, once. They are saved to `$W/env`: a later shell
runs the definitions, then `. ~/apun-image-<STAMP>/env` instead of this block
(once Odoo is stopped there is no web pod left to read the node from).

```sh
IMAGE='ghcr.io/woowtech/apporo-odoo:<tag>@sha256:<digest>'   # = odoo.image in apun.yaml
STAMP=<yyyymmdd><letter>        # e.g. 20261118b: names the one-off objects and the dump
W=~/apun-image-$STAMP; mkdir -p "$W"; chmod 700 "$W"           # logs, filled manifests, env
NODE=$($K get pod -l app.kubernetes.io/name=apun,app.kubernetes.io/component=application \
  -o jsonpath='{.items[0].spec.nodeName}')                     # where Odoo runs now
DB_PV=$($K get pvc apun-db-pvc -o jsonpath='{.spec.volumeName}')
FS_PV=$($K get pvc apun-filestore-pvc -o jsonpath='{.spec.volumeName}')
MODULES=
if [ -z "$NODE" ] || [ -z "$DB_PV" ] || [ -z "$FS_PV" ]; then echo "MISSING: NODE, DB_PV or FS_PV is empty"
elif [ -e "$W/env" ]; then echo "$W/env exists: source it instead of setting the values again"
else printf "%s='%s'\n" IMAGE "$IMAGE" STAMP "$STAMP" W "$W" NODE "$NODE" \
  DB_PV "$DB_PV" FS_PV "$FS_PV" MODULES "$MODULES" > "$W/env" && echo "values saved to $W/env"
fi
grep -qF "image: $IMAGE" deploy/woow-k3s/apun.yaml && echo "IMAGE is the pin" || echo "IMAGE IS NOT THE PIN IN apun.yaml"
```

## Before the window (no downtime)

### 1. Pull the image and list the modules to upgrade

[`check.tmpl.yaml`](check.tmpl.yaml) starts the new image on `$NODE` with
apun's `odoo.conf` and the data volume mounted read-only.
[`module_check.py`](module_check.py) then compares every installed module's
version on the addons path (resolved the way the server resolves it) with the
version the database was last upgraded to. It is read-only.

The check pod is new with this runbook: on 2026-11-18 a pod only pulled the
image, and the modules were picked by hand. `module_check.py` itself has run
in the live web and cron pods. Watch the check pod's first use: that it
mounts the data volume next to the running pods, and that the check reaches
the database.

```sh
fill check.tmpl.yaml > "$W/check.yaml" && $K apply -f "$W/check.yaml"
$K wait --for=condition=Ready pod/apun-image-check-$STAMP --timeout=60m   # = the pull
$K exec apun-image-check-$STAMP -- python3 -I -c "$(cat $D/module_check.py)" | tee "$W/modules.txt"
$K delete pod apun-image-check-$STAMP     # it holds the data volume
```

Each `UPGRADE <module>: database <old> -> files <new> (<path>)` line is a
module of the image to upgrade, and the last line, `MODULES=...`, lists them.
Read the output before you use it:

- A `VOLUME` line is a module whose files lie on the data volume
  (`/var/lib/odoo`), not in the image. `DATA_VOLUME_ONLY=...`, the line
  before the last, lists them, and `MODULES` leaves them out. Such a module
  was changed on the volume without an upgrade, which is not part of this
  change: ask whoever changed it before adding it. On 2026-11-18 that was
  `apporo_relay_oauth` (files 18.0.1.2.0, database 18.0.1.0.0; a routes-only
  change whose upgrade was skipped on purpose).
- A `CHECK` line (a module left in `to upgrade`, or installed but not on the
  addons path) must be understood before going on.
- A module whose XML data or views changed without a version bump also needs
  `-u`; the image's pull request says which modules changed.

```sh
MODULES=<the MODULES= list, plus any module the pull request names>
echo "MODULES='$MODULES'" >> "$W/env"
```

With nothing to upgrade (an empty list, and no data or views changed), step 6
is skipped, and so are the upgrade Job's lines in step 3; every other step
stays.

Then pull the image onto every other node the web pod may be scheduled on (the
label in apun.yaml's `odoo.nodeSelector`): the scheduler may place the new web
pod on any of them, the cron pod follows it, and a pull inside the window
would add its duration to the outage.

```sh
for n in $($KC get nodes -l node-role.kubernetes.io/control-plane=true \
    -o jsonpath='{.items[*].metadata.name}'); do
  [ "$n" = "$NODE" ] || fill prepull.tmpl.yaml -e "s|__NODE__|$n|g" | $K apply -f -
done
PRE=app.kubernetes.io/part-of=apun-image-change-$STAMP,app.kubernetes.io/component=prepull
$K wait --for=jsonpath='{.status.phase}'=Succeeded pod -l "$PRE" --timeout=120m
$K delete pod -l "$PRE"
```

### 2. Online database dump

[`job-backup.tmpl.yaml`](job-backup.tmpl.yaml): `pg_dump` while the site
runs, into `/backups/keep/odoo_pre-$STAMP.pg` with its sha256. Not near 03:30
UTC, when the nightly backup uses the same ReadWriteOnce volume. The dump is
the fallback restore source: it misses what is written between the dump and
the stop, which the snapshots of step 5 do not.

```sh
fill job-backup.tmpl.yaml > "$W/job-backup.yaml" && $K apply -f "$W/job-backup.yaml"
job_wait apun-image-backup-$STAMP && echo succeeded
$K logs job/apun-image-backup-$STAMP | tee "$W/backup.log"    # table count, sha256
```

### 3. Check the render and the manifests

The values file must change nothing but the image. If the diff shows more,
someone changed apun.yaml or the live release since: find out before going
on.

```sh
helm template odoo-tenant charts/odoo-tenant -n apun -f deploy/woow-k3s/apun.yaml > "$W/render.yaml"
$H get manifest odoo-tenant > "$W/live.yaml"
diff "$W/live.yaml" "$W/render.yaml"   # only the odoo `image:` lines of apun-odoo and
                                       # apun-odoo-cron, and an empty last line
fill snapshot.tmpl.yaml -e "s|__PART__|db|g" -e "s|__VOLUME__|$DB_PV|g" > "$W/snap-db.yaml"
fill snapshot.tmpl.yaml -e "s|__PART__|fs|g" -e "s|__VOLUME__|$FS_PV|g" > "$W/snap-fs.yaml"
grep -n '__[A-Z]*__' "$W"/snap-*.yaml    # expect no output
$L apply --dry-run=server -f "$W/snap-db.yaml" -f "$W/snap-fs.yaml"
# the revision a rollback goes back to:
REVISION=$($H history odoo-tenant --max 1 -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)[-1]["revision"])')
echo "REVISION='$REVISION'" >> "$W/env"; echo "rollback revision: $REVISION"
```

Unless `MODULES` is empty (no step 6 then):

```sh
fill job-upgrade.tmpl.yaml > "$W/job-upgrade.yaml"
grep -n '__[A-Z]*__\|"-u", ""' "$W/job-upgrade.yaml"    # expect no output
$K apply --dry-run=server -f "$W/job-upgrade.yaml"
```

## The window

### 4. Stop Odoo, cron first

```sh
date '+%F %T %z' | tee "$W/t-stop"
```

```sh
$K scale deploy/apun-odoo-cron --replicas=0
until out=$($K get pod -l app.kubernetes.io/name=apun,app.kubernetes.io/component=cron -o name) &&
  [ -z "$out" ]; do sleep 2; done
$K scale deploy/apun-odoo --replicas=0
until out=$($K get pod -l app.kubernetes.io/name=apun,app.kubernetes.io/component=application -o name) &&
  [ -z "$out" ]; do sleep 2; done
# nothing else may hold or wait for the data volume (expect "data volume free"):
if out=$($K get pod --field-selector='status.phase!=Succeeded,status.phase!=Failed' \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.volumes[*].persistentVolumeClaim.claimName}{"\n"}{end}')
then printf '%s\n' "$out" | grep apun-filestore-pvc || echo "data volume free"
else echo "kubectl failed: run the check again"
fi
```

A failed `kubectl` call never ends a wait: a loop only ends on an empty
answer from a call that succeeded.

### 5. Longhorn snapshots

Postgres keeps running, so the database snapshot is crash-consistent
(Postgres replays its WAL after a revert); with Odoo stopped nothing writes.

```sh
$L apply -f "$W/snap-db.yaml" -f "$W/snap-fs.yaml"
for p in db fs; do
  until [ "$($L get snapshots.longhorn.io apun-$p-pre-$STAMP -o jsonpath='{.status.readyToUse}')" = true ]; do sleep 2; done
done
```

### 6. The module upgrade Job

[`job-upgrade.tmpl.yaml`](job-upgrade.tmpl.yaml): `odoo -u $MODULES
--stop-after-init` with the new image, the same `odoo.conf`, data and env as
the pods.

```sh
$K apply -f "$W/job-upgrade.yaml"
job_wait apun-image-upgrade-$STAMP && echo succeeded || echo FAILED
$K logs job/apun-image-upgrade-$STAMP > "$W/upgrade.log"
grep -E ' (ERROR|CRITICAL) |Modules loaded|Registry loaded|all steps applied' "$W/upgrade.log"
```

It must succeed and log `Modules loaded.` and `Registry loaded`; an upgraded
`apporo_paas_overlay` also logs `[APPORO_OVERLAY] all steps applied`. Compare
ERROR lines with the previous run's log: on 2026-11-18 the only one was
`Importing test framework, avoid importing from business modules ...`,
raised by a module on the data volume that imports its tests, and harmless.
A failed Job: rollback R1 below. Do not run `helm upgrade`.

### 7. helm upgrade

```sh
$H upgrade odoo-tenant charts/odoo-tenant -f deploy/woow-k3s/apun.yaml
$K rollout status deploy/apun-odoo --timeout=20m
$K rollout status deploy/apun-odoo-cron --timeout=20m
date '+%F %T %z' | tee "$W/t-start"
```

The upgrade sets both Deployments back to 1 replica. The web pod schedules
first and the cron pod follows it onto the same node. No `--atomic`: an
automatic rollback would put the old image on the upgraded database.

If the web pod stays `Pending` with `didn't match pod affinity rules`, see
"The web pod can only go where the cron pod is" in the
[chart README](../../charts/odoo-tenant/README.md): scale `apun-odoo-cron` to
0, wait for its pod to go, delete the Pending web pod, then scale
`apun-odoo-cron` back to 1.

## Verify

Print variable NAMES only, never values. Everything below must hold.

```sh
$K get pod -l 'app.kubernetes.io/name=apun,app.kubernetes.io/component in (application,cron)' -o wide
#   both Running, on ONE node, 0 restarts
$K get pod -l 'app.kubernetes.io/name=apun,app.kubernetes.io/component in (application,cron)' \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[?(@.name=="odoo")].imageID}{"\n"}{end}'
#   both end in the pinned digest
for d in apun-odoo apun-odoo-cron; do
  echo "$d: $($K get deploy $d -o jsonpath='{.spec.template.spec.containers[?(@.name=="odoo")].env[*].name}')"
done
#   web has WOOW_NEWAPI_PROXY_AUTH_WEB and not ..._CRON, cron the other way round;
#   both have WOOW_LLM_SECRET_KEYS and the four WOOW_LLM_EXTRA_*
$K exec deploy/apun-odoo -c odoo -- cat /proc/1/cmdline | tr '\0' ' '; echo
#   ends in --max-cron-threads=0
$K exec deploy/apun-odoo -c odoo -- python3 -I -c "$(cat $D/module_check.py)"
#   MODULES= is empty (a VOLUME line is not the image's)
```

Then, five to ten minutes after the start:

```sh
for d in apun-odoo apun-odoo-cron; do
  $K logs deploy/$d -c odoo --since=10m | grep -E ' (ERROR|CRITICAL) |is malformed; it is ignored'
done
#   nothing new (compare with the same command before the window)
$K exec deploy/apun-postgres -- psql -U woow-odoo -d odoo -Atc \
  "select now() - max(lastcall) from ir_cron where active"
#   minutes, not hours: the cron pod runs the scheduled jobs
curl -s -o /dev/null -w '%{http_code}\n' https://www.apporo.ai/web/health    # 200
$H history odoo-tenant --max 2    # the new revision is deployed
```

Last, log in with a test account and open the pages the change is about.

## After

- Resume what was paused in step 0, and tell the owner.
- Merge the pull request: `main` must equal what runs, or the next `helm
  upgrade` from `main` reverts the site.
- The Jobs delete themselves after 14 days. Delete the snapshots after a
  stable week (`$L delete snapshots.longhorn.io apun-db-pre-$STAMP
  apun-fs-pre-$STAMP`). Keep the dump for 30 days; the nightly backup prunes
  only `/backups/odoo_*.pg`, not `/backups/keep`.

## Rollback

The old image on an upgraded database is not a supported state: **restore the
database first**, then start the old image. Neither restore path has been run
on apun as of 2026-11-18.

In a new shell, run step 0's definitions, then `. ~/apun-image-<STAMP>/env`
(not step 0's values block: with Odoo stopped it finds no node).

**R1 - the `-u` Job failed (no `helm upgrade` yet).** Both Deployments are at
0 and still on the old image, and since the snapshots of step 5 only the
failed Job has written. Keep `upgrade.log`. Restore the database (A, or B),
then start web, then cron:

```sh
$K scale deploy/apun-odoo --replicas=1 && $K rollout status deploy/apun-odoo --timeout=20m
$K scale deploy/apun-odoo-cron --replicas=1
```

**R2 - the new image misbehaves after `helm upgrade`.** From `$W/t-start` on,
the new image has served the site and run the scheduled jobs: sign-ups,
orders, payments and invoices, wallet points, AI credit conversions, and the
New API accounts, keys and top-ups that go with them. **Both restore paths
drop all of that**, and New API is not rolled back with Odoo: the top-ups it
applied and the accounts and keys it created stay. Worse, the old image's
scheduled jobs act on the restored state: a credit order that was still
waiting to be sent at the stop, and has been sent since, would be sent again.
So once the site has served for a while, fixing forward (a corrected image,
through this runbook again) is usually the better choice. Roll back only for
a problem that cannot wait for one, agreed with the site owner.

1. Pause again what step 0 paused. Stop: `date '+%F %T %z' | tee
   "$W/t-r2-stop"`, then step 4's second block.
2. Before anything is restored, dump the database as the new image left it,
   to `/backups/keep/odoo_pre-$STAMP-failed.pg`. Step 5 reconciles from this
   copy; after restore A it is the only one.

   ```sh
   fill job-backup.tmpl.yaml -e "s|__STAMP__|$STAMP-failed|g" > "$W/job-backup-failed.yaml"
   $K apply -f "$W/job-backup-failed.yaml"
   job_wait apun-image-backup-$STAMP-failed && echo succeeded
   $K logs job/apun-image-backup-$STAMP-failed | tee "$W/backup-failed.log"
   ```

3. Restore A, both volumes: database and files are then of one moment (the
   new image may have removed files the old database refers to; files added
   since `$W/t-start` go with the revert). B only if A is not possible: it
   also drops what was written between the dump and `$W/t-stop`, and leaves
   the files as the new image left them.
4. Roll back to the revision saved in step 3, and stop the cron pod at once,
   before its first run: it stays at 0 until step 5 is done.

   ```sh
   $H rollback odoo-tenant "$REVISION" && $K scale deploy/apun-odoo-cron --replicas=0
   $K rollout status deploy/apun-odoo --timeout=20m
   $K exec deploy/apun-postgres -- psql -U woow-odoo -d odoo -Atc \
     "select max(lastcall) at time zone 'UTC' from ir_cron"
   #   not later than $W/t-stop: the cron pod did not run (if it did, step 5
   #   covers that run too)
   ```

5. Reconcile what the restore dropped, with the site owner: everything
   written after `$W/t-start` (with B, also between the dump and
   `$W/t-stop`). Odoo's side is in the copy of step 2 (after restore A, read
   it as below; with B, also in `odoo_failed_$STAMP`): new accounts, orders,
   payments and invoices, wallet points, LLMC credit orders and their
   top-ups. New API's side is on New API: the users, keys and top-ups since
   `$W/t-start`. Each goes back in by hand, or is undone where it was
   applied. Settle two kinds first, while the cron pod is at 0: a credit
   order that the restored database still has waiting or in flight and the
   copy shows credited (the cron would send it again), and an account the
   copy shows provisioned on New API that the restored database does not
   (the cron would try to provision it again). Then start the cron pod:
   `$K scale deploy/apun-odoo-cron --replicas=1`.
6. Close the pull request (or revert it if it was merged).

To read the copy after restore A, restore it into a database of its own, made
like restore B's empty one (`$P` as defined there; no rename):

```sh
$P "create database odoo_failed_$STAMP owner \"woow-odoo\" encoding '<enc>' lc_collate '<collate>' lc_ctype '<ctype>' template template0"
fill job-restore.tmpl.yaml -e "s|__STAMP__|$STAMP-failed|g" \
  -e "s|-d odoo |-d odoo_failed_$STAMP |" > "$W/job-restore-failed.yaml"
if grep -q -- "-d odoo_failed_$STAMP " "$W/job-restore-failed.yaml"; then
  $K apply -f "$W/job-restore-failed.yaml"
  job_wait apun-image-restore-$STAMP-failed; $K logs job/apun-image-restore-$STAMP-failed | tail -5
else echo "NOT APPLIED: the Job would restore into odoo itself"
fi
```

**Restore A - Longhorn snapshots (the state at the stop of step 4;
preferred).** A revert drops every write after the snapshot: in R1 only the
failed Job's, in R2 everything the new image wrote (R2 step 2 keeps a copy).

1. `$K scale deploy/apun-postgres --replicas=0` and wait for its pod to go.
2. Longhorn UI, volume `$DB_PV`: Attach with Maintenance mode, Snapshots,
   `apun-db-pre-$STAMP`, Revert, Detach.
3. The files: in R2 always, in R1 only if they must go back too. The same for
   `$FS_PV` and `apun-fs-pre-$STAMP` (both Odoo Deployments at 0).
4. `$K scale deploy/apun-postgres --replicas=1` and wait until it is ready.

**Restore B - the online dump (misses the writes after the dump).** Keep the
failed database under another name, create an empty one like it, restore:

```sh
P="$K exec deploy/apun-postgres -- psql -U woow-odoo -d postgres -v ON_ERROR_STOP=1 -Atc"
$P "select pg_encoding_to_char(encoding)||' '||datcollate||' '||datctype from pg_database where datname='odoo'"
$P "select pg_terminate_backend(pid) from pg_stat_activity where datname='odoo' and pid<>pg_backend_pid()"
$P "alter database odoo rename to odoo_failed_$STAMP"
$P "create database odoo owner \"woow-odoo\" encoding '<enc>' lc_collate '<collate>' lc_ctype '<ctype>' template template0"
fill job-restore.tmpl.yaml > "$W/job-restore.yaml" && $K apply -f "$W/job-restore.yaml"
job_wait apun-image-restore-$STAMP; $K logs job/apun-image-restore-$STAMP | tee "$W/restore.log" | tail -5
#   "pg_restore exit code 0"
```

Before dropping `odoo_failed_$STAMP`, find what it holds that the dump does
not: orders, payments, invoices and AI credit conversions written after the
dump (in R2, step 5).

In R1 the data volume rarely needs restoring: the `-u` Job adds files, and
files the restored database no longer references are removed by Odoo's own
garbage collection. In R2 restore A reverts it too (R2 step 3).
