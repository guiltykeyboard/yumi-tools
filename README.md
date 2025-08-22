# yumi-tools
Tools for YUMI

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

---

## ⚡ Quick Install

Run this in your terminal to download the script and make it executable:

```bash
curl -L -o update-installed.sh https://raw.githubusercontent.com/guiltykeyboard/yumi-tools/main/MacOS/update-installed.sh
chmod +x update-installed.sh
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

- macOS operating system
- Bash shell (default on macOS)
- Standard Unix tools: `find`, `diff`, `sed`, `awk`, and `tput` for colors

---

## Troubleshooting

### Color codes appearing in logs

If you see raw ANSI color escape sequences in your output instead of colored text, your terminal may not support ANSI colors or the `tput` command is not working. You can disable colorized diff output by choosing “N” when prompted to enable colors.

### YUMI folder not found

Ensure the selected volume or path contains a `YUMI` folder at its root. The script depends on this folder to locate `.iso` files. If not found, you can create it with:

```bash
mkdir -p /Volumes/MyUSB/YUMI
```

Replace `/Volumes/MyUSB` with your actual volume path.

### Missing diff or no output

macOS includes the `diff` utility by default. If you encounter errors indicating `diff` is missing, you can install GNU diffutils via Homebrew:

```bash
brew install diffutils
```

### `sed` issues on macOS

macOS uses BSD `sed`, which requires an argument for the `-i` (in-place) option, typically an empty string `''`. GNU `sed` (common on Linux) uses `sed -i` without an argument. If you modify the script for Linux, replace `sed -i ''` with `sed -i` to avoid errors.

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
