#!/usr/bin/env bash
# update-installed-linux.sh
# Keeps <MountBase>/<SelectedVolume>/YUMI/Installed.txt in sync with on-disk *.iso files.
# - Volume picker (list + manual path) from common Linux mount roots (/media, /run/media/$USER)
# - Dry-run first with unified diff + color toggle + legend
# - Interactive menu: Write / View / Rescan / Quit
# - Only *.iso (excludes *.iso.zip); skips typical Linux system dirs under YUMI (none by default)
# - Outputs relative backslash paths; groups by top-level folder in disk order
# - Case-sensitive sorting within each group
# - No manual temp files (uses process substitution only for diff; write verification avoids it)

set -euo pipefail

# ---------------- Settings ----------------
# Candidate mount roots; order matters
MOUNT_ROOTS=("/media" "/run/media/${USER:-$(id -un)}")

# ---------------- Volume selection (with Manual Path) ----------------

choose_volume() {
  local candidates=()
  # Collect first-level directories under mount roots
  for root in "${MOUNT_ROOTS[@]}"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r -d '' d; do
      # Save as root:path  (we'll render nicely later)
      candidates+=("$root:${d#$root/}")
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -not -name ".*" -print0)
  done

  if [[ ${#candidates[@]} -eq 0 ]]; then
    echo "No user volumes found under: ${MOUNT_ROOTS[*]}"
    echo "You can still choose Manual Path."
  fi

  while true; do
    echo
    echo "Select a volume:"
    local i=1
    for entry in "${candidates[@]}"; do
      local root path label base
      root=${entry%%:*}
      path=${entry#*:}
      base="$root/$path/YUMI"
      if [[ -d "$base" ]]; then
        label="$root/$path (YUMI found)"
      else
        label="$root/$path"
      fi
      printf "  %2d) %s\n" "$i" "$label"
      i=$((i+1))
    done
    echo "   M) Manual path (e.g., /media/username/MyUSB)"
    echo "   Q) Quit"
    read -r -p "Enter choice: " ans

    case "$ans" in
      [Qq]) echo "Aborted."; exit 0 ;;
      [Mm])
        read -r -p "Enter mounted volume path (e.g., /media/$USER/MyUSB): " manual
        manual=${manual%/}
        if [[ ! -d "$manual" ]]; then
          echo "Volume path not found: $manual"; continue
        fi
        BASE="$manual/YUMI"
        if [[ -d "$BASE" ]]; then
          echo "Using BASE: $BASE"; return 0
        else
          echo "Folder not found: $BASE"
          echo "Tip: ensure the selected volume contains a 'YUMI' folder."
          continue
        fi
        ;;
      *)
        if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans>=1 && ans<=${#candidates[@]} )); then
          local sel=${candidates[$((ans-1))]}
          local root=${sel%%:*}
          local path=${sel#*:}
          BASE="$root/$path/YUMI"
          if [[ -d "$BASE" ]]; then
            echo "Using BASE: $BASE"; return 0
          else
            echo "Folder not found: $BASE"; echo "Tip: ensure the selected volume contains a 'YUMI' folder."
          fi
        else
          echo "Invalid choice."
        fi
        ;;
    esac
  done
}

# ---------------- Color / Legend ----------------
COLORIZE=0
bold=$'\033[1m'; red=$'\033[31m'; green=$'\033[32m'; cyan=$'\033[36m'; reset=$'\033[0m'

ask_color_choice() {
  local default_yes=0
  if [ -t 1 ]; then default_yes=1; fi
  echo
  if (( default_yes )); then
    read -r -p "Show colorized diff? [Y/n]: " resp
    case "$resp" in [Nn]*) COLORIZE=0 ;; *) COLORIZE=1 ;; esac
  else
    read -r -p "Show colorized diff? (output is being piped) [y/N]: " resp
    case "$resp" in [Yy]*) COLORIZE=1 ;; *) COLORIZE=0 ;; esac
  fi
}

