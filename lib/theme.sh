#!/usr/bin/env bash
# Theming (spec section 12, decision D10 as revised by D21).
#
# THE SHAPE OF THIS
#
# A palette is thirteen colours in manifest/palettes/<id>.palette. Nothing
# downstream hardcodes a colour: every themed file is generated from a template
# in config/theme/ by substituting @token@ placeholders, and manifest/
# theme-files.tsv says which template becomes which file.
#
# WHY GENERATED COLOUR FILES RATHER THAN GENERATED CONFIGS
#
# Switching theme has to be possible after install without destroying the
# user's own configuration - that is the whole point of shipping seven palettes
# rather than one. Every consumer here supports an include, so the split is:
#
#   ~/.config/foot/foot.ini      the user's. Seeded once, never rewritten.
#   ~/.config/foot/colors.ini    ours. Regenerated on every theme change.
#
# The user's file carries one include line pointing at ours. So a theme change
# rewrites only files this project owns, and a config someone has spent an
# evening tuning survives it.
#
# ABSOLUTE PATHS IN THOSE INCLUDES
#
# foot and fuzzel both document `include` as taking an absolute path (mako also
# accepts ~/). So the include line cannot be a static string - it carries the
# real home directory, which is why the user-facing configs are rendered
# through this same substitution rather than copied.

AW_THEME_TOKENS="crust mantle base surface0 surface1 overlay subtext text accent alt1 alt2 alt3 alt4"

aw_theme_reset() {
  local tok
  for tok in $AW_THEME_TOKENS; do
    unset "AW_PAL_$tok" "AW_PAL_${tok}_hex"
  done
  AW_PAL_id=""
  AW_PAL_name=""
  AW_PAL_gtk_accent=""
  AW_PAL_home=""
}
aw_theme_reset

# Palette ids, sorted, one per line.
aw_theme_list() {
  local dir="$1" f
  [ -d "$dir" ] || aw_die "no palette directory: $dir"
  for f in "$dir"/*.palette; do
    [ -f "$f" ] || continue
    f="${f##*/}"
    printf '%s\n' "${f%.palette}"
  done | LC_ALL=C sort
}

# Load one palette. Never sourced - parsed, like the answer file, and for the
# same reason: these values are interpolated into generated files.
aw_theme_load() {
  local file="$1" line key value tok
  [ -f "$file" ] || aw_die "no such palette: $file"
  aw_theme_reset

  AW_PAL_id="${file##*/}"
  AW_PAL_id="${AW_PAL_id%.palette}"

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in *=*) ;; *) continue ;; esac
    key="${line%%=*}"
    value="${line#*=}"
    # Trim both sides.
    key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
    case "$key" in
      name)       AW_PAL_name="$value" ;;
      gtk_accent) AW_PAL_gtk_accent="$value" ;;
      *)
        for tok in $AW_THEME_TOKENS; do
          if [ "$key" = "$tok" ]; then
            printf '%s' "$value" | grep -qiE '^#[0-9a-f]{6}$' \
              || aw_die "palette $AW_PAL_id: $key is not a 6-digit hex colour: [$value]"
            printf -v "AW_PAL_$tok" '%s' "$value"
            printf -v "AW_PAL_${tok}_hex" '%s' "${value#\#}"
          fi
        done
        ;;
    esac
  done < "$file"

  for tok in $AW_THEME_TOKENS; do
    local var="AW_PAL_$tok"
    [ -n "${!var:-}" ] || aw_die "palette $AW_PAL_id is missing the '$tok' colour"
  done
  [ -n "$AW_PAL_name" ] || aw_die "palette $AW_PAL_id has no name"
  # A GTK4 app takes a NAMED accent, not a hex, so this is a fixed vocabulary
  # rather than free text.
  case "$AW_PAL_gtk_accent" in
    blue|teal|green|yellow|orange|red|pink|purple|slate) ;;
    *) aw_die "palette $AW_PAL_id: gtk_accent [$AW_PAL_gtk_accent] is not a libadwaita accent name" ;;
  esac
}

# Render one template to stdout, substituting @token@.
#
# Every placeholder must resolve. An unsubstituted @something@ left in a config
# is not a cosmetic problem - foot and fuzzel refuse to start on a parse error,
# so it would be a black screen at first login.
aw_theme_render() {
  local template="$1" line tok var out
  [ -f "$template" ] || aw_die "no such template: $template"
  out=""
  while IFS= read -r line || [ -n "$line" ]; do
    for tok in $AW_THEME_TOKENS; do
      var="AW_PAL_$tok";       line="${line//@$tok@/${!var}}"
      var="AW_PAL_${tok}_hex"; line="${line//@${tok}_hex@/${!var}}"
    done
    line="${line//@name@/$AW_PAL_name}"
    line="${line//@id@/$AW_PAL_id}"
    line="${line//@gtk_accent@/$AW_PAL_gtk_accent}"
    line="${line//@home@/$AW_PAL_home}"
    out="$out$line"$'\n'
  done < "$template"

  # Look for the placeholder SHAPE, not merely for two '@' characters. GTK CSS
  # legitimately uses '@define-color' on every line, so a naive match rejected
  # the waybar template for every palette.
  local leftover
  leftover="$(printf '%s' "$out" | grep -oE '@[a-z][a-z0-9_]*@' | head -1)"
  [ -z "$leftover" ] \
    || aw_die "template $template still has an unsubstituted placeholder: $leftover"
  printf '%s' "$out"
}

# Render the rows of a theme-files manifest that belong to one owner.
#
#   <template>\t<destination>\t<owner>
#
# owner 'theme' - colours only, regenerated on every theme change.
# owner 'user'  - structure, seeded once. Rendered rather than copied only
#                 because the include line has to carry an absolute home path.
#
# Filtering by owner is what makes `archwright theme set` safe: it regenerates
# the 'theme' rows and never touches a 'user' row, so a config someone has
# tuned survives a theme change.
#
# Writes the number of files rendered to stdout, so a caller can assert it did
# something rather than silently doing nothing.
aw_theme_generate() {
  local files="$1" tmpl_dir="$2" dest_root="$3" want_owner="${4:-theme}"
  local template dest owner n=0
  [ -f "$files" ] || aw_die "no theme file manifest: $files"
  while IFS=$'\t' read -r template dest owner; do
    [ -n "$template" ] || continue
    case "$template" in '#'*) continue ;; esac
    [ -n "$owner" ] || aw_die "theme manifest row for $template names no owner"
    case "$owner" in
      theme|user) ;;
      *) aw_die "theme manifest row for $template has an unknown owner: [$owner]" ;;
    esac
    [ "$owner" = "$want_owner" ] || continue
    [ -f "$tmpl_dir/$template" ] || aw_die "missing template: $tmpl_dir/$template"
    install -d -m 0755 "$dest_root/$(dirname "$dest")" \
      || aw_die "could not create the directory for $dest"
    aw_theme_render "$tmpl_dir/$template" > "$dest_root/$dest" \
      || aw_die "could not write $dest"
    n=$((n + 1))
  done < <(grep -v '^[[:space:]]*#' "$files" | grep -v '^[[:space:]]*$')
  printf '%s\n' "$n"
}
