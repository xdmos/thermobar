# ThermoBar Top Resource Consumers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `sol-advisor:orchestration` with the Terra / High implementation lane. The primary session owns architecture, diff inspection, verification, and acceptance; a fresh Sol / High reviewer must return `ship` before completion is reported.

**Goal:** Replace the floating panel's healthy `Dane są aktualne` footer with compact top-three CPU and top-three physical-memory rankings, refreshed by the existing two-second visible cadence and never sampled while the panel is hidden or the Mac sleeps.

**Architecture:** Add a bounded `libproc` reader and a stateful interval calculator to `ThermoBarCore`, publish immutable ranking state in `SystemSnapshot`, integrate it into the existing serialized `MetricsSampler` actor, and render it in a dedicated SwiftUI list below retained diagnostics/freshness warnings. Extend the existing AppKit window bridge to re-clamp the current frame after content-size growth without restoring persisted geometry or creating a second sampling loop.

**Tech Stack:** Swift 6.2, macOS 27, SwiftUI, AppKit, Darwin `libproc` APIs from `libSystem`, Swift Testing, Thread Sanitizer, existing shell security verifier.

---

## Governing specification

Implement exactly:

- `docs/superpowers/specs/2026-08-13-thermobar-top-consumers-design.md`
- Approved specification plus commitment-review correction SHA-256:
  `85eb030418e53765daf84b146af44180a8ea3b10561c89adfaa73029be637657`

Do not broaden the feature beyond that document. In particular, do not add controls, history, persistence, network access, XPC, helpers, shell commands, extra timers, menu-bar rankings, or installation/publishing behavior.

## Execution boundary and file map

The current `feature/thermobar-app` worktree contains unrelated uncommitted work. Do not implement in it. Create a clean sibling worktree from the current public `origin/main`, then cherry-pick only the two approved design commits.

Expected implementation checkout: a clean sibling worktree named
`.worktrees/thermobar-top-consumers`.

Files to create:

- `Sources/ThermoBarCore/Consumers/ResourceConsumerModels.swift`
- `Sources/ThermoBarCore/Consumers/ResourceConsumerCalculator.swift`
- `Sources/ThermoBarCore/Consumers/ResourceConsumerReader.swift`
- `Sources/ThermoBarCore/Sampling/SamplingDelivery.swift`
- `Sources/ThermoBar/Views/ResourceConsumerList.swift`
- `Tests/ThermoBarCoreTests/ResourceConsumerCalculatorTests.swift`
- `Tests/ThermoBarCoreTests/ResourceConsumerReaderTests.swift`
- `Tests/ThermoBarAppTests/ResourceConsumerPresentationTests.swift`

Files to modify:

- `Sources/ThermoBarCore/Models/SystemSnapshot.swift`
- `Sources/ThermoBarCore/Sampling/MetricsSampler.swift`
- `Sources/ThermoBar/AppModel.swift`
- `Sources/ThermoBar/Views/FloatingPanelView.swift`
- `Sources/ThermoBar/Views/PreviewFixtures.swift`
- `Sources/ThermoBar/Resources/Localizable.xcstrings`
- `Sources/ThermoBar/Window/PanelWindowBridge.swift`
- `Tests/ThermoBarCoreTests/MetricsSamplerTests.swift`
- `Tests/ThermoBarAppTests/AppModelTests.swift`
- `Tests/ThermoBarAppTests/PanelFrameStoreTests.swift`
- `Scripts/verify-security.sh` only if a narrow deterministic fixture is required; do not weaken an existing rejection.

Names in product code must not contain the standalone exact identifier `Process`, because the fail-closed security audit intentionally rejects `Foundation.Process` and related subprocess APIs. Use `ResourceConsumer`, `ConsumerUsageRecord`, and similar names.

## Task 0: Isolate the implementation checkout

**Files:** None.

- [ ] Fetch the public base without altering the dirty worktree.

Run from the primary repository root:

```bash
git fetch origin main
git -C .worktrees/thermobar-app status --short --branch
```

Expected: fetch succeeds; the current dirty `feature/thermobar-app` state is only
observed, not changed.

- [ ] Create the clean feature worktree and import the approved design history.

```bash
git worktree add .worktrees/thermobar-top-consumers \
  -b feature/top-consumers origin/main
git -C .worktrees/thermobar-top-consumers cherry-pick e2c2a61 f81f773
```

