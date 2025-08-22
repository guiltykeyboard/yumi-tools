#!/usr/bin/env bash
# update-installed.sh
# Keeps /Volumes/<SelectedVolume>/YUMI/Installed.txt in sync with on-disk *.iso files.
# - Volume picker (list + manual path)
# - Dry-run first with unified diff + color toggle + legend
# - Interactive menu: Write / View / Rescan / Quit
# - Only *.iso (excludes *.iso.zip); skips macOS system dirs under YUMI
# - Outputs relative backslash paths; groups by top-level folder in disk order
# - Case-sensitive sorting within each group
# - No manual temp files (uses process substitution only for diff; write verification avoids it)

set -euo pipefail

# ---------------- Volume selection (with Manual Path) ----------------

choose_volume() {
  local names=()
  echo "Scanning /Volumes ..."
  # List visible top-level directories in /Volumes (exclude dot-dirs)
  while IFS= read -r -d '' d; do
    names+=("${d#/Volumes/}")
  done < <(find /Volumes -mindepth 1 -maxdepth 1 -type d -not -name ".*" -print0)

  if [[ ${#names[@]} -eq 0 ]]; then
    echo "No user volumes found under /Volumes."
    exit 1
  fi

  while true; do
    echo
    echo "Select a volume:"
    local i=1
    for n in "${names[@]}"; do
      printf "  %2d) %s\n" "$i" "$n"
      i=$((i+1))
    done
    echo "   M) Manual path (e.g., /Volumes/Potato)"
    echo "   Q) Quit"
    read -r -p "Enter choice: " ans

    case "$ans" in
      [Qq])
        echo "Aborted."
        exit 0
        ;;
      [Mm])
        read -r -p "Enter volume path (e.g., /Volumes/Potato): " manual
        case "$manual" in
          /volumes/*) manual="/Volumes/${manual#/volumes/}";;
          /Volumes/*) ;;
          *) echo "Please enter a path under /Volumes (e.g., /Volumes/Potato)."; continue;;
        esac
        manual="${manual%/}"
        if [[ ! -d "$manual" ]]; then
          echo "Volume path not found: $manual"
          continue
        fi
        SELECTED_VOLUME="${manual#/Volumes/}"
        BASE="/Volumes/$SELECTED_VOLUME/YUMI"
        if [[ -d "$BASE" ]]; then
          echo "Using BASE: $BASE"
          return 0
        else
          echo "Folder not found: $BASE"
          echo "Tip: ensure the selected volume contains a 'YUMI' folder."
          continue
        fi
        ;;
      *)
        if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans>=1 && ans<=${#names[@]} )); then
          SELECTED_VOLUME="${names[$((ans-1))]}"
          BASE="/Volumes/$SELECTED_VOLUME/YUMI"
          if [[ -d "$BASE" ]]; then
            echo "Using BASE: $BASE"
            return 0
          else
            echo "Folder not found: $BASE"
            echo "Tip: ensure the selected volume contains a 'YUMI' folder."
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
  # Default: enable color if stdout is a TTY; otherwise disable
  local default_yes=0
  if [ -t 1 ]; then default_yes=1; fi

  echo
  if (( default_yes )); then
    read -r -p "Show colorized diff? [Y/n]: " resp
    case "$resp" in
      [Nn]*) COLORIZE=0 ;;
      *)      COLORIZE=1 ;;
    esac
  else
    read -r -p "Show colorized diff? (output is being piped) [y/N]: " resp
    case "$resp" in
      [Yy]*) COLORIZE=1 ;;
      *)      COLORIZE=0 ;;
    esac
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
      /^\+/    {print green $0 reset; next}  # additions
      /^-/     {print red   $0 reset; next}  # deletions
               {print $0}
    '
  else
    cat
  fi
}

# ---------------- Core logic ----------------

LIST=""
PROPOSED=""

normalize_list() {
  LIST="$BASE/Installed.txt"
  mkdir -p "$BASE"
  touch "$LIST"
  # strip CR (if edited on Windows)
  sed -i '' $'s/\r$//' "$LIST" || true
}

# Build $PROPOSED from disk; groups from disk order; case-sensitive sort per group
build_proposed() {
  PROPOSED=""
  local groups=()

  # ROOT first if any *.iso at BASE (no recursion in ROOT)
  if find "$BASE" -maxdepth 1 -type f \( -iname "*.iso" -a ! -iname "*.iso.zip" \) -print -quit >/dev/null 2>&1; then
    groups+=("ROOT")
  fi

  # Top-level dirs inside BASE in disk traversal order, excluding macOS system dirs
  while IFS= read -r -d '' d; do
    groups+=("${d#$BASE/}")
  done < <(find "$BASE" -mindepth 1 -maxdepth 1 -type d \
    \( -path "$BASE/.Spotlight-V100" -o \
       -path "$BASE/.fseventsd"     -o \
       -path "$BASE/.Trashes"       -o \
       -path "$BASE/.TemporaryItems" -o \
       -path "$BASE/lost+found" \) -prune -o -print0)

  # Build each group’s lines, sort case-sensitively, add blank line between groups
  local grp lines
  for grp in "${groups[@]}"; do
    if [[ "$grp" == "ROOT" ]]; then
      lines="$(find "$BASE" -maxdepth 1 -type f \( -iname "*.iso" -a ! -iname "*.iso.zip" \) -print0 \
        | xargs -0 -I{} bash -c 'f="$1"; rel="${f#'"$BASE"'/}"; printf "%s\n" "${rel//\//\\}"' _ {})"
    else
      if [[ -d "$BASE/$grp" ]]; then
        # Recurse into all subfolders for non-ROOT groups
        lines="$(find "$BASE/$grp" -type f \( -iname "*.iso" -a ! -iname "*.iso.zip" \) -print0 \
          | xargs -0 -I{} bash -c 'f="$1"; rel="${f#'"$BASE"'/}"; printf "%s\n" "${rel//\//\\}"' _ {})"
      else
        lines=""
      fi
    fi

    if [[ -n "${lines//[$'\n' ]/}" ]]; then
      # sort -u with LC_ALL=C for bytewise, case-sensitive
      lines="$(printf "%s\n" "$lines" | LC_ALL=C sort -u)"
      PROPOSED+="$lines"$'\n\n'
    fi
  done

  # Trim trailing blanks & ensure exactly one blank line between groups
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
  if command -v diff >/dev/null 2>&1; then
    # process substitution is fine under bash; colorization handled downstream
    diff -u -L "Installed.txt (current)" -L "Installed.txt (proposed)" \
      <(printf "%s\n" "$current") <(printf "%s\n" "$proposed") \
      | colorize_diff || true
  else
    echo "(diff not found; showing proposed file)"
    printf "%s\n" "$proposed"
  fi
}

write_changes() {
  # Ensure target dir is writable
  if [[ ! -w "$BASE" ]]; then
    echo "Error: Directory not writable: $BASE"
    ls -ldO "$BASE" 2>/dev/null || ls -ld "$BASE" || true
    return 1
  fi

  # If the file exists but is not writable, report and show flags
  if [[ -e "$LIST" && ! -w "$LIST" ]]; then
    echo "Error: File not writable: $LIST"
    ls -lO "$LIST" 2>/dev/null || ls -l "$LIST" || true
    echo "Tip: check volume permissions or file flags (e.g., 'uchg')."
    return 1
  fi

  # Backup current file if present
  if [[ -e "$LIST" ]]; then
    cp -f "$LIST" "$LIST.bak.$(date +%Y%m%d-%H%M%S)" || true
  fi

  # Write proposed content exactly; ensure a trailing newline
  if [[ -n "$PROPOSED" ]]; then
    printf "%s\n" "$PROPOSED" > "$LIST"
  else
    : > "$LIST"
  fi

  # Flush to disk
  sync || true

  # Verify that write took effect (avoid process substitution for portability)
  if printf "%s\n" "$PROPOSED" | cmp -s - "$LIST"; then
    echo "Changes written to Installed.txt. Backup saved alongside Installed.txt."
  else
    echo "Warning: write verification failed; Installed.txt does not match proposed content."
    echo "Inspect permissions/flags on the volume or file."
    ls -lO "$LIST" 2>/dev/null || ls -l "$LIST" || true
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
      [Ww])
        write_changes
        break
        ;;
      [Vv])
        echo "----- Proposed Installed.txt -----"
        printf "%s\n" "$PROPOSED"
        echo "----------------------------------"
        ;;
      [Rr])
        build_proposed
        show_diff
        ;;
      [Qq])
        echo "Aborted. No changes written."
        break
        ;;
      *)
        echo "Unrecognized choice."
        ;;
    esac
  done
}

main() {
  choose_volume                 # sets BASE via list or manual
  normalize_list                # sets LIST and normalizes
  build_proposed                # in-memory build

  # If no changes, report and exit (avoid process substitution)
  if printf "%s\n" "$PROPOSED" | cmp -s - "$LIST"; then
    echo "No changes needed. Installed.txt is up to date."
    exit 0
  fi

  ask_color_choice              # ask before showing diff
  show_diff
  menu_loop
}

main "$@"