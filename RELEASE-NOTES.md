# Release notes

Newest first. Each release is also on the repository's Releases page.

## 1.3.0 (2026-11-12)

**Arcade Foundry: Insert Coin Kit 1.3.0**

First public release of the kit: the Swift engine of the Apple apps, moved
out of Insert Coin into its own repository (Insert Coin's `kit/` submodule).
It ships with Insert Coin 1.3.0.

- **What it does:** loads a game core, runs it frame by frame with sound and
  controls, draws it on Metal, records replays, and keeps the game list, ROM
  sets, saves and settings. The window a game plays in and its pause menu are
  here too.
- **New since Insert Coin 1.2.0:** save states and Resume (three slots per
  game, for the boards whose cores have them), game categories in the
  library, Chihiro before Lindbergh in the platform list, Show speed in full
  screen on the Mac, and no crash when iCloud isn't available.
- **Using it:** a folder of sources, not a Swift package; each app compiles
  it into its own module. See README.md.

**Licence: BSD-3-Clause**, as Insert Coin.
