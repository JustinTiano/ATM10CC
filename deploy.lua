-- deploy.lua -- push an over-the-air update to the fleet.
-- Run on any computer with a wireless modem (the dashboard is the natural home).
--
--   deploy             -> update EVERY group below
--   deploy quarry      -> update just the quarry turtle
--   deploy treefarm    -> update just the tree farm
--   deploy dashboard   -> update the dashboard (card.lua + monitor.lua + tooling)
--
-- Each updater.lua on the target downloads BASE..<file> and reboots itself.
--
-- The host (BASE) and the per-role file lists live in groups.lua, shared with
-- install.lua so the two never drift. To change where files are hosted, or which
-- files a role pulls, edit groups.lua -- not here.

local manifest = require("groups")
local BASE = manifest.BASE
local GROUPS = manifest.GROUPS

local modem = peripheral.find("modem")
if not modem then error("No modem attached!") end
rednet.open(peripheral.getName(modem))

local function send(tag, files)
  rednet.broadcast(textutils.serialise({
    deploy = true, to = tag, base = BASE, files = files,
  }))
  print(("-> %s  (%d files)"):format(tag, #files))
end

local target = ...
if target == nil then
  for tag, files in pairs(GROUPS) do send(tag, files) end
  print("Sent update to ALL groups.")
elseif GROUPS[target] then
  send(target, GROUPS[target])
else
  print("Unknown target: " .. tostring(target))
  local names = {}
  for k in pairs(GROUPS) do names[#names + 1] = k end
  print("Targets: (none)=all, " .. table.concat(names, ", "))
end