Expected: both cherry-picks succeed; the new checkout contains the approved specification.

- [ ] Prove the execution checkout is clean and based on public main.

```bash
git -C .worktrees/thermobar-top-consumers status --short --branch
git -C .worktrees/thermobar-top-consumers merge-base --is-ancestor origin/main HEAD
shasum -a 256 \
  .worktrees/thermobar-top-consumers/docs/superpowers/specs/2026-08-13-thermobar-top-consumers-design.md
```

Expected: clean status, merge-base exits zero, and the specification hash is exactly
`85eb030418e53765daf84b146af44180a8ea3b10561c89adfaa73029be637657`.

## Task 1: Define immutable ranking state and interval calculation

**Files:**

- Create: `Sources/ThermoBarCore/Consumers/ResourceConsumerModels.swift`
- Create: `Sources/ThermoBarCore/Consumers/ResourceConsumerCalculator.swift`
- Create: `Tests/ThermoBarCoreTests/ResourceConsumerCalculatorTests.swift`
- Modify: `Sources/ThermoBarCore/Models/SystemSnapshot.swift`

- [ ] Write failing model/calculator tests before production code.

The tests must cover:

1. first valid reading produces CPU `.measuring` and immediate memory `.available`;
2. second reading computes `delta CPU nanoseconds / delta monotonic nanoseconds * 100`;
3. a multi-threaded result over 100% remains over 100%;
4. descending ordering and exact top-three cap;
5. ties sort by deterministic Unicode-scalar name order, then PID ascending;
6. duplicate names remain independent rows;
7. PID reuse through changed start time establishes a fresh baseline;
8. regressed counters, overflowing cumulative additions, zero elapsed time, and regressed timestamps do not emit invalid CPU rows;
9. one or two readable entries remain `.available`;
10. nil/empty whole-reading failure clears the baseline and returns both sections `.unavailable`;
11. first successful recovery returns CPU `.measuring`, second successful recovery can return CPU rows;
12. `reset()` returns both sections `.inactive` and discards baseline state.

Run:

```bash
swift test --filter ResourceConsumerCalculatorTests
```

Expected RED: compilation fails because the new ranking types and calculator do not exist.

- [ ] Add the public immutable snapshot types.

Use this contract:

```swift
public struct ResourceConsumerCPUEntry: Equatable, Sendable {
    public let pid: Int32
    public let name: String
    public let percent: Double
}

public struct ResourceConsumerMemoryEntry: Equatable, Sendable {
    public let pid: Int32
    public let name: String
    public let physicalFootprintBytes: UInt64
}

public enum ResourceConsumerSection<Row: Equatable & Sendable>: Equatable, Sendable {
    case inactive
    case measuring
    case available([Row])
    case unavailable
}

public struct ResourceConsumerMetric: Equatable, Sendable {
    public let cpu: ResourceConsumerSection<ResourceConsumerCPUEntry>
    public let memory: ResourceConsumerSection<ResourceConsumerMemoryEntry>

    public static let inactive = ResourceConsumerMetric(
        cpu: .inactive,
        memory: .inactive
    )
}
```

The calculator and production snapshot factories must never construct
`available([])`; represent no rows as `.unavailable`.

- [ ] Add internal raw-reading types and the calculator.

Use an internal input independent of Darwin so arithmetic tests are deterministic:

```swift
struct ConsumerUsageRecord: Equatable, Sendable {
    let pid: Int32
    let startTime: UInt64
    let name: String
    let cumulativeCPUTimeNanoseconds: UInt64
    let physicalFootprintBytes: UInt64
}

struct ConsumerUsageReading: Equatable, Sendable {
    let monotonicNanoseconds: UInt64
    let records: [ConsumerUsageRecord]
}

struct ResourceConsumerCalculator: Sendable {
    mutating func consume(_ reading: ConsumerUsageReading?) -> ResourceConsumerMetric
    mutating func reset() -> ResourceConsumerMetric
}
```

The baseline key is PID and the stored identity includes start time. Use checked addition/subtraction. Do not convert to `Double` until deltas are known valid. Accept only finite, nonnegative percentages. Sort by resource descending, then `name.unicodeScalars.lexicographicallyPrecedes`, then PID ascending.

