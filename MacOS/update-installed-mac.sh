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

# Predeclare arrays to avoid nounset errors on older bash
declare -a MOUNT_ROOTS
declare -a candidates

# Decide where the working BASE should be for a given mounted volume path.
# Prefer the location that actually contains ISOs when both the volume root and the YUMI folder have an Installed.txt.
compute_base_for_mnt() {
  local mnt="$1"
  local root_base="$mnt"
  local yumi_base="$mnt/YUMI"

  local has_yumi_dir has_yumi_inst has_root_inst has_yumi_isos has_root_isos
  has_yumi_dir=0; has_yumi_inst=0; has_root_inst=0; has_yumi_isos=0; has_root_isos=0

  [[ -d "$yumi_base" ]] && has_yumi_dir=1
  [[ -f "$yumi_base/Installed.txt" ]] && has_yumi_inst=1
  [[ -f "$root_base/Installed.txt" ]] && has_root_inst=1

  if [[ -d "$yumi_base" ]]; then
    if find "$yumi_base" -type f \( -iname "*.iso" -a ! -iname "*.iso.zip" \) -print -quit >/dev/null 2>&1; then
      has_yumi_isos=1
    fi
  fi
  if [[ -d "$root_base" ]]; then
    if find "$root_base" -type f \( -iname "*.iso" -a ! -iname "*.iso.zip" \) -print -quit >/dev/null 2>&1; then
      has_root_isos=1
    fi
  fi

  # Selection rules:
  # 1) If YUMI has ISOs, prefer YUMI.
  # 2) Else if ROOT has ISOs, prefer ROOT (even if YUMI has an Installed.txt with no ISOs).
  # 3) Else if only one side has Installed.txt, prefer that side.
  # 4) Else default to YUMI if it exists; otherwise ROOT.
  if (( has_yumi_isos )); then
    printf '%s' "$yumi_base"; return 0
  fi
  if (( has_root_isos )); then
    printf '%s' "$root_base"; return 0
  fi
  if (( has_yumi_inst && ! has_root_inst )); then
    printf '%s' "$yumi_base"; return 0
  fi
  if (( has_root_inst && ! has_yumi_inst )); then
    printf '%s' "$root_base"; return 0
  fi
  if (( has_yumi_dir )); then
    printf '%s' "$yumi_base"; return 0
  fi
  printf '%s' "$root_base"
}

# ---------------- Settings ----------------
# Probe likely mount roots rather than relying on env vars (works under sudo)
MOUNT_ROOTS=()
for d in \
  /Volumes \
  "/media" \
  "/run/media/${SUDO_USER:-${USER:-$(id -un)}}" \
  "/run/media/${USER:-$(id -un)}"; do
  [[ -d "$d" ]] && MOUNT_ROOTS+=("$d")
