# glenr-exit

Tools to take a Glenr cell export and apply it on a Kubernetes cluster you
operate. Everything here runs with tools you install from their upstream
projects: coreutils, OpenSSL 3, `yq` (mikefarah), `crane`
(`github.com/google/go-containerregistry`), `kubectl` and, for the re-render
route, `score-k8s`.

Licence: Apache-2.0 (`LICENSE`).

Status: Glenr ran both routes of this README end to end on a test cell
(design/145 gate checks 6 and 10; label: Live). The table lists the passing
run of each route: every check passed with no manual edit (the only change to
exported files was `bin/images.sh rewrite`, as the steps say). Earlier runs on
older exports, on 2026-11-20 and 2026-11-21, failed and led to fixes in the
export and in this README.

| Date (UTC) | Route | Export | Cluster | Result |
|---|---|---|---|---|
| 2026-11-21 | Steps 1 to 8, environments `production` and `staging` | a test cell on a Glenr zone: a service with a public route and 2 named ports, a worker, a cron job and a PostgreSQL database seeded with 10,000 rows; glenr-api `eef8f7fa` | k3s v1.37.2 on one server, installed with the upstream script and no flags; a second server ran the steps | Every object applied (13 per environment). The 13 objects use only `v1`, `apps/v1`, `batch/v1` and `networking.k8s.io/v1`; the cluster had no `glenr.io` CRD and no Glenr pod. Both Deployments available; the cron job's Job completed. Each pod ran the digest in `images.json`. `GET /` and a check endpoint returned the same status and body SHA-256 as on Glenr; the check endpoint covers the plain file, the secret file, the environment secret, the variable and a write to the scratch volume. Row counts after `pg_restore` equal the counts in the dump. DNS capture on both servers: 0 queries for a name containing `glenr` (1,082 query lines) |
| 2026-11-22 | The second route, `staging` | the same cell, exported again with glenr-api `9efdae75` | the same cluster | Rendered and applied; `GET /` returned the same status and body SHA-256 as on Glenr, the second port answered, and the check endpoint showed the same plain file, secret file, variable and scratch write as on Glenr. Not measured on this route: the image digest, DNS and row-count checks of the first route. Two items differ by design of this route: the environment Secret that Glenr passes with `envFrom` (the Score document does not carry it) and the database connection (the `postgres` provisioner creates an empty CloudNativePG cluster) |
| 2026-11-22 | Steps 1 to 5, 7 and 8 (no database, so no step 6), environment `production`, for an app built from source | a test cell on a Glenr zone with one service built from a repository and a public route; its image handed over as an OCI archive (`images/production/api.tar`) and pushed with `bin/images.sh load` to `ttl.sh`; no database | k3s v1.37.2 on one server, installed with the upstream script and no flags; a second server ran the steps | `verify.sh` passed with no network. The archive's manifest SHA-256 equals the digest in `images.json`; `load` exited 0 and an anonymous `crane digest` of the `ttl.sh` copy equals that digest. After `rewrite`, the one `image:` in `manifests/` names `ttl.sh` at that digest and no file under `manifests/` names a Glenr host. 8 objects applied with exit 0; the Deployment was available 10 s after the apply; the pod's image digest equals the digest in `images.json`. `GET /` and `GET /healthz` returned the same status and body SHA-256 as on Glenr. DNS capture on both servers: 0 queries for a name containing `glenr` (233 query lines) |

Kit commits used: `eb21531` and `4b1ba70` (first route), `589d222` (second
route), `e5a86c5` (source-built app). Limits of this test:

- One run on one cluster, from a test cell. Your cluster, apps and data differ.
- The DNS capture sees DNS only; a hard-coded address or DNS over HTTPS would
  not show.
- In the first two runs the test image was in a public registry, so step 2
  did not read the Glenr zone registry and `bin/images.sh rewrite` did not
  rewrite a zone registry host on a real cluster. The third run did: its image
  was in the zone registry, Glenr handed it over as an archive (no registry
  credential), and `bin/images.sh load` pushed it. `bin/images.sh copy` from a
  zone registry is unsupported, because Glenr hands over no credential for it.
- The third run applied `manifests/` only. The second route (score-k8s) was
  not run on the source-built app, and an export that holds both archives and
  public images was not run.
- TLS was not exercised: every request used plain HTTP.

## What an export holds

An export is a directory. The parts these tools act on:

| Path | Holds |
|---|---|
| `MANIFEST`, `MANIFEST.sig` | every file and its SHA-256, and the Ed25519 signature of `MANIFEST` |
| `manifests/<env>/` | the rendered Kubernetes objects for one environment: `_namespace.yaml` and one file per app. Every namespaced object names its namespace |
| `secrets/<env>.example.yaml` | each Secret the workloads expect, with its namespace and key names, all values empty |
| `images.json` | per app and environment: the image and the digest it was built at |
| `score-k8s/`, `overrides/<env>/`, `glenr.provisioners.yaml` | inputs for the re-render route below |

