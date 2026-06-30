-- quarry.lua -- static 7x7 quarry
-- GPS-anchored, reboot-safe (quarry.state), ender-chest fuel + unload.
--
-- PLACEMENT: stand the turtle on a corner of the 7x7 area, ON the surface,
-- FACING into the area. A GPS constellation must be in range.
-- SLOTS:  16 = FUEL-channel ender chest, 15 = DUMP-channel ender chest.

local nav     = require("nav")
local control = require("control")
local updater = require("updater")

----------------------------------------------------------------------
-- Config
----------------------------------------------------------------------
local WIDTH       = 7
local FUEL_BUFFER = 100
local STATE_FILE  = "quarry.state"
local RISE_CAL    = 1    -- rise this many blocks before heading calibration
local BOTTOM_Y    = -59  -- deepest layer to mine (just above the bedrock zone)

----------------------------------------------------------------------
-- State persistence
----------------------------------------------------------------------
local function saveState(layer, home, hvec)
  local f = fs.open(STATE_FILE, "w")
  f.write(textutils.serialise({ layer = layer, home = home, hvec = hvec }))
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

local function report(status, layer)
  layer = layer or 0
  nav.report(status, {
    layer    = layer,
    currentY = SURFACE_Y and (SURFACE_Y - layer) or "?",
  })
end

----------------------------------------------------------------------
-- Fuel / inventory
----------------------------------------------------------------------
local function fuelNeeded(layer)
  -- one full layer raster + climb home + buffer
  return WIDTH * WIDTH + layer * 2 + FUEL_BUFFER
end

local function ensureFuel(layer)
  while not nav.refuelFromEnder(fuelNeeded(layer), 0, { layer = layer }) do
    report("fuel_empty", layer)
    sleep(10)   -- wait for charcoal to flow into the FUEL chest
  end
end

local function ensureSpace()
  if nav.workingInventoryFull() then nav.dumpInventory() end
end

----------------------------------------------------------------------
-- Single-pass serpentine raster of the current layer (forward-only digs).
-- The turtle has already descended one block into this layer.
----------------------------------------------------------------------
-- Returns true if the whole layer was cleared, or false if a move was blocked
-- by an unbreakable block (turtle left sitting against it, facing it).
-- Honor a dashboard STOP at a safe checkpoint. Returns to the shaft at the
-- current depth, climbs the shaft to the surface, parks until START, then comes
-- home and drops back to this layer -- returning true so the caller aborts and
-- RESTARTS the layer (cheap: the dug part is air, so the redo is just travel).
-- Returns false when no STOP is pending. Checked every block, so STOP now lands
-- in ~a second instead of a whole layer later.
local function honorStop(layer)
  if not control.stopRequested() then return false end
  nav.goTo(0, 0); nav.face(0)
  nav.returnToSurface()
  control.setRunState("stopped")
  report("stopped", layer)
  control.ackStop()
  control.waitForStart()
  control.setRunState("run")
  report("resuming", layer)
  nav.goHome()
  nav.descend(layer)
  return true
end

-- Raster the WIDTH x WIDTH layer from (0,0). Returns (completed, stopped):
--   true,  false -> layer finished
--   false, true  -> a STOP was honored mid-layer (caller restarts the layer)
--   false, false -> hit an obstruction (caller inspects bedrock vs. stuck)
local function digLayer(layer)
  nav.goTo(0, 0); nav.face(0)          -- normalize start (no-op on a fresh layer)
  for row = 0, WIDTH - 1 do
    for _ = 0, WIDTH - 2 do
      if honorStop(layer) then return false, true end
      ensureSpace()
      if not nav.fwd() then return false, false end
    end
    if row < WIDTH - 1 then
      if honorStop(layer) then return false, true end
      ensureSpace()
      if row % 2 == 0 then
        nav.turnRight(); if not nav.fwd() then return false, false end; nav.turnRight()
      else
        nav.turnLeft();  if not nav.fwd() then return false, false end; nav.turnLeft()
      end
    end
  end
  return true, false
