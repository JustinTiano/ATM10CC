-- monitor.lua
-- Turtle-ops dashboard for the Advanced Computer.
-- Attach: wireless modem + monitor + chatBox.
--
-- Renders each module (quarry / tree farm / strip miner / future reactor) as a
-- shared, fixed-size card (see card.lua) tiled into a 2-column grid that fills
-- the whole screen. A card only appears once its module reports in, auto-hides
-- after a clean "done", and flips to a red OFFLINE alarm if a working module
-- goes silent. GPS, status, an always-reserved warning row, and START/STOP
-- buttons all live inside each card. Tap a card to acknowledge its alarm; tap a
-- card's START/STOP button to send that module a control command.

local card    = require("card")
local updater = require("updater")
local groups  = require("groups")   -- BASE + per-role file lists (shared with deploy)

local mon     = peripheral.find("monitor")
local modem   = peripheral.find("modem")
local chat    = peripheral.find("chatBox")

if not modem then error("No modem attached!") end
if not mon   then error("No monitor attached!") end

rednet.open(peripheral.getName(modem))
updater.tag("dashboard")    -- so `deploy dashboard` reaches this computer too
mon.setTextScale(0.5)

----------------------------------------------------------------------
-- Tunables
----------------------------------------------------------------------
local OFFLINE_SECS = 90    -- working module silent this long => OFFLINE alarm
local DROP_SECS    = 25    -- finished module silent this long => hide its card
local GAP          = 1     -- columns/rows between cards
local CARD_TOP     = 1     -- first card row (no header anymore)

-- ACTIVE/TERMINAL/ALARM come from card.lua; DROPPABLE is dashboard policy.
local DROPPABLE = { done = true }

----------------------------------------------------------------------
-- Warnings are STATELESS: the card's warning row reflects whatever is wrong
-- RIGHT NOW, derived from the latest reported state. It defaults to nil (blank,
-- but the row is still reserved so the card never changes height), and clears
-- itself the moment the condition goes away -- no latched "Started" text.
--
-- `baseWarn` covers the conditions every module shares; a device's own `warn`
-- wraps it to add module-specific ones (e.g. the tree farm's empty saplings).
----------------------------------------------------------------------
local function baseWarn(s)
  if s._offline                       then return "OFFLINE - no signal" end
  if s.status == "blocked"            then return "STUCK - check it" end
  if s.status == "fuel_empty"
     or s.status == "low_fuel"        then return "LOW FUEL - feed it" end
  if s.status == "dump_chest_missing" then return "DUMP CHEST GONE" end
  return nil
end

----------------------------------------------------------------------
-- Module registry. Each entry is a card descriptor (title/color/gps/control/
-- rows) PLUS:
--   warn(s)          -> current problem string or nil (drives the warning row)
--   alert(status, s) -> one-shot { chat= } chat-box ping for INFORMATIONAL transitions
--                       (start/resume/stop/done); never used for problems.
----------------------------------------------------------------------
local DEVICES = {
  {
    key = "quarry", title = "QUARRY", color = colors.orange, gps = true, control = true,
    rows = function(s) return {
      { "Layer", tostring(s.layer or 0) .. " (Y=" .. tostring(s.currentY or "?") .. ")", colors.white },
      { "Fuel",  s.fuel, card.fuelColor(s.fuel) },
    } end,
    warn = baseWarn,
    alert = function(status, s)
      if status == "starting" then
        return { chat = "Quarry started. Fuel: " .. tostring(s.fuel) }
      elseif status == "resuming" then
        return { chat = "Quarry resuming from layer " .. tostring(s.layer) }
      elseif status == "stopped" then
        return { chat = "Quarry stopped at layer " .. tostring(s.layer) }
      elseif status == "done" then
        return { chat = "Quarry done! Y=" .. tostring(s.currentY) .. " Fuel: " .. tostring(s.fuel) }
      end
    end,
  },
  {
    key = "treefarm", title = "TREE FARM", color = colors.green, gps = true, control = true,
    rows = function(s) return {
      { "Field",    s.size ~= nil and (tostring(s.size) .. "x" .. tostring(s.size)
                    .. " (" .. tostring(s.trees) .. " trees)") or "?", colors.lightBlue },
      { "Saplings", s.saplings, (s.saplings == 0) and colors.red or colors.lime },
      { "Logs",     s.logsDeposited or 0, colors.lime },
      { "Fuel",     s.fuel, card.fuelColor(s.fuel) },
    } end,
    warn = function(s)
      -- saplings is reported on every sweep, so empty-stock self-clears on restock.
      return baseWarn(s) or (((s.saplings or 1) == 0) and "NO SAPLINGS - restock" or nil)
    end,
    alert = function(status, s)
      if status == "starting" then
        return { chat = "Tree farm online. Fuel: " .. tostring(s.fuel) }
      elseif status == "clearing" then
        return { chat = "Tree farm doing a full-area clear" }
      elseif status == "stopped" then
        return { chat = "Tree farm stopped" }
      end
    end,
  },
  {
    key = "stripmine", title = "STRIP MINER", color = colors.cyan, gps = true, control = true,
    rows = function(s) return {
      { "Y/Side", tostring(s.ylevel or "?") .. " " .. tostring(s.side or ""), colors.white },
      { "Step",   s.step or 0, colors.lime },
      { "Fuel",   s.fuel, card.fuelColor(s.fuel) },
    } end,
    warn = baseWarn,
    alert = function(status, s)
      if status == "starting" then
        return { chat = "Strip miner online. Fuel: " .. tostring(s.fuel) }
      elseif status == "resuming" then
        return { chat = "Strip miner resuming" }
      elseif status == "stopped" then
        return { chat = "Strip miner stopped" }
      elseif status == "done" then
        return { chat = "Strip mine complete! Fuel: " .. tostring(s.fuel) }
      end
    end,
  },
  {
    -- The dashboard's own card. It never reports over rednet (it can't hear its
    -- own broadcasts); its state is filled in locally each tick. No GPS, no
    -- START/STOP -- just status, ID, and its own pending-update token.
    key = "dashboard", title = "DASHBOARD", color = colors.purple,
    gps = false, control = false,
    rows = function(s) return {
      { "ID",   tostring(s.id or os.getComputerID()), colors.lightGray },
      { "Code", s._updateAvail and "update ready" or "up to date",
                s._updateAvail and colors.yellow or colors.lime },
    } end,
    warn = function() return nil end,
  },
}

