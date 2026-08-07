# Memory

_2026-08-07_

Architecture notes worth keeping beyond one session.

## The service boundary is what makes testing possible

`OFinderServices` has no AppKit, and the test target depends only on it.
Every piece of logic that got real tests — history stack, path splitting,
transfer guard, Trash index — got them because it was put there. Logic left in
a view controller cannot be tested on this machine at all.

## Stopping a child process is three problems, not one

Found while making Cancel work. Each part looks optional until you trace what
happens without it:

- The handle has to exist before the process does. A job is started on one
  thread and spawns its child on another, so a cancel can land in between.
  Remember it and apply it on attach, or the click silently does nothing.
- `Process` cannot put its child in a process group, so there is no group to
  signal. SIGKILL on the parent alone leaves rsync's forks alive, still holding
  the stdout pipe — the reader never sees EOF, so the job never reports back,
  and for a move the orphans keep deleting sources. The tree has to be walked
  through `sysctl(KERN_PROC_ALL)`.
- The UI must not depend on the child answering. An archive job queued behind
  another has no child to signal at all, so a window that waits for
  confirmation waits forever. Every wait needs a way out.

## TCC is the recurring trap

Three separate sessions lost time to it. What is true:

- `~/.Trash` and `~/Library/Application Support/com.apple.TCC` need Full Disk
  Access; the failure is EPERM, not the ordinary EACCES.
- Full Disk Access cannot be requested programmatically. There is no API.
- Checking from a terminal reports the terminal's access. TCC attributes a
  request to the responsible process.
- Deleting and recreating the app bundle invalidates the grant while System
  Settings still shows it enabled.
