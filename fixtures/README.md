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
and the jobs run the README's commands as written; neither job has a
workaround step of its own.

| # | Finding | README block the job runs |
|---|---|---|
| F-1 | The exit profile writes `hostUsers: false` into pod specs. On `kind` a pod sandbox fails with `error mounting "sysfs" ... operation not permitted`. | `t1`: the `find ... yq` command in step 7 removes the field before the apply. The committed fixture keeps it. |
| F-2 | `_namespace.yaml` sets Pod Security `restricted`. With the field removed the pods in `manifests/` fail `runAsNonRoot != true`; the Deployments `score-k8s` renders have no `securityContext`. | `t1`: the `kubectl label ... baseline` command after the apply (the apply resets the label). `t1b`: the same command after step 4. |
| F-3 | `_namespace.yaml` creates a default-deny ingress NetworkPolicy and `kind`'s CNI enforces it. The CloudNativePG operator cannot reach its instance (`Instance Status Extraction Error: HTTP communication issue`) and Traefik cannot reach `web`. The `manifests/` route has `web-from-ingress`; the score-k8s route has no policy. | `t1b`: `kubectl -n <namespace> apply -f examples/score-k8s-allow-ingress.yaml` |

## Left untested

| Item | Where it is tested |
|---|---|
| README step 2: `images.sh copy` of a row with a tag and no digest, and from a real public registry | `bin/selftest.sh` covers `rewrite`; the `mixed` job covers `load` then `copy` by digest between two local registries |
| The Ingress object in `manifests/` | no job sends a request through it |
| `GET /exit-check`, the row counts of the cell's own database | design/145 gate check 6 on T2 |
| `hostUsers: false` taking effect (user namespaces on the nodes) | no job: `kind` has none, so `t1` removes the field. Design/145 gate check 6 exercises it on a k3s cluster (T2) |

## `load/`

`load/` holds the input of `bin/test-load.sh` and the `load` job (design/150
KIT-LOAD): `images.json` and `images/production/api.tar`, a kind 5 hand-over
file (an `oci-archive`: `index.json`, `oci-layout`, `blobs/sha256/`). The image
has one layer (`hello.txt`) and the manifest digest recorded in `images.json`.
`images.json` also holds a public-registry row (`cache`, no archive) and a
`staging` row (no archive), so the test shows that `load` skips the first and
leaves the second alone.

The archive was made with `crane` v0.22.1, on `crane registry serve` in memory:
`crane append --oci-empty-base -f layer.tar -t <host>/api:fixture`, then
`crane pull --format oci <host>/api:fixture layout/`, then
`tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf api.tar -C layout .`
with `layout/` set to mode `u=rwX,go=rX`, and `layer.tar` made the same way from
`hello.txt`.

## `second-route/`

`second-route/` holds the input of `bin/test-second-route.sh` and a step of the
`t1b` job (design/150 KIT-REWRITE): the export of an app Glenr built from
source. `images.json`, `score-k8s/web.yaml` and
`overrides/production/web.score.yaml` each name
`lz7.apps.glenr.io/exitsrc/exit-src/web@sha256:c4637041…caaef`, the shape of the
GLE-3444 export. The script runs the README's second-route code block with a
destination registry, asserts that every `image:` in the score-k8s output is
`<registry>/exitsrc/exit-src/web@<fixture digest>`, then runs the block without
its `images.sh rewrite ./export/overrides` line and requires the assertion to
fail (the mutant). The fixture holds no cluster object: the case needs
`score-k8s`, `yq` and `jq` only.

## Other fixtures

| Path | Used by | Holds |
|---|---|---|
| `load/` | `bin/test-load.sh` | one OCI archive (`images/production/api.tar`) and its `images.json` |
| `mixed/` | `bin/test-mixed.sh` | `images.json` with one archive row, one public row and a `staging` row that `copy` must not touch, and the archive (`images/production/api.tar`, the file in `load/`); the test replaces `PUBLIC_HOST` and `PUBLIC_DIGEST` in the public row |
