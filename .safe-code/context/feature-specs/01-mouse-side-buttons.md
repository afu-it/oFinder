---
status: done
created: 2026-08-07
---

# Back and forward on the mouse thumb buttons

## Problem

Navigation history could only be driven from the toolbar's segmented control.
There was no keyboard shortcut and no mouse binding, so a browsing mouse with
thumb buttons did nothing in this app while it works everywhere else.

## Proposal

Two routes, because mice do not agree on what a thumb button sends:

- The raw buttons. macOS reports them as `otherMouseDown` with
  `buttonNumber` 3 (back) and 4 (forward).
- `Cmd+[` and `Cmd+]`. Drivers from Logitech, Razer and others commonly remap
  the thumb buttons to those keystrokes instead of passing the button through,
  so the raw path alone would silently do nothing on those mice.

The raw buttons are caught with a local `NSEvent` monitor rather than an
`otherMouseDown` override: an override only fires if the event survives every
view it passes on the way up the responder chain, and the outline, icon and
column views are each free to swallow it.

In a split, the press moves the pane under the pointer, not whichever pane
happens to be active, matching what an ordinary click there would do.

## Out of scope

- Any other mouse button. The middle button and anything past button 4 pass
  through untouched.
- Making the binding configurable.

## Verification

- Browse into a few folders, then press the back thumb button: the view walks
  back through them, and the toolbar's back segment greys out at the start.
- The same through `View > Back` / `Cmd+[`, which also greys out when there is
  nowhere to go back to.
- Split the window, hover the inactive half and press back: that half moves
  and becomes the active pane.
- Middle-click still behaves as it did.
