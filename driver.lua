--[[
    Christie M 4K25 RGB - Control4 DriverWorks driver

    Speaks Christie's serial API over TCP 3002. Built for main control board
    software 1.3.x: the codes and reply shapes below were established against
    a physical M 4K25 RGB running 1.3.9 (SST+VERS -> "ChristieM 1.3.9"), and
    re-verified via `make live-test` after the same unit was updated to
    1.3.10, with no behavior changes. Which codes exist at all is a property
    of the firmware rather than the model. See the py-christie-mseries
    Python library (a sibling repo, not vendored here) for the long-form
    write-up of each quirk.

    Three things about this protocol drive the design here:

      * Replies pair a number with the projector's own description of it,
        e.g. (PWR!000 "Standby Mode"), so the data is not a bare integer.
      * A successful SET is answered with silence; a rejected one returns an
        error message with no code of its own. Because this driver parses
        every inbound message and routes it by code rather than doing a
        blocking read after each write, a stray error is simply logged
        instead of being mistaken for the next reply.
      * For a few seconds after a power command the projector accepts a TCP
        connection but answers nothing. Silence therefore means "unknown",
        never "off".
]]

-- Binding IDs. Ranges are fixed by Control4: proxies 5000-5999,
-- network 6000-6999, video inputs 1000-1099.
PROXY_BINDING     = 5001
NETWORK_BINDING   = 6001
PROJECTOR_PORT    = 3002
INPUT_BINDINGS    = { 1001, 1002, 1003, 1004 }

-- The projector reports brightness in tenths of a percent and refuses to run
-- the lasers below its published soft minimum of 20%. The floor here is
-- Christie's recommended 30% rather than that: their release notes list
-- "LiteLOC performance is compromised when running at low brightness levels
-- (30% or less) ... laser devices may shut down and colors may drop out" as
-- an open known issue, and LiteLOC is enabled on this unit.
BRIGHTNESS_MIN    = 30
BRIGHTNESS_MAX    = 100

-- LAS+STAT is not a boolean: 3 is on, 1 is off.
LITELOC_ENABLED   = 3
LITELOC_DISABLED  = 1

-- Power codes from PWR. 10/11 are transitional.
PWR_STANDBY, PWR_ON, PWR_COOLING, PWR_WARMING = 0, 1, 10, 11

-- Test patterns, exactly as the projector's own menu lists them.
TEST_PATTERNS = {
    [0] = "Off",            [1] = "Grid",              [2] = "Gray Scale 16",
    [3] = "Flat White",     [4] = "Flat Gray",         [5] = "Flat Black",
    [6] = "Checker",        [7] = "17 Point",          [8] = "Edge Blend",
    [9] = "Color Bars",    [10] = "Multi-color",      [11] = "RGBW Ramp",
   [12] = "Horizontal Ramp", [13] = "Vertical Ramp",  [14] = "Diagonal Ramp",
   [15] = "Square Grid",   [16] = "Diagonal Grid",    [18] = "Prism / Convergence",
   [21] = "Boresight",     [23] = "Integrator Rod",   [28] = "Electronic Convergence",
}

-- Driver state. `power` is deliberately nil until the projector tells us,
-- so that "not yet known" is distinguishable from "off".
State = {
    connected     = false,
    power         = nil,
    powerText     = "",
    shutterOpen   = nil,
    input         = nil,
    inputName     = "",
    brightness    = nil,
    liteloc       = nil,
    testPattern   = nil,
    hours         = "",
    intakeTemp    = nil,
    alarms        = 0,
    model         = "",
    serial        = "",
    lens          = {},   -- focus / zoom / h / v, absolute motor positions
}

RxBuffer   = ""
StatusRows = {}          -- accumulates multi-message SST replies by group
PollTimer  = nil
DebugMode  = false
DebugTimer = nil

--=============================================================================
-- Logging
--=============================================================================

