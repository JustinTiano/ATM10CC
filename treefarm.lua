-- treefarm.lua -- GPS grid BIRCH farm (harvest-from-above), static 7x7 footprint.
-- Runs on a Mining/Felling Turtle with a wireless modem.
--
-- WHY BIRCH + A MAGNET CHEST:
--   * Birch is a pure 1x1 trunk with no large/branchy variant, so cutting straight
--     down each column removes 100% of the logs every sweep. With no log left
--     standing, EVERY leaf decays on its own -- no leaf-clearing pass needed.
--   * A Sophisticated Storage chest with an Advanced Magnet upgrade sits at the
--     field CENTER and vacuums all the sapling drops (filter it to saplings). The
--     turtle never chases ground drops; it just reloads its replant buffer by
--     sucking saplings back out of that chest before each sweep.
--
-- PLACEMENT (first run):
--   * Stand the turtle on the FRONT-LEFT corner of the field, ON the ground,
--     FACING into the field.
--   * SLOT 16 = FUEL-channel ender chest, SLOT 15 = LOGS-channel ender chest.
--   * Put the MAGNET chest at the field center (block 3,3 on a 7x7 -- an odd
--     position, so it doesn't displace a tree), top flush with the soil.
--   * Load some birch saplings + charcoal. A GPS constellation must be in range.
--
-- 7x7 footprint -> birch on every-other block -> a 4x4 grid = 16 trees.
-- Config (home + heading) is captured once from GPS and saved; reboots are silent.

local nav     = require("nav")
local control = require("control")
local updater = require("updater")

local CONFIG_FILE   = "tree_config.txt"
local SIZE          = 7        -- static footprint
local FUEL_PER_TREE = 50       -- rough fuel budget per tree per cycle
local FUEL_RESERVE  = 64       -- charcoal items kept in inventory after topping up
local TRANSIT_UP    = 12       -- height above home to fly between columns
local GROW_WAIT     = 75       -- seconds between sweeps (ungrown spots are skipped, caught next sweep)
local SAPLING_BUFFER = 32      -- replant stock to keep on hand (refilled from the magnet chest)

----------------------------------------------------------------------
-- Position / heading (absolute world coords from GPS)
----------------------------------------------------------------------
local pos   = { x = 0, y = 0, z = 0 }
local dir   = { x = 0, z = 1 }
local home  = nil
local fwd0  = nil
local state = { logsDeposited = 0, sweeps = 0 }
local transitY

local nameHas = nav.nameHas
local function isLog(d) return nameHas(d, "log") or nameHas(d, "wood") or nameHas(d, "stem") end
local function isSoil(d)
  return nameHas(d, "dirt") or nameHas(d, "grass") or nameHas(d, "podzol")
      or nameHas(d, "farmland") or nameHas(d, "rooted")
end
local function isChest(d)
  return nameHas(d, "chest") or nameHas(d, "barrel") or nameHas(d, "sophisticated")
end

local function countItem(word)
  local n = 0
  for slot = 1, 16 do
    local it = turtle.getItemDetail(slot)
    if nameHas(it, word) then n = n + it.count end
  end
  return n
end

local function selectItem(word)
  for slot = 1, 16 do
    if nameHas(turtle.getItemDetail(slot), word) then
      turtle.select(slot)
      return true
    end
  end
  return false
end

-- First empty working slot (1..14; 15/16 are the ender chests). nil if all full.
local function firstFreeSlot()
  for slot = 1, 14 do
    if turtle.getItemCount(slot) == 0 then return slot end
  end
  return nil
end

-- After logs go to the chest, tidy what the turtle picked up breaking the canopy:
-- drop sticks/apples (junk -- keep them out of the furnace loop) and any saplings
-- beyond SAPLING_BUFFER. Everything is dropped into the field at home, where the
-- (saplings-only) magnet re-grabs the surplus saplings and ignores the junk (which
-- despawns). So the turtle carries only logs out and a tidy replant buffer back.
local function tidyInventory()
  local keptSap = 0
  for slot = 1, 14 do
    local it = turtle.getItemDetail(slot)
    if it then
      if nameHas(it, "sapling") then
        local room = math.max(0, SAPLING_BUFFER - keptSap)
        if it.count > room then turtle.select(slot); turtle.drop(it.count - room) end
        keptSap = keptSap + math.min(it.count, room)
      elseif nameHas(it, "stick") or nameHas(it, "apple") then
        turtle.select(slot); turtle.drop()
      end
    end
  end
  turtle.select(1)
end

local function treesPerSide() return math.floor((SIZE - 1) / 2) + 1 end

----------------------------------------------------------------------
-- Reporting
----------------------------------------------------------------------
local function send(status)
  local n = treesPerSide()
  nav.report(status, {
    saplings      = countItem("sapling"),
    logsDeposited = state.logsDeposited,
    size          = SIZE,
    trees         = n * n,
    -- The tree farm tracks its own anchor, so nav can't derive coords for it.
    -- Report the home/base position explicitly for the dashboard map.
    wx = home and home.x, wy = home and home.y, wz = home and home.z,
  })
end

----------------------------------------------------------------------
-- Movement (world-absolute; dig through obstacles, keep pos/dir in sync)
----------------------------------------------------------------------
local function turnRight() turtle.turnRight(); dir = { x = -dir.z, z = dir.x } end
local function turnLeft()  turtle.turnLeft();  dir = { x =  dir.z, z = -dir.x } end

local function faceTo(tx, tz)
  if dir.x == tx and dir.z == tz then return end
  if dir.z == tx and -dir.x == tz then turnLeft(); return end
  for _ = 1, 3 do
    if dir.x == tx and dir.z == tz then return end
    turnRight()
  end
end

local function forwardDig()
  local tries = 0
  while not turtle.forward() do
    if turtle.detect() then turtle.dig() else turtle.attack() end
    tries = tries + 1
    if tries > 40 then
      -- Hard block: surface it as the dashboard's STUCK alarm (treefarm runs its
      -- own navigation, so nav's blocked-reporting never fires for us) and abort
      -- so startup.lua retries from a clean recalibration.
      nav.report("blocked", { detail = "treefarm forward" })
      error("treefarm: forward blocked", 0)
    end
    sleep(0.2)
  end
  pos.x = pos.x + dir.x; pos.z = pos.z + dir.z
  return true
end

local function upDig()
  while not turtle.up() do
    if turtle.detectUp() then turtle.digUp() else turtle.attackUp() end
    sleep(0.2)
  end
  pos.y = pos.y + 1
end

local function downDig()
  while not turtle.down() do
    if turtle.detectDown() then turtle.digDown() else turtle.attackDown() end
    sleep(0.2)
  end
  pos.y = pos.y - 1
end

local function ascendTo(y) while pos.y < y do upDig() end; while pos.y > y do downDig() end end

local function goHoriz(tx, tz)
  while pos.x ~= tx do
    local s = (tx > pos.x) and 1 or -1
    faceTo(s, 0); forwardDig()
  end
  while pos.z ~= tz do
    local s = (tz > pos.z) and 1 or -1
    faceTo(0, s); forwardDig()
  end
end

----------------------------------------------------------------------
-- GPS calibration
----------------------------------------------------------------------
local function calibrateHeading()
  ascendTo(pos.y + TRANSIT_UP)
  local p1 = nav.locate(); if not p1 then error("No GPS fix") end
  pos = p1
  if not forwardDig() then error("Calibration move failed -- check fuel/obstruction") end
  local p2 = nav.locate(); if not p2 then error("No GPS fix") end
  -- GPS can be off by a block; trust only the dominant axis's sign, not magnitude.
  local dx, dz = p2.x - p1.x, p2.z - p1.z
  if dx == 0 and dz == 0 then
    error("Calibration saw no movement (GPS hosts too close together?)")
  end
  if math.abs(dx) >= math.abs(dz) then
    dir = { x = (dx > 0) and 1 or -1, z = 0 }
  else
    dir = { x = 0, z = (dz > 0) and 1 or -1 }
  end
  pos = p2
end

----------------------------------------------------------------------
-- Field geometry
----------------------------------------------------------------------
local function rightVec() return { x = -fwd0.z, z = fwd0.x } end

local function treeWorld(i, j)
  local rv = rightVec()
  return {
    x = home.x + fwd0.x * (1 + 2 * i) + rv.x * (2 * j),
    z = home.z + fwd0.z * (1 + 2 * i) + rv.z * (2 * j),
  }
end

-- World (x,z) of the magnet chest: the field center. On a 7x7 that's local cell
-- (3,3) from home -- an odd block, so it never sits where a tree goes.
local function chestWorld()
  local rv = rightVec()
  local c  = math.floor(SIZE / 2)
  return {
    x = home.x + fwd0.x * c + rv.x * c,
    z = home.z + fwd0.z * c + rv.z * c,
  }
end

----------------------------------------------------------------------
-- Harvest one column: descend digging the 1x1 birch trunk, replant, rise.
-- Birch leaves to the sides are left untouched -- they decay on their own once
-- the trunk (and all the other trunks this sweep) are gone, and the magnet chest
-- collects the sapling drops. No ground-collection here.
----------------------------------------------------------------------
local function harvestColumn(tx, tz)
  ascendTo(transitY)
  goHoriz(tx, tz)
  local floorY = home.y - 4
  -- Descend, classifying what's below: dig through logs/leaves (the cut), but
  -- if we meet an ungrown sapling, leave it standing and move on.
  while pos.y > floorY do
    local ok, d = turtle.inspectDown()
    if not ok then
      downDig()                       -- air: keep dropping
    elseif isSoil(d) then
      break                           -- reached the planting spot
    elseif nameHas(d, "sapling") then
      ascendTo(transitY)              -- not grown yet: leave it, skip
      return
    else
      downDig()                       -- log / leaves / other: cut through it
    end
  end
  -- Standing on the soil spot (harvested a tree, or it was empty). Replant.
  upDig()
  if selectItem("sapling") then
    turtle.placeDown()
  end
  -- Out of saplings: leave the spot bare. The dashboard derives the NO SAPLINGS
  -- warning from the saplings=0 count carried in every report, so there's no
  -- dedicated status here (and thus no flicker against the per-column heartbeat).
  ascendTo(transitY)
end

----------------------------------------------------------------------
-- Reload the replant buffer from the center magnet chest. The magnet vacuums all
-- the sapling drops into this chest; we suck them back out before each sweep.
----------------------------------------------------------------------
local function refillSaplings()
  if countItem("sapling") >= SAPLING_BUFFER then return end
  local c = chestWorld()
  ascendTo(transitY)
  goHoriz(c.x, c.z)
  -- Drop until the chest is directly below us, cutting through anything in the way
  -- (birch leaves love to overhang the center) but STOPPING on the chest so we
  -- never dig it. The chest sits ~flush with the soil (home.y-1), so we descend to
  -- home.y; the floor also stops us before we'd ever dig the soil/chest layer.
  local ok, d = turtle.inspectDown()
  while pos.y > home.y and not (ok and isChest(d)) do
    downDig()   -- air, or leaves/logs overhanging the chest: cut through
    ok, d = turtle.inspectDown()
  end
  if ok and isChest(d) then
    -- suckDown drops into the selected slot first, so start on a guaranteed-empty
    -- one; then pull until we hit the buffer or the chest stops giving items.
    local free = firstFreeSlot()
    if free then turtle.select(free) end
    local before = countItem("sapling")
    while countItem("sapling") < SAPLING_BUFFER and turtle.suckDown() do end
    turtle.select(1)
    print(("refill: on %s, pulled %d saplings (now %d)")
      :format(d.name, countItem("sapling") - before, countItem("sapling")))
  else
    print("refill: nothing suckable below (" .. (ok and d.name or "air") .. ")")
  end
  ascendTo(transitY)
end

-- True once a sweep's mid-run refill found the magnet chest can't top us up, so we
-- stop detouring to an empty chest for the rest of THIS sweep. Reset each sweep.
local sweepChestDry = false

-- Keep enough saplings on hand to finish the replants still ahead this sweep. If
-- we're short, detour to the center chest RIGHT NOW (don't limp to the end of the
-- sweep bare) -- the chest is also filling with this sweep's fresh drops, so a
-- mid-run top-up usually recovers. If even that can't reach `need`, give up the
-- detour for the rest of the sweep so we don't thrash flying to a dry chest.
local function ensureSaplings(need)
  if need <= 0 or sweepChestDry then return end
  if countItem("sapling") >= need then return end
  refillSaplings()
  if countItem("sapling") < need then sweepChestDry = true end
