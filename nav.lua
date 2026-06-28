-- nav.lua
-- Shared turtle library for the mining/farm fleet.
-- Loaded with:  local nav = require("nav")
--
-- Provides:
--   * relative position/heading tracking with a world anchor (GPS)
--   * movement primitives that HALT (error) on a hard block instead of
--     silently desyncing position
--   * GPS anchor / reboot recovery / drift verification
--   * ender-chest inventory dump + in-place fuel pull
--   * rednet reporting (stamps from-tag + computer id)
--
-- The movement/anchor half uses a RELATIVE coordinate system (origin = the
-- block the turtle started on, f in 0..3). The inventory/fuel/report helpers
-- are paradigm-agnostic and are also used by treefarm.lua, which keeps its own
-- world-absolute navigation.

local nav = {}

----------------------------------------------------------------------
-- Reserved inventory slots (the two ender chests live here, never mined into)
----------------------------------------------------------------------
nav.FUEL_SLOT = 16   -- ender chest on the FUEL channel  (charcoal IN)
nav.DUMP_SLOT = 15   -- ender chest on the DUMP/LOGS channel (items OUT)
local WORKING_MAX = 14
local MOVE_TRIES  = 60   -- dig/attack retries per move before declaring a hard block

-- Vanilla fuel items we burn / keep. (Substring "coal" would also match
-- coal_ore, so match item ids exactly.)
local FUEL_NAMES = {
  ["minecraft:coal"]     = true,
  ["minecraft:charcoal"] = true,
}

----------------------------------------------------------------------
-- Internal state
----------------------------------------------------------------------
local pos  = { x = 0, y = 0, z = 0, f = 0 }   -- relative; f: 0=+z,1=+x,2=-z,3=-x
local DX   = { 0, 1, 0, -1 }                  -- indexed by f+1
local DZ   = { 1, 0, -1, 0 }
local home = nil      -- world {x,y,z} of relative origin
local hvec = nil      -- world unit vector of relative forward (f==0): {x,z}
local fromTag = "turtle"

-- Heartbeat: re-broadcast the last status while moving so the dashboard can
-- tell "busy" from "crashed" even during long silent stretches of work.
local HEARTBEAT_SECS = 12
local lastStatus, lastExtra, lastBeat = nil, nil, 0

nav.p = pos           -- exposed for read access (scripts read nav.p.x/y/z/f)

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------
local function nameHas(it, word)
  return it ~= nil and it.name ~= nil and it.name:find(word) ~= nil
end
nav.nameHas = nameHas

local function isFuelItem(it)
  return it ~= nil and FUEL_NAMES[it.name] == true
end
nav.isFuelItem = isFuelItem

function nav.fuel()
  local f = turtle.getFuelLevel()
  if f == "unlimited" then return math.huge end
  return f
end

function nav.depth() return -pos.y end

----------------------------------------------------------------------
-- World <-> relative mapping
----------------------------------------------------------------------
local function worldRight()            -- world vector for relative +x (right of forward)
  return { x = -hvec.z, z = hvec.x }
end

local function worldToRel(wx, wy, wz)
  local r  = worldRight()
  local dx = wx - home.x
  local dz = wz - home.z
  return {
    x = dx * r.x    + dz * r.z,         -- dot with right
    z = dx * hvec.x + dz * hvec.z,      -- dot with forward
    y = wy - home.y,
  }
end

local function fFromWorld(mx, mz)
  local r = worldRight()
  if mx == hvec.x and mz == hvec.z then return 0 end
  if mx == r.x    and mz == r.z    then return 1 end
  if mx == -hvec.x and mz == -hvec.z then return 2 end
  return 3
end

-- Snap a measured (dx,dz) GPS delta to a unit axis vector. GPS can be off by a
-- block (especially with weak host geometry), so we trust only the dominant
-- axis's SIGN, never the magnitude. Returns nil if there was no clear movement.
local function unitAxis(dx, dz)
  if dx == 0 and dz == 0 then return nil end
  if math.abs(dx) >= math.abs(dz) then
    return { x = (dx > 0) and 1 or -1, z = 0 }
  else
    return { x = 0, z = (dz > 0) and 1 or -1 }
  end
