{{- /*
  score-k8s patch template: the user a Glenr workload runs as.

  Glenr renders `glenr.io/run-as-user: "<uid>"` or "<uid>:<gid>" on a Score
  document as runAsUser, runAsGroup (only with a gid) and runAsNonRoot in the
  pod securityContext. score-k8s does not read the annotation, so this template
  writes the same three fields into each Deployment, Job and CronJob whose
  workload carries it. A pod-level field covers every init container.
  Pass it once at init: score-k8s init --patch-templates <this file>
*/ -}}
{{ range $i, $m := .Manifests }}
{{- $name := dig "metadata" "annotations" "k8s.score.dev/workload-name" "" $m }}
{{- if and $name (has $m.kind (list "Deployment" "StatefulSet" "Job" "CronJob")) }}
{{- $workload := index $.Workloads $name }}
{{- $user := dig "metadata" "annotations" "glenr.io/run-as-user" "" $workload }}
{{- if $user }}
{{- $parts := splitList ":" $user }}
{{- $podSpec := "spec.template.spec" }}
{{- if eq $m.kind "CronJob" }}{{ $podSpec = "spec.jobTemplate.spec.template.spec" }}{{ end }}
- op: set
  path: {{ $i }}.{{ $podSpec }}.securityContext
  value:
    runAsUser: {{ index $parts 0 }}
{{- if gt (len $parts) 1 }}
    runAsGroup: {{ index $parts 1 }}
{{- end }}
    runAsNonRoot: true
{{ end }}
{{- end }}
{{- end }}
