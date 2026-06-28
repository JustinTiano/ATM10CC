-- cardtest.lua
-- Standalone harness to iterate on the card container in isolation. Renders a
-- single tree-farm card with mock data and working START/STOP buttons, so we
-- can tune card.lua on the real monitor without the full dashboard or turtles.
--
-- Run on the dashboard computer (monitor attached):  cardtest

local card = require("card")

local mon = peripheral.find("monitor")
if not mon then error("No monitor attached!") end
mon.setTextScale(0.5)

-- The tree-farm descriptor: the ONLY per-module customization.
local desc = {
  title = "TREE FARM",
  color = colors.green,
  gps     = true,
  control = true,
  rows = function(s) return {
    { "Field",    (s.size and (s.size .. "x" .. s.size .. " (" .. s.trees .. " trees)")) or "?", colors.lightBlue },
    { "Saplings", s.saplings, s.saplings == 0 and colors.red or colors.lime },
    { "Logs",     s.logsDeposited, colors.lime },
    { "Fuel",     s.fuel, card.fuelColor(s.fuel) },
  } end,
}

-- Mock live state (what the dashboard would normally fill from rednet).
local state = {
  status = "chopping", _last = os.clock(),
  wx = 498, wy = 64, wz = -1010,
  size = 7, trees = 49, saplings = 7, logsDeposited = 320, fuel = 2950,
  running = true,
  _alert = "none",
}

local W, H = mon.getSize()
local CARD_X, CARD_Y = 1, 1
local CARD_W = W                      -- use the whole width to measure the fit

local last = { buttons = nil }

local function render()
  mon.setBackgroundColor(colors.black); mon.clear()
  last = card.draw(mon, desc, state, CARD_X, CARD_W, CARD_Y)
  -- Always-visible size readout on the bottom monitor row + the computer term.
  card.put(mon, 1, H, colors.yellow, colors.black,
           ("mon %dx%d  card needs %dx%d"):format(W, H, CARD_W, (last and last.h) or 0))
end

print(("cardtest: monitor is %dx%d chars (scale 0.5)."):format(W, H))
print("Tap START / STOP on the monitor. Ctrl+T to quit.")
render()
local timer = os.startTimer(1)

while true do
  local e = { os.pullEvent() }
  if e[1] == "monitor_touch" then
    local tx, ty = e[3], e[4]
    if card.hit(last.buttons and last.buttons.start, tx, ty) then
      state.running, state.status, state._last = true, "starting", os.clock()
      print("START tapped")
    elseif card.hit(last.buttons and last.buttons.stop, tx, ty) then
      state.running, state.status, state._last = false, "stopped", os.clock()
      print("STOP tapped")
    end
    render()
  elseif e[1] == "timer" and e[2] == timer then
    timer = os.startTimer(1)
    render()   -- refresh the age field
  end
end
