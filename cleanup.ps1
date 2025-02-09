if (Test-Path "launcher_pid.txt") {
    $parentPID = Get-Content -Path "launcher_pid.txt"
    Write-Output "Cleaning up for PID: $parentPID..."

    # Kill child processes
    Get-Process | Where-Object { $_.ParentProcessId -eq $parentPID } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

    # Kill the parent process
    Stop-Process -Id $parentPID -Force

    Remove-Item "launcher_pid.txt"
    Write-Output "Done!"
} else {
    Write-Output "Already cleaned up"
}