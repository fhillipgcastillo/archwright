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

# Agent identities for the AI layer: three tab-separated fields, being the
# command name, the mise spec that provides it, and the executable inside that
# package. Which agents exist is data, exactly like which packages exist (D9),
# so lib/70-ai.sh never names one.
#
# Comments and blank lines are dropped; everything else is emitted verbatim so
# the tabs survive into cut and read.
aw_manifest_agents() {
  local file="$1"
  [ -f "$file" ] || aw_die "manifest not found: $file"
  grep -v '^[[:space:]]*#' "$file" | grep -v '^[[:space:]]*$' || true
}

# Group-aware readers for manifest/extras.packages.
#
# The file is grouped by job:
#
#   ## Group: gaming
#   ## Requires: multilib
#   steam
#
# A '## Requires:' directive states that the group needs something beyond the
# default repositories. It lives in the manifest rather than in lib/ so package
# facts stay with the package data - the same rule that keeps package names out
# of lib/.

aw_manifest_groups() {
  local file="$1"
  [ -f "$file" ] || aw_die "manifest not found: $file"
  sed -n 's/^##[[:space:]]*Group:[[:space:]]*//p' "$file"
}

aw_manifest_group() {
  local file="$1" want="$2"
  [ -f "$file" ] || aw_die "manifest not found: $file"
  awk -v want="$want" '
    /^##[[:space:]]*Group:/ {
      sub(/^##[[:space:]]*Group:[[:space:]]*/, "")
      current = $0
      next
    }
    /^##[[:space:]]*Requires:/ { next }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    current == want { print }
  ' "$file"
}

aw_manifest_group_requires() {
  local file="$1" want="$2"
  [ -f "$file" ] || aw_die "manifest not found: $file"
  awk -v want="$want" '
    /^##[[:space:]]*Group:/ {
      sub(/^##[[:space:]]*Group:[[:space:]]*/, "")
      current = $0
      next
    }
    current == want && /^##[[:space:]]*Requires:/ {
      sub(/^##[[:space:]]*Requires:[[:space:]]*/, "")
      print
    }
  ' "$file"
}
