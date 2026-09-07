# shellcheck shell=sh
# Archwright agent environment. System-wide, ours, replaced on update.
#
# Sourced by /etc/profile, not executed, so it has no shebang and must stay
# POSIX: /etc/profile is read by every login shell, not only bash.
#
# Nothing here is yours to edit - put your own settings in
# ~/.config/archwright/agents.sh, which this file sources last.

# Arch does not put ~/.local/bin on PATH, and that is where the agent launchers
# live. Added only when it is missing, so re-sourcing a login shell does not
# grow PATH one copy at a time.
case ":${PATH}:" in
  *":${HOME}/.local/bin:"*) ;;
  *) PATH="${HOME}/.local/bin:${PATH}" ;;
esac
export PATH

# `a` runs the default agent inline in this terminal, forwarding whatever you
# give it. A function rather than an alias so arguments work in every position:
#
#   a                     start the default agent here
#   a "fix the failing test"
#
# Change which agent that is with:  archwright default agent <name>
a() {
  command archwright agent "$@"
}

if [ -r "${HOME}/.config/archwright/agents.sh" ]; then
  # shellcheck source=/dev/null
  . "${HOME}/.config/archwright/agents.sh"
fi
