param(
    [string]$Timestamp,
    [string]$App1Label,
    [string]$App1Pattern,
    [string]$App2Label,
    [string]$App2Pattern,
    [string]$MonitorScriptName
)

$monitorScript = if ([string]::IsNullOrWhiteSpace($MonitorScriptName)) {
    'benchmark_windows.sh'
} else {
    $MonitorScriptName.ToLowerInvariant()
}

function Get-ProcessPerfMaps {
    $perfByPid = @{}
    $perfByName = @{}

    Get-CimInstance Win32_PerfFormattedData_PerfProc_Process | ForEach-Object {
        if ($_.IDProcess -le 0 -or $_.Name -eq '_Total' -or $_.Name -eq 'Idle') {
            return
        }

        $perf = $_
        $perfByPid[[int]$perf.IDProcess] = $perf

        $normalizedName = ([string]$perf.Name).ToLowerInvariant()
        if (-not $perfByName.ContainsKey($normalizedName)) {
            $perfByName[$normalizedName] = New-Object System.Collections.ArrayList
        }
        [void]$perfByName[$normalizedName].Add($perf)
    }

    return @{
        ByPid = $perfByPid
        ByName = $perfByName
    }
}

function Resolve-PerfRow {
    param(
        [hashtable]$PerfByPid,
        [hashtable]$PerfByName,
        [int]$ProcessId,
        [string]$ProcessName
    )

    if ($PerfByPid.ContainsKey($ProcessId)) {
        return $PerfByPid[$ProcessId]
    }

    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($ProcessName).ToLowerInvariant()
    if ($PerfByName.ContainsKey($baseName)) {
        $matches = @($PerfByName[$baseName])
        if ($matches.Count -eq 1) {
            return $matches[0]
        }
    }

    return $null
}

$perfMaps = Get-ProcessPerfMaps
$perfByPid = $perfMaps.ByPid
$perfByName = $perfMaps.ByName

Get-CimInstance Win32_Process | ForEach-Object {
    $procId = [int]$_.ProcessId
    $name = [string]$_.Name
    $cmd = [string]$_.CommandLine
    $search = ($name + ' ' + $cmd).ToLowerInvariant()

    if ($search -match [regex]::Escape($monitorScript)) {
        return
    }

    $app = $null
    if ($search -match $App1Pattern) {
        $app = $App1Label
    } elseif ($search -match $App2Pattern) {
        $app = $App2Label
    }

    if (-not $app) {
        return
    }

    $perf = Resolve-PerfRow -PerfByPid $perfByPid -PerfByName $perfByName -ProcessId $procId -ProcessName $name
    $cpu = 0.0
    $memMb = 0.0

    if ($perf) {
        $cpu = [math]::Round([double]$perf.PercentProcessorTime, 2)
        $memMb = [math]::Round(([double]$perf.WorkingSetPrivate / 1MB), 2)
    } elseif ($_.WorkingSetSize) {
        $memMb = [math]::Round(([double]$_.WorkingSetSize / 1MB), 2)
    }

    $command = if ([string]::IsNullOrWhiteSpace($name)) { 'unknown' } else { $name }
    $command = $command.Replace(',', ';')
    $command = $command.Replace([string][char]34, [string][char]39)
    $quote = [char]34

    [Console]::WriteLine($Timestamp + ',' + $app + ',' + $procId + ',' + $quote + $command + $quote + ',' + $cpu.ToString('0.00') + ',' + $memMb.ToString('0.00'))
}