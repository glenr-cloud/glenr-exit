#!/usr/bin/env bash
# check.sh — refuse a manifest set that a plain cluster must not receive.
#
# Usage: bin/check.sh <manifests-dir>
#
# It reads every YAML (and JSON) document in the directory tree — top level and
# inside any `kind: List` items — and refuses (exit 1) when it finds any of the
# following, each of which means the file was not produced by the exit profile
# (design/145 §3.1, §5.1):
#
#   - an apiVersion outside the exit allowlist: core (v1), apps, batch,
#     autoscaling, policy, networking.k8s.io. Anything else needs a CRD the
#     export is not allowed to assume;
#   - the string `glenr.io` anywhere. The exit profile writes no Glenr key,
#     label, annotation, node selector or toleration;
#   - a Secret whose `data` or `stringData` is non-empty. An export never
#     carries a secret value; the customer fills secrets/<env>.example.yaml.
#
# A file that does not parse as YAML/JSON is refused, never treated as "no
# apiVersion found". Requires yq (mikefarah, v4).
set -euo pipefail

if [ "$#" -ne 1 ]; then
	echo "usage: $0 <manifests-dir>" >&2
	exit 2
fi
dir=${1%/}
[ -d "$dir" ] || { echo "check: $dir is not a directory" >&2; exit 2; }
command -v yq >/dev/null 2>&1 || { echo "check: yq (mikefarah v4) is required" >&2; exit 2; }

# allowed reports whether an apiVersion is in the exit allowlist.
allowed() {
	case "$1" in
		v1 | apps/v1 | batch/v1 | autoscaling/v1 | autoscaling/v2 | policy/v1 | networking.k8s.io/v1)
			return 0 ;;
		*) return 1 ;;
	esac
}

fail=0
# find every manifest file bellow the directory, including hidden ones and JSON,
# sorted for stable output
while IFS= read -r f; do
	# every apiVersion in the file, including items inside a `kind: List`
	if ! avs=$(yq -N -r '(.. | select(tag == "!!map" and has("apiVersion")) | .apiVersion) // ""' "$f" 2>/dev/null); then
		echo "check: $f: does not parse as YAML/JSON" >&2
		fail=1
		continue
	fi
	while IFS= read -r av; do
		[ -z "$av" ] && continue
		if ! allowed "$av"; then
			echo "check: $f: apiVersion '$av' is outside the allowlist" >&2
			fail=1
		fi
	done <<<"$avs"

	# no glenr.io key, selector or toleration anywhere
	if grep -q 'glenr.io' "$f"; then
		echo "check: $f: contains 'glenr.io'" >&2
		fail=1
	fi

	# no Secret (top level or inside a List) with a value
	if ! names=$(yq -N -r '(.. | select(tag == "!!map") | select(.kind == "Secret") | select((((.data // {}) | length) > 0) or (((.stringData // {}) | length) > 0)) | (.metadata.name // "?")) // ""' "$f" 2>/dev/null); then
		echo "check: $f: does not parse as YAML/JSON" >&2
		fail=1
		continue
	fi
	while IFS= read -r name; do
		[ -z "$name" ] && continue
		echo "check: $f: Secret '$name' has non-empty data or stringData" >&2
		fail=1
	done <<<"$names"
done < <(find "$dir" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) | sort)

if [ "$fail" -ne 0 ]; then
	echo "check: refused" >&2
	exit 1
fi
echo "check: ok"