local DEV_BY_KEY = {}
for _, d in ipairs(DEVICES) do DEV_BY_KEY[d.key] = d end

-- Fixed body-row count = the busiest module, so every card is the same height.
local MAX_ROWS = 0
for _, d in ipairs(DEVICES) do
  local ok, r = pcall(d.rows, {})
  if ok and #r > MAX_ROWS then MAX_ROWS = #r end
end

----------------------------------------------------------------------
-- Live state. store[key] holds the merged payload plus meta: _seen, _last
-- (os.clock), _alert, _alarm, _acked, _offline, running, _geom.
----------------------------------------------------------------------
local store = {}
local cards = {}    -- per-redraw: { {key=, geom=}, ... } for touch routing
local available = {}  -- role -> code hash currently published at BASE (nil until first check)

----------------------------------------------------------------------
-- Output side-effects
----------------------------------------------------------------------
local function notify(msg) if chat then chat.sendMessage(msg, "TURTLE") end end

-- Send a control command to a module. Turtles filter on `to == own tag`.
local function sendCommand(key, cmd)
  rednet.broadcast(textutils.serialise({ to = key, cmd = cmd }))
  notify("Sent " .. cmd:upper() .. " to " .. DEV_BY_KEY[key].title)
end

-- Push an update to one device. Turtles get it as a deploy broadcast (same shape
-- deploy.lua sends); the dashboard can't broadcast to itself, so it self-updates
-- directly and reboots (the UI relaunches via startup.lua).
local function triggerUpdate(key)
  local files = groups.GROUPS[key]
  if not files then return end
  if key == "dashboard" then
    notify("Dashboard self-updating...")
    updater.selfUpdate(groups.BASE, files)
  else
    rednet.broadcast(textutils.serialise({
      deploy = true, to = key, base = groups.BASE, files = files,
    }))
    notify("Updating " .. DEV_BY_KEY[key].title)
  end
end

----------------------------------------------------------------------
-- Message handling
----------------------------------------------------------------------
local function onMessage(msg)
  local dev = DEV_BY_KEY[msg.from]
  if not dev then return end
  local s = store[msg.from]
  if not s then s = { _alert = "none", _acked = true }; store[msg.from] = s end

  local prevStatus = s.status
  for k, v in pairs(msg) do s[k] = v end   -- merge payload (incl. optional warn=)
  s._seen, s._last = true, os.clock()

  -- One-shot notifications for INFORMATIONAL transitions only. Problems are not
  -- handled here -- they surface through the stateless warning row in tick().
  if msg.status ~= prevStatus then
    local a = dev.alert and dev.alert(msg.status, s)
    if a then
      if a.chat then notify(a.chat) end
    end
  end
