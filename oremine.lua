-- oremine.lua -- ore-seeking branch miner for the ATM10 Mining Dimension.
-- GPS-anchored, reboot-safe (oremine.state), ender-chest fuel + unload.
--
-- WHY THIS EXISTS: the 7x7 quarry hauls megatons of stone per ore (great for
-- clearing a build site, terrible for gathering). Plain branch mining is far
-- more fuel-efficient but only catches a vein it physically tunnels through.
-- This adds VEIN-FOLLOWING: at every corridor/branch step it scans the 2-tall
-- cross-section and floods out along any ore it can see, so a branch harvests
-- everything within a block or two of the tunnel -- the best ore-per-fuel of the
-- three. It also targets ATM10's real ore bands instead of arbitrary depths.
--
-- WHERE TO RUN IT: the Mining Dimension -- flat, no hostile spawns, very high
-- ore density, ore gen Y -64..256. Stand the turtle on the surface where it can
-- dig straight down, FACING the direction you want the corridors to run. It digs
-- its OWN access shaft to each Y level (no prior quarry needed). A GPS
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
-- Each pass carves a 2-tall corridor + branches and vein-follows outward, so a
-- level harvests roughly its Y +/- a few blocks.
local PROFILES = {
  -- Mining Dimension: flat, no mobs, very high density. Ore gen Y -64..256.
  --   105/95  money band (Y 80-120): allthemodium, diamond, emerald, copper,
  --           iron, coal, redstone, tin, xychorium (sampled twice; add 85/115 for more)
  --    20     ancient-debris / nether resources (Y 1-64)
  --   -55     deep metals (Y -63..0): lead, nickel, osmium, platinum, silver, uranium
  mining    = { label = "Mining Dimension", levels = { 105, 95, 20, -55 } },

  -- Overworld (ATM10 = vanilla 1.21 bands + modded). Diamond & allthemodium live
  -- deep. NOTE: allthemodium only spawns below Y-40 (Deep Dark) and needs a
  -- netherite-tier pickaxe -- a diamond turtle skips it (the vein-follower learns
  -- and skips un-diggable ore fast; see README).
  --   48   copper peak + mid modded ores
  --   14   iron main peak (Y15)
  --  -16   gold peak, lapis, iron deep
  --  -54   diamond peak + redstone + allthemodium + deep metals  <- the money level
  overworld = { label = "Overworld", levels = { 48, 14, -16, -54 } },
}
local DEFAULT_PROFILE = "overworld"   -- used when none has been chosen yet
local PROFILE_FILE    = "oremine.profile"

local TUN_LEN     = 48     -- corridor length out from the shaft, each direction
local BRANCH_LEN  = 12     -- branch length each side of the corridor
local BRANCH_SPC  = 3      -- blocks between branches (2-block wall; veins poke through)
local MAX_VEIN    = 96     -- safety cap on a single vein-follow (blocks)
local FUEL_BUFFER = 400    -- climb-out + vein-follow slack on top of the shaft depth
local STATE_FILE  = "oremine.state"
local RISE_CAL    = 1
local BOTTOM_Y    = -59    -- never mine below this (bedrock zone)

-- What counts as ore to chase. Substring match on the block id; covers vanilla +
-- deepslate (`*_ore`), modded ores, and ancient debris (which lacks `_ore`).
local ORE_HINTS = { "_ore", "ancient_debris" }

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

local function isOre(name)
  if not name then return false end
  for _, h in ipairs(ORE_HINTS) do
    if name:find(h, 1, true) then return true end
  end
  return false
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
-- Vein-following. From the turtle's current cell, recursively dig every
-- connected ore block, ALWAYS returning to the starting cell and facing so the
-- caller's tracked position stays truthful. Each recursion checks all 6
-- neighbours; we only step (and thus recurse/return) when a move actually
-- succeeds, so a falling-gravel hiccup can't desync position. A reboot mid-vein
-- is safe too: recoverOnBoot re-derives pos from GPS.
----------------------------------------------------------------------
local veinSeen   = 0
local undiggable = {}   -- block ids the equipped pickaxe can't break (tier-gated,
                        -- e.g. allthemodium with a sub-netherite turtle): learned
                        -- once, then skipped instantly instead of grinding on them.

local digVein   -- forward decl (chase recurses back into it)

