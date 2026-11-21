# fixtures

`exit-profile/` is the export tree that CI applies on `kind`: the jobs `t1` and
`t1b` in `.github/workflows/exit.yml` (design/145 gate checks 7 and 8). It has
the file layout of a v1.4 cell export:

| Path | Holds |
|---|---|
| `manifests/production/` | a namespace file, a `web` Deployment with a plain file, a secret file, an environment secret, a database connection and a scratch volume, and a `tick` CronJob |
| `secrets/production.example.yaml` | the Secrets those workloads read, every value empty |
| `score-k8s/web.yaml`, `overrides/staging/` | the Score document for the re-render route and the `staging` size, variables and replica count |
| `images.json`, `glenr.provisioners.yaml` | image digests; the provisioners file, byte-equal to the one at the repository root (a workflow step compares them) |

`data/` is outside the export: `maindb.dump` is a `pg_dump -Fc` of one table,
`items` with 25 rows; `row-counts.txt` records the count the restore must
reproduce.

## What this fixture is

- The `manifests/` files follow the operator's exit-profile goldens
  (`render/testdata/golden-exit/`: `files-and-database`, `kind-cron`,
  `scratch-volume`, `files-secret`) for object shapes, with one change: the
  goldens use placeholder image digests, so the fixture names a public image
  by digest (`docker.io/library/busybox`, tag 1.37.0) that a cluster can pull.
  The fixture was written by hand from those shapes. Byte-equality between an
  export's `manifests/` and `exit.Render` output is design/145 gate check 5
  (glenr-api), not this job.
- `web` is a BusyBox `httpd`, not the app that serves `/exit-check`. The jobs
  read the mounted files and variables with `kubectl exec` and reach `web`
  through the cluster's ingress or Gateway.
- The export is signed in CI with a key the workflow generates
  (`bin/make-test-export.sh`). The private half of the deployed export key is
  not in this repository.

## Differences the jobs apply, and why

The first CI runs of this fixture (GLE-3154) found three places where the
export's own files do not run unchanged on `kind` with the README's steps.
The workflow names each one in a comment.

| # | Finding | What the job does |
|---|---|---|
| F-1 | The exit profile writes `hostUsers: false` into pod specs. On `kind` a pod sandbox fails with `error mounting "sysfs" ... operation not permitted`. | `t1` removes the field from its copy of the fixture before signing it. The committed fixture keeps it. |
| F-2 | `_namespace.yaml` sets Pod Security `restricted`. The pods in `manifests/` set no `runAsNonRoot` (`runAsNonRoot != true`), and the Deployments `score-k8s` renders have no `securityContext`, so the namespace refuses both. | `t1` and `t1b` set the label to `baseline` after step 4. |
| F-3 | `_namespace.yaml` creates a default-deny ingress NetworkPolicy and `kind`'s CNI enforces it. The CloudNativePG operator cannot reach its instance (`Instance Status Extraction Error: HTTP communication issue`) and Traefik cannot reach `web`. The `manifests/` route has `web-from-ingress`; the score-k8s route has no policy. | `t1b` applies one NetworkPolicy that allows ingress from the namespace, `traefik` and `cnpg-system`. |
