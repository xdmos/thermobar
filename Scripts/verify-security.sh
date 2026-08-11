#!/bin/zsh
set -euo pipefail

raw_symbol_violations() {
    print -r -- "$1" | rg '(^|[^[:alnum:]])(NSURLSession|URLSession|NSURLRequest|URLRequest|NSURLConnection|CFHTTP|URLLoading|NWConnection|NWListener|NSXPC[[:alnum:]]*|XPCConnection|NSTask|socket|connect|getaddrinfo|bind|listen|accept|send|recv|posix_spawn|posix_spawnp|fork|execl|execle|execlp|execv|execve|execvp|execvP|popen|system|dlopen|dlsym)([^[:alnum:]]|$)|(^|[^[:alnum:]])xpc_[[:alnum:]_]*([^[:alnum:]]|$)' | rg -v '^[[:space:]]*(U[[:space:]]+)?_dlsym$' || true
}

demangled_symbol_violations() {
    print -r -- "$1" | rg 'Foundation\.(URLSession|URLRequest)|NSURLConnection|CFHTTP|URLLoading|Network\.(NWConnection|NWListener)|XPC\.|NSXPC[[:alnum:]]*|(^|[^[:alnum:]])(Process|NSTask)([^[:alnum:]]|$)' || true
}

if [[ "${THERMOBAR_SECURITY_SELF_TEST:-}" == 1 ]]; then
    objc_fixture=$'_OBJC_CLASS_$_NSURLSession\n_OBJC_CLASS_$_NSTask\n_OBJC_CLASS_$_NSXPCConnection\n_OBJC_CLASS_$_NSProcessInfo'
    fixture_violations="$(raw_symbol_violations "$objc_fixture")"
    [[ "$fixture_violations" == *"NSURLSession"* && "$fixture_violations" == *"NSTask"* && "$fixture_violations" == *"NSXPCConnection"* && "$fixture_violations" != *"NSProcessInfo"* ]] || {
        print -ru2 -- "Objective-C symbol fixture failed: $fixture_violations"
        exit 1
    }
    allowed_violations="$(raw_symbol_violations '_OBJC_CLASS_$_NSProcessInfo')"
    [[ -z "$allowed_violations" ]] || {
        print -ru2 -- "NSProcessInfo must remain allowed: $allowed_violations"
        exit 1
    }
    demangled_fixture="$(demangled_symbol_violations $'Foundation.URLSession.data(for:delegate:)\nFoundation.Process.run()\nNSXPCConnection')"
    [[ "$demangled_fixture" == *"Foundation.URLSession"* && "$demangled_fixture" == *"Foundation.Process"* && "$demangled_fixture" == *"NSXPCConnection"* ]] || {
        print -ru2 -- "Demangled fixture failed: $demangled_fixture"
        exit 1
    }
    allowed_demangled="$(demangled_symbol_violations 'Foundation.ProcessInfo.thermalState')"
    [[ -z "$allowed_demangled" ]] || {
        print -ru2 -- "ProcessInfo must remain allowed: $allowed_demangled"
        exit 1
    }
    print -r -- "security self-test passed: Objective-C and demangled URLSession/Process/NSXPC/NSTask rejected; ProcessInfo allowed"
    exit 0
fi

if (( $# < 1 || $# > 2 )); then
    print -ru2 -- "Usage: $0 <ThermoBar.app> [running-pid]"
    exit 64
fi

app_path=${1:A}
pid=${2:-}
script_dir=${0:A:h}
repo_root=${script_dir:h}
executable="$app_path/Contents/MacOS/ThermoBar"

[[ -d "$app_path" && -x "$executable" ]] || {
    print -ru2 -- "Expected a built ThermoBar.app with an executable: $app_path"
    exit 64
}

pid_fingerprint() {
    local candidate_path candidate_start
    candidate_path="$(ps -p "$pid" -o comm= | awk 'NR == 1 { print }')"
    [[ -n "$candidate_path" ]] || { print -ru2 -- "Could not resolve executable for process $pid"; exit 1; }
    [[ "${candidate_path:A}" == "${executable:A}" ]] || {
        print -ru2 -- "PID $pid is not the supplied ThermoBar executable: $candidate_path"
        exit 1
    }
    candidate_start="$(ps -p "$pid" -o lstart= | awk '{$1=$1; print; exit}')"
    [[ -n "$candidate_start" ]] || { print -ru2 -- "Could not resolve start time for process $pid"; exit 1; }
    print -r -- "${candidate_path:A}|$candidate_start"
}

revalidate_pid_identity() {
    kill -0 "$pid" 2>/dev/null || { print -ru2 -- "Process $pid exited during audit"; exit 1; }
    current_pid_fingerprint="$(pid_fingerprint)"
    [[ "$current_pid_fingerprint" == "$initial_pid_fingerprint" ]] || {
        print -ru2 -- "Process $pid identity changed during audit"
        exit 1
    }
}

if [[ -n "$pid" ]]; then
    [[ "$pid" == <-> ]] || { print -ru2 -- "PID must be numeric"; exit 64; }
    kill -0 "$pid" 2>/dev/null || { print -ru2 -- "Process $pid is not running"; exit 1; }
    initial_pid_fingerprint="$(pid_fingerprint)"
fi

fail_matches() {
    local category=$1
    local pattern=$2
    shift 2
    local matches
    if matches="$(rg -n -e "$pattern" "$@")"; then
        print -ru2 -- "Prohibited first-party $category reference(s):"
        print -ru2 -- "$matches"
        exit 1
    else
        local scan_result=$?
        (( scan_result == 1 )) || {
            print -ru2 -- "Source scan failed for $category"
            exit "$scan_result"
        }
    fi
}

# Scan only product inputs. This deliberately excludes this verifier, tests, documentation,
# and generated build products so audit vocabulary cannot trigger its own gate.
source_inputs=("$repo_root/Sources" "$repo_root/Package.swift" "$repo_root/Packaging")
fail_matches "SMC write or fan control" 'writeBytes|case[[:space:]].*=[[:space:]]*6|setFan|[Ff]an[[:alnum:] _-]*[Cc]ontrol|[Cc]ontrol[[:alnum:] _-]*[Ff]an' "${source_inputs[@]}"
fail_matches "subprocess or shell" '\b(Process|NSTask)\b|/(bin|usr/bin)/|(^|[^.[:alnum:]_])(posix_spawn|posix_spawnp|fork|popen|system|execl|execle|execlp|execv|execve|execvp|execvP)[[:space:]]*\(|\bDarwin[[:space:]]*\.[[:space:]]*system[[:space:]]*\(' "${source_inputs[@]}"
fail_matches "XPC or privileged helper" 'NSXPC|XPCConnection|SMJobBless|SMAppService\.(daemon|agent)|LaunchDaemon|PrivilegedHelper|privileged[[:space:]_-]*helper|\bxpc_[[:alnum:]_]*[[:space:]]*\(|import[[:space:]]+XPC' "${source_inputs[@]}"
fail_matches "URL loading" 'URLSession|NSURLConnection|CFHTTP|URLLoading|URLRequest' "${source_inputs[@]}"
fail_matches "Network or CFNetwork" 'import[[:space:]]+Network|Network\.framework|CFNetwork' "${source_inputs[@]}"
fail_matches "BSD socket" '\b(socket|connect|getaddrinfo|bind|listen|accept|send|recv)[[:space:]]*\(' "${source_inputs[@]}"
fail_matches "dynamic loading" '\b(dlopen|dlsym|NSCreateObjectFileImageFromFile)[[:space:]]*\(|NSBundle.*\bload[[:space:]]*\(' "${source_inputs[@]}"

if [[ -n "$pid" ]]; then
    revalidate_pid_identity
fi

resolved_files=( ${(f)$(find "$repo_root" -type f -name Package.resolved ! -path '*/.build/*' ! -path '*/build/*' ! -path '*/.git/*' -print)} )
for resolved in "${resolved_files[@]}"; do
    [[ ! -s "$resolved" ]] || {
        print -ru2 -- "Package.resolved must be absent or empty: $resolved"
        exit 1
    }
done

entitlements_file="$(mktemp -t thermobar-entitlements.XXXXXX)"
trap 'rm -f "$entitlements_file"' EXIT
codesign -d --entitlements :- "$app_path" > "$entitlements_file" 2>/dev/null
plutil -lint "$entitlements_file" >/dev/null
if rg -n '<key>' "$entitlements_file"; then
    print -ru2 -- "Unexpected entitlement(s) in $app_path"
    exit 1
fi

linked_libraries="$(otool -L "$executable")"
print -r -- "$linked_libraries"
allowed_frameworks=(
    AppKit CoreFoundation CoreGraphics Foundation IOKit ServiceManagement SwiftUI UserNotifications
)
allowed_libraries=(
    /usr/lib/libSystem.B.dylib
    /usr/lib/libobjc.A.dylib
    /usr/lib/swift/libswiftCore.dylib
    /usr/lib/swift/libswiftCoreAudio.dylib
    /usr/lib/swift/libswiftCoreFoundation.dylib
    /usr/lib/swift/libswiftCoreImage.dylib
    /usr/lib/swift/libswiftDispatch.dylib
    /usr/lib/swift/libswiftIOKit.dylib
    /usr/lib/swift/libswiftMetal.dylib
    /usr/lib/swift/libswiftOSLog.dylib
    /usr/lib/swift/libswiftObjectiveC.dylib
    /usr/lib/swift/libswiftObservation.dylib
    /usr/lib/swift/libswiftQuartzCore.dylib
    /usr/lib/swift/libswiftSpatial.dylib
    /usr/lib/swift/libswiftUniformTypeIdentifiers.dylib
    /usr/lib/swift/libswiftXPC.dylib
    /usr/lib/swift/libswift_Builtin_float.dylib
    /usr/lib/swift/libswift_Concurrency.dylib
    /usr/lib/swift/libswiftos.dylib
    /usr/lib/swift/libswiftsimd.dylib
)
linked_lines=( "${(@f)$(print -r -- "$linked_libraries" | sed 1d)}" )
for library_line in "${linked_lines[@]}"; do
    library_path="$(print -r -- "$library_line" | sed -E 's/^[[:space:]]*([^[:space:]]+).*/\1/')"
    [[ "$library_path" == /System/Library/* || "$library_path" == /usr/lib/* ]] || {
        print -ru2 -- "Non-system linked library: $library_path"
        exit 1
    }
    if [[ "$library_path" == /System/Library/Frameworks/* ]]; then
        framework=${${library_path##*/}%.framework}
        if (( ${allowed_frameworks[(Ie)$framework]} == 0 )); then
            print -ru2 -- "Unapproved linked system framework: $framework"
            exit 1
        fi
        print -r -- "allowed framework: $framework"
    elif (( ${allowed_libraries[(Ie)$library_path]} == 0 )); then
        print -ru2 -- "Unapproved linked system library: $library_path"
        exit 1
    fi
    if [[ "$library_path" == /usr/lib/swift/libswiftXPC.dylib ]]; then
        [[ "$library_line" == *" weak)" ]] || {
            print -ru2 -- "libswiftXPC.dylib must remain weak-linked"
            exit 1
        }
        print -r -- "allowed toolchain library: libswiftXPC.dylib (weak Swift runtime dependency)"
    fi
done

undefined_symbols="$(nm -u "$executable")"
# Swift's system runtime currently imports _dlsym for its own metadata machinery.
# First-party source is separately fail-closed above; this one documented toolchain
# symbol is not evidence of an application dynamic-loading surface.
prohibited_symbols="$(raw_symbol_violations "$undefined_symbols")"
if [[ -n "$prohibited_symbols" ]]; then
    print -ru2 -- "Prohibited undefined symbol"
    print -ru2 -- "$prohibited_symbols"
    exit 1
fi
if print -r -- "$undefined_symbols" | rg -q '^[[:space:]]*(U[[:space:]]+)?_dlsym$'; then
    print -r -- "allowed toolchain symbol: _dlsym (Swift runtime metadata)"
fi
demangled_symbols="$(print -r -- "$undefined_symbols" | swift demangle)"
demangled_violations="$(demangled_symbol_violations "$demangled_symbols")"
if [[ -n "$demangled_violations" ]]; then
    print -ru2 -- "Prohibited demangled high-level symbol"
    print -ru2 -- "$demangled_violations"
    exit 1
fi
if [[ -n "$pid" ]]; then
    socket_output="$(lsof -a -p "$pid" -i 2>&1)" || socket_status=$?
    socket_status=${socket_status:-0}
    if [[ -n "$socket_output" || "$socket_status" -gt 1 ]]; then
        print -ru2 -- "App-owned network socket(s) or lsof failure:"
        print -ru2 -- "$socket_output"
        exit 1
    fi
    revalidate_pid_identity
    print -r -- "runtime socket audit: no app-owned sockets"
fi

print -r -- "security audit passed: no prohibited source, dependency, entitlement, link, symbol, or socket finding"
