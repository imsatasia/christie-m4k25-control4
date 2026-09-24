# AGENTS.md

## Purpose

`christie-m4k25-control4` is a Control4 DriverWorks driver for the Christie
M 4K25 RGB projector, speaking Christie's serial API over TCP 3002. It is a
Lua port of the protocol worked out in
[`py-christie-mseries`](https://github.com/imsatasia/py-christie-mseries) — that
repo's README is the reference for how the projector behaves (reply shapes,
missing codes, the TruLife+ platform). This repo only covers what's
different about doing it inside Control4.

The whole driver is two files: `driver.xml` (the manifest Composer reads)
and `driver.lua` (all the logic). `build.sh` zips them plus
`www/documentation.html` into `christie_m4k25.c4z`.

## Workflow

- `make test` builds the throwaway Lua 5.1 test image and runs the offline
  suite. `make live-test HOST=<ip>` runs the same driver code against a real
  projector, read-only.
- Target **Lua 5.1** specifically — that's what Control4 controllers run, so
  no `goto`, no integer division, no `table.unpack`. `build.sh` byte-compiles
  with `luac5.1` to catch this before it ships to a controller.
- Run the offline suite before pushing. There is no CI-run hardware test;
  `make live-test` is manual-only.

## Design Expectations

- **Never add a function that waits for a reply.** `C4:SendToNetwork`
  returns immediately; replies arrive later in `ReceivedFromNetwork`. Request
  and response are always separate: send the query, let a `Handlers.<CODE>`
  function update `State` and the variable when the reply actually arrives.
  This is what makes the Python client's worst bug (an unread rejected-SET
  error becoming the next query's answer, desyncing every later reading)
  structurally impossible here — nothing is "the next reply"; an unexpected
  error matches no handler, gets logged, and affects nothing else. Keep the
  dispatch-by-code structure and the regression test for this
  (`tests/test_driver.lua`: an error message immediately followed by a valid
  `PWR` message).
- `State` is the single source of truth, mirrored outward via `SetVariable`.
- `Protocol.*` functions stay pure string functions with no `C4:` calls, so
  `tests/c4_stub.lua` can exercise them off-controller.
- Timers are `C4:SetTimer`; cancel them in `OnDriverDestroyed` or they
  survive a driver reload.
- Never write this projector's serial number (or any other unit-identifying
  value) into this repo. Firmware/software versions are fine; the driver
  reads the serial live into `State.serial` at runtime, which is where it
  belongs.
- The brightness floor (`BRIGHTNESS_MIN = 30`), the lens-preset-synthesis
  approach (the projector has no lens memory of its own — `SaveLensPreset`/
  `RecallLensPreset` persist and replay the four motor positions via
  `C4:PersistSetValue`), and the input-indices-are-configuration-not-
  discovery design are all load-bearing decisions carried over from
  `py-christie-mseries` — see its README before "fixing" any of them back to a
  device default.
- Treat changes to `driver.xml` bindings as riskier than changes to
  `driver.lua`: the Lua has a test harness, the XML does not. Getting the
  proxy binding class, `<combo>`, or `<video_consumer_count>` wrong drops the
  HDMI inputs from Composer with no visible error (driver still loads,
  power/shutter still work) — see the inline XML comments and README's
  Troubleshooting section for the three specific gotchas this already hit
  once (fixed in driver version 1.0.1).

## Commits

Use conventional commits for releasable changes: `fix: ...` or `feat: ...`.
Bump `driver.xml`'s `<version>` and the `Driver Version` property together
with any releasable change.

## Releases

There is no PyPI-style package here — a release is a tagged `christie_m4k25.c4z`
build, made by `.github/workflows/release.yml` when a `vX.Y.Z` tag is pushed.
To release: bump `driver.xml`'s `<version>` and `Driver Version` property, run
`make test`, merge to `main`, wait for CI, then `git tag vX.Y.Z && git push origin
vX.Y.Z`. The workflow refuses the tag unless it matches `Driver Version`, the
commit is on `main`, and CI passed on it (CI includes the TruffleHog scan --
the scan action itself does nothing on a tag push, so the workflow checks
CI's result instead). It then builds the `.c4z` and attaches it, plus a
`.sha256`, to the GitHub Release (created if needed; a `-rc1`-style suffix
makes it a pre-release). Do not hand-edit or hand-upload the built `.c4z` — it's
a build artifact (`.gitignore`d), always regenerated from `driver.xml`/`driver.lua`.
