-- updater.lua
-- Over-the-air code deploy for the fleet. Runs as a parallel listener next to
-- the main program (exactly like control.lua):
--
--   local updater = require("updater")
--   updater.tag("quarry")
--   parallel.waitForAny(control.listen, updater.listen, worker)
--
-- When any computer broadcasts a deploy command, each TARGETED computer
-- downloads the listed files over HTTP and reboots into the new code. The base
-- URL is whatever you host the raw .lua at -- a pastebin raw link today, your
-- own server later (no change needed here, just point deploy.lua's BASE at it).
--
-- Deploy command shape (broadcast, serialised):
--   { deploy = true, to = "all"|<tag>, base = "https://host/path/",
--     files = { "nav.lua", "control.lua", "quarry.lua" } }
--
-- Files download to "<name>.new" first and only replace the live file on a
-- clean fetch, so a failed/empty download never bricks a turtle.

local updater = {}

local tag = "turtle"

function updater.tag(t) tag = t or tag end

----------------------------------------------------------------------
-- Code versioning: a cheap content hash over a role's file list, computed the
-- SAME way on both ends so the dashboard can tell "this machine's code differs
-- from the repo" => an update is pending. Deterministic polynomial rolling hash
-- kept under 2^31 so it stays an exact integer in CC's Lua (no bit32 needed).
-- The files ARE the version -- nothing to bump by hand.
----------------------------------------------------------------------
local function strfold(h, s)
  for i = 1, #s do h = (h * 131 + s:byte(i)) % 2147483647 end
  return h
end

-- Hash `files` in list order. getContent(file) -> string (or nil if absent).
-- Caller supplies getContent so the SAME routine hashes local files (turtle) or
-- freshly-fetched remote bytes (dashboard).
function updater.composeHash(files, getContent)
  local h = 0
  for _, file in ipairs(files or {}) do
    h = strfold(h, file .. "\0")
    h = strfold(h, getContent(file) or "")
    h = strfold(h, "\1")
  end
  return h
end

local function readLocal(file)
  if not fs.exists(file) then return nil end
  local f = fs.open(file, "r")
  local d = f.readAll()
  f.close()
  return d
end

-- Hash of the files as currently installed on THIS machine.
function updater.localHash(files)
  return updater.composeHash(files, readLocal)
end

local function report(extra)
  extra.from = tag
  rednet.broadcast(textutils.serialise(extra))
end

-- Download one file to a temp path, then move it into place atomically.
local function fetch(base, file)
  local resp = http.get(base .. file)
  if not resp then return false, "no response" end
  local data = resp.readAll()
  resp.close()
  if not data or #data == 0 then return false, "empty" end
  local tmp = file .. ".new"
  local h = fs.open(tmp, "w")
  h.write(data)
  h.close()
  if fs.exists(file) then fs.delete(file) end
  fs.move(tmp, file)
  return true
end

local function apply(cmd)
  local ok, fail = 0, 0
  for _, file in ipairs(cmd.files or {}) do
    local good, err = fetch(cmd.base, file)
    if good then ok = ok + 1 else fail = fail + 1 end
    report({ status = "updating", file = file, ok = good == true, err = err })
    print((good and "  ok  " or " FAIL ") .. file .. (err and (" (" .. err .. ")") or ""))
  end
  return ok, fail
end

-- Update THIS machine directly (no rednet round-trip). Needed for the dashboard:
-- rednet.broadcast never delivers to the sender, so the dashboard can't deploy
-- to itself the normal way -- the UI's self-update button calls this instead.
function updater.selfUpdate(base, files)
  local ok, fail = 0, 0
  for _, file in ipairs(files or {}) do
    local good, err = fetch(base, file)
    if good then ok = ok + 1 else fail = fail + 1 end
    print((good and "  ok  " or " FAIL ") .. file .. (err and (" (" .. err .. ")") or ""))
  end
  print(("Self-update: %d ok, %d failed. Rebooting..."):format(ok, fail))
  sleep(1)
  os.reboot()
end

function updater.listen()
  while true do
    local _, raw = rednet.receive()
    local msg = (type(raw) == "string") and textutils.unserialise(raw) or raw
    if type(msg) == "table" and msg.deploy and msg.base
       and (msg.to == "all" or msg.to == tag) then
      print("Update incoming (" .. tostring(#(msg.files or {})) .. " files)...")
      report({ status = "updating" })
      local ok, fail = apply(msg)
      report({ status = "updated", ok = ok, fail = fail })
      print(("Updated %d, failed %d. Rebooting..."):format(ok, fail))
      sleep(1)          -- let the final broadcast flush before we drop offline
      os.reboot()       -- restart into the freshly downloaded code
    end
  end
end

return updater
