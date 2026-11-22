#!/usr/bin/env bash
# Proves images.sh load with crane's in-memory registry: the fixture archive
# (fixtures/load/images/production/api.tar, a kind 5 hand-over file) is pushed
# with its digest unchanged, and each changed copy of it is refused with nothing
# pushed. The first case runs the `load` line of README step 2 as written.
# Needs crane, jq and tar on PATH.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
fx="$here/fixtures/load"
work=$(mktemp -d)
regpid=
trap 'if [ -n "$regpid" ]; then kill "$regpid" 2>/dev/null || true; fi; rm -rf "$work"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

reg=
newreg() { # start an empty registry on a free loopback port; sets $reg
	if [ -n "$regpid" ]; then kill "$regpid" 2>/dev/null || true; fi
	crane registry serve --address 127.0.0.1:0 >"$work/serve.log" 2>&1 &
	regpid=$!
	local port=
	for _ in $(seq 1 50); do
		port=$(sed -n 's/.*serving on port \([0-9][0-9]*\).*/\1/p' "$work/serve.log")
		[ -n "$port" ] && break
		sleep 0.1
	done
	[ -n "$port" ] || fail "the test registry did not start: $(cat "$work/serve.log")"
	reg=127.0.0.1:$port
}

want=$(jq -r '.apps[] | select(.name == "api") | .environments[] | select(.environment == "production") | .digest' "$fx/images.json")
# The digest of the archive's manifest, computed here from the archive, not read from images.json.
idx=$(tar -xOf "$fx/images/production/api.tar" ./index.json | jq -r '.manifests[0].digest')
[ "$idx" = "$want" ] || fail "fixture: the archive lists $idx but images.json records $want"
[ "sha256:$(tar -xOf "$fx/images/production/api.tar" "./blobs/sha256/${want#sha256:}" | sha256sum | cut -d' ' -f1)" = "$want" ] \
	|| fail "fixture: the archive's manifest file does not hash to $want"

images() { "$here/bin/images.sh" "$@"; }

echo "== README step 2: its load command pushes the archive and the digest does not change =="
newreg
# The README's line, with its comment removed, run from a directory laid out as
# the README says: ./export/images.json, ./images/<env>/<app>.tar, bin/.
cmd=$(grep -m1 '^bin/images.sh load ' "$here/README.md" | sed 's/[[:space:]]*#.*$//' || true)
[ -n "$cmd" ] || fail "README.md has no line starting with: bin/images.sh load"
mkdir -p "$work/readme/export"
cp "$fx/images.json" "$work/readme/export/images.json"
cp -r "$fx/images" "$work/readme/images"
ln -s "$here/bin" "$work/readme/bin"
cmd=${cmd//<your-registry>/$reg}
out=$(cd "$work/readme" && eval "$cmd" 2>"$work/err") || { cat "$work/err" >&2; fail "the README's load command exited non-zero: $cmd"; }
got=$(crane digest "$reg/exitsrc/api")
[ "$got" = "$want" ] || fail "crane digest at the destination is $got, not $want"
got=$(crane digest "$reg/exitsrc/api@$want")
[ "$got" = "$want" ] || fail "crane digest by digest at the destination is $got, not $want"
[ "$(crane catalog "$reg")" = "exitsrc/api" ] || fail "the registry holds more than exitsrc/api: $(crane catalog "$reg" | tr '\n' ' ')"
grep -q 'skip cache' "$work/err" || fail "the public-registry row (cache) was not skipped with a line: $(cat "$work/err")"
grep -q 'loaded 1 image' <<<"$out" || fail "load did not report 1 image: $out"
# The pushed image holds the fixture's layer.
[ "$(crane export "$reg/exitsrc/api@$want" - | tar -xOf - hello.txt)" = "glenr-exit load fixture" ] || fail "the pushed image does not hold the fixture layer"

echo "== load of an environment with no archive fails and pushes nothing =="
newreg
if images load "$fx/images.json" "$fx/images" staging "$reg" 2>"$work/err"; then fail "load exited 0 with no archive for staging"; fi
grep -q 'loaded no archive' "$work/err" || fail "unexpected message: $(cat "$work/err")"
[ -z "$(crane catalog "$reg")" ] || fail "something was pushed"

expect_refused() { # name pattern dir env: load fails with a message matching pattern and the registry stays empty
	local name=$1 pattern=$2 json=$3 dir=$4
	newreg
	if images load "$json" "$dir" production "$reg" 2>"$work/err"; then fail "mutant '$name': load exited 0"; fi
	grep -qE -- "$pattern" "$work/err" || fail "mutant '$name': load refused for another reason: $(cat "$work/err")"
	[ -z "$(crane catalog "$reg")" ] || fail "mutant '$name': an image was pushed ($(crane catalog "$reg" | tr '\n' ' '))"
	echo "refused: $name"
}

echo "== load refuses a changed archive or record, and pushes nothing =="
# images.json records another digest than the archive's manifest.
sed "s/d362494094a2ac2c/e362494094a2ac2c/g" "$fx/images.json" >"$work/other-digest.json"
expect_refused "images.json digest differs" "REFUSED api" "$work/other-digest.json" "$fx/images"

# The archive's manifest file has one byte more; index.json still names it.
mkdir -p "$work/m1/layout" "$work/m1/images/production"
tar -xf "$fx/images/production/api.tar" -C "$work/m1/layout"
printf ' ' >>"$work/m1/layout/blobs/sha256/${want#sha256:}"
tar -cf "$work/m1/images/production/api.tar" -C "$work/m1/layout" .
expect_refused "manifest file changed" "REFUSED api" "$fx/images.json" "$work/m1/images"

# index.json lists the image twice.
mkdir -p "$work/m2/layout" "$work/m2/images/production"
tar -xf "$fx/images/production/api.tar" -C "$work/m2/layout"
jq '.manifests += .manifests' "$work/m2/layout/index.json" >"$work/m2/index.json" && mv "$work/m2/index.json" "$work/m2/layout/index.json"
tar -cf "$work/m2/images/production/api.tar" -C "$work/m2/layout" .
expect_refused "two images in one archive" "lists 2 images" "$fx/images.json" "$work/m2/images"

# The archive holds a symlink.
mkdir -p "$work/m3/layout" "$work/m3/images/production"
tar -xf "$fx/images/production/api.tar" -C "$work/m3/layout"
ln -s /etc/passwd "$work/m3/layout/evil"
tar -cf "$work/m3/images/production/api.tar" -C "$work/m3/layout" .
expect_refused "archive holds a symlink" "not a file or directory" "$fx/images.json" "$work/m3/images"

# The file is not a tar archive.
mkdir -p "$work/m4/images/production"
printf 'not a tar archive\n' >"$work/m4/images/production/api.tar"
expect_refused "not a tar archive" "not an uncompressed tar" "$fx/images.json" "$work/m4/images"

# The archive's config blob (named by the manifest) has one byte more.
cfg=$(tar -xOf "$fx/images/production/api.tar" "./blobs/sha256/${want#sha256:}" | jq -r '.config.digest')
mkdir -p "$work/m5/layout" "$work/m5/images/production"
tar -xf "$fx/images/production/api.tar" -C "$work/m5/layout"
printf ' ' >>"$work/m5/layout/blobs/sha256/${cfg#sha256:}"
tar -cf "$work/m5/images/production/api.tar" -C "$work/m5/layout" .
expect_refused "config blob changed" "REFUSED api" "$fx/images.json" "$work/m5/images"

# The archive holds a hard link.
mkdir -p "$work/m6/layout" "$work/m6/images/production"
tar -xf "$fx/images/production/api.tar" -C "$work/m6/layout"
printf 'x\n' >"$work/m6/layout/a" && ln "$work/m6/layout/a" "$work/m6/layout/b"
tar -cf "$work/m6/images/production/api.tar" -C "$work/m6/layout" .
expect_refused "archive holds a hard link" "not a file or directory" "$fx/images.json" "$work/m6/images"

# The archive holds a name that climbs out of its directory.
mkdir -p "$work/m7/layout" "$work/m7/images/production"
tar -xf "$fx/images/production/api.tar" -C "$work/m7/layout"
printf 'x\n' >"$work/m7/layout/up"
tar -cf "$work/m7/images/production/api.tar" -C "$work/m7/layout" --transform 's,^\./up$,../up,' .
tar -tf "$work/m7/images/production/api.tar" | grep -qx '\.\./up' || fail "the test archive m7 holds no ../ name"
expect_refused "archive holds a ../ name" "outside its own directory" "$fx/images.json" "$work/m7/images"

# The archive is compressed (gzip), which tar would extract without a bound.
mkdir -p "$work/m8/images/production"
gzip -c "$fx/images/production/api.tar" >"$work/m8/images/production/api.tar"
expect_refused "compressed archive" "not an uncompressed tar" "$fx/images.json" "$work/m8/images"

# images.json records two digests for the row.
jq '(.apps[] | select(.name == "api") | .environments[] | select(.environment == "production") | .digest) = "sha256:3333333333333333333333333333333333333333333333333333333333333333"' "$fx/images.json" >"$work/two-digests.json"
expect_refused "images.json digest and image disagree" "two digests" "$work/two-digests.json" "$fx/images"

echo "== load refuses the wrong number of arguments =="
rc=0
images load "$fx/images.json" "$fx/images" production >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] || fail "load with 3 arguments exited $rc, not 2"

echo "OK: images.sh load"
