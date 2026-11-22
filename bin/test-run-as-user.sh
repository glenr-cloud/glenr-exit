#!/usr/bin/env bash
# Proves examples/score-k8s-run-as-user.tpl with the pinned score-k8s: a document
# with glenr.io/run-as-user gets runAsUser, runAsGroup (only with a gid) and
# runAsNonRoot in its Deployment's pod securityContext; a document without the
# annotation gets none. Needs score-k8s and yq on PATH.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tpl="$here/examples/score-k8s-run-as-user.tpl"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

score() { # name annotations-block
  printf 'apiVersion: score.dev/v1b1\nmetadata:\n  name: %s\n%scontainers:\n  main:\n    image: busybox:1.37\n' "$1" "$2"
}
render() { # name annotations-block -> manifests on stdout, from a fresh score-k8s state
  local dir="$work/$1"
  mkdir -p "$dir"
  score "$1" "$2" >"$dir/score.yaml"
  (cd "$dir" && score-k8s init --no-sample --quiet --patch-templates "$tpl" >/dev/null \
    && score-k8s generate score.yaml --quiet -o manifests.yaml && cat manifests.yaml)
}
pod() { yq 'select(.kind == "Deployment") | .spec.template.spec.securityContext' -o=json -I=0 -; }

fail() { echo "FAIL: $*" >&2; exit 1; }

got=$(render uid $'  annotations:\n    glenr.io/run-as-user: "33"\n' | pod)
[[ "$got" == '{"runAsNonRoot":true,"runAsUser":33}' ]] || fail "uid only: $got"

got=$(render uidgid $'  annotations:\n    glenr.io/run-as-user: "33:44"\n' | pod)
[[ "$got" == '{"runAsGroup":44,"runAsNonRoot":true,"runAsUser":33}' ]] || fail "uid:gid: $got"

got=$(render gidzero $'  annotations:\n    glenr.io/run-as-user: "999:0"\n' | pod)
[[ "$got" == '{"runAsGroup":0,"runAsNonRoot":true,"runAsUser":999}' ]] || fail "gid 0: $got"

got=$(render plain "" | pod)
[[ "$got" == 'null' ]] || fail "no annotation: $got"

got=$(render other $'  annotations:\n    example.com/other: "1"\n' | pod)
[[ "$got" == 'null' ]] || fail "other annotation: $got"

echo "run-as-user patch template: ok"
