Get-VBRBackupSession | Where-Object CreationTime -gt (Get-Date).AddDays(-14) |
    Group-Object JobName | ForEach-Object {
        $s = $_.Group | Sort-Object CreationTime -Descending | Select-Object -First 1
        [pscustomobject]@{
            Job      = $s.JobName
            Type     = $s.JobType
            Result   = $s.Result
            State    = $s.State
            Started  = $s.CreationTime
            Ended    = if ($s.EndTime -gt $s.CreationTime) { $s.EndTime } else { $null }
        }
    } | Sort-Object Result, Job | Format-Table -AutoSize