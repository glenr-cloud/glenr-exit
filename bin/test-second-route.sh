#!/usr/bin/env bash
# Proves the second route (README, "The second route") for an app Glenr built
# from source. The fixture fixtures/second-route/ names the zone registry in
# images.json, score-k8s/web.yaml and overrides/production/web.score.yaml, as an
# export of such an app does. The case runs the README's code block as written
# (with <your-registry> and <namespace> filled in) and then asserts that every
# `image:` in the score-k8s output names the destination registry, with the
# digest images.json records and the path `images.sh plan` prints.
# The mutant runs the same block without its `rewrite ./export/overrides` line;
# the override's zone host then wins, and the assertion must fail.
# Needs score-k8s, yq and jq on PATH.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
fx="$here/fixtures/second-route"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
dest=registry.customer.example:5000
ns=acme
zone=lz7.apps.glenr.io

fail() { echo "FAIL: $*" >&2; exit 1; }

# The README's code block of the second route that holds the rewrite and the
# generate command, first line to last.
block=$(awk '
	/^## The second route/ { sec = 1; next }
	sec && /^## / { sec = 0 }
	sec && /^```sh$/ { inb = 1; buf = ""; next }
	sec && inb && /^```$/ { inb = 0; if (buf ~ /images\.sh rewrite \.\/export\/score-k8s/ && buf ~ /score-k8s generate/) { printf "%s", buf; exit } next }
	sec && inb { buf = buf $0 "\n" }
' "$here/README.md")
[ -n "$block" ] || fail "README.md: no code block in 'The second route' with both 'images.sh rewrite ./export/score-k8s' and 'score-k8s generate'"

want=$(jq -r '.apps[] | select(.name == "web") | .environments[] | select(.environment == "production") | .digest' "$fx/images.json")
[[ "$want" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "fixture: images.json holds no sha256 digest for web: $want"

# The fixture is a source-built export: all three inputs name the zone registry
# with the digest. Without this the case would pass for any export.
for f in images.json score-k8s/web.yaml overrides/production/web.score.yaml; do
	grep -qF "$zone/" "$fx/$f" || fail "fixture: $f does not name $zone"
	grep -qF "$want" "$fx/$f" || fail "fixture: $f does not carry $want"
done

# The destination `images.sh plan` prints for the fixture's one image row.
plan=$("$here/bin/images.sh" plan "$fx/images.json" "$dest" | cut -f2)
[ "$(printf '%s\n' "$plan" | grep -c .)" = 1 ] || fail "fixture: plan printed other than one destination: $plan"

# route <name> <block> — lay the fixture out as the README says (./export,
# bin/, examples/), run <block> there and leave the score-k8s output in
# $work/<name>/export/manifests.yaml.
route() {
	local name=$1 blk=$2 root="$work/$1"
	mkdir -p "$root"
	cp -r "$fx" "$root/export"
	cp "$here/glenr.provisioners.yaml" "$root/export/glenr.provisioners.yaml"
	ln -s "$here/bin" "$root/bin"
	ln -s "$here/examples" "$root/examples"
	blk=${blk//<your-registry>/$dest}
	blk=${blk//<namespace>/$ns}
	(cd "$root" && bash -euo pipefail -c "$blk") >"$root/out" 2>&1 || { cat "$root/out" >&2; fail "$name: the README block exited non-zero"; }
}

# check_images <name> — every image in the output is <dest>/<plan path>@<digest>.
# Prints the reason and returns 1 when one is not.
check_images() {
	local name=$1 out="$work/$1/export/manifests.yaml" ref n=0
	[ -s "$out" ] || { echo "$name: score-k8s wrote no manifests.yaml" >&2; return 1; }
	[ -n "$plan" ] || { echo "$name: images.sh plan printed no destination" >&2; return 1; }
	while IFS= read -r ref; do
		[ -n "$ref" ] || continue
		n=$((n + 1))
		if [ "$ref" != "$plan@$want" ]; then
			echo "$name: image '$ref' is not '$plan@$want'" >&2
			return 1
		fi
	done < <(yq -r '.. | select(tag == "!!map" and has("image") and (.image | tag == "!!str")) | .image' "$out")
	[ "$n" -ge 1 ] || { echo "$name: the output has no image: line" >&2; return 1; }
	echo "  $n image(s), all $plan@${want:0:19}…"
}

echo "== README second route: every image in the score-k8s output names $dest with the fixture digest =="
grep -qF 'images.sh rewrite ./export/overrides' <<<"$block" || fail "README block has no 'images.sh rewrite ./export/overrides' line"
route route "$block"
[ "$(yq '.containers.main.image' "$work/route/export/overrides/production/web.score.yaml")" = "$plan@$want" ] \
	|| fail "rewrite did not set containers.main.image of the override to $plan@$want"
check_images route || fail "the README's second route leaves a zone image in the output"

echo "== mutant: the README block without the overrides rewrite must fail the assertion =="
mut=$(grep -vF 'images.sh rewrite ./export/overrides' <<<"$block")
[ "$mut" != "$block" ] || fail "mutant: removed no line"
route mutant "$mut"
if check_images mutant 2>"$work/mutant.err"; then
	fail "mutant survived: with the overrides rewrite skipped, every image names $dest"
fi
grep -qF "$zone/" "$work/mutant.err" || { cat "$work/mutant.err" >&2; fail "mutant failed for another reason than the zone image"; }
sed 's/^/  /' "$work/mutant.err"
echo "  killed"

echo "second route (source-built app): ok"
