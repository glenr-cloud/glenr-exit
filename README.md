# glenr-exit

Tools to take a Glenr cell export and apply it on a Kubernetes cluster you
operate. Everything here runs with tools you install from their upstream
projects: coreutils, OpenSSL 3, `yq` (mikefarah), `crane`
(`github.com/google/go-containerregistry`), `kubectl` and, for the re-render
route, `score-k8s`.

Licence: Apache-2.0 (`LICENSE`).

Status: this README lists the steps. The end-to-end test of these steps on a
current export (design/145 gate check 6) has not been recorded yet. When it
passes, this section gets the result, its date and whether it ran on a
live cell or a test cell.

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
- `jq` for `bin/images.sh plan`; `crane` and `jq` for `bin/images.sh copy`.

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

### 2. Copy the images out of the zone registry

The images sit in the zone registry, and that registry closes when retrieval
ends. Copy each image, then point the manifests at the registry you copied to
(design/145 §4.4 step 5).

```sh
crane auth login <your-registry>            # once, however your registry wants it
bin/images.sh plan    ./export/images.json  <your-registry>   # optional: list what copy does
bin/images.sh copy    ./export/images.json  <your-registry>
bin/images.sh rewrite ./export/manifests    <your-registry>
```

| Command | What it does |
|---|---|
| `plan` | prints one line per image, `<source>` TAB `<destination>`, and copies nothing |
| `copy` | copies each image to `<your-registry>/<path>`, where `<path>` is the source reference without its registry host (`library/postgres`, not `postgres`). It copies by the `sha256:` digest when `images.json` records one, and by the reference as written (its tag) otherwise |
| `rewrite` | changes only the registry host in every `image:` value and keeps the path and digest, so each reference names a path `copy` filled |

Rows `plan` and `copy` skip, each with a line on stderr:
- a row with no image (the cell's database): nothing to copy;
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

```sh
kubectl apply -f ./export/manifests/production/
```

This applies `_namespace.yaml` again (no change) and every app's objects.

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
too, then render:

```sh
bin/images.sh rewrite ./export/score-k8s <your-registry>
cd ./export
mkdir -p .score-k8s && cp glenr.provisioners.yaml .score-k8s/
score-k8s init --no-sample --patch-templates overrides/production/score-k8s-patch.tpl
score-k8s generate score-k8s/web.yaml \
  --overrides-file overrides/production/web.score.yaml \
  --namespace <namespace> -o manifests.yaml
```

Compare each `image:` in `score-k8s/` with the destinations
`bin/images.sh plan` printed: a path that is not in that list was not copied,
and a pod using it cannot pull its image.

Run `score-k8s generate` once per app in `score-k8s/`, each with its own
`--overrides-file`. `<namespace>` must exist before you apply the result: step 4
creates it, or add `--generate-namespace` to have score-k8s write a Namespace
object. `overrides/README.md` in the export lists the command for
every app.

Keep plain files and secret files in separate directories. score-k8s mounts
the ConfigMap that holds a container's plain files over the whole target
directory, so a secret file in the same directory cannot be mounted inside it:
the pod fails to start with `runc: ... not a directory`. Example: with a plain
file at `/etc/web/config.yaml`, put the secret file at
`/etc/web-secret/token`, not `/etc/web/token`. Change the path in
`score-k8s/<app>.yaml` and in the app's own configuration.

## Suffixes, variables and scale

`overrides/<env>/<app>.score.yaml` carries the app's resource limits and
variables; `overrides/<env>/score-k8s-patch.tpl` carries the replica count. Edit
those for the re-render route. The rendered `manifests/` already carry them for
the run-as-exported route.

## Continuous integration

`.github/workflows/exit.yml` runs `bin/selftest.sh` on every push: it builds a
signed export from `testdata/fixture` with a throwaway key and proves
`verify.sh` and `check.sh` accept a good export and refuse each bad case.
Cluster runs on `kind` are not part of CI yet.

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
