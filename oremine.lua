-- oremine.lua -- straight branch miner for the ATM10 Mining Dimension.
-- GPS-anchored, reboot-safe (oremine.state), ender-chest fuel + unload.
--
-- WHY THIS EXISTS: the 7x7 quarry hauls megatons of stone per ore (great for
-- clearing a build site, terrible for gathering). This is a plain BRANCH MINE:
-- at each ATM10 ore band it carves a grid of 2-tall tunnels and keeps whatever
-- ore it drives straight through -- no vein chasing, no scanning, no detours.
-- Way less admin per block than a vein-follower, so it covers far more ground
-- (= finds more resources) for the fuel. It targets ATM10's real ore bands, and
-- digs its OWN access shaft to each Y level (no prior quarry needed).
--
-- FOOTPRINT: the whole dig stays inside a 3x3 CHUNK load (48 blocks). SPAN is
-- how far it reaches from the shaft in every direction; the mined square is
-- (2*SPAN+1) on a side. Default SPAN=16 fits a 3x3 no matter where the turtle
-- sits in its chunk (a 3x3 load guarantees >=16 blocks of reach each way). If you
-- center the chunk loader on the shaft you can push SPAN up toward 22.
--
-- WHERE TO RUN IT: the Mining Dimension -- flat, no hostile spawns, very high
-- ore density, ore gen Y -64..256. Stand the turtle on the surface where it can
-- dig straight down, FACING the direction you want the spine to run. A GPS
-- constellation must be in range IN THE MINING DIMENSION (set one up there).
--
-- SLOTS:  16 = FUEL-channel ender chest, 15 = DUMP-channel ender chest.

local nav     = require("nav")
local control = require("control")
local updater = require("updater")

local CLI = { ... }   -- e.g. `oremine overworld` -> CLI[1] == "overworld"

----------------------------------------------------------------------
-- Config (static; edit here to retune)
----------------------------------------------------------------------
-- Per-dimension ore-band profiles. Selected EXPLICITLY (a turtle can't tell the
-- Overworld from the Mining Dimension -- both are plain stone/deepslate -- so we
-- never guess). Pick one by either:
--   * running it once with an arg:  oremine overworld   (saved to oremine.profile)
--   * or creating oremine.profile yourself containing that one word.
-- The saved choice persists across reboots / dashboard auto-launch and survives a
-- Reset (Reset only re-anchors location; it never changes which dimension you're in).
-- Since we no longer vein-follow, a level catches only ore in its 2-tall slice --
-- so these sit ON the peak Y of each ore band.
local PROFILES = {
  -- Mining Dimension: flat, no mobs, very high density. Ore gen Y -64..256.
  --   105/95  money band (Y 80-120): allthemodium, diamond, emerald, copper,
  --           iron, coal, redstone, tin, xychorium (sampled twice)
  --    20     ancient-debris / nether resources (Y 1-64)
  --   -55     deep metals (Y -63..0): lead, nickel, osmium, platinum, silver, uranium
  mining    = { label = "Mining Dimension", levels = { 105, 95, 20, -55 } },

  -- Overworld (ATM10 = vanilla 1.21 bands + modded). Diamond & allthemodium live
  -- deep. NOTE: allthemodium only spawns below Y-40 (Deep Dark) and needs a
  -- netherite-tier pickaxe -- a diamond turtle can't break it (it'll just stop the
  -- tunnel at that block; see README).
  --   48   copper peak + mid modded ores
  --   14   iron main peak (Y15)
  --  -16   gold peak, lapis, iron deep
  --  -54   diamond peak + redstone + deep metals  <- the money level
  overworld = { label = "Overworld", levels = { 48, 14, -16, -54 } },
}
local DEFAULT_PROFILE = "overworld"   -- used when none has been chosen yet
local PROFILE_FILE    = "oremine.profile"

local SPAN        = 16     -- reach from the shaft, each direction (blocks). Keeps the
                           -- whole dig inside a 3x3 chunk load regardless of placement;
                           -- bump toward 22 if the chunk loader is centered on the shaft.
