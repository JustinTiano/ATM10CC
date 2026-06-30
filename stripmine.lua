-- stripmine.lua -- branch-mining at fixed Y levels, run AFTER the 7x7 quarry.
-- GPS-anchored, reboot-safe (stripmine.state), ender-chest fuel + unload.
--
-- PLACEMENT: same surface corner as the quarry, facing the same way (into the
-- hole). It uses the quarry shaft to transit between Y levels.
-- SLOTS:  16 = FUEL-channel ender chest, 15 = DUMP-channel ender chest.

local nav     = require("nav")
local control = require("control")
local updater = require("updater")

----------------------------------------------------------------------
-- Config (static; edit here to retune)
----------------------------------------------------------------------
local WIDTH       = 7
local TUN_LEN     = 32     -- corridor length out from each quarry wall
local BRANCH_LEN  = 16     -- branch length each side of the corridor
local BRANCH_SPC  = 3      -- blocks between branches
local Y_LEVELS    = { 48, 15, 0, -16, -40, -59 }
local FUEL_BUFFER = 200
local STATE_FILE  = "stripmine.state"
local RISE_CAL    = 1
local BOTTOM_Y    = -59  -- never mine below this (the quarry shaft stops here too)

table.sort(Y_LEVELS, function(a, b) return a > b end)   -- shallowest first

