{{/*
Helper templates for the odoo-tenant chart.

This chart reproduces tenants that were applied by hand with kubectl over more
than a year. They are NOT one shape: each has its own provisioning init
containers, its own volume list and its own object names. So the chart supplies
the structure - which objects exist, how they are named and labelled, how they
select each other - and the per-tenant specifics arrive as values.

`tenant` is the prefix almost everything derives from. Every derived name can
still be overridden, because the live names do not all follow the rule: one
tenant has no prefix at all and another's tunnel is named after a different
project entirely.
*/}}

{{- define "odoo-tenant.ns" -}}
{{ .Values.namespace.name | default .Release.Namespace }}
{{- end -}}

{{- define "odoo-tenant.odooName" -}}
{{ .Values.odoo.name | default (printf "%s-odoo" .Values.tenant) }}
{{- end -}}

{{- define "odoo-tenant.odooService" -}}
{{ .Values.odoo.service.name | default (printf "%s-odoo-svc" .Values.tenant) }}
{{- end -}}

{{- define "odoo-tenant.pgName" -}}
{{ .Values.postgres.name | default (printf "%s-postgres" .Values.tenant) }}
{{- end -}}

{{- define "odoo-tenant.pgService" -}}
{{ .Values.postgres.service.name | default (printf "%s-postgres-svc" .Values.tenant) }}
{{- end -}}

{{- define "odoo-tenant.tunnelName" -}}
{{ .Values.tunnel.name | default (printf "%s-cloudflared" .Values.tenant) }}
{{- end -}}

{{/*
Selector labels. IMMUTABLE on a live Deployment - the API server rejects an
update that changes them, so these must match whatever is already running.
*/}}
{{- define "odoo-tenant.odooSelector" -}}
{{- if .Values.odoo.selectorLabels -}}
{{ toYaml .Values.odoo.selectorLabels }}
{{- else -}}
app.kubernetes.io/component: application
app.kubernetes.io/name: {{ include "odoo-tenant.odooName" . }}
{{- end -}}
{{- end -}}

{{- define "odoo-tenant.pgSelector" -}}
{{- if .Values.postgres.selectorLabels -}}
{{ toYaml .Values.postgres.selectorLabels }}
{{- else -}}
app.kubernetes.io/component: database
app.kubernetes.io/name: {{ include "odoo-tenant.pgName" . }}
{{- end -}}
{{- end -}}

{{- define "odoo-tenant.tunnelSelector" -}}
{{- if .Values.tunnel.selectorLabels -}}
{{ toYaml .Values.tunnel.selectorLabels }}
{{- else -}}
app: {{ include "odoo-tenant.tunnelName" . }}
{{- end -}}
{{- end -}}

{{/*
The web selector as a map (JSON round trip, so a label value never changes
type on the way). Same labels as odoo-tenant.odooSelector.
*/}}
{{- define "odoo-tenant.odooSelectorMap" -}}
{{- if .Values.odoo.selectorLabels -}}
{{- toJson .Values.odoo.selectorLabels -}}
{{- else -}}
{{- toJson (dict "app.kubernetes.io/component" "application" "app.kubernetes.io/name" (include "odoo-tenant.odooName" .)) -}}
{{- end -}}
{{- end -}}

{{/* ── Separate cron Deployment (odoo.cron.*; off by default) ───────────── */}}

{{/*
odoo.cron and odoo.secretEnv are read through `| default dict` everywhere a
render without the split reaches them. `helm upgrade --reuse-values` from a
release made with chart 1.0.0 renders these templates with 1.0.0's defaults,
which have neither key; a bare .Values.odoo.cron.enabled fails there with
"nil pointer evaluating interface {}.enabled".
*/}}
{{- define "odoo-tenant.cronName" -}}
{{ (.Values.odoo.cron | default dict).name | default (printf "%s-cron" (include "odoo-tenant.odooName" .)) }}
{{- end -}}

