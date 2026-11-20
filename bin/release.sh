#!/usr/bin/env bash
# release.sh — build and sign a release of this repository (design/145 §5.1).
#
# A release is a git tag plus three assets:
#
#   glenr-exit-<ref>.tar.gz   `git archive` of <ref>, gzip with no timestamp
#   SHA256SUMS                the tarball's SHA-256, `sha256sum` format
#   SHA256SUMS.sig            Ed25519 signature of SHA256SUMS's bytes, base64
#
# The signing key is the release key, separate from the export key: SHA256SUMS
# and an export's MANIFEST share one format, so a release signed with the export
# key would also verify as a signed export (design/145 §5.1). The private key is
# read from the environment variable GLENR_EXIT_RELEASE_SIGNING_KEY (PKIX PEM)
# and passed to OpenSSL through a pipe; it is never written to disk.
#
# Before signing, the script refuses when:
#   - the key's public half differs from keys/release.pub at <ref>;
#   - glenr.provisioners.yaml at <ref> differs from the file given with
#     --provisioners (the operator's render/export/glenr.provisioners.yaml,
#     the same file the export carries).
#
# Usage: bin/release.sh <ref> --provisioners <file> [--out <dir>] [--public-key <file>]
#   <ref>              the tag to release (any commit-ish is accepted)
#   --provisioners     the operator copy of glenr.provisioners.yaml to compare
#   --out              output directory; default dist/<ref>
#   --public-key       compare the key against this file instead of
#                      keys/release.pub at <ref>; refused unless
#                      GLENR_EXIT_SELFTEST=1 (self-test only)
set -euo pipefail

usage() { echo "usage: $0 <ref> --provisioners <file> [--out <dir>] [--public-key <file>]" >&2; exit 2; }
fail() { echo "release: $*" >&2; exit 1; }

[ "$#" -ge 1 ] || usage
ref=$1; shift
prov= out= pubfile=
while [ "$#" -gt 0 ]; do
	case $1 in
	--provisioners) [ "$#" -ge 2 ] || usage; prov=$2; shift 2 ;;
	--out) [ "$#" -ge 2 ] || usage; out=$2; shift 2 ;;
	--public-key) [ "$#" -ge 2 ] || usage; pubfile=$2; shift 2 ;;
	*) usage ;;
	esac
done
[ -n "$prov" ] || usage
[ -f "$prov" ] || fail "provisioners file $prov is missing"
[ -z "$pubfile" ] || [ "${GLENR_EXIT_SELFTEST:-}" = 1 ] || fail "--public-key is for the self-test only (set GLENR_EXIT_SELFTEST=1)"
[ -n "${GLENR_EXIT_RELEASE_SIGNING_KEY:-}" ] || fail "GLENR_EXIT_RELEASE_SIGNING_KEY is not set"
# Keep the key in this shell only: child processes (git, gzip, sha256sum) do
# not inherit it.
key=$GLENR_EXIT_RELEASE_SIGNING_KEY
unset GLENR_EXIT_RELEASE_SIGNING_KEY

here=$(cd "$(dirname "$0")/.." && pwd)
git -C "$here" rev-parse --verify --quiet "$ref^{commit}" >/dev/null || fail "$ref is not a commit in $here"
name=glenr-exit-${ref//\//-}
out=${out:-"$here/dist/${ref//\//-}"}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# 1. The key matches the public key the release names.
if [ -n "$pubfile" ]; then
	cp "$pubfile" "$tmp/release.pub"
else
	git -C "$here" show "$ref:keys/release.pub" > "$tmp/release.pub" 2>/dev/null || fail "keys/release.pub is missing at $ref"
fi
want=$(openssl pkey -pubin -in "$tmp/release.pub" -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1) \
	|| fail "the release public key is not a PEM public key"
have=$(printf '%s\n' "$key" | openssl pkey -pubout -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1) \
	|| fail "GLENR_EXIT_RELEASE_SIGNING_KEY is not a PEM private key"
[ "$want" = "$have" ] || fail "the signing key does not match the release public key (want $want)"

# 2. The provisioners file is the one the export carries.
git -C "$here" show "$ref:glenr.provisioners.yaml" > "$tmp/prov.yaml" 2>/dev/null || fail "glenr.provisioners.yaml is missing at $ref"
cmp -s "$tmp/prov.yaml" "$prov" || fail "glenr.provisioners.yaml at $ref differs from $prov"

# 3. Tarball, sums, signature.
mkdir -p "$out"
git -C "$here" archive --format=tar --prefix="$name/" "$ref" | gzip -n -9 > "$out/$name.tar.gz"
( cd "$out" && sha256sum "$name.tar.gz" > SHA256SUMS )
printf '%s\n' "$key" \
	| openssl pkeyutl -sign -inkey /dev/stdin -rawin -in "$out/SHA256SUMS" \
	| base64 -w0 > "$out/SHA256SUMS.sig"
echo >> "$out/SHA256SUMS.sig"

# 4. Check what was written with the verifier shipped at <ref>: it verifies
#    under the release key and does not verify under the export key (gate
#    check 9).
git -C "$here" show "$ref:bin/verify-release.sh" > "$tmp/verify-release.sh" 2>/dev/null || fail "bin/verify-release.sh is missing at $ref"
git -C "$here" show "$ref:keys/export-signing.pub" > "$tmp/export-signing.pub" 2>/dev/null || fail "keys/export-signing.pub is missing at $ref"
bash "$tmp/verify-release.sh" "$out" "$tmp/release.pub" >/dev/null || fail "the written release does not verify"
if bash "$tmp/verify-release.sh" "$out" "$tmp/export-signing.pub" >/dev/null 2>&1; then
	fail "the written release also verifies under keys/export-signing.pub"
fi
echo "release: $out/$name.tar.gz, SHA256SUMS, SHA256SUMS.sig (key $want)"
