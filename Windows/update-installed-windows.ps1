#requires -Version 5.1
<#!
  update-installed-windows.ps1
  Keeps <Drive>:\YUMI\Installed.txt in sync with on-disk *.iso files.
  - Drive picker (letter list) + manual path
  - Dry-run first with diff + color toggle + legend
  - Optional unified diff via Git for Windows (if available), else clear add/remove view
  - Interactive menu: [W]rite / [V]iew / [R]escan / [Q]uit
  - Only *.iso (excludes *.iso.zip)
  - Relative backslash paths; grouped by top-level folder (disk enumeration order)
  - Case-sensitive sorting within each group
  - Timestamped backup and write verification
!#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ----------------------------- Color / Legend -----------------------------
$global:UseColor = $false
function Test-ColorDefault {
    try {
        if ($Host.Name -like '*ConsoleHost*' -or $env:WT_SESSION -or $PSStyle) { return $true }
    } catch {}
    return $false
}

function Read-ColorPreference {
    $defaultYes = Test-ColorDefault
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
        Write-Host ('Legend:  ') -NoNewline
        Write-Host ('- deletion') -ForegroundColor Red -NoNewline
        Write-Host ('   ') -NoNewline
        Write-Host ('+ addition') -ForegroundColor Green
    } else {
        Write-Host 'Legend:  - deletion   + addition'
    }
}

function Write-DiffLine {
    param([string]$Line)
    if (-not $global:UseColor) { Write-Host $Line; return }
    if ($Line.StartsWith('+')) { Write-Host $Line -ForegroundColor Green; return }
    if ($Line.StartsWith('-')) { Write-Host $Line -ForegroundColor Red;   return }
    Write-Host $Line
}

# ----------------------------- Drive selection ----------------------------
function Select-Drive {
    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match '^[A-Z]:\\$' } | Sort-Object Name
    if (-not $drives) { throw 'No filesystem drives found.' }

    Write-Host 'Select a drive:'
    $index = 1
    foreach ($d in $drives) {
        $hasY = Test-Path (Join-Path $d.Root 'YUMI')
        $label = if ($hasY) { "{0} (YUMI found)" -f $d.Root } else { $d.Root }
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

# ----------------------------- Core helpers --------------------------------
$script:BASE = $null
$script:LIST = $null
$script:PROPOSED = $null

function Set-ListFile {
    $script:LIST = Join-Path $script:BASE 'Installed.txt'
    if (-not (Test-Path $script:BASE)) { New-Item -ItemType Directory -Path $script:BASE -Force | Out-Null }
    if (-not (Test-Path $script:LIST)) { New-Item -ItemType File -Path $script:LIST -Force | Out-Null }
}

function Get-TopDirs {
    $exclude = @('System Volume Information', '$RECYCLE.BIN', 'RECYCLER', 'Recovery', 'MSOCache', 'lost+found')
    Get-ChildItem -LiteralPath $script:BASE -Directory -Force | Where-Object { $exclude -notcontains $_.Name }
}

function Convert-PathToRelativeBackslash {
    param([string]$FullPath)
    $baseWithSep = $script:BASE.TrimEnd('\\') + '\\'
    if ($FullPath.StartsWith($baseWithSep, [System.StringComparison]::OrdinalIgnoreCase)) {
        ($FullPath.Substring($baseWithSep.Length)) -replace '/', '\\'
    } else {
        $FullPath -replace '/', '\\'
    }
}

# ----------------------------- Build proposed ------------------------------
function Build-Proposed {
    $linesAll = @()
    $groups = @()

    $rootIsos = Get-ChildItem -LiteralPath $script:BASE -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -ieq '.iso' -and ($_.Name -notmatch '\.iso\.zip$') }
    if ($rootIsos.Count -gt 0) { $groups += 'ROOT' }

    $dirs = Get-TopDirs
    foreach ($d in $dirs) { $groups += $d.Name }

    foreach ($grp in $groups) {
        $groupLines = @()
        if ($grp -eq 'ROOT') {
            foreach ($f in $rootIsos) { $groupLines += (Convert-PathToRelativeBackslash $f.FullName) }
        } else {
            $dirPath = Join-Path $script:BASE $grp
            if (Test-Path $dirPath) {
                $files = Get-ChildItem -LiteralPath $dirPath -File -Recurse -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -ieq '.iso' -and ($_.Name -notmatch '\.iso\.zip$') }
                foreach ($f in $files) { $groupLines += (Convert-PathToRelativeBackslash $f.FullName) }
            }
        }
        if ($groupLines.Count -gt 0) {
            $groupLines = $groupLines | Sort-Object -CaseSensitive -Unique
            $linesAll += $groupLines
            $linesAll += ''
        }
    }

    while ($linesAll.Count -gt 0 -and [string]::IsNullOrWhiteSpace($linesAll[-1])) { [void]$linesAll.RemoveAt($linesAll.Count-1) }
    $script:PROPOSED = ($linesAll -join "`n")
}

