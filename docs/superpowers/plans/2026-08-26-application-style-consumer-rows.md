# Application-Style Consumer Rows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render the Process and RAM consumer sections as polished application rows with real icons, system-wide summaries, and buttons that open Activity Monitor.

**Architecture:** ThermoBarCore carries only a validated optional icon path alongside each process identity and propagates it through the existing calculator. The ThermoBar target owns one main-actor icon cache and one Activity Monitor launcher, then injects them through the floating-panel hierarchy into a redesigned `ResourceConsumerList`. Existing sampling, ranking, memory aggregation, and five-row limits remain unchanged.

**Tech Stack:** Swift 6.2, SwiftUI, AppKit (`NSWorkspace`, `NSImage`, `NSCache`), Swift Testing, Swift Package Manager, macOS 27.

**Spec:** `docs/superpowers/specs/2026-08-26-resource-consumer-card-layout-design.md`

## Global Constraints

- Keep the panel width exactly `260` points and its horizontal padding at `14` points per side.
- Keep at most five Process rows and five RAM rows.
- Keep Process ranking by descending `max(CPU, GPU)` and keep existing tie-breakers.
- Keep RAM aggregation by application/executable group.
- Remove only the visible rank numbers; preserve rank in VoiceOver labels.
- Process summary is `CPU <system value> · GPU <system value>`; RAM summary is the system memory percentage.
- Every action button only opens `/System/Applications/Utilities/Activity Monitor.app`; it never selects or filters a PID.
- `ThermoBarCore` must not import AppKit or carry `NSImage`.
- The `NSImage` cache is `@MainActor`, non-`Sendable`, owned once by `ThermoBarApp`, and passed explicitly to the list.
- Icon conflicts make only RAM unavailable for that sample; Process output and CPU/GPU baselines continue normally.
- Cap the consumer list at Dynamic Type `xxxLarge`; cap icon size at `26` points and preserve one-line numeric/action columns.
- Add no network access, subprocess, entitlement, dependency, telemetry, process termination, or fan control.
- Preserve the existing untracked `.superpowers/` directory and unrelated user changes.

---

## File Map

**Create:**

- `Sources/ThermoBar/Services/ApplicationIconStore.swift` — main-actor `NSWorkspace` icon lookup and stable `NSCache`.
- `Sources/ThermoBar/Services/ActivityMonitorLauncher.swift` — one injected, testable action that opens Activity Monitor.
- `Tests/ThermoBarAppTests/ApplicationIconStoreTests.swift` — cache, missing-path, and main-actor behavior.
- `Tests/ThermoBarAppTests/ActivityMonitorLauncherTests.swift` — exact system application URL and one-call behavior.

**Modify:**

- `Sources/ThermoBarCore/Consumers/ResourceConsumerModels.swift` — optional `iconPath` on public consumer rows.
- `Sources/ThermoBarCore/Consumers/ResourceConsumerReader.swift` — validated outer app/executable icon path in process identity.
- `Sources/ThermoBarCore/Consumers/ResourceConsumerCalculator.swift` — path propagation and RAM-only icon-conflict handling.
- `Tests/ThermoBarCoreTests/ResourceConsumerReaderTests.swift` — app, executable, fallback, and identity-change path contracts.
- `Tests/ThermoBarCoreTests/ResourceConsumerCalculatorTests.swift` — propagation, conflict isolation, baseline continuation, recovery.
- `Sources/ThermoBar/Views/ResourceConsumerList.swift` — variant-A headers, icons, rows, buttons, layout budget, accessibility.
- `Sources/ThermoBar/Views/FloatingPanelView.swift` — summary values and dependency forwarding.
- `Sources/ThermoBar/Views/PreviewFixtures.swift` — representative icon paths for visual previews.
- `Sources/ThermoBar/ThermoBarApp.swift` — stable ownership and production injection of both AppKit services.
- `Sources/ThermoBar/Resources/Localizable.xcstrings` — localized Activity Monitor button label/help.
- `Tests/ThermoBarAppTests/ResourceConsumerPresentationTests.swift` — summaries, accessibility copy, and 260-point layout budget.

---

### Task 1: Carry Validated Icon Identity Through the Reader

**Files:**

- Modify: `Sources/ThermoBarCore/Consumers/ResourceConsumerModels.swift:1-14`
- Modify: `Sources/ThermoBarCore/Consumers/ResourceConsumerReader.swift:33-43,66-82,101-131`
- Modify: `Sources/ThermoBarCore/Consumers/ResourceConsumerCalculator.swift:3-12`
- Test: `Tests/ThermoBarCoreTests/ResourceConsumerReaderTests.swift:96-132`

**Interfaces:**

- Produces: `ResourceConsumerCPUEntry.iconPath: String?`
- Produces: `ResourceConsumerMemoryEntry.iconPath: String?`
- Produces: `ConsumerUsageRecord.iconPath: String?`
- Preserves: existing public initializers through `iconPath: String? = nil`

- [ ] **Step 1: Write failing reader tests for app, executable, and fallback paths**

