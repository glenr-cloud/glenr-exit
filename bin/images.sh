#!/usr/bin/env bash
# images.sh — move a cell export's images to a registry the customer controls.
# Usage:
#   bin/images.sh plan    <images.json> <dest-registry>   # print src<TAB>dest per row
#   bin/images.sh copy    <images.json> <dest-registry>   # copy each image out
#   bin/images.sh load    <images.json> <images-dir> <env> <dest-registry>  # push hand-over archives
#   bin/images.sh rewrite <manifests-dir> <dest-registry> # point the manifests at it
#
# `plan` reads images.json (per app, per environment: the image and its
# `sha256:` digest) and prints, one row per image, the reference `copy` reads
# and the repository it writes, without calling `crane`. CI uses it to prove
# `copy` and `rewrite` name the same path.
#
# `copy` copies each image by digest to <dest-registry>/<path> with `crane`, so
# the digest is preserved. It reads the reference in images.json, so it serves an
# image in a public registry; an image in the zone registry needs a credential
# Glenr does not hand over, and goes through `load`. A digest that names an index
# is copied whole: every platform it lists. A row with no image (the cell's
# database) carries nothing to copy and is skipped.
#
# `load` pushes the images Glenr hands over as OCI archives, for an image that
# sits in the zone registry. Glenr hands over no credential for that registry, so
# `copy` cannot read it; the hand-over holds `<images-dir>/<env>/<app>.tar` for
# each such image instead (an `oci-archive`, one image per file). For every row of
# <env> in images.json, `load` extracts the archive and refuses it unless every
# file under blobs/sha256/ hashes to its own name and the manifest's SHA-256
# equals the digest `images.json` records for the row. It then pushes the archive
# with `crane` to the destination `copy` would write (<dest-registry>/<path>) and
# reads the digest back from the destination. The digest does not change. A row
# with no archive at that path is skipped with a line on stderr: it is an image
# `copy` moves from a public registry. `load` fails when it loaded nothing. It
# handles the rows in order: a refusal stops it, and rows pushed before it stay.
#
# `rewrite` changes the registry host of every `image:` value under the
# manifests directory to <dest-registry>, keeping the path and the digest, so
# the applied objects pull from the registry `copy` filled. Run it after copy
# and before apply.
#
# The registry host is the segment before the first '/'. `copy`, `plan` and
# `rewrite` all take the path after it from image_path(), so a rewritten
# reference cannot name a path `copy` did not fill. A reference with no '/'
# names no host: `rewrite` leaves it as it is (the object keeps pulling the
# image from where it points today), so `copy` skips it too.
#
# copy requires `crane` (github.com/google/go-containerregistry) and `jq`;
# load requires `crane`, `jq`, `tar` and `sha256sum`; plan requires `jq`;
# rewrite requires `yq` (mikefarah, v4).
set -euo pipefail

usage() {
	sed -n '3,7p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 2
}

# image_path <reference> — the part of an image reference after its registry
# host: what `rewrite` puts <dest-registry>/ in front of and keeps, digest and
# tag included. Returns 1 for a reference with no host ('postgres:16').
image_path() {
	case "$1" in
	*/*) printf '%s\n' "${1#*/}" ;;
	*) return 1 ;;
	esac
}

# image_rows <images.json> <dest-registry> [env] — one line per row `copy` moves
# (only the rows of <env> when it is given):
# <app> TAB <src> TAB <dest>. <src> is the image, pinned by digest when the row
# or the digest names one; <dest> is <dest-registry>/<image_path>, with the
# digest dropped because `crane copy` writes a tag or repository (the copied
# content keeps the digest the manifests pull). Rows with no image and rows
# naming no host are skipped, with a line on stderr.
image_rows() {
	local images=$1 dest=${2%/} env=${3:-} app image digest src path rows
	# Read every row before the loop: a row table that does not parse must stop
	# the caller, not read as an empty images.json.
	if ! rows=$(jq -r --arg env "$env" '.apps[]? | .name as $n | .environments[]? | select($env == "" or .environment == $env) | [$n, (.image // ""), (.digest // "")] | @tsv' "$images"); then
		echo "images: $images is not a JSON images.json" >&2
		return 1
	fi
	while IFS=$'\t' read -r app image digest; do
		if [ -z "$app" ]; then
			continue
		fi
		if [ -z "$image" ]; then
			echo "images: skip $app (no image)" >&2
			continue
		fi
		if ! path=$(image_path "$image"); then
			echo "images: skip $app ($image names no registry host; rewrite leaves it as it is)" >&2
			continue
		fi
		src=$image
		# Prefer the digest: copying by digest preserves it at the destination.
		case "$image" in
		*@sha256:*) : ;;
		*) if [ -n "$digest" ]; then src="$image@$digest"; fi ;;
		esac
		printf '%s\t%s\t%s\n' "$app" "$src" "$dest/${path%%@*}"
	done <<<"$rows"
}

