#!/usr/bin/env bash
# selftest.sh — exercise verify.sh, check.sh and images.sh rewrite without a
# cluster and without Glenr. It builds a signed export from testdata/fixture
# with an ephemeral Ed25519 key, proves the tools accept a good export, and
# proves each one refuses the case it exists to catch.
#
# This is the part of gate check 7 that needs no cluster. The kind apply (P-1,
# P-3) runs in the workflow once the EXIT-PROFILE fixture is in place.
#
# Requires: openssl (3), coreutils, jq and yq (mikefarah v4).
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

command -v openssl >/dev/null 2>&1 || { echo "selftest: openssl is required" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "selftest: jq is required" >&2; exit 2; }
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

# A directory named addons holds objects of CRD-based add-ons that the customer
# installs on their own cluster. check.sh skips it, says so, and still refuses
# the same object anywhere else.
echo "== check skips an addons directory (expect ok and a skip line) =="
route='apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: web, namespace: exit-gate-production}
spec:
  rules: []'
d_addons=$work/addons-ok
cp -R "$here/testdata/fixture/manifests" "$d_addons"
mkdir -p "$d_addons/production/addons/gateway-api"
printf '%s\n' "$route" > "$d_addons/production/addons/gateway-api/route.yaml"
addons_out=$("$here/bin/check.sh" "$d_addons") || { echo "SELFTEST FAIL: check refused an addons directory" >&2; exit 1; }
case $addons_out in
	*"skipping $d_addons/production/addons"*) ;;
	*) echo "SELFTEST FAIL: check did not name the skipped addons directory" >&2; exit 1 ;;
esac
echo "  accepted and named the skipped directory"
d_addons_env=$work/addons-env
cp -R "$d_addons/production" "$d_addons_env"
"$here/bin/check.sh" "$d_addons_env" >/dev/null || { echo "SELFTEST FAIL: check refused addons when run on the env directory" >&2; exit 1; }
echo "  accepted with the environment directory as the argument"
echo "== check still refuses the same object outside addons =="
d_route=$work/addons-moved
cp -R "$here/testdata/fixture/manifests" "$d_route"
printf '%s\n' "$route" > "$d_route/production/route.yaml"
if "$here/bin/check.sh" "$d_route" 2>/dev/null; then
	echo "SELFTEST FAIL: check accepted a Gateway API object outside addons" >&2
	exit 1
fi
echo "  refused a Gateway API object outside addons"
echo "== check does not skip a directory it is given as the argument =="
if "$here/bin/check.sh" "$d_addons/production/addons" >/dev/null 2>&1; then
	echo "SELFTEST FAIL: check skipped the addons directory it was asked to check" >&2
	exit 1
fi
echo "  refused the Gateway API object when addons itself is the argument"

# Real exports set metadata.namespace on every namespaced object and Secret; the
# fixture must do the same so the kit is tested against that shape. Namespace is
# the one cluster-scoped kind in the fixture.
echo "== fixture names a namespace on every namespaced object =="
nons=$(find "$here/testdata/fixture/manifests" "$here/testdata/fixture/secrets" -type f -name '*.yaml' | sort |
	while IFS= read -r f; do
		yq -N -r 'select(.kind != "Namespace") | select(.metadata.namespace == null) | .kind + "/" + .metadata.name' "$f"
	done)
if [ -n "$nons" ]; then
	echo "SELFTEST FAIL: objects without metadata.namespace:" >&2
	echo "$nons" >&2
	exit 1
fi
echo "  0 namespaced objects without metadata.namespace"

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

echo "== images.sh rewrite keeps a library/ path =="
if ! grep -q 'registry.customer.example:5000/library/postgres:16' "$rw/manifests/production/postgres.yaml"; then
	echo "SELFTEST FAIL: rewrite did not keep the library/ path" >&2
	grep 'image:' "$rw/manifests/production/postgres.yaml" >&2
	exit 1
fi
echo "  kept library/postgres:16"

# `copy` must skip a row that carries no image (the cell's database): before the
# fix it handed crane an empty reference and the whole of step 5 failed. `plan`
# prints what `copy` would do, without calling crane, so CI can hold both
# properties below.
echo "== images.sh plan skips a row with no image =="
plan_err=$work/plan.err
plan=$("$here/bin/images.sh" plan "$here/testdata/fixture/images.json" registry.customer.example:5000 2>"$plan_err")
if ! grep -q 'skip db (no image)' "$plan_err"; then
	echo "SELFTEST FAIL: plan (and so copy) did not skip the db row, which has no image" >&2
	cat "$plan_err" >&2
	exit 1
fi
if ! plan_rows=$(printf '%s\n' "$plan" | grep -c .); then
	plan_rows=0
fi
if [ "$plan_rows" -ne 2 ]; then
	echo "SELFTEST FAIL: plan printed $plan_rows row(s); want the 2 rows that carry an image" >&2
	printf '%s\n' "$plan" >&2
	exit 1
fi
echo "  skipped the db row, printed 2 rows"