end

----------------------------------------------------------------------
-- Fuel + deposit (via ender chests)
----------------------------------------------------------------------
local function refuel(target)
  return nav.refuelFromEnder(target, FUEL_RESERVE, {
    saplings = countItem("sapling"),
    size = SIZE, trees = treesPerSide() * treesPerSide(),
  })
end

local function depositLogs()
  local added = 0
  for s = 1, 14 do
    local it = turtle.getItemDetail(s)
    if isLog(it) then added = added + it.count end
  end
  -- Keep the LOGS ender chest LOGS-ONLY (it feeds the furnace loop): dump only
  -- logs, keeping everything non-log (fuel + saplings + the stray junk), then tidy
  -- the rest -- drop sticks/apples and recirculate surplus saplings to the magnet.
  nav.dumpInventory(function(it) return not isLog(it) end)
  tidyInventory()
  state.logsDeposited = state.logsDeposited + added
end

local function goHome()
  ascendTo(transitY)
  goHoriz(home.x, home.z)
  ascendTo(home.y)
  faceTo(fwd0.x, fwd0.z)
end

----------------------------------------------------------------------
-- Config
----------------------------------------------------------------------
local function saveConfig()
  local f = fs.open(CONFIG_FILE, "w")
  f.write(textutils.serialise({ home = home, fwd0 = fwd0,
    logsDeposited = state.logsDeposited, sweeps = state.sweeps or 0 }))
  f.close()