function Dbg(fmt, ...)
    if (DebugMode) then
        local ok, msg = pcall(string.format, fmt, ...)
        print("Christie: " .. (ok and msg or tostring(fmt)))
    end
end

function LogError(fmt, ...)
    local ok, msg = pcall(string.format, fmt, ...)
    msg = "Christie: " .. (ok and msg or tostring(fmt))
    print(msg)
    if (C4 and C4.ErrorLog) then C4:ErrorLog(msg) end
end

--=============================================================================
-- Protocol. Pure string functions, kept free of any C4 call so the test
-- harness in tests/ can exercise them off-controller.
--=============================================================================

Protocol = {}

--- Undo the backslash escaping the projector applies inside quoted text,
--- e.g. "3:14 \(h:m\)" -> "3:14 (h:m)".
function Protocol.Unescape(text)
    return (text:gsub("\\(.)", "%1"))
end

--- Build a request or a set: (CODE?), (CODE+SUB?), (CODE data).
--- Returns nil (after LogError) for a code/subcode/data shape that doesn't
--- fit the wire format, rather than silently building a message a stray (or
--- deliberately crafted) parenthesis could use to smuggle a second command
--- past the "(...)" framing -- mirrors py-christie-mseries's build_message().
function Protocol.Build(code, subcode, data, query)
    if (not code or not code:match("^%a%a%a$")) then
        LogError("invalid code %s: must be exactly 3 letters", tostring(code))
        return nil
    end
    if (subcode and subcode ~= "" and not subcode:match("^%w%w%w%w$")) then
        LogError("invalid subcode %s: must be exactly 4 letters/digits", tostring(subcode))
        return nil
    end
    if (type(data) == "string" and (data:find("[()]") or data:find("%c"))) then
        LogError("invalid data %s: parentheses/control characters would corrupt the message framing", data)
        return nil
    end

    local body = code
    if (subcode and subcode ~= "") then body = body .. "+" .. subcode end
    if (query) then return "(" .. body .. "?)" end
    if (data == nil) then return "(" .. body .. ")" end
    return "(" .. body .. " " .. tostring(data) .. ")"
end

--- Pull the first complete (...) message out of `buf`.
--- Returns message, remainder. Message is nil if `buf` holds a partial one.
--- Respects the \( \) escape so quoted text with literal parens can't break
--- framing.
function Protocol.Split(buf)
    local depth, started, escape = 0, false, false
    for i = 1, #buf do
        local c = buf:sub(i, i)
        if (escape) then
            escape = false
        elseif (c == "\\") then
            escape = true
        elseif (c == "(") then
            depth = depth + 1
            started = true
        elseif (c == ")") then
            depth = depth - 1
            if (started and depth == 0) then
                return buf:sub(1, i), buf:sub(i + 1)
            end
        end
    end
    return nil, buf
end

--- Extract the first double-quoted run from `data`, honouring backslash
--- escapes. Lua patterns can't express that, so this scans by hand.
function Protocol.FirstQuoted(data)
    local start = nil
    local escape = false
    for i = 1, #data do
        local c = data:sub(i, i)
        if (start == nil) then
            if (c == '"') then start = i + 1 end
        elseif (escape) then
            escape = false
        elseif (c == "\\") then
            escape = true
        elseif (c == '"') then
            return Protocol.Unescape(data:sub(start, i - 1))
        end
    end
    return nil
end

--- Split reply data into its leading number and first quoted description.
--- Replies are not uniform: some are bare numbers, some pair a number with a
--- label ((PWR!000 "Standby Mode")), some are text only.
function Protocol.Value(data)
    local number = data:match("^%s*(%-?%d+)")
    return (number and tonumber(number) or nil), Protocol.FirstQuoted(data)
end

