-- startup.lua -- runs automatically on boot (chunk reload / server restart).
--
-- Reads role.txt ("quarry" | "stripmine" | "treefarm") to pick the program, and
-- runstate.txt to decide whether to RUN it. The dashboard's STOP makes a worker
-- persist runstate="stopped"; START clears it back to "run". So a turtle that was
-- parked stays parked across reboots instead of silently resuming into your base.
--
--   runstate (missing) -> first run: launch and let it anchor / resume
--   runstate "run"      -> launch (the program resumes from its .state via GPS)
--   runstate "stopped"  -> DON'T dig; sit at base and listen for a START from the
--                          dashboard, then launch
--   runstate "done"     -> job finished cleanly; drop to shell
--
-- The monitor computer has no role.txt and just drops to the shell.

local RUNSTATE_FILE = "runstate.txt"

local function readWord(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  local s = (f.readLine() or ""):gsub("%s+", "")
  f.close()
  if s == "" then return nil end
  return s
end

local function writeWord(path, s)
  local f = fs.open(path, "w")
  f.write(s)
  f.close()
end

local role = readWord("role.txt")
if not role then
  print("startup: no role.txt -- dropping to shell.")
  return
end

local program = role .. ".lua"
if not fs.exists(program) then
  print("startup: " .. program .. " not found -- dropping to shell.")
  return
end

local runstate = readWord(RUNSTATE_FILE)

-- A Ctrl+T-able wait: returns true if the user pressed Ctrl+T during it. We use
-- pullEventRaw so a terminate is a value we can act on, not a fatal error.
local function abortableSleep(secs)
  local timer = os.startTimer(secs)
  while true do
    local e = { os.pullEventRaw() }
    if e[1] == "terminate" then return true end
    if e[1] == "timer" and e[2] == timer then return false end
  end
end

----------------------------------------------------------------------
-- Job finished cleanly last time: nothing to resume. Stay at the shell so the
-- turtle never re-digs a completed quarry on a chunk reload.
----------------------------------------------------------------------
if runstate == "done" then
  print("startup: last " .. role .. " job finished -- dropping to shell.")
  print("(delete " .. RUNSTATE_FILE .. ", or re-run " .. program .. ", to start again.)")
  return
end

----------------------------------------------------------------------
-- Parked by a dashboard STOP: do NOT move. Open rednet and wait for a START so
-- the dashboard can resume the turtle remotely. Ctrl+T here drops to the shell.
----------------------------------------------------------------------
if runstate == "stopped" then
  local modem = peripheral.find("modem")
  if not modem then
    print("startup: parked, but no modem to hear START -- dropping to shell.")
    return
  end
  rednet.open(peripheral.getName(modem))
  print("startup: " .. role .. " is PARKED (STOP). Waiting for START from the dashboard...")
  print("(Ctrl+T to drop to shell instead.)")
  while true do
    local _, raw = rednet.receive()
    local msg = (type(raw) == "string") and textutils.unserialise(raw) or raw
    if type(msg) == "table" and msg.to == role and msg.cmd == "start" then
      break
    end
  end
  rednet.close(peripheral.getName(modem))   -- hand the modem back to the worker
  writeWord(RUNSTATE_FILE, "run")
  print("startup: START received -- launching " .. program .. ".")
end

----------------------------------------------------------------------
-- Launch. A short abort window first so a wrongly-resuming turtle can be caught
-- before it moves; cancelling parks it (so it won't relaunch on the next boot).
----------------------------------------------------------------------
print("startup: launching " .. program .. " in 3s (Ctrl+T to cancel)...")
if abortableSleep(3) then
  writeWord(RUNSTATE_FILE, "stopped")
  print("startup: cancelled -- parked. START from the dashboard to resume.")
  return
end

-- shell.run returns true on a clean exit (job done / halted on purpose) -> stop.
-- A false return is either a transient crash (lost GPS, chunk unload) or a user
-- Ctrl+T -- both look identical, so we pause in an abort window: stay quiet and
-- it retries (resuming from the .state via GPS); press Ctrl+T and it parks.
while true do
  if shell.run(program) then
    print("startup: " .. program .. " exited cleanly.")
    break
  end
  print("startup: " .. program .. " stopped; retrying in 10s (Ctrl+T to park)...")
  if abortableSleep(10) then
    writeWord(RUNSTATE_FILE, "stopped")
    print("startup: parked. START from the dashboard to resume.")
    break
  end
end
