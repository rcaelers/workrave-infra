#!/usr/bin/env sh
set -u

failed_files="$(mktemp "${TMPDIR:-/tmp}/decrypt-failed.XXXXXX")"
error_log=""
trap 'rm -f "$failed_files" "$error_log"' EXIT

find apps -type f \( -name '*.yaml' -o -name '*.yml' \) -print | sort | while IFS= read -r file; do
  if ! grep -q '^kind: SopsSecret$' "$file"; then
    continue
  fi

  if grep -q 'ENC\[AES256_GCM' "$file"; then
    echo "Decrypting file: $file"
    error_log="$(mktemp "${TMPDIR:-/tmp}/decrypt-error.XXXXXX")"
    if ! sops -d -i "$file" 2> "$error_log"; then
      if grep -q 'MAC mismatch' "$error_log"; then
        echo "MAC mismatch while decrypting file: $file" >&2
        sed 's/^/  /' "$error_log" >&2
        echo "Retrying without MAC verification: $file" >&2
        if ! SOPS_CONFIG=/dev/null sops --config /dev/null --ignore-mac -d -i "$file"; then
          echo "Failed to decrypt file after MAC fallback: $file" >&2
          printf '%s\n' "$file" >> "$failed_files"
        fi
      else
        sed 's/^/  /' "$error_log" >&2
        echo "Failed to decrypt file: $file" >&2
        printf '%s\n' "$file" >> "$failed_files"
      fi
    fi
    rm -f "$error_log"
  else
    echo "Skipping already decrypted file: $file"
  fi
done

if [ -s "$failed_files" ]; then
  echo "Decryption completed with failures:" >&2
  sed 's/^/  /' "$failed_files" >&2
  exit 1
fi