- [ ] Extend `SystemSnapshot` atomically.

Add:

```swift
public let resourceConsumers: ResourceConsumerMetric
```

Add an initializer argument with default `.inactive` so existing call sites and fixtures remain source compatible until sampler integration is complete.

- [ ] Run focused and strict tests.

```bash
swift test --filter ResourceConsumerCalculatorTests
swift test -Xswiftc -strict-concurrency=complete --filter ThermoBarCoreTests
```

Expected GREEN: all calculator tests pass; no strict-concurrency warnings.

- [ ] Commit the green model/calculator slice.

```bash
git add \
  Sources/ThermoBarCore/Consumers/ResourceConsumerModels.swift \
  Sources/ThermoBarCore/Consumers/ResourceConsumerCalculator.swift \
  Sources/ThermoBarCore/Models/SystemSnapshot.swift \
  Tests/ThermoBarCoreTests/ResourceConsumerCalculatorTests.swift
git commit -m "feat: model top resource consumers"
```

## Task 2: Implement the bounded native `libproc` reader

**Files:**

- Create: `Sources/ThermoBarCore/Consumers/ResourceConsumerReader.swift`
- Create: `Tests/ThermoBarCoreTests/ResourceConsumerReaderTests.swift`

- [ ] Write failing reader tests using injected native-call seams.

Cover:

1. count query, capacity slack, and successful PID fill;
2. exactly one retry when returned count reaches capacity;
3. no second retry and a whole-reading failure if the second fill still reaches capacity;
4. negative count/fill return, excessive count, invalid PID, duplicate PID, and invalid or unterminated names;
5. per-PID `proc_pid_rusage` failure skips only that PID;
6. `proc_name` first, final `proc_pidpath` component fallback, and total name failure skip;
7. checked `ri_user_time + ri_system_time` overflow skips the affected PID;
8. zero readable records returns a valid empty reading, allowing the calculator to clear its baseline;
9. the captured monotonic timestamp belongs to the completed pass;
10. maximum allocated PID capacity remains bounded.

Run:

```bash
swift test --filter ResourceConsumerReaderTests
```

Expected RED: compilation fails because `ResourceConsumerReader` and its dependency seam do not exist.

- [ ] Implement a stateless, bounded reader.

Use an internal dependency struct with `@Sendable` closures for count, fill, usage, short name, path, and monotonic clock. Keep the live public/internal initializer parameterless.

Recommended bounds:

```swift
static let minimumPIDCapacity = 64
static let PIDCapacitySlack = 64
static let maximumPIDCapacity = 32_768
```

The exact live bridges are:

```swift
proc_listallpids(nil, 0)

pids.withUnsafeMutableBytes { buffer in
    proc_listallpids(buffer.baseAddress, Int32(buffer.count))
}

withUnsafeMutablePointer(to: &info) { pointer in
    pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
        proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
    }
}

proc_name(pid, buffer.baseAddress, UInt32(buffer.count))
proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
```

Import `Darwin`, not `Foundation.Process`. No new package dependency or linker setting is required because these symbols are in `libSystem`.

Map `rusage_info_v4.ri_user_time` and `.ri_system_time` into the checked cumulative
CPU nanoseconds, `.ri_phys_footprint` into physical-footprint bytes, and
`.ri_proc_start_abstime` into the PID-reuse identity. Do not substitute resident size
or a wall-clock launch date.

Treat per-PID disappearance/permission failures as normal omissions. Deduplicate PIDs before resource reads. Require positive PIDs, terminated UTF-8 strings, a finite bounded buffer length, and checked CPU-time addition.

- [ ] Run focused, strict, and live-smoke tests.

```bash
swift test --filter ResourceConsumerReaderTests
swift test -Xswiftc -strict-concurrency=complete --filter ThermoBarCoreTests
swift test --filter ResourceConsumerReaderLiveTests
```

Expected: deterministic tests pass. If an opt-in live test is used, it must assert only safe invariants—at least one readable record, unique positive PIDs, nonempty names, and no crash—not exact host values.

- [ ] Verify binary linkage remains system-only.

```bash
swift build -c release
otool -L "$(swift build -c release --show-bin-path)/ThermoBar"
```

Expected: no new non-system linked library.

- [ ] Commit the reader slice.

