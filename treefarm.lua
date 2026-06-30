-- treefarm.lua -- GPS grid tree farm (harvest-from-above), static 7x7 footprint.
-- Runs on a Mining/Felling Turtle with a wireless modem.
--
-- PLACEMENT (first run):
--   * Stand the turtle on the FRONT-LEFT corner of the field, ON the ground,
--     FACING into the field.
--   * SLOT 16 = FUEL-channel ender chest, SLOT 15 = LOGS-channel ender chest.
--   * Load some saplings + charcoal. A GPS constellation must be in range.
--
-- 7x7 footprint -> trees on every-other block -> a 4x4 grid = 16 trees.
-- Config (home + heading) is captured once from GPS and saved; reboots are silent.

local nav     = require("nav")
local control = require("control")
local updater = require("updater")

local CONFIG_FILE   = "tree_config.txt"
local SIZE          = 7        -- static footprint
local FUEL_PER_TREE = 50       -- rough fuel budget per tree per cycle
local FUEL_RESERVE  = 64       -- charcoal items kept in inventory after topping up
local TRANSIT_UP    = 12       -- height above home to fly between columns
local LEAF_WAIT     = 0        -- seconds to pause for leaf-decay drops (0 = skip; ground drops get scooped on later passes)
local GROW_WAIT     = 45       -- seconds between sweeps
local CLEAR_EVERY   = 6        -- full-area clear every N harvest sweeps (0 = never)
local CLEAR_HEIGHT  = 16       -- clear from ground+1 up to home.y+CLEAR_HEIGHT (cover canopies)
local CLEAR_MARGIN  = 1        -- extend the clear box this many blocks past the trees (catch overhang)

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

----------------------------------------------------------------------
-- Harvest one column: descend digging trunk, replant, rise back up
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
      -- not grown yet: grab any ground drops here, leave the sapling, skip
      turtle.suck(); turtle.suckDown()
      ascendTo(transitY)
      return
    else
      downDig()                       -- log / leaves / other: cut through it
    end
  end
  -- Standing on the soil spot (harvested a tree, or it was empty). Replant.
  if LEAF_WAIT > 0 then sleep(LEAF_WAIT) end
  turtle.suck(); turtle.suckDown()
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
  nav.dumpInventory(function(it) return nameHas(it, "sapling") end)
  state.logsDeposited = state.logsDeposited + added
end

local function goHome()
  ascendTo(transitY)
  goHoriz(home.x, home.z)
  ascendTo(home.y)
  faceTo(fwd0.x, fwd0.z)
end

----------------------------------------------------------------------
-- Periodic full-area clear. The per-tree harvest only digs straight down each
-- trunk column, so big/branchy trees (large oaks especially) leave stray logs
-- between columns -- and the leaves around them won't decay while a log is near.
-- Every CLEAR_EVERY sweeps we visit every column of the field grid and clear it
-- top-down, but SMART, not brute force:
--   * dig only logs/leaves; free-fall through air (no pointless digging);
--   * stop a column once its canopy is cleared (a short run of air below the
--     last wood) instead of plowing the empty trunk space down to the ground;
--   * never touch a standing sapling, the soil, or anything we don't recognize
--     (so a wall/build inside the field is left alone);
--   * suck drops down each column AND finish with a low pass over the field, so
--     the saplings/apples end up in the turtle instead of on the ground for you
--     to gather by hand.
-- Removing all the logs also lets any leaves overhanging past the box decay.
----------------------------------------------------------------------
local function freeSlots()
  local n = 0
  for s = 1, 16 do if turtle.getItemCount(s) == 0 then n = n + 1 end end
  return n
end