end

----------------------------------------------------------------------
-- Main
----------------------------------------------------------------------
nav.open("quarry")
control.tag("quarry")
updater.tag("quarry")

-- A saved state only describes THIS spot. If the turtle was picked up and
-- dropped elsewhere, the GPS fix won't be within the 7x7 footprint of the saved
-- home -- so the state is stale and we must NOT fly back to the old dig site.
local function isStaleState(saved)
  if not (saved and saved.home) then return false end
  local here = nav.locate()
  if not here then return false end          -- no fix: assume in-place reboot
  local dx, dz = here.x - saved.home.x, here.z - saved.home.z
  local limit = WIDTH + 4
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
  local layer = 0

  if saved then
    nav.setAnchor(saved.home, saved.hvec)
    home, hvec = nav.getAnchor()
    SURFACE_Y  = saved.home.y
    layer      = saved.layer or 0
    print("Rebooted -- recovering position via GPS...")
    nav.recoverOnBoot()
    report("resuming", layer)
    nav.goHome()
    nav.descend(layer)           -- drop back to the last completed layer
  else
    home, hvec = nav.firstRunAnchor(RISE_CAL)
    SURFACE_Y  = home.y
    saveState(0, home, hvec)
    print(("Anchored. Surface Y=%d. 7x7 quarry starting..."):format(SURFACE_Y))
    nav.goHome()
    report("starting", 0)
    sleep(2)
  end

  -- Finish cleanly: surface, clear state, report done.
  local function finish(msg)
    print(msg)
    nav.returnToSurface()
    fs.delete(STATE_FILE)
    control.setRunState("done")        -- job over: startup drops to shell, no auto-resume
    report("done", layer)
    print("Quarry complete: " .. layer .. " layers. Home.")
  end

  while true do
    -- A STOP pending right at the layer boundary (turtle is at the shaft origin).
    honorStop(layer)

    -- Stop at the configured floor or when bedrock sits directly below the shaft.
    if (SURFACE_Y - (layer + 1)) < BOTTOM_Y then
      return finish(("Reached floor Y=%d. Done digging."):format(BOTTOM_Y))
    end
    if nav.bedrockBelow() then
      return finish(("Bedrock below at Y=%d. Done digging."):format(SURFACE_Y - layer))
    end

    ensureFuel(layer + 1)
    turtle.digDown()
    nav.down()
    layer = layer + 1

    report("mining", layer)
    print(("Layer %d | Y=%d | Fuel %s"):format(layer, SURFACE_Y - layer, tostring(nav.fuel())))

    -- Dig the layer; a mid-layer STOP parks/waits (honorStop) then restarts it.
    local completed = false
    while not completed do
      local done, stopped = digLayer(layer)
      if done then
        completed = true
      elseif stopped then
        -- honorStop already parked + resumed (homed, dropped back to this layer);
        -- loop to re-raster the layer.
      else
        -- Hit an unbreakable block mid-layer. Return safely by rising into the
        -- layer above (always fully cleared, so it's open) before homing.
        local bedrock = nav.bedrockAhead()
        nav.up()
        nav.goTo(0, 0); nav.face(0)
        if bedrock then
          return finish("Bedrock reached mid-layer. Done digging.")
        end
        report("blocked", layer)         -- not bedrock: raise STUCK + chat the operator
        nav.returnToSurface()
        control.setRunState("stopped")   -- persist so a reboot stays parked, not re-hitting
        report("stopped", layer)         -- show START on the card; stop re-digging the block
        print("Unbreakable obstruction -- parked. Clear it, then press START.")
        control.waitForStart()           -- listener stays alive; wait for a dashboard START
        control.setRunState("run")
        report("resuming", layer)
        nav.goHome()
        nav.descend(layer)               -- back to the last layer; redo it
      end
    end

    nav.goTo(0, 0); nav.face(0)
    nav.verifyPos()
    saveState(layer, home, hvec)
  end
end

parallel.waitForAny(control.listen, updater.listen, worker)
