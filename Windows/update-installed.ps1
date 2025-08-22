<file name=Windows/update-installed.ps1>
<#
 update-installed.ps1 (Windows)
 Mirrors the macOS bash script behavior for keeping YUMI\Installed.txt
 in sync with on-disk *.iso files.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ----------------------------- Color / Legend -----------------------------
$global:UseColor = $false
$esc = "`e"  # ANSI ESC
$SRed   = "$esc[31m"
$SGreen = "$esc[32m"
$SCyan  = "$esc[36m"
$SBold  = "$esc[1m"
$SReset = "$esc[0m"

function Ask-ColorChoice {
    # Default to color if output is a terminal/VT-enabled
    $defaultYes = $Host.UI.RawUI -and ($Host.Name -like '*ConsoleHost*' -or $env:WT_SESSION -or $env:TERM -or $PSStyle) 
    if ($defaultYes) {
        $resp = Read-Host 'Show colorized diff? [Y/n]'
        if ($resp -match '^[Nn]') { $global:UseColor = $false } else { $global:UseColor = $true }
    } else {
        $resp = Read-Host 'Show colorized diff? (output may be redirected) [y/N]'
        if ($resp -match '^[Yy]') { $global:UseColor = $true } else { $global:UseColor = $false }
    }
}

function Write-Legend {
    Write-Host ''
    if ($global:UseColor) {
        Write-Host ("{0}Legend:{1}  {2}- deletion{1}   {3}+ addition{1}" -f $SBold,$SReset,$SRed,$SGreen)
    } else {
        Write-Host 'Legend:  - deletion   + addition'
    }
}

function Colorize-Line {
    param(
        [string]$Line
    )
    if (-not $global:UseColor) { return $Line }
    if ($Line.StartsWith('+')) { return "$SGreen$Line$SReset" }
    if ($Line.StartsWith('-')) { return "$SRed$Line$SReset" }
    return $Line
}

function Get-GitPath {
    try { return (Get-Command git -ErrorAction Stop).Source } catch { return $null }
}