```bash
git add \
  Sources/ThermoBarCore/Consumers/ResourceConsumerReader.swift \
  Tests/ThermoBarCoreTests/ResourceConsumerReaderTests.swift
git commit -m "feat: read native resource consumers"
```

## Task 3: Integrate rankings into the single sampler cadence

**Files:**

- Create: `Sources/ThermoBarCore/Sampling/SamplingDelivery.swift`
- Modify: `Sources/ThermoBarCore/Sampling/MetricsSampler.swift`
- Modify: `Sources/ThermoBar/AppModel.swift`
- Modify: `Tests/ThermoBarCoreTests/MetricsSamplerTests.swift`
- Modify: `Tests/ThermoBarAppTests/AppModelTests.swift`

- [ ] Add failing sampler tests before changing the actor.

Add deterministic tests for:

1. one and only one consumer read during each `.visible` sample;
2. immediate visible snapshot has memory rows and CPU `.measuring`;
3. the next two-second cadence can publish CPU rows;
4. `.menuBarOnly` performs zero consumer API calls and publishes both sections `.inactive`;
5. `.sleeping` performs zero consumer API calls, clears the baseline, replaces an
   existing `latestSnapshot` consumer state with `.inactive`, and emits a matching
   redacted newest-buffer value without fabricating a sensor snapshot when none exists;
6. visible → menuBarOnly → visible begins CPU at `.measuring` again;
7. visible → sleeping → visible begins CPU at `.measuring` again;
8. enumeration failure publishes both sections `.unavailable`, clears the baseline, and recovers measuring-then-available;
9. concurrent/latest-mode-wins transition cannot publish a visible result after a hidden/sleeping intent;
10. the snapshot stream receives system metrics and resource rankings in one immutable
    tagged value, never as separate metric yields;
11. `bufferingNewest(1)` retains at most one undelivered identity-bearing snapshot;
    a newer visible sample releases the older value and sleep replaces the sole pending
    value with a redacted snapshot;
12. sleeping before any first snapshot leaves `latestSnapshot` absent and returns its
    exact direct UUID-tagged transition receipt without fabricating a snapshot;
13. AppModel synchronously redacts its current snapshot at `.willSleep` before the
    sampler await and records the sleep UUID;
14. a deterministic diagnostics/stream suspension queues a pre-sleep visible
    snapshot; after sleep intent it is consumer-redacted and cannot reintroduce names
    or PIDs because only the current active UUID is accepted;
15. sleep/wake before the first snapshot, wake superseding paused sleep work, and an
    older queued menu-bar `.inactive` snapshot tagged with another UUID cannot restore
    identities or leave AppModel permanently redacted;
16. a blocked snapshot consumer does not drop any lightweight thermal samples, each
    real thermal sample reaches notification baseline/consumption in FIFO order, and a
    sleep redaction produces no thermal sample;
17. deinit/cancellation finishes both streams, clears the calculator, and does not
    create a second timer/task.

Run:

```bash
swift test --filter MetricsSamplerTests
```

Expected RED: the dependency and snapshot behavior are absent.

- [ ] Add bounded snapshot delivery, lossless thermal delivery, and direct receipts.

Create:

```swift
import Foundation

public struct SamplingSnapshot: Equatable, Sendable {
    public let value: SystemSnapshot
    public let transitionID: UUID
}

public struct ThermalSample: Equatable, Sendable {
    public let level: ThermalLevel
    public let monotonicNanoseconds: UInt64
}

public struct SamplingTransitionReceipt: Equatable, Sendable {
    public let requestedTransitionID: UUID
    public let currentTransitionID: UUID
    public let currentMode: SamplingMode
    public let isCurrent: Bool
}
```

Change `snapshots()` to `AsyncStream<SamplingSnapshot>` created with
`.bufferingNewest(1)`. Add a separate `thermalSamples() -> AsyncStream<ThermalSample>`
that carries no process names, PIDs, or usage. Add
`setMode(_:transitionID:) -> SamplingTransitionReceipt` and retain a convenience
`setMode(_:)` only where existing non-AppModel callers require it. AppModel always
creates and supplies a fresh UUID. Do not use `UInt64`, `&+=`, section state, or
timestamps as transition identity.

- [ ] Extend sampler dependencies without breaking existing fixtures.

