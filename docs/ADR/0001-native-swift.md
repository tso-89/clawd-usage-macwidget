# ADR 0001: Native Swift app built with SwiftPM

Status: accepted (2026-10-17)

## Context

The upstream widget is PowerShell 5.1 + WPF, which does not exist on macOS. The port needs a
menu bar item, a borderless floating window that stays put across Spaces, a pixel-art animation
at 60-90 ms per frame, system notifications and a login item.

## Decision

A native app in Swift 6 (language mode 5), SwiftUI views hosted in AppKit panels, built with
Swift Package Manager (no Xcode project), macOS 14+. Two targets: `ClawdCore` (all logic, no
AppKit, unit-tested) and `ClawdUsage` (the app). `scripts/build-app.sh` assembles the `.app`.

## Alternatives

- Tauri / Electron: a web runtime for a 262-pt window; worse fit for `NSStatusItem` and a
  non-activating floating panel; more memory.
- PowerShell 7 on macOS: runs the logic, but every line of WPF UI would be rewritten anyway.

## Consequences

- No dependencies. The data formats (config.json keys, Clawd's home, history) stay the same as
  upstream, so upstream changes port mechanically.
- In-place self-update is not implemented: without a Developer ID signature an updated app is
  quarantined. A new release is announced and opens its page; Sparkle can be added once the
  app is signed and notarized.
