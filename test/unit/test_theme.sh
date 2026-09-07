#!/usr/bin/env bash
# aw_theme_load assigns every AW_PAL_* variable indirectly, with printf -v,
# so no static analysis can see where they come from. File scope, because a
# directive placed lower down applies only to the next command.
# shellcheck disable=SC2154
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/../.."
# shellcheck source=test/unit/harness.sh
. "$HERE/harness.sh"
# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=lib/theme.sh
. "$ROOT/lib/theme.sh"


tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/pal" "$tmp/tpl" "$tmp/out"

write_palette() {
  cat > "$tmp/pal/$1.palette" <<EOF
name = Test $1
gtk_accent = ${2:-purple}
crust = #010203
mantle = #040506
base = #070809
surface0 = #0a0b0c
surface1 = #0d0e0f
overlay = #101112
subtext = #131415
text = #161718
accent = ${3:-#191a1b}
alt1 = #1c1d1e
alt2 = #1f2021
alt3 = #222324
alt4 = #252627
EOF
}

# --- listing -----------------------------------------------------------------
write_palette zebra
write_palette alpha
assert_eq "$(aw_theme_list "$tmp/pal" | tr '\n' ',')" "alpha,zebra," \
  "palettes are listed by id, sorted"
assert_fails aw_theme_list "$tmp/nope" "a missing palette directory fails loudly"

# --- loading -----------------------------------------------------------------
aw_theme_load "$tmp/pal/alpha.palette"
assert_eq "$AW_PAL_id" "alpha" "the id comes from the filename"
assert_eq "$AW_PAL_name" "Test alpha" "the display name is read"
assert_eq "$AW_PAL_accent" "#191a1b" "a colour is read with its hash"
assert_eq "$AW_PAL_accent_hex" "191a1b" "and again without, for formats that want bare hex"
assert_eq "$AW_PAL_gtk_accent" "purple" "the libadwaita accent name is read"

# Loading a second palette must not inherit from the first - the same reset bug
# the answer file had.
write_palette beta slate "#abcdef"
aw_theme_load "$tmp/pal/beta.palette"
assert_eq "$AW_PAL_accent" "#abcdef" "a second load replaces the first"
assert_eq "$AW_PAL_gtk_accent" "slate" "including the accent name"

# --- rejections --------------------------------------------------------------
printf 'name = X\ngtk_accent = blue\ncrust = notacolour\n' > "$tmp/pal/bad1.palette"
assert_fails aw_theme_load "$tmp/pal/bad1.palette" "a malformed hex value is refused"

printf 'name = X\ngtk_accent = blue\ncrust = #010203\n' > "$tmp/pal/bad2.palette"
assert_fails aw_theme_load "$tmp/pal/bad2.palette" "a palette missing colours is refused"

write_palette bad3 "chartreuse"
assert_fails aw_theme_load "$tmp/pal/bad3.palette" \
  "an accent name libadwaita does not have is refused"

sed 's/^name = .*//' "$tmp/pal/alpha.palette" > "$tmp/pal/bad4.palette"
assert_fails aw_theme_load "$tmp/pal/bad4.palette" "a palette with no name is refused"

assert_fails aw_theme_load "$tmp/pal/missing.palette" "a missing palette file is refused"

# --- rendering ---------------------------------------------------------------
aw_theme_load "$tmp/pal/alpha.palette"
AW_PAL_home="/home/tester"
printf 'a=@accent@\nb=@accent_hex@\nc=@name@\nd=@home@/x\ne=@gtk_accent@\n' > "$tmp/tpl/t.in"
got="$(aw_theme_render "$tmp/tpl/t.in")"
assert_contains "$got" "a=#191a1b"        "the hash form substitutes"
assert_contains "$got" "b=191a1b"         "the bare form substitutes"
assert_contains "$got" "c=Test alpha"     "the name substitutes"
assert_contains "$got" "d=/home/tester/x" "the home path substitutes"
assert_contains "$got" "e=purple"         "the accent name substitutes"

# An unsubstituted placeholder is not cosmetic: foot and fuzzel refuse to start
# on a parse error, so it would be a black screen at first login.
printf 'x=@nosuchtoken@\n' > "$tmp/tpl/bad.in"
assert_fails aw_theme_render "$tmp/tpl/bad.in" "an unknown placeholder fails loudly"
assert_fails aw_theme_render "$tmp/tpl/absent.in" "a missing template fails loudly"

# --- generating by owner -----------------------------------------------------
printf 'x=@base@\n' > "$tmp/tpl/one.in"
printf 'y=@text@\n' > "$tmp/tpl/two.in"
printf '# comment\none.in\t.config/a/one\ttheme\ntwo.in\t.config/b/two\tuser\n' > "$tmp/files.tsv"

assert_eq "$(aw_theme_generate "$tmp/files.tsv" "$tmp/tpl" "$tmp/out" theme)" "1" \
  "only the theme-owned row is generated"
if [ -f "$tmp/out/.config/a/one" ]; then _pass
else _fail "theme" "the theme-owned file was not written"; fi
if [ -f "$tmp/out/.config/b/two" ]; then
  _fail "theme" "a user-owned file was written during a theme-owned pass"
else _pass; fi

assert_eq "$(aw_theme_generate "$tmp/files.tsv" "$tmp/tpl" "$tmp/out" user)" "1" \
  "the user-owned row generates on its own pass"
assert_contains "$(cat "$tmp/out/.config/b/two")" "y=#161718" "with substitution applied"

printf 'one.in\t.config/a/one\tsomebody\n' > "$tmp/badowner.tsv"
assert_fails aw_theme_generate "$tmp/badowner.tsv" "$tmp/tpl" "$tmp/out" theme \
  "an unknown owner is refused"

# ---------------------------------------------------------------------------
# The shipped palettes and templates.
#
# Every palette must render every template cleanly. This is the assertion that
# catches a typo in a template or a token missing from one palette, and it is
# cheap: seven palettes across seven templates is a fraction of a second, and
# the alternative is finding it as an unparseable config on a booted machine.
# ---------------------------------------------------------------------------
pal_dir="$ROOT/manifest/palettes"
tpl_dir="$ROOT/config/theme"
files_tsv="$ROOT/manifest/theme-files.tsv"

shipped="$(aw_theme_list "$pal_dir")"
if [ -n "$shipped" ]; then _pass
else _fail "palettes" "no palettes are shipped"; fi

# Mocha is the documented default and the answer file falls back to it.
if printf '%s\n' "$shipped" | grep -qx mocha; then _pass
else _fail "palettes" "the default palette 'mocha' is not shipped"; fi

for pid in $shipped; do
  if ( aw_theme_load "$pal_dir/$pid.palette" ) >/dev/null 2>&1; then _pass
  else _fail "palettes" "$pid does not load"; fi

  aw_theme_load "$pal_dir/$pid.palette"
  AW_PAL_home="/home/tester"

  for tpl in "$tpl_dir"/*.in; do
    out="$(aw_theme_render "$tpl" 2>&1)" || out="RENDER-FAILED"
    if [ "$out" = "RENDER-FAILED" ]; then
      _fail "theme" "$pid does not render $(basename "$tpl")"
    elif printf '%s' "$out" | grep -qE '@[a-z0-9_]+@'; then
      _fail "theme" "$pid left a placeholder in $(basename "$tpl")"
    else _pass; fi
  done

  # A palette with no wallpaper would boot to a plain colour with no warning.
  if [ -f "$ROOT/config/wallpapers/$pid.png" ]; then _pass
  else _fail "wallpapers" "$pid has no generated wallpaper"; fi
done

# Every row of the file manifest must name a template that exists, and every
# template must be named by a row - an orphan template is dead weight, a
# missing one is a broken install.
while IFS=$'\t' read -r template dest owner; do
  case "$template" in ''|'#'*) continue ;; esac
  if [ -f "$tpl_dir/$template" ]; then _pass
  else _fail "theme-files.tsv" "row names a template that does not exist: $template"; fi
  case "$dest" in .config/*) _pass ;; *) _fail "theme-files.tsv" "destination is not under .config: $dest" ;; esac
  case "$owner" in theme|user) _pass ;; *) _fail "theme-files.tsv" "bad owner: $owner" ;; esac
done < <(grep -v '^[[:space:]]*#' "$files_tsv" | grep -v '^[[:space:]]*$')

for tpl in "$tpl_dir"/*.in; do
  base="$(basename "$tpl")"
  if grep -q "^$base	" "$files_tsv"; then _pass
  else _fail "theme-files.tsv" "template $base is not named by any row"; fi
done

finish_tests
