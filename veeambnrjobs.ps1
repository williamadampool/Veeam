$cmds = 'Get-VBRJob','Get-VBRComputerBackupJob','Get-VBRBackupCopyJob','Get-VBRUnstructuredBackupJob',
        'Get-VBRTapeJob','Get-VBRSureBackupJob','Get-VBRPluginJob','Get-VBRCDPPolicy'

$all = foreach ($c in $cmds) {
    if (Get-Command $c -ErrorAction SilentlyContinue) {
        & $c -WarningAction SilentlyContinue | Select-Object Name, @{n='Type';e={$_.GetType().Name}}, @{n='Source';e={$c}}
    }
}
$all | Sort-Object Name -Unique | Sort-Object Source, Name | Format-Table -AutoSize