-- card.lua
-- Reusable dashboard card container. Every module (quarry, tree farm, strip
-- miner, future reactor, ...) renders through card.draw so they all share
-- exactly the same geometry; a module only customizes color, title, and rows.
--
--   local card = require("card")
--   local geom = card.draw(mon, descriptor, state, x, w, y)
--
-- The container is pure presentation: it draws the box and returns hit-boxes
-- (whole-card extent + button rects). The caller decides what taps DO.

local card = {}

----------------------------------------------------------------------
-- Geometry: single source of truth so every card lines up.
----------------------------------------------------------------------
card.LABEL_W = 9     -- "Saplings:" fits in 9; value column starts after it
card.MIN_W   = 24    -- below this the button row gets cramped (truncates)

local BTN_START = "[ START ]"   -- 9 wide
local BTN_STOP  = "[ STOP ]"    -- 8 wide

----------------------------------------------------------------------
-- Status vocabulary + colors (canonical home for the whole dashboard).
----------------------------------------------------------------------
card.ACTIVE   = { mining=true, chopping=true, collecting=true, planting=true,
                  starting=true, resuming=true, clearing=true }
card.TERMINAL = { done=true, waiting=true, stopped=true }
card.ALARM    = { low_fuel=true, fuel_empty=true, no_saplings=true,
                  full_inventory=true, blocked=true, dump_chest_missing=true }

function card.statusColor(s)
  if s == "OFFLINE" then return colors.red end
  if card.ACTIVE[s]   then return colors.lime end
  if card.TERMINAL[s] then return colors.cyan end
  if card.ALARM[s]    then return colors.red end
  return colors.orange
end

function card.fuelColor(f)
  if type(f) ~= "number" then return colors.lightGray end
  if f < 200  then return colors.red
  elseif f < 1000 then return colors.yellow
  else return colors.lime end
end

----------------------------------------------------------------------
-- Small text helpers.
----------------------------------------------------------------------
function card.pad(text, w)   return (tostring(text) .. string.rep(" ", w)):sub(1, math.max(0, w)) end
function card.trunc(text, w) return tostring(text):sub(1, math.max(0, w)) end

function card.ageStr(state)
  local a = math.floor(os.clock() - (state._last or os.clock()))
  if a < 1 then return "now" end
  return a .. "s"
end

function card.ageColor(state, staleSecs)
  if state._offline then return colors.red end
  return (os.clock() - (state._last or 0) > (staleSecs or 10)) and colors.yellow or colors.lime
end

----------------------------------------------------------------------
-- Drawing primitives (paint cells; caller clears/repaints as needed).
----------------------------------------------------------------------
local function put(mon, x, y, fg, bg, text)
  mon.setBackgroundColor(bg); mon.setTextColor(fg)
  mon.setCursorPos(x, y); mon.write(text)
end

local function fillRect(mon, x, y, w, bg)
  if w <= 0 then return end
  mon.setBackgroundColor(bg); mon.setCursorPos(x, y); mon.write(string.rep(" ", w))
end

card.put, card.fillRect = put, fillRect   -- exposed for callers/test harness

-- A horizontal "+----+" rule in the accent color.
local function hrule(mon, x, y, w, color)
  put(mon, x, y, color, colors.black, "+" .. string.rep("-", math.max(0, w - 2)) .. "+")
end

-- One interior "| label: value |" row.
local function bodyRow(mon, x, y, w, color, label, value, valueColor)
  fillRect(mon, x, y, w, colors.black)
  put(mon, x,         y, color, colors.black, "|")
  put(mon, x + w - 1, y, color, colors.black, "|")
  put(mon, x + 2, y, colors.lightGray, colors.black, card.pad(label .. ":", card.LABEL_W))
  put(mon, x + 2 + card.LABEL_W, y, valueColor or colors.white, colors.black,
      card.trunc(value, w - 3 - card.LABEL_W))
end

-- An empty interior row (keeps the side borders so padded cards stay framed).
local function blankRow(mon, x, y, w, color)
  fillRect(mon, x, y, w, colors.black)
  put(mon, x, y, color, colors.black, "|")
  put(mon, x + w - 1, y, color, colors.black, "|")
end

-- Resolve the alert text a card should display. Modules can drive it directly
-- by broadcasting `warn="..."`; otherwise the dashboard's status-derived
-- `_alert` is used. Returns text (or nil) and whether it is a live alarm.
local function alertText(state)
  local text = state.warn
  if not text and state._alert and state._alert ~= "none" then text = state._alert end
  return text, (state._alarm and not state._acked) and text ~= nil
end

