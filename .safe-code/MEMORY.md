# Memory

_

Architecture notes worth keeping beyond one session.

## The service boundary is what makes testing possible

`R2FinderServices` has no AppKit, and the test target depends only on it.
Every piece of logic that got real tests — history stack, path splitting,
transfer guard, Trash index — got them because it was put there. Logic left in
a view controller cannot be tested on this machine at all.

## TCC is the recurring trap

Three separate sessions lost time to it. What is true:

- `~/.Trash` and `~/Library/Application Support/com.apple.TCC` need Full Disk
  Access; the failure is EPERM, not the ordinary EACCES.
- Full Disk Access cannot be requested programmatically. There is no API.
- Checking from a terminal reports the terminal's access. TCC attributes a
  request to the responsible process.
- Deleting and recreating the app bundle invalidates the grant while System
  Settings still shows it enabled.
