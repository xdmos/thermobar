# Visibility controls for resource-consumer lists

## Summary

Add two independent controls to the ThermoBar menu that determine whether the
resource-consumer sections are visible in the floating panel. Simplify the
panel section titles by removing the wording that means “top/highest”.

## User experience

The menu gains a "Widok panelu" / "Panel view" section below the opacity
control with two toggles, both enabled by default:

- `setting.show-compute-consumers`: "Pokaż aplikację z największym użyciem CPU/GPU" / "Show app with highest CPU/GPU usage"
- `setting.show-memory-consumers`: "Pokaż aplikację z największym użyciem RAM" / "Show app with highest RAM usage"

Changing a toggle updates the visible floating panel immediately. The two
settings are independent, so a user may display either, both, or neither list.
The measurement pipeline continues to collect both resource-consumer metrics;
the controls only affect presentation.

In the floating panel the compute heading changes from "Najwięcej CPU / GPU"
to "CPU/GPU", and the memory heading changes from "Najwięcej RAM" to
"RAM". English strings also become "CPU/GPU" and "RAM". A new
`setting.panel-view` catalog key supplies the section heading; the new keys are
exposed through `ThermoBarCopy` alongside the existing menu strings.

When both lists are hidden, the lower panel divider and otherwise-empty footer
are omitted for a fresh, healthy snapshot. The footer remains visible whenever
it needs to show a sensor diagnostic or freshness warning, so a user cannot
hide operational feedback accidentally.

## Architecture and data flow

`AppPreferences` persists two boolean preferences using the stable keys
`thermobar.showComputeConsumers` and `thermobar.showMemoryConsumers`. Each
uses a typed `Bool` read and falls back to `true` if its value is missing or
invalid; a user-selected `false` is persisted unchanged. `AppModel` reads them
during initialization, exposes observable state, and supplies synchronous
setters that persist a new value before publishing the normalized preference
value.

`MenuPopoverView` binds the two toggles to the model. The application scene
passes the current settings into `FloatingPanelView`, then to
`FloatingPanelContent` and `ResourceConsumerList`. The resource-list view has
a small, pure visibility configuration and conditionally renders the compute
and memory sections independently. `FloatingPanelContent` uses the same
configuration to decide whether the lower divider/footer is needed. The
existing resource metric is passed through unchanged.

## Localization and accessibility

Add localized menu labels for Polish and English. Native `Toggle` labels give
the controls appropriate keyboard and VoiceOver semantics. Existing row labels
and metric accessibility output remain unchanged.

## Validation

Add focused tests for defaults, invalid stored values, and persistence of each
visibility preference; model initialization and setters; and the existing exact
persistent-key inventory test. Add deterministic presentation tests using the
pure visibility configuration for all four combinations, including whether a
fresh healthy footer is shown and that diagnostics/freshness warnings retain
it. Run the full Swift package test suite and build the app.
