{{/*
Helper templates for the odoo chart.
Resource names and selectors are fixed (app: odoo / component: <x>), not
derived from the release name, matching the pre-Helm manifests this chart
was rewritten from.
*/}}

{{- define "odoo.ns" -}}
{{ .Values.namespace.name }}
{{- end -}}

{{/* `annotations:` block with the keep policy, or nothing. */}}
{{- define "odoo.keepAnnotations" -}}
{{- if .Values.keepOnUninstall }}
annotations:
  helm.sh/resource-policy: keep
{{- end }}
{{- end -}}
