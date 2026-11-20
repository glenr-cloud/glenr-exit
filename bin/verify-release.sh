#!/usr/bin/env bash
# verify-release.sh — check a downloaded release of this repository with
# coreutils and OpenSSL 3 only.
#
#   1. SHA256SUMS.sig is a valid Ed25519 signature of SHA256SUMS under the
#      release public key (keys/release.pub, not the export key).
#   2. Every file SHA256SUMS lists is present and hashes to its recorded value.
#
# Usage: bin/verify-release.sh <dir> [public-key]
#   <dir>          the directory holding SHA256SUMS, SHA256SUMS.sig and the tarball
#   [public-key]   PKIX PEM public key; default keys/release.pub
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
	echo "usage: $0 <dir> [public-key]" >&2
	exit 2
fi

dir=${1%/}
here=$(cd "$(dirname "$0")/.." && pwd)
pub=${2:-"$here/keys/release.pub"}

fail() { echo "verify-release: $*" >&2; exit 1; }

[ -f "$dir/SHA256SUMS" ] || fail "$dir/SHA256SUMS is missing"
[ -f "$dir/SHA256SUMS.sig" ] || fail "$dir/SHA256SUMS.sig is missing"
[ -f "$pub" ] || fail "public key $pub is missing"
[ -s "$dir/SHA256SUMS" ] || fail "$dir/SHA256SUMS is empty"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

base64 -d "$dir/SHA256SUMS.sig" > "$tmp/sig.bin" 2>/dev/null || fail "SHA256SUMS.sig is not base64"
if ! openssl pkeyutl -verify -pubin -inkey "$pub" -rawin \
	-in "$dir/SHA256SUMS" -sigfile "$tmp/sig.bin" >/dev/null 2>&1; then
	fail "SHA256SUMS.sig does not verify under $pub"
fi

( cd "$dir" && sha256sum -c --strict SHA256SUMS >/dev/null ) || fail "a file does not match SHA256SUMS"

echo "verify-release: ok, signed by $pub:"
cut -c67- "$dir/SHA256SUMS" | sed 's/^/  /'
