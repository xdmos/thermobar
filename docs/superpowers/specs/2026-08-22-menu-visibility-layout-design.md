# Compact consumer-visibility menu layout

## Goal

Make the consumer-list visibility controls readable in the ThermoBar menu.
The current long Polish labels truncate in the popover and make the two controls
look crowded.

## Design

Keep the same two persisted booleans and bindings. Replace the section title
with "Widoczne w panelu" / "Visible in panel" and the two toggle labels with
"CPU/GPU" and "RAM" in both languages. The heading supplies the context while
each label remains single-line at the existing popover width.

Use the native macOS checkbox toggle style explicitly and increase the vertical
spacing inside the section. The controls remain independent. Although their
visible labels are short, each gets a separate full localized accessibility
label: "Pokaż aplikację z największym użyciem CPU/GPU" and "Pokaż aplikację z
największym użyciem RAM" (and English equivalents).

## Validation

Update localization assertions or focused menu-control tests for the new
visible and accessibility resources, run `swift test`, then build and install
the release bundle for a visual check.
