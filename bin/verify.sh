#!/usr/bin/env bash
# verify.sh — check a Glenr cell export with upstream tools only.
#
# A Glenr export carries a MANIFEST (every file and its SHA-256, `sha256sum`
# format) and MANIFEST.sig (the Ed25519 signature of MANIFEST's bytes, base64).
# This script does the three checks the export's own page describes
# (design/145 §5.1), with coreutils and OpenSSL 3 and nothing from Glenr:
#
#   1. MANIFEST.sig is a valid signature of MANIFEST under the public key.
#   2. Every file listed in MANIFEST hashes to its recorded SHA-256.
#   3. No file in the directory is missing from MANIFEST (an added file is a
#      changed export).
#
# Usage: bin/verify.sh <export-dir> [public-key]
#   <export-dir>   the directory the export was unpacked into (holds MANIFEST)
#   [public-key]   PKIX PEM public key; default keys/export-signing.pub
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
	echo "usage: $0 <export-dir> [public-key]" >&2
	exit 2
fi

dir=${1%/}
pub=${2:-}
here=$(cd "$(dirname "$0")/.." && pwd)
pub=${pub:-"$here/keys/export-signing.pub"}

fail() { echo "verify: $*" >&2; exit 1; }

[ -d "$dir" ] || fail "$dir is not a directory"
[ -f "$dir/MANIFEST" ] || fail "$dir/MANIFEST is missing"
[ -f "$dir/MANIFEST.sig" ] || fail "$dir/MANIFEST.sig is missing"
[ -f "$pub" ] || fail "public key $pub is missing"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# 1. Signature. The decoded signature must live outside the export directory:
#    a stray file inside would be an unlisted file and fail step 3.
base64 -d "$dir/MANIFEST.sig" > "$tmp/MANIFEST.sig.bin" || fail "MANIFEST.sig is not base64"
if ! openssl pkeyutl -verify -pubin -inkey "$pub" -rawin \
	-in "$dir/MANIFEST" -sigfile "$tmp/MANIFEST.sig.bin" >/dev/null 2>&1; then
	fail "MANIFEST.sig does not verify under $pub (wrong export or wrong key)"
fi

# 2. Every listed file hashes correctly. Run from the export root so the
#    relative paths in MANIFEST resolve. --strict refuses a malformed line.
( cd "$dir" && sha256sum -c --strict MANIFEST >/dev/null ) || fail "a file does not match MANIFEST"

# 3. Every file present is listed. Enumerate the regular files and symlinks
#    below the export root, drop MANIFEST and MANIFEST.sig (the signer writes
#    those and never lists them), and compare the two sets both ways. A
#    symlink is counted: for an export it is always tampering, and kubectl
#    follows a symlinked manifest in directory mode.
cut -c67- "$dir/MANIFEST" | sort > "$tmp/listed"
( cd "$dir" && find . \( -type f -o -type l \) | sed 's|^\./||' ) \
	| grep -v -x -e 'MANIFEST' -e 'MANIFEST.sig' | sort > "$tmp/present" || true

if extra=$(comm -13 "$tmp/listed" "$tmp/present") && [ -n "$extra" ]; then
	echo "verify: files present but not listed in MANIFEST:" >&2
	echo "$extra" >&2
	exit 1
fi
if missing=$(comm -23 "$tmp/listed" "$tmp/present") && [ -n "$missing" ]; then
	echo "verify: files listed in MANIFEST but absent:" >&2
	echo "$missing" >&2
	exit 1
fi

echo "verify: ok ($(wc -l < "$tmp/listed" | tr -d ' ') files, signed and complete)"
