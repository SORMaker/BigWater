# Big Water

A macOS 13+ menu bar water reminder in Swift (SwiftPM, no Xcode project). A
pixel mascot (Claude, a droplet, a wizard, a cactus or a whale) comes in from a screen edge and throws water bottles until the
person says they will drink; it then drinks along for 20 seconds, and only a
drink that runs to its end is recorded. The UI and README are in Chinese;
code, comments and commit messages are in English.

## Commands

```sh
swift build                      # everything, debug
swift run BigWaterTests          # all tests: about 10 seconds, opens no window
swift run BigWaterTests away     # only tests whose suite or name contains "away"
./Tools/build.sh                 # release app at dist/Big Water.app
./Tools/run.sh --preview         # build, replace the running copy, show one real reminder
swift run BigWaterTests --pictures dist/Pictures   # the panel pages and the reminder as PNGs
swift run BigWaterArtwork dist/Artwork             # icon, storyboard and GIFs; copy what changed into docs/
```

The tests are a plain executable, not XCTest: the machine may have only the
Command Line Tools. A test is a `test("…") { … }` entry in a suite in
`Tests/BigWaterTests`; `expect` records a failure and carries on.

## How it fits together

```
BigWaterCore   rules and state, no AppKit
  Moment         one reading of the wall clock and the monotonic clock
  Hours          periods of a day, week hours, and their layout on real dates
  Schedule       the countdown: a value type that never reads a clock
  DrinkLog       when the person drank
  Preferences    settings      SavedState   what is written to disk
  ReminderScene  the animation as numbers: positions, phases, bottles
  Sprites        the pixel art as data; a new mascot is a case in `Mascot` plus its
                 blocks and props here, and `throwsBottles` if it throws
  Reminder       one reminder on screen: what a click does, where its parts sit
  StatusText     the countdown in words
BigWaterArt    Palette and Painter: turns the above into pixels
BigWaterApp    the app
  AppModel            the one place that holds state and applies the rules
  ReminderPresenter   runs a Reminder frame by frame on an OverlaySurface
  OverlayWindows      the AppKit panels (the only OverlaySurface besides the tests')
  SystemMonitor, StateStore, LoginItem, AppUpdater, MenuBarController, Views/
BigWater         the three-line executable
BigWaterArtwork  icon, storyboard and GIFs, drawn by the same Painter
```

`AppModel` handles everything the same way: read the clocks and the system
once (`observe`), apply the change, then `reconcile` brings the screen, the
saved state and the next wake-up into line. New behaviour usually belongs in
`Schedule` or `Reminder` (pure, easy to test) with a line or two in
`AppModel`. The model's dependencies are protocols, so tests drive the real
model and presenter with a hand-moved clock and no windows (`World.swift`).

## What must not change

Every installed copy depends on these. Changing one strands people's data or
cuts them off from updates:

- `CFBundleIdentifier` (`com.oil.bigwater`), `SUFeedURL` and `SUPublicEDKey`
  in `Resources/Info.plist`.
- The `appStateV1` defaults key and the JSON under it. The coding keys in
  `Preferences`, `DayHours`, `SavedProgress` and `DrinkLog` are that format.
  A new field needs a default; `saveFrom052` in `DataTests.swift` is a real
  old save that must keep loading.

## Working here

- The countdown runs on `Moment.uptime`, a monotonic clock. Take one `Moment`
  per pass and hand it down; never read a second clock inside a pass.
- Change behaviour together with a test that fails without it. Run the tests
  once before committing code; there is nothing else to run. Docs-only
  changes need no run.
- A terminal session without screen recording permission cannot see the
  screen. Look at the interface with `--pictures`, which renders the real
  views off screen, and say plainly what was not seen on the real windows.
- A release bumps `CFBundleShortVersionString` and `CFBundleVersion` together
  and adds `docs/releases/<version>.md`. `Tools/release.sh` refuses a dirty tree.
- README describes behaviour for users and stays in step with what ships.
  `VERIFICATION.md` records what was and was not verified for each release.
- Commits follow Conventional Commits (`type(scope): description`,
  imperative, at most 72 characters), one purpose each.
