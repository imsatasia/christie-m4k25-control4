# christie-m4k25-control4

A DriverWorks driver for a Christie M 4K25 RGB projector, controlling it
over Christie's serial API on TCP 3002. The protocol work it is built on
lives in [`py-christie-mseries`](https://github.com/imsatasia/py-christie-mseries)
— this is a Lua port of the parts a Control4 system needs (Control4 drivers
can't shell out to a Python process, so the wire protocol is reimplemented
here in pure Lua, not called into at runtime).

Build output is `christie_m4k25.c4z`.

## Contents

- [Firmware this was built for](#firmware-this-was-built-for)
- [What it does](#what-it-does)
- [Lens presets are synthesised by the driver](#lens-presets-are-synthesised-by-the-driver)
- [Build](#build)
- [Testing without a controller](#testing-without-a-controller)
- [Protocol notes carried over from the Python client](#protocol-notes-carried-over-from-the-python-client)
- [Input indices are configurable, not discovered](#input-indices-are-configurable-not-discovered)
- [Installing (for the dealer)](#installing-for-the-dealer)
- [Status](#status)
- [Layout](#layout)

## Firmware this was built for

**Christie M 4K25 RGB, main control board software 1.3.x** — developed and
verified against a unit running **1.3.9**, re-verified via `make live-test`
after the same unit was updated to **1.3.10** (`SST+VERS` → `ChristieM
1.3.10`) — every field parsed cleanly with no bytes left unconsumed, no
behavior changes. The full component version block is in
[`py-christie-mseries`'s README](https://github.com/imsatasia/py-christie-mseries#firmware-this-was-built-for).

Which codes exist is a property of the firmware, not the model: this unit
runs Christie's TruLife+ platform, which implements about a third of the
codes in the published M Series serial API document. So a projector on
materially different software may not answer every code this driver sends.
After a projector software upgrade, run the live test and check it still
reports every field with no unparsed bytes:

```bash
make live-test HOST=192.0.2.50
```

## What it does

Exposed through Control4's **projector** proxy, so it behaves as a display
in room Watch flows: power on/off and discrete input selection on four HDMI
bindings.

Everything the proxy has no concept of is exposed as programming commands:
`SetBrightness` (laser power, 30–100%), `ShutterOpen` / `ShutterClose`,
`SetTestPattern` (21 patterns), `SetLiteLOC`, `SetLensPosition`, `NudgeLens`,
`SaveLensPreset` / `RecallLensPreset`, `SendRaw`, and `RefreshStatus`.

Fourteen read-only variables are published for programming: `POWER_STATE`,
`BRIGHTNESS`, `LITELOC`, `SHUTTER_OPEN`, `INPUT_NAME`, `TEST_PATTERN`,
`HOURS`, `INTAKE_TEMP`, `ALARMS`, `CONNECTED`, and the four lens motor
positions `LENS_FOCUS`, `LENS_ZOOM`, `LENS_H`, `LENS_V`.

## Lens presets are synthesised by the driver

Focus, zoom and lens offset are plain absolute-position codes (`FCS`, `ZOM`,
`LHO`, `LVO`) with no published range — the limits depend on the lens
fitted, so the driver sends what it is given and lets the projector reject
anything out of range.

The projector has **no lens memory of its own**: the ILS codes are absent,
and recalling a channel does not move the lens. So `SaveLensPreset` stores
the four motor positions in driver persistence and `RecallLensPreset`
replays them as absolute moves, which is what makes a scope / 16:9
screen-ratio preset possible on this unit at all. Four slots, surviving
driver restarts.

Positions are readable at any time but only *movable* while the projector is
on, so both commands refuse in standby with a logged reason rather than
sending a move the projector would reject.

## Build

```bash
make build      # or: ./build.sh
```

A `.c4z` is just a ZIP, so this needs nothing from Control4's SDK — the
DriverPackager is only required for squishing multiple Lua files together or
encrypting the source, neither of which applies here. The script validates
`driver.xml` and byte-compiles `driver.lua` before packaging, because
Composer rejects malformed XML silently and a Lua syntax error only
surfaces once the driver is loaded on a controller.

### Releases

Pushing a tag such as `v1.0.1` builds the `.c4z` in CI and attaches it (with a
`.sha256`) to that tag's [GitHub Release](https://github.com/imsatasia/christie-m4k25-control4/releases). The tag must match
`driver.xml`'s `Driver Version`. Download the `.c4z` from there, or build it
yourself as above.

## Testing without a controller

Installing a driver requires **Composer Pro**, so on-device iteration is
expensive. Everything below the Control4 API is therefore testable here.

`tests/c4_stub.lua` implements the subset of the `C4:` API the driver uses
and records what the driver did: what it wrote to the network, what it told
the proxy, which variables it set.

```bash
make test                       # 83 offline tests against captured projector replies
make live-test HOST=192.0.2.50   # the same driver code against the real projector, read-only
```

Both targets build `Dockerfile` (Alpine + `lua5.1`/`lua5.1-socket` — there's
no Lua on the host, and this driver targets Lua 5.1 specifically, which is
what Control4 controllers run) the first time they're needed.

The live test swaps only `C4:SendToNetwork` for a real socket and pumps
received bytes back through the driver's own `ReceivedFromNetwork`, so the
framing, parsing and state handling exercised are exactly what ships. It
finishes by reporting any bytes left unparsed in the buffer, which is what a
framing bug would look like.

## Protocol notes carried over from the Python client

- **Replies pair a number with a description** — `(PWR!000 "Standby Mode")`
  — so the payload is not a bare integer.
- **A successful SET is answered with silence; a rejected one returns an
  error that carries no code of its own.** In the Python client, which reads
  synchronously after each write, an unread error became the answer to the
  *next* query and shifted every later reading by one. This driver avoids
  that class of bug structurally: it parses every inbound message and
  routes it by code, so a stray error is logged rather than mistaken for
  data. There is a regression test for exactly this.
- **Silence is not "off".** For a few seconds after a power command the
  projector accepts a TCP connection but answers nothing. `POWER_STATE`
  stays at its last value rather than dropping to off, transitional states
  (`Warming Up`, `Cooling Down`) are not reported to the proxy at all, and
  any power command schedules a re-read 20 seconds later.
- **Brightness is `LAS+POWR`**, in tenths of a percent, with a soft minimum
  of 20% below which the projector will not run its lasers. The driver's
  floor is Christie's recommended **30%** instead: their release notes
  list, still unresolved, that LiteLOC is compromised at 30% or less and
  that lasers may shut down and colour may drop out. LiteLOC is enabled on
  this unit.
- **Image and lens controls are rejected in standby** with `ERR00105
  "Disabled Control"` — test patterns and lens moves only apply once the
  projector is on, though lens positions still *read* correctly in standby.

## Input indices are configurable, not discovered

The projector does not publish its input list over either the serial API or
the web RPC, and enumerating it by trial would mean actually switching
inputs. So each HDMI binding sends a Christie `SIN` index taken from an
**Input N Index** property, defaulting to 1–4.

To find the right values on site: switch the projector to an input by hand
and run the **Print Status** action. It prints the current index alongside
the projector's own name for it, e.g. `1 One-Port HDMI0`.

## Installing (for the dealer)

1. Copy `christie_m4k25.c4z` into `Documents\Control4\Drivers\` on the
   Composer Pro machine.
2. Add **Christie M 4K25 RGB** to the project.
3. Set the projector's IP under Connections → Network. It needs a DHCP
   reservation; the driver has no discovery and a changed address silently
   stops all control.
4. Bind sources to the HDMI 1–4 video inputs, and set the Input N Index
   properties to match.
5. Run **Print Status** and confirm the Lua output window shows the model,
   serial and hours — that is the check that two-way communication works.

If step 4 has nothing to bind to — the Control & Audio Video Connections
pane lists the network connection but no video inputs — the `.c4z` predates
driver version 1.0.1. That release fixed three separate faults in
`driver.xml`, any one of which makes Composer discard the proxy-owned input
bindings silently: the proxy binding declared class `PROJECTOR` (the class
is `TV`; `PROJECTOR` is the proxy name, not a connection class), `<combo>`
was `True`, and `<video_consumer_count>` was absent. 1.0.1 also adds the
room binding that lets a room use the projector as its video end-point.
Rebuild with `make build`, then remove and re-add the device, since Composer
caches the connection list from when the driver was first added.

`www/documentation.html` ships inside the `.c4z` and covers the same ground
plus troubleshooting, viewable from Composer's documentation tab.

## Status

Verified against the projector over a live socket: power state, shutter,
input, brightness, LiteLOC, test pattern, lens positions, hours, intake
temperature, alarm count, model and serial all parse correctly, with no
bytes left unconsumed. Lens *moves* are unverified against hardware — the
projector was in standby, where they are refused — so the first recall
should be watched.
The Control4 side has had one install attempt, which is what turned up the
1.0.1 binding faults above. Its XML now matches the shape of Control4's own
certified projector drivers field for field, but **proxy behaviour, binding
and Navigator presentation are still unconfirmed on a controller.**

## Layout

| Path | Purpose |
|------|---------|
| `driver.xml` | Composer manifest: proxy, connections, properties, commands |
| `driver.lua` | All driver logic |
| `driver.c4zproj` | DriverPackager project file (informational; `build.sh` doesn't need it) |
| `www/documentation.html` | Ships inside the `.c4z`, shown in Composer's Documentation tab |
| `build.sh` / `Makefile` | Validate + package into `christie_m4k25.c4z` |
| `Dockerfile` | Throwaway Lua 5.1 image used for `make test` / `make live-test` |
| `tests/c4_stub.lua` | Fake `C4:` API |
| `tests/test_driver.lua` | 83 offline assertions against captured projector replies |
| `tests/live_test.lua` | Runs the real driver against a real projector, read-only |