Update the existing nested-helper test and add two focused expectations:

```swift
@Test func readerUsesOutermostAppBundleAndLexicallyNormalizesNestedHelpers() {
    let reader = ResourceConsumerReader(dependencies: .init(
        count: { 1 },
        fill: { pointer, _ in pointer!.assumingMemoryBound(to: Int32.self)[0] = 42; return 1 },
        usage: { _ in .init(user: 2, system: 3, footprint: 4, startTime: 5) },
        shortName: { _ in "ignored" },
        path: { _ in "/Applications/./Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/../MacOS/Google Chrome Helper" },
        clock: { 99 }
    ))

    #expect(reader.read()?.records == [
        .init(
            pid: 42,
            startTime: 5,
            groupID: "app:/Applications/Google Chrome.app",
            name: "Google Chrome",
            processName: "Google Chrome Helper",
            iconPath: "/Applications/Google Chrome.app",
            cumulativeCPUTimeNanoseconds: 5,
            physicalFootprintBytes: 4
        )
    ])
}

@Test func readerUsesNormalizedExecutableAsItsIconPath() {
    let reader = ResourceConsumerReader(dependencies: .init(
        count: { 1 },
        fill: { pointer, _ in pointer!.assumingMemoryBound(to: Int32.self)[0] = 7; return 1 },
        usage: { _ in .init(user: 1, system: 2, footprint: 3, startTime: 4) },
        shortName: { _ in "ignored" },
        path: { _ in "/usr/local/../local/bin/worker" },
        clock: { 8 }
    ))

    #expect(reader.read()?.records.first?.iconPath == "/usr/local/bin/worker")
}

@Test func readerFallbackIdentityHasNoIconPath() {
    let reader = ResourceConsumerReader(dependencies: .init(
        count: { 1 },
        fill: { pointer, _ in pointer!.assumingMemoryBound(to: Int32.self)[0] = 9; return 1 },
        usage: { _ in .init(user: 1, system: 2, footprint: 3, startTime: 4) },
        shortName: { _ in "worker" },
        path: { _ in nil },
        clock: { 8 }
    ))

    #expect(reader.read()?.records.first?.iconPath == nil)
}
```

- [ ] **Step 2: Run the reader tests and verify RED**

Run:

```bash
swift test -Xswiftc -strict-concurrency=complete --filter 'readerUsesOutermostAppBundleAndLexicallyNormalizesNestedHelpers|readerUsesNormalizedExecutableAsItsIconPath|readerFallbackIdentityHasNoIconPath'
```

Expected: compilation fails because `ConsumerUsageRecord` and public entries do not accept or expose `iconPath`.

- [ ] **Step 3: Add optional icon paths to the models**

Add the same optional property and source-compatible default to both public rows:

```swift
public let iconPath: String?

public init(
    pid: Int32,
    name: String,
    percent: Double,
    gpuPercent: Double? = nil,
    iconPath: String? = nil
) {
    self.pid = pid
    self.name = name
    self.percent = percent
    self.gpuPercent = gpuPercent
    self.iconPath = iconPath
}
```

For `ResourceConsumerMemoryEntry`, use the parameter order:

```swift
public init(
    pid: Int32,
    name: String,
    physicalFootprintBytes: UInt64,
    iconPath: String? = nil
)
```

Extend the internal usage record in `ResourceConsumerCalculator.swift`:

```swift
let iconPath: String?

init(
    pid: Int32,
    startTime: UInt64,
    groupID: String,
    name: String,
    processName: String? = nil,
    iconPath: String? = nil,
    cumulativeCPUTimeNanoseconds: UInt64,
    physicalFootprintBytes: UInt64,
    cumulativeGPUTimeNanoseconds: UInt64? = nil
) {
    self.pid = pid
    self.startTime = startTime
    self.groupID = groupID
    self.name = name
    self.processName = processName ?? name
    self.iconPath = iconPath
    self.cumulativeCPUTimeNanoseconds = cumulativeCPUTimeNanoseconds
    self.physicalFootprintBytes = physicalFootprintBytes
    self.cumulativeGPUTimeNanoseconds = cumulativeGPUTimeNanoseconds
}
```

- [ ] **Step 4: Resolve and validate the icon path with process identity**

Change `Identity` so `resolved` always returns an icon path field:

```swift
private enum Identity: Equatable, Sendable {
    case path(groupID: String, name: String, processName: String, iconPath: String)
    case fallback(name: String)

    func resolved(pid: Int32, startTime: UInt64) -> (
        groupID: String,
        name: String,
        processName: String,
        iconPath: String?
    ) {
        switch self {
        case let .path(groupID, name, processName, iconPath):
            (groupID, name, processName, iconPath)
        case let .fallback(name):
            ("pid:\(pid):\(startTime)", name, name, nil)
        }
    }
}
```

For an app path, return the outermost app bundle as both the group identity suffix and icon path. For an executable, return the normalized executable:

