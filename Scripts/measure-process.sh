#!/bin/zsh
set -euo pipefail
export LC_ALL=C
export LANG=C
script_dir=${0:A:h}
repo_root=${script_dir:h}
expected_executable="$repo_root/build/ThermoBar.app/Contents/MacOS/ThermoBar"

summarize_samples() {
    local summary_mode=$1
    local summary_file=$2
    awk -v mode="$summary_mode" '
        function median(values, count,    position, cursor, value) {
            for (position = 2; position <= count; position++) {
                value = values[position]
                cursor = position - 1
                while (cursor >= 1 && values[cursor] > value) {
                    values[cursor + 1] = values[cursor]
                    cursor--
                }
                values[cursor + 1] = value
            }
            return (values[count / 2] + values[(count / 2) + 1]) / 2
        }
        {
            cpu += $1
            if ($2 > maxRSS) maxRSS = $2
            if (NR <= 30) firstRSS[NR] = $2
            lastRSS[((NR - 1) % 30) + 1] = $2
        }
        END {
            if (NR != 300) exit 1
            firstMedian = median(firstRSS, 30)
            lastMedian = median(lastRSS, 30)
            printf "mode=%s samples=%d mean_cpu=%.4f max_rss_kib=%d first30_rss_median_kib=%.10g last30_rss_median_kib=%.10g rss_growth_kib=%.10g\n", mode, NR, cpu / NR, maxRSS, firstMedian, lastMedian, lastMedian - firstMedian
        }
    ' "$summary_file"
}

if [[ "${THERMOBAR_MEASURE_SELF_TEST:-}" == 1 ]]; then
    fixture="$(mktemp -t thermobar-measure-fixture.XXXXXX)"
    trap 'rm -f "$fixture"' EXIT
    for _ in {1..270}; do print -r -- "0 5120" >> "$fixture"; done
    for _ in {1..30}; do print -r -- "0 5121" >> "$fixture"; done
    fixture_summary="$(summarize_samples fixture "$fixture")"
    [[ "$fixture_summary" == *"rss_growth_kib=1"* ]] || {
        print -ru2 -- "Median fixture failed: $fixture_summary"
        exit 1
    }
    print -r -- "measure-process self-test passed: $fixture_summary"
    exit 0
fi

if (( $# != 3 )); then
    print -ru2 -- "Usage: $0 <pid> <visible|menu-bar-only> <output>"
    exit 64
fi

pid=$1
mode=$2
out=$3

[[ "$pid" == <-> ]] || { print -ru2 -- "PID must be numeric"; exit 64; }
[[ "$mode" == visible || "$mode" == menu-bar-only ]] || { print -ru2 -- "Mode must be visible or menu-bar-only"; exit 64; }
[[ -n "$out" ]] || { print -ru2 -- "Output path must not be empty"; exit 64; }

process_fingerprint() {
    local process_path process_start
    process_path="$(ps -p "$pid" -o comm= | awk 'NR == 1 { print }')"
    [[ -n "$process_path" ]] || {
        print -ru2 -- "Could not resolve executable for process $pid"
        exit 1
    }
    [[ "${process_path:A}" == "${expected_executable:A}" ]] || {
        print -ru2 -- "Process $pid is not this worktree's ThermoBar executable: $process_path"
        exit 1
    }
    process_start="$(ps -p "$pid" -o lstart= | awk '{$1=$1; print; exit}')"
    [[ -n "$process_start" ]] || {
        print -ru2 -- "Could not resolve start time for process $pid"
        exit 1
    }
    print -r -- "${process_path:A}|$process_start"
}

ensure_running() {
    kill -0 "$pid" 2>/dev/null || {
        print -ru2 -- "Process $pid is not running"
        exit 1
    }
    current_fingerprint="$(process_fingerprint)"
    [[ "$current_fingerprint" == "$initial_fingerprint" ]] || {
        print -ru2 -- "Process $pid identity changed during measurement"
        exit 1
    }
}

initial_fingerprint="$(process_fingerprint)"
ensure_running
sleep 60
ensure_running
: > "$out"

for _ in {1..300}; do
    ensure_running
    sample="$(ps -p "$pid" -o %cpu=,rss=)"
    fields=( ${(z)sample} )
    if (( ${#fields} != 2 )) || [[ "${fields[1]}" != <->(|.<->) ]] || [[ "${fields[2]}" != <-> ]]; then
        print -ru2 -- "Missing or invalid sample for process $pid"
        exit 1
    fi
    print -r -- "${fields[1]} ${fields[2]}" >> "$out"
    sleep 2
done

sample_count="$(wc -l < "$out" | tr -d '[:space:]')"
[[ "$sample_count" == 300 ]] || { print -ru2 -- "Expected 300 samples, found $sample_count"; exit 1; }

summarize_samples "$mode" "$out"
ensure_running