end

----------------------------------------------------------------------
-- Rednet / reporting
----------------------------------------------------------------------
function nav.open(tag)
  fromTag = tag or fromTag
  local modem = peripheral.find("modem")
  if modem then rednet.open(peripheral.getName(modem)) end
  return modem ~= nil
end

function nav.report(status, extra)
  local msg = {
    from  = fromTag,
    status = status,
    fuel  = nav.fuel(),
    id    = os.getComputerID(),
    name  = os.getComputerLabel(),   -- friendly name for the dashboard (if set)
  }
  -- World coordinates, derived from the GPS anchor (home + heading) and the
  -- relative position we track. Only available once the turtle has anchored.
  if home and hvec then
    local r = { x = -hvec.z, z = hvec.x }   -- world unit vector pointing right
    msg.wx = home.x + pos.x * r.x + pos.z * hvec.x
    msg.wy = home.y + pos.y
    msg.wz = home.z + pos.x * r.z + pos.z * hvec.z
  end
  if extra then
    for k, v in pairs(extra) do msg[k] = v end
  end
  lastStatus, lastExtra, lastBeat = status, extra, os.clock()
  rednet.broadcast(textutils.serialise(msg))
end

-- Throttled re-broadcast of the current status; cheap to call on every move.
local function heartbeat()
  if lastStatus and os.clock() - lastBeat >= HEARTBEAT_SECS then
    nav.report(lastStatus, lastExtra)   -- refreshes fuel/position + lastBeat
  end
end

----------------------------------------------------------------------
-- Movement primitives (honour failure: error out instead of desyncing)
----------------------------------------------------------------------
-- True if the block reported by `inspectFn` is unbreakable (bedrock). Lets us
-- bail instantly instead of grinding MOVE_TRIES digs against it.
local function isBedrock(inspectFn)
  if not inspectFn then return false end
  local ok, data = inspectFn()
  return ok and data ~= nil and data.name ~= nil and data.name:find("bedrock") ~= nil
end
nav.isBedrock = isBedrock

-- Try to move, digging/attacking through obstacles. Returns true if it moved,
-- false if it gave up (an unbreakable block, or still stuck after MOVE_TRIES).
-- It NEVER errors and NEVER reports a position change on failure, so the
-- caller's tracked position stays truthful and the CALLER decides what a hard
-- block means (bedrock floor, obstruction to skip, etc).
local function attemptMove(moveFn, digFn, attackFn, inspectFn)
  for _ = 1, MOVE_TRIES do
    if moveFn() then heartbeat(); return true end
    if isBedrock(inspectFn) then return false end   -- unbreakable: don't grind
    digFn()
    attackFn()
    sleep(0.2)
  end
  return false
end

function nav.turnLeft()  turtle.turnLeft();  pos.f = (pos.f - 1) % 4 end
function nav.turnRight() turtle.turnRight(); pos.f = (pos.f + 1) % 4 end

function nav.face(d)
  local diff = (d - pos.f) % 4
  if     diff == 1 then nav.turnRight()
  elseif diff == 2 then nav.turnRight(); nav.turnRight()
  elseif diff == 3 then nav.turnLeft()
  end
end

-- All of these return true on success, false if a move was refused (blocked).
function nav.fwd()
  if not attemptMove(turtle.forward, turtle.dig, turtle.attack, turtle.inspect) then return false end
  pos.x = pos.x + DX[pos.f + 1]
  pos.z = pos.z + DZ[pos.f + 1]
  return true
end

function nav.up()
  if not attemptMove(turtle.up, turtle.digUp, turtle.attackUp, turtle.inspectUp) then return false end
  pos.y = pos.y + 1
  return true
end

function nav.down()
  if not attemptMove(turtle.down, turtle.digDown, turtle.attackDown, turtle.inspectDown) then return false end
  pos.y = pos.y - 1
  return true
end

function nav.ascend(n)  for _ = 1, n do if not nav.up()   then return false end end return true end
function nav.descend(n) for _ = 1, n do if not nav.down() then return false end end return true end

