# ThermoBar top resource consumers design

Date: 2026-08-13

Status: user-approved; independent spec review fixes applied

Target: Mac17,9, macOS 27.0 build 26A5406e

## Objective

Replace the floating panel's normal **Dane są aktualne** footer with two compact,
read-only rankings:

1. the three application families currently consuming the most CPU;
2. the three application families currently using the most physical memory.

The rankings appear one below the other, refresh every two seconds only while the
floating panel is visible, and cover every readable process, including system
services, helper processes, and ThermoBar itself.

## Scope and non-goals

- Use only native, in-process macOS resource APIs.
- Do not execute `ps`, `top`, a shell, `Foundation.Process`, or any helper tool.
- Do not add network, XPC, privileged-helper, administrator, or new entitlement
  requirements.
- Do not persist, log, upload, or otherwise retain process names, identifiers, or
  usage values beyond the in-memory sampling baseline and current snapshot.
- Do not add process controls, details, navigation, force quit, search, filtering,
  history, charts, or user-defined exclusions.
- Do not add the rankings to the menu-bar label or menu popover.
- Do not sample process usage in `menuBarOnly` or `sleeping` mode.
- Do not hide ThermoBar from its own rankings when it legitimately qualifies.
- Do not change the existing two-second visible, ten-second menu-bar-only, or sleep
  sampling cadences.

## Native data source

Add an isolated reader in `ThermoBarCore` that uses the macOS `libproc` APIs already
provided by `libSystem`:

- `proc_listallpids` to enumerate active process identifiers;
- `proc_pid_rusage` with `RUSAGE_INFO_V4` for cumulative user/system CPU time,
  `ri_phys_footprint`, and `ri_proc_start_abstime`;
- `proc_pidpath` as the primary identity source and `proc_name` only for a bounded
  per-PID fallback when that path is missing or unusable.

The reader must not add a package dependency or a non-system linked library. Each
sampling pass allocates from a bounded process-count result, performs at most one
bounded enumeration retry when the process list changes while being read, and rejects
negative API results, invalid identifiers, unterminated strings, arithmetic overflow,
and non-finite calculated values.

Per-process read failures are expected because a process may exit or be inaccessible
between enumeration and inspection. Such entries are skipped. A failure of the whole
enumeration produces unavailable rankings rather than stale prior results. The one
usage read is bracketed by two identity observations; an entry is retained only when
the two observations agree, preventing a PID/path race from being attributed to the
wrong application.

## Application-family identity and aggregation

Every native PID remains a separately sampled record, carrying its PID, start time,
cumulative CPU time, physical footprint, display name, and a collision-free group ID.
Paths are normalized lexically only: they must be absolute, separators and `.` are
collapsed, and `..` is resolved without reading the filesystem or following symlinks.
Root-only or otherwise unusable paths fall back to PID scope.

- A normalized path containing one or more `.app` components is grouped as
  `app:<outermost-app-root>` and displayed as that outermost bundle filename without
  `.app`. This includes helper bundles nested inside an application, so Chrome main
  and helper PIDs form one `Google Chrome` row and ChatGPT/Codex helpers form one
  `ChatGPT` row.
- A valid path outside an app bundle is grouped as `exe:<full-normalized-path>` and
  displayed using its basename.
- Missing or unusable paths are grouped as `pid:<pid>:<startTime>` and use
  `proc_name`; matching fallback names are never merged.

CPU baselines remain PID-scoped and match only when PID, start time, and group ID all
match. Checked CPU deltas are then summed by group and converted to a percentage once.
Current physical footprints are likewise added with checked arithmetic by group. A
per-section aggregation overflow makes only that section unavailable for the pass;
CPU baselines still advance. A group ID with inconsistent display names rejects the
reading as a fail-safe.

## CPU semantics and process identity

CPU is an interval measurement. For every readable process, retain only the prior
sample's:

- PID;
- `ri_proc_start_abstime`;
- cumulative `ri_user_time + ri_system_time`.

A PID matches a prior sample only when its start time and group ID also match. Reused PIDs,
regressed counters, zero elapsed time, and overflowing additions establish a new
baseline and do not produce a CPU percentage for that interval.

For a valid match:

```text
cpuPercent = cpuTimeDeltaNanoseconds / elapsedMonotonicNanoseconds * 100
```