----------------------------------------------------------------------
-- card.draw(mon, desc, state, x, w, y0, bodyRows)
--   desc  = { title, color, gps=bool, control=bool, rows=function(state) }
--   state = { status, _last, wx,wy,wz, _alert,_alarm,_acked, _offline, warn, running }
--   bodyRows: pad the module rows to this count so every card is the same
--             height (and the buttons always land in the same place).
-- Layout is fixed: title / [Pos] / bodyRows data / alert / [buttons] / bottom.
-- Returns { h, extent={x0,x1,y0,y1}, buttons={start={x0,x1,y},stop={...}} | nil }
----------------------------------------------------------------------
function card.draw(mon, desc, state, x, w, y0, bodyRows)
  local color  = desc.color
  local right  = x + w - 1
  local y      = y0

  -- Top border carries the title (accent) and status + age (status color). The
  -- title is the turtle's computer label if it set one (so you can tell two of
  -- the same role apart), otherwise the module's default role name.
  local title = (state.name and state.name ~= "") and state.name or desc.title
  title = card.trunc(title, math.max(1, w - 6))
  fillRect(mon, x, y, w, colors.black)
  hrule(mon, x, y, w, color)
  put(mon, x + 2, y, color, colors.black, " " .. title .. " ")
  local titleEnd = x + 2 + #title + 2          -- first free col after " title "
  local dispStatus = state._offline and "OFFLINE" or tostring(state.status)
  local rtext = " " .. dispStatus .. " " .. card.ageStr(state) .. " "
  local rx = right - 1 - #rtext

  -- A pending-update token sits just left of the status and is tappable. "[^]"
  -- (yellow) = update available; "[^!]" (red) = armed, waiting for a confirm tap
  -- (used when the device is mid-task so a stray tap can't reboot it).
  local updBtn = nil
  if state._updateAvail then
    local tok  = state._updArmed and "[^!]" or "[^]"
    local tcol = state._updArmed and colors.red or colors.yellow
    local txk  = rx - 1 - #tok
    if txk >= titleEnd then
      put(mon, txk, y, tcol, colors.black, tok)
      updBtn = { x0 = txk, x1 = txk + #tok - 1, y = y }
    end
  end

  if rx > x + 3 + #title then
    put(mon, rx, y, card.statusColor(dispStatus), colors.black, rtext)
  end
  y = y + 1

  -- Optional GPS row (same for every module that has a position).
  if desc.gps then
    if state.wx then
      bodyRow(mon, x, y, w, color, "Pos",
              string.format("%d,%d,%d", state.wx, state.wy, state.wz), card.ageColor(state))
    else
      bodyRow(mon, x, y, w, color, "Pos", "no fix", colors.gray)
    end
    y = y + 1
  end

  -- Module-specific rows, padded with blank rows to `bodyRows` so all cards
  -- of a dashboard are the same height.
  local rows = desc.rows(state)
  local n = bodyRows or #rows
  for i = 1, n do
    local r = rows[i]
    if r then bodyRow(mon, x, y, w, color, r[1], r[2], r[3])
    else      blankRow(mon, x, y, w, color) end
    y = y + 1
  end

  -- Always-reserved alert row: the built-in [!] warning sign + module text,
  -- or blank. Reserved even when clear so card height never changes.
  do
    local text, live = alertText(state)
    blankRow(mon, x, y, w, color)
    if text then
      put(mon, x + 2, y, live and colors.red or colors.orange, colors.black, "[!]")
      put(mon, x + 6, y, live and colors.white or colors.orange, colors.black,
          card.trunc(text, w - 8))
    end
    y = y + 1
  end

  -- Optional control row: two buttons, live action solid / other dimmed.
  local buttons = nil
  if desc.control then
    fillRect(mon, x, y, w, colors.black)
    put(mon, x, y, color, colors.black, "|"); put(mon, right, y, color, colors.black, "|")

    local running = state.running and true or false
    local sx = x + 2                       -- START at the left
    local tx = right - 1 - #BTN_STOP       -- STOP right-aligned

    if running then
      put(mon, sx, y, colors.gray,  colors.black, BTN_START)      -- dim
      put(mon, tx, y, colors.white, colors.red,   BTN_STOP)       -- armed
    else
      put(mon, sx, y, colors.black, colors.lime,  BTN_START)      -- armed
      put(mon, tx, y, colors.gray,  colors.black, BTN_STOP)       -- dim
    end

    buttons = {
      start = { x0 = sx, x1 = sx + #BTN_START - 1, y = y },
      stop  = { x0 = tx, x1 = tx + #BTN_STOP  - 1, y = y },
    }
    y = y + 1
  end

  -- The update token lives in the title bar but routes like any other button.
  if updBtn then buttons = buttons or {}; buttons.update = updBtn end

  -- Bottom border closes the box.
  hrule(mon, x, y, w, color)
  y = y + 1

  return {
    h = y - y0,
    extent = { x0 = x, x1 = right, y0 = y0, y1 = y - 1 },
    buttons = buttons,
  }
end

-- True if (x,y) falls inside a {x0,x1,y} button rect from card.draw.
function card.hit(btn, x, y)
  return btn and y == btn.y and x >= btn.x0 and x <= btn.x1
end

return card
