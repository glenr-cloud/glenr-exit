#!/usr/bin/env bash
# make-test-export.sh — CI helper: turn the committed fixture into a signed
# export the README steps can run against.
#
# The deployed export key signs real exports and its private half is not in
# this repository, so CI cannot sign with it. This script signs with a key it
# generates, writes the matching public key beside the export, and the workflow
# passes that key to verify.sh (the README's `bin/verify.sh ./export <public-key>`
# form). It does not touch keys/export-signing.pub.
#
# Usage: bin/make-test-export.sh <fixture-dir> <export-dir> <key-dir>
#   writes <export-dir>/** (the fixture plus MANIFEST and MANIFEST.sig),
#   <key-dir>/key.pem and <key-dir>/pub.pem
set -euo pipefail

if [ "$#" -ne 3 ]; then
	echo "usage: $0 <fixture-dir> <export-dir> <key-dir>" >&2
	exit 2
fi
src=${1%/}
dst=${2%/}
keys=${3%/}

[ -d "$src" ] || { echo "make-test-export: $src is not a directory" >&2; exit 2; }
[ ! -e "$dst" ] || { echo "make-test-export: $dst exists" >&2; exit 2; }

mkdir -p "$keys"
cp -R "$src" "$dst"
openssl genpkey -algorithm ed25519 -out "$keys/key.pem" 2>/dev/null
openssl pkey -in "$keys/key.pem" -pubout -out "$keys/pub.pem" 2>/dev/null

(
	cd "$dst"
	find . -type f ! -name MANIFEST ! -name MANIFEST.sig | sed 's|^\./||' | sort |
		while IFS= read -r p; do
			printf '%s  %s\n' "$(sha256sum "$p" | cut -d' ' -f1)" "$p"
		done > MANIFEST
)
openssl pkeyutl -sign -inkey "$keys/key.pem" -rawin -in "$dst/MANIFEST" | base64 -w0 > "$dst/MANIFEST.sig"
echo >> "$dst/MANIFEST.sig"
echo "make-test-export: $dst signed ($(wc -l < "$dst/MANIFEST") files)"
