#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

tmp="$(mktemp /tmp/hash-fieldmap-bench.XXXXXX.luau)"
trap 'rm -f "$tmp"' EXIT

sed '$s/return Hash//' src/ReplicatedStorage/Vikingr/Hash.luau > "$tmp"
cat docs/hash-fieldmap-bench.luau >> "$tmp"

luau "$tmp"