```swift
let appPath = "/" + components.prefix(through: appIndex).joined(separator: "/")
return .path(
    groupID: "app:\(appPath)",
    name: displayName,
    processName: String(filename),
    iconPath: appPath
)

return .path(
    groupID: "exe:\(normalized)",
    name: String(filename),
    processName: String(filename),
    iconPath: normalized
)
```

Include `beforeResolved.iconPath == afterResolved.iconPath` in the existing identity guard, then pass `iconPath: beforeResolved.iconPath` into `ConsumerUsageRecord`.

Extend the existing live-reader assertion so a present icon path must remain absolute:

```swift
#expect(reading.records.allSatisfy { record in
    record.iconPath == nil || record.iconPath?.first == "/"
})
```

- [ ] **Step 5: Run focused and full Core tests**

Run:

```bash
swift test -Xswiftc -strict-concurrency=complete --filter 'readerUsesOutermostAppBundleAndLexicallyNormalizesNestedHelpers|readerUsesNormalizedExecutableAsItsIconPath|readerFallbackIdentityHasNoIconPath'
swift test -Xswiftc -strict-concurrency=complete
```

Expected: reader tests pass; existing callers compile unchanged because all new initializer parameters default to `nil`.

- [ ] **Step 6: Commit Task 1**

```bash
git add Sources/ThermoBarCore/Consumers/ResourceConsumerModels.swift Sources/ThermoBarCore/Consumers/ResourceConsumerReader.swift Sources/ThermoBarCore/Consumers/ResourceConsumerCalculator.swift Tests/ThermoBarCoreTests/ResourceConsumerReaderTests.swift
git commit -m "Carry application icon paths with consumer identity"
```

---

### Task 2: Propagate Icons and Isolate RAM Icon Conflicts

**Files:**

- Modify: `Sources/ThermoBarCore/Consumers/ResourceConsumerCalculator.swift:3-90`
- Test: `Tests/ThermoBarCoreTests/ResourceConsumerCalculatorTests.swift:75-160,189`

**Interfaces:**

- Consumes: `ConsumerUsageRecord.iconPath: String?` from Task 1
- Produces: CPU and RAM rows carrying their originating `iconPath`
- Produces: RAM-only `.unavailable` on same-group icon conflicts while CPU baselines advance

- [ ] **Step 1: Extend the test record helper and write the conflict/recovery test**

Replace the helper with an icon-aware initializer:

```swift
private func record(
    _ pid: Int32,
    _ name: String,
    _ cpu: UInt64,
    _ memory: UInt64,
    gpu: UInt64? = nil,
    start: UInt64 = 1,
    group: String? = nil,
    processName: String? = nil,
    iconPath: String? = nil
) -> ConsumerUsageRecord {
    .init(
        pid: pid,
        startTime: start,
        groupID: group ?? "pid:\(pid):\(start)",
        name: name,
        processName: processName,
        iconPath: iconPath,
        cumulativeCPUTimeNanoseconds: cpu,
        physicalFootprintBytes: memory,
        cumulativeGPUTimeNanoseconds: gpu
    )
}
```

Add this behavior test:

```swift
@Test func iconConflictOnlyInvalidatesRAMWhileComputeBaselinesAdvanceAndRAMRecovers() {
    var calculator = ResourceConsumerCalculator()
    let group = "app:/Applications/Same.app"

    let first = calculator.consume(.init(monotonicNanoseconds: 100, records: [
        record(1, "Same", 10, 30, group: group, processName: "One", iconPath: "/Applications/Same.app"),
        record(2, "Same", 20, 40, group: group, processName: "Two", iconPath: "/Applications/Other.app")
    ]))
    #expect(first.cpu == .measuring)
    #expect(first.memory == .unavailable)

    let second = calculator.consume(.init(monotonicNanoseconds: 200, records: [
        record(1, "Same", 110, 30, group: group, processName: "One", iconPath: "/Applications/Same.app"),
        record(2, "Same", 220, 40, group: group, processName: "Two", iconPath: "/Applications/Other.app")
    ]))
    #expect(second.memory == .unavailable)
    #expect(second.cpu == .available([
        .init(pid: 2, name: "Two", percent: 200, iconPath: "/Applications/Other.app"),
        .init(pid: 1, name: "One", percent: 100, iconPath: "/Applications/Same.app")
    ]))

    let third = calculator.consume(.init(monotonicNanoseconds: 300, records: [
        record(1, "Same", 210, 30, group: group, processName: "One", iconPath: "/Applications/Same.app"),
        record(2, "Same", 320, 40, group: group, processName: "Two", iconPath: "/Applications/Same.app")
    ]))
    #expect(third.memory == .available([
        .init(pid: 1, name: "Same", physicalFootprintBytes: 70, iconPath: "/Applications/Same.app")
    ]))
    #expect(third.cpu != .measuring)
}
```

- [ ] **Step 2: Run the calculator test and verify RED**

Run:

```bash
swift test -Xswiftc -strict-concurrency=complete --filter iconConflictOnlyInvalidatesRAMWhileComputeBaselinesAdvanceAndRAMRecovers
```