This intentionally follows Activity Monitor-style process CPU semantics: a
multi-threaded process may exceed 100%. Values are finite and nonnegative but are not
normalized by logical CPU count. The first visible sample establishes the baseline;
therefore the CPU section displays **Pomiar…** until the next two-second sample.

The CPU baseline is cleared whenever sampling leaves `visible`, when the Mac sleeps,
and during reader teardown. Re-entering `visible` always begins a new interval and
never compares against a hidden or pre-sleep sample.

## Memory semantics

Memory ranking uses checked sums of the current `ri_phys_footprint` values for each
application family. It is a point-in-time estimate and is available on the first
visible sample. Zero is valid. Overflow makes only the RAM section unavailable for
that pass. The sums do not necessarily reconcile with global used RAM because shared
memory, helper accounting, and protected/unreadable paths can differ.

Physical footprint is formatted using locale-aware binary byte units with at most one
fraction digit, for example `620 MB` or `1,8 GB`. The underlying value remains an
integer byte count.

## Ranking contract

Publish value types in the immutable `SystemSnapshot` for:

- a CPU row containing PID, display name, and CPU percentage;
- a memory row containing PID, display name, and physical-footprint bytes;
- section state: `inactive`, `measuring`, `available(rows)`, or `unavailable`.

An `available` section may contain one to three rows when fewer than three processes
are readable. It must never contain more than three or a row without its required
value. CPU and memory are independent states so memory can be available while CPU is
still measuring.

`inactive` means process inspection is intentionally disabled because the sampler is
not in `visible` mode. Both sections are `inactive` in `menuBarOnly` and `sleeping`, and
no process API is called. `inactive` is not an error and is never rendered while the
panel is hidden. When the panel becomes visible, the immediate sample replaces it with
CPU `measuring` and either available or unavailable memory.

Rank application families descending by the displayed resource value. Ties use display
name in deterministic Unicode scalar order and then stable group ID. The smallest
member PID is retained only as the public row representative; it is neither displayed
nor persisted. Duplicate display names with distinct group IDs remain separate rows.

Avoid product type names that use the exact `Foundation.Process` symbol spelling so
the existing fail-closed subprocess security gate remains precise and green.

## Sampling integration

Integrate the reader into the existing `MetricsSampler` actor and its single cadence;
do not create a second timer or detached loop.

Identity-bearing delivery is strictly bounded and notification delivery remains
lossless by separating their payloads:

```swift
public struct SamplingSnapshot: Equatable, Sendable {
    public let value: SystemSnapshot
    public let transitionID: UUID
}

public struct ThermalSample: Equatable, Sendable {
    public let level: ThermalLevel
    public let monotonicNanoseconds: UInt64
}
```

`snapshots()` uses `AsyncStream<SamplingSnapshot>.bufferingNewest(1)`. Thus at most
one undelivered immutable snapshot can retain names/PIDs; a newer snapshot releases
the older buffered value. `thermalSamples()` is a separate FIFO stream containing
only thermal level and timestamp, so the existing notification state machine observes
every real sensor sample without process identity or usage entering that queue. Both
streams are fed by the same sampler pass and create no additional cadence.

Every AppModel mode request supplies a fresh opaque UUID to `setMode`. The actor sets
the requested mode/identity and performs sleep reset/redaction before its first
suspension. `setMode` returns a direct `SamplingTransitionReceipt` containing the
requested identity and the actual current mode/identity after reconciliation. This
acknowledgement is a function result, not a buffered event, so overflow cannot discard
it. Every real `SamplingSnapshot` is tagged with the identity of the mode that
produced it. Do not use a wrapping integer counter, timestamps, or section state as
transition identity.

- `visible`: sample immediately, then every two seconds. The immediate sample returns
  current memory and establishes CPU baselines; subsequent samples can return CPU.
- `menuBarOnly`: reset the process reader and publish `inactive` for both sections
  without enumerating PIDs.
- `sleeping`: before the first suspension, reset the reader, perform no process reads,
  retain no baseline, and atomically replace `latestSnapshot` consumer sections with
  `inactive` when a snapshot exists. Yield that redacted value into the
  `bufferingNewest(1)` snapshot stream using the sleep transition UUID, which replaces
  and releases any older pending identity-bearing snapshot. This is a presentation
  replacement only and does not enter `thermalSamples()`. Before any first real
  snapshot, `latestSnapshot` remains absent and no snapshot is fabricated; the direct
  transition receipt still acknowledges the mode request.

