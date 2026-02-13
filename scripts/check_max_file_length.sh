#!/usr/bin/env bash
set -euo pipefail

MAX_FILE_LINES="${MAX_FILE_LINES:-900}"

if ! [[ "$MAX_FILE_LINES" =~ ^[0-9]+$ ]] || [[ "$MAX_FILE_LINES" -le 0 ]]; then
  echo "MAX_FILE_LINES must be a positive integer (got: $MAX_FILE_LINES)"
  exit 2
fi

FILES=()
while IFS= read -r file; do
  FILES+=("$file")
done < <(
  rg --files addons/local_agents scripts .github/workflows \
    -g '*.gd' -g '*.gdshader' -g '*.tscn' -g '*.tres' -g '*.yml' -g '*.yaml' \
  | rg -v '/gdextensions/localagents/(thirdparty|build)/'
)

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "No matching files found for max-file-length check."
  exit 0
fi

violations=0
for file in "${FILES[@]}"; do
  if [[ ! -f "$file" ]]; then
    continue
  fi
  lines=$(wc -l < "$file" | tr -d '[:space:]')
  if [[ "$lines" -gt "$MAX_FILE_LINES" ]]; then
    echo "FILE TOO LONG: $file ($lines lines > $MAX_FILE_LINES max)"
    violations=$((violations + 1))
  fi
done

if [[ "$violations" -gt 0 ]]; then
  echo
  echo "Max file length check failed with $violations violation(s)."
  echo "No exceptions are supported. Split large files into focused modules."
  exit 1
fi

echo "Max file length check passed (limit: $MAX_FILE_LINES lines)."