`manifests/README.md` in the export carries the apply order and what the export
does not reproduce. Secret values are write-only in Glenr and are not in the
export.

## Prerequisites

- `kubectl` pointed at your cluster.
- `openssl` (3.x), `sha256sum`, `base64` (coreutils) for `bin/verify.sh`.
- `yq` v4 (Mike Farah) for `bin/check.sh` and `bin/images.sh rewrite`.
- `jq` for `bin/images.sh plan`; `crane` and `jq` for `bin/images.sh copy`;
  `crane`, `jq`, `tar` and `sha256sum` for `bin/images.sh load`.

## Cluster requirements

| Need | Why | If your cluster lacks it |
|---|---|---|
| User namespaces on the nodes (the kubelet honours `hostUsers: false`) | The exit profile writes `hostUsers: false` into every pod spec of `manifests/`. That field is what lets the pods pass the namespace's Pod Security level `restricted` (`_namespace.yaml` sets `enforce: restricted`) without a `runAsNonRoot` setting. Glenr's test clusters (k3s v1.35 on 2026-11-20, k3s v1.37.2 on 2026-11-21, one server each) met it. | The cluster refuses the pods (on `kind`: `error mounting "sysfs" ... operation not permitted`). Removing the field alone makes `restricted` refuse them (`runAsNonRoot != true`). Use the two commands in step 7 for a cluster without user namespaces: remove the field and set the namespace's level to `baseline`. |
| Pod Security level `baseline` for the second route | score-k8s writes no `securityContext`, so `restricted` refuses its Deployments. | Step "The second route" sets the level after step 4. |

## Steps

Run every command from the root of a clone of this repository, with the export
unpacked at `./export`. The examples use the environment `production`.

### 1. Verify the export

```sh
bin/verify.sh ./export              # uses keys/export-signing.pub
bin/verify.sh ./export <public-key> # or a key you saved from the export page
```

`bin/verify.sh` checks the `MANIFEST` signature, that every listed file hashes
to its recorded value, and that no file is present that `MANIFEST` does not
list. The default public key is `keys/export-signing.pub` in this repository;
you can also pass the key printed on the page where you downloaded the export.
Verify before step 2: `rewrite` edits files of the export in place, so the
export no longer matches `MANIFEST` after it.

### 2. Move the images to your registry

Move each image to a registry you control, then point the manifests at it
(design/145 §4.4 step 5). Use `load` for an image with an archive at
`images/<env>/<app>.tar` (an OCI archive, one image per file): put the `images`
directory inside this repository's directory, next to `export/`. Use `copy` for an
image in a public registry, which has no archive. Run `load` once for each
environment you apply.

```sh
crane auth login <your-registry>            # once, however your registry wants it
bin/images.sh plan    ./export/images.json  <your-registry>   # optional: list what load and copy do
bin/images.sh load    ./export/images.json  ./images production <your-registry>   # images handed over as archives
bin/images.sh copy    ./export/images.json  <your-registry>   # only when every image is in a public registry
bin/images.sh rewrite ./export/manifests    <your-registry>
```

| Command | What it does |
|---|---|
| `plan` | prints one line per image, `<source>` TAB `<destination>`, and moves nothing |
| `load` | for each image of the environment (`production` above) that has an archive `./images/<env>/<app>.tar`: extracts the archive, refuses it when a file under `blobs/sha256/` does not hash to its name or when the SHA-256 of its manifest differs from the `sha256:` digest `images.json` records, and pushes it to `<your-registry>/<path>` with `crane`. It then reads the digest back from your registry and fails when it differs. A row with no archive is skipped with a line on stderr. `load` fails when it loaded no archive |
| `copy` | copies each image to `<your-registry>/<path>`, where `<path>` is the source reference without its registry host (`library/postgres`, not `postgres`). It copies by the `sha256:` digest when `images.json` records one, and by the reference as written (its tag) otherwise. It reads every row with an image, so it stops at an image it cannot read without a credential: run it only when every image is in a public registry |
| `rewrite` | changes only the registry host in every `image:` value and keeps the path and digest, so each reference names a path `load` or `copy` filled |

`load` and `copy` write each image to the same `<path>`. An export that holds
both kinds of image: run `load`, then run `crane copy <source> <destination>`
for each public image, with the pair `plan` printed for it.

