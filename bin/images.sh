#!/usr/bin/env bash
# images.sh — move a cell export's images to a registry the customer controls.
# Usage:
#   bin/images.sh plan    <images.json> <dest-registry>   # print src<TAB>dest per row
#   bin/images.sh copy    <images.json> <dest-registry>   # copy each image out
#   bin/images.sh rewrite <manifests-dir> <dest-registry> # point the manifests at it
#
# `plan` reads images.json (per app, per environment: the image and its
# `sha256:` digest) and prints, one row per image, the reference `copy` reads
# and the repository it writes, without calling `crane`. CI uses it to prove
# `copy` and `rewrite` name the same path.
#
# `copy` copies each image by digest to <dest-registry>/<path> with `crane`, so
# the digest is preserved. A digest that names an index is copied whole: every
# platform it lists. Run it before retrieval of the cell export ends: the images
# live in the zone registry, and that registry goes with the account
# (design/145 §4.4 step 5, §2.1 kind 5). A row with no image (the cell's
# database) carries nothing to copy and is skipped.
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
# plan requires `jq`; rewrite requires `yq` (mikefarah, v4).
set -euo pipefail

usage() {
	sed -n '3,6p' "$0" | sed 's/^# \{0,1\}//' >&2
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

# image_rows <images.json> <dest-registry> — one line per row `copy` moves:
# <app> TAB <src> TAB <dest>. <src> is the image, pinned by digest when the row
# or the digest names one; <dest> is <dest-registry>/<image_path>, with the
# digest dropped because `crane copy` writes a tag or repository (the copied
# content keeps the digest the manifests pull). Rows with no image and rows
# naming no host are skipped, with a line on stderr.
image_rows() {
	local images=$1 dest=${2%/} app image digest src path rows
	# Read every row before the loop: a row table that does not parse must stop
	# the caller, not read as an empty images.json.
	if ! rows=$(jq -r '.apps[]? | .name as $n | .environments[]? | [$n, (.image // ""), (.digest // "")] | @tsv' "$images"); then
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

[ "$#" -eq 3 ] || usage
cmd=$1

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