--- Parse one complete (...) message into a table.
--- Errors are returned as { err = <code>, text = <message> }; they carry no
--- code of their own, which is why they're detected first.
function Protocol.Parse(message)
    local body = message:sub(2, #message - 1)

    local errCode, errText = body:match('ERR(%d+)%s+"(.-)"')
    if (errCode) then
        return { err = tonumber(errCode), text = Protocol.Unescape(errText) }
    end

    local code = body:match("^(%a%a%a)")
    if (not code) then return nil end

    local rest = body:sub(4)
    local subcode = nil
    if (rest:sub(1, 1) == "+") then
        subcode = rest:sub(2, 5)
        rest = rest:sub(6)
    end
    local op = rest:sub(1, 1)
    if (op == "!" or op == "?") then rest = rest:sub(2) else op = "" end

    return { code = code, subcode = subcode, op = op, data = rest }
end

--=============================================================================
-- Transmit
--=============================================================================

function Send(code, subcode, data, query)
    if (not State.connected) then
        Dbg("not connected, dropping %s", tostring(code))
        return
    end
    local message = Protocol.Build(code, subcode, data, query)
    if (message == nil) then return end
    Dbg("TX %s", message)
    C4:SendToNetwork(NETWORK_BINDING, PROJECTOR_PORT, message)
end

function Query(code, subcode) Send(code, subcode, nil, true) end
function Set(code, subcode, data) Send(code, subcode, data, false) end

--=============================================================================
-- Receive
--=============================================================================

function ReceivedFromNetwork(idBinding, nPort, strData)
    RxBuffer = RxBuffer .. strData
    -- Guard against a runaway buffer if the projector ever sends something
    -- that never closes its parenthesis.
    if (#RxBuffer > 65536) then
        LogError("receive buffer overflow, discarding")
        RxBuffer = ""
        return
    end

    while (true) do
        local message, remainder = Protocol.Split(RxBuffer)
        if (message == nil) then break end
        RxBuffer = remainder
        Dbg("RX %s", message)
        local ok, err = pcall(HandleMessage, message)
        if (not ok) then LogError("error handling %s: %s", message, tostring(err)) end
    end
end

function HandleMessage(message)
    local reply = Protocol.Parse(message)
    if (reply == nil) then return end

    if (reply.err) then
        -- 101 Control Not Found, 105 Disabled Control (e.g. image controls
        -- rejected while in standby). Neither is fatal; log and carry on.
        Dbg("projector error %d: %s", reply.err, reply.text or "")
        return
    end

    local handler = Handlers[reply.code]
    if (handler) then
        handler(reply)
    else
        Dbg("unhandled code %s", reply.code)
    end
end

Handlers = {}

function Handlers.PWR(reply)
    local code, text = Protocol.Value(reply.data)
    if (code == nil) then return end

    State.power = code
    State.powerText = text or ""
    SetVariable("POWER_STATE", State.powerText)

    -- Only ON and STANDBY are reported to the proxy. During WARMING/COOLING
    -- the projector is mid-transition and the proxy should keep its last
    -- state rather than flapping.
    if (code == PWR_ON) then
        C4:SendToProxy(PROXY_BINDING, "ON", {})
    elseif (code == PWR_STANDBY) then
        C4:SendToProxy(PROXY_BINDING, "OFF", {})
    end
end

function Handlers.SHU(reply)
    local value = Protocol.Value(reply.data)
    if (value == nil) then return end
    -- SHU is 0 for open, 1 for closed -- the opposite sense to the name.
    State.shutterOpen = (value == 0)
    SetVariable("SHUTTER_OPEN", State.shutterOpen and "1" or "0")
end

function Handlers.SIN(reply)
    local index, name = Protocol.Value(reply.data)
    if (index == nil) then return end
    State.input = index
    State.inputName = name or ""
    SetVariable("INPUT_NAME", State.inputName)

    local binding = BindingForInput(index)
    if (binding) then
        C4:SendToProxy(PROXY_BINDING, "INPUT_CHANGED", { INPUT = binding })
    end
end

function Handlers.ITP(reply)
    local value = Protocol.Value(reply.data)
    if (value == nil) then return end
    State.testPattern = value
    SetVariable("TEST_PATTERN", TEST_PATTERNS[value] or tostring(value))
end

function Handlers.LAS(reply)
    if (reply.subcode == "POWR") then
        local tenths = Protocol.Value(reply.data)
        if (tenths == nil) then return end
        State.brightness = tenths / 10
        SetVariable("BRIGHTNESS", string.format("%.1f", State.brightness))
    elseif (reply.subcode == "STAT") then
        local value = Protocol.Value(reply.data)
        if (value == nil) then return end
        State.liteloc = (value == LITELOC_ENABLED)
        SetVariable("LITELOC", State.liteloc and "1" or "0")
    end
end

-- Lens motor positions. These are absolute step counts whose valid range
-- depends on the lens fitted, so the projector does not publish a min/max and
-- neither does this driver -- an out-of-range value is rejected by the
-- projector rather than clamped here.
LENS_AXES = {
    Focus      = { code = "FCS", variable = "LENS_FOCUS", field = "focus" },
    Zoom       = { code = "ZOM", variable = "LENS_ZOOM",  field = "zoom"  },
    Horizontal = { code = "LHO", variable = "LENS_H",     field = "h"     },
    Vertical   = { code = "LVO", variable = "LENS_V",     field = "v"     },
}

local function LensHandler(field, variable)
    return function(reply)
        local value = Protocol.Value(reply.data)
        if (value == nil) then return end
        State.lens[field] = value
        SetVariable(variable, tostring(value))
    end
end

Handlers.FCS = LensHandler("focus", "LENS_FOCUS")
Handlers.ZOM = LensHandler("zoom",  "LENS_ZOOM")
Handlers.LHO = LensHandler("h",     "LENS_H")
Handlers.LVO = LensHandler("v",     "LENS_V")

--- SST answers with one message per item and no terminator, so items are
--- accumulated as they arrive rather than waited for as a block. Each looks
--- like: SST+TEMP!002 000 "34 °C" "Air Intake Temperature (Temp 2)"
function Handlers.SST(reply)
    local group = reply.subcode
    if (group == nil) then return end

    local value, label = nil, nil
    local quotes = {}
    local rest = reply.data
    while (true) do
        local found = Protocol.FirstQuoted(rest)
        if (found == nil) then break end
        quotes[#quotes + 1] = found
        local _, closeAt = rest:find('".-[^\\]"')
        if (closeAt == nil) then break end
        rest = rest:sub(closeAt + 1)
        if (#quotes >= 2) then break end
    end
    value, label = quotes[1], quotes[2]
    if (label == nil or value == nil) then return end

    StatusRows[group] = StatusRows[group] or {}
    StatusRows[group][label] = value
    ApplyStatusRow(group, label, value)
end

function ApplyStatusRow(group, label, value)
    if (group == "SYST" and label == "Projector Hours") then
        State.hours = value
        SetVariable("HOURS", value)
    elseif (group == "TEMP" and label:find("Air Intake", 1, true)) then
        local number = value:match("(%-?%d+%.?%d*)")
        if (number) then
            State.intakeTemp = tonumber(number)
            SetVariable("INTAKE_TEMP", number)
        end
    elseif (group == "CONF" and label == "Projector Model") then
        State.model = value
    elseif (group == "CONF" and label == "Projector S/N") then
        State.serial = value
    end
end

--=============================================================================
-- Polling
--=============================================================================

--- Fast poll: the things a user can change from the projector's own remote
--- or front panel, so the Control4 UI stays truthful.
function PollFast()
    Query("PWR")
    Query("SHU")
    Query("SIN")
    Query("ITP")
    Query("LAS", "POWR")
    Query("LAS", "STAT")
end

--- Slow poll: diagnostics that change on the scale of hours. Each SST group
--- answers with many messages, so these are kept off the fast path.
function PollSlow()
    Query("SST", "SYST")
    Query("SST", "TEMP")

    -- Alarms are counted rather than read from a field: a healthy projector
    -- answers SST+ALRM with error 9 ("no status items") and sends no rows at
    -- all. Since an error message carries no code, it can't be attributed to
    -- the group that caused it -- so the count is taken by clearing the group
    -- and seeing how many rows arrive.
    -- Lens positions only change when something moves them, so they belong
    -- on the slow path rather than the 30-second one.
    PollLens()

    StatusRows["ALRM"] = {}
    Query("SST", "ALRM")
    C4:SetTimer(3000, function()
        local count = 0
        for _ in pairs(StatusRows["ALRM"] or {}) do count = count + 1 end
        State.alarms = count
        SetVariable("ALARMS", tostring(count))
    end)
end

function StartPolling()
    if (PollTimer) then PollTimer:Cancel() end
    local seconds = tonumber(Properties["Poll Interval"]) or 30
    if (seconds < 5) then seconds = 5 end

    local ticks = 0
    PollTimer = C4:SetTimer(seconds * 1000, function()
        if (not State.connected) then return end
        PollFast()
        ticks = ticks + 1
        -- Diagnostics roughly every ten fast polls.
        if (ticks % 10 == 1) then PollSlow() end
    end, true)
end

--=============================================================================
-- Inputs
--=============================================================================

--- SIN index configured for a Control4 video input binding.
function InputIndexForBinding(binding)
    for position, id in ipairs(INPUT_BINDINGS) do
        if (id == binding) then
            return tonumber(Properties["Input " .. position .. " Index"]) or position
        end
    end
    return nil
end

function BindingForInput(index)
    for position, id in ipairs(INPUT_BINDINGS) do
        if ((tonumber(Properties["Input " .. position .. " Index"]) or position) == index) then
            return id
        end
    end
    return nil
end

--- The SIN index that follows the current one, wrapping round. Walks the
--- configured Input N Index values rather than counting 1..4, since those
--- properties can name any indices the projector happens to use.
function NextInputIndex()
    local indices = {}
    for position = 1, #INPUT_BINDINGS do
        indices[position] = tonumber(Properties["Input " .. position .. " Index"]) or position
    end
    for position, index in ipairs(indices) do
        if (index == State.input) then
            return indices[(position % #indices) + 1]
        end
    end
    -- Current input is not one of the configured four (or is not known yet),
    -- so start from the first.
    return indices[1]
end

--=============================================================================
-- Control4 lifecycle
--=============================================================================

function OnDriverInit()
    -- Variables must be created here; adding them later breaks programming
    -- across a Director restart.
    C4:AddVariable("POWER_STATE",  "",    "STRING", true)
    C4:AddVariable("BRIGHTNESS",   "0",   "FLOAT",  true)
    C4:AddVariable("LITELOC",      "0",   "BOOL",   true)
    C4:AddVariable("SHUTTER_OPEN", "0",   "BOOL",   true)
    C4:AddVariable("INPUT_NAME",   "",    "STRING", true)
    C4:AddVariable("TEST_PATTERN", "Off", "STRING", true)
    -- Hours is a string because the projector reports "4:23 (h:m)", not a number.
    C4:AddVariable("HOURS",        "",    "STRING", true)
    C4:AddVariable("INTAKE_TEMP",  "0",   "FLOAT",  true)
    C4:AddVariable("ALARMS",       "0",   "INT",    true)
    C4:AddVariable("CONNECTED",    "0",   "BOOL",   true)
    -- Absolute lens motor positions; range depends on the lens fitted.
    C4:AddVariable("LENS_FOCUS",   "0",   "INT",    true)
    C4:AddVariable("LENS_ZOOM",    "0",   "INT",    true)
    C4:AddVariable("LENS_H",       "0",   "INT",    true)
    C4:AddVariable("LENS_V",       "0",   "INT",    true)
end

function OnDriverLateInit()
    for name, _ in pairs(Properties) do OnPropertyChanged(name) end
    C4:NetConnect(NETWORK_BINDING, PROJECTOR_PORT)
    StartPolling()
end

function OnDriverDestroyed()
    if (PollTimer) then PollTimer:Cancel() end
    C4:NetDisconnect(NETWORK_BINDING, PROJECTOR_PORT)
end

function OnConnectionStatusChanged(idBinding, nPort, strStatus)
    if (idBinding ~= NETWORK_BINDING) then return end

    State.connected = (strStatus == "ONLINE")
    SetVariable("CONNECTED", State.connected and "1" or "0")
    Dbg("connection %s", tostring(strStatus))

    if (State.connected) then
        RxBuffer = ""
        -- Identity is static; read it once per connection rather than polling.
        Query("SST", "CONF")
        PollFast()
        PollSlow()
    else
        -- Don't claim to know the power state while the link is down.
        State.power = nil
    end
end

function OnPropertyChanged(strProperty)
    local value = Properties[strProperty]

    if (strProperty == "Debug Mode") then
        DebugMode = (value == "On")
        if (DebugTimer) then DebugTimer:Cancel(); DebugTimer = nil end
        if (DebugMode) then
            -- Never leave debug logging on permanently; it is noisy.
            DebugTimer = C4:SetTimer(3600000, function()
                DebugMode = false
                C4:UpdateProperty("Debug Mode", "Off")
            end)
        end
    elseif (strProperty == "Poll Interval") then
        StartPolling()
    end
end

--=============================================================================
-- Proxy commands (Navigator, room Watch, and the projector proxy)
--=============================================================================

function ReceivedFromProxy(idBinding, strCommand, tParams)
    if (strCommand == nil) then return end
    tParams = tParams or {}

    local handler = ProxyCommands[strCommand]
    if (handler) then
        local ok, err = pcall(handler, tParams)
        if (not ok) then LogError("proxy %s failed: %s", strCommand, tostring(err)) end
    else
        Dbg("unhandled proxy command %s", strCommand)
    end
end

ProxyCommands = {}

function ProxyCommands.ON()
    Set("PWR", nil, 1)
    -- Warm-up takes about 16 seconds and the projector answers nothing at all
    -- for the first few of them, so re-read once it can respond again rather
    -- than leaving Navigator stale until the next poll.
    C4:SetTimer(20000, function() Query("PWR") end)
end

function ProxyCommands.OFF()
    Set("PWR", nil, 0)
    C4:SetTimer(20000, function() Query("PWR") end)
end

function ProxyCommands.SET_INPUT(tParams)
    local binding = tonumber(tParams.INPUT)
    local index = binding and InputIndexForBinding(binding)
    if (index == nil) then
        LogError("no SIN index configured for input binding %s", tostring(tParams.INPUT))
        return
    end
    Set("SIN", nil, index)
    C4:SetTimer(1500, function() Query("SIN") end)
end

function ProxyCommands.PULSE_INPUT()
    Set("SIN", nil, NextInputIndex())
    C4:SetTimer(1500, function() Query("SIN") end)
end

--=============================================================================
-- Custom commands (Composer programming) and Actions
--=============================================================================

function ExecuteCommand(strCommand, tParams)
    tParams = tParams or {}
    local handler = Commands[strCommand]
    if (handler) then
        local ok, err = pcall(handler, tParams)
        if (not ok) then LogError("command %s failed: %s", strCommand, tostring(err)) end
    else
        Dbg("unhandled command %s", strCommand)
    end
end

Commands = {}

function Commands.ShutterOpen()  Set("SHU", nil, 0); C4:SetTimer(800, function() Query("SHU") end) end
function Commands.ShutterClose() Set("SHU", nil, 1); C4:SetTimer(800, function() Query("SHU") end) end

function Commands.SetBrightness(tParams)
    local percent = tonumber(tParams["Brightness"] or tParams["BRIGHTNESS"])
    if (percent == nil) then
        LogError("SetBrightness needs a number")
        return
    end
    if (percent < BRIGHTNESS_MIN or percent > BRIGHTNESS_MAX) then
        LogError("brightness %s out of range %d-%d (the projector will not run "
                 .. "the lasers below its %d%% soft minimum)",
                 tostring(percent), BRIGHTNESS_MIN, BRIGHTNESS_MAX, BRIGHTNESS_MIN)
        return
    end
    -- Sent in tenths of a percent.
    Set("LAS", "POWR", math.floor(percent * 10 + 0.5))
    C4:SetTimer(800, function() Query("LAS", "POWR") end)
end

function Commands.SetTestPattern(tParams)
    local wanted = tParams["Pattern"] or tParams["PATTERN"]
    if (wanted == nil) then return end

    local value = tonumber(wanted)
    if (value == nil) then
        for number, name in pairs(TEST_PATTERNS) do
            if (name == wanted) then value = number break end
        end
    end
    if (value == nil) then
        LogError("unknown test pattern %s", tostring(wanted))
        return
    end
    -- Rejected with "Disabled Control" while in standby; image controls only
    -- accept writes once the projector is on.
    Set("ITP", nil, value)
    C4:SetTimer(800, function() Query("ITP") end)
end

function Commands.SetLiteLOC(tParams)
    local wanted = tParams["Enabled"] or tParams["ENABLED"]
    local on = (wanted == "True" or wanted == "true" or wanted == true or wanted == 1 or wanted == "1")
    Set("LAS", "STAT", on and LITELOC_ENABLED or LITELOC_DISABLED)
    C4:SetTimer(800, function() Query("LAS", "STAT") end)
end

--=============================================================================
-- Lens
--
-- Positions are readable at any time but only *movable* while the projector
-- is on: in standby every lens code answers ERR00105 "Disabled Control", the
-- same gate that applies to image controls. That is checked up front so the
-- installer gets a clear reason rather than a silent no-op.
--
-- This projector has no lens memory of its own (the ILS codes are absent, and
-- recalling a channel does not move the lens), so presets are synthesised
-- here: the four motor positions are persisted by the driver and replayed as
-- absolute moves. That is what makes a scope / 16:9 screen-ratio preset
-- possible at all on this unit.
--=============================================================================

--- True if the projector will currently accept a lens move.
function LensMovable()
    if (State.power ~= PWR_ON) then
        LogError("lens moves are rejected unless the projector is on "
                 .. "(power is currently %s)", tostring(State.powerText ~= "" and State.powerText or "unknown"))
        return false
    end
    return true
end

function MoveLens(axisName, position)
    local axis = LENS_AXES[axisName]
    if (axis == nil) then
        LogError("unknown lens axis %s", tostring(axisName))
        return
    end
    if (not LensMovable()) then return end

    Set(axis.code, nil, math.floor(tonumber(position)))
    -- Motors take a moment to travel; read back once they have settled.
    C4:SetTimer(3000, function() Query(axis.code) end)
end

function Commands.SetLensPosition(tParams)
    local axis = tParams["Axis"]
    local position = tonumber(tParams["Position"])
    if (axis == nil or position == nil) then
        LogError("SetLensPosition needs an axis and a position")
        return
    end
    MoveLens(axis, position)
end

--- Relative move, for nudging focus or offset from a keypad.
function Commands.NudgeLens(tParams)
    local axisName = tParams["Axis"]
    local steps = tonumber(tParams["Steps"])
    local axis = axisName and LENS_AXES[axisName]
    if (axis == nil or steps == nil) then
        LogError("NudgeLens needs an axis and a step count")
        return
    end
    local current = State.lens[axis.field]
    if (current == nil) then
        LogError("current %s position unknown; run Refresh Status first", axisName)
        return
    end
    MoveLens(axisName, current + steps)
end

local function PresetKey(slot) return "lens_preset_" .. tostring(slot) end

function Commands.SaveLensPreset(tParams)
    local slot = tParams["Preset"]
    if (slot == nil) then return end

    local preset = {}
    for name, axis in pairs(LENS_AXES) do
        local value = State.lens[axis.field]
        if (value == nil) then
            LogError("cannot save preset %s: %s position not yet read", tostring(slot), name)
            return
        end
        preset[axis.field] = value
    end

    C4:PersistSetValue(PresetKey(slot), preset)
    print(string.format("Christie: saved lens preset %s (focus %d, zoom %d, h %d, v %d)",
                        tostring(slot), preset.focus, preset.zoom, preset.h, preset.v))
end

function Commands.RecallLensPreset(tParams)
    local slot = tParams["Preset"]
    if (slot == nil) then return end

    local preset = C4:PersistGetValue(PresetKey(slot))
    if (type(preset) ~= "table") then
        LogError("lens preset %s has not been saved", tostring(slot))
        return
    end
    if (not LensMovable()) then return end

    for _, axis in pairs(LENS_AXES) do
        local value = preset[axis.field]
        if (value ~= nil) then Set(axis.code, nil, value) end
    end
    C4:SetTimer(5000, PollLens)
end

function PollLens()
    for _, axis in pairs(LENS_AXES) do Query(axis.code) end
end

--- Escape hatch: send any code the driver doesn't wrap, e.g. "GAM?" or
--- "LAS+POWR?" to read, "SHU 1" to write.
function Commands.SendRaw(tParams)
    local text = tParams["Command"] or tParams["COMMAND"]
    if (text == nil or text == "") then return end
    if (not State.connected) then
        LogError("not connected; cannot send %s", text)
        return
    end
    local message = text
    if (message:sub(1, 1) ~= "(") then message = "(" .. message .. ")" end

    -- Unlike Protocol.Build, this accepts free-form text, so it can't be
    -- shape-checked against a single code/subcode/data -- but it must still
    -- be exactly *one* wire message. Without this, a Command like
    -- "SHU 1) ($PWR 0" would wrap into "(SHU 1) ($PWR 0)", smuggling a
    -- second command past the framing.
    local first, rest = Protocol.Split(message)
    if (first == nil or rest ~= "") then
        LogError("invalid raw command %s: must be exactly one \"(...)\" message", text)
        return
    end

    Dbg("TX %s (raw)", message)
    C4:SendToNetwork(NETWORK_BINDING, PROJECTOR_PORT, message)
end

function Commands.RefreshStatus()
    PollFast()
    PollSlow()
end

function Commands.PrintStatus()
    print("Christie M 4K25 RGB")
    print("  connected:   " .. tostring(State.connected))
    print("  power:       " .. tostring(State.powerText) .. " (" .. tostring(State.power) .. ")")
    print("  shutter:     " .. (State.shutterOpen == nil and "unknown"
                                or (State.shutterOpen and "open" or "closed")))
    print("  input:       " .. tostring(State.input) .. " " .. tostring(State.inputName))
    print("  brightness:  " .. tostring(State.brightness) .. "%")
    print("  LiteLOC:     " .. tostring(State.liteloc))
    print("  pattern:     " .. tostring(TEST_PATTERNS[State.testPattern or -1]))
    print(string.format("  lens:        focus %s  zoom %s  h %s  v %s",
                        tostring(State.lens.focus), tostring(State.lens.zoom),
                        tostring(State.lens.h), tostring(State.lens.v)))
    print("  hours:       " .. tostring(State.hours))
    print("  intake temp: " .. tostring(State.intakeTemp))
    print("  model/serial:" .. tostring(State.model) .. " / " .. tostring(State.serial))
end

--=============================================================================
-- Helpers
--=============================================================================

function SetVariable(name, value)
    if (C4 and C4.SetVariable) then C4:SetVariable(name, value) end
end