Expected: the test fails because aggregates and output rows do not yet propagate or compare `iconPath`.

- [ ] **Step 3: Propagate icon identity through aggregation and CPU rows**

Extend `Aggregate`:

```swift
private struct Aggregate: Sendable {
    let groupID: String
    let name: String
    let iconPath: String?
    var representativePID: Int32
    var value: UInt64
}
```

When merging an existing group, fail only the memory aggregation on an icon mismatch:

```swift
guard existing.name == record.name, existing.iconPath == record.iconPath else {
    return nil
}
```

Initialize new aggregates with `iconPath: record.iconPath`. Build output rows with:

```swift
return .init(
    pid: record.pid,
    name: record.processName,
    percent: percent,
    gpuPercent: gpuPercentByPID[record.pid],
    iconPath: record.iconPath
)
```

and:

```swift
private static func memoryEntry(_ group: Aggregate) -> ResourceConsumerMemoryEntry {
    .init(
        pid: group.representativePID,
        name: group.name,
        physicalFootprintBytes: group.value,
        iconPath: group.iconPath
    )
}
```

Do not add `iconPath` to `Baseline`: app and executable paths are already part of `groupID`, fallback paths are `nil`, and the reader rejects before/after identity changes.

- [ ] **Step 4: Update the existing Chrome aggregation expectation**

Give both Chrome records `iconPath: "/Applications/Google Chrome.app"`, give ChatGPT its own path, and assert those paths on both Process and RAM entries. Keep the existing PID order and CPU/GPU values unchanged.

- [ ] **Step 5: Run focused and full tests**

Run:

```bash
swift test -Xswiftc -strict-concurrency=complete --filter 'calculator|iconConflictOnlyInvalidatesRAMWhileComputeBaselinesAdvanceAndRAMRecovers'
swift test -Xswiftc -strict-concurrency=complete
```

Expected: all tests pass; the existing five-row and ranking tests retain their current order.

- [ ] **Step 6: Commit Task 2**

```bash
git add Sources/ThermoBarCore/Consumers/ResourceConsumerCalculator.swift Tests/ThermoBarCoreTests/ResourceConsumerCalculatorTests.swift
git commit -m "Propagate consumer icon paths through rankings"
```

---

### Task 3: Add Main-Actor AppKit Services

**Files:**

- Create: `Sources/ThermoBar/Services/ApplicationIconStore.swift`
- Create: `Sources/ThermoBar/Services/ActivityMonitorLauncher.swift`
- Create: `Tests/ThermoBarAppTests/ApplicationIconStoreTests.swift`
- Create: `Tests/ThermoBarAppTests/ActivityMonitorLauncherTests.swift`

**Interfaces:**

- Produces: `@MainActor protocol ApplicationIconProviding: AnyObject`
- Produces: `ApplicationIconStore.icon(for path: String?) -> NSImage?`
- Produces: `ActivityMonitorLauncher.open()`
- Produces: `ActivityMonitorLauncher.applicationURL`

- [ ] **Step 1: Write failing service tests**

Create `ApplicationIconStoreTests.swift`:

```swift
import AppKit
import Testing
@testable import ThermoBar

@Test @MainActor
func applicationIconStoreCachesOneWorkspaceLookupPerExistingPath() {
    var loads = 0
    let expected = NSImage(size: NSSize(width: 16, height: 16))
    let store = ApplicationIconStore(
        fileExists: { $0 == "/Applications/Test.app" },
        loadIcon: { _ in loads += 1; return expected }
    )

    let first = store.icon(for: "/Applications/Test.app")
    let second = store.icon(for: "/Applications/Test.app")

    #expect(first === expected)
    #expect(second === expected)
    #expect(loads == 1)
}

@Test @MainActor
func applicationIconStoreRejectsMissingEmptyAndNilPathsWithoutLoading() {
    var loads = 0
    let store = ApplicationIconStore(
        fileExists: { _ in false },
        loadIcon: { _ in loads += 1; return NSImage() }
    )

    #expect(store.icon(for: nil) == nil)
    #expect(store.icon(for: "") == nil)
    #expect(store.icon(for: "/missing") == nil)
    #expect(loads == 0)
}
```

Create `ActivityMonitorLauncherTests.swift`:

```swift
import Foundation
import Testing
@testable import ThermoBar

@Test @MainActor
func activityMonitorLauncherOpensTheExactSystemApplicationOnce() {
    var received: [URL] = []
    let launcher = ActivityMonitorLauncher(openApplication: { received.append($0) })

    launcher.open()

    #expect(received == [ActivityMonitorLauncher.applicationURL])
    #expect(received.first?.path == "/System/Applications/Utilities/Activity Monitor.app")
}
```

- [ ] **Step 2: Run the service tests and verify RED**

Run:

```bash
swift test -Xswiftc -strict-concurrency=complete --filter applicationIconStore
swift test -Xswiftc -strict-concurrency=complete --filter activityMonitorLauncher
```

Expected: compilation fails because both production types are missing.

