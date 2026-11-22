# Replica counts of environment production, from values/production.yaml (Glenr export v1.4).
# Use: score-k8s init --patch-templates overrides/production/score-k8s-patch.tpl
{{ range $i, $m := .Manifests }}
{{ if eq $m.kind "Deployment" }}
{{ if eq $m.metadata.name "web" }}
- op: set
  path: {{ $i }}.spec.replicas
  value: 2
  description: replicas of web, from values/production.yaml
{{ end }}
{{ end }}
{{ end }}
