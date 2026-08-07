# UI Context

## Shape

AppKit, programmatic — no storyboards, no nibs. Views are built in code with
Auto Layout constraints. [extracted: Sources/OFinder]

## Conventions learned the hard way

- **Size to content, not to constants.** macOS draws a capsule around a custom
  toolbar item at exactly the width the item reports, so a fixed floor leaves
  the content adrift inside it. `PathBarView` reports both width and height
  from its contents.
- **Toolbar centring**: `.flexibleSpace` centres within the leftover space, not
  the window. Use `toolbar.centeredItemIdentifiers`.
- **Do not rebuild a view mid-gesture.** AppKit delivers `mouseDragged` to
  whichever view took the `mouseDown`; rebuilding the tab strip on selection
  destroyed it and drags silently died.
- **Borderless buttons need a hover fill.** A bare glyph gives no sign it can be
  clicked. Size the glyph and the hit target independently.
- **A cell that fades** does so through `alphaValue`: hidden items 0.55, cut
  items 0.35.

## Localization

Every user-facing string goes through `L10n`. English is the base and lives at
the call site; `es.lproj` must gain the same key.
