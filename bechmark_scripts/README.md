# Process Benchmark

Simple scripts for comparing the CPU and memory impact of Insync and SynciZen.

## Table of Contents

- [Files](#files)
- [Unix: macOS and Linux](#unix-macos-and-linux)
- [Windows](#windows)
- [Results](#results)

## Files

- `benchmark_unix.sh`: use on Linux and macOS.
- `benchmark_windows.sh`: Bash launcher for Windows.
- `benchmark_windows_collector.ps1`: PowerShell collector used by the Windows script.

## Unix: macOS and Linux

Use the same script on both platforms:

```bash
chmod +x benchmark_unix.sh
./benchmark_unix.sh 300
```

On macOS, run it with `sudo`:

```bash
sudo ./benchmark_unix.sh 300
```

Default output:

```text
benchmark_unix_usage.csv
```

## Windows

Run from Git Bash or WSL:

```bash
chmod +x benchmark_windows.sh
./benchmark_windows.sh 300 Insync 'insync|isdaemon' SynciZen 'syncizen|rclone' benchmark_windows_usage.csv
```

Default output:

```text
benchmark_windows_usage.csv
```

## Results

Check these first:

- `Avg CPU %`
- `Total CPU-sec`
- `Avg MEM (MB)`
- `Peak MEM (MB)`

Lower CPU-seconds and lower average memory usually mean a lighter app.