Add:

```swift
let consumerUsage: @Sendable () -> ConsumerUsageReading?
```

Give test-only dependency initialization a default `{ nil }` so older focused fixtures compile while tests migrate. The live initializer supplies:

```swift
consumerUsage: { ResourceConsumerReader().read() }
```

The actor owns one `ResourceConsumerCalculator` value.

- [ ] Integrate with the existing serialized `sample()` only.

Rules:

- `.visible`: invoke `consumerUsage()` exactly once, then call the calculator once;
- `.menuBarOnly`: never invoke it; reset the calculator and publish `.inactive`;
- `.sleeping`: reset when mode changes, close existing resources as before, and do
  not run a sensor/process sample or cadence. Before the transition's first `await`,
  assign the requested mode/UUID, reset the consumer calculator, redact consumer state
  in `latestSnapshot` when it exists, and yield that redacted value tagged with the
  sleep UUID so `.bufferingNewest(1)` replaces any pending identity value. When no
  snapshot exists, do not fabricate one;
- build `SystemSnapshot` once after every source has completed;
- tag each real snapshot with the exact active transition UUID that produced it;
- return the direct transition receipt after reconciliation, reporting whether that
  request remains current if a newer request superseded it;
- yield one lightweight `ThermalSample` for every real sensor snapshot, but never for
  a sleep redaction replacement;
- keep consumer availability independent of `SamplingDiagnostic` and thermal notifications;
- preserve existing two-second visible and ten-second menu-bar-only cadence values.

Reset the calculator synchronously at the same transition boundary that resets CPU interval state. Re-check the winning mode before publishing the completed snapshot.

In `AppModel`, synchronously replace locally held consumer sections with `.inactive`
at the start of `.willSleep`, generate/store the sleep UUID, and call the explicit
transition API. While sleeping, sanitize every received snapshot before any awaited
diagnostics work. Wake generates/stores a different active UUID; accept consumer
identities only from snapshots tagged with that exact active UUID. Older menu-bar,
visible, or sleep values remain redacted. Move notification baseline/consumption to a
separate task over `thermalSamples()` so snapshot coalescing cannot drop thermal
transitions and sleep redaction cannot retrigger notifications.

- [ ] Run focused concurrency tests and Thread Sanitizer.

```bash
swift test -Xswiftc -strict-concurrency=complete --filter MetricsSamplerTests
swift test --sanitize=thread --filter MetricsSamplerTests
```

Expected GREEN: all tests pass with no race report and no strict-concurrency warning.

- [ ] Commit the sampler integration.

```bash
git add \
  Sources/ThermoBarCore/Sampling/SamplingDelivery.swift \
  Sources/ThermoBarCore/Sampling/MetricsSampler.swift \
  Sources/ThermoBar/AppModel.swift \
  Tests/ThermoBarCoreTests/MetricsSamplerTests.swift \
  Tests/ThermoBarAppTests/AppModelTests.swift
git commit -m "feat: sample resource consumers when visible"
```

## Task 4: Build deterministic presentation and the two ranking lists

**Files:**

- Create: `Sources/ThermoBar/Views/ResourceConsumerList.swift`
- Create: `Tests/ThermoBarAppTests/ResourceConsumerPresentationTests.swift`
- Modify: `Sources/ThermoBar/Views/FloatingPanelView.swift`
- Modify: `Sources/ThermoBar/Views/PreviewFixtures.swift`
- Modify: `Sources/ThermoBar/Resources/Localizable.xcstrings`

- [ ] Write failing pure presentation tests first.

Test a non-View presentation helper for:

1. CPU whole-number formatting with no upper clamp (`237%` remains `237%`);
2. binary memory formatting with at most one locale-aware fraction (`620 MB`, Polish `1,8 GB`);
3. `.measuring` → `Pomiar…`;
4. `.unavailable` → `Brak dostępnych danych`;
5. `.inactive` does not produce visible ranking rows;
6. full, untruncated accessibility labels containing rank, full name, resource type, and formatted value;
7. available one/two/three rows retain their supplied deterministic order;
8. a long visual name uses tail truncation while the accessibility string remains complete.

Run:

```bash
swift test --filter ResourceConsumerPresentationTests
```

Expected RED: the presentation helper and list component are missing.

- [ ] Add localized copy.

