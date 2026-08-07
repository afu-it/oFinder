# Active

## Last Session

status: saved
saved_at: 2026-08-07
completed: verified the renamed checkout builds clean; sticky sort (Recents
  newest-first by default, any header click persists per context); columns
  reordered to Name/Date/Type/Size, draggable, order+widths autosaved; Kind
  renamed Type; folder Size cell blank; window opens 1200x700 and remembers
  its size (fixed contentViewController squashing the frame to the 640 min,
  and NSWindowController's cascade mode silently disabling frame autosave);
  grid view is the first-run default and the last view mode is remembered;
  bilingual README (EN + ms) with logo (docs/assets/logo.png) and badges;
  tagged and pushed v0.0.1
pending: AFU to grant Full Disk Access and test the mouse thumb buttons;
  old "R2 Finder Self-Signed" cert and backup/pre-identity-rewrite branch can
  go once the new history has proven itself (carmonac's upstream tags
  v1.0.0-v2.0.2 were deleted from the fork on 2026-08-07; v0.0.1 is the only
  tag now)
next_action: AFU tests FDA + thumb buttons; next features toward v0.0.2
  (AFU will say when to bump the version)

## Notes

The app's identity changed in this session: bundle identifier
`com.example.r2finder` to `dev.afuit.ofinder`, and the signing certificate to
`oFinder Self-Signed`. macOS therefore treats it as a new app and Full Disk
Access has to be granted again. The old `/Applications/R2 Finder.app` was moved
to the Trash.

`origin` speaks SSH now. Over HTTPS the `gh` OAuth token lacks the `workflow`
scope, so any push that touches `.github/workflows/` is rejected outright. An
SSH key is not scoped that way.

`backup/pre-identity-rewrite` still holds the pre-rewrite commits. Delete it
once the new history has proven itself.

The checkout folder is still `r2_finder` and renaming it is deliberately left
for last. A rename invalidates the build cache in both directions: SwiftPM
bakes the absolute path into the module cache, so the first build after a move
fails with "missing required module 'SwiftShims'". The fix is `rm -rf .build`.
Any open editor window also keeps pointing at the path that no longer exists.