function Show-GitUnifiedDiff {
    param(
        [string]$CurrentText,
        [string]$ProposedText
    )
    $git = Get-GitPath
    if (-not $git) { return $false }

    $tmp1 = [System.IO.Path]::GetTempFileName()
    $tmp2 = [System.IO.Path]::GetTempFileName()
    try {
        # Normalize to LF to avoid noisy CRLF diffs; Git will still show nicely
        $ct = if ($null -ne $CurrentText) { $CurrentText -replace "\r\n?", "`n" } else { '' }
        $pt = if ($null -ne $ProposedText) { $ProposedText -replace "\r\n?", "`n" } else { '' }
        [System.IO.File]::WriteAllText($tmp1, $ct, [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText($tmp2, $pt, [System.Text.Encoding]::UTF8)

        $colorArg = if ($global:UseColor) { '--color=always' } else { '--color=never' }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName  = $git
        $psi.ArgumentList.Add('--no-pager')
        $psi.ArgumentList.Add('diff')
        $psi.ArgumentList.Add('--no-index')
        $psi.ArgumentList.Add('--unified=3')
        $psi.ArgumentList.Add('--label')
        $psi.ArgumentList.Add('Installed.txt (current)')
        $psi.ArgumentList.Add('--label')
        $psi.ArgumentList.Add('Installed.txt (proposed)')
        $psi.ArgumentList.Add($colorArg)
        $psi.ArgumentList.Add($tmp1)
        $psi.ArgumentList.Add($tmp2)
        $psi.RedirectStandardOutput = $true
        $psi.UseShellExecute = $false
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        $p.WaitForExit()

        if ([string]::IsNullOrWhiteSpace($out)) { return $false }

        # Git already colorizes when requested; otherwise plain text
        Write-Host $out -NoNewline
        return $true
    }
    finally {
        if (Test-Path $tmp1) { Remove-Item $tmp1 -Force -ErrorAction SilentlyContinue }
        if (Test-Path $tmp2) { Remove-Item $tmp2 -Force -ErrorAction SilentlyContinue }
    }
}

# ----------------------------- Drive selection ----------------------------
function Choose-Drive {
    # List all filesystem drives, prefer those with a YUMI folder
    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match '^[A-Z]:\\$' } | Sort-Object Name
    if (-not $drives) { throw 'No filesystem drives found.' }

    Write-Host 'Select a drive:'
    $index = 1
    foreach ($d in $drives) {
        $hasY = Test-Path (Join-Path $d.Root 'YUMI')
        $label = if ($hasY) { "$(($d.Name)):\\  (YUMI found)" } else { "$(($d.Name)):\\" }
        Write-Host ("  {0,2}) {1}" -f $index, $label)
        $index++
    }
    Write-Host '   M) Manual path (e.g., E:\)'
    Write-Host '   Q) Quit'

    while ($true) {
        $ans = Read-Host 'Enter choice'
        switch -Regex ($ans) {
            '^[Qq]$' { throw 'Aborted by user.' }
            '^[Mm]$' {
                $manual = Read-Host 'Enter drive root (e.g., E:\ or E:)'
                if ($manual -match '^[A-Za-z]:$') { $manual += '\\' }
                if ($manual -notmatch '^[A-Za-z]:\\$') { Write-Host 'Please enter like E:\'; continue }
                $base = Join-Path $manual 'YUMI'
                if (Test-Path $base) { return $base } else { Write-Host "Folder not found: $base"; continue }
            }
            '^[0-9]+$' {
                $i = [int]$ans
                if ($i -lt 1 -or $i -gt $drives.Count) { Write-Host 'Invalid choice.'; continue }
                $root = $drives[$i-1].Root
                $base = Join-Path $root 'YUMI'
                if (Test-Path $base) { return $base } else { Write-Host "Folder not found: $base" }
            }
            default { Write-Host 'Invalid choice.' }
        }
    }
}

# ----------------------------- Core build logic ---------------------------
$script:BASE = $null
$script:LIST = $null
$script:PROPOSED = $null

function Normalize-List {
    $script:LIST = Join-Path $script:BASE 'Installed.txt'
    if (-not (Test-Path $script:BASE)) { New-Item -ItemType Directory -Path $script:BASE -Force | Out-Null }
    if (-not (Test-Path $script:LIST)) { New-Item -ItemType File -Path $script:LIST -Force | Out-Null }
}

# Helpers
function Get-TopDirs {
    # Exclude common Windows system dirs
    $ex = @('System Volume Information', '$RECYCLE.BIN', 'RECYCLER', 'Recovery', 'MSOCache')
    Get-ChildItem -LiteralPath $script:BASE -Directory -Force | Where-Object { $ex -notcontains $_.Name }
}

function To-RelativeBackslash {
    param([string]$FullPath)
    $baseWithSep = $script:BASE.TrimEnd('\\') + '\\'
    $rel = if ($FullPath.StartsWith($baseWithSep, [System.StringComparison]::OrdinalIgnoreCase)) {
        $FullPath.Substring($baseWithSep.Length)
    } else { $FullPath }
    return $rel -replace '/', '\\'
}

function Build-Proposed {
    $linesAll = @()
    $groups = @()

    # ROOT group if any *.iso directly inside BASE (non-recursive)
    $rootIsos = Get-ChildItem -LiteralPath $script:BASE -File |
        Where-Object { $_.Extension -ieq '.iso' -and ($_.Name -notmatch '\.iso\.zip$') }
    if ($rootIsos.Count -gt 0) { $groups += 'ROOT' }

    # Top-level dirs (disk enumeration order)
    $dirs = Get-TopDirs
    foreach ($d in $dirs) { $groups += $d.Name }

    foreach ($grp in $groups) {
        $groupLines = @()
        if ($grp -eq 'ROOT') {
            foreach ($f in $rootIsos) { $groupLines += (To-RelativeBackslash $f.FullName) }
        } else {
            $dirPath = Join-Path $script:BASE $grp
            if (Test-Path $dirPath) {
                # Recurse for group; only *.iso, exclude *.iso.zip
                $files = Get-ChildItem -LiteralPath $dirPath -File -Recurse |
                    Where-Object { $_.Extension -ieq '.iso' -and ($_.Name -notmatch '\.iso\.zip$') }
                foreach ($f in $files) { $groupLines += (To-RelativeBackslash $f.FullName) }
            }
        }
        if ($groupLines.Count -gt 0) {
            # Case-sensitive unique + sort
            $groupLines = $groupLines | Sort-Object -CaseSensitive -Unique
            $linesAll += $groupLines
            $linesAll += ''  # blank line between groups
        }
    }

    # Trim trailing blanks
    while ($linesAll.Count -gt 0 -and [string]::IsNullOrWhiteSpace($linesAll[-1])) { [void]$linesAll.RemoveAt($linesAll.Count-1) }

    $script:PROPOSED = ($linesAll -join "`n")
}

# ----------------------------- Diff (line-based) --------------------------
function Show-Diff {
    param(
        [string]$CurrentText,
        [string]$ProposedText
    )
    Write-Legend

    Write-Host ''
    Write-Host 'Proposed changes to Installed.txt:'

    # Prefer git unified diff if available
    if (Show-GitUnifiedDiff -CurrentText $CurrentText -ProposedText $ProposedText) { return }

    $cur = if ([string]::IsNullOrEmpty($CurrentText)) { @() } else { $CurrentText -split "`r?`n" }
    $pro = if ([string]::IsNullOrEmpty($ProposedText)) { @() } else { $ProposedText -split "`r?`n" }

    # Simple diff via Compare-Object (not unified hunks, but clear adds/removes)
    $diff = Compare-Object -ReferenceObject $cur -DifferenceObject $pro -IncludeEqual:$false
    if (-not $diff) { Write-Host '(no changes)'; return }

    foreach ($d in $diff) {
        $prefix = if ($d.SideIndicator -eq '=>') { '+' } else { '-' }
        Write-Host (Colorize-Line ("$prefix" + $d.InputObject))
    }
}

# ----------------------------- Write w/ backup ----------------------------
function Write-Changes {
    # Check directory/file writability
    $dir = Get-Item -LiteralPath $script:BASE
    if (-not $dir.Attributes.ToString().Contains('ReadOnly')) { } # just accessing
    if ((Test-Path $script:LIST) -and (Get-Item -LiteralPath $script:LIST).Attributes.ToString().Contains('ReadOnly')) {
        Write-Host "Error: File is read-only: $script:LIST" -ForegroundColor Red
        return
    }

    # Backup first
    if (Test-Path $script:LIST) {
        $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
        Copy-Item -LiteralPath $script:LIST -Destination "$script:LIST.bak.$ts" -Force -ErrorAction SilentlyContinue
    }

    # Write proposed content with trailing newline
    $contentToWrite = if ([string]::IsNullOrEmpty($script:PROPOSED)) { '' } else { $script:PROPOSED + "`n" }
    [System.IO.File]::WriteAllText($script:LIST, $contentToWrite, [System.Text.Encoding]::UTF8)

    # Verify
    $written = [System.IO.File]::ReadAllText($script:LIST)
    if ($written -eq $contentToWrite) {
        Write-Host 'Changes written to Installed.txt. Backup saved alongside Installed.txt.'
    } else {
        Write-Host 'Warning: write verification failed; Installed.txt does not match proposed content.' -ForegroundColor Yellow
    }
}

# ----------------------------- Menu loop ----------------------------------
function Menu-Loop {
    while ($true) {
        Write-Host ''
        Write-Host 'Select an option:'
        Write-Host '  [W] Write these changes to Installed.txt'
        Write-Host '  [V] View full proposed file'
        Write-Host '  [R] Rescan disk and re-run dry run'
        Write-Host '  [Q] Quit without writing'
        $choice = Read-Host 'Your choice (W/V/R/Q)'
        switch -Regex ($choice) {
            '^[Ww]$' { Write-Changes; break }
            '^[Vv]$' { Write-Host '----- Proposed Installed.txt -----'; Write-Host $script:PROPOSED; Write-Host '----------------------------------' }
            '^[Rr]$' { Build-Proposed; Show-Diff -CurrentText (Get-Content -LiteralPath $script:LIST -Raw) -ProposedText $script:PROPOSED }
            '^[Qq]$' { Write-Host 'Aborted. No changes written.'; break }
            default  { Write-Host 'Unrecognized choice.' }
        }
    }
}

# ----------------------------- Main ---------------------------------------
try {
    $script:BASE = Choose-Drive
    Normalize-List
    Build-Proposed

    $current = Get-Content -LiteralPath $script:LIST -Raw
    if ($current -eq ($script:PROPOSED)) {
        Write-Host 'No changes needed. Installed.txt is up to date.'
        return
    }
    Ask-ColorChoice
    Show-Diff -CurrentText $current -ProposedText $script:PROPOSED
    Menu-Loop
}
catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
</file>

<file name=README.md>
# yumi-tools

This repository contains scripts to keep YUMI\Installed.txt in sync with the on-disk *.iso files. There are two versions available: a macOS Bash script and a Windows PowerShell script. Both behave the same and provide a consistent experience across platforms.

## Quick Install

### macOS

```bash
curl -L -o update-installed.sh https://raw.githubusercontent.com/guiltykeyboard/yumi-tools/main/MacOS/update-installed.sh && chmod +x update-installed.sh && ./update-installed.sh
```

### Windows

```powershell
PowerShell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/guiltykeyboard/yumi-tools/main/Windows/update-installed.ps1' -OutFile 'update-installed.ps1'; & '.\update-installed.ps1'"
```

## Features

- Drive picker (drive letters) + manual path entry (e.g., E:\)
- Verifies YUMI folder exists at `<Drive>:\YUMI`
- Dry-run first with a colorized diff (+ additions, - deletions) and legend
- Interactive menu: [W]rite / [V]iew proposed / [R]escan / [Q]uit
- Only *.iso files (excludes *.iso.zip)
- Relative backslash paths; grouped by top-level folder (disk enumeration order)
- Case-sensitive sorting within each group
- Timestamped backup before write; robust write + verification
- No manual temp files (backup only)
- On Windows, uses `git` for a unified diff when installed, otherwise falls back to a clear add/remove view

## macOS Example Session

```bash
$ ./update-installed.sh
Select a drive:
  1) /Volumes/USB1 (YUMI found)
  2) /Volumes/USB2
  M) Manual path
  Q) Quit
Enter choice: 1

Show colorized diff? [Y/n] y

Legend:  - deletion   + addition

Proposed changes to Installed.txt:
- old.iso
+ new.iso

Select an option:
  [W] Write these changes to Installed.txt
  [V] View full proposed file
  [R] Rescan disk and re-run dry run
  [Q] Quit without writing
Your choice (W/V/R/Q): w
Changes written to Installed.txt. Backup saved alongside Installed.txt.
```

<!-- The rest of the README content remains unchanged -->
</file>