The process scan is synchronous inside the sampler's existing serialized sample. It
must finish before the immutable snapshot is yielded. It does not change thermal
notification state, SMC connection management, existing diagnostic counters, or the
meaning of public CPU/RAM system-wide metrics.

`AppModel.handleLifecycleEvent(.willSleep)` must synchronously replace any locally
held consumer sections with `inactive` before awaiting the sampler and records the
fresh sleep transition UUID. While sleeping, every received snapshot is sanitized to
`inactive` before any awaited diagnostics work. Wake supplies its own fresh UUID;
AppModel accepts consumer identities only from snapshot values tagged with the current
active request UUID. An older queued menu-bar/visible value or another sleep UUID
therefore cannot restore names/PIDs after sleep intent or wake.

Notification baseline/consumption moves to the lightweight `thermalSamples()` task.
A sleep redaction replacement never enters that stream and cannot retrigger thermal
notifications. This remains correct when wake supersedes paused sleep work, when sleep
occurs before the first snapshot, and when diagnostics delay snapshot consumption.

Process-ranking availability is self-contained and does not create a sensor diagnostic
or reuse the temperature/fan retry UI.

## Floating-panel interface

Keep the existing header and four metric tiles unchanged. After the lower divider,
replace only the normal **Dane są aktualne** row with:

```text
Najwięcej CPU
1  Google Chrome                         32%
2  WindowServer                          21%
3  Codex                                 12%

Najwięcej RAM
1  Google Chrome                      1,8 GB
2  Codex                              1,2 GB
3  WindowServer                       620 MB
```

Use the existing panel typography and spacing. Section titles use compact caption
styling. Each row has a muted rank, a single-line process name with tail truncation,
and a monospaced, trailing-aligned value. CPU uses a whole-number percent without an
upper clamp. Memory uses the formatting defined above. Rows are accessibility elements
whose labels include rank, full process name, resource type, and value.

The panel width stays 238 points. Its content height grows naturally by approximately
120–140 points. `PanelWindowBridge` must observe the installed window/content-frame
size change caused by SwiftUI layout and re-clamp the window's current frame on the
next main-actor turn using the existing 12-point visible-screen inset. This size-change
clamp uses the current screen/frame, does not reload persisted launch geometry, does
not recurse indefinitely, and does not treat its programmatic correction as a user
move. Restoration and screen-topology clamping continue to use their existing paths.

Section fallback text:

- CPU `measuring`: **Pomiar…**;
- either section `unavailable`: **Brak dostępnych danych**;
- `available([])` is forbidden; represent it as `unavailable`.

Existing sensor diagnostics and stale/initial freshness warnings remain visible above
the process rankings. Presentation follows this exact precedence:

1. when a sensor diagnostic exists, render the current compact sensor warning;
2. otherwise, when there is no snapshot or the snapshot is stale, render the current
   freshness warning row;
3. otherwise the snapshot is fresh and healthy, so omit only the normal **Dane są
   aktualne** row.

Before the first visible snapshot, keep the existing no-snapshot freshness warning,
render CPU as **Pomiar…**, and render memory as **Brak dostępnych danych**. A
process-ranking failure does not suppress an unrelated sensor/freshness warning, and
such a warning does not suppress process rankings.

## Error handling and lifecycle

- A process that exits, denies access, changes identity, or returns invalid resource
  data is omitted from that pass without failing other entries.
- If at least one valid row exists, publish the available subset, up to three.
- If enumeration fails or no row is readable, clear the entire CPU baseline and
  publish `unavailable` for memory and CPU. On the first later successful visible
  sample, memory may become available immediately while CPU returns to `measuring`;
  only the following successful interval can publish CPU rows. No multi-interval CPU
  average crosses an enumeration failure.
- If valid memory rows exist but no CPU row has a valid prior identity/counter pair,
  CPU remains `measuring` and its fresh baselines replace the old set.
- Cancellation, mode transition, stream replacement, and deinitialization clear the
  retained baseline and cannot publish a late visible ranking after hidden/sleeping
  mode wins.