-- Dig the ceiling then advance: carves a 2-tall tunnel. Returns fwd's result.
function nav.fwdDig2()
  turtle.digUp()
  return nav.fwd()
end

-- Is the block directly ahead / below unbreakable? (Callers use this to tell a
-- bedrock floor from an obstruction worth flagging.)
function nav.bedrockAhead() return isBedrock(turtle.inspect) end
function nav.bedrockBelow() return isBedrock(turtle.inspectDown) end

-- Navigate to a relative (x,z). Returns false the moment a move is blocked, so
-- callers can react instead of spinning forever against a wall.
function nav.goTo(tx, tz)
  if tx > pos.x then nav.face(1); while pos.x < tx do if not nav.fwd() then return false end end
  elseif tx < pos.x then nav.face(3); while pos.x > tx do if not nav.fwd() then return false end end end
  if tz > pos.z then nav.face(0); while pos.z < tz do if not nav.fwd() then return false end end
  elseif tz < pos.z then nav.face(2); while pos.z > tz do if not nav.fwd() then return false end end end
  return true
end

function nav.returnToSurface()
  nav.goTo(0, 0); nav.face(0)
  while pos.y < 0 do if not nav.up() then return false end end
  return true
end

-- Return to the relative origin at home Y, facing forward.
function nav.goHome()
  nav.goTo(0, 0)
  while pos.y > 0 do if not nav.down() then return false end end
  while pos.y < 0 do if not nav.up()   then return false end end
  nav.face(0)
  return true
end

----------------------------------------------------------------------
-- GPS: locate, first-run anchor, reboot recovery, drift verify
----------------------------------------------------------------------
function nav.locate(timeout)
  for _ = 1, 3 do
    local x, y, z = gps.locate(timeout or 2)
    if x then return { x = x, y = y, z = z } end
  end
  return nil
end

function nav.setAnchor(h, v)
  home = { x = h.x, y = h.y, z = h.z }
  hvec = { x = v.x, z = v.z }
end

function nav.getAnchor() return home, hvec end
function nav.surfaceY() return home and home.y or nil end

-- One physical forward move to discover the world direction we face.
local function stepForwardRaw()
  for _ = 1, MOVE_TRIES do
    if turtle.forward() then return true end
    turtle.dig(); turtle.attack(); sleep(0.2)
  end
  return false
end

-- First run: capture home + heading. Rises `rise` blocks (into clearer air) so
-- the calibration step doesn't chew up terrain. Leaves the turtle 1 forward +
-- `rise` up from home; pos is synced. Caller should goHome() afterwards.
function nav.firstRunAnchor(rise)
  local h = nav.locate()
  if not h then error("nav: no GPS fix for anchor (is the constellation up?)", 0) end
  for _ = 1, (rise or 0) do
    if turtle.up() then pos.y = pos.y + 1 else turtle.digUp(); turtle.attackUp() end
  end
  local p1 = nav.locate()
  if not stepForwardRaw() then error("nav: could not step to calibrate heading", 0) end
  local p2 = nav.locate()
  if not (p1 and p2) then error("nav: lost GPS during calibration", 0) end
  home = { x = h.x, y = h.y, z = h.z }
  hvec = unitAxis(p2.x - p1.x, p2.z - p1.z)
  if not hvec then error("nav: calibration saw no movement (GPS hosts too close together?)", 0) end
  pos.f = 0
  local r = worldToRel(p2.x, p2.y, p2.z)
  pos.x, pos.y, pos.z = r.x, r.y, r.z
  return home, hvec
end

-- After a reboot: anchor must already be restored via setAnchor(). Re-derives
-- current position AND facing from GPS (one forward calibration move).
function nav.recoverOnBoot()
  if not (home and hvec) then error("nav: recoverOnBoot without anchor", 0) end
  local p1 = nav.locate()
  if not p1 then error("nav: no GPS fix on boot", 0) end
  if not stepForwardRaw() then error("nav: blocked during boot calibration", 0) end
  local p2 = nav.locate()
  if not p2 then error("nav: lost GPS on boot", 0) end
  local mfwd = unitAxis(p2.x - p1.x, p2.z - p1.z)
  if not mfwd then error("nav: boot calibration saw no movement (GPS?)", 0) end
  pos.f = fFromWorld(mfwd.x, mfwd.z)
  local r = worldToRel(p2.x, p2.y, p2.z)
  pos.x, pos.y, pos.z = r.x, r.y, r.z
