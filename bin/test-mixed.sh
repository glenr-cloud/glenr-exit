#!/usr/bin/env bash
# Proves an export that holds both archives and public images needs no hand step:
# README step 2's `load` line, then its `copy` line, put every image of the
# environment in the destination registry at the digest images.json records.
# One image is the hand-over archive fixtures/mixed/images/production/api.tar
# (its row names a zone registry that does not resolve); the other is pushed to a
# local registry that stands in for a public one. Two in-memory registries from
# `crane registry serve`. Needs crane, jq and tar on PATH.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
fx="$here/fixtures/mixed"
work=$(mktemp -d)
pids=()
trap 'for p in "${pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done; rm -rf "$work"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# serve <name>: start an empty registry on a free loopback port; sets $<name>
serve() {
	local port= i
	crane registry serve --address 127.0.0.1:0 >"$work/$1.log" 2>&1 &
	pids+=($!)
	for i in $(seq 1 50); do
		port=$(sed -n 's/.*serving on port \([0-9][0-9]*\).*/\1/p' "$work/$1.log")
		[ -n "$port" ] && break
		sleep 0.1
	done
	[ -n "$port" ] || fail "the $1 registry did not start: $(cat "$work/$1.log")"
	printf -v "$1" '%s' "127.0.0.1:$port"
}

images() { "$here/bin/images.sh" "$@"; }

# The archive is the one fixtures/load holds: a regenerated copy must be copied here too.
cmp -s "$fx/images/production/api.tar" "$here/fixtures/load/images/production/api.tar" || fail "fixtures/mixed/images/production/api.tar differs from fixtures/load/images/production/api.tar"

# The public image: one layer, pushed to the stand-in registry.
serve pub
mkdir -p "$work/layer"
echo "glenr-exit mixed fixture: public image" >"$work/layer/hello.txt"
tar -cf "$work/layer.tar" -C "$work/layer" hello.txt
crane append -f "$work/layer.tar" -t "$pub/library/cache:1" >/dev/null 2>&1
pubdigest=$(crane digest "$pub/library/cache:1")
apidigest=$(jq -r '.apps[] | select(.name == "api") | .environments[0].digest' "$fx/images.json")

# The export as the README lays it out: ./export/images.json, ./images/<env>/<app>.tar, bin/.
mkdir -p "$work/readme/export"
sed "s#PUBLIC_HOST#$pub#; s#PUBLIC_DIGEST#$pubdigest#g" "$fx/images.json" >"$work/readme/export/images.json"
cp -r "$fx/images" "$work/readme/images"
ln -s "$here/bin" "$work/readme/bin"
json=$work/readme/export/images.json
[ "$(jq -r '.apps[] | select(.name == "cache") | .environments[0].digest' "$json")" = "$pubdigest" ] || fail "fixture: the cache row does not record $pubdigest"

readme_line() { # <command>: the first README line starting with `bin/images.sh <command> `, comment removed
	local l
	l=$(grep -m1 "^bin/images.sh $1 " "$here/README.md" | sed 's/[[:space:]]*#.*$//' || true)
	[ -n "$l" ] || fail "README.md has no line starting with: bin/images.sh $1"
	printf '%s\n' "$l"
}
loadcmd=$(readme_line load)
copycmd=$(readme_line copy)
grep -qF -- './images production' <<<"$copycmd" || fail "the README's copy line does not pass the hand-over directory: $copycmd"

