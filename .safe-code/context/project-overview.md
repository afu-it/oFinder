# Project Overview

## What it is

R2 Finder is a macOS file manager — a Finder replacement — written in Swift and
AppKit. [extracted: Package.swift, Sources/]

## Why it exists

Finder's copy path fails against SMB shares: it tries to write macOS-specific
metadata (resource forks, extended attributes, `.DS_Store`) that many Samba
configurations reject, producing error -36 or silent stalls with partial files
left behind. R2 Finder routes every copy and move through `rsync` instead.
[extracted: README.md]

## Who it is for

People who move files onto NAS or SMB volumes often enough that Finder's
failures are a daily cost. Also anyone who wants tabs and dual panes in a file
manager. [inferred: README.md rationale + the feature set that has been built]

## This fork

`afu-it/r2_finder`, forked from `carmonac/r2_finder`. The upstream app shipped
with every UI string hardcoded in Spanish and no localization at all; this fork
made English the base language and kept Spanish as a translation, then added
tabs, dual panes, a breadcrumb path bar, Recents, a Cloud section, Trash with
restore, and a set of drag-and-drop safety guards. [extracted: git log]

The fork is public and is not currently proposed upstream. [extracted: git
remote -v]

## Success criteria

- Copies and moves to SMB volumes complete where Finder fails
- No operation destroys data without a confirmation and a way back
- The app stays usable without Full Disk Access, and says so plainly where a
  location needs it
