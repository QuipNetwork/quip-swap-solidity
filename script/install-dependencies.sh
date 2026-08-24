#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root_manifest="$repo_root/soldeer.toml"
root_lock="$repo_root/soldeer.lock"

if [[ -d "$repo_root/dependencies" ]]; then
  echo "Solidity dependencies are already installed."
  exit 0
fi

if [[ -e "$root_manifest" || -e "$root_lock" ]]; then
  echo "Refusing to overwrite root Soldeer metadata." >&2
  exit 1
fi

cleanup() {
  if [[ -f "$root_lock" ]]; then
    mv "$root_lock" "$repo_root/config/soldeer.lock"
  fi
  rm -f "$root_manifest"
}
trap cleanup EXIT

cp "$repo_root/config/soldeer.toml" "$root_manifest"
cp "$repo_root/config/soldeer.lock" "$root_lock"

cd "$repo_root"
forge soldeer install --config-location soldeer
