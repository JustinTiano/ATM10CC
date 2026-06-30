-- control.lua
-- START/STOP command channel for fleet turtles, mirroring the dashboard.
--
--   local control = require("control")
--   control.tag("quarry")                       -- our own command tag
--   parallel.waitForAny(control.listen, worker)  -- listen runs alongside work
--
-- The dashboard broadcasts { to = <tag>, cmd = "start"|"stop" } (serialised).
-- `listen` runs forever in parallel with the worker and only sets flags; the
-- worker decides WHEN to honor them (at safe checkpoints) so it never parks or
-- resumes from a half-finished position.
--
-- Requires rednet to already be open (nav.open does this).

local control = {}

local tag      = "turtle"
local stopReq  = false
local hardStop = false
local startReq = false

function control.tag(t) tag = t or tag end

-- Forever loop: accept only commands addressed to us. The turtle also hears its
-- own status broadcasts (they carry `from`, not `to`/`cmd`) and other turtles'
-- commands -- both are filtered out here.
--
-- STOP is two-stage. The first STOP is a CYCLE stop (stopReq): the worker finishes
-- its current unit -- layer / corridor / sweep -- then parks, so resume is cheap
-- (no re-walking). A SECOND STOP while one is already pending escalates to a HARD
-- stop (hardStop): the worker bails at its next safe checkpoint and heads home
-- right away, accepting that it'll redo the current unit on resume.
function control.listen()
  while true do
    local _, raw = rednet.receive()
    local msg = (type(raw) == "string") and textutils.unserialise(raw) or raw
    if type(msg) == "table" and msg.to == tag and msg.cmd then
      if msg.cmd == "stop" then
        if stopReq then hardStop = true else stopReq = true end
      elseif msg.cmd == "start" then
        startReq, stopReq, hardStop = true, false, false
      end
    end
  end
end

-- True once a STOP (of either kind) is pending and not yet acknowledged.
function control.stopRequested() return stopReq end

-- True once a STOP has been escalated to a hard stop (a second STOP tap).
function control.hardStopRequested() return hardStop end

-- The worker calls this after it has parked to a safe state, to clear the flags.
function control.ackStop() stopReq, hardStop = false, false end

-- Block (letting `listen` keep running in parallel) until a START arrives.
function control.waitForStart()
  startReq = false
  while not startReq do sleep(0.5) end
  startReq = false
end

----------------------------------------------------------------------
-- Persistent run-state. The START/STOP flags above live only in RAM, so a
-- reboot (chunk reload / server restart) forgets them and startup.lua would
-- blindly resume the dig. This records the INTENT to disk so startup honors it
-- across reboots: a parked turtle stays parked instead of digging back into your
-- base. Values: "run" | "stopped" | "done". A missing file means "never set" and
-- startup treats it as a first run (i.e. "run").
----------------------------------------------------------------------
local RUNSTATE_FILE = "runstate.txt"

function control.setRunState(s)
  local f = fs.open(RUNSTATE_FILE, "w")
  f.write(s)
  f.close()
end

function control.getRunState()
  if not fs.exists(RUNSTATE_FILE) then return nil end
  local f = fs.open(RUNSTATE_FILE, "r")
  local s = (f.readLine() or ""):gsub("%s+", "")
  f.close()
  if s == "" then return nil end
  return s
end

return control
