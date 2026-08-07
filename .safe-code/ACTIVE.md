# Active

## Last Session

status: saved
saved_at: 2026-08-07
completed: made Cancel actually stop rsync (and its forks); mouse thumb buttons
  and Cmd+[ / Cmd+] drive back and forward; the path bar can be copied from;
  renamed the app to oFinder on `dev.afuit.ofinder` at v0.0.1, carrying
  Favorites across; rewrote the 49 commits to the `afu-it` identity and pushed
  it; renamed the checkout folder to `oFinder`
pending: AFU to confirm the mouse thumb buttons work on his own mouse; decide
  what to do with the upstream tags mirrored into this fork; decide whether to
  rename the GitHub repo, still `afu-it/r2_finder`
next_action: none blocking. Re-grant Full Disk Access to oFinder, then confirm
  the thumb buttons.

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
