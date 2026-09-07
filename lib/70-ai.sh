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
# The point of a SHARED skill directory is that every agent on the machine can
# be asked to change the system - "restyle the bar", "turn off the idle lock" -
# and finds the same description of how this system is laid out. An agent
# without the link is an agent that has to be told all of it again, or that
# guesses. So the link goes everywhere an agent looks, including agents not
# installed yet: the directory costs nothing and is already correct when one
# arrives.
#
# All four paths are real conventions, verified:
#   ~/.claude/skills      Claude Code
#   ~/.codex/skills       Codex CLI
#   ~/.pi/agent/skills    pi
#   ~/.agents/skills      the cross-agent location in the agentskills.io
#                         standard, which pi and others scan
AW_AGENT_SKILL_LINKS=".claude/skills .codex/skills .pi/agent/skills .agents/skills"

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

  # The canonical copy is ours and is replaced on every run; the user's copy is
  # SEEDED from it and never overwritten.
  #
  # This was an unconditional `install` into the user's tree, which is exactly
  # the contract the shipped skill teaches agents to rely on - "Archwright
  # seeds a user config file once and never again". The file that says that was
  # the file breaking it: a re-run of this phase discarded any edit the user
  # had made to their own copy, silently.
  aw_log info "installing the shared agent skill"
  install -d -m 0755 /mnt/usr/share/archwright/agent-skills/archwright
  install -m 0644 "$AW_ROOT/config/agent-skills/archwright/SKILL.md" \
    /mnt/usr/share/archwright/agent-skills/archwright/SKILL.md \
    || aw_die "could not install the shared agent skill"

  rc=0
  aw_seed_config /mnt/usr/share/archwright/agent-skills \
    "$home/$AW_AGENT_SKILL_DIR_REL" "archwright/SKILL.md" || rc=$?
  [ "$rc" -le 1 ] || aw_die "could not seed the shared agent skill"

  local link up rest target
  for link in $AW_AGENT_SKILL_LINKS; do
    # mkdir, not `install -d`: install -d resets the mode of a directory that
    # already exists, and ~/.claude or ~/.pi may well be 0700 on purpose.
    mkdir -p "$home/$link" || aw_die "could not create $link"
    target="$home/$link/archwright"

    # Relative to the user's home rather than absolute, so the link still
    # resolves if the home directory is moved or mounted elsewhere. The number
    # of '..' steps is derived from how deep the link sits, because these are
    # not all the same depth - .pi/agent/skills is three - and a hardcoded
    # '../../' would produce a dangling link that nothing notices until an
    # agent quietly fails to find the skill.
    up="../"
    rest="$link"
    while [ "$rest" != "${rest#*/}" ]; do
      rest="${rest#*/}"
      up="../$up"
    done

    # A real directory here belongs to the user - an agent may have put its own
    # skill in it. ln -sfn would descend INTO it and create a nested link.
    if [ -e "$target" ] && [ ! -L "$target" ]; then
      aw_log warn "  $link/archwright already exists and is not a link - left alone"
      continue
    fi
    ln -sfn "$up$AW_AGENT_SKILL_DIR_REL/archwright" "$target" \
      || aw_die "could not link the shared skill into $link"
    [ -f "$target/SKILL.md" ] \
      || aw_die "the shared skill link in $link does not resolve"
  done

  # The window a reboot would otherwise leave open. See
  # config/tmpfiles/archwright-sudo-window.conf for why this is not optional.
  aw_log info "installing the sudo-window boot cleanup"
  install -d -m 0755 /mnt/usr/lib/tmpfiles.d
  install -m 0644 "$AW_ROOT/config/tmpfiles/archwright-sudo-window.conf" \
    /mnt/usr/lib/tmpfiles.d/archwright-sudo-window.conf \
    || aw_die "could not install the sudo-window boot cleanup"

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
