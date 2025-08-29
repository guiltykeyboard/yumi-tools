# yumi-tools

Tools to keep a YUMI flash drive's `Installed.txt` in sync with the ISO files on disk, across **macOS (Bash)**, **Linux (Bash)**, and **Windows (PowerShell)**.

> **Important:** The USB drive must be prepared by **YUMI exFAT** *before* running any script.
>
> 1. Download YUMI exFAT: https://pendrivelinux.com/yumi-multiboot-usb-creator/
> 2. Use YUMI to format/prepare the drive, then create your desired subfolder structure under `YUMI` and copy your `.iso` files.
> 3. Run one of the scripts below to update `Installed.txt`.

---

## What these scripts do
- Scan `<Drive>/YUMI` for **`.iso` files** (explicitly excludes `*.iso.zip`).
- Build a list of **relative, backslash-style paths** (e.g. `Linux-ISOs\\ubuntu.iso`).
- **Group** entries by **top-level folder** in **on‑disk order**; the top of `YUMI` (ROOT) is listed first if it contains ISOs.
- **Case‑sensitive sort** within each group; groups separated by a blank line.
- Show a **dry‑run diff** (color optional) and an interactive menu:
  - **W**rite changes
  - **V**iew full proposed file
  - **R**escan & re‑diff
  - **Q**uit without writing
- Create a **timestamped backup** of `Installed.txt` before writing and **verify** the write.

### Exclusions / rules
- Only `*.iso` files (no `*.iso.zip`).
- Skip common system directories where applicable (macOS: `.Trashes`, `.Spotlight-V100`, `.fseventsd`, etc.; Windows: `$RECYCLE.BIN`, `System Volume Information`).
- **ROOT** (the top of `YUMI`) is scanned **non‑recursively**; all other top‑level folders are scanned **recursively**.

### Unified diff support
- **Windows:** Uses `git diff --no-index` when Git for Windows is installed; otherwise shows a clear add/remove view.
- **macOS & Linux:** Prefer `git diff --no-index` when available; otherwise fall back to the system `diff -u`.

---

## Quick install & run

### macOS (Bash)
```bash
curl -L -o update-installed-mac.sh \
  https://raw.githubusercontent.com/guiltykeyboard/yumi-tools/main/MacOS/update-installed-mac.sh \
  && chmod +x update-installed-mac.sh && ./update-installed-mac.sh
```

### Linux (Bash)
```bash
curl -L -o update-installed-linux.sh \
  https://raw.githubusercontent.com/guiltykeyboard/yumi-tools/main/Linux/update-installed-linux.sh \
  && chmod +x update-installed-linux.sh && ./update-installed-linux.sh
```

### Windows (PowerShell)
```powershell
PowerShell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/guiltykeyboard/yumi-tools/main/Windows/update-installed-windows.ps1' -OutFile 'update-installed-windows.ps1'; & '.\update-installed-windows.ps1'"
```

> Tip: To update later, just re-run the script. It always starts with a dry run.

---

## Usage overview
1. **Pick the drive**: The script lists mounted volumes (macOS `/Volumes`, Linux `/media` & `/run/media/$USER`, Windows drive letters) or lets you **enter a manual path**. It then verifies `<Drive>/YUMI` exists.
2. **Color prompt**: Choose whether to colorize the diff (useful for interactive terminals; can be disabled for logs/pipes).
3. **Review the diff**: See what would be added/removed in `Installed.txt`.
4. **Choose an action**: `W`, `V`, `R`, or `Q` from the menu.

---

## Requirements
- **macOS / Linux**: Bash, `find`, `awk`, `sed`, `diff` (GNU utilities on Linux; BSD on macOS). Optional: **Git** for unified diff.
- **Windows**: PowerShell 5.1 or 7+, optional **Git for Windows** for unified diff.

---

## Troubleshooting
- **`YUMI` not found**: Ensure the drive has a top-level `YUMI` folder created by YUMI exFAT.
- **No diff shown**: On macOS/Linux without Git, system `diff -u` is used. If `diff` is missing on Linux: `sudo apt install diffutils` or `sudo yum install diffutils`.
- **Write fails / read‑only**: Check drive permissions/flags (macOS `ls -lO`, `chflags nouchg`; Windows file attributes). Ensure the drive isn’t mounted read‑only.
- **Paths look wrong**: The file intentionally uses **backslashes** and **relative paths** (expected by YUMI environments).

---

## Contributing
Issues and PRs welcome. Please keep script behavior consistent across platforms. Follow PowerShell’s approved verb naming (`Verb-Noun`) and shell portability guidelines for Bash.

---

## Mailmap
To unify contributor identities:

```text
guiltykeyboard <15965363+guiltykeyboard@users.noreply.github.com> guiltykeyboard <123456+guiltykeyboard@users.noreply.github.com>
```

---

## License
MIT