-- Drop levels below the bedrock-safe floor: the quarry shaft won't reach them.
do
  local kept = {}
  for _, y in ipairs(Y_LEVELS) do if y >= BOTTOM_Y then kept[#kept + 1] = y end end
  Y_LEVELS = kept
end

----------------------------------------------------------------------
-- State persistence
----------------------------------------------------------------------
local function saveState(idx, home, hvec)
  local f = fs.open(STATE_FILE, "w")
  f.write(textutils.serialise({ yLevelIndex = idx, home = home, hvec = hvec }))
  f.close()
end

local function loadState()
  if not fs.exists(STATE_FILE) then return nil end
  local f = fs.open(STATE_FILE, "r")
  local s = textutils.unserialise(f.readAll())
  f.close()
  return s
end

----------------------------------------------------------------------
-- Reporting
----------------------------------------------------------------------
local SURFACE_Y

local function report(status, side, ylevel, step)
  nav.report(status, {
    currentY = SURFACE_Y and (SURFACE_Y + nav.p.y) or "?",
    side     = side   or "surface",
    ylevel   = ylevel or 0,
    step     = step   or 0,
  })
end

----------------------------------------------------------------------
-- Fuel / inventory (handled in place via the ender chests)
----------------------------------------------------------------------
local function ensureFuel(extra)
  local need = nav.depth() * 2 + FUEL_BUFFER   -- enough to climb out + slack
  while not nav.refuelFromEnder(need, 0, extra) do
    sleep(10)
  end
end

local function ensureSpace()
  if nav.workingInventoryFull() then nav.dumpInventory() end
end

----------------------------------------------------------------------
-- Carve a 2-tall corridor `len` long, with perpendicular branches every
-- `spacing` blocks. Restores corridor facing on exit.
----------------------------------------------------------------------
-- Dig a branch out up to `n` (2-tall), counting only blocks we actually cleared,
-- then retrace exactly that far and restore the entry facing. Bedrock-safe: it
-- stops extending the instant it meets an unbreakable block, and only walks back
-- as far as it really dug, so position stays correct.
local function digOutAndBack(n)
  local moved = 0
  for _ = 1, n do
    ensureSpace()
    if nav.fwdDig2() then moved = moved + 1 else break end
  end
  turtle.digUp()
  nav.turnRight(); nav.turnRight()      -- about-face
  for _ = 1, moved do nav.fwd() end       -- retrace the dug (clear) branch
  nav.turnRight(); nav.turnRight()      -- restore entry facing
end

local function mineCorridor(len, spacing, branchLen, side, ylevel)
  turtle.digUp()
  for step = 1, len do
    ensureSpace()
    ensureFuel({ side = side, ylevel = ylevel, step = step })
    if not nav.fwdDig2() then break end   -- bedrock/obstruction: stop this corridor
    report("mining", side, ylevel, step)

    if step % spacing == 0 then
      nav.turnLeft();  digOutAndBack(branchLen); nav.turnRight()
      nav.turnRight(); digOutAndBack(branchLen); nav.turnLeft()
    end
  end
  turtle.digUp()
end

----------------------------------------------------------------------
-- Main
----------------------------------------------------------------------
nav.open("stripmine")
control.tag("stripmine")
updater.tag("stripmine")

-- Saved state describes THIS placement. If the turtle was moved beyond the reach
-- of its corridors, the state is stale -- don't transit back to the old site.
local function isStaleState(saved)
  if not (saved and saved.home) then return false end
  local here = nav.locate()
  if not here then return false end          -- no fix: assume in-place reboot
  local dx, dz = here.x - saved.home.x, here.z - saved.home.z
  local limit = TUN_LEN + BRANCH_LEN + WIDTH
  return (dx * dx + dz * dz) > (limit * limit)
end

local function worker()
  control.setRunState("run")          -- we are committed to running; survive reboots
  nav.primeFuel()                     -- top up to nav.MIN_FUEL before anything moves
  local saved = loadState()
  if isStaleState(saved) then
    print("Moved since last run -- discarding stale state, re-anchoring here.")
    fs.delete(STATE_FILE)
    saved = nil
  end

  local home, hvec
  local startIdx = 1

  if saved then
    nav.setAnchor(saved.home, saved.hvec)
    home, hvec = nav.getAnchor()
    SURFACE_Y  = saved.home.y
    startIdx   = (saved.yLevelIndex or 0) + 1
    print("Rebooted -- recovering position via GPS...")
    nav.recoverOnBoot()
    report("resuming")
    nav.goHome()
  else
    home, hvec = nav.firstRunAnchor(RISE_CAL)
    SURFACE_Y  = home.y
    saveState(0, home, hvec)
    print(("Anchored. Surface Y=%d. Strip miner starting..."):format(SURFACE_Y))
    nav.goHome()
    report("starting")
    sleep(2)
  end

  print("Y levels: " .. table.concat(Y_LEVELS, ", "))

for i = startIdx, #Y_LEVELS do
  -- Honor a dashboard STOP between Y levels (the turtle is at the shaft origin
  -- here): rise to the surface, idle until START, then resume at the next level.
  if control.stopRequested() then
    nav.returnToSurface()
    control.setRunState("stopped")    -- persist STOP so a reboot stays parked
    report("stopped")
    control.ackStop()
    control.waitForStart()
    control.setRunState("run")
    report("resuming")
    nav.goHome()
  end

  local targetY     = Y_LEVELS[i]
  local targetDepth = SURFACE_Y - targetY

  if targetDepth < 0 then
    print("Skip Y=" .. targetY .. " (above surface)")
  else
    nav.goTo(0, 0)
    local diff = targetDepth - nav.depth()
    if diff > 0 then
      if not nav.descend(diff) then
        -- Shaft hit bedrock before this depth: no deeper level is reachable.
        print("Shaft blocked before Y=" .. targetY .. "; stopping here.")
        nav.returnToSurface()
        break
      end
    elseif diff < 0 then nav.ascend(-diff) end

    print(("=== Y=%d (depth=%d) Fuel=%s ==="):format(targetY, targetDepth, tostring(nav.fuel())))

    -- Back wall: go to far edge, carve outward (+Z)
    report("mining", "back", targetY, 0)
    nav.goTo(0, WIDTH - 1); nav.face(0)
    mineCorridor(TUN_LEN, BRANCH_SPC, BRANCH_LEN, "back", targetY)
    nav.goTo(0, 0)

    -- Front wall: from corner carve outward (-Z)
    report("mining", "front", targetY, 0)
    nav.face(2)
    mineCorridor(TUN_LEN, BRANCH_SPC, BRANCH_LEN, "front", targetY)
    nav.goTo(0, 0)

    saveState(i, home, hvec)
    nav.verifyPos()
    print("Y=" .. targetY .. " complete. Fuel: " .. tostring(nav.fuel()))
  end
end

  nav.returnToSurface()
  fs.delete(STATE_FILE)
  control.setRunState("done")         -- job over: startup drops to shell, no auto-resume
  report("done")
  print("Strip mine complete!")
end

parallel.waitForAny(control.listen, updater.listen, worker)