Rows `plan`, `load` and `copy` skip, each with a line on stderr:
- a row with no image (the cell's database): nothing to move;
- a reference with no registry host (`postgres:16`): `rewrite` leaves it as it
  is, so that object keeps pulling from the registry it names today.

A digest that names a multi-platform index is copied whole, every platform it
lists; there is no option to copy one platform. The `postgres` index lists 16
platform images and took about 7 min to copy in Glenr's test run (2026-11-20).

### 3. Check the manifest set

```sh
bin/check.sh ./export/manifests/production
```

`bin/check.sh` refuses a manifest set that an export must never contain: an
apiVersion outside the allowed groups (core, apps, batch, autoscaling, policy,
networking.k8s.io), the string `glenr.io`, or a Secret with a value. Run it
after `rewrite` and before you apply anything. It skips a directory named
`addons` (optional CRD-based add-ons such as Gateway API) and names it in its
output; step 7 does not apply it, and you review and apply it yourself.

### 4. Create the namespace

```sh
kubectl apply -f ./export/manifests/production/_namespace.yaml
```

`_namespace.yaml` creates the Namespace, the ResourceQuota, the LimitRange and
the default-deny NetworkPolicy the workloads expect. It goes before the Secrets:
each Secret names this namespace, and `kubectl apply` refuses a Secret whose
namespace does not exist (`namespaces "<name>" not found`). The steps below
call the namespace `<namespace>`: it is `metadata.name` of the Namespace object
in `_namespace.yaml`.

### 5. Fill the secrets

`secrets/<env>.example.yaml` lists each Secret and its key names with empty
values. Copy it to `secrets/<env>.yaml`, fill each value from your own record
and apply:

```sh
cp ./export/secrets/production.example.yaml ./export/secrets/production.yaml
# fill the values
kubectl apply -f ./export/secrets/production.yaml
```

The filled file holds your secret values. Keep it out of version control and
delete it after `kubectl apply`.

### 6. Restore the database

The export does not carry a database object: you supply a PostgreSQL of the
same or a later major as the export records (design/145 §3.1, §4.3). Restore
the dump you received, then confirm the row counts match the export's record
before you apply the workloads.

### 7. Apply

A cluster without user namespaces (see "Cluster requirements") needs two
commands around the apply: the first before it, the second after it.

Before the apply, on a cluster without user namespaces: remove `hostUsers` from
the manifests. This edits files of the export, so run it after step 1:

```sh
find ./export/manifests/production -name '*.yaml' -exec yq -i 'del(.spec.template.spec.hostUsers) | del(.spec.jobTemplate.spec.template.spec.hostUsers)' {} \;
```

The apply, on every cluster:

```sh
kubectl apply -f ./export/manifests/production/
```

This applies `_namespace.yaml` again (no change) and every app's objects.

After the apply, on a cluster without user namespaces: set the namespace's Pod
Security level to `baseline`. Run it after the apply, because the apply restores
the `restricted` label that `_namespace.yaml` carries. The ReplicaSet and Job
controllers retry the pods the namespace refused in the meantime.

```sh
kubectl label namespace <namespace> pod-security.kubernetes.io/enforce=baseline --overwrite
```

### 8. Confirm

```sh
kubectl -n <namespace> rollout status deploy/<app> --timeout=10m
```

Then call each app's own health endpoint. Glenr's exit test cell serves
`/exit-check`, which prints a SHA-256 of each mounted file, of the environment
secret and of the values variable, confirms the scratch volume accepts a write,
and prints the row count of the seeded table; your apps serve what you built
into them.

## The second route: re-render with score-k8s

Instead of applying the rendered `manifests/`, you can render again from the
Score documents with `score-k8s`. The export's `glenr.provisioners.yaml` comes
from the same operator file as the one at the root of this repository;
`bin/release.sh` refuses to release when this repository's copy differs from
the operator's.

Step 2 rewrote only `manifests/`. Point the Score documents at your registry
too. score-k8s writes no `securityContext` into its Deployments, so the
namespace's Pod Security level `restricted` refuses them. After step 4, set the
level to `baseline`, and allow ingress into the namespace: step 4's
default-deny NetworkPolicy has no allow policy for this route (the `manifests/`
route carries `web-from-ingress`; score-k8s renders none).
`examples/score-k8s-allow-ingress.yaml` allows pods of the namespace, the
namespace `traefik` (change it to your ingress controller's namespace) and
`cnpg-system`:

```sh
kubectl label namespace <namespace> pod-security.kubernetes.io/enforce=baseline --overwrite
kubectl -n <namespace> apply -f examples/score-k8s-allow-ingress.yaml
```

Then render:

```sh
bin/images.sh rewrite ./export/score-k8s <your-registry>
cd ./export
mkdir -p .score-k8s && cp glenr.provisioners.yaml .score-k8s/
score-k8s init --no-sample --patch-templates overrides/production/score-k8s-patch.tpl --patch-templates ../examples/score-k8s-run-as-user.tpl
score-k8s generate score-k8s/web.yaml \
  --overrides-file overrides/production/web.score.yaml \
  --namespace <namespace> -o manifests.yaml
```

`examples/score-k8s-run-as-user.tpl` is the second patch template in the `init`
command. A Score document in `score-k8s/` that carries the annotation
`glenr.io/run-as-user: "<uid>"` or `"<uid>:<gid>"` ran as that user in Glenr,
and score-k8s does not read the annotation. The template writes `runAsUser`,
`runAsGroup` (only with a gid) and `runAsNonRoot: true` into the pod
`securityContext` of each such workload, so an image that needs a fixed
non-root user starts as it did there. A document without the annotation is
unchanged. The `manifests/` route already carries the three fields.

Compare each `image:` in `score-k8s/` with the destinations
`bin/images.sh plan` printed: a path that is not in that list was not copied or loaded,
and a pod using it cannot pull its image.

Run `score-k8s generate` once per app in `score-k8s/`, each with its own
`--overrides-file`. `<namespace>` must exist before you apply the result: step 4
creates it, or add `--generate-namespace` to have score-k8s write a Namespace
object. `overrides/README.md` in the export lists the command for
every app.

Apply the rendered objects from `./export`:

```sh
kubectl apply -f manifests.yaml
```

A secret file (a `files` entry whose content is `${resources.<s>.<KEY>}`) is
mounted from the Secret named in the `secret` resource's `params.name`, in the
directory of its target path, next to any plain file there. Its value is in no
ConfigMap. The `files` entry's content must be exactly that placeholder, and
`params.keys` of the resource lists every `<KEY>` the app's files read; score-k8s
refuses a key that is not listed. Create that Secret from `secrets/<env>.example.yaml` (step 5) before
you apply `manifests.yaml`.

## Suffixes, variables and scale

`overrides/<env>/<app>.score.yaml` carries the app's resource limits and
variables; `overrides/<env>/score-k8s-patch.tpl` carries the replica count. Edit
those for the re-render route. The rendered `manifests/` already carry them for
the run-as-exported route.

## Continuous integration

`.github/workflows/exit.yml` runs on GitHub-hosted runners on every push and
pull request:

| Job | What it runs |
|---|---|
| `selftest` | `bin/selftest.sh`: builds a signed export from `testdata/fixture` with a throwaway key and proves `verify.sh` and `check.sh` accept a good export and refuse each bad case |
| `t1` | on `kind` (Kubernetes 1.35, no user namespaces) with Traefik as the default Ingress class: steps 1, 3, 4, 5, 7 (with "A cluster without user namespaces") and 8 against the export in `fixtures/exit-profile/`; every `Deployment` becomes available and the `tick` CronJob's Job completes |
| `t1b` | on `kind` with the Gateway API CRDs, Traefik's Gateway provider with a Gateway named `default`, and the CloudNativePG operator, each from its upstream release: the score-k8s route with its `baseline` label and `examples/score-k8s-allow-ingress.yaml`, then the restore of `fixtures/data/maindb.dump` with `pg_restore` (step 6), then a check that `web` reads its mounted files and variables and answers through the Gateway |

Each cluster job lists its README commands, fails when one is missing from this
file, and runs the same strings. The export is signed in the job with a key it
generates, so the jobs verify with `bin/verify.sh ./export <public-key>`.
`t1b` runs the README's score-k8s commands with `staging`, the fixture's second
environment, in place of `production`. `fixtures/README.md` states what the fixture
is and lists what the jobs leave untested.

## Verify a release

A release is a tag with three assets: `glenr-exit-<tag>.tar.gz`, `SHA256SUMS`
and `SHA256SUMS.sig`. Download the three into one directory, then:

```sh
bin/verify-release.sh <download-dir>   # uses keys/release.pub
```

It checks the Ed25519 signature of `SHA256SUMS` under `keys/release.pub` and
the tarball's SHA-256. The release key and the export key
(`keys/export-signing.pub`) are different keys; a release does not verify under
the export key.

| Key | SHA-256 of the PKIX DER |
|---|---|
| `keys/export-signing.pub` | `ccce020a857b8a61092819e0c436af8b989d492ef0348a7d3f3ff9ce7159c661` |
| `keys/release.pub` | `6adc5013da2b117d697208b7c1aa13ed256e2a6b36190aedfba4293e4d46923f` |

Print a fingerprint with
`openssl pkey -pubin -in keys/release.pub -outform DER | sha256sum`.

The script, the key and this table come from the same place as the release.
Run `bin/verify-release.sh` from a clone of this repository at the release
tag, not from the tarball you are checking, and compare the key's fingerprint
with a copy you obtained separately: one you saved from an earlier release, or
one Glenr gives you on request. The export key's fingerprint is also on the
Glenr data register page, `https://www.glenr.io/data-act`.

## Licence

Apache License 2.0; the text is in `LICENSE`. It covers every file in this
repository, `glenr.provisioners.yaml` included.
