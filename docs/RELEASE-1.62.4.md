# NotchPill 1.62.4

The notch expands from both sides and the bottom of the hardware outline, with smooth, interruptible spring motion. Usage cards fit their details within the selected pill size without vertical scrolling.

### Improvements

- Larger, brighter small text and metadata, with refined card spacing and controls.
- Cleaner chip-to-card transitions and a smooth return of collapsed chips.
- File shelf menus stay open on the first attempt: the notch remains held through right-click menu tracking, the destination-menu handoff, and folder selection or cancellation.
- Media streams shut down when their parent exits, including dead parents that have not yet been reaped.
- More reliable agent/session integration, usage toggles, terminal launching, process cancellation, media handling, and development builds.
- Safer update downloads validate release URLs and redirects before installation.

### Release recovery

The earlier 1.62 builds were never published. This release fixes compatibility with GitHub's Swift compiler and removes test assumptions about installed terminal apps and animation startup timing. Sol reproduced and fixed a media-supervisor bug that treated unreaped dead parents as alive. Parent-death fixtures now trigger independently of Swift task scheduling; process probes distinguish zombies conservatively, and cancellation fixtures avoid CPU spinning. Failed tags remain in repository history.

### Validation

All 934 local tests pass, with regression coverage for whole-notch expansion, complete usage-card fitting, menu lifetime and overlapping holds, terminal reliability, and updater safety. GitHub's release workflow tests the tagged source before packaging the app.