print_legend() {
  echo
  if (( COLORIZE )); then
    echo "${bold}Legend:${reset}  ${red}- deletion${reset}   ${green}+ addition${reset}   ${cyan}@@ hunk@@${reset}   ${bold}---/+++ labels${reset}"
  else
    echo "Legend:  - deletion   + addition   @@ hunk@@   ---/+++ labels"
  fi
}


colorize_diff() {
  if (( COLORIZE )); then
    awk -v red="$red" -v green="$green" -v cyan="$cyan" -v bold="$bold" -v reset="$reset" '
      /^--- /  {print bold $0 reset; next}
      /^\+\+\+/{print bold $0 reset; next}
      /^@@/    {print cyan $0 reset; next}
      /^\+/    {print green $0 reset; next}
      /^-/     {print red   $0 reset; next}
               {print $0}
    '
  else
    cat
  fi
}

# ---------------- Optional unified diff via git ----------------
get_git_path() {
  if command -v git >/dev/null 2>&1; then
    command -v git
    return 0
  fi
  return 1
}

show_git_unified_diff() {
  # Usage: show_git_unified_diff "current_text" "proposed_text"
  # Returns 0 if git diff was run/shown, 1 otherwise (so caller can fallback)
  local current_text="$1"
  local proposed_text="$2"
  local gitbin
  gitbin="$(get_git_path)" || return 1

  # Create temp files and ensure cleanup
  local tmp1 tmp2
  tmp1="$(mktemp)" || return 1
  tmp2="$(mktemp)" || { rm -f "$tmp1"; return 1; }
  # Normalize to LF to avoid noisy CRLF diffs
  printf '%s\n' "${current_text//$'\r'/}" > "$tmp1"
  printf '%s\n' "${proposed_text//$'\r'/}" > "$tmp2"

  local color_arg
  if (( COLORIZE )); then color_arg="--color=always"; else color_arg="--color=never"; fi

  "$gitbin" --no-pager diff --no-index --unified=3 \
    --label "Installed.txt (current)" --label "Installed.txt (proposed)" \
    "$color_arg" "$tmp1" "$tmp2"
  local rc=$?
  rm -f "$tmp1" "$tmp2"
  # git diff exits 1 when there are differences; still counts as success for our purposes
  if [[ $rc -eq 0 || $rc -eq 1 ]]; then
    return 0
  fi
  return 1
}

# ---------------- Core logic ----------------
LIST=""
PROPOSED=""

normalize_list() {
  LIST="$BASE/Installed.txt"
  mkdir -p "$BASE"
  : > "$LIST"  # ensure file exists (Linux sed -i works without backup suffix)
  # Strip CR characters if any (in case file was edited on Windows)
  sed -i $'s/\r$//' "$LIST" || true
}