local BRANCH_SPC  = 3      -- blocks between ribs (2-block walls). Lower = more ore
                           -- caught per level but more stone dug; 3 is the classic pitch.
local FUEL_BUFFER = 300    -- climb-out slack on top of the shaft depth
local STATE_FILE  = "oremine.state"
local RISE_CAL    = 1
local BOTTOM_Y    = -59    -- never mine below this (bedrock zone)

----------------------------------------------------------------------
-- Profile selection (which dimension's ore bands to mine)
----------------------------------------------------------------------
local function profileNames()
  local names = {}
  for k in pairs(PROFILES) do names[#names + 1] = k end
  table.sort(names)
  return names
end

-- Resolve the active profile: a valid CLI arg wins (and is persisted), else the
-- saved oremine.profile, else DEFAULT_PROFILE. Always (re)writes the file so the
-- choice is stable for reboots and dashboard auto-launch (which pass no args).
local function resolveProfile()
  local want = CLI[1]
  if want and not PROFILES[want] then
    print("Unknown profile '" .. tostring(want) .. "' -- use: " .. table.concat(profileNames(), " / "))
    want = nil
  end
  if not want and fs.exists(PROFILE_FILE) then
    local f = fs.open(PROFILE_FILE, "r")
    local s = (f.readLine() or ""):gsub("%s+", "")
    f.close()
    if PROFILES[s] then want = s end
  end
  want = want or DEFAULT_PROFILE
  local f = fs.open(PROFILE_FILE, "w"); f.write(want); f.close()
  return want
end

-- Sort shallowest-first and drop anything below the bedrock-safe floor.
local function bandLevels(levels)
  local out = {}
  for _, y in ipairs(levels) do if y >= BOTTOM_Y then out[#out + 1] = y end end
  table.sort(out, function(a, b) return a > b end)
  return out
end

local PROFILE  = resolveProfile()
local Y_LEVELS = bandLevels(PROFILES[PROFILE].levels)

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
    profile  = PROFILE,
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
-- Branch / corridor carving
----------------------------------------------------------------------
-- Dig a rib out up to `n` (2-tall), then retrace exactly as far as we dug and
-- restore the entry facing. Bedrock-safe: stops the instant it meets an
-- unbreakable block, walks back only as far as it cleared.
local function digOutAndBack(n)
  local moved = 0
  for _ = 1, n do
    -- A hard stop must not have to wait out a whole rib: stop EXTENDING the
    -- instant it's requested. We still retrace exactly what we dug so the tracked
    -- position stays truthful; honorStop() at the next corridor step then parks.
    if control.hardStopRequested() then break end
    ensureSpace()
    if nav.fwdDig2() then moved = moved + 1 else break end
  end
  turtle.digUp()
  nav.turnRight(); nav.turnRight()      -- about-face
  for _ = 1, moved do nav.fwd() end       -- retrace the dug (clear) rib
  nav.turnRight(); nav.turnRight()      -- restore entry facing
end

-- Park to a safe idle state: back to the shaft along the cleared corridor, up to
-- the surface, persist the STOP, then wait for START and come home. Used by both
-- the cycle stop (at the level boundary) and the hard stop (mid-corridor).
local function park()
  nav.goTo(0, 0)
  nav.returnToSurface()
  control.setRunState("stopped")
  report("stopped")
  control.ackStop()
  control.waitForStart()
  control.setRunState("run")
  report("resuming")
  nav.goHome()
end

-- Mid-corridor checkpoint: only a HARD stop (double-tap) parks here and heads
-- home right away. A single (cycle) stop is left for the level-boundary check so
-- the current Y level finishes first. Returns true if it parked (caller restarts
-- the level). Checked every corridor step, so a hard stop lands in seconds.
local function honorStop()
  if not control.hardStopRequested() then return false end
  park()
  return true
end

-- Carve a 2-tall spine `len` long, with perpendicular ribs `ribLen` to each side
-- every `spacing` blocks. Returns true if the spine finished, false if a STOP was
-- honored mid-corridor (caller should restart the level).
local function mineCorridor(len, spacing, ribLen, side, ylevel)
  turtle.digUp()
  for step = 1, len do
    if honorStop() then return false end   -- STOP: parked + homed; abort corridor
    ensureSpace()
    ensureFuel({ side = side, ylevel = ylevel, step = step })
    if not nav.fwdDig2() then break end   -- bedrock/obstruction: stop this corridor
    report("mining", side, ylevel, step)

    if step % spacing == 0 then
      nav.turnLeft();  digOutAndBack(ribLen); nav.turnRight()
      nav.turnRight(); digOutAndBack(ribLen); nav.turnLeft()
    end
  end
  turtle.digUp()
  return true
end

-- Mine one Y level: descend the access shaft, then the spine both ways (each with
-- ribs). A mid-corridor STOP parks/waits (via honorStop) then restarts the level
-- here. Returns true when complete, false if the shaft is blocked before this
-- depth (no deeper level reachable).
local function mineLevel(targetY, targetDepth)
  while true do
    nav.goTo(0, 0)
    local diff = targetDepth - nav.depth()
    if diff > 0 then
      if not nav.descend(diff) then
        print("Shaft blocked before Y=" .. targetY .. "; stopping here.")
        nav.returnToSurface()
        return false
      end
    elseif diff < 0 then nav.ascend(-diff) end

    print(("=== Y=%d (depth=%d) Fuel=%s ==="):format(targetY, targetDepth, tostring(nav.fuel())))

    report("mining", "back", targetY, 0)
    nav.face(0)
    if mineCorridor(SPAN, BRANCH_SPC, SPAN, "back", targetY) then
      nav.goTo(0, 0)
      report("mining", "front", targetY, 0)
      nav.face(2)
      if mineCorridor(SPAN, BRANCH_SPC, SPAN, "front", targetY) then
        nav.goTo(0, 0); nav.face(0)
        return true
      end
    end
    -- STOPped mid-corridor: honorStop already parked/waited/homed; loop restarts.
  end
end

----------------------------------------------------------------------
-- Main
----------------------------------------------------------------------
nav.open("oremine")
control.tag("oremine")
updater.tag("oremine")

-- Saved state describes THIS placement. If the turtle was moved beyond the reach
-- of its dig, the state is stale -- don't transit back to the old site.
local function isStaleState(saved)
  if not (saved and saved.home) then return false end
  local here = nav.locate()
  if not here then return false end          -- no fix: assume in-place reboot
  local dx, dz = here.x - saved.home.x, here.z - saved.home.z
  local limit = SPAN + SPAN + 4
  return (dx * dx + dz * dz) > (limit * limit)
end

local function worker()
  control.setRunState("run")          -- committed to running; survive reboots
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
    print(("Anchored. Surface Y=%d. Ore miner starting..."):format(SURFACE_Y))
    print("Profile: " .. PROFILES[PROFILE].label .. " (" .. PROFILE .. ")")
    nav.goHome()
    report("starting")
    sleep(2)
  end

  print(("[%s] Y levels: %s"):format(PROFILE, table.concat(Y_LEVELS, ", ")))

  for i = startIdx, #Y_LEVELS do
    -- Cycle stop: a single STOP is honored here, at the level boundary, so the
    -- last Y level finished cleanly before parking.
    if control.stopRequested() then park() end

    local targetY     = Y_LEVELS[i]
    local targetDepth = SURFACE_Y - targetY

    if targetDepth < 0 then
      print("Skip Y=" .. targetY .. " (above surface)")
    else
      if not mineLevel(targetY, targetDepth) then break end   -- shaft blocked: done
      saveState(i, home, hvec)
      nav.verifyPos()
      print("Y=" .. targetY .. " complete. Fuel: " .. tostring(nav.fuel()))
    end
  end

  nav.returnToSurface()
  fs.delete(STATE_FILE)
  control.setRunState("done")         -- job over: startup drops to STANDBY
  report("done")
  print("Ore mine complete!")
end

parallel.waitForAny(control.listen, updater.listen, worker)