# The destination is not <dest>/<app>: it is the path `rewrite` keeps, so both
# tools name the same place. `copy` writes a repository (a digest names content,
# which the copy preserves; it is not a tag to push), and the manifests keep the
# digest or tag.
plan_row() { # plan_row <src> <dest> — refuse unless plan printed exactly this row
	printf '%s\n' "$plan" | awk -F '\t' -v s="$1" -v d="$2" \
		'$1 == s && $2 == d { found = 1 } END { exit !found }' && return 0
	echo "SELFTEST FAIL: plan has no row '$1 -> $2'" >&2
	printf '%s\n' "$plan" >&2
	exit 1
}
echo "== images.sh plan names the path rewrite keeps =="
plan_row 'registry.glenr.example/acme/web:1.0@sha256:1111111111111111111111111111111111111111111111111111111111111111' \
	'registry.customer.example:5000/acme/web:1.0'
plan_row 'docker.io/library/postgres:16' \
	'registry.customer.example:5000/library/postgres:16'
echo "  destinations use the path, not the app name"

# Every planned destination must be a place the rewritten export pulls from:
# compare repositories, because a copy destination names a repository while the
# manifest names the digest or tag inside it.
repo_of() {
	local r=$1
	r=${r%%@*}
	case "${r##*/}" in
	*:*) r=${r%:*} ;;
	esac
	printf '%s\n' "$r"
}
rewritten=$work/rewritten-images
grep -rh '^[[:space:]]*image:' "$rw/manifests" | sed 's/^[[:space:]]*image:[[:space:]]*//' | sort -u >"$rewritten"
while IFS=$'\t' read -r src to; do
	if [ -z "$src" ]; then
		continue
	fi
	found=0
	while IFS= read -r ref; do
		if [ "$(repo_of "$ref")" = "$(repo_of "$to")" ]; then
			found=1
			break
		fi
	done <"$rewritten"
	if [ "$found" -ne 1 ]; then
		echo "SELFTEST FAIL: copy fills $to; rewrite points at no such path" >&2
		cat "$rewritten" >&2
		exit 1
	fi
done <<<"$plan"
echo "  every plan destination is a rewritten path"

# plan is the CI view of copy, so a row table that does not parse must stop it
# (exit 2). Reading it through a pipeline would hide the jq failure and print
# no rows, which reads as "nothing to copy".
echo "== images.sh plan refuses an images.json that does not parse =="
printf '{"apps": [\n' >"$work/bad-images.json"
if "$here/bin/images.sh" plan "$work/bad-images.json" registry.customer.example:5000 2>/dev/null; then
	echo "SELFTEST FAIL: plan accepted an images.json that does not parse" >&2
	exit 1
fi
echo "  refused"

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
GLENR_EXIT_SELFTEST=1 GLENR_EXIT_RELEASE_SIGNING_KEY=$(cat "$work/key.pem") "$here/bin/release.sh" HEAD \
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

# release.sh refuses before signing when the key is not the release key, when
# the provisioners file differs from the operator copy, when --public-key is
# used outside the self-test, or when the key does not parse. Each case checks
# the reason, so an unrelated failure does not count as a pass.
expect_refusal() { # <message substring> <description> -- command...
	local want=$1 what=$2; shift 3
	if "$@" > /dev/null 2> "$work/err"; then
		echo "SELFTEST FAIL: release.sh accepted $what" >&2; exit 1
	fi
	grep -q -- "$want" "$work/err" || { echo "SELFTEST FAIL: $what refused for another reason:" >&2; cat "$work/err" >&2; exit 1; }
	echo "  refused $what"
}
k=$(cat "$work/key.pem")
expect_refusal "does not match the release public key" "a key that is not keys/release.pub" -- \
	env GLENR_EXIT_RELEASE_SIGNING_KEY="$k" "$here/bin/release.sh" HEAD --provisioners "$here/glenr.provisioners.yaml" --out "$work/rel2"
cp "$here/glenr.provisioners.yaml" "$work/prov-changed.yaml"
echo "# changed" >> "$work/prov-changed.yaml"
expect_refusal "differs from" "a provisioners file that differs" -- \
	env GLENR_EXIT_SELFTEST=1 GLENR_EXIT_RELEASE_SIGNING_KEY="$k" "$here/bin/release.sh" HEAD --provisioners "$work/prov-changed.yaml" --public-key "$work/pub.pem" --out "$work/rel3"
expect_refusal "self-test only" "--public-key outside the self-test" -- \
	env -u GLENR_EXIT_SELFTEST GLENR_EXIT_RELEASE_SIGNING_KEY="$k" "$here/bin/release.sh" HEAD --provisioners "$here/glenr.provisioners.yaml" --public-key "$work/pub.pem" --out "$work/rel4"
expect_refusal "not a PEM private key" "a key that does not parse" -- \
	env GLENR_EXIT_RELEASE_SIGNING_KEY='not a key' "$here/bin/release.sh" HEAD --provisioners "$here/glenr.provisioners.yaml" --out "$work/rel5"

echo "SELFTEST OK"
