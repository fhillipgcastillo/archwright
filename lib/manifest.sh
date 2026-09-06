#!/usr/bin/env bash
# Readers for manifest/. The installer must never hardcode a package list:
# both the installer and the guide read their facts from these files, and the
# drift check compares them. See D9 in docs/decisions.md.

aw_manifest_packages() {
  local file="$1"
  [ -f "$file" ] || aw_die "manifest not found: $file"
  sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$file" | grep -v '^[[:space:]]*$' || true
}

aw_manifest_subvolumes() {
  local file="$1"
  [ -f "$file" ] || aw_die "manifest not found: $file"
  grep -v '^[[:space:]]*#' "$file" | grep -v '^[[:space:]]*$' || true
}
