param(
    [int]$DaysBack = 45,
    [string]$CsvPath = "$env:USERPROFILE\Downloads\VeeamJobStatus-$(Get-Date -Format 'yyyyMMdd-HHmm').csv"
)

$since   = (Get-Date).AddDays(-$DaysBack)
$results = @{}   # keyed by job name so each job appears once

function Add-Result {
    param($Name, $Type, $Source, $Enabled, $Session)
    if ([string]::IsNullOrWhiteSpace($Name)) { return }
    if ($results.ContainsKey($Name) -and $null -eq $Session) { return }   # don't overwrite real data with blanks

    $result = 'No recent run'; $state = ''; $start = $null; $end = $null
    if ($null -ne $Session) {
        $result = [string]$Session.Result
        $state  = [string]$Session.State
        $start  = $Session.CreationTime
        if ($Session.EndTime -gt $Session.CreationTime) { $end = $Session.EndTime }
    }
    $results[$Name] = [pscustomobject]@{
        Job = $Name; Type = $Type; Source = $Source; Enabled = $Enabled
        Result = $result; State = $state; LastStart = $start; LastEnd = $end
    }
}

# --- 1. Classic jobs ---------------------------------------------------------
Write-Host "Reading standard jobs..." -ForegroundColor Cyan
$jobs = Get-VBRJob -WarningAction SilentlyContinue
foreach ($j in $jobs) {
    $s = $null
    try { $s = $j.FindLastSession() } catch { }
    Add-Result -Name $j.Name -Type ([string]$j.JobType) -Source 'Get-VBRJob' -Enabled $j.IsScheduleEnabled -Session $s
}

# --- 2. Agent jobs -----------------------------------------------------------
if (Get-Command Get-VBRComputerBackupJob -ErrorAction SilentlyContinue) {
    Write-Host "Reading agent jobs..." -ForegroundColor Cyan
    $agentJobs = Get-VBRComputerBackupJob -WarningAction SilentlyContinue
    foreach ($j in $agentJobs) {
        $s = $null
        try {
            $s = Get-VBRComputerBackupJobSession -Name $j.Name -ErrorAction Stop |
                 Sort-Object CreationTime -Descending | Select-Object -First 1
        } catch { }
        Add-Result -Name $j.Name -Type 'Agent' -Source 'Get-VBRComputerBackupJob' -Enabled $j.JobEnabled -Session $s
    }
}

# --- 3. Other job types (listed; last run filled in from sessions below) -----
$otherCmds = 'Get-VBRBackupCopyJob','Get-VBRUnstructuredBackupJob','Get-VBRTapeJob','Get-VBRSureBackupJob'
foreach ($c in $otherCmds) {
    if (Get-Command $c -ErrorAction SilentlyContinue) {
        Write-Host "Reading $c..." -ForegroundColor Cyan
        $list = & $c -WarningAction SilentlyContinue
        foreach ($j in $list) {
            if (-not $results.ContainsKey($j.Name)) {
                Add-Result -Name $j.Name -Type ($c -replace '^Get-VBR','' -replace 'Job$','') -Source $c -Enabled $null -Session $null
            }
        }
    }
}

# --- 4. Session history (fills gaps + finds plug-in jobs) --------------------
Write-Host "Reading backup sessions from the last $DaysBack days..." -ForegroundColor Cyan
$sessions = Get-VBRBackupSession | Where-Object { $_.CreationTime -gt $since }
$grouped  = $sessions | Group-Object JobName
foreach ($g in $grouped) {
    $latest   = $g.Group | Sort-Object CreationTime -Descending | Select-Object -First 1
    $existing = $null
    if ($results.ContainsKey($g.Name)) { $existing = $results[$g.Name] }

    if ($null -eq $existing) {
        Add-Result -Name $g.Name -Type ([string]$latest.JobType) -Source 'Session history' -Enabled $null -Session $latest
    }
    elseif ($existing.Result -eq 'No recent run' -or $null -eq $existing.LastStart -or $latest.CreationTime -gt $existing.LastStart) {
        $enabled = $existing.Enabled
        $type    = $existing.Type
        $source  = $existing.Source
        $results.Remove($g.Name)
        Add-Result -Name $g.Name -Type $type -Source $source -Enabled $enabled -Session $latest
    }
}

# --- 5. Backups with no job/session found ------------------------------------
Write-Host "Checking backups for jobs not seen yet..." -ForegroundColor Cyan
$backups = Get-VBRBackup -WarningAction SilentlyContinue
foreach ($b in $backups) {
    if (-not $results.ContainsKey($b.JobName)) {
        Add-Result -Name $b.JobName -Type ([string]$b.JobType) -Source 'Backup only (no recent session)' -Enabled $null -Session $null
    }
}

# --- Output ------------------------------------------------------------------
$report = $results.Values | Sort-Object Result, Job
$report | Format-Table Job, Type, Enabled, Result, State, LastStart, LastEnd -AutoSize

$counts = $report | Group-Object Result
foreach ($c in $counts) {
    $color = 'Gray'
    if ($c.Name -eq 'Success') { $color = 'Green' }
    elseif ($c.Name -eq 'Warning') { $color = 'Yellow' }
    elseif ($c.Name -eq 'Failed') { $color = 'Red' }
    Write-Host ("{0,-15} {1}" -f $c.Name, $c.Count) -ForegroundColor $color
}

$report | Export-Csv -Path $CsvPath -NoTypeInformation
Write-Host "`nTotal jobs: $($report.Count)  |  CSV: $CsvPath" -ForegroundColor Cyan