end

----------------------------------------------------------------------
-- Per-tick housekeeping: offline detection, then re-derive each card's warning
-- from current state. A freshly raised (or changed) warning pings the chat box
-- once; an acknowledged one stays visible (orange); a cleared one blanks the
-- row. Nothing here latches stale text or re-spams the chat for an unchanged
-- warning.
----------------------------------------------------------------------
local function tick()
  local now = os.clock()

  -- Keep the self-card "live": it never reports over rednet, so refresh it here.
  local sd = store["dashboard"]
  if sd then sd._last, sd.status = now, "online" end

  for key, s in pairs(store) do
    local dev     = DEV_BY_KEY[key]
    local age     = now - (s._last or now)
    -- Anything that isn't intentionally quiet (parked/finished) is expected to
    -- keep beating -- including the idle "waiting" state between sweeps -- so a
    -- long silence there means the turtle died: flip it to OFFLINE, not stale.
    local working = s.status ~= nil and not card.QUIET[s.status]
    s._offline    = working and age > OFFLINE_SECS

    -- Pending-update flag: our reported code hash vs what the host now publishes.
    if available[key] and s.codehash then
      s._updateAvail = (s.codehash ~= available[key])
    end
    if not s._updateAvail then s._updArmed = false end       -- nothing to confirm
    if s._updArmed and (now - (s._armedAt or 0) > 5) then     -- confirm timed out
      s._updArmed = false
    end

    local w = dev.warn and dev.warn(s)
    if w then
      -- Chat the operator when a problem first appears OR changes to a different
      -- one (e.g. LOW FUEL -> STUCK); an unchanged warning stays quiet.
      if w ~= s._alert then
        s._acked = false                            -- show red until tapped to ack
        notify(dev.title .. ": " .. w)
      end
      s._alarm, s._alert = true, w
    else
      s._alarm, s._acked, s._alert = false, true, "none"
    end
  end
end

----------------------------------------------------------------------
-- Background update checker: its own parallel task so the blocking http.get
-- calls never freeze the UI. Every CHECK_SECS it fetches each file once from
-- BASE and hashes each role's list exactly the way the turtles hash their own
-- installs; tick() compares the two to drive each card's update token. A role's
-- hash is only published when EVERY file fetched, so a transient 404/timeout
-- never makes an up-to-date machine look out of date.
----------------------------------------------------------------------
local CHECK_SECS = 300
local function updateChecker()
  while true do
    local map, want = {}, {}
    for _, files in pairs(groups.GROUPS) do
      for _, f in ipairs(files) do want[f] = true end
    end
    for f in pairs(want) do
      local resp = http.get(groups.BASE .. f)
      if resp then map[f] = resp.readAll(); resp.close() end
    end
    for role, files in pairs(groups.GROUPS) do
      local complete = true
      for _, f in ipairs(files) do if map[f] == nil then complete = false; break end end
      if complete then
        available[role] = updater.composeHash(files, function(x) return map[x] end)
      end
    end
    os.queueEvent("update_check_done")   -- nudge the UI to redraw with fresh flags
    sleep(CHECK_SECS)
  end
end

-- Tapping a card acknowledges its warning (red -> orange) but leaves the text up
-- until the underlying condition actually clears (then tick() blanks it).
local function ackDevice(s)
  if s then s._acked = true end
end

-- A card shows unless its module finished cleanly and has been quiet a while.
local function visible(s)
  if not s._seen then return false end
  if s._offline then return true end
  if DROPPABLE[s.status] and (os.clock() - (s._last or 0)) > DROP_SECS then return false end
  return true
end

-- "running" drives button arming: an actively-working module shows STOP; an idle
-- one shows START. The idle set is card.TERMINAL (stopped, done, AND waiting) --
-- a module parked between sweeps is idle, so START should arm, not STOP.
local function isRunning(s)
  if s._offline then return false end
  return not card.TERMINAL[s.status]
end

----------------------------------------------------------------------
-- Render: fixed-size cards in a 2-column grid filling the screen.
----------------------------------------------------------------------
local W, H = mon.getSize()
local prevLayout = ""

