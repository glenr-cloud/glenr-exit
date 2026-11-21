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
- `web` is a BusyBox `httpd`. It serves `GET /` only; the app that serves
  `/exit-check` is in design/145 gate check 6. `t1b` reads the mounted files and
  variables with `kubectl exec` and reaches `web` through the Gateway; `t1` sends
  no request.
- The export is signed in CI with a key the workflow generates
  (`bin/make-test-export.sh`). The private half of the deployed export key is
  held by Glenr and never enters this repository.

## What the jobs add to the README's steps

The first CI runs of this fixture (GLE-3154) found three places where `kind`
needs a step the README did not state. The README now states them (GLE-3314),
and the jobs run the README's commands as written; neither job edits the
fixture or adds a step of its own.

| # | Finding | README block the job runs |
|---|---|---|
| F-1 | The exit profile writes `hostUsers: false` into pod specs. On `kind` a pod sandbox fails with `error mounting "sysfs" ... operation not permitted`. | `t1`: step 7, "A cluster without user namespaces": the `find ... yq` command removes the field before the apply. The committed fixture keeps it. |
| F-2 | `_namespace.yaml` sets Pod Security `restricted`. With the field removed the pods in `manifests/` fail `runAsNonRoot != true`; the Deployments `score-k8s` renders have no `securityContext`. | `t1`: the `kubectl label ... baseline` command after the apply (the apply resets the label). `t1b`: the same command after step 4. |
| F-3 | `_namespace.yaml` creates a default-deny ingress NetworkPolicy and `kind`'s CNI enforces it. The CloudNativePG operator cannot reach its instance (`Instance Status Extraction Error: HTTP communication issue`) and Traefik cannot reach `web`. The `manifests/` route has `web-from-ingress`; the score-k8s route has no policy. | `t1b`: `kubectl -n <namespace> apply -f examples/score-k8s-allow-ingress.yaml` |

## Left untested

| Item | Where it is tested |
|---|---|
| README step 2 (`images.sh copy` and `rewrite` against a registry) | `bin/selftest.sh` covers `rewrite`; `copy` has no job |
| The Ingress object in `manifests/` | no job sends a request through it |
| `GET /exit-check`, the row counts of the cell's own database | design/145 gate check 6 on T2 |
| `hostUsers: false` taking effect (user namespaces on the nodes) | no job: `kind` has none, so `t1` removes the field. Design/145 gate check 6 runs it on a k3s cluster (T2) |
