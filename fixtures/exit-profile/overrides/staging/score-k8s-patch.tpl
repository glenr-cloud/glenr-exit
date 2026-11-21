# Replica counts of environment staging, from values/staging.yaml (Glenr export v1.4).
# Use: score-k8s init --patch-templates overrides/staging/score-k8s-patch.tpl
{{ range $i, $m := .Manifests }}
{{ if eq $m.kind "Deployment" }}
{{ if eq $m.metadata.name "web" }}
- op: set
  path: {{ $i }}.spec.replicas
  value: 1
  description: replicas of web, from values/staging.yaml
{{ end }}
{{ end }}
{{ end }}
