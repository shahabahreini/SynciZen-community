#!/bin/bash
# =============================================================================
# Unix benchmark for Insync vs SynciZen.
# Use on Linux directly, and run with sudo on macOS.
# =============================================================================

DURATION=${1:-60}
INTERVAL=0.5
REPORT_FILE="benchmark_unix_usage.csv"

echo "TIMESTAMP,APP,PID,COMMAND,CPU_PERCENT,MEM_MB" > "$REPORT_FILE"

echo "Sampling Insync & SynciZen every ${INTERVAL}s for ${DURATION}s..."
echo "Saving raw data → ${REPORT_FILE}"

# High-precision timestamp (macOS safe)
get_timestamp() {
    python3 -c '
import datetime
print(datetime.datetime.now().strftime("%Y-%m-%d_%H:%M:%S.%f")[:-3])
' 2>/dev/null || date +%Y-%m-%d_%H:%M:%S
}

# Precise end time
if command -v python3 >/dev/null 2>&1; then
    END_TIME=$(python3 -c "import time; print(time.time() + $DURATION)")
    USE_PRECISE=true
else
    END_TIME=$(( $(date +%s) + DURATION ))
    USE_PRECISE=false
fi

while true; do
    TIMESTAMP=$(get_timestamp)

    ps -e -o pid,%cpu,rss,command | awk -v ts="$TIMESTAMP" '
    NR > 1 {
        pid = $1
        cpu = $2 + 0
        rss = $3

        full_cmd = $4
        for (i=5; i<=NF; i++) full_cmd = full_cmd " " $i
        lfull = tolower(full_cmd)

        if (lfull ~ /awk|grep|benchmark_unix/) next

        mem_mb = sprintf("%.2f", rss / 1024)

        cmd_name = $4
        gsub(/^.*\//, "", cmd_name)
        gsub(/ .*$/, "", cmd_name)
        if (cmd_name == "") cmd_name = "unknown"

        if (lfull ~ /insync\.app/ || lfull ~ /isdaemon/ || lfull ~ /insync/) {
            print ts ",Insync," pid ",\"" cmd_name "\"," cpu "," mem_mb
            next
        }

        if (lfull ~ /syncizen\.app/ || full_cmd ~ /\brclone\b/) {
            print ts ",SynciZen," pid ",\"" cmd_name "\"," cpu "," mem_mb
        }
    }' >> "$REPORT_FILE"

    if [ "$USE_PRECISE" = true ]; then
        NOW=$(python3 -c 'import time; print(time.time())')
        [ "$(bc <<< "$NOW >= $END_TIME" 2>/dev/null || echo 0)" -eq 1 ] && break
    else
        [ "$(date +%s)" -ge "$END_TIME" ] && break
    fi

    sleep "$INTERVAL"
done

echo ""
echo "--- 1. PEAK TOTAL CONCURRENT USAGE ($DURATION seconds) ---"
awk -F, '
NR > 1 {
    gsub(/^"|"$/, "", $4)
    key = $1 "|" $2
    cpu_sum[key] += $5 + 0
    mem_sum[key] += $6 + 0
    apps[$2] = 1
}
END {
    for (k in cpu_sum) {
        split(k, arr, "|")
        app = arr[2]
        if (cpu_sum[k] > peak_cpu[app] || peak_cpu[app] == "") peak_cpu[app] = cpu_sum[k]
        if (mem_sum[k] > peak_mem[app] || peak_mem[app] == "") peak_mem[app] = mem_sum[k]
    }
    printf "%-10s | %-20s | %-20s\n", "APP", "PEAK TOTAL CPU %", "PEAK TOTAL MEM (MB)"
    printf "------------------------------------------------------------\n"
    for (a in apps) {
        printf "%-10s | %-20.2f | %-20.2f\n", a, peak_cpu[a], peak_mem[a]
    }
}' "$REPORT_FILE"

echo ""
echo "--- 2. ENERGY EFFICIENCY & AVERAGE RESOURCE USAGE ---"
echo "Lower Total CPU-sec + lower Avg MEM = better battery / efficiency"

python3 - <<'PYEOF'
import csv
from collections import defaultdict

REPORT = "benchmark_unix_usage.csv"
INTERVAL = 0.5

app_cpu = defaultdict(lambda: defaultdict(float))
app_mem = defaultdict(lambda: defaultdict(float))
all_timestamps = set()

with open(REPORT, 'r') as f:
    reader = csv.reader(f)
    next(reader)
    for row in reader:
        if len(row) < 6: continue
        ts = row[0]
        app = row[1]
        try:
            cpu = float(row[4])
            mem = float(row[5])
            app_cpu[app][ts] += cpu
            app_mem[app][ts] += mem
            all_timestamps.add(ts)
        except ValueError:
            continue

if not all_timestamps:
    print("No data collected.")
else:
    sorted_ts = sorted(all_timestamps)

    print(f"{'APP':<10} | {'Avg CPU %':<12} | {'Total CPU-sec':<15} | {'Peak CPU %':<11} | {'Longest Peak(s)':<16} | {'Avg MEM (MB)':<14} | {'Peak MEM (MB)':<14} | {'Time>20%(s)':<12} | {'Time>50%(s)':<12}")
    print("-" * 135)

    for app in sorted(app_cpu.keys()):
        cpu_series = [app_cpu[app].get(ts, 0.0) for ts in sorted_ts]
        mem_series = [app_mem[app].get(ts, 0.0) for ts in sorted_ts]
        n = len(cpu_series)

        avg_cpu = sum(cpu_series) / n
        avg_mem = sum(mem_series) / n
        total_cpu_sec = sum(cpu_series) * INTERVAL / 100.0
        peak_cpu = max(cpu_series) if cpu_series else 0.0
        peak_mem = max(mem_series) if mem_series else 0.0

        # Longest sustained high load (>=60% of its own peak)
        high_thresh = 0.60 * peak_cpu if peak_cpu > 0 else 10
        max_streak = current = 0
        for c in cpu_series:
            if c >= high_thresh:
                current += 1
                max_streak = max(max_streak, current)
            else:
                current = 0
        longest_peak_sec = max_streak * INTERVAL

        time_20 = sum(1 for c in cpu_series if c > 20) * INTERVAL
        time_50 = sum(1 for c in cpu_series if c > 50) * INTERVAL

        print(f"{app:<10} | {avg_cpu:<12.2f} | {total_cpu_sec:<15.2f} | {peak_cpu:<11.2f} | {longest_peak_sec:<16.1f} | {avg_mem:<14.1f} | {peak_mem:<14.1f} | {time_20:<12.1f} | {time_50:<12.1f}")
PYEOF

echo ""
echo "--- 3. INDIVIDUAL PROCESS PEAKS ---"
awk -F, '
NR > 1 {
    gsub(/^"|"$/, "", $4)
    pid = $3
    app[pid] = $2
    cmd[pid] = $4
    if ($5 + 0 > max_cpu[pid]) max_cpu[pid] = $5
    if ($6 + 0 > max_mem[pid]) max_mem[pid] = $6
}
END {
    for (p in max_cpu) {
        printf "%s|%s|%s|%.2f|%.2f\n", app[p], p, cmd[p], max_cpu[p], max_mem[p]
    }
}' "$REPORT_FILE" | sort -t"|" -k1,1 -k3,3 | awk -F"|" '
BEGIN {
    printf "%-10s | %-8s | %-45s | %-12s | %-12s\n", "APP", "PID", "COMMAND", "PEAK CPU %", "PEAK MEM (MB)"
    print "-------------------------------------------------------------------------------------------"
}
{ printf "%-10s | %-8s | %-45s | %-12.2f | %-12.2f\n", $1, $2, $3, $4, $5 }
'

echo ""
echo "Full high-resolution log saved to: $REPORT_FILE"
echo "→ Compare **Total CPU-sec** and **Avg MEM (MB)** to see which app saves more energy."