{{/*
The --max-cron-threads value the web container's Odoo really starts with, or ""
when its command sets none. Only the command's LAST shell segment counts - the
one that runs odoo; segments are split on newlines, ';', '&&', '||' and '|'
after joining backslash-continued lines - and within it the LAST occurrence
wins, as in Odoo's own option parser. So a flag that appears only in an earlier
`echo`, or `--max-cron-threads=0 --max-cron-threads=2`, is not taken for 0.
*/}}
{{- define "odoo-tenant.webCronThreads" -}}
{{- $cmd := join " " (.Values.odoo.command | default list) -}}
{{- $cmd = regexReplaceAll "\\\\\\r?\\n" $cmd " " -}}
{{- $last := "" -}}
{{- range $seg := regexSplit "\\r?\\n|;|&&|\\|\\||\\|" $cmd -1 -}}
{{- if trim $seg -}}
{{- $last = $seg -}}
{{- end -}}
{{- end -}}
{{- $flags := regexFindAll "--max-cron-threads(=|[ \\t]+)[0-9]+" $last -1 -}}
{{- if $flags -}}
{{- regexReplaceAll "^--max-cron-threads(=|[ \\t]+)" (last $flags) "" | atoi -}}
{{- end -}}
{{- end -}}

{{/*
Checks for a render WITHOUT the cron Deployment (odoo.cron.enabled false).

1. The web command must not switch cron threads off: with no cron pod, nothing
   would run the scheduled jobs (mail queue, fetchmail, billing), and the site
   would look healthy while they silently stop.
2. This release must not be running a cron Deployment right now. An upgrade
   with values that leave the split out (an image bump passing only the
   instance file, say) would delete the cron pod, move the jobs back into the
   web pod - which lacks the cron-only Secret env - and restart the site.
   `lookup` sees the cluster only in a real install/upgrade (and
   --dry-run=server); `helm template` and CI get an empty result, so renders
   are unaffected. Removing the split on purpose: scale the cron Deployment to
   0 first (README "Separate cron Deployment"), or `helm rollback`, which does
   not render templates.
*/}}
{{- define "odoo-tenant.cronOffValidate" -}}
{{- if eq (include "odoo-tenant.webCronThreads" .) "0" -}}
{{- fail "odoo.command passes --max-cron-threads=0 but odoo.cron.enabled is false: no pod would run Odoo's scheduled jobs. Turn the cron Deployment on, or drop the flag from the web command" -}}
{{- end -}}
{{- $ns := include "odoo-tenant.ns" . -}}
{{- $name := include "odoo-tenant.cronName" . -}}
{{- $live := lookup "apps/v1" "Deployment" $ns $name -}}
{{- if $live -}}
{{- $ann := $live.metadata.annotations | default dict -}}
{{- $replicas := 1 -}}
{{- if hasKey ($live.spec | default dict) "replicas" -}}
{{- $replicas = int $live.spec.replicas -}}
{{- end -}}
{{- if and (eq (toString (get $ann "meta.helm.sh/release-name")) .Release.Name) (eq (toString (get $ann "meta.helm.sh/release-namespace")) .Release.Namespace) (gt $replicas 0) -}}
{{- fail (printf "odoo.cron.enabled is false, but release %s runs Deployment %s/%s with %d replica(s). These values would delete the cron pod, move the scheduled jobs back into the web pod (which lacks the cron-only Secret env) and restart the site. Pass the same values files the release was installed with (the instance file plus its planned cron-split file until that is folded in). To remove the split on purpose, scale %s to 0 first" .Release.Name $ns $name $replicas $name) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
The cron pod's labels: the web selector with app.kubernetes.io/component set
to cron. odoo-tenant.cronValidate guarantees the web selector carries that key,
so these labels can never satisfy the web selector - the web Service and the
web Deployment never pick up the cron pod.
*/}}
{{- define "odoo-tenant.cronSelectorMap" -}}
{{- $sel := include "odoo-tenant.odooSelectorMap" . | fromJson -}}
{{- $_ := set $sel "app.kubernetes.io/component" "cron" -}}
{{- toJson $sel -}}
{{- end -}}

