# NotchPill 1.62.1

The notch expands from both sides and the bottom of the hardware outline, with smooth, interruptible spring motion. Usage cards fit their details within the selected pill size without vertical scrolling.

### Improvements

- Larger, brighter small text and metadata, with refined card spacing and controls.
- Cleaner chip-to-card transitions and a smooth return of collapsed chips.
- File shelf menus stay open on the first attempt: the notch remains held through right-click menu tracking, the destination-menu handoff, and folder selection or cancellation.
- More reliable agent/session integration, usage toggles, terminal launching, process cancellation, media handling, and development builds.
- Safer update downloads validate release URLs and redirects before installation.

### Release recovery

The v1.62.0 release stopped during test compilation on GitHub's Swift compiler and was never published. This release simplifies the affected geometry-test expression and includes the file shelf menu fix. The original failed tag remains for history.

### Validation

The full local suite passes, with regression coverage for whole-notch expansion, complete usage-card fitting, menu lifetime and overlapping holds, terminal reliability, and updater safety. GitHub's release workflow tests the tagged source before packaging the app.
