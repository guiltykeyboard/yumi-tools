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
# yumi-tools
Tools for YUMI

This repository contains macOS (Bash), Linux (Bash), and Windows (PowerShell) versions of the update-installed script. All scripts behave the same, providing a way to keep an `Installed.txt` index of `.iso` files inside a `YUMI` folder on any mounted drive.

> **Important:** The USB drive must be prepared by **YUMI exFAT** *before* running any script.
>
> ### Prerequisite setup
> 1. **Download YUMI exFAT:** https://pendrivelinux.com/yumi-multiboot-usb-creator/
> 2. **Format/prepare the drive with YUMI exFAT**, then create your desired **subfolder structure** under `YUMI` and copy your **.iso** files to the drive.
> 3. **Run the script** (macOS, Linux, or Windows) to scan the drive and update `Installed.txt` accordingly.

# update-installed.sh

A macOS Bash script to keep a `Installed.txt` index of all `.iso` files inside a `YUMI` folder on any mounted drive.

---

## Features

- **Volume selector:** Choose from a numbered list of mounted drives, enter a manual path, or quit.
- **Dry-run with unified diff:** Preview changes with a unified diff output before applying updates.
- **Colorized diff with legend:** View differences with colors and a clear legend explaining the color codes, with an option to disable colors.
- **Interactive menu:** Use keys (W)rite changes, (V)iew current Installed.txt, (R)efresh diff, (Q)uit without changes.
- **Smart file handling:** Processes only `.iso` files; skips macOS system directories like `.Trashes` and `.Spotlight-V100`; paths use relative backslashes; files are grouped by top-level folder; sorted case-sensitively; and listed in disk order.
- **No manual temp files:** All operations are handled internally without creating temporary files on disk.
- On Windows, the diff uses `git` for a unified diff when installed, otherwise falls back to a clear add/remove view.

---

## ⚡ Quick Install

### macOS

Run this in your terminal to download the script, make it executable, and run it:

```bash
curl -L -o update-installed-mac.sh https://raw.githubusercontent.com/guiltykeyboard/yumi-tools/main/MacOS/update-installed-mac.sh && chmod +x update-installed-mac.sh && ./update-installed-mac.sh
```

### Linux

Run this in your terminal to download the script, make it executable, and run it:

```bash
curl -L -o update-installed-linux.sh https://raw.githubusercontent.com/guiltykeyboard/yumi-tools/main/Linux/update-installed-linux.sh && chmod +x update-installed-linux.sh && ./update-installed-linux.sh
```

### Windows

Run this in PowerShell to download and execute the script:

```powershell
PowerShell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/guiltykeyboard/yumi-tools/main/Windows/update-installed-windows.ps1' -OutFile 'update-installed-windows.ps1'; & '.\update-installed-windows.ps1'"
```

---

## Example Session

When you run `./update-installed.sh`, the script first scans `/Volumes` and prompts you to select a volume from a numbered list or enter a manual path or quit:

```
Scanning /Volumes for mounted drives...
Select a volume:
1) USB_Drive
2) ExternalSSD
3) MacintoshHD
M) Enter manual path
Q) Quit
Enter choice: 1
Using base path: /Volumes/USB_Drive
```

Next, it asks if you want to enable colorized diff output:

```
Enable colorized diff? (Y/N): Y
Diff Legend:
  + Green: Added lines
  - Red: Removed lines
  ~ Yellow: Modified lines
```

Then it displays the proposed changes as a unified diff with colors:

```
--- Installed.txt
+++ New list
@@ -1,5 +1,6 @@
+YUMI\NewISO.iso
 YUMI\Linux\ubuntu.iso
-YUMI\Windows\win10.iso
+YUMI\Windows\win11.iso
```

After viewing the diff, an interactive menu appears:

```
Menu:
(W) Write changes
(V) View current Installed.txt
(R) Refresh diff
(Q) Quit without changes

Enter choice:
```

Pressing `W` writes the new `Installed.txt`, `V` shows the current file, `R` refreshes the diff if files have changed, and `Q` exits without saving. The script ensures only `.iso` files are included, skips system folders, uses relative backslashes for paths, groups files by top-level folder, sorts them case-sensitively in disk order, and performs all operations internally without creating temporary files on disk.

---

## Safety

The script performs a dry-run and shows a colorized diff before making any changes, allowing you to review modifications carefully. It does not overwrite your existing `Installed.txt` until you explicitly choose to write changes. This approach helps prevent accidental data loss. Additionally, no temporary files are written to disk, minimizing risk of clutter or partial updates.

---

## Requirements

- macOS or Linux operating system
- Bash shell (default on macOS and common on Linux)
- Standard Unix tools: `find`, `diff`, `sed`, `awk`, and `tput` for colors

---

## Troubleshooting

### Color codes appearing in logs

If you see raw ANSI color escape sequences in your output instead of colored text, your terminal may not support ANSI colors or the `tput` command is not working. You can disable colorized diff output by choosing “N” when prompted to enable colors.

### YUMI folder not found

Ensure the selected volume or path contains a `YUMI` folder at its root. The script depends on this folder to locate `.iso` files. If not found, you can create it with:

```bash
mkdir -p /media/username/MyUSB/YUMI
```

Replace `/media/username/MyUSB` with your actual volume path.

### Missing diff or no output

Most Linux distributions include the `diff` utility by default. If you encounter errors indicating `diff` is missing, install it via your package manager, e.g.,

```bash
sudo apt install diffutils   # Debian/Ubuntu
sudo yum install diffutils   # RHEL/CentOS
```

### `sed` issues

This script uses `sed -i` without a backup suffix, which works on GNU sed (common on Linux). If you modify the script for BSD/macOS, adjust accordingly.

---

## Screenshots

### Diff Legend

Below is an example of the diff legend shown in the terminal (ANSI-styled code block):

```ansi
[36mDiff Legend:[0m
  [32m+[0m Green: Added lines
  [31m-[0m Red: Removed lines
  [33m~[0m Yellow: Modified lines
```

### Colorized Diff Example

Below is an example of a colorized unified diff output (ANSI-styled code block):

```ansi
--- Installed.txt
+++ New list
@@ -1,5 +1,6 @@
[32m+YUMI\NewISO.iso[0m
 YUMI\Linux\ubuntu.iso
[31m-YUMI\Windows\win10.iso[0m
[32m+YUMI\Windows\win11.iso[0m
```

### Interactive Menu

Below is an example of the interactive menu as shown in the terminal (ANSI-styled code block):

```ansi
[36mMenu:[0m
(W) Write changes
(V) View current Installed.txt
(R) Refresh diff
(Q) Quit without changes

Enter choice:
```

---

## Mailmap

The `.mailmap` file is used to unify contributor identities and prevent duplicate entries when commits are made with different emails. It helps ensure that all commits from the same contributor are attributed consistently.

In this repository, the `.mailmap` file maps an older GitHub noreply address to the current one so all commits appear under the same contributor:

```plaintext
guiltykeyboard <15965363+guiltykeyboard@users.noreply.github.com> guiltykeyboard <123456+guiltykeyboard@users.noreply.github.com>
```
