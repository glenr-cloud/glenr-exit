#!/usr/bin/env bash
# selftest.sh — exercise verify.sh, check.sh and images.sh rewrite without a
# cluster and without Glenr. It builds a signed export from testdata/fixture
# with an ephemeral Ed25519 key, proves the tools accept a good export, and
# proves each one refuses the case it exists to catch.
#
# This is the part of gate check 7 that needs no cluster. The kind apply (P-1,
# P-3) runs in the workflow once the EXIT-PROFILE fixture is in place.
#
# Requires: openssl (3), coreutils, yq (mikefarah v4).
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

command -v openssl >/dev/null 2>&1 || { echo "selftest: openssl is required" >&2; exit 2; }
command -v yq >/dev/null 2>&1 || { echo "selftest: yq (mikefarah v4) is required" >&2; exit 2; }

exp=$work/export
cp -R "$here/testdata/fixture" "$exp"

# Ephemeral signing key: verify.sh's real key is keys/export-signing.pub, which
# PUBLISH fills from the deployed register key. A throwaway key lets this test
# run without it.
openssl genpkey -algorithm ed25519 -out "$work/key.pem" 2>/dev/null
openssl pkey -in "$work/key.pem" -pubout -out "$work/pub.pem" 2>/dev/null

# MANIFEST in `sha256sum` format, sorted by path, excluding the two files the
# signer writes.
(
	cd "$exp"
	find . -type f ! -name MANIFEST ! -name MANIFEST.sig | sed 's|^\./||' | sort |
		while IFS= read -r p; do
			printf '%s  %s\n' "$(sha256sum "$p" | cut -d' ' -f1)" "$p"
		done > MANIFEST
)
openssl pkeyutl -sign -inkey "$work/key.pem" -rawin -in "$exp/MANIFEST" | base64 -w0 > "$exp/MANIFEST.sig"
echo >> "$exp/MANIFEST.sig"

echo "== verify a good export (expect ok) =="
"$here/bin/verify.sh" "$exp" "$work/pub.pem"

echo "== check a good manifest set (expect ok) =="
"$here/bin/check.sh" "$exp/manifests"

echo "== verify refuses a changed file (expect refusal) =="
echo "# tampered" >> "$exp/manifests/production/web.yaml"
if "$here/bin/verify.sh" "$exp" "$work/pub.pem" 2>/dev/null; then
	echo "SELFTEST FAIL: verify accepted a changed file" >&2
	exit 1
fi
echo "  refused as expected"

echo "== verify refuses an added file (expect refusal) =="
exp2=$work/export2
cp -R "$here/testdata/fixture" "$exp2"
(
	cd "$exp2"
	find . -type f ! -name MANIFEST ! -name MANIFEST.sig | sed 's|^\./||' | sort |
		while IFS= read -r p; do printf '%s  %s\n' "$(sha256sum "$p" | cut -d' ' -f1)" "$p"; done > MANIFEST
)
openssl pkeyutl -sign -inkey "$work/key.pem" -rawin -in "$exp2/MANIFEST" | base64 -w0 > "$exp2/MANIFEST.sig"
echo >> "$exp2/MANIFEST.sig"
echo "extra" > "$exp2/manifests/production/extra.yaml"
if "$here/bin/verify.sh" "$exp2" "$work/pub.pem" 2>/dev/null; then
	echo "SELFTEST FAIL: verify accepted an unlisted file" >&2
	exit 1
fi
echo "  refused as expected"

# check.sh must refuse each of the three things it exists to catch.
plant_and_expect_refusal() {
	local label=$1 body=$2
	local d
	d="$work/bad-$(echo "$label" | tr -c 'a-z0-9' '-')"
	cp -R "$here/testdata/fixture/manifests" "$d"
	printf '%s\n' "$body" >> "$d/production/web.yaml"
	if "$here/bin/check.sh" "$d" 2>/dev/null; then
		echo "SELFTEST FAIL: check accepted $label" >&2
		exit 1
	fi
	echo "  refused $label as expected"
}
echo "== check refuses a non-allowlisted apiVersion =="
plant_and_expect_refusal "a Cilium object" '---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: bad}'
echo "== check refuses a glenr.io key =="
plant_and_expect_refusal "a glenr.io key" '---
apiVersion: apps/v1
kind: Deployment
metadata: {name: bad}
spec:
  template:
    spec:
      nodeSelector: {"node-role.glenr.io/customer": "true"}
      containers: [{name: x, image: x}]'
echo "== check refuses a Secret with a value =="
plant_and_expect_refusal "a Secret with data" '---
apiVersion: v1
kind: Secret
metadata: {name: leak}
data: {k: aGVsbG8=}'

# A malicious object can hide inside a `kind: List` or a .json file; both are
# applied by kubectl in directory mode, so check.sh must inspect them.
d_list=$work/bad-list
cp -R "$here/testdata/fixture/manifests" "$d_list"
cat >> "$d_list/production/web.yaml" <<'YAML'
---
apiVersion: v1
kind: List
items:
- apiVersion: cilium.io/v2
  kind: CiliumNetworkPolicy
  metadata: {name: hidden}
YAML
if "$here/bin/check.sh" "$d_list" 2>/dev/null; then
	echo "SELFTEST FAIL: check accepted a Cilium object inside a List" >&2
	exit 1
fi
echo "  refused a Cilium object inside a List"
echo "== check refuses a bad object in a .json file =="
d_json=$work/bad-json
cp -R "$here/testdata/fixture/manifests" "$d_json"
cat > "$d_json/production/bad.json" <<'JSON'
{"apiVersion": "cilium.io/v2", "kind": "CiliumNetworkPolicy", "metadata": {"name": "bad"}}
JSON
if "$here/bin/check.sh" "$d_json" 2>/dev/null; then
	echo "SELFTEST FAIL: check accepted a Cilium object in a .json file" >&2
	exit 1
