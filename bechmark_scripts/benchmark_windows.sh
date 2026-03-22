#!/usr/bin/env bash

set -u

DURATION="${1:-60}"
APP1_LABEL="${2:-Insync}"
APP1_PATTERN="${3:-insync|isdaemon}"
APP2_LABEL="${4:-SynciZen}"
APP2_PATTERN="${5:-syncizen|rclone}"
REPORT_FILE="${6:-benchmark_windows_usage.csv}"
INTERVAL="${INTERVAL:-0.5}"
POWERSHELL_BIN="${POWERSHELL_BIN:-powershell.exe}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
COLLECTOR_PS1="$SCRIPT_DIR/benchmark_windows_collector.ps1"

if command -v cygpath >/dev/null 2>&1; then
    COLLECTOR_PS1_WIN="$(cygpath -w "$COLLECTOR_PS1")"
elif command -v wslpath >/dev/null 2>&1; then
    COLLECTOR_PS1_WIN="$(wslpath -w "$COLLECTOR_PS1")"
else
    COLLECTOR_PS1_WIN="$COLLECTOR_PS1"
fi

usage() {
    cat <<EOF
Usage:
    ./benchmark_windows.sh [duration] [app1_label] [app1_regex] [app2_label] [app2_regex] [report_file]

Examples:
    ./benchmark_windows.sh
    ./benchmark_windows.sh 120 Insync 'insync|isdaemon' SynciZen 'syncizen|rclone' benchmark_windows_usage.csv

Notes:
  - Run this from Git Bash or WSL on Windows.
  - Process metrics are collected with PowerShell/CIM, but the script itself is Bash.
  - The regex arguments are matched against both process name and command line.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if ! command -v "$POWERSHELL_BIN" >/dev/null 2>&1; then
    echo "Error: $POWERSHELL_BIN was not found in PATH."
    exit 1
fi

if ! command -v awk >/dev/null 2>&1; then
    echo "Error: awk is required."
    exit 1
fi

if [ ! -f "$COLLECTOR_PS1" ]; then
    echo "Error: collector script not found: $COLLECTOR_PS1"
    exit 1
fi

if ! awk -v value="$DURATION" 'BEGIN { exit !(value + 0 > 0) }'; then
    echo "Error: duration must be greater than 0 seconds."
    exit 1
fi

if ! awk -v value="$INTERVAL" 'BEGIN { exit !(value + 0 > 0) }'; then
    echo "Error: INTERVAL must be greater than 0 seconds."
    exit 1
fi

get_epoch_seconds() {
    date +%s.%3N 2>/dev/null || "$POWERSHELL_BIN" -NoProfile -Command '[math]::Round((Get-Date).ToUniversalTime().Subtract([datetime]"1970-01-01").TotalSeconds, 3)' | tr -d '\r'
}

get_timestamp() {
    "$POWERSHELL_BIN" -NoProfile -Command '(Get-Date).ToString("yyyy-MM-dd_HH:mm:ss.fff")' | tr -d '\r'
}

ps_escape_single_quotes() {
    printf "%s" "$1" | sed "s/'/''/g"
}

collect_sample() {
    local timestamp="$1"
    local command
    local monitor_script_name

    monitor_script_name="$(basename "$0")"
    command="& '$COLLECTOR_PS1_WIN'"
    command+=" -Timestamp '$(ps_escape_single_quotes "$timestamp")'"
    command+=" -App1Label '$(ps_escape_single_quotes "$APP1_LABEL")'"
    command+=" -App1Pattern '$(ps_escape_single_quotes "$APP1_PATTERN")'"
    command+=" -App2Label '$(ps_escape_single_quotes "$APP2_LABEL")'"
    command+=" -App2Pattern '$(ps_escape_single_quotes "$APP2_PATTERN")'"
    command+=" -MonitorScriptName '$(ps_escape_single_quotes "$monitor_script_name")'"

    "$POWERSHELL_BIN" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$command" | tr -d '\r' >> "$REPORT_FILE"
}

echo "TIMESTAMP,APP,PID,COMMAND,CPU_PERCENT,MEM_MB" > "$REPORT_FILE"

echo "Sampling $APP1_LABEL and $APP2_LABEL every ${INTERVAL}s for ${DURATION}s on Windows..."
echo "Saving raw data -> ${REPORT_FILE}"

START_TIME="$(get_epoch_seconds)"
END_TIME="$(awk -v start="$START_TIME" -v duration="$DURATION" 'BEGIN { printf "%.3f", start + duration }')"

while true; do
    TIMESTAMP="$(get_timestamp)"
    collect_sample "$TIMESTAMP"

    NOW="$(get_epoch_seconds)"
    if awk -v now="$NOW" -v end="$END_TIME" 'BEGIN { exit !(now >= end) }'; then
        break
    fi

    sleep "$INTERVAL"
done

DATA_ROWS="$(awk 'END { print NR - 1 }' "$REPORT_FILE")"
if [ "$DATA_ROWS" -le 0 ]; then
    echo ""
    echo "No matching processes were sampled."
    echo "Check the app regex patterns: $APP1_PATTERN | $APP2_PATTERN"
    exit 0
fi

echo ""
echo "--- 1. PEAK TOTAL CONCURRENT USAGE ($DURATION seconds) ---"
awk -F, '
NR > 1 {
    key = $1 "|" $2
    cpu_sum[key] += $5 + 0
    mem_sum[key] += $6 + 0
    apps[$2] = 1
}
END {
    printf "%-12s | %-20s | %-20s\n", "APP", "PEAK TOTAL CPU %", "PEAK TOTAL MEM (MB)"
    printf "----------------------------------------------------------------\n"
    for (k in cpu_sum) {
        split(k, parts, "|")
        app = parts[2]
        if (!(app in peak_cpu) || cpu_sum[k] > peak_cpu[app]) peak_cpu[app] = cpu_sum[k]
        if (!(app in peak_mem) || mem_sum[k] > peak_mem[app]) peak_mem[app] = mem_sum[k]
    }
    for (app in apps) {
        printf "%-12s | %-20.2f | %-20.2f\n", app, peak_cpu[app] + 0, peak_mem[app] + 0
    }
}' "$REPORT_FILE"

echo ""
echo "--- 2. EFFICIENCY PROXY & AVERAGE RESOURCE USAGE ---"
echo "Lower Total CPU-sec and lower Avg MEM generally indicate lighter system impact."
awk -F, -v interval="$INTERVAL" '
NR == 1 { next }
{
    ts = $1
    app = $2
    cpu = $5 + 0
    mem = $6 + 0

    if (!(ts in seen_ts)) {
        seen_ts[ts] = 1
        ts_order[++ts_count] = ts
    }
    if (!(app in seen_app)) {
        seen_app[app] = 1
        app_order[++app_count] = app
    }

    key = ts SUBSEP app
    cpu_sum[key] += cpu
    mem_sum[key] += mem
}
END {
    if (ts_count == 0) {
        print "No data collected."
        exit
    }

    printf "%-12s | %-12s | %-15s | %-11s | %-16s | %-14s | %-14s | %-12s | %-12s\n", "APP", "Avg CPU %", "Total CPU-sec", "Peak CPU %", "Longest Peak(s)", "Avg MEM (MB)", "Peak MEM (MB)", "Time>20%(s)", "Time>50%(s)"
    printf "--------------------------------------------------------------------------------------------------------------------------------------\n"

    for (ai = 1; ai <= app_count; ai++) {
        app = app_order[ai]
        avg_cpu = 0
        avg_mem = 0
        total_cpu_sec = 0
        peak_cpu = 0
        peak_mem = 0

        for (ti = 1; ti <= ts_count; ti++) {
            ts = ts_order[ti]
            key = ts SUBSEP app
            cpu_series[ti] = cpu_sum[key] + 0
            mem_series[ti] = mem_sum[key] + 0
            avg_cpu += cpu_series[ti]
            avg_mem += mem_series[ti]
            total_cpu_sec += (cpu_series[ti] * interval) / 100.0
            if (cpu_series[ti] > peak_cpu) peak_cpu = cpu_series[ti]
            if (mem_series[ti] > peak_mem) peak_mem = mem_series[ti]
        }

        avg_cpu /= ts_count
        avg_mem /= ts_count
        high_thresh = peak_cpu > 0 ? peak_cpu * 0.60 : 10
        max_streak = 0
        current_streak = 0
        time20 = 0
        time50 = 0

        for (ti = 1; ti <= ts_count; ti++) {
            cpu = cpu_series[ti]
            if (cpu >= high_thresh) {
                current_streak++
                if (current_streak > max_streak) max_streak = current_streak
            } else {
                current_streak = 0
            }
            if (cpu > 20) time20 += interval
            if (cpu > 50) time50 += interval
        }

        printf "%-12s | %-12.2f | %-15.2f | %-11.2f | %-16.1f | %-14.1f | %-14.1f | %-12.1f | %-12.1f\n", app, avg_cpu, total_cpu_sec, peak_cpu, max_streak * interval, avg_mem, peak_mem, time20, time50
        delete cpu_series
        delete mem_series
    }
}' "$REPORT_FILE"

echo ""
echo "--- 3. INDIVIDUAL PROCESS PEAKS ---"
awk -F, '
NR > 1 {
    pid = $3
    app[pid] = $2
    cmd[pid] = $4
    if (!($5 + 0 < max_cpu[pid])) max_cpu[pid] = $5 + 0
    if (!($6 + 0 < max_mem[pid])) max_mem[pid] = $6 + 0
}
END {
    printf "%-12s | %-8s | %-28s | %-12s | %-12s\n", "APP", "PID", "COMMAND", "PEAK CPU %", "PEAK MEM (MB)"
    printf "--------------------------------------------------------------------------------\n"
    for (pid in max_cpu) {
        gsub(/^"|"$/, "", cmd[pid])
        printf "%-12s | %-8s | %-28s | %-12.2f | %-12.2f\n", app[pid], pid, cmd[pid], max_cpu[pid], max_mem[pid]
    }
}' "$REPORT_FILE"

echo ""
echo "Full high-resolution log saved to: $REPORT_FILE"
echo "Compare Total CPU-sec and Avg MEM (MB) to judge which app is lighter on the system."