{{/*
Selects the web pod OR the cron pod: the web selector's other labels, plus
component In [<web component>, cron]. The web pod's required affinity uses it.
Because the web pod matches it itself, the scheduler's "first pod of a group"
rule lets the web pod start when neither pod exists, so it can never deadlock.
*/}}
{{- define "odoo-tenant.odooGroupSelector" -}}
{{- $web := include "odoo-tenant.odooSelectorMap" . | fromJson -}}
{{- $comp := get $web "app.kubernetes.io/component" -}}
{{- $expr := dict "key" "app.kubernetes.io/component" "operator" "In" "values" (list $comp "cron") -}}
{{- toYaml (dict "matchLabels" (omit $web "app.kubernetes.io/component") "matchExpressions" (list $expr)) -}}
{{- end -}}

{{/*
Everything the split depends on, checked at render time. Each failure here is
a configuration that would otherwise deploy and misbehave quietly.
*/}}
{{- define "odoo-tenant.cronValidate" -}}
{{- $c := .Values.odoo.cron -}}
{{- $web := include "odoo-tenant.odooSelectorMap" . | fromJson -}}
{{- $comp := toString (get $web "app.kubernetes.io/component") -}}
{{- if or (not (hasKey $web "app.kubernetes.io/component")) (eq $comp "") -}}
{{- fail "odoo.cron.enabled: the web selector has no app.kubernetes.io/component label, so the cron pod (component=cron) could not be kept out of the web Service's selector" -}}
{{- end -}}
{{- if eq $comp "cron" -}}
{{- fail "odoo.cron.enabled: the web selector already says app.kubernetes.io/component=cron; the cron pod would match the web Service" -}}
{{- end -}}
{{- if not (omit $web "app.kubernetes.io/component") -}}
{{- fail "odoo.cron.enabled: the web selector needs at least one label besides app.kubernetes.io/component, or the web/cron co-location rule would match unrelated pods in the namespace" -}}
{{- end -}}
{{- if ne (include "odoo-tenant.webCronThreads" .) "0" -}}
{{- fail "odoo.cron.enabled: the web container's odoo.command must pass --max-cron-threads=0 to the odoo it runs (last shell segment, last occurrence). Otherwise the web pod keeps running cron jobs too, and any job that needs a cron-only credential (odoo.secretEnv.cron) fails there" -}}
{{- end -}}
{{- if not $c.configPath -}}
{{- fail "odoo.cron.configPath is required: the odoo.conf path inside the container (the web reads the same file)" -}}
{{- end -}}
{{- $n := $c.maxCronThreads | int -}}
{{- if lt $n 1 -}}
{{- fail "odoo.cron.maxCronThreads must be at least 1" -}}
{{- end -}}
{{- with $c.dbMaxconn -}}
{{- if lt (int .) (mul 3 $n) -}}
{{- fail (printf "odoo.cron.dbMaxconn=%d < 3 x odoo.cron.maxCronThreads (%d): in threaded mode every cron thread holds a LISTEN connection plus cron_cr and job_cr from the same pool, so this guarantees PoolError once all threads run a job; use 3 x N + 2 or more" (int .) (mul 3 $n)) -}}
{{- end -}}
{{- end -}}
{{- if gt ($c.replicas | int) 1 -}}
{{- fail "odoo.cron.replicas must be 0 or 1: one cron pod per tenant (more cron throughput = odoo.cron.maxCronThreads)" -}}
{{- end -}}
{{- if $c.noHttp -}}
{{- range $p := list $c.livenessProbe $c.readinessProbe $c.startupProbe -}}
{{- if and $p (hasKey $p "httpGet") -}}
{{- fail "odoo.cron.noHttp is true, so the cron pod serves no HTTP; its probes cannot use httpGet" -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
odoo-tenant.env: the env list of one Odoo container, as YAML ("" if empty).
Argument: (list <root> "web"|"cron").

  odoo.env verbatim, then odoo.secretEnv.both, then odoo.secretEnv.<component>.

With no secretEnv this is exactly odoo.env, so existing tenants render byte for
byte as before. secretEnv entries become valueFrom.secretKeyRef and nothing
else: an entry with any field besides name/secretName/key/optional is refused,
so a literal credential cannot be committed through these lists. A name that
is already in the container's env is refused too (the later one would silently
win).
*/}}
{{- define "odoo-tenant.env" -}}
{{- $root := index . 0 -}}
{{- $component := index . 1 -}}
{{- $odoo := $root.Values.odoo -}}
{{- $se := $odoo.secretEnv | default dict -}}
{{- $env := concat ($odoo.env | default list) list -}}
{{- $seen := dict -}}
{{- range $odoo.env | default list -}}
{{- if and (kindIs "map" .) .name -}}
{{- $_ := set $seen (toString .name) "odoo.env" -}}
{{- end -}}
{{- end -}}
{{- range $group := list "both" $component -}}
{{- range $i, $e := (get $se $group | default list) -}}
{{- $where := printf "odoo.secretEnv.%s[%d]" $group $i -}}
{{- if not (kindIs "map" $e) -}}
{{- fail (printf "%s must be a map {name, secretName, key}" $where) -}}
{{- end -}}
{{- range $k, $_ := $e -}}
{{- if not (has $k (list "name" "secretName" "key" "optional")) -}}
{{- fail (printf "%s: unknown field %q. Entries take only name, secretName, key and optional - a literal value can never be set here" $where $k) -}}
{{- end -}}
{{- end -}}
{{- $name := toString (required (printf "%s.name is required" $where) $e.name) -}}
{{- if hasKey $seen $name -}}
{{- fail (printf "%s: %s is already set by %s in the same container" $where $name (get $seen $name)) -}}
{{- end -}}
{{- $_ := set $seen $name (printf "odoo.secretEnv.%s" $group) -}}
{{- $ref := dict "name" (required (printf "%s.secretName is required" $where) $e.secretName) "key" (required (printf "%s.key is required" $where) $e.key) -}}
{{- if hasKey $e "optional" -}}
{{- $_ := set $ref "optional" $e.optional -}}
{{- end -}}
{{- $env = append $env (dict "name" $name "valueFrom" (dict "secretKeyRef" $ref)) -}}
{{- end -}}
{{- end -}}
{{- if $env -}}
{{- toYaml $env -}}
{{- end -}}
{{- end -}}