done
# Hard fallback if nothing matched
if [[ ${#MOUNT_ROOTS[@]:-0} -eq 0 ]]; then
  [[ -d /Volumes ]] && MOUNT_ROOTS=("/Volumes") || MOUNT_ROOTS=("/media")
fi

# ---------------- Volume selection (with Manual Path) ----------------

choose_volume() {
  candidates=()
  # Collect first-level directories under mount roots
  for root in "${MOUNT_ROOTS[@]}"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r -d '' d; do
      # Save as root:path  (we'll render nicely later)
      candidates+=("$root:${d#$root/}")
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -not -name ".*" -print0)
  done

  if [[ ${#candidates[@]:-0} -eq 0 ]]; then
    echo "No user volumes found under: ${MOUNT_ROOTS[*]}"
    echo "You can still choose Manual Path."
  fi

  while true; do
    echo
    echo "Select a volume:"
    local i=1
    for entry in "${candidates[@]:-}"; do
      local root path label base mnt stats kblocks used pct total_gb
      root=${entry%%:*}
      path=${entry#*:}
      mnt="$root/$path"
      base="$(compute_base_for_mnt "$mnt")"

      # Try to get capacity and % used (portable: df -kP)
      stats="$(df -kP "$mnt" 2>/dev/null | awk 'NR==2 {print $2, $3, $5}')"
      kblocks=""; used=""; pct=""; total_gb=""
      if [[ -n "$stats" ]]; then
        read -r kblocks used pct <<<"$stats"
        # Convert 1K-blocks to gigabytes (GiB-based using 1024)
        total_gb="$(awk -v b="$kblocks" 'BEGIN{printf "%.1f", b/1048576}')"
      fi

      # Counts for this volume
      local list_path iso_count installed_count
      list_path="$base/Installed.txt"
      if [[ -f "$list_path" ]]; then
        # Count non-empty lines only, to avoid counting a trailing newline as a line
        installed_count="$(grep -c "." "$list_path" || echo 0)"
      else
        installed_count=0
      fi
      # Count ISO files present under BASE for this volume
      iso_count="$(find "$base" -type f \( -iname "*.iso" -a ! -iname "*.iso.zip" \) -print 2>/dev/null | wc -l | tr -d ' ')"
      [[ -z "$iso_count" ]] && iso_count=0

      if [[ -d "$base" ]]; then
        if [[ "$base" == "$mnt/YUMI" ]]; then
          label="$mnt (YUMI found)"
        else
          label="$mnt (root)"
        fi
      else
        label="$mnt"
      fi

      local info_parts=()
      if [[ -n "$total_gb" && -n "$pct" ]]; then
        info_parts+=("$total_gb GB total")
        info_parts+=("$pct used")
      fi
      info_parts+=("installed: ${installed_count}")
      info_parts+=("found: ${iso_count} ISOs")
      local info_str
      info_str="$(IFS=", "; echo "${info_parts[*]}")"

      local where
      if [[ "$base" == "$mnt/YUMI" ]]; then where="base: YUMI"; else where="base: root"; fi
      printf "  %2d) %s — %s (%s)\n" "$i" "$label" "$info_str" "$where"
      i=$((i+1))
    done
    local hint_root
    hint_root=${MOUNT_ROOTS[0]:-/Volumes}
    echo "   M) Manual path (e.g., ${hint_root}/MyUSB)"
    echo "   Q) Quit"
    read -r -p "Enter choice: " ans

    case "$ans" in
      [Qq]) echo "Aborted."; exit 0 ;;
      [Mm])
        local hint_root
        hint_root=${MOUNT_ROOTS[0]:-/Volumes}
        read -r -p "Enter mounted volume path (e.g., ${hint_root}/MyUSB): " manual
        manual=${manual%/}
        if [[ ! -d "$manual" ]]; then
          echo "Volume path not found: $manual"; continue
        fi
        BASE="$(compute_base_for_mnt "$manual")"
        if [[ -d "$BASE" ]]; then
          echo "Using BASE: $BASE"; return 0
        else
          echo "Folder not found: $BASE"
          echo "Tip: ensure the selected path or its YUMI subfolder contains content."
          continue
        fi
        ;;
      *)
        if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans>=1 && ans<=${#candidates[@]:-0} )); then
          local sel=${candidates[$((ans-1))]}
          local root=${sel%%:*}
          local path=${sel#*:}
          local mnt_sel="$root/$path"
          BASE="$(compute_base_for_mnt "$mnt_sel")"
          if [[ -d "$BASE" ]]; then
            echo "Using BASE: $BASE"; return 0
          else
            echo "Folder not found: $BASE"; echo "Tip: ensure the selected volume or its YUMI folder contains content."
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
  # Returns 0 if a git-based unified diff was shown, 1 otherwise (caller may fallback)
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

  # Capability probe: does this git support --label with --no-index?
  local support_label=0
  if "$gitbin" --no-pager diff --no-index --unified=0 \
       --label x --label y /dev/null /dev/null >/dev/null 2>&1; then
    support_label=1
  fi

  local color_arg
  if (( COLORIZE )); then color_arg="--color=always"; else color_arg="--color=never"; fi

  # Build argv respecting capability
  local rc=0
  if (( support_label )); then
    "$gitbin" --no-pager diff --no-index --unified=3 \
      --label "Installed.txt (current)" --label "Installed.txt (proposed)" \
      $color_arg "$tmp1" "$tmp2" || rc=$?
  else
    "$gitbin" --no-pager diff --no-index --unified=3 \
      $color_arg "$tmp1" "$tmp2" || rc=$?
  fi

  rm -f "$tmp1" "$tmp2"
  # git diff exits 1 when there are differences; treat 0/1 as success for display
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
  # Create the file only if it does not exist; do NOT truncate prior to diff
  if [[ ! -f "$LIST" ]]; then
    : > "$LIST"
  fi
  # Keep existing content intact for dry-run; only normalize line endings
  # Strip CR characters if any (in case file was edited on Windows)
  if sed --version >/dev/null 2>&1; then
    # GNU sed available
    sed -i -e $'s/\r$//' "$LIST" || true
  else
    # BSD/macOS sed requires an explicit (possibly empty) backup suffix
    sed -i '' -e $'s/\r$//' "$LIST" || true
  fi
}

#
# ---------------- Debugging ----------------
debug_scan() {
  echo
  echo "----- Debug: Scan Details -----"
  echo "BASE: $BASE"
  echo "LIST: $LIST"
  echo "Mount roots: ${MOUNT_ROOTS[*]}"
  echo
  echo "Found ISO files under BASE (search root shown below; excludes *.iso.zip):"
  echo "Search root: $BASE"
  # List up to 50 entries; indicate if more exist
  local count=0
  while IFS= read -r -d '' f; do
    printf '  - %s\n' "${f#"$BASE/"}"
    count=$((count+1))
    if (( count==50 )); then echo "  ... (more files not shown)"; break; fi
  done < <(find "$BASE" -type f \( -iname "*.iso" -a ! -iname "*.iso.zip" \) -print0)
  if (( count==0 )); then echo "  (none)"; fi
  echo
  echo "Current Installed.txt line count: $(wc -l < "$LIST" 2>/dev/null || echo 0)"
  echo "Proposed list line count: $(printf "%s" "$PROPOSED" | awk 'length>0{c++} END{print c+0}')"
  echo "-------------------------------"
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

  local grp
  for grp in "${groups[@]}"; do
    local search_root
    if [[ "$grp" == "ROOT" ]]; then
      search_root="$BASE"
    else
      search_root="$BASE/$grp"
      [[ -d "$search_root" ]] || continue
    fi

    # Collect raw lines for this group
    local raw_lines=""
    while IFS= read -r -d '' f; do
      local rel="${f#$BASE/}"
      rel="${rel//\//\\}"
      raw_lines+="$rel"$'\n'
    done < <(find "$search_root" -type f \( -iname "*.iso" -a ! -iname "*.iso.zip" \) -print0)

    # Skip empty groups
    if [[ -z "$(printf "%s" "$raw_lines" | tr -d '\n\r\t \f')" ]]; then
      continue
    fi

    # Sort and dedupe lines within the group
    raw_lines="$(printf "%s" "$raw_lines" | LC_ALL=C sort -u)"

    # Append to PROPOSED with a blank line between groups
    if [[ -n "$PROPOSED" ]]; then
      PROPOSED+=$'\n'
    fi
    PROPOSED+="$raw_lines"
  done

  # Normalize blank lines between groups (no multiple blank runs)
  if [[ -n "$PROPOSED" ]]; then
    PROPOSED="$(printf "%s\n" "$PROPOSED" | awk 'NF{print; blank=0; next} {if(!blank){print ""} blank=1}')"
  fi

  # If PROPOSED is only whitespace/newlines, collapse to empty
  if [[ -z "$(printf "%s" "$PROPOSED" | tr -d "\n\r\t \f")" ]]; then
    PROPOSED=""
  fi
}

# ---------------- Removals preview/prune helpers ----------------
# Lines pending removal are those present in Installed.txt but NOT in the proposed list.
# We annotate any line that does not end with .iso (case-insensitive) as [non-iso].
compute_pending_removals() {
  awk -v prop="$PROPOSED" '
    BEGIN {
      # Build set of proposed lines (non-empty)
      n = split(prop, p, /\r?\n/);
      for (i=1; i<=n; i++) { if (length(p[i])) seen[p[i]] = 1 }
    }
    length($0) {
      if (!($0 in seen)) {
        flag = "";
        s = $0;
        # mark non-iso lines for clarity (case-insensitive)
        if (s !~ /\.[Ii][Ss][Oo]$/) flag = " [non-iso]";
        print $0 flag
      }
    }
  ' "$LIST"
}

preview_removals() {
  echo
  echo "----- Pending removals (present in Installed.txt but not on disk) -----"
  local pending count
  pending="$(compute_pending_removals)"
  count=$(printf "%s" "$pending" | awk 'NF{c++} END{print c+0}')
  if [[ "$count" == "0" ]]; then
    echo "(none)"
    return 0
  fi
  echo "Total lines to be removed: $count"
  echo "Showing up to first 200 entries:"
  printf "%s\n" "$pending" | head -n 200
  if (( count > 200 )); then echo "... (more not shown)"; fi
}

show_diff() {
  local current proposed
  current="$(cat "$LIST")"
  proposed="$PROPOSED"

  print_legend
  echo
  echo "Proposed changes to Installed.txt:"

  # First preference: git-based unified diff via helper
  if get_git_path >/dev/null 2>&1; then
    if show_git_unified_diff "$current" "$proposed"; then
      # show_git_unified_diff already printed the diff (with color if enabled)
      return
    fi
  fi

  # Fallback: system diff
  if command -v diff >/dev/null 2>&1; then
    if diff --version >/dev/null 2>&1; then
      # GNU diffutils supports -L labels
      diff -u -L "Installed.txt (current)" -L "Installed.txt (proposed)" \
        <(printf "%s\n" "$current") <(printf "%s\n" "$proposed") \
        | colorize_diff || true
    else
      # BSD/macOS diff: no -L option
      diff -u \
        <(printf "%s\n" "$current") <(printf "%s\n" "$proposed") \
        | colorize_diff || true
    fi

    # If the diff command reported "no differences" (exit status 0), make that explicit
    if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
      echo "(no differences)"
    fi
  else
    echo "(diff not found; showing proposed file instead)"
    printf "%s\n" "$proposed"
  fi
}

write_changes() {
  # Check writability of BASE and Installed.txt
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

  echo
  echo "About to write proposed content to:"
  echo "  Installed.txt path: $LIST"
  echo "  BASE directory:     $BASE"

  # Always make a timestamped backup if Installed.txt exists
  if [[ -e "$LIST" ]]; then
    local backup="$LIST.bak.$(date +%Y%m%d-%H%M%S)"
    cp -f "$LIST" "$backup" || {
      echo "Warning: failed to create backup at: $backup"
    }
  fi

  # Write proposed content; ensure trailing newline (even if PROPOSED is empty)
  if [[ -n "$PROPOSED" ]]; then
    printf "%s\n" "$PROPOSED" > "$LIST"
  else
    : > "$LIST"
  fi

  sync || true

  echo "Write step completed."
  echo "  Installed.txt path: $LIST"
  echo "  You can re-run the script to verify that the diff is now empty."
}

menu_loop() {
  while true; do
    echo
    echo "Select an option:"
    echo "  [W] Write these changes to Installed.txt"
    echo "  [V] View full proposed file"
    echo "  [R] Rescan disk and re-run dry run"
    echo "  [P] Preview pending removals"
    echo "  [D] Debug scan details"
    echo "  [Q] Quit without writing"
    read -r -p "Your choice (W/V/R/P/Q): " choice
    case "$choice" in
      [Ww]) write_changes; break ;;
      [Vv]) echo "----- Proposed Installed.txt -----"; printf "%s\n" "$PROPOSED"; echo "----------------------------------" ;;
      [Rr]) build_proposed; show_diff ;;
      [Pp]) preview_removals ; ;;
      [Dd]) debug_scan ; ;;
      [Qq]) echo "Aborted. No changes written."; break ;;
      *) echo "Unrecognized choice." ;;
    esac
  done
}

main() {
  choose_volume
  normalize_list
  build_proposed

  ask_color_choice
  show_diff
  menu_loop
}

main "$@"