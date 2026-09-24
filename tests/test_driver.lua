--[[
    Offline tests for driver.lua, run against the C4 stub.

    The reply strings below are real captures from the M 4K25 RGB, so these
    double as a record of what the projector actually sends.

    Run:  lua5.1 tests/test_driver.lua      (from the driver directory)
]]

package.path = "./?.lua;./tests/?.lua;" .. package.path

local stub = require("c4_stub")
dofile("driver.lua")

local say = stub.realPrint
local passed, failed = 0, 0

local function check(name, condition, detail)
    if (condition) then
        passed = passed + 1
    else
        failed = failed + 1
        say("FAIL: " .. name .. (detail and ("  -- " .. tostring(detail)) or ""))
    end
end

local function equal(name, actual, expected)
    check(name, actual == expected,
          "got " .. tostring(actual) .. ", expected " .. tostring(expected))
end

local function setup()
    stub.reset()
    RxBuffer = ""
    StatusRows = {}
    State.connected = true
    State.power, State.shutterOpen, State.input = nil, nil, nil
    State.brightness, State.liteloc, State.testPattern = nil, nil, nil
    State.lens = {}
end

--=============================================================================
-- Message building
--=============================================================================

setup()
equal("build query",         Protocol.Build("PWR", nil, nil, true),   "(PWR?)")
equal("build subcode query", Protocol.Build("LAS", "POWR", nil, true), "(LAS+POWR?)")
equal("build set",           Protocol.Build("SHU", nil, 1, false),    "(SHU 1)")
equal("build subcode set",   Protocol.Build("LAS", "POWR", 850),      "(LAS+POWR 850)")

-- A code/subcode/data shape that doesn't fit the wire format must be
-- refused rather than silently building a message that smuggles a second
-- "(...)" command past the framing.
equal("build rejects short code",       Protocol.Build("PW", nil, 1),           nil)
equal("build rejects non-letter code",  Protocol.Build("PW1", nil, 1),          nil)
equal("build rejects bad subcode",      Protocol.Build("LAS", "P", 1),          nil)
equal("build rejects paren in data",    Protocol.Build("SHU", nil, "1) ($PWR 0"), nil)
equal("build allows quoted string data", Protocol.Build("SIN", nil, '"HDMI 1"'), '(SIN "HDMI 1")')

