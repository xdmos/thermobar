# ThermoBar

ThermoBar is a lightweight macOS menu bar app that displays your Mac's current
resource usage and thermal condition. It runs entirely locally, sends no
telemetry, and requires neither an account nor an Internet connection.

## Features

- floating panel and menu bar interface;
- CPU, GPU, and memory usage;
- average CPU and GPU temperatures, plus the hottest sensor reading;
- current speed of the fastest fan in RPM;
- macOS system thermal state;
- optional local notifications for serious and critical thermal conditions;
- optional launch at login;
- adaptive sampling based on panel visibility and Mac sleep state.

ThermoBar is read-only. It does not change fan speeds or write values to
AppleSMC.

## Requirements

- macOS 27.0 or later;
- Xcode with the Swift 6.2 toolchain;
- Apple Silicon.

Full access to private sensors is currently verified only on `Mac17,9` running
macOS build `26A5388g`. On a different model or after a system update,
ThermoBar intentionally disables unverified temperature, GPU, and RPM readings
instead of guessing sensor keys. Public CPU, memory, and macOS thermal-state
metrics remain available.

## Install from source

```bash
git clone https://github.com/xdmos/thermobar.git
cd thermobar
./Scripts/build-app.sh
ditto build/ThermoBar.app /Applications/ThermoBar.app
open /Applications/ThermoBar.app
```

The build script creates a locally signed app bundle at
`build/ThermoBar.app`. After launch, the ThermoBar icon appears in the menu bar.
You can show or hide the floating panel from the app menu.

Notifications require macOS permission. Enabling launch at login may require
confirmation in **System Settings → General → Login Items & Extensions**.

## Privacy and security

- no external SwiftPM dependencies;
- no networking, telemetry, or analytics;
- no subprocesses, XPC, or privileged helper;
- empty entitlements;
- read-only AppleSMC access using an exact sensor-key allowlist for the
  supported model and OS build;
- preferences are stored locally in `UserDefaults`.

## Tests

Run the main test suite:

```bash
swift test -Xswiftc -strict-concurrency=complete
```

Additional quality gates:

```bash
swift test --sanitize=thread -Xswiftc -strict-concurrency=complete
THERMOBAR_RUN_LIVE_SENSORS=1 swift test --filter Live
THERMOBAR_RUN_PERFORMANCE=1 swift test -c release --filter SensorReadPerformanceTests
./Scripts/build-app.sh
./Scripts/verify-security.sh build/ThermoBar.app
```

The `Live` tests and performance benchmark are intended for the exact supported
Mac model and OS build.

## Third-party information

The project has no executable third-party dependencies. Attribution for the
source used to understand the AppleSMC ABI layout is provided in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