[ "$#" -ge 1 ] || usage
cmd=$1
case "$cmd" in
load) [ "$#" -eq 5 ] || usage ;;
*) [ "$#" -eq 3 ] || usage ;;
esac

case "$cmd" in
plan)
	images=${2}
	dest=${3%/}
	command -v jq >/dev/null 2>&1 || { echo "images: jq is required" >&2; exit 2; }
	[ -f "$images" ] || { echo "images: $images not found" >&2; exit 2; }
	rows=$(image_rows "$images" "$dest") || exit 2
	while IFS=$'\t' read -r app src to; do
		if [ -z "$app" ]; then
			continue
		fi
		printf '%s\t%s\n' "$src" "$to"
	done <<<"$rows"
	;;
copy)
	images=${2}
	dest=${3%/}
	command -v crane >/dev/null 2>&1 || { echo "images: crane is required" >&2; exit 2; }
	command -v jq >/dev/null 2>&1 || { echo "images: jq is required" >&2; exit 2; }
	[ -f "$images" ] || { echo "images: $images not found" >&2; exit 2; }
	rows=$(image_rows "$images" "$dest") || exit 2
	# The rows the file lists, before the skips above: an export that lists no
	# row at all is broken; an export that lists rows none of which need a copy
	# is not.
	listed=$(jq -r '[.apps[]? | .environments[]?] | length' "$images") || exit 2
	copied=0
	while IFS=$'\t' read -r app src to; do
		if [ -z "$app" ]; then
			continue
		fi
		echo "images: copy $src -> $to"
		crane copy "$src" "$to"
		copied=$((copied + 1))
	done <<<"$rows"
	if [ "$copied" -eq 0 ]; then
		# An export whose images are all public (no registry host to swap) and a
		# database-only export legitimately need no copy.
		if [ "$listed" -eq 0 ]; then
			echo "images: images.json lists no images to copy" >&2
			exit 1
		fi
		echo "images: nothing to copy (every row has no image or no registry host)"
		exit 0
	fi
	echo "images: copied $copied image(s) to $dest"
	;;
