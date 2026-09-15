{{/*
Helper templates for the odoo chart.
Resource names and selectors are fixed (app: odoo / component: <x>), not
derived from the release name, matching the pre-Helm manifests this chart
was rewritten from.
*/}}

{{- /*
Target namespace. Falls back to the release namespace so that `-n` ALWAYS
controls object placement: a values-file `namespace.name` that silently beat
`-n` is how a rehearsal once wrote Helm ownership annotations onto a live
production Deployment. Set namespace.name only to place objects somewhere
other than the release namespace, and never in an instance-values file.
*/ -}}
{{- define "odoo.ns" -}}
{{ .Values.namespace.name | default .Release.Namespace }}
{{- end -}}

{{/* `annotations:` block with the keep policy, or nothing. */}}
{{- define "odoo.keepAnnotations" -}}
{{- if .Values.keepOnUninstall }}
annotations:
  helm.sh/resource-policy: keep
{{- end }}
{{- end -}}
