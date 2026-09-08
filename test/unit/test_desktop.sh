#!/usr/bin/env bash
# The desktop applications layer (P2).
#
# The shipped config files are the interesting part here. waybar refuses to
# start on a malformed config.jsonc, and a keybind pointing at a command that
# is not installed does nothing at all, with no error anywhere - both fail
# silently on a booted machine and cost a gate run each to find.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/../.."
# shellcheck source=test/unit/harness.sh
. "$HERE/harness.sh"
# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=lib/manifest.sh
. "$ROOT/lib/manifest.sh"

core="$(aw_manifest_packages "$ROOT/manifest/core.packages")"
extras="$ROOT/manifest/extras.packages"

# --- the graphical answers to system tasks ----------------------------------
#
# Each of these exists because there was previously no graphical way to do the
# thing at all. Named individually rather than counted, so removing one is a
# decision somebody has to make on purpose.
for pkg in network-manager-applet nm-connection-editor pavucontrol blueman \
           grim slurp swappy nwg-displays file-roller gnome-text-editor \
           gnome-calculator; do
  if printf '%s\n' "$core" | grep -qx "$pkg"; then _pass
  else _fail "core.packages" "desktop application missing: $pkg"; fi
done

# nm-applet lists networks to JOIN; nm-connection-editor edits saved ones.
# They are not interchangeable and shipping only the editor leaves a laptop
# unable to get online without a terminal.
if printf '%s\n' "$core" | grep -qx network-manager-applet \
   && printf '%s\n' "$core" | grep -qx nm-connection-editor; then _pass
else _fail "core.packages" "both halves of the network GUI are required"; fi

# --- the new extras groups ---------------------------------------------------
for g in desktop-tools theming-gui printing; do
  if aw_manifest_groups "$extras" | grep -qx "$g"; then _pass
  else _fail "extras.packages" "group missing: $g"; fi
  if [ -n "$(aw_manifest_group "$extras" "$g")" ]; then _pass
  else _fail "extras.packages" "group $g is empty"; fi
done

# cups runs a daemon. It must never be in core - a machine that never prints
# has no business listening.
if printf '%s\n' "$core" | grep -qx cups; then
  _fail "core.packages" "cups is a daemon and belongs in the printing extras group"
else _pass; fi

# --- waybar's configuration must parse --------------------------------------
#
# waybar does not start at all on a malformed config. Python's json module
# after stripping // comments is close enough to jsonc for this purpose, and
# infinitely closer than not checking.
jsonc="$ROOT/config/waybar/config.jsonc"
if python3 - "$jsonc" <<'PY'
import json, re, sys
src = open(sys.argv[1], encoding="utf-8").read()
json.loads(re.sub(r"^\s*//.*$", "", src, flags=re.M))
PY
then _pass
else _fail "waybar" "config.jsonc is not valid JSON once comments are stripped"; fi

# Every module named in modules-* must be defined, or waybar logs and drops it.
if python3 - "$jsonc" <<'PY'
import json, re, sys
src = open(sys.argv[1], encoding="utf-8").read()
cfg = json.loads(re.sub(r"^\s*//.*$", "", src, flags=re.M))
named = []
for k in ("modules-left", "modules-center", "modules-right"):
    named += cfg.get(k, [])
missing = [m for m in named
           if m not in cfg and not m.startswith(("hyprland/", "clock", "tray"))]
sys.exit(1 if missing else 0)
PY
then _pass
else _fail "waybar" "a module is listed in modules-* but never configured"; fi

# --- keybinds may only call commands that exist ------------------------------
#
# A bind pointing at a missing command produces nothing: no error, no log, no
# clue. Every command a bind invokes must be either a package in core or one of
# our own binaries.
shellconf="$ROOT/config/hypr/shell.conf"
ours="aw archwright archwright-screenshot fuzzel makoctl loginctl systemctl uwsm foot"
while read -r cmd; do
  [ -n "$cmd" ] || continue
  if printf '%s\n' "$core" | grep -qx "$cmd"; then _pass; continue; fi
  case " $ours " in *" $cmd "*) _pass; continue ;; esac
  _fail "shell.conf" "keybind calls [$cmd], which is neither in core.packages nor one of ours"
done < <(sed -n 's/^bind[m]* = .*, exec, //p' "$shellconf" \
         | sed 's/^uwsm app -- //' | awk '{print $1}' | LC_ALL=C sort -u)

# The screenshot binds are the ones that did not exist at all before.
for action in region screen annotate; do
  if grep -q "archwright-screenshot $action" "$shellconf"; then _pass
  else _fail "shell.conf" "no keybind for screenshot $action"; fi
done

# --- the screenshot helper ---------------------------------------------------
shot="$ROOT/bin/archwright-screenshot"
if [ -x "$shot" ]; then _pass
else _fail "screenshot" "the helper is not executable"; fi
if bash -n "$shot"; then _pass
else _fail "screenshot" "the helper is not valid bash"; fi
assert_eq "$(bash "$shot" --help >/dev/null 2>&1; printf '%s' "$?")" "0" \
  "--help exits 0"
assert_eq "$(bash "$shot" nonsense >/dev/null 2>&1; printf '%s' "$?")" "2" \
  "an unknown action exits 2"

# Cancelling a region selection must be silent. slurp exits non-zero when the
# user presses Escape, and treating that as an error means a notification every
# time somebody changes their mind.
if grep -q 'exit 0' "$shot"; then _pass
else _fail "screenshot" "a cancelled selection is not handled as a non-error"; fi

# --- default handlers --------------------------------------------------------
mime="$ROOT/config/xdg/mimeapps.list"
# Verified against the package file lists on 2026-09-07; a wrong .desktop name
# resolves to nothing and the file simply refuses to open.
assert_eq "$(sed -n 's/^text\/plain=//p' "$mime")" "org.gnome.TextEditor.desktop" \
  "text files open in a GUI editor, not a modal terminal one"
for t in application/zip application/x-tar application/gzip; do
  if grep -qx "$t=org.gnome.FileRoller.desktop" "$mime"; then _pass
  else _fail "mimeapps.list" "no archive handler for $t"; fi
done

finish_tests