load)
	images=${2}
	srcdir=${3%/}
	env=${4}
	dest=${5%/}
	for t in crane jq tar sha256sum; do
		command -v "$t" >/dev/null 2>&1 || { echo "images: $t is required" >&2; exit 2; }
	done
	[ -f "$images" ] || { echo "images: $images not found" >&2; exit 2; }
	[ -d "$srcdir" ] || { echo "images: $srcdir is not a directory" >&2; exit 2; }
	[ -n "$env" ] || usage
	rows=$(image_rows "$images" "$dest" "$env") || exit 2
	work=$(mktemp -d)
	trap 'chmod -R u+rwX "$work" 2>/dev/null; rm -rf "$work"' EXIT
	loaded=0
	while IFS=$'\t' read -r app src to; do
		if [ -z "$app" ]; then
			continue
		fi
		# An app name becomes a path: refuse one that could leave <images-dir>.
		case "$app" in
		*/* | .*) echo "images: app name '$app' is not a file name" >&2; exit 1 ;;
		esac
		archive="$srcdir/$env/$app.tar"
		if [ ! -f "$archive" ]; then
			echo "images: skip $app (no archive $archive; copy moves an image from a public registry)" >&2
			continue
		fi
		case "$src" in
		*@sha256:*) want=${src##*@} ;;
		*) echo "images: $app records no digest in $images; its archive cannot be checked" >&2; exit 1 ;;
		esac
		if ! [[ "$want" =~ ^sha256:[0-9a-f]{64}$ ]]; then
			echo "images: $app records the digest '$want', which is not sha256:<64 hex>" >&2
			exit 1
		fi
		# The row's `digest` field and the digest in its `image` must agree.
		recorded=$(jq -r --arg a "$app" --arg e "$env" '[.apps[]? | select(.name == $a) | .environments[]? | select(.environment == $e) | (.digest // "")] | map(select(. != "")) | first // ""' "$images")
		if [ -n "$recorded" ] && [ "$recorded" != "$want" ]; then
			echo "images: $app records two digests for $env: $want in its image and $recorded in its digest field" >&2
			exit 1
		fi
		layout="$work/$app"
		mkdir -p "$layout"
		# An uncompressed tar carries "ustar" at byte 257; a compressed file does
		# not, and extracting it would expand without a bound.
		if [ "$(dd if="$archive" bs=1 skip=257 count=5 2>/dev/null)" != ustar ]; then
			echo "images: $archive is not an uncompressed tar archive" >&2
			exit 1
		fi
		# The archive is untrusted input: refuse an entry that is not a file or a
		# directory, and a name that is absolute or climbs out of the directory.
		if ! listing=$(tar -tvf "$archive" 2>/dev/null); then
			echo "images: $archive is not a tar archive" >&2
			exit 1
		fi
		if grep -qvE '^[-d]' <<<"$listing"; then
			echo "images: $archive holds an entry that is not a file or directory" >&2
			exit 1
		fi
		if tar -tf "$archive" | grep -qE '(^|/)\.\.(/|$)|^/'; then
			echo "images: $archive holds an entry outside its own directory" >&2
			exit 1
		fi
		tar -xf "$archive" -C "$layout" --no-same-owner --no-same-permissions
		[ -f "$layout/index.json" ] || { echo "images: $archive is not an OCI archive (no index.json)" >&2; exit 1; }
		count=$(jq -r 'if (.manifests | type) == "array" then (.manifests | length) else "none" end' "$layout/index.json") || { echo "images: $archive has no readable index.json" >&2; exit 1; }
		if [ "$count" != 1 ]; then
			echo "images: $archive lists $count images; expected 1" >&2
			exit 1
		fi
		listed=$(jq -r '.manifests[0].digest // ""' "$layout/index.json")
		if ! [[ "$listed" =~ ^sha256:[0-9a-f]{64}$ ]]; then
			echo "images: $archive lists the manifest digest '$listed', which is not sha256:<64 hex>" >&2
			exit 1
		fi
		# Every file under blobs/sha256/ must hash to its own name: the manifest
		# names the config and the layers, and a registry that does not check them
		# would take the manifest without them.
		if [ -d "$layout/blobs/sha256" ]; then
			while IFS= read -r -d '' f; do
				name=${f##*/}
				if [ "sha256:$(sha256sum <"$f" | cut -d' ' -f1)" != "sha256:$name" ]; then
					echo "images: REFUSED $app: the archive's file blobs/sha256/$name does not hash to its name" >&2
					exit 1
				fi
			done < <(find "$layout/blobs/sha256" -type f -print0)
		fi
		# Hash the manifest file itself: the name index.json gives it is a claim.
		blob="$layout/blobs/sha256/${listed#sha256:}"
		[ -f "$blob" ] && [ ! -L "$blob" ] || { echo "images: $archive has no manifest file for $listed" >&2; exit 1; }
		got=sha256:$(sha256sum <"$blob" | cut -d' ' -f1)
		if [ "$got" != "$want" ]; then
			echo "images: REFUSED $app: the archive's manifest is $got; $images records $want for $env" >&2
			exit 1
		fi
		echo "images: load $archive ($got) -> $to"
		crane push "$layout" "$to"
		back=$(crane digest "$to")
		if [ "$back" != "$want" ]; then
			echo "images: $to reads back as $back, not $want" >&2
			exit 1
		fi
		rm -rf "$layout"
		loaded=$((loaded + 1))
	done <<<"$rows"
	if [ "$loaded" -eq 0 ]; then
		echo "images: loaded no archive for environment $env (looked for $srcdir/$env/<app>.tar)" >&2
		exit 1
	fi
	echo "images: loaded $loaded image(s) to $dest"
	;;
rewrite)
	dir=${2%/}
	dest=${3%/}
	command -v yq >/dev/null 2>&1 || { echo "images: yq (mikefarah v4) is required" >&2; exit 2; }
	[ -d "$dir" ] || { echo "images: $dir is not a directory" >&2; exit 2; }
	files=()
	while IFS= read -r -d '' f; do
		files+=("$f")
	done < <(find "$dir" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)
	[ "${#files[@]}" -ne 0 ] || { echo "images: no YAML files under $dir" >&2; exit 2; }
	# Each distinct image reference, retargeted by image_path() — the function
	# `plan` and `copy` use — so the two cannot name different paths. yq only
	# replaces the old value with the new one, which leaves the file's other
	# documents and fields alone.
	refs=$(for f in "${files[@]}"; do
		yq -r '.. | select(tag == "!!map" and has("image") and (.image | tag == "!!str")) | .image' "$f"
	done | sort -u)
	count=0
	for f in "${files[@]}"; do
		while IFS= read -r ref; do
			if [ -z "$ref" ]; then
				continue
			fi
			grep -Fq -- "$ref" "$f" || continue
			# A reference with no host is left as it is (see the header).
			if ! path=$(image_path "$ref"); then
				continue
			fi
			OLD=$ref NEWREF="$dest/$path" yq -i \
				'(.. | select(tag == "!!map" and has("image") and .image == strenv(OLD))) |= (.image = strenv(NEWREF))' "$f"
		done <<<"$refs"
		count=$((count + 1))
	done
	echo "images: rewrote registry host to $dest in $count file(s)"
	;;
*)
	usage
	;;
esac