fi
echo "  refused a .json violation"
echo "== check refuses a file that does not parse =="
d_bad=$work/bad-yaml
cp -R "$here/testdata/fixture/manifests" "$d_bad"
printf 'apiVersion: v1\n  bad: [unclosed\n' > "$d_bad/production/broken.yaml"
if "$here/bin/check.sh" "$d_bad" 2>/dev/null; then
	echo "SELFTEST FAIL: check passed over unparsable YAML (fail-open)" >&2
	exit 1
fi
echo "  refused unparsable YAML"

# verify.sh must refuse a symlink added to a signed export: kubectl follows a
# symlinked manifest in directory mode.
echo "== verify refuses an added symlink =="
exp3=$work/export3
cp -R "$here/testdata/fixture" "$exp3"
(
	cd "$exp3"
	find . \( -type f -o -type l \) ! -name MANIFEST ! -name MANIFEST.sig | sed 's|^\./||' | sort |
		while IFS= read -r p; do printf '%s  %s\n' "$(sha256sum "$p" | cut -d' ' -f1)" "$p"; done > MANIFEST
)
openssl pkeyutl -sign -inkey "$work/key.pem" -rawin -in "$exp3/MANIFEST" | base64 -w0 > "$exp3/MANIFEST.sig"
echo >> "$exp3/MANIFEST.sig"
ln -s /etc/hostname "$exp3/manifests/production/evil.yaml"
if "$here/bin/verify.sh" "$exp3" "$work/pub.pem" 2>/dev/null; then
	echo "SELFTEST FAIL: verify accepted an added symlink" >&2
	exit 1
fi
echo "  refused an added symlink"

echo "== images.sh rewrite changes the host and keeps the digest =="
rw=$work/rw
cp -R "$here/testdata/fixture" "$rw"
"$here/bin/images.sh" rewrite "$rw/manifests" registry.customer.example:5000
if ! grep -q 'registry.customer.example:5000/acme/web@sha256:1111111111111111111111111111111111111111111111111111111111111111' \
	"$rw/manifests/production/web.yaml"; then
	echo "SELFTEST FAIL: rewrite did not keep the path and digest" >&2
	grep 'image:' "$rw/manifests/production/web.yaml" >&2
	exit 1
fi
echo "  rewrote host, kept digest"

# The two published keys: each is an Ed25519 PEM public key, and they differ
# (design/145 §5.1: a release signed with the export key would verify as an
# export).
echo "== keys/export-signing.pub and keys/release.pub are distinct Ed25519 keys =="
fp() { openssl pkey -pubin -in "$1" -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1; }
for k in export-signing release; do
	openssl pkey -pubin -in "$here/keys/$k.pub" -noout -text 2>/dev/null | grep -q '^ED25519 Public-Key' \
		|| { echo "SELFTEST FAIL: keys/$k.pub is not an Ed25519 public key" >&2; exit 1; }
done
[ "$(fp "$here/keys/export-signing.pub")" != "$(fp "$here/keys/release.pub")" ] \
	|| { echo "SELFTEST FAIL: the export key and the release key are the same" >&2; exit 1; }
echo "  two distinct Ed25519 keys"

# release.sh builds and signs with the key in the environment; verify-release.sh
# accepts it under the matching key and refuses every other key and a changed
# tarball. The throwaway key stands in for the release key.
echo "== release.sh and verify-release.sh =="
rel=$work/rel
GLENR_EXIT_RELEASE_SIGNING_KEY=$(cat "$work/key.pem") "$here/bin/release.sh" HEAD \
	--provisioners "$here/glenr.provisioners.yaml" --public-key "$work/pub.pem" --out "$rel" >/dev/null
"$here/bin/verify-release.sh" "$rel" "$work/pub.pem" >/dev/null
echo "  built and verified under the signing key"
for k in "$here/keys/export-signing.pub" "$here/keys/release.pub"; do
	if "$here/bin/verify-release.sh" "$rel" "$k" 2>/dev/null; then
		echo "SELFTEST FAIL: release verified under $k, which did not sign it" >&2
		exit 1
	fi
done
echo "  refused under keys/export-signing.pub and keys/release.pub"
tarball=$(ls "$rel"/*.tar.gz)
printf 'x' >> "$tarball"
if "$here/bin/verify-release.sh" "$rel" "$work/pub.pem" 2>/dev/null; then
	echo "SELFTEST FAIL: verify-release accepted a changed tarball" >&2
	exit 1
fi
echo "  refused a changed tarball"

# release.sh refuses before signing when the key is not the release key, or when
# the provisioners file differs from the operator copy.
if GLENR_EXIT_RELEASE_SIGNING_KEY=$(cat "$work/key.pem") "$here/bin/release.sh" HEAD \
	--provisioners "$here/glenr.provisioners.yaml" --out "$work/rel2" 2>/dev/null; then
	echo "SELFTEST FAIL: release.sh signed with a key that is not keys/release.pub" >&2
	exit 1
fi
echo "  refused a key that is not keys/release.pub"
cp "$here/glenr.provisioners.yaml" "$work/prov-changed.yaml"
echo "# changed" >> "$work/prov-changed.yaml"
if GLENR_EXIT_RELEASE_SIGNING_KEY=$(cat "$work/key.pem") "$here/bin/release.sh" HEAD \
	--provisioners "$work/prov-changed.yaml" --public-key "$work/pub.pem" --out "$work/rel3" 2>/dev/null; then
	echo "SELFTEST FAIL: release.sh accepted a provisioners file that differs from the operator copy" >&2
	exit 1
fi
echo "  refused a provisioners file that differs"

echo "SELFTEST OK"
