--[[
    A stand-in for the Control4 Lua environment, so driver.lua can be loaded
    and exercised off-controller.

    This exists because installing the driver requires Composer Pro, which
    means every on-device test cycle is expensive. Everything the driver does
    that isn't a C4 call -- protocol framing, reply parsing, state tracking,
    command dispatch -- can be verified here instead.

    It implements only the subset of the API driver.lua actually uses, and
    records calls so tests can assert on them.
]]

local stub = {}

stub.sent      = {}   -- messages written to the network binding
stub.proxy     = {}   -- { binding, command, params } sent to the proxy
stub.variables = {}   -- variable name -> value
stub.timers    = {}   -- pending timers, fired manually by tests
stub.printed   = {}

--- Reset all recorded state between tests.
function stub.reset()
    stub.sent, stub.proxy, stub.variables, stub.timers, stub.printed = {}, {}, {}, {}, {}
end

local Timer = {}
Timer.__index = Timer
function Timer:Cancel() self.cancelled = true end

local C4 = {}

function C4:SendToNetwork(binding, port, data)
    table.insert(stub.sent, { binding = binding, port = port, data = data })
end

function C4:SendToProxy(binding, command, params)
    table.insert(stub.proxy, { binding = binding, command = command, params = params or {} })
end

function C4:AddVariable(name, value, kind, readonly)
    stub.variables[name] = value
end

function C4:SetVariable(name, value)
    stub.variables[name] = value
end

function C4:UpdateProperty(name, value)
    Properties[name] = value
end

function C4:SetTimer(ms, callback, repeating)
    local timer = setmetatable(
        { ms = ms, callback = callback, repeating = repeating, cancelled = false }, Timer)
    table.insert(stub.timers, timer)
    return timer
end

-- Driver-scoped persistence, used for the synthesised lens presets.
stub.persisted = {}
function C4:PersistSetValue(name, value, encrypted) stub.persisted[name] = value end
function C4:PersistGetValue(name, encrypted) return stub.persisted[name] end

function C4:NetConnect(binding, port) stub.connected = true end
function C4:NetDisconnect(binding, port) stub.connected = false end
function C4:ErrorLog(message) table.insert(stub.printed, message) end
function C4:AllowExecute(_) end

--- Fire every pending non-cancelled timer once, in the order created.
function stub.fireTimers()
    local pending = stub.timers
    stub.timers = {}
    for _, timer in ipairs(pending) do
        if (not timer.cancelled) then timer.callback(timer) end
    end
end

--- Feed bytes to the driver exactly as Director would, optionally split at
--- arbitrary boundaries to prove the framing survives fragmentation.
function stub.receive(data, chunkSize)
    if (chunkSize == nil) then
        ReceivedFromNetwork(6001, 3002, data)
        return
    end
    for i = 1, #data, chunkSize do
        ReceivedFromNetwork(6001, 3002, data:sub(i, i + chunkSize - 1))
    end
end

--- The last thing written to the network, or nil.
function stub.lastSent()
    local entry = stub.sent[#stub.sent]
    return entry and entry.data or nil
end

--- All network writes as a plain list of strings.
function stub.sentMessages()
    local out = {}
    for i, entry in ipairs(stub.sent) do out[i] = entry.data end
    return out
end

-- Globals the driver expects to already exist.
_G.C4 = C4
_G.Properties = {
    ["Debug Mode"]    = "Off",
    ["Poll Interval"] = "30",
    ["Input 1 Index"] = "1",
    ["Input 2 Index"] = "2",
    ["Input 3 Index"] = "3",
    ["Input 4 Index"] = "4",
    ["Driver Version"] = "1.0.1",
}

-- driver.lua's own print() is captured rather than shown, so tests can assert
-- on it. Tests need the real one to report their results.
local realPrint = print
stub.realPrint = realPrint
_G.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    table.insert(stub.printed, table.concat(parts, "\t"))
    if (os.getenv("C4_VERBOSE")) then realPrint(...) end
end

return stub
