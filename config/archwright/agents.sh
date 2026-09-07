# shellcheck shell=sh
# Your agent settings.
#
# Archwright seeds this file once and never overwrites it, so anything you put
# here survives every update. It is sourced by every login shell, after
# /etc/profile.d/archwright-agents.sh has set up PATH and the `a` function.

# ---------------------------------------------------------------------------
# UNATTENDED MODES - DELIBERATELY COMMENTED OUT
# ---------------------------------------------------------------------------
#
# Every agent below can be told not to stop and ask before it acts: it will
# edit files, run commands and install things without pausing for you.
#
# On a machine you just installed, that is a lot of trust to hand over by
# default. So Archwright ships the aliases written out and switched off. Turn
# one on by deleting the '#', and know what you turned on.
#
# What you are agreeing to, concretely: an agent running in this mode can
# delete files you care about, push to a remote, install packages, and - if you
# have a sudo window open - do all of that as root. It is a reasonable thing to
# want in a scratch project or a container. It is a poor default for $HOME.
#
# Flag names move between versions. If one of these is rejected, check the
# agent's own --help rather than assuming the agent is broken.

# alias claude-yolo='claude --dangerously-skip-permissions'
# alias codex-yolo='codex --full-auto'
# alias crush-yolo='crush --yolo'

# ---------------------------------------------------------------------------
# Local models
# ---------------------------------------------------------------------------
#
# With EXTRAS=ai-local the machine has ollama. Point an agent at it by
# exporting the endpoint it expects - see the Guide's AI chapter, which has the
# per-agent details.

# export OLLAMA_HOST=127.0.0.1:11434