{{/*
The cron pod's volumes: only the entries of odoo.volumes that the cron
container (or a cron init container) mounts, in odoo.volumes order. The web's
nginx-only volumes stay out, and a mount that names no volume fails here.
*/}}
{{- define "odoo-tenant.cronVolumes" -}}
{{- $c := .Values.odoo.cron -}}
{{- $names := dict -}}
{{- range ($c.volumeMounts | default .Values.odoo.volumeMounts | default list) -}}
{{- $_ := set $names .name true -}}
{{- end -}}
{{- range ($c.initContainers | default list) -}}
{{- range (.volumeMounts | default list) -}}
{{- $_ := set $names .name true -}}
{{- end -}}
{{- end -}}
{{- $have := dict -}}
{{- $vols := list -}}
{{- range (.Values.odoo.volumes | default list) -}}
{{- $_ := set $have .name true -}}
{{- if hasKey $names .name -}}
{{- $vols = append $vols . -}}
{{- end -}}
{{- end -}}
{{- range $n := keys $names | sortAlpha -}}
{{- if not (hasKey $have $n) -}}
{{- fail (printf "odoo.cron: volume %q is mounted but odoo.volumes has no entry with that name" $n) -}}
{{- end -}}
{{- end -}}
{{- if $vols -}}
{{- toYaml $vols -}}
{{- end -}}
{{- end -}}
