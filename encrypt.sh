#!/usr/bin/env sh
set -u

failed_files="$(mktemp "${TMPDIR:-/tmp}/encrypt-failed.XXXXXX")"
trap 'rm -f "$failed_files"' EXIT

find apps -type f \( -name '*.yaml' -o -name '*.yml' \) ! -name '*-template.*' -print | sort | while IFS= read -r file; do
  if ! grep -q '^kind: SopsSecret$' "$file"; then
    continue
  fi

  if grep -q 'ENC\[AES256_GCM' "$file"; then
    echo "Skipping already encrypted file: $file"
  else
    echo "Encrypting file: $file"
    if ! sops -e -i "$file"; then
      echo "Failed to encrypt file: $file" >&2
      printf '%s\n' "$file" >> "$failed_files"
    fi
  fi
done

if [ -s "$failed_files" ]; then
  echo "Encryption completed with failures:" >&2
  sed 's/^/  /' "$failed_files" >&2
  exit 1
fi
