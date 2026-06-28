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