- [ ] **Step 3: Implement the icon provider and stable cache**

Create `ApplicationIconStore.swift`:

```swift
import AppKit

@MainActor
protocol ApplicationIconProviding: AnyObject {
    func icon(for path: String?) -> NSImage?
}

@MainActor
final class ApplicationIconStore: ApplicationIconProviding {
    private let fileExists: (String) -> Bool
    private let loadIcon: (String) -> NSImage
    private let cache = NSCache<NSString, NSImage>()

    init(
        fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        loadIcon: @escaping (String) -> NSImage = { NSWorkspace.shared.icon(forFile: $0) }
    ) {
        self.fileExists = fileExists
        self.loadIcon = loadIcon
    }

    func icon(for path: String?) -> NSImage? {
        guard let path, !path.isEmpty, fileExists(path) else { return nil }
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let icon = loadIcon(path)
        cache.setObject(icon, forKey: key)
        return icon
    }
}
```

- [ ] **Step 4: Implement the injected Activity Monitor launcher**

Create `ActivityMonitorLauncher.swift`:

```swift
import AppKit

@MainActor
final class ActivityMonitorLauncher {
    typealias OpenApplication = @MainActor (URL) -> Void

    static let applicationURL = URL(
        fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app",
        isDirectory: true
    )

    private let openApplication: OpenApplication

    init(openApplication: OpenApplication? = nil) {
        self.openApplication = openApplication ?? { url in
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in }
        }
    }

    func open() {
        openApplication(Self.applicationURL)
    }
}
```

- [ ] **Step 5: Run service and full app tests**

Run:

```bash
swift test -Xswiftc -strict-concurrency=complete --filter applicationIconStore
swift test -Xswiftc -strict-concurrency=complete --filter activityMonitorLauncher
swift test -Xswiftc -strict-concurrency=complete
```

Expected: all service and application tests pass with strict concurrency enabled.

- [ ] **Step 6: Commit Task 3**

```bash
git add Sources/ThermoBar/Services/ApplicationIconStore.swift Sources/ThermoBar/Services/ActivityMonitorLauncher.swift Tests/ThermoBarAppTests/ApplicationIconStoreTests.swift Tests/ThermoBarAppTests/ActivityMonitorLauncherTests.swift
git commit -m "Add cached application icons and Activity Monitor launcher"
```

---

### Task 4: Build the Variant-A Consumer Sections

**Files:**

- Modify: `Sources/ThermoBar/Views/ResourceConsumerList.swift:1-197`
- Modify: `Sources/ThermoBar/Resources/Localizable.xcstrings:4-27`
- Test: `Tests/ThermoBarAppTests/ResourceConsumerPresentationTests.swift:5-49`

**Interfaces:**

- Consumes: `ApplicationIconProviding.icon(for:)` from Task 3
- Consumes: `ResourceConsumerSummary(cpu:gpu:memory:)`
- Consumes: `openActivityMonitor: () -> Void`
- Produces: `ResourceConsumerPresentation.openActivityMonitor(name:locale:) -> String`
- Produces: a list capped at `DynamicTypeSize.xxxLarge`

- [ ] **Step 1: Write failing presentation and layout-budget tests**

Add `import SwiftUI` beside the existing imports, then append to
`ResourceConsumerPresentationTests.swift`:

```swift
@Test func resourceConsumerSummaryFormatsTheApprovedSectionHeaders() {
    let summary = ResourceConsumerSummary(cpu: "18%", gpu: "7%", memory: "69%")
    #expect(summary.compute == "CPU 18% · GPU 7%")
    #expect(summary.memory == "69%")
}

@Test func activityMonitorButtonIncludesTheRowNameInBothLanguages() {
    #expect(ResourceConsumerPresentation.openActivityMonitor(name: "Finder", locale: Locale(identifier: "pl_PL")) == "Otwórz Monitor aktywności — Finder")
    #expect(ResourceConsumerPresentation.openActivityMonitor(name: "Finder", locale: Locale(identifier: "en_US")) == "Open Activity Monitor — Finder")
}

@Test func maximumConsumerColumnsLeaveAReadableNameAtTwoHundredThirtyTwoPoints() {
    #expect(ResourceConsumerRowLayout.contentWidth == 232)
    #expect(ResourceConsumerRowLayout.maximumComputeNameWidth >= 70)
    #expect(ResourceConsumerRowLayout.maximumMemoryNameWidth >= 90)
    #expect(ResourceConsumerRowLayout.maximumDynamicTypeSize == .xxxLarge)
}
```

- [ ] **Step 2: Run presentation tests and verify RED**

Run:

```bash
swift test -Xswiftc -strict-concurrency=complete --filter 'resourceConsumerSummaryFormatsTheApprovedSectionHeaders|activityMonitorButtonIncludesTheRowNameInBothLanguages|maximumConsumerColumnsLeaveAReadableNameAtTwoHundredThirtyTwoPoints'
```

Expected: compilation fails because `ResourceConsumerSummary`, the localized action formatter, and `ResourceConsumerRowLayout` do not exist.

