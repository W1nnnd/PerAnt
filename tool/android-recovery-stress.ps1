# SPDX-License-Identifier: GPL-3.0-only
# Run against a dedicated AVD with storage_pressure_test.dart built using
# --dart-define=PERANT_PROCESS_PROBE=true. Results use test-only SQLite files.
param(
    [Parameter(Mandatory)][ValidatePattern('^emulator-[0-9]+$')][string]$Target,
    [string]$AdbExe = 'adb',
    [int]$AdbPort = 5037,
    [string]$LogPath = (Join-Path ([IO.Path]::GetTempPath()) ('perant-recovery-' + [guid]::NewGuid() + '.log'))
)
$ErrorActionPreference = 'Stop'
$package = 'dev.perant.perant'
function Invoke-TestAdb {
    & $adbExe -P $AdbPort -s $target @args
}
if ((Invoke-TestAdb get-state) -ne 'device') { throw 'Dedicated emulator unavailable' }
for ($turn = 0; $turn -lt 13; $turn++) {
    Invoke-TestAdb shell am start -W -n dev.perant.perant/.MainActivity | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds(32)
    $stepDone = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 600
        $appProcess = ([string](Invoke-TestAdb shell pidof $package)).Trim()
        if (!$appProcess) { continue }
        $lines = @(Invoke-TestAdb logcat -d "--pid=$appProcess" -s flutter:I)
        $failure = $lines -match 'Some tests failed|\[E\]|EXCEPTION CAUGHT'
        if ($failure) { $lines | Add-Content -Encoding utf8 -LiteralPath $LogPath; throw 'Flutter device assertion failed' }
        if ($lines -match 'PERANT_RECOVERED' -and $lines -match 'All tests passed!') {
            $lines | Add-Content -Encoding utf8 -LiteralPath $LogPath
            Write-Output ($lines -match 'PERANT_RECOVERED|All tests passed!')
            Write-Output "Device log saved to $LogPath"
            exit 0
        }
        $ready = @( $lines -match 'PERANT_INTERRUPT_READY' )
        if (!$ready.Count) { continue }
        if (!($lines -match 'PERANT_DISK')) { throw 'SQLite capacity test did not complete' }
        $ready[-1] | Write-Output
        $lines | Add-Content -Encoding utf8 -LiteralPath $LogPath
        Invoke-TestAdb shell input keyevent KEYCODE_HOME | Out-Null
        if ($turn % 2 -eq 0) {
            Invoke-TestAdb shell input keyevent KEYCODE_SLEEP | Out-Null
            Start-Sleep -Milliseconds 600
            Invoke-TestAdb shell input keyevent KEYCODE_WAKEUP | Out-Null
            Invoke-TestAdb shell wm dismiss-keyguard | Out-Null
        }
        Invoke-TestAdb shell am force-stop $package | Out-Null
        if (([string](Invoke-TestAdb shell pidof $package)).Trim()) { throw 'Process still running' }
        $stepDone = $true
        break
    }
    if (!$stepDone) { throw 'Device did not reach a test checkpoint' }
}
throw 'Exceeded recovery probe rounds'