Add English and Polish values for these keys:

```text
consumer.cpu-title        Najwięcej CPU
consumer.memory-title     Najwięcej RAM
consumer.measuring        Pomiar…
consumer.unavailable      Brak dostępnych danych
consumer.cpu-accessibility
consumer.memory-accessibility
```

Use `LocalizedStringResource(..., bundle: #bundle)` through the existing `ThermoBarCopy` pattern. Do not put PID or names into localization keys, logs, or accessibility identifiers.

- [ ] Implement `ResourceConsumerPresentation` and `ResourceConsumerList`.

The list must use:

- compact caption titles;
- a muted fixed-width rank column;
- one-line tail-truncated name;
- a trailing monospaced value column;
- separate CPU and memory sections, CPU first;
- existing panel color/typography conventions;
- no controls, buttons, links, or hover detail.

Keep the panel width exactly `238` points. Allow height to grow naturally.

- [ ] Replace only the healthy freshness footer.

Refactor `FloatingPanelContent.footer` into a `VStack` with exact precedence:

1. persistent/unsupported sensor diagnostic, when present;
2. otherwise the current no-snapshot or stale freshness warning;
3. omit only the current healthy `Dane są aktualne` row;
4. render the consumer lists below any retained warning.

Before the first snapshot, show the existing no-snapshot warning, CPU `Pomiar…`, and memory `Brak dostępnych danych`. A stale snapshot keeps its stale warning and still shows the ranking state carried by that immutable snapshot.

- [ ] Add preview fixtures for every state.

Add previews/fixtures for:

- initial no snapshot;
- CPU measuring + memory available;
- both available with long/duplicate names and CPU over 100%;
- both unavailable;
- stale + rankings;
- sensor diagnostic + rankings;
- increased contrast, reduced motion, and large Dynamic Type.

- [ ] Run focused UI tests and validate the string catalog.

```bash
swift test -Xswiftc -strict-concurrency=complete --filter ResourceConsumerPresentationTests
jq empty Sources/ThermoBar/Resources/Localizable.xcstrings
swift build
```

Expected GREEN: all tests pass, catalog JSON is valid, and the app target builds without warnings.

- [ ] Commit the presentation slice.

```bash
git add \
  Sources/ThermoBar/Views/ResourceConsumerList.swift \
  Sources/ThermoBar/Views/FloatingPanelView.swift \
  Sources/ThermoBar/Views/PreviewFixtures.swift \
  Sources/ThermoBar/Resources/Localizable.xcstrings \
  Tests/ThermoBarAppTests/ResourceConsumerPresentationTests.swift
git commit -m "feat: show top resource consumers"
```

## Task 5: Re-clamp the window after content-size growth

**Files:**

- Modify: `Sources/ThermoBar/Window/PanelWindowBridge.swift`
- Modify: `Tests/ThermoBarAppTests/PanelFrameStoreTests.swift`

- [ ] Write failing bridge lifecycle tests.

Cover:

1. an installed content-view size change schedules exactly one next-main-turn current-frame clamp;
2. multiple notifications before the scheduled turn coalesce;
3. the programmatic correction does not save geometry as a user move;
4. the correction does not recursively schedule itself forever;
5. it clamps against current screen geometry and never calls persisted `restoreFrame()`;
6. enlarged frames clamp on current, disconnected, negative-origin, and small visible screens using the existing 12-point inset;
7. switching windows, uninstall, and dismantle remove the observer and cancel/ignore stale scheduled work;
8. the original `postsFrameChangedNotifications` value and delegate forwarding are restored;
9. opacity and native background dragging behavior remain unchanged.

Run:

```bash
swift test --filter PanelFrameStoreTests
```

Expected RED: no content-frame observer or coalesced clamp exists.

- [ ] Observe the installed content view safely.

During install:

- retain a weak reference to the observed content view;
- save its original `postsFrameChangedNotifications` value;
- enable frame-change notifications;
- observe `NSView.frameDidChangeNotification` for that exact object;
- track the last content size;
- coalesce a next-main-turn clamp using the existing installation generation.

During switch/uninstall/dismantle:

- remove the exact observer;
- restore the original notification flag;
- invalidate queued work through generation/state guards;
- leave delegate restoration and opacity restoration intact.

- [ ] Clamp only the current frame.

