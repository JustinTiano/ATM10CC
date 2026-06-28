-- install.lua -- one-line bootstrap for a fresh turtle or computer.
--
--   wget run <BASE>install.lua <role>
--     e.g.  wget run https://raw.githubusercontent.com/JustinTiano/ATM10CC/main/install.lua quarry
--
-- Pulls ONLY the files <role> needs (read from the shared groups.lua manifest),
-- writes role.txt so startup.lua launches it on boot, and tells you to reboot.
-- With no role argument it lists the roles and prompts for one.
--
-- This is the cold-start that updater.lua can't do for itself -- updater.lua has
-- to exist before it can self-update. After this first install, the `deploy`
-- command keeps the machine current over the air with no more hand-carrying.
--
-- Roles: quarry | stripmine | treefarm | dashboard   (dashboard => role.txt=monitor)

-- Bootstrap pointer: where to fetch the manifest + files. MUST match the BASE in
-- groups.lua (same repo/host). This one constant is unavoidably here because the
-- installer needs to know where "home" is before it can download anything.
local BASE = "https://raw.githubusercontent.com/JustinTiano/ATM10CC/main/"

-- Download one file to "<name>.new", then swap it into place only on a clean,
-- non-empty fetch -- a failed download never clobbers a good file.
local function fetch(file)
  local resp = http.get(BASE .. file)
  if not resp then return false, "no response" end
  local data = resp.readAll()
  resp.close()
  if not data or #data == 0 then return false, "empty" end
  local tmp = file .. ".new"
  local h = fs.open(tmp, "w"); h.write(data); h.close()
  if fs.exists(file) then fs.delete(file) end
  fs.move(tmp, file)
  return true
end

local function roleNames(GROUPS)
  local names = {}
  for k in pairs(GROUPS) do names[#names + 1] = k end
  table.sort(names)
  return names
end

-- Pull the manifest first so we share one source of truth with deploy.lua.
print("Fetching manifest from " .. BASE .. "...")
local ok, err = fetch("groups.lua")
if not ok then
  error("Could not download groups.lua (" .. tostring(err) .. "). Check BASE/host.")
end
local manifest = dofile("groups.lua")
local GROUPS = manifest.GROUPS

-- Pick the role: command-line arg, else prompt.
local role = ...
if not role then
  print("Which role? (" .. table.concat(roleNames(GROUPS), " / ") .. ")")
  write("> ")
  role = read():gsub("%s+", "")
end

local files = GROUPS[role]
if not files then
  error("Unknown role '" .. tostring(role) .. "'. Known: "
        .. table.concat(roleNames(GROUPS), ", "))
end

print(("Installing '%s' (%d files)..."):format(role, #files))
local fail = 0
for _, file in ipairs(files) do
  local good, ferr = fetch(file)
  print((good and "  ok  " or " FAIL ") .. file .. (ferr and (" (" .. ferr .. ")") or ""))
  if not good then fail = fail + 1 end
end

if fail > 0 then
  print(fail .. " file(s) failed -- fix the host/URL and re-run. role.txt NOT written.")
  return
end

-- Record the role so startup.lua picks the right program on boot. The dashboard
-- runs monitor.lua, so its role.txt is "monitor" (startup does role..".lua").
local roletxt = (role == "dashboard") and "monitor" or role
local h = fs.open("role.txt", "w"); h.write(roletxt); h.close()
print("Wrote role.txt=" .. roletxt)

print("")
print("Done. Reboot to start (hold Ctrl+R, or run: os.reboot() ).")