local function fullClear()
  local n    = treesPerSide()
  local fMax = (2 * n - 1) + CLEAR_MARGIN     -- forward extent (home row = local 0)
  local rMax = (2 * n - 2) + CLEAR_MARGIN     -- right extent
  local clearTop = home.y + CLEAR_HEIGHT       -- fly/scan height above the canopy
  local rv   = rightVec()
  local AIR_AFTER = 2                          -- stop a column this many air blocks past the last wood

  -- Budget ~two vertical passes per column plus the horizontal hops. Skip the
  -- clear (try again next cycle) rather than strand the turtle if fuel is short.
  local cols   = (fMax + 1) * (rMax + 1)
  local budget = cols * (2 * CLEAR_HEIGHT + 2) + cols + 200
  if not refuel(budget) then return end

  -- world (x,z) of the local grid cell (f forward, r right)
  local function cell(f, r)
    return home.x + fwd0.x * f + rv.x * r, home.z + fwd0.z * f + rv.z * r
  end

  -- Clear the column under the turtle: dig only logs/leaves, free-fall air, suck
  -- drops down with us, and bail once the canopy's been cleared. Soil, saplings,
  -- and unrecognized blocks stop the descent untouched.
  local function clearColumn()
    local seen, airRun = false, 0
    while pos.y > home.y do
      local ok, d = turtle.inspectDown()
      if not ok then                                   -- air
        if seen then
          airRun = airRun + 1
          if airRun >= AIR_AFTER then break end        -- canopy cleared; don't plow the trunk gap
        end
        turtle.suckDown(); downDig()                   -- (downDig in air just moves down)
      elseif isLog(d) or nameHas(d, "leaves") then     -- wood: dig it, follow drops down
        seen, airRun = true, 0
        turtle.suckDown(); downDig()
      else
        break                                          -- soil / sapling / a build: leave it
      end
    end
    turtle.suck(); turtle.suckDown()
    ascendTo(clearTop)
  end

  send("clearing")
  ascendTo(clearTop)

  -- Serpentine the column grid (adjacent columns are one hop apart at clearTop).
  local fwdFirst = true
  for r = 0, rMax do
    if control.stopRequested() then break end
    if freeSlots() <= 2 then ascendTo(transitY); goHome(); depositLogs(); ascendTo(clearTop) end
    for i = 0, fMax do
      local f = fwdFirst and i or (fMax - i)
      ascendTo(clearTop)
      local wx, wz = cell(f, r)
      goHoriz(wx, wz)
      clearColumn()
    end
    fwdFirst = not fwdFirst
    send("clearing")                                   -- heartbeat: a clear can outlast OFFLINE_SECS
  end

  -- Low vacuum pass: glide one block above the field and suck up the drops that
  -- fell to the ground, so saplings/apples come home instead of needing pickup.
  if not control.stopRequested() then
    ascendTo(home.y + 1)
    local fwd2 = true
    for r = 0, rMax do
      for i = 0, fMax do
        local f = fwd2 and i or (fMax - i)
        local wx, wz = cell(f, r)
        goHoriz(wx, wz)
        turtle.suckDown(); turtle.suck()
      end
      fwd2 = not fwd2
      send("clearing")
    end
  end

  ascendTo(transitY); goHome(); depositLogs()
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
  print("=== Tree farm first-time setup (7x7) ===")
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
      send("chopping")
      local completed = true
      for i = 0, n - 1 do
        local cols = {}
        for j = 0, n - 1 do cols[#cols + 1] = j end
        if i % 2 == 1 then
          local r = {}; for k = #cols, 1, -1 do r[#r + 1] = cols[k] end; cols = r
        end
        for _, j in ipairs(cols) do
          if honorStop() then completed = false; break end  -- STOP: parked + homed
          local t = treeWorld(i, j)
          harvestColumn(t.x, t.z)
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
        if CLEAR_EVERY > 0 and state.sweeps % CLEAR_EVERY == 0 then
          fullClear()       -- mop up stray logs/leaves the per-column harvest missed
        end
        saveConfig()        -- persist logsDeposited + sweeps across reboots
        send("waiting")
        interruptibleSleep(GROW_WAIT)
      end
    end
  end
end

parallel.waitForAny(control.listen, updater.listen, worker)