end

-- Correct x/y/z drift against GPS. Skips silently if GPS momentarily absent.
function nav.verifyPos()
  if not (home and hvec) then return end
  local w = nav.locate(1)
  if not w then return end
  local r = worldToRel(w.x, w.y, w.z)
  if r.x ~= pos.x or r.y ~= pos.y or r.z ~= pos.z then
    pos.x, pos.y, pos.z = r.x, r.y, r.z
    -- Re-broadcast the CURRENT status so the dashboard picks up the corrected
    -- coordinates without flipping the card to an unknown "drift_corrected"
    -- status (which would read as not-working and pause OFFLINE detection).
    if lastStatus then nav.report(lastStatus, lastExtra) end
  end
end

----------------------------------------------------------------------
-- Ender-chest inventory helpers (place UP, transfer, retrieve)
----------------------------------------------------------------------
local function placeUpFrom(slot)
  turtle.select(slot)
  if turtle.getItemCount(slot) == 0 then return false end  -- chest missing!
  if turtle.detectUp() then turtle.digUp() end
  return turtle.placeUp()
end

local function retrieveUpInto(slot)
  turtle.select(slot)
  turtle.digUp()        -- picks the chest back up into the (now empty) selected slot
  turtle.select(1)
end

function nav.workingInventoryFull()
  for s = 1, WORKING_MAX do
    if turtle.getItemCount(s) == 0 then return false end
  end
  return true
end

-- Dump working slots into the DUMP/LOGS ender chest. Fuel items are always
-- kept; `extraKeep(it)` may keep more (e.g. saplings). Returns logs/all dropped.
function nav.dumpInventory(extraKeep)
  if not placeUpFrom(nav.DUMP_SLOT) then
    nav.report("dump_chest_missing", {})
    return false
  end
  for s = 1, WORKING_MAX do
    local it = turtle.getItemDetail(s)
    if it then
      local keep = isFuelItem(it) or (extraKeep ~= nil and extraKeep(it))
      if not keep then
        turtle.select(s)
        turtle.dropUp()
      end
    end
  end
  retrieveUpInto(nav.DUMP_SLOT)
  return true
end

-- Top up fuel from the FUEL ender chest, in place. Keeps up to `reserve`
-- charcoal items afterward; returns the surplus to the chest. Returns true if
-- the target fuel level was reached, false (and reports fuel_empty) otherwise.
function nav.refuelFromEnder(target, reserve, reportExtra)
  reserve = reserve or 0
  if nav.fuel() >= target then return true end
  if not placeUpFrom(nav.FUEL_SLOT) then
    nav.report("fuel_empty", reportExtra)
    return false
  end

  -- Burn charcoal one at a time, pulling stacks as needed, until target or dry.
  while nav.fuel() < target do
    local fslot = nil
    for s = 1, WORKING_MAX do
      if isFuelItem(turtle.getItemDetail(s)) then fslot = s; break end
    end
    if fslot then
      turtle.select(fslot)
      turtle.refuel(1)
    else
      turtle.select(1)
      if not turtle.suckUp() then break end   -- chest is empty
    end
  end

  -- Return surplus fuel above `reserve` back into the chest.
  local kept = 0
  for s = 1, WORKING_MAX do
    local it = turtle.getItemDetail(s)
    if isFuelItem(it) then
      local keepHere = math.max(0, reserve - kept)
      if it.count > keepHere then
        turtle.select(s)
        turtle.dropUp(it.count - keepHere)
      end
      kept = kept + math.min(it.count, keepHere)
    end
  end

  retrieveUpInto(nav.FUEL_SLOT)
  local ok = nav.fuel() >= target
  if not ok then nav.report("fuel_empty", reportExtra) end
  return ok
end

return nav