On a genuine size change, calculate screens using the same display identifier and visible-frame mapping as screen-topology handling, then call:

```swift
PanelFrameStore.clamp(window.frame, screens: currentScreens)
```

Apply through the existing `isApplyingProgrammaticFrame` path. Do not read persisted launch geometry. Update the remembered content size before applying the correction so the resulting frame notification cannot re-arm itself.

- [ ] Run focused tests, TSan, and app builds.

```bash
swift test -Xswiftc -strict-concurrency=complete --filter PanelFrameStoreTests
swift test --sanitize=thread --filter ThermoBarAppTests
swift build
swift build -c release
```

Expected GREEN: tests pass, no race report, no warnings.

- [ ] Commit the bridge slice.

```bash
git add \
  Sources/ThermoBar/Window/PanelWindowBridge.swift \
  Tests/ThermoBarAppTests/PanelFrameStoreTests.swift
git commit -m "fix: clamp panel after content growth"
```

## Task 6: Preserve the fail-closed security boundary

**Files:**

- Modify only if necessary: `Scripts/verify-security.sh`

- [ ] Run the existing audit before modifying it.

```bash
THERMOBAR_SECURITY_SELF_TEST=1 Scripts/verify-security.sh
```

Expected: existing prohibited-source and prohibited-symbol fixtures remain rejected.

- [ ] Inspect product source and linked symbols.

```bash
rg -n '\b(Process|NSTask)\b|posix_spawn|exec[lvpe]*\(|popen|system\(|import XPC|URLSession|NSXPC|socket\(|connect\(' \
  Sources Package.swift
nm -u "$(swift build -c release --show-bin-path)/ThermoBar" | swift demangle
```

Expected: no subprocess, shell, network, XPC, socket, or dynamic-loading use; only the intended `proc_listallpids`, `proc_pid_rusage`, `proc_name`, and `proc_pidpath` inspection symbols are new.

- [ ] Change the verifier only if the current audit falsely rejects allowed `libproc` symbols or lacks a deterministic regression proof.

If changed, add narrow self-test fixtures proving:

- `ResourceConsumerReader` and the four intended `proc_*` symbols are accepted;
- `Foundation.Process`, `NSTask`, `posix_spawnp`, `Darwin.system`, URLSession, NSXPC, sockets, and unexpected dylibs remain rejected.

Do not add a broad `proc_` allowlist and do not suppress the existing raw/demangled symbol scan.

- [ ] Run the self-test and built-app audit.

```bash
THERMOBAR_SECURITY_SELF_TEST=1 Scripts/verify-security.sh
Scripts/build-app.sh
Scripts/verify-security.sh build/ThermoBar.app
```

Expected: the self-test and static built-bundle audit pass; the bundle has no new
entitlement or non-system linked library. The exact-running-PID audit is performed in
Task 8 after launching this exact bundle.

- [ ] Commit only if the verifier changed.

```bash
git add Scripts/verify-security.sh
git commit -m "test: preserve resource inspection security gate"
```

If no change is needed, record that decision in the implementation report and create no empty commit.

## Task 7: Complete automated verification

**Files:** All accumulated in-scope files; no new product scope.

- [ ] Run the complete strict Debug suite.

```bash
swift test -Xswiftc -strict-concurrency=complete
```

Expected: all non-opt-in tests pass; only explicitly documented live/performance tests may skip.

- [ ] Run Release tests and builds.

```bash
swift test -c release -Xswiftc -strict-concurrency=complete
swift build -Xswiftc -strict-concurrency=complete
swift build -c release -Xswiftc -strict-concurrency=complete
```

Expected: all pass without warnings.

- [ ] Run Thread Sanitizer.

```bash
swift test --sanitize=thread
```

Expected: all tests pass and no sanitizer report appears.

- [ ] Package and inspect the app.

```bash
Scripts/build-app.sh
codesign --verify --deep --strict --verbose=2 build/ThermoBar.app
codesign -d --entitlements :- build/ThermoBar.app 2>/dev/null
otool -L build/ThermoBar.app/Contents/MacOS/ThermoBar
jq empty Sources/ThermoBar/Resources/Localizable.xcstrings
git diff --check
```

Expected: valid signature, unchanged empty entitlements, system-only libraries, valid catalog, and clean diff formatting.