# run_readme <registry> <command...>: run README lines from the layout, in order
run_readme() {
	local reg=$1 c
	shift
	for c in "$@"; do
		c=${c//<your-registry>/$reg}
		(cd "$work/readme" && eval "$c") >"$work/out" 2>"$work/err" || return 1
	done
}

echo "== README step 2: load, then copy, and every image is at the digest images.json records =="
serve dest
run_readme "$dest" "$loadcmd" "$copycmd" || { cat "$work/err" >&2; fail "the README's load and copy lines exited non-zero"; }
grep -q 'skip api (archive' "$work/err" || fail "copy did not skip the archive row: $(cat "$work/err")"
[ "$(crane digest "$dest/exitsrc/api")" = "$apidigest" ] || fail "crane digest of the archive image is $(crane digest "$dest/exitsrc/api"), not $apidigest"
[ "$(crane digest "$dest/library/cache")" = "$pubdigest" ] || fail "crane digest of the public image is $(crane digest "$dest/library/cache"), not $pubdigest"
[ "$(crane digest "$dest/library/cache@$pubdigest")" = "$pubdigest" ] || fail "the public image is not at $pubdigest by digest"
[ "$(crane catalog "$dest" | sort | tr '\n' ' ')" = "exitsrc/api library/cache " ] || fail "the destination holds: $(crane catalog "$dest" | tr '\n' ' ')"
[ "$(crane export "$dest/library/cache@$pubdigest" - | tar -xOf - hello.txt)" = "glenr-exit mixed fixture: public image" ] || fail "the copied public image does not hold its layer"
echo "ok: api $apidigest, cache $pubdigest"

echo "== copy, then load, also fills the destination (the order does not matter) =="
serve dest
run_readme "$dest" "$copycmd" "$loadcmd" || { cat "$work/err" >&2; fail "copy then load exited non-zero"; }
[ "$(crane digest "$dest/exitsrc/api")" = "$apidigest" ] && [ "$(crane digest "$dest/library/cache")" = "$pubdigest" ] || fail "copy then load left a wrong digest"

echo "== mutant: copy without the hand-over directory stops at the archive row =="
serve dest
if (cd "$work/readme" && images copy export/images.json "$dest") >"$work/out" 2>"$work/err"; then fail "copy without the hand-over directory exited 0"; fi
grep -q "images: copy registry.glenr.example/exitsrc/api" "$work/out" || fail "copy did not stop at the api row: $(cat "$work/out") $(cat "$work/err")"
[ -z "$(crane catalog "$dest")" ] || fail "copy without the directory pushed: $(crane catalog "$dest" | tr '\n' ' ')"
echo "refused: copy without the directory"

echo "== mutant: copy with a directory that holds no archive stops at the archive row =="
mkdir -p "$work/emptydir/production"
if (cd "$work/readme" && images copy export/images.json "$dest" "$work/emptydir" production) >"$work/out" 2>"$work/err"; then fail "copy with an empty hand-over directory exited 0"; fi
grep -q "images: copy registry.glenr.example/exitsrc/api" "$work/out" || fail "copy did not stop at the api row: $(cat "$work/out")"
echo "refused: copy with an empty directory"

echo "== copy skips every row when each has an archive =="
jq '.apps |= map(select(.name == "api"))' "$json" >"$work/api-only.json"
serve dest
images copy "$work/api-only.json" "$dest" "$work/readme/images" production >"$work/out" 2>"$work/err" || fail "copy of an archive-only export exited non-zero: $(cat "$work/err")"
grep -qF 'nothing to copy (every row has no image, no registry host or an archive)' "$work/out" || fail "unexpected output: $(cat "$work/out")"
[ -z "$(crane catalog "$dest")" ] || fail "copy pushed an archive row"

echo "== copy handles only the rows of its environment =="
# The staging row names an unresolvable zone host with no archive: copying it would fail.
serve dest
run_readme "$dest" "$copycmd" || { cat "$work/err" >&2; fail "copy of production touched the staging row"; }
[ "$(crane catalog "$dest" | sort | tr '\n' ' ')" = "library/cache " ] || fail "copy of production left: $(crane catalog "$dest" | tr '\n' ' ')"
rc=0
(cd "$work/readme" && images copy export/images.json "$dest" "$work/readme/images" nosuchenv) >"$work/out" 2>"$work/err" || rc=$?
[ "$rc" = 1 ] || fail "copy of an environment with no rows exited $rc, not 1"
grep -q 'lists no images to copy' "$work/err" || fail "unexpected message: $(cat "$work/err")"
echo "ok: staging untouched, an unknown environment is refused"

echo "== copy refuses an app name that is not a file name (the guard of load) =="
jq '.apps |= map(if .name == "cache" then .name = ".x" else . end)' "$json" >"$work/dotname.json"
serve dest
rc=0
images copy "$work/dotname.json" "$dest" "$work/readme/images" production >"$work/out" 2>"$work/err" || rc=$?
[ "$rc" = 1 ] || fail "copy with the app name .x exited $rc, not 1"
grep -q "app name '.x' is not a file name" "$work/err" || fail "unexpected message: $(cat "$work/err")"
[ -z "$(crane catalog "$dest")" ] || fail "copy pushed before the guard: $(crane catalog "$dest" | tr '\n' ' ')"

echo "== copy takes 3 or 5 arguments, and a directory =="
rc=0
images copy "$json" "$dest" "$work/readme/images" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "copy with 4 arguments exited $rc, not 2"
rc=0
images copy "$json" "$dest" "$work/no-such-dir" production >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "copy with a missing directory exited $rc, not 2"

rc=0
images copy "$json" "$dest" "$work/readme/images" "" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "copy with an empty environment exited $rc, not 2"

echo "== the 3-argument form keeps its message when no row needs a copy =="
printf '{"apps":[{"name":"db","environments":[{"environment":"production","image":"postgres:16"}]}]}' >"$work/nohost.json"
images copy "$work/nohost.json" "$dest" >"$work/out" 2>/dev/null || fail "copy of a no-host export exited non-zero"
grep -qF 'nothing to copy (every row has no image or no registry host)' "$work/out" || fail "3-argument message changed: $(cat "$work/out")"

echo "OK: images.sh copy with a hand-over directory"