# Build $PROPOSED from disk; groups from disk order; case-sensitive sort per group
build_proposed() {
  PROPOSED=""
  local groups=()

  # ROOT first if any *.iso at BASE (no recursion in ROOT)
  if find "$BASE" -maxdepth 1 -type f \( -iname "*.iso" -a ! -iname "*.iso.zip" \) -print -quit >/dev/null 2>&1; then
    groups+=("ROOT")
  fi

  # Top-level dirs inside BASE in disk traversal order
  while IFS= read -r -d '' d; do
    groups+=("${d#$BASE/}")
  done < <(find "$BASE" -mindepth 1 -maxdepth 1 -type d -not -name ".*" -print0)

  local grp lines
  for grp in "${groups[@]}"; do
    if [[ "$grp" == "ROOT" ]]; then
      lines="$(find "$BASE" -maxdepth 1 -type f \( -iname "*.iso" -a ! -iname "*.iso.zip" \) -print0 \
        | xargs -0 -I{} bash -c 'f="$1"; rel="${f#'"$BASE"'/}"; printf "%s\n" "${rel//\//\\}"' _ {})"
    else
      if [[ -d "$BASE/$grp" ]]; then
        lines="$(find "$BASE/$grp" -type f \( -iname "*.iso" -a ! -iname "*.iso.zip" \) -print0 \
          | xargs -0 -I{} bash -c 'f="$1"; rel="${f#'"$BASE"'/}"; printf "%s\n" "${rel//\//\\}"' _ {})"
      else
        lines=""
      fi
    fi

    if [[ -n "${lines//$'\n' /}" ]]; then
      lines="$(printf "%s\n" "$lines" | LC_ALL=C sort -u)"
      PROPOSED+="$lines"$'\n\n'
    fi
  done

  # Trim trailing blanks & normalize single blank between groups
  if [[ -n "$PROPOSED" ]]; then
    PROPOSED="$(printf "%s" "$PROPOSED" | awk 'NF{last=NR} {print} END{for(i=NR;i>last;i--) ;}')"
    PROPOSED="$(printf "%s\n" "$PROPOSED" | awk 'NF{print; blank=0; next} {if(!blank){print ""} blank=1}')"
  fi
}

show_diff() {
  local current proposed
  current="$(cat "$LIST")"
  proposed="$PROPOSED"
  print_legend
  echo
  echo "Proposed changes to Installed.txt:"
  if show_git_unified_diff "$current" "$proposed"; then
    return
  fi
  if command -v diff >/dev/null 2>&1; then
    diff -u -L "Installed.txt (current)" -L "Installed.txt (proposed)" \
      <(printf "%s\n" "$current") <(printf "%s\n" "$proposed") \
      | colorize_diff || true
  else
    echo "(diff not found; showing proposed file)"; printf "%s\n" "$proposed"
  fi
}

write_changes() {
  # Check writability
  if [[ ! -w "$BASE" ]]; then
    echo "Error: Directory not writable: $BASE"
    ls -ld "$BASE" || true
    return 1
  fi
  if [[ -e "$LIST" && ! -w "$LIST" ]]; then
    echo "Error: File not writable: $LIST"
    ls -l "$LIST" || true
    return 1
  fi

  # Backup current file if present
  if [[ -e "$LIST" ]]; then
    cp -f "$LIST" "$LIST.bak.$(date +%Y%m%d-%H%M%S)" || true
  fi

  # Write proposed content; ensure trailing newline
  if [[ -n "$PROPOSED" ]]; then
    printf "%s\n" "$PROPOSED" > "$LIST"
  else
    : > "$LIST"
  fi

  sync || true

  # Verify (avoid process substitution for portability)
  if printf "%s\n" "$PROPOSED" | cmp -s - "$LIST"; then
    echo "Changes written to Installed.txt. Backup saved alongside Installed.txt."
  else
    echo "Warning: write verification failed; Installed.txt does not match proposed content."
    ls -l "$LIST" || true
    return 1
  fi
}

menu_loop() {
  while true; do
    echo
    echo "Select an option:"
    echo "  [W] Write these changes to Installed.txt"
    echo "  [V] View full proposed file"
    echo "  [R] Rescan disk and re-run dry run"
    echo "  [Q] Quit without writing"
    read -r -p "Your choice (W/V/R/Q): " choice
    case "$choice" in
      [Ww]) write_changes; break ;;
      [Vv]) echo "----- Proposed Installed.txt -----"; printf "%s\n" "$PROPOSED"; echo "----------------------------------" ;;
      [Rr]) build_proposed; show_diff ;;
      [Qq]) echo "Aborted. No changes written."; break ;;
      *) echo "Unrecognized choice." ;;
    esac
  done
}

main() {
  choose_volume
  normalize_list
  build_proposed

  if printf "%s\n" "$PROPOSED" | cmp -s - "$LIST"; then
    echo "No changes needed. Installed.txt is up to date."
    exit 0
  fi

  ask_color_choice
  show_diff
  menu_loop
}

main "$@"