- Entering sleep after a snapshot replaces both the sampler's and app model's current
  consumer state with `inactive` without retaining names/PIDs or retriggering thermal
  notification consumption. Entering sleep before the first snapshot retains `nil`
  and relies on the direct transition receipt rather than fabricating a snapshot.
- Buffered pre-sleep snapshots cannot restore consumer identities after sleep intent:
  local redaction is synchronous, the sole pending buffer slot is overwritten by the
  redacted sleep value, and post-wake identities require the current active UUID.
- Process names and PIDs never enter `UserDefaults`, notifications, logs, crash text,
  accessibility identifiers, or security-verifier output.

## Security and privacy

The implementation remains read-only. `proc_listallpids`, `proc_pid_rusage`,
`proc_name`, and `proc_pidpath` are the only new system inspection APIs. The existing
security verifier must continue to reject subprocesses, shells, networking, XPC,
dynamic loading, sockets, SMC writes, fan control, non-system libraries, and unexpected
entitlements.

Extend the verifier's deterministic fixtures only if necessary to prove the allowed
`libproc` symbols do not weaken any existing rejection. Do not add a broad allowlist
that could admit `Foundation.Process`, `NSTask`, spawn, exec, or shell symbols.

## Verification

Deterministic unit tests cover:

- exact CPU delta calculation, including values above 100% and group aggregation;
- first-sample measuring state and second-sample availability;
- PID reuse via changed start time;
- regressed/overflowing CPU counters and zero/overflowing elapsed time;
- physical-footprint application-family ranking and binary-unit formatting;
- outermost nested app-bundle identity, lexical path normalization, PID fallback,
  identity-race skips, conflicting-name fail-safe, deterministic group-ID ties,
  duplicate names, and exact top-three cap;
- one/two readable entries, per-process exit/permission failure, total enumeration
  failure, baseline clearing, first-recovery measuring state, and second-recovery CPU
  availability;
- bounded enumeration resize/retry behavior;
- mode transitions resetting baselines and performing zero process reads in
  `menuBarOnly` and `sleeping`;
- exact `inactive` snapshots in `menuBarOnly`, plus sleeping redaction of an existing
  `MetricsSampler.latestSnapshot` without fabricating a snapshot when none exists;
- `bufferingNewest(1)` identity-bearing snapshot delivery, proving a second snapshot
  releases the first pending identity set and sleep overwrites the sole pending slot
  with a redacted value;
- direct UUID-tagged transition receipts that cannot be dropped by snapshot buffering,
  including a request superseded during a paused transition;
- a separate process-free thermal FIFO proving every real sensor sample still reaches
  notification baseline/consumption while sleep redaction emits no thermal event;
- a deterministically blocked AppModel stream/diagnostics path across sleep proving a
  queued pre-sleep visible snapshot never reintroduces names/PIDs, including wake
  before the first snapshot, wake superseding paused sleep work, and an older queued
  `.inactive` snapshot tagged with a different UUID;
- exactly one process scan per visible sampler sample, with no second timer;
- immutable snapshot atomicity and cancellation/latest-mode-wins behavior;
- UI states for initial/no-snapshot, stale, measuring, available, unavailable,
  truncated visual names, full accessibility labels, diagnostics plus rankings,
  retention of warning rows, and absence only of healthy **Dane są aktualne**;
- a content-size change scheduling exactly one non-recursive current-frame clamp, plus
  enlarged-window clamping on current, disconnected, negative-origin, and small visible
  screen frames.

Live verification on the exact target requires:

- rankings that plausibly match Activity Monitor during a controlled CPU and memory
  load, allowing for sampling-time differences;
- process-list reads only while the panel is visible;
- a ten-minute visible run with ThermoBar mean CPU at or below 1.0%, no upward RSS
  growth above the existing 5 MiB budget, and nominal thermal state before and after;
- the existing complete sensor-read Release p95 budget remaining green;
- strict-concurrency Debug tests, Release tests/build, Thread Sanitizer tests, bundle
  packaging/signature verification, security self-test and exact-PID audit, localization
  validation, and `git diff --check` all passing.

Do not install, commit implementation changes, or publish to GitHub when a required
test, security check, or live performance gate fails. Installation and publication
remain separately authorized actions.
