#!/usr/bin/env sh
set -eu

find apps -type f \( -name '*.yaml' -o -name '*.yml' \) -print | sort | while IFS= read -r file; do
  if grep -q '^kind: SopsSecret$' "$file"; then
    sops -e -i "$file"
  fi
done