-- Chase one ore neighbour in a given direction: if it's ore we can break, step in
-- (tracked move), recurse, then step back. A single failed dig on a still-present
-- ore means it's tier-gated -- record it and skip its kind for the rest of the run.
local function chase(depth, inspectFn, digFn, stepFn, backFn)
  local ok, d = inspectFn()
  if not (ok and isOre(d.name)) then return end
  if undiggable[d.name] then return end
  if not digFn() then                       -- one quick attempt to break it
    local sOk, s = inspectFn()
    if sOk and isOre(s.name) then undiggable[d.name] = true end   -- still there: can't mine it
    return
  end
  if stepFn() then
    veinSeen = veinSeen + 1
    digVein(depth + 1)
    backFn()
  end
end

digVein = function(depth)
  if depth > MAX_VEIN then return end
  ensureSpace()
  chase(depth, turtle.inspectDown, turtle.digDown, nav.down, nav.up)
  chase(depth, turtle.inspectUp,   turtle.digUp,   nav.up,   nav.down)
  -- The four horizontal neighbours. Four right-turns net zero facing change.
  for _ = 1, 4 do
    chase(depth, turtle.inspect, turtle.dig, nav.fwd, function()
      nav.turnRight(); nav.turnRight(); nav.fwd(); nav.turnRight(); nav.turnRight()
    end)
    nav.turnRight()
  end
end

-- Harvest any ore touching the full 2-tall tunnel cross-section at the current
-- step: scan from the lower cell (floor + lower walls), then the upper cell
-- (upper walls + ceiling). Restores position (back in the lower cell, same facing).
local function harvestAround()
  veinSeen = 0
  digVein(0)
  if nav.up() then
    digVein(0)
    nav.down()
  end
  return veinSeen
end

----------------------------------------------------------------------
-- Branch / corridor carving
----------------------------------------------------------------------
-- Dig a branch out up to `n` (2-tall), vein-following at each step, then retrace
-- exactly as far as we dug and restore the entry facing. Bedrock-safe: stops the
-- instant it meets an unbreakable block, walks back only as far as it cleared.
local function digOutAndBack(n)
  local moved = 0
  for _ = 1, n do
    -- A hard stop must not have to wait out a whole branch: stop EXTENDING the
    -- instant it's requested. We still retrace exactly what we dug so the tracked
    -- position stays truthful; honorStop() at the next corridor step then parks.
    if control.hardStopRequested() then break end
    ensureSpace()
    if nav.fwdDig2() then moved = moved + 1; harvestAround() else break end
  end
  turtle.digUp()
  nav.turnRight(); nav.turnRight()      -- about-face
  for _ = 1, moved do nav.fwd() end       -- retrace the dug (clear) branch
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

-- Returns true if the corridor finished, false if a STOP was honored mid-corridor
-- (caller should restart the level).
local function mineCorridor(len, spacing, branchLen, side, ylevel)
  turtle.digUp()
  harvestAround()
  for step = 1, len do
    if honorStop() then return false end   -- STOP: parked + homed; abort corridor
    ensureSpace()
    ensureFuel({ side = side, ylevel = ylevel, step = step })
    if not nav.fwdDig2() then break end   -- bedrock/obstruction: stop this corridor
    harvestAround()
    report("mining", side, ylevel, step)

    if step % spacing == 0 then
      nav.turnLeft();  digOutAndBack(branchLen); nav.turnRight()
      nav.turnRight(); digOutAndBack(branchLen); nav.turnLeft()
    end
  end
  turtle.digUp()
  return true
end

-- Mine one Y level: descend the access shaft, then both corridors. A mid-corridor
-- STOP parks/waits (via honorStop) then restarts the level here. Returns true when
-- complete, false if the shaft is blocked before this depth (no deeper reachable).
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
    if mineCorridor(TUN_LEN, BRANCH_SPC, BRANCH_LEN, "back", targetY) then
      nav.goTo(0, 0)
      report("mining", "front", targetY, 0)
      nav.face(2)
      if mineCorridor(TUN_LEN, BRANCH_SPC, BRANCH_LEN, "front", targetY) then
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
-- of its corridors, the state is stale -- don't transit back to the old site.
local function isStaleState(saved)
  if not (saved and saved.home) then return false end
  local here = nav.locate()
  if not here then return false end          -- no fix: assume in-place reboot
  local dx, dz = here.x - saved.home.x, here.z - saved.home.z
  local limit = TUN_LEN + BRANCH_LEN + 4
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
