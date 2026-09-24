--[[
    Runs the real driver.lua against the real projector.

    The offline tests prove the parsing against captured strings; this proves
    it against whatever the projector actually says today. It swaps the stub's
    SendToNetwork for a luasocket connection and pumps received bytes back
    through the driver's own ReceivedFromNetwork, so every code path below the
    Control4 API is the code that will ship.

    Read-only: it issues queries only, never a set.

    Run:  lua5.1 tests/live_test.lua 192.0.2.50
]]

package.path = "./?.lua;./tests/?.lua;" .. package.path

local socket = require("socket")
local stub = require("c4_stub")
dofile("driver.lua")

local say = stub.realPrint
local host = arg[1] or "192.0.2.50"
local port = 3002

local connection = assert(socket.tcp())
connection:settimeout(5)
local ok, err = connection:connect(host, port)
if (not ok) then
    say("Could not connect to " .. host .. ":" .. port .. " - " .. tostring(err))
    os.exit(1)
end
say("Connected to " .. host .. ":" .. port)

-- Route the driver's writes to the real socket.
function C4:SendToNetwork(binding, nPort, data)
    connection:send(data)
end

State.connected = true
RxBuffer = ""

--- Pump the socket for `seconds`, feeding everything to the driver.
local function pump(seconds)
    local deadline = socket.gettime() + seconds
    connection:settimeout(0.2)
    while (socket.gettime() < deadline) do
        local chunk, readErr, partial = connection:receive(1)
        local data = chunk or partial
        if (data and #data > 0) then
            ReceivedFromNetwork(6001, port, data)
        elseif (readErr == "closed") then
            say("Projector closed the connection")
            return
        end
    end
end

say("\nQuerying...")
PollFast()
pump(2)
-- Identity is read once per connection by the driver, not polled.
Query("SST", "CONF")
pump(2)
PollSlow()
pump(4)
stub.fireTimers()   -- lets the deferred alarm count run

say("\n--- State as the driver sees it ---")
Commands.PrintStatus()
for _, line in ipairs(stub.printed) do say(line) end

say("\n--- Variables Control4 would publish ---")
local names = {}
for name in pairs(stub.variables) do names[#names + 1] = name end
table.sort(names)
for _, name in ipairs(names) do
    say(string.format("  %-14s %s", name, tostring(stub.variables[name])))
end

say("\n--- Proxy notifications sent ---")
for _, entry in ipairs(stub.proxy) do
    local detail = ""
    for key, value in pairs(entry.params) do detail = detail .. key .. "=" .. tostring(value) end
    say("  " .. entry.command .. " " .. detail)
end

-- Anything still buffered means a message was never completed, which would
-- point at a framing bug.
if (#RxBuffer > 0) then
    say("\nWARNING: unparsed bytes left in buffer: " .. string.format("%q", RxBuffer))
else
    say("\nAll received bytes parsed cleanly.")
end

connection:close()
