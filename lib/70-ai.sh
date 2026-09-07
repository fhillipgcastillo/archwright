#!/usr/bin/env bash
# Phase 8: the AI layer (spec section 9).
#
# Packages are already installed - the base phase pacstraps mise and the GitHub
# CLI along with everything else. This phase only generates, installs and
# seeds.
#
# Four things land here:
#
#   1. A lazy launcher per agent, so the CLIs are available without any of them
#      being downloaded at install time.
#   2. The archwright command itself.
#   3. A shared skill describing this system, so an agent that starts here
#      already knows where things live.
#   4. Login-shell wiring: ~/.local/bin on PATH, and the `a` shortcut.
#
# The sudo window has nothing to install - it is a subcommand of the archwright
# command, which arrives in step 2.

AW_AGENT_MANIFEST_REL="manifest/agents.tsv"
AW_AGENT_STUB_DIR="/usr/share/archwright/agent-stubs"
AW_AGENT_SKILL_DIR_REL=".local/share/archwright/agent-skills"

# Where the shared skill directory is linked from.
#
# Only Claude Code has a settled convention for a per-user skills directory, so
# only that link is made. Linking into ~/.codex, ~/.pi and ~/.agents was in the
# design, but nothing reads those paths today and shipping something nothing
# reads is exactly what got plymouth removed (L36, D20). This is a list so
# adding one later is a one-line change.
AW_AGENT_SKILL_LINKS=".claude/skills"

aw_ai() {
  local manifest="$AW_ROOT/$AW_AGENT_MANIFEST_REL"
  local home="/mnt/home/$AW_USERNAME"
  [ -f "$manifest" ] || aw_die "missing $AW_AGENT_MANIFEST_REL"
  [ -d "$home" ] || aw_die "user home $home does not exist - did the base phase run?"

  aw_log info "installing the archwright command"
  install -d -m 0755 /mnt/usr/share/archwright/bin
  install -m 0755 "$AW_ROOT/bin/archwright" \
    /mnt/usr/share/archwright/bin/archwright \
    || aw_die "could not install the archwright command"
  ln -sf /usr/share/archwright/bin/archwright /mnt/usr/bin/archwright \
    || aw_die "could not link archwright into /usr/bin"

  # The stub tree is ours and is regenerated every run. The user's copies in
  # ~/.local/bin are seeded from it and never overwritten, so this is where a
  # changed spec actually takes effect for a new install.
  aw_log info "generating agent launchers"
  aw_agent_write_stubs "$manifest" "/mnt$AW_AGENT_STUB_DIR"

  aw_log info "seeding the user's launchers"
  install -d -m 0755 "$home/.local/bin"
  local name rc
  while IFS=$'\t' read -r name _ _; do
    [ -n "$name" ] || continue
    rc=0
    aw_seed_config "/mnt$AW_AGENT_STUB_DIR" "$home/.local/bin" "$name" || rc=$?
    [ "$rc" -le 1 ] || aw_die "could not seed the $name launcher"
    # aw_seed_config installs 0644 because it exists for config files. A
    # launcher that is not executable fails in a way that looks like the agent
    # is missing, so fix the mode on anything actually seeded - and only on
    # that, because rc=1 means the file is the user's and is not ours to chmod.
    if [ "$rc" -eq 0 ]; then
      chmod 0755 "$home/.local/bin/$name" \
        || aw_die "could not make the $name launcher executable"
    fi
  done < <(aw_manifest_agents "$manifest")

  aw_log info "installing the shared agent skill"
  local skilldir="$home/$AW_AGENT_SKILL_DIR_REL/archwright"
  install -d -m 0755 "$skilldir"
  install -m 0644 "$AW_ROOT/config/agent-skills/archwright/SKILL.md" \
    "$skilldir/SKILL.md" \
    || aw_die "could not install the shared agent skill"

  local link up rest
  for link in $AW_AGENT_SKILL_LINKS; do
    install -d -m 0755 "$home/$link"
    # Relative to the user's home rather than absolute, so the link still
    # resolves if the home directory is moved or mounted elsewhere. The number
    # of '..' steps is derived from how deep the link sits, so adding a link at
    # a different depth to AW_AGENT_SKILL_LINKS cannot silently produce a
    # dangling symlink.
    up="../"
    rest="$link"
    while [ "$rest" != "${rest#*/}" ]; do
      rest="${rest#*/}"
      up="../$up"
    done
    ln -sfn "$up$AW_AGENT_SKILL_DIR_REL/archwright" "$home/$link/archwright" \
      || aw_die "could not link the shared skill into $link"
    [ -f "$home/$link/archwright/SKILL.md" ] \
      || aw_die "the shared skill link in $link does not resolve"
  done

  aw_log info "installing the login-shell environment"
  install -d -m 0755 /mnt/etc/profile.d
  install -m 0644 "$AW_ROOT/config/profile.d/archwright-agents.sh" \
    /mnt/etc/profile.d/archwright-agents.sh \
    || aw_die "could not install the agent profile script"

  aw_log info "seeding the user's agent settings"
  aw_install_defaults "$AW_ROOT/config" /mnt \
    || aw_die "could not refresh the default config tree"
  rc=0
  aw_seed_config "/mnt/usr/share/archwright/default-config" "$home/.config" \
    "archwright/agents.sh" || rc=$?
  [ "$rc" -le 1 ] || aw_die "could not seed archwright/agents.sh"

  # Agents refuse to treat the home directory as a workspace, and the launcher
  # redirects there, so it has to exist before the first launch rather than
  # being created by a failing cd.
  install -d -m 0755 "$home/Work"

  aw_log info "recording the default agent"
  install -d -m 0755 "$home/.local/state/archwright"
  if [ ! -f "$home/.local/state/archwright/default-agent" ]; then
    # `sed -n 1p` rather than `head -1`: head closes the pipe as soon as it has
    # its line, which can SIGPIPE the upstream grep. Under `set -o pipefail`
    # that aborts the install, and only sometimes - the worst kind of bug to
    # leave in an installer.
    local first
    first="$(aw_manifest_agents "$manifest" | cut -f1 | sed -n 1p)"
    [ -n "$first" ] || aw_die "the agent manifest is empty - no default to record"
    printf '%s\n' "$first" > "$home/.local/state/archwright/default-agent" \
      || aw_die "could not record the default agent"
  fi

  aw_run_in_chroot "chown -R '$AW_USERNAME:$AW_USERNAME' '/home/$AW_USERNAME'" \
    || aw_die "could not chown the user's home directory"

  aw_log info "AI layer complete"
}
