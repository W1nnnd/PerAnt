# SPDX-License-Identifier: GPL-3.0-only
# Install the matching device test APK on a dedicated AVD before running.
param(
    [Parameter(Mandatory)][ValidatePattern('^emulator-[0-9]+$')][string]$Target,
    [Parameter(Mandatory)][ValidateSet('Meeting','Memory')][string]$Probe,
    [string]$AdbExe = 'adb',
    [int]$AdbPort = 5037,
    [string]$LogPath = (Join-Path ([IO.Path]::GetTempPath()) ('perant-model-' + [guid]::NewGuid() + '.log'))
)
$ErrorActionPreference = 'Stop'
$package = 'dev.perant.perant'
function Invoke-TestAdb {
    & $AdbExe -P $AdbPort -s $Target @args
    if ($LASTEXITCODE) { throw "ADB operation failed on $Target" }
}
function Start-TestApp {
    Invoke-TestAdb shell am start -W -n dev.perant.perant/.MainActivity | Out-Null
}
if ((Invoke-TestAdb get-state) -ne 'device') { throw 'Dedicated emulator unavailable' }
$ready = if ($Probe -eq 'Meeting') { 'PERANT_MEETING_KILL saved=2' } else { 'PERANT_PRESSURE_READY completed=1' }
$done = if ($Probe -eq 'Meeting') { 'PERANT_MEETING_RESTORED reused=2' } else { 'PERANT_PRESSURE_RELEASED steps=[1-9][0-9]* reloaded=true' }
Start-TestApp
$injected = $false
$deadline = [datetime]::UtcNow.AddMinutes(6)
while ([datetime]::UtcNow -lt $deadline) {
    Start-Sleep -Milliseconds 400
    $processNumber = ((& $AdbExe -P $AdbPort -s $Target shell pidof $package) -join '').Trim()
    if (!$processNumber) { continue }
    $lines = @(Invoke-TestAdb logcat -d "--pid=$processNumber" -s flutter:I)
    if ($lines -match 'Some tests failed|\[E\]|EXCEPTION CAUGHT') { break }
    if (!$injected -and $lines -match $ready) {
        $lines | Add-Content -Encoding utf8 -LiteralPath $LogPath
        $lines -match $ready
        if ($Probe -eq 'Meeting') {
            Invoke-TestAdb shell am force-stop $package | Out-Null
            Start-TestApp
        } else {
            Invoke-TestAdb shell am send-trim-memory $package RUNNING_CRITICAL
        }
        $injected = $true
        continue
    }
    if ($injected -and $lines -match $done -and $lines -match 'All tests passed!') {
        $lines | Add-Content -Encoding utf8 -LiteralPath $LogPath
        $lines -match $done
        Write-Output "Passed. Device log saved to $LogPath"
        exit 0
    }
}
$lines | Add-Content -Encoding utf8 -LiteralPath $LogPath
throw "Device test did not complete. See $LogPath"
