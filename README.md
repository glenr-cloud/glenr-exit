# glenr-exit

Tools to take a Glenr cell export and apply it on a Kubernetes cluster you
operate. Everything here runs with tools you install from their upstream
projects: coreutils, OpenSSL 3, `yq` (mikefarah), `crane`
(`github.com/google/go-containerregistry`), `kubectl` and, for the re-render
route, `score-k8s`.

Status: private, under construction. Design:
`glenr-cloud/ovi` `design/145-exit-to-plain-kubernetes.md` §5. This repository
goes public and takes its licence at lane PUBLISH (D-145.6, D-145.7).

## What an export holds

An export is a directory. The parts these tools act on:

| Path | Holds |
|---|---|
| `MANIFEST`, `MANIFEST.sig` | every file and its SHA-256, and the Ed25519 signature of `MANIFEST` |
| `manifests/<env>/` | the rendered Kubernetes objects for one environment, one file per app |
| `manifests/<env>/addons/` | optional objects (Gateway API routes, a CloudNativePG cluster) |
| `secrets/<env>.example.yaml` | each Secret the workloads expect, all values empty |
| `images.json` | per app and environment: the image and the digest it was built at |
| `score-k8s/`, `overrides/<env>/`, `glenr.provisioners.yaml` | inputs for the re-render route below |

`manifests/README.md` in the export carries the apply order and what the export
does not reproduce. `secrets/<env>.example.yaml` lists the secret key names;
values are write-only in Glenr and are not in the export.

## Prerequisites

- `kubectl` pointed at your cluster.
- `openssl` (3.x), `sha256sum`, `base64` (coreutils) for `bin/verify.sh`.
- `yq` v4 (Mike Farah) for `bin/check.sh` and `bin/images.sh rewrite`.
- `crane` and `jq` for `bin/images.sh copy`.

## Steps

### 1. Verify the export

```sh
bin/verify.sh ./export              # uses keys/export-signing.pub
bin/verify.sh ./export <public-key> # or a key you saved from the export page
```

`bin/verify.sh` checks the `MANIFEST` signature, that every listed file hashes
to its recorded value, and that no file is present that `MANIFEST` does not
list. The default public key is `keys/export-signing.pub` in this repository;
you can also pass the key printed on the page where you downloaded the export.

### 2. Copy the images out of the zone registry

The images sit in the zone registry, and that registry closes when retrieval
ends. Copy each digest, then point the manifests at the registry you copied to
(design/145 §4.4 step 5).

```sh
crane auth login <your-registry>            # once, however your registry wants it
bin/images.sh copy    ./export/images.json  <your-registry>
bin/images.sh rewrite ./export/manifests    <your-registry>
```

`copy` keeps each `sha256:` digest; `rewrite` changes only the registry host in
every `image:` value and leaves the path and digest.

### 3. Fill the secrets

`secrets/<env>.example.yaml` lists each Secret and its keys with empty values.
Fill them from your own record and apply:

```sh
kubectl apply -f secrets/production.yaml
```

### 4. Restore the database

The export does not carry a database object: you supply a PostgreSQL of the
same or a later major as the export records (design/145 §3.1, §4.3). Restore
the dump you received, then confirm the row counts match the export's record
before you apply the workloads.

### 5. Check the manifest set

```sh
bin/check.sh manifests/production
```

`bin/check.sh` refuses a manifest set that an export must never contain: an
apiVersion outside the allowed groups (core, apps, batch, autoscaling, policy,
networking.k8s.io), the string `glenr.io`, or a Secret with a value. Run it
before you apply.

### 6. Apply

```sh
kubectl apply -f manifests/production/_namespace.yaml
kubectl apply -f manifests/production/
```

`_namespace.yaml` goes first: it creates the Namespace, the ResourceQuota, the
LimitRange and the default-deny NetworkPolicy the workloads expect.

### 7. Confirm

```sh
kubectl -n production rollout status deploy/web --timeout=10m
curl -s http://<host>/exit-check
```

`/exit-check` prints a SHA-256 of each mounted file, of the environment secret
and of the values variable, confirms the scratch volume accepts a write, and
prints the row count of the seeded table.

## The second route: re-render with score-k8s

Instead of applying the rendered `manifests/`, you can render again from the
Score documents with `score-k8s`:

```sh
score-k8s init --no-sample
cp glenr.provisioners.yaml .score-k8s/
score-k8s generate -n production -o manifests.yaml \
  score-k8s/web.yaml overrides/production/web.score.yaml
```

Divergences between this route and the export's renderer, per resource type, are
listed in the provisioners parity test and the CI summary.

## Suffixes, variables and scale

`overrides/<env>/<app>.score.yaml` carries the app's resource limits and
variables; `overrides/<env>/score-k8s-patch.tpl` carries the replica count. Edit
those for the re-render route. The rendered `manifests/` already carry them for
the run-as-exported route.

## Continuous integration

`.github/workflows/exit.yml` runs `bin/selftest.sh` on every push: it builds a
signed export from `testdata/fixture` with a throwaway key and proves
`verify.sh` and `check.sh` accept a good export and refuse each bad case. The
cluster runs (T1 with `kind`, T1b with the Gateway API and CloudNativePG) run
once the full exit fixture from the exit-profile work is committed under
`testdata/fixture-export/`.

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

## Licence

Pending (design/145 R-145.7).
