# Big Water

A macOS 13+ menu bar water reminder in Swift (SwiftPM, no Xcode project). A
pixel character enters from a screen edge and throws water bottles until the
user confirms a drink. The UI and README are in Chinese; code, comments and
commit messages are in English.

## Commands

```sh
swift build                                   # debug build of every target
swift run BigWaterChecks                      # core checks (no window server needed)
swift run BigWaterChecks --filter segmented   # one group, matched by name
./Tools/check-session.sh                      # drives the real AppDelegate; needs an awake desktop
swift run BigWaterSessionChecks --features    # session checks without the animation scenarios
./Tools/build.sh                              # release app at dist/Big Water.app
./Tools/run.sh --preview                      # build, launch, and show one real reminder
```

There is no XCTest. Both check runners are executables: a new check is a
function plus an entry in that file's `checks` list (core) or `scenarios`
list (session). Session checks open real overlay windows for a moment.

## Layout

- `Sources/BigWaterCore`: scheduling, preferences, history, scene state. No AppKit UI.
- `Sources/BigWaterArt`: pixel drawing shared by the app, the checks and `BigWaterArtwork`.
- `Sources/BigWaterApp`: menu bar, SwiftUI settings, storage, overlay windows, Sparkle.
  A library so `BigWaterSessionChecks` can `@testable import` it.
- `Sources/BigWater`: the three-line executable entry.
- `Sources/BigWaterArtwork`: renders the icon, storyboard and GIFs in `docs/`.

## Rules that protect installed users

- Never change `CFBundleIdentifier` (`com.oil.bigwater`), the `appStateV1`
  key, `SUFeedURL` or `SUPublicEDKey`. Each one either orphans saved data or
  breaks the update chain for every installed copy.
- Saved models decode leniently (`lenientValue`). A new field needs a default,
  and an old save must still load; add a fixture check when the format changes.
- The schedule counts awake use on `ReminderClock.uptime` (a monotonic clock).
  Read the time once per check and pass `now`/`uptime` down; never mix in a
  second clock read.
- Bump `CFBundleShortVersionString` and `CFBundleVersion` together, and add
  `docs/releases/<version>.md`. `./Tools/release.sh` refuses dirty trees.

## Changes

- Behavior changes come with a check that fails without them.
- Run checks in proportion to the change. While iterating, `--filter` to the
  group you touched. Run the full core suite once before committing code, and
  the session checks only when app, overlay or settings behavior changed.
  Docs-only changes, and a tree that already passed (a fast-forward merge, a
  reworded commit), need no rerun.
- README describes behavior for users; keep it in sync with what ships.
- `VERIFICATION.md` records what was actually verified for each release,
  including what was not.
- Commits follow Conventional Commits (`type(scope): description`, imperative,
  72 characters at most), one purpose per commit.