- [ ] **Step 3: Add the pure summary and fixed layout budget**

Add near the top of `ResourceConsumerList.swift`:

```swift
struct ResourceConsumerSummary: Equatable {
    let cpu: String
    let gpu: String
    let memory: String

    var compute: String { "CPU \(cpu) · GPU \(gpu)" }
}

enum ResourceConsumerRowLayout {
    static let contentWidth: CGFloat = FloatingPanelLayout.width - 28
    static let maximumIconSize: CGFloat = 26
    static let actionSize: CGFloat = 20
    static let maximumValueColumnWidth: CGFloat = 44
    static let maximumMemoryColumnWidth: CGFloat = 60
    static let spacing: CGFloat = 5
    static let maximumDynamicTypeSize: DynamicTypeSize = .xxxLarge

    static let maximumComputeNameWidth = contentWidth
        - maximumIconSize - actionSize - (2 * maximumValueColumnWidth) - (4 * spacing)
    static let maximumMemoryNameWidth = contentWidth
        - maximumIconSize - actionSize - maximumMemoryColumnWidth - (3 * spacing)
}
```

Replace the rank-column metric with these capped metrics:

```swift
@ScaledMetric(relativeTo: .body) private var scaledIconSize: CGFloat = 22
@ScaledMetric(relativeTo: .body) private var scaledValueColumnWidth: CGFloat = 38
@ScaledMetric(relativeTo: .body) private var scaledMemoryColumnWidth: CGFloat = 54

private var iconSize: CGFloat { min(scaledIconSize, ResourceConsumerRowLayout.maximumIconSize) }
private var valueColumnWidth: CGFloat { min(scaledValueColumnWidth, ResourceConsumerRowLayout.maximumValueColumnWidth) }
private var memoryColumnWidth: CGFloat { min(scaledMemoryColumnWidth, ResourceConsumerRowLayout.maximumMemoryColumnWidth) }
```

- [ ] **Step 4: Add the localized Activity Monitor label**

Add `action.open-activity-monitor` to the string catalog:

```json
"action.open-activity-monitor" : {
  "localizations" : {
    "pl" : { "stringUnit" : { "state" : "translated", "value" : "Otwórz Monitor aktywności — %@" } },
    "en" : { "stringUnit" : { "state" : "translated", "value" : "Open Activity Monitor — %@" } }
  }
}
```

In `ResourceConsumerPresentation`, select the locale-specific `.lproj` bundle the same way as the existing accessibility helpers, then format that catalog key with the supplied process name:

```swift
static func openActivityMonitor(name: String, locale: Locale = .current) -> String {
    let language = locale.language.languageCode?.identifier ?? "en"
    let bundle = Bundle.module.path(forResource: language, ofType: "lproj")
        .flatMap(Bundle.init(path:)) ?? .module
    let format = bundle.localizedString(
        forKey: "action.open-activity-monitor",
        value: "Open Activity Monitor — %@",
        table: nil
    )
    return String(format: format, locale: locale, name)
}
```

- [ ] **Step 5: Replace rank cells with icons and add separate action buttons**

Change the list initializer to require the approved dependencies:

```swift
let summary: ResourceConsumerSummary
let iconProvider: any ApplicationIconProviding
let openActivityMonitor: () -> Void

init(
    metric: ResourceConsumerMetric,
    summary: ResourceConsumerSummary,
    visibility: ResourceConsumerVisibility = .all,
    iconProvider: any ApplicationIconProviding,
    openActivityMonitor: @escaping () -> Void
) {
    self.metric = metric
    self.summary = summary
    self.visibility = visibility
    self.iconProvider = iconProvider
    self.openActivityMonitor = openActivityMonitor
}
```

Use a section header with the system summary and separator:

```swift
private func sectionHeader(title: LocalizedStringResource, summary: String) -> some View {
    VStack(spacing: 8) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.body.bold()).textCase(.uppercase)
            Spacer(minLength: 4)
            Text(verbatim: summary).font(.body.bold().monospacedDigit())
        }
        Divider()
    }
}
```

Create a reusable icon and action button:

```swift
@ViewBuilder
private func consumerIcon(path: String?) -> some View {
    if let icon = iconProvider.icon(for: path) {
        Image(nsImage: icon).resizable()
    } else {
        Image(systemName: "app.dashed").resizable().scaledToFit().padding(3)
    }
}

private func activityMonitorButton(name: String) -> some View {
    let label = ResourceConsumerPresentation.openActivityMonitor(name: name)
    return Button(action: openActivityMonitor) {
        Image(systemName: "arrow.up.right.square")
            .frame(width: ResourceConsumerRowLayout.actionSize, height: ResourceConsumerRowLayout.actionSize)
    }
    .buttonStyle(.plain)
    .help(Text(verbatim: label))
    .accessibilityLabel(Text(verbatim: label))
}
```

Implement the compute and memory rows exactly as follows. The icon, name, and
values form one rank-aware accessibility element. The action button stays outside
that element so it remains a separate keyboard and VoiceOver target:

```swift
private func computeRow(rank: Int, row: ResourceConsumerCPUEntry) -> some View {
    HStack(spacing: ResourceConsumerRowLayout.spacing) {
        HStack(spacing: ResourceConsumerRowLayout.spacing) {
            consumerIcon(path: row.iconPath)
                .frame(width: iconSize, height: iconSize)
                .clipShape(.rect(cornerRadius: 6))
                .accessibilityHidden(true)
            Text(verbatim: row.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(Text(verbatim: row.name))
            Spacer(minLength: 4)
            computeColumns(
                cpu: ResourceConsumerPresentation.cpu(row.percent),
                gpu: ResourceConsumerPresentation.gpu(row.gpuPercent)
            )
            .font(.body.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            ResourceConsumerPresentation.computeAccessibility(
                rank: rank,
                name: row.name,
                cpu: row.percent,
                gpu: row.gpuPercent
            )
        )

        activityMonitorButton(name: row.name)
    }
    .font(.body)
}

private func memoryRow(rank: Int, row: ResourceConsumerMemoryEntry) -> some View {
    let value = ResourceConsumerPresentation.memory(row.physicalFootprintBytes)
    return HStack(spacing: ResourceConsumerRowLayout.spacing) {
        HStack(spacing: ResourceConsumerRowLayout.spacing) {
            consumerIcon(path: row.iconPath)
                .frame(width: iconSize, height: iconSize)
                .clipShape(.rect(cornerRadius: 6))
                .accessibilityHidden(true)
            Text(verbatim: row.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(Text(verbatim: row.name))
            Spacer(minLength: 4)
            Text(verbatim: value)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: memoryColumnWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            ResourceConsumerPresentation.accessibility(
                rank: rank,
                name: row.name,
                resource: "RAM",
                value: value
            )
        )

        activityMonitorButton(name: row.name)
    }
    .font(.body)
}
```

Use the existing CPU/GPU column labels beneath the Process separator. For both
active sections, render `sectionHeader` before switching between available,
measuring, and unavailable content so every active state retains its summary and
separator. Remove every visible `Text("\(rank)")`, but continue passing `rank` to
the accessibility formatters. Apply:

```swift
.dynamicTypeSize(...ResourceConsumerRowLayout.maximumDynamicTypeSize)
```

to the outer consumer list only.

- [ ] **Step 6: Run presentation tests and build the target**

Run:

```bash
swift test -Xswiftc -strict-concurrency=complete --filter 'resourceConsumerSummaryFormatsTheApprovedSectionHeaders|activityMonitorButtonIncludesTheRowNameInBothLanguages|maximumConsumerColumnsLeaveAReadableNameAtTwoHundredThirtyTwoPoints'
swift build -Xswiftc -strict-concurrency=complete
```

Expected: tests pass and `ResourceConsumerList` compiles with distinct row and button accessibility elements.

- [ ] **Step 7: Commit Task 4**

```bash
git add Sources/ThermoBar/Views/ResourceConsumerList.swift Sources/ThermoBar/Resources/Localizable.xcstrings Tests/ThermoBarAppTests/ResourceConsumerPresentationTests.swift
git commit -m "Redesign consumer rows with icons and actions"
```

---

### Task 5: Wire Stable Ownership, Summaries, Previews, and Full Verification

**Files:**

- Modify: `Sources/ThermoBar/ThermoBarApp.swift:5-75`
- Modify: `Sources/ThermoBar/Views/FloatingPanelView.swift:8-52,145-167,250-340`
- Modify: `Sources/ThermoBar/Views/PreviewFixtures.swift:3-23`
- Test: `Tests/ThermoBarAppTests/ResourceConsumerPresentationTests.swift`

**Interfaces:**

- Consumes: `ApplicationIconStore`, `ActivityMonitorLauncher`, and redesigned `ResourceConsumerList`
- Produces: `ThermoBarPresentation.resourceConsumerSummary: ResourceConsumerSummary`
- Preserves: one stable icon cache in production and one shared icon cache for all previews

- [ ] **Step 1: Write the failing presentation-summary integration test**

Append:

```swift
@Test func thermobarPresentationPublishesConsumerHeaderSummariesFromTheSnapshot() {
    let presentation = ThermoBarPresentation(
        snapshot: PreviewFixtures.nominal,
        mode: .visible,
        nowNanoseconds: PreviewFixtures.nowNanoseconds
    )

    #expect(presentation.resourceConsumerSummary == .init(
        cpu: "26%",
        gpu: "19%",
        memory: "50%"
    ))
}
```

- [ ] **Step 2: Run the integration test and verify RED**

Run:

```bash
swift test -Xswiftc -strict-concurrency=complete --filter thermobarPresentationPublishesConsumerHeaderSummariesFromTheSnapshot
```

Expected: compilation fails because `ThermoBarPresentation.resourceConsumerSummary` is missing.

- [ ] **Step 3: Publish existing formatted system values as a consumer summary**

Add to `ThermoBarPresentation`:

```swift
var resourceConsumerSummary: ResourceConsumerSummary {
    .init(cpu: cpuLoad, gpu: gpuLoad, memory: memoryDetail)
}
```

This reuses the existing fresh/stale formatting and produces `—` automatically when data is unavailable.

- [ ] **Step 4: Create stable App-level service ownership**

Add to `ThermoBarApp`:

```swift
@State private var iconStore: ApplicationIconStore
private let activityMonitorLauncher: ActivityMonitorLauncher
```

Initialize them once:

```swift
_iconStore = State(initialValue: ApplicationIconStore())
activityMonitorLauncher = ActivityMonitorLauncher()
```

Pass both into `FloatingPanelSceneContent`, then into `FloatingPanelView`:

```swift
FloatingPanelSceneContent(
    model: model,
    frameStore: frameStore,
    iconProvider: iconStore,
    openActivityMonitor: activityMonitorLauncher.open
)
```

Add these stored properties to `FloatingPanelSceneContent`:

```swift
let iconProvider: any ApplicationIconProviding
let openActivityMonitor: () -> Void
```

- [ ] **Step 5: Forward dependencies through the panel and provide shared preview dependencies**

Add required `iconProvider` and `openActivityMonitor` parameters to
`FloatingPanelView` and `FloatingPanelContent`; do not construct either dependency
inside a view initializer. The production call always supplies the App-owned
instances. Add one shared preview cache and inert preview action to
`PreviewFixtures`:

```swift
@MainActor static let iconStore = ApplicationIconStore()
@MainActor static let openActivityMonitor: () -> Void = {}
```

Update every `FloatingPanelView` preview in `FloatingPanelView.swift` to pass
`iconProvider: PreviewFixtures.iconStore` and
`openActivityMonitor: PreviewFixtures.openActivityMonitor`. Tests that construct
the view directly must pass a local fake provider and inert closure.

Call the list with all dependencies:

```swift
ResourceConsumerList(
    metric: presentation.resourceConsumers,
    summary: presentation.resourceConsumerSummary,
    visibility: resourceConsumerVisibility,
    iconProvider: iconProvider,
    openActivityMonitor: openActivityMonitor
)
```

- [ ] **Step 6: Give previews representative icon identities**

Update `PreviewFixtures.resourceConsumers` without changing names, ordering, or values. Use stable system paths where appropriate and `nil` to exercise fallback:

```swift
.init(
    pid: 1,
    name: "Preview Browser with a deliberately long process name",
    percent: 137,
    gpuPercent: 22,
    iconPath: "/System/Applications/Safari.app"
),
.init(
    pid: 2,
    name: "Local Model",
    percent: 84,
    gpuPercent: 71,
    iconPath: nil
)
```

Use `/System/Applications/Utilities/Terminal.app` for the `WindowServer` visual fixture so the preview includes a second real icon. Apply the same app path consistently to matching RAM entries.

- [ ] **Step 7: Run the complete automated verification**

Run:

```bash
swift test -Xswiftc -strict-concurrency=complete
THERMOBAR_LIVE_CONSUMER_READER=1 swift test -Xswiftc -strict-concurrency=complete --filter liveReaderReturnsOnlySafeRecordsWhenEnabled
./Scripts/build-app.sh
./Scripts/verify-security.sh build/ThermoBar.app
git diff --check
```

Expected:

- all Core and App tests pass;
- live reader returns only positive PIDs, non-empty names, and validated optional icon paths;
- release bundle builds and codesigns;
- security audit reports no prohibited source, dependency, entitlement, link, symbol, or socket finding;
- `git diff --check` prints nothing.

- [ ] **Step 8: Perform the visual runtime check**

Install and restart the locally built app using the established repository workflow:

```bash
pkill -x ThermoBar
```

Exit status 1 is acceptable only when ThermoBar was not running. Then run:

```bash
ditto build/ThermoBar.app /Applications/ThermoBar.app
open -a /Applications/ThermoBar.app
```

Verify in the running panel:

- Process and RAM sections each show at most five rows;
- headers show system summaries and separators;
- visible ranks are gone while row order is unchanged;
- real app icons appear and missing identities use the neutral fallback;
- CPU/GPU and RAM values remain on one line at the normal size and `xxxLarge`;
- each arrow button has keyboard focus and opens Activity Monitor;
- long names truncate without displacing numeric values or the action.

- [ ] **Step 9: Commit Task 5**

```bash
git add Sources/ThermoBar/ThermoBarApp.swift Sources/ThermoBar/Views/FloatingPanelView.swift Sources/ThermoBar/Views/PreviewFixtures.swift Tests/ThermoBarAppTests/ResourceConsumerPresentationTests.swift
git commit -m "Wire application-style consumer sections"
```

- [ ] **Step 10: Inspect final scope**

Run:

```bash
git status --short
git diff c312ec3..HEAD --stat
git log -5 --oneline
```

Expected: only the planned source, test, localization, spec, and plan files are part of the feature commits; `.superpowers/` remains untracked and untouched.