- [ ] Verify scope and history before live testing.

```bash
git status --short --branch
git diff --stat origin/main...HEAD
git diff --name-only origin/main...HEAD
```

Expected: only the specification, plan, and files listed in this plan are changed.

## Task 8: Perform exact-target live and performance acceptance

**Files:** Evidence under ignored `build/verification/` only; do not commit host/process data.

- [ ] Confirm the exact target and preconditions.

Record model, build, power, thermal state, current branch/head, and clean status. Do not include process names/PIDs in committed files or logs.

- [ ] Verify ranking plausibility under controlled load.

Run the packaged app, show the panel, and create one bounded CPU load and one bounded memory load using already-authorized local test tooling outside product code. Compare the top-three order to Activity Monitor at approximately the same moment.

Acceptance: values need not match exactly because sampling times differ, but the controlled workload must plausibly appear in the corresponding ranking; CPU may exceed 100%; the first visible interval must show `Pomiar…`.

- [ ] Verify lifecycle privacy and cadence.

Use an injected/live counter or supported system trace to prove:

- visible panel: one process enumeration per existing two-second sample;
- menu-bar-only: zero process enumeration;
- sleeping: zero process enumeration and cleared baseline;
- reshow: CPU returns to `Pomiar…` for the first interval.

Do not use product logging of names/PIDs to prove this.

- [ ] Verify window behavior manually.

Check:

- enlarged panel remains within the 12-point visible inset;
- it can still be dragged at 30% and 100% opacity;
- close/show, Spaces, full-screen auxiliary behavior, display removal, negative-origin display, and relaunch restoration remain correct;
- long names truncate visually while VoiceOver reads the complete label.

- [ ] Run the existing sensor Release performance gate.

```bash
THERMOBAR_RUN_PERFORMANCE=1 swift test -c release --filter SensorReadPerformanceTests
```

Expected: complete sensor-read p95 remains within the existing accepted threshold.

- [ ] Run a clean ten-minute visible performance sample.

Use the existing exact-PID measurement/security scripts and accepted protocol. Required gates:

- ThermoBar mean CPU `<= 1.0%`;
- upward RSS growth `<= 5 MiB` using the existing protocol;
- nominal thermal state before and after;
- exact executable/PID fingerprint remains stable;
- no listening or connected network sockets.

If any gate fails, stop. Do not install, commit additional implementation changes, or publish.

- [ ] Obtain the required fresh Sol / High final verdict.

The primary session supplies the actual base/head diff and all verification evidence to a new `sol_advisor_sol_reviewer`. The reviewer remains behaviorally read-only and returns exactly `ship`, `fix-first`, or `rethink`.

If `fix-first`, send the precise corrections to the same Terra implementation lane, rerun affected and full verification, and request a new fresh review. If `rethink`, revise architecture and return to the user. Only `ship` permits completion reporting.

## Task 9: Handoff without implicit installation or publication

**Files:** None unless the user separately authorizes delivery documentation.

- [ ] Report:

- checkout path and branch;
- exact implementation commits;
- changed-file scope;
- deterministic, strict, Release, TSan, packaging, signing, security, and live-performance evidence;
- final Sol verdict and observed reviewer sandbox/permission profile;
- any residual risk.

- [ ] Stop before installation, copying into `/Applications`, changing Login Items, committing failed evidence, or pushing to GitHub.

Those are separate external-state actions and require a new explicit user instruction.

## Final self-review checklist

Before handing this plan to an implementer, confirm:

- every approved requirement maps to a task and a test;
- no task creates a second timer, detached loop, helper process, network path, XPC path, persistence path, or new entitlement;
- CPU baseline resets on hidden/sleep/failure and first recovery measures before publishing CPU;
- memory is available on the first successful visible pass;
- `inactive`, `measuring`, `available`, and `unavailable` have distinct deterministic meanings;
- diagnostics/no-snapshot/stale warnings remain above rankings and only healthy `Dane są aktualne` disappears;
- the window width remains 238 points and content growth re-clamps the current frame only;
- no product identifier uses the standalone exact symbol `Process`;
- process names/PIDs never enter persistence, notifications, committed evidence, logs, or accessibility identifiers;
- all commits use exact path staging, never `git add -A`, because other worktrees may remain dirty.