setup()
Send("PW1", nil, 1, false)
equal("Send drops an invalid message rather than transmitting it", #stub.sent, 0)

--=============================================================================
-- Framing
--=============================================================================

local message, rest = Protocol.Split("(PWR!001 \"On\")(SHU!000)")
equal("split first message", message, "(PWR!001 \"On\")")
equal("split remainder",     rest,    "(SHU!000)")

message, rest = Protocol.Split("(PWR!001 \"O")
equal("partial message yields nil", message, nil)
equal("partial message keeps buffer", rest, "(PWR!001 \"O")

-- The projector escapes parens inside quoted text; they must not end framing.
message = Protocol.Split('(SST+SYST!001 "4:05 \\(h:m\\)" "Projector Hours")')
equal("escaped parens do not split",
      message, '(SST+SYST!001 "4:05 \\(h:m\\)" "Projector Hours")')

--=============================================================================
-- Parsing
--=============================================================================

local reply = Protocol.Parse('(PWR!000 "Standby Mode")')
equal("parse code", reply.code, "PWR")
equal("parse data", reply.data, '000 "Standby Mode"')

local number, text = Protocol.Value(reply.data)
equal("value number", number, 0)
equal("value text",   text,   "Standby Mode")

reply = Protocol.Parse("(LAS+POWR!700)")
equal("parse subcode", reply.subcode, "POWR")
equal("parse subcode value", (Protocol.Value(reply.data)), 700)

reply = Protocol.Parse("(ZOM!-267)")
equal("parse negative", (Protocol.Value(reply.data)), -267)

-- An error message carries no code of its own.
reply = Protocol.Parse('(65535 00000 ERR00101 "LAS: Control Not Found")')
equal("parse error code", reply.err, 101)
equal("parse error text", reply.text, "LAS: Control Not Found")

equal("unescape", Protocol.Unescape("4:05 \\(h:m\\)"), "4:05 (h:m)")

--=============================================================================
-- Inbound handling and state
--=============================================================================

setup()
stub.receive('(PWR!001 "On")')
equal("power recorded", State.power, 1)
equal("power text", State.powerText, "On")
equal("proxy told ON", stub.proxy[1].command, "ON")
equal("power variable", stub.variables["POWER_STATE"], "On")

setup()
stub.receive('(PWR!000 "Standby Mode")')
equal("proxy told OFF", stub.proxy[1].command, "OFF")

-- Warming is transitional: the proxy should not be told anything, because
-- neither ON nor OFF is true yet.
setup()
stub.receive('(PWR!011 "Warming Up")')
equal("warming sends nothing to proxy", #stub.proxy, 0)
equal("warming still records state", State.power, 11)

setup()
stub.receive("(SHU!000)")
equal("shutter 0 means open", State.shutterOpen, true)
stub.receive("(SHU!001)")
equal("shutter 1 means closed", State.shutterOpen, false)

setup()
stub.receive("(LAS+POWR!700)")
equal("brightness converted from tenths", State.brightness, 70)
equal("brightness variable", stub.variables["BRIGHTNESS"], "70.0")

setup()
stub.receive('(LAS+STAT!003 "Enabled")')
equal("liteloc 3 is enabled", State.liteloc, true)
stub.receive('(LAS+STAT!001 "Disabled")')
equal("liteloc 1 is disabled", State.liteloc, false)

setup()
stub.receive('(SIN!001 "One-Port HDMI0")')
equal("input index", State.input, 1)
equal("input name", State.inputName, "One-Port HDMI0")
equal("proxy told input changed", stub.proxy[1].command, "INPUT_CHANGED")
equal("input mapped to binding 1001", stub.proxy[1].params.INPUT, 1001)

setup()
stub.receive("(ITP!000)")
equal("test pattern name", stub.variables["TEST_PATTERN"], "Off")
stub.receive("(ITP!009)")
equal("test pattern colour bars", stub.variables["TEST_PATTERN"], "Color Bars")

-- Multi-message status reply, delivered as one blob.
setup()
stub.receive('(SST+SYST!001 "4:05 \\(h:m\\)" "Projector Hours")')
equal("hours parsed", stub.variables["HOURS"], "4:05 (h:m)")

setup()
stub.receive('(SST+TEMP!002 000 "34 \194\176C" "Air Intake Temperature \\(Temp 2\\)")')
equal("intake temperature parsed", stub.variables["INTAKE_TEMP"], "34")

-- An error reply must not be mistaken for data, and must not desynchronise
-- the messages after it.
setup()
stub.receive('(65535 00000 ERR00105 "ITP: Disabled Control")(PWR!001 "On")')
equal("message after an error still parsed", State.power, 1)

-- Framing has to survive arbitrary TCP fragmentation.
setup()
stub.receive('(PWR!001 "On")(LAS+POWR!700)(SHU!000)', 3)
equal("fragmented: power", State.power, 1)
equal("fragmented: brightness", State.brightness, 70)
equal("fragmented: shutter", State.shutterOpen, true)

--=============================================================================
-- Outbound commands
--=============================================================================

setup()
ProxyCommands.ON()
equal("ON sends PWR 1", stub.lastSent(), "(PWR 1)")

setup()
ProxyCommands.OFF()
equal("OFF sends PWR 0", stub.lastSent(), "(PWR 0)")

setup()
ProxyCommands.SET_INPUT({ INPUT = 1002 })
equal("input binding maps to configured index", stub.lastSent(), "(SIN 2)")

setup()
Properties["Input 2 Index"] = "7"
ProxyCommands.SET_INPUT({ INPUT = 1002 })
equal("input index is configurable", stub.lastSent(), "(SIN 7)")
Properties["Input 2 Index"] = "2"

setup()
State.input = 2
ProxyCommands.PULSE_INPUT()
equal("pulse input advances to the next input", stub.lastSent(), "(SIN 3)")

setup()
State.input = 4
ProxyCommands.PULSE_INPUT()
equal("pulse input wraps round to the first", stub.lastSent(), "(SIN 1)")

-- Cycling must follow the configured indices, not 1..4: with these the
-- projector's own numbering shares no value with the binding positions.
setup()
Properties["Input 1 Index"] = "5"
Properties["Input 2 Index"] = "6"
Properties["Input 3 Index"] = "7"
Properties["Input 4 Index"] = "8"
State.input = 6
ProxyCommands.PULSE_INPUT()
equal("pulse input cycles configured indices", stub.lastSent(), "(SIN 7)")

setup()
State.input = 8
ProxyCommands.PULSE_INPUT()
equal("pulse input wraps configured indices", stub.lastSent(), "(SIN 5)")

-- An input the projector reports that no binding claims should not wedge
-- the cycle; fall back to the first configured one.
setup()
State.input = 11
ProxyCommands.PULSE_INPUT()
equal("pulse input recovers from an unmapped input", stub.lastSent(), "(SIN 5)")

Properties["Input 1 Index"] = "1"
Properties["Input 2 Index"] = "2"
Properties["Input 3 Index"] = "3"
Properties["Input 4 Index"] = "4"

setup()
Commands.SetBrightness({ Brightness = "85" })
equal("brightness sent in tenths", stub.lastSent(), "(LAS+POWR 850)")

setup()
Commands.SetBrightness({ Brightness = "10" })
equal("brightness below soft minimum is refused", #stub.sent, 0)

-- 25% is inside the projector's own soft range but below Christie's
-- recommended floor, where they warn LiteLOC degrades and lasers may trip.
setup()
Commands.SetBrightness({ Brightness = "25" })
equal("brightness in the discouraged band is refused", #stub.sent, 0)

setup()
Commands.SetBrightness({ Brightness = "30" })
equal("brightness at the recommended floor is allowed", stub.lastSent(), "(LAS+POWR 300)")

setup()
Commands.SetBrightness({ Brightness = "120" })
equal("brightness above maximum is refused", #stub.sent, 0)

setup()
Commands.SetTestPattern({ Pattern = "Color Bars" })
equal("test pattern by name", stub.lastSent(), "(ITP 9)")

setup()
Commands.SetTestPattern({ Pattern = "Boresight" })
equal("test pattern with a gap in numbering", stub.lastSent(), "(ITP 21)")

setup()
Commands.SetTestPattern({ Pattern = "Nonexistent" })
equal("unknown test pattern is refused", #stub.sent, 0)

setup()
Commands.ShutterClose()
equal("shutter close", stub.lastSent(), "(SHU 1)")

setup()
Commands.SetLiteLOC({ Enabled = "True" })
equal("liteloc on sends 3", stub.lastSent(), "(LAS+STAT 3)")
Commands.SetLiteLOC({ Enabled = "False" })
equal("liteloc off sends 1", stub.lastSent(), "(LAS+STAT 1)")

setup()
Commands.SendRaw({ Command = "LAS+POWR?" })
equal("raw command gets wrapped", stub.lastSent(), "(LAS+POWR?)")
Commands.SendRaw({ Command = "(GAM?)" })
equal("raw command already wrapped is left alone", stub.lastSent(), "(GAM?)")

-- Naively wrapping "SHU 1) ($PWR 0" would produce "(SHU 1) ($PWR 0)" --
-- two complete commands smuggled past the framing in one Command string.
setup()
Commands.SendRaw({ Command = "SHU 1) ($PWR 0" })
equal("raw command smuggling a second message is refused", #stub.sent, 0)
equal("refusal is logged", #stub.printed > 0, true)

setup()
Commands.SendRaw({ Command = "(SHU 1)(PWR 0)" })
equal("raw command already wrapping two messages is refused", #stub.sent, 0)

--=============================================================================
-- Lens
--=============================================================================

setup()
stub.receive("(FCS!1100)(ZOM!-267)(LHO!-1032)(LVO!-1417)")
equal("lens focus parsed", State.lens.focus, 1100)
equal("lens zoom parsed (negative)", State.lens.zoom, -267)
equal("lens horizontal parsed", State.lens.h, -1032)
equal("lens vertical variable", stub.variables["LENS_V"], "-1417")

-- The projector rejects lens moves in standby, so the driver refuses to send
-- them rather than letting the command silently fail.
setup()
State.power = PWR_STANDBY
Commands.SetLensPosition({ Axis = "Focus", Position = "1200" })
equal("lens move refused in standby", #stub.sent, 0)

setup()
State.power = PWR_ON
Commands.SetLensPosition({ Axis = "Focus", Position = "1200" })
equal("lens move sent when on", stub.lastSent(), "(FCS 1200)")

setup()
State.power = PWR_ON
Commands.SetLensPosition({ Axis = "Vertical", Position = "-1400" })
equal("negative lens position", stub.lastSent(), "(LVO -1400)")

setup()
State.power = PWR_ON
Commands.SetLensPosition({ Axis = "Nonsense", Position = "10" })
equal("unknown lens axis refused", #stub.sent, 0)

setup()
State.power = PWR_ON
stub.receive("(ZOM!-267)")
Commands.NudgeLens({ Axis = "Zoom", Steps = "33" })
equal("nudge is relative to the last known position", stub.lastSent(), "(ZOM -234)")

setup()
State.power = PWR_ON
Commands.NudgeLens({ Axis = "Zoom", Steps = "10" })
equal("nudge refused when position unknown", #stub.sent, 0)

-- Presets are synthesised by the driver, since the projector has no lens
-- memory of its own.
setup()
State.power = PWR_ON
stub.receive("(FCS!1100)(ZOM!-267)(LHO!-1032)(LVO!-1417)")
Commands.SaveLensPreset({ Preset = "1" })
stub.reset()
Commands.RecallLensPreset({ Preset = "1" })
local recalled = {}
for _, message in ipairs(stub.sentMessages()) do recalled[message] = true end
check("recall moves focus", recalled["(FCS 1100)"])
check("recall moves zoom", recalled["(ZOM -267)"])
check("recall moves horizontal", recalled["(LHO -1032)"])
check("recall moves vertical", recalled["(LVO -1417)"])

setup()
State.power = PWR_ON
Commands.RecallLensPreset({ Preset = "4" })
equal("recalling an unsaved preset does nothing", #stub.sent, 0)

setup()
State.power = PWR_STANDBY
Commands.RecallLensPreset({ Preset = "1" })
equal("preset recall refused in standby", #stub.sent, 0)

-- Nothing should be written while the link is down.
setup()
State.connected = false
ProxyCommands.ON()
equal("no traffic while disconnected", #stub.sent, 0)

--=============================================================================

say(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