end

local function loadConfig()
  if not fs.exists(CONFIG_FILE) then return false end
  local f = fs.open(CONFIG_FILE, "r")
  local cfg = textutils.unserialise(f.readAll())
  f.close()
  if not cfg then return false end
  home, fwd0 = cfg.home, cfg.fwd0
  state.logsDeposited = cfg.logsDeposited or 0
  state.sweeps        = cfg.sweeps or 0
  return true
end

local function firstRunSetup()
  print("=== Tree farm first-time setup (7x7 birch) ===")
  pos = nav.locate(); if not pos then error("No GPS fix") end
  home = { x = pos.x, y = pos.y, z = pos.z }
  calibrateHeading()
  fwd0 = { x = dir.x, z = dir.z }
  saveConfig()
  print(("Saved: 7x7 field, home (%d,%d,%d)."):format(home.x, home.y, home.z))
end

----------------------------------------------------------------------
-- Main
----------------------------------------------------------------------
nav.open("treefarm")
control.tag("treefarm")
updater.tag("treefarm")

-- Park to a safe idle state: go home, persist the STOP, then wait for START.
-- Used by both the cycle stop (at the sweep boundary) and the hard stop (mid-sweep).
local function park()
  goHome()
  control.setRunState("stopped")
  send("stopped")
  control.ackStop()
  control.waitForStart()
  control.setRunState("run")
  send("starting")