local function redraw()
  local shown = {}
  for _, d in ipairs(DEVICES) do
    local s = store[d.key]
    if s and visible(s) then shown[#shown + 1] = d end
  end

  -- Cards are fixed height, so only the SET of shown cards can change geometry.
  local sig = W .. "x" .. H .. ":"
  for _, d in ipairs(shown) do sig = sig .. d.key .. "," end
  if sig ~= prevLayout then
    mon.setBackgroundColor(colors.black); mon.clear()
    prevLayout = sig
  end

  cards = {}
  local cols = (W >= 2 * card.MIN_W + GAP) and 2 or 1
  local colW = math.floor((W - (cols - 1) * GAP) / cols)
  local y = CARD_TOP

  if #shown == 0 then
    card.put(mon, 2, y, colors.gray, colors.black, "Waiting for modules to report in...")
    return
  end

  local i = 1
  while i <= #shown do
    local rowH = 0
    for c = 0, cols - 1 do
      local d = shown[i + c]
      if d then
        local s = store[d.key]
        s.running = isRunning(s)
        local x = 1 + c * (colW + GAP)
        local w = (c == cols - 1) and (W - x + 1) or colW
        local geom = card.draw(mon, d, s, x, w, y, MAX_ROWS)
        s._geom = geom
        cards[#cards + 1] = { key = d.key, geom = geom }
        if geom.h > rowH then rowH = geom.h end
      end
    end
    y = y + rowH + GAP
    i = i + cols
  end
end

----------------------------------------------------------------------
-- Touch: a START/STOP button sends a command; tapping elsewhere on a card
-- acknowledges (silences) its alarm.
----------------------------------------------------------------------
local function onTouch(tx, ty)
  for _, c in ipairs(cards) do
    local g = c.geom
    if card.hit(g.buttons and g.buttons.update, tx, ty) then
      card.flash(mon, g.buttons.update)
      local s = store[c.key]
      if s and s._updateAvail then
        -- Idle/parked: act on the first tap. Mid-task (ACTIVE): arm first, act on
        -- the second tap, so a stray touch can't reboot a working turtle.
        if card.ACTIVE[s.status] and not s._updArmed then
          s._updArmed, s._armedAt = true, os.clock()
        else
          s._updArmed = false
          triggerUpdate(c.key)
        end
      end
      return
    elseif card.hit(g.buttons and g.buttons.start, tx, ty) then
      card.flash(mon, g.buttons.start)
      sendCommand(c.key, "start"); return
    elseif card.hit(g.buttons and g.buttons.stop, tx, ty) then
      card.flash(mon, g.buttons.stop)
      sendCommand(c.key, "stop"); return
    elseif tx >= g.extent.x0 and tx <= g.extent.x1
       and ty >= g.extent.y0 and ty <= g.extent.y1 then
      ackDevice(store[c.key]); return
    end
  end
end

----------------------------------------------------------------------
-- Main loop: one event pump for rednet + touch + a 1s housekeeping timer.
-- Runs in parallel with updater.listen so the dashboard can be redeployed over
-- the air too (it reboots itself on update -- needs role.txt="monitor" so
-- startup.lua relaunches monitor.lua afterward).
----------------------------------------------------------------------
local function dashboard()
  print("Dashboard running. Listening...")

  -- Seed the self-card so it shows immediately and can flag its own updates. Its
  -- code hash is computed locally (it never reports over rednet); the checker
  -- fills available["dashboard"] for tick() to compare against.
  store["dashboard"] = store["dashboard"] or { _alert = "none", _acked = true }
  local sd = store["dashboard"]
  sd._seen, sd.status, sd._last = true, "online", os.clock()
  sd.id = os.getComputerID()
  sd.codehash = updater.localHash(groups.GROUPS["dashboard"])

  redraw()
  local timer = os.startTimer(1)

  while true do
    local e = { os.pullEvent() }
    local ev = e[1]
    if ev == "rednet_message" then
      local msg = textutils.unserialise(e[3])
      if type(msg) == "table" and msg.from then onMessage(msg) end
    elseif ev == "monitor_touch" then
      onTouch(e[3], e[4])
    elseif ev == "monitor_resize" then
      W, H = mon.getSize(); prevLayout = ""
    elseif ev == "timer" and e[2] == timer then
      timer = os.startTimer(1)
    end
    tick()
    redraw()
  end
end

parallel.waitForAny(updater.listen, dashboard, updateChecker)
