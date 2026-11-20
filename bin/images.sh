#!/usr/bin/env bash
# images.sh — move a cell export's images to a registry the customer controls.
#
# Usage:
#   bin/images.sh copy    <images.json> <dest-registry>   # copy each digest out
#   bin/images.sh rewrite <manifests-dir> <dest-registry> # point the manifests at it
#
# `copy` reads images.json (per app, per environment: the image and its
# `sha256:` digest) and copies each image by digest to <dest-registry>/<app>
# with `crane`, so the digest is preserved. Run it before retrieval of the cell
# export ends: the images live in the zone registry, and that registry goes
# with the account (design/145 §4.4 step 5, §2.1 kind 5).
#
# `rewrite` changes the registry host of every `image:` value under the
# manifests directory to <dest-registry>, keeping the path and the digest, so
# the applied objects pull from the registry `copy` filled. Run it after copy
# and before apply.
#
# copy requires `crane` (github.com/google/go-containerregistry); rewrite
# requires `yq` (mikefarah, v4).
set -euo pipefail

usage() {
	sed -n '3,6p' "$0" | sed 's/^# \{0,1\}//' >&2
	exit 2
}

[ "$#" -eq 3 ] || usage
cmd=$1

case "$cmd" in
copy)
	images=${2}
	dest=${3%/}
	command -v crane >/dev/null 2>&1 || { echo "images: crane is required" >&2; exit 2; }
	command -v jq >/dev/null 2>&1 || { echo "images: jq is required" >&2; exit 2; }
	[ -f "$images" ] || { echo "images: $images not found" >&2; exit 2; }
	# Per app and environment: the image reference and its digest.
	copied=0
	while IFS=$'\t' read -r app image digest; do
		[ -z "$app" ] && continue
		src=$image
		# Prefer the digest: copying by digest preserves it at the destination.
		case "$image" in
		*@sha256:*) : ;;
		*) [ -n "$digest" ] && src="$image@$digest" ;;
		esac
		echo "images: copy $src -> $dest/$app"
		crane copy "$src" "$dest/$app"
		copied=$((copied + 1))
	done < <(jq -r '.apps[]? | .name as $n | .environments[]? | [$n, .image, (.digest // "")] | @tsv' "$images")
	if [ "$copied" -eq 0 ]; then
		echo "images: images.json lists no images to copy" >&2
		exit 1
	fi
	echo "images: copied $copied image(s) to $dest"
	;;
rewrite)
	dir=${2%/}
	dest=${3%/}
	command -v yq >/dev/null 2>&1 || { echo "images: yq (mikefarah v4) is required" >&2; exit 2; }
	[ -d "$dir" ] || { echo "images: $dir is not a directory" >&2; exit 2; }
	export NEW=$dest
	# Rewrite the registry host (the segment before the first '/') of every
	# map that has a string `image`, keeping the rest of the reference and the
	# digest. A reference with no '/' (a bare image name) is left alone. Read
	# paths with a null delimiter so a space in a path is not split.
	count=0
	while IFS= read -r -d '' f; do
		yq -i '(.. | select(tag == "!!map" and has("image"))) |= (.image |= (if test("/") then sub("^[^/]+"; strenv(NEW)) else . end))' "$f"
		count=$((count + 1))
	done < <(find "$dir" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)
	[ "$count" -ne 0 ] || { echo "images: no YAML files under $dir" >&2; exit 2; }
	echo "images: rewrote registry host to $dest in $count file(s)"
	;;
*)
	usage
	;;
esac
