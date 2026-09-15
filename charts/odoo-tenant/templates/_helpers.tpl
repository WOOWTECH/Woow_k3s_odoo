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
