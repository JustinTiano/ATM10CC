-- startup.lua -- runs automatically on boot (chunk reload / server restart).
--
-- Reads role.txt ("quarry" | "stripmine" | "oremine" | "treefarm") to pick the program, and
-- runstate.txt to decide whether to RUN it. The dashboard's STOP makes a worker
-- persist runstate="stopped"; START clears it back to "run". So a turtle that was
-- parked stays parked across reboots instead of silently resuming into your base.
--
--   runstate (missing) -> first run: launch and let it anchor / resume
--   runstate "run"      -> launch (the program resumes from its .state via GPS)
--   runstate "stopped"  -> DON'T dig; sit in STANDBY (see below) until a START
--   runstate "done"     -> job finished; sit in STANDBY until a START re-runs it
--
-- STANDBY keeps an idle turtle BOTH visible on the monitor and OTA-updatable
-- without it ever digging: it heartbeats its status (so a card shows) and runs
-- updater.listen (so a dashboard "[^]" deploy lands), and only moves once you
-- press START. So a parked or finished turtle survives a server restart still on
-- the dashboard and still updatable -- it just won't dig on its own.
--
-- The monitor (role "monitor") skips all of this and just runs/relaunches the UI.

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

-- The dashboard runs monitor.lua, not a turtle program: it never digs, so the
-- whole STOP/park machinery is meaningless for it. Crucially it must NEVER persist
-- a "stopped" runstate -- otherwise a crash-and-Ctrl+T (e.g. to reach the shell)
-- parks it, and it boots forever into "waiting for START" instead of the UI.
local parkable = (role ~= "monitor" and role ~= "dashboard")

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
-- STANDBY: an idle turtle (parked by STOP, or finished) that stays on the monitor
-- AND remotely updatable WITHOUT digging. It heartbeats its status so a card
-- shows, runs updater.listen so a dashboard "[^]" deploy downloads + reboots it
-- into new code, and watches for a START to launch. No nav/GPS here, so its card
-- reads "no fix" for position -- fine for an idle turtle. Returns true when a
-- START arrives (caller should launch), false if there's no modem (-> shell). A
-- Ctrl+T raises terminate out of here, which drops to the shell.
----------------------------------------------------------------------
local function standby(statusName)
  local modem = peripheral.find("modem")
  if not modem then
    print("startup: " .. role .. " idle (" .. statusName .. "), no modem -- shell.")
    return false
  end
  rednet.open(peripheral.getName(modem))

  local updater = require("updater")
  local groups  = require("groups")
  updater.tag(role)
  local files    = groups.GROUPS[role]
  local codehash = files and updater.localHash(files) or nil

  local started = false
  local function beacon()
    while true do
      rednet.broadcast(textutils.serialise({
        from = role, status = statusName,
        fuel = turtle and turtle.getFuelLevel() or nil,
        id = os.getComputerID(), name = os.getComputerLabel(), codehash = codehash,
      }))
      sleep(10)
    end
  end
  local function waitStart()
    while true do
      local _, raw = rednet.receive()
      local msg = (type(raw) == "string") and textutils.unserialise(raw) or raw
      if type(msg) == "table" and msg.to == role and msg.cmd then
        if msg.cmd == "start" then
          started = true; return
        elseif msg.cmd == "reset" then
          -- A finished/parked turtle lives here, not in the role's control.listen,
          -- so honor reset in STANDBY too: wipe the saved location and reboot back
          -- into STANDBY, ready for a clean START at its new spot.
          require("control").resetAndReboot()
        end
      end
    end
  end

  print("startup: " .. role .. " in STANDBY (" .. statusName .. "): on the monitor &")
  print("  accepting updates; START from the dashboard to launch. (Ctrl+T = shell.)")
  parallel.waitForAny(waitStart, beacon, updater.listen)

  rednet.close(peripheral.getName(modem))
  return started
end

----------------------------------------------------------------------
-- Main lifecycle loop. Idle states (parked / done) wait in STANDBY -- visible and
-- updatable -- until a START, then launch with a short abort window. A clean
-- finish loops back to STANDBY (so a done turtle stays on the monitor instead of
-- vanishing to the shell, yet still never re-digs on its own); a crash retries,
-- resuming via GPS. The dashboard (parkable=false) skips STANDBY and just
-- runs/relaunches the UI.
----------------------------------------------------------------------
while true do
  runstate = readWord(RUNSTATE_FILE)

  if parkable and (runstate == "stopped" or runstate == "done") then
    if not standby(runstate) then return end   -- no modem -> shell
    writeWord(RUNSTATE_FILE, "run")
    print("startup: START received -- launching " .. program .. ".")
  end

  print("startup: launching " .. program .. " in 3s (Ctrl+T to cancel)...")
  if abortableSleep(3) then
    if parkable then
      writeWord(RUNSTATE_FILE, "stopped")
      print("startup: cancelled -- parked (idle on the monitor). START to resume.")
    else
      print("startup: cancelled -- dropping to shell. Run " .. program .. " to relaunch.")
    end
    return
  end

  -- shell.run returns true on a clean exit (job done / halted) and false on a
  -- crash (lost GPS, chunk unload) or a Ctrl+T -- those two look identical, so a
  -- crash pauses in an abort window: stay quiet to retry, or Ctrl+T to park.
  if shell.run(program) then
    print("startup: " .. program .. " exited cleanly.")
    if not parkable then return end   -- dashboard UI has nothing to stand by for
    -- A clean finish left runstate "done"/"stopped"; loop back into STANDBY.
  else
    local hint = parkable and "Ctrl+T to park" or "Ctrl+T for shell"
    print("startup: " .. program .. " stopped; retrying in 10s (" .. hint .. ")...")
    if abortableSleep(10) then
      if parkable then
        writeWord(RUNSTATE_FILE, "stopped")
        print("startup: parked (idle on the monitor). START from the dashboard to resume.")
      else
        print("startup: dropping to shell. Run " .. program .. " to relaunch.")
      end
      return
    end
    -- else: loop relaunches, resuming from .state via GPS.
  end
end