end

-- Mid-sweep checkpoint: only a HARD stop (double-tap) parks here right away. A
-- single (cycle) stop is left for the sweep-boundary check so the current sweep
-- finishes (and deposits) first. Returns true if it parked (caller restarts sweep).
local function honorStop()
  if not control.hardStopRequested() then return false end
  park()
  return true
end

-- sleep(secs) that bails the instant a STOP is pending, so the grow-wait can't
-- swallow a STOP for up to GROW_WAIT seconds.
local function interruptibleSleep(secs)
  for _ = 1, secs do
    if control.stopRequested() then return end
    sleep(1)
  end
end

local function worker()
  control.setRunState("run")          -- we are committed to running; survive reboots
  nav.primeFuel()                     -- top up to nav.MIN_FUEL before anything moves
  if loadConfig() then
    pos = nav.locate(); if not pos then error("No GPS fix") end
    calibrateHeading()
  else
    firstRunSetup()
  end

  transitY = home.y + TRANSIT_UP
  goHome()
  send("starting")

  while true do
    -- Cycle stop: a single STOP is honored here, at the sweep boundary, so the
    -- last sweep finished (and deposited) before parking.
    if control.stopRequested() then park() end

    local n = treesPerSide()
    if not refuel(n * n * FUEL_PER_TREE) then
      sleep(30)   -- FUEL chest dry: wait for charcoal, then retry
    else
      sweepChestDry = false
      refillSaplings()   -- top up the replant buffer from the center magnet chest
      send("chopping")
      local completed = true
      local replantsLeft = n * n   -- upper bound on saplings still needed this sweep
      for i = 0, n - 1 do
        local cols = {}
        for j = 0, n - 1 do cols[#cols + 1] = j end
        if i % 2 == 1 then
          local r = {}; for k = #cols, 1, -1 do r[#r + 1] = cols[k] end; cols = r
        end
        for _, j in ipairs(cols) do
          if honorStop() then completed = false; break end  -- STOP: parked + homed
          ensureSaplings(replantsLeft)   -- short on saplings? detour to the chest now
          local t = treeWorld(i, j)
          harvestColumn(t.x, t.z)
          replantsLeft = replantsLeft - 1
          send("chopping")   -- per-column heartbeat: this loop can outlast the
                             -- dashboard's OFFLINE timeout, and treefarm's own
                             -- movement bypasses nav's heartbeat.
        end
        if not completed then break end
      end

      if completed then     -- a STOP restarts the sweep instead of depositing
        send("collecting")
        goHome()
        depositLogs()
        state.sweeps = (state.sweeps or 0) + 1
        saveConfig()        -- persist logsDeposited + sweeps across reboots
        send("waiting")
        interruptibleSleep(GROW_WAIT)
      end
    end
  end
end

parallel.waitForAny(control.listen, updater.listen, worker)