# ----------------------------- Diff (git optional) -------------------------
function Get-GitPath { try { (Get-Command git -ErrorAction Stop).Source } catch { $null } }

function Show-GitUnifiedDiff {
    param([string]$CurrentText, [string]$ProposedText)
    $git = Get-GitPath
    if (-not $git) { return $false }

    $tmp1 = [System.IO.Path]::GetTempFileName()
    $tmp2 = [System.IO.Path]::GetTempFileName()
    try {
        $ct = if ($null -ne $CurrentText) { $CurrentText -replace "\r\n?", "`n" } else { '' }
        $pt = if ($null -ne $ProposedText) { $ProposedText -replace "\r\n?", "`n" } else { '' }
        [System.IO.File]::WriteAllText($tmp1, $ct, [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText($tmp2, $pt, [System.Text.Encoding]::UTF8)
        $colorArg = if ($global:UseColor) { '--color=always' } else { '--color=never' }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName  = $git
        $psi.ArgumentList.Add('--no-pager'); $psi.ArgumentList.Add('diff'); $psi.ArgumentList.Add('--no-index'); $psi.ArgumentList.Add('--unified=3')
        $psi.ArgumentList.Add('--label'); $psi.ArgumentList.Add('Installed.txt (current)')
        $psi.ArgumentList.Add('--label'); $psi.ArgumentList.Add('Installed.txt (proposed)')
        $psi.ArgumentList.Add($colorArg)
        $psi.ArgumentList.Add($tmp1); $psi.ArgumentList.Add($tmp2)
        $psi.RedirectStandardOutput = $true; $psi.UseShellExecute = $false
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd(); $p.WaitForExit()
        if (-not [string]::IsNullOrWhiteSpace($out)) { Write-Host $out -NoNewline; return $true }
        return $false
    }
    finally {
        if (Test-Path $tmp1) { Remove-Item $tmp1 -Force -ErrorAction SilentlyContinue }
        if (Test-Path $tmp2) { Remove-Item $tmp2 -Force -ErrorAction SilentlyContinue }
    }
}

function Show-Diff {
    param([string]$CurrentText, [string]$ProposedText)
    Write-Legend
    Write-Host ''
    Write-Host 'Proposed changes to Installed.txt:'
    if (Show-GitUnifiedDiff -CurrentText $CurrentText -ProposedText $ProposedText) { return }

    $cur = if ([string]::IsNullOrEmpty($CurrentText)) { @() } else { $CurrentText -split "`r?`n" }
    $pro = if ([string]::IsNullOrEmpty($ProposedText)) { @() } else { $ProposedText -split "`r?`n" }
    $diff = Compare-Object -ReferenceObject $cur -DifferenceObject $pro -IncludeEqual:$false
    if (-not $diff) { Write-Host '(no changes)'; return }
    foreach ($d in $diff) {
      $prefix = if ($d.SideIndicator -eq '=>') { '+' } else { '-' }
      Write-DiffLine ("$prefix" + $d.InputObject)
    }
}

# ----------------------------- Write with backup ---------------------------
function Write-Changes {
    if (Test-Path $script:LIST) {
        $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
        Copy-Item -LiteralPath $script:LIST -Destination "$script:LIST.bak.$ts" -Force -ErrorAction SilentlyContinue
    }
    $contentToWrite = if ([string]::IsNullOrEmpty($script:PROPOSED)) { '' } else { $script:PROPOSED + "`n" }
    [System.IO.File]::WriteAllText($script:LIST, $contentToWrite, [System.Text.Encoding]::UTF8)

    $written = [System.IO.File]::ReadAllText($script:LIST)
    if ($written -eq $contentToWrite) {
        Write-Host 'Changes written to Installed.txt. Backup saved alongside Installed.txt.'
    } else {
        Write-Host 'Warning: write verification failed; Installed.txt does not match proposed content.' -ForegroundColor Yellow
    }
}

# ----------------------------- Menu loop ----------------------------------
function Invoke-Menu {
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
    $script:BASE = Select-Drive
    Set-ListFile
    Build-Proposed

    $current = Get-Content -LiteralPath $script:LIST -Raw
    if ($current -eq ($script:PROPOSED)) { Write-Host 'No changes needed. Installed.txt is up to date.'; return }

    Read-ColorPreference
    Show-Diff -CurrentText $current -ProposedText $script:PROPOSED
    Invoke-Menu
}
catch {
    Write-Host ("Error: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}