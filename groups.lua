-- groups.lua -- single source of truth for the fleet's file layout.
--
-- Both deploy.lua (push OTA updates to running machines) and install.lua
-- (first-time bootstrap of a fresh machine) read this table, so adding a role
-- or a file is a ONE-PLACE edit here -- the two can't drift apart.
--
--   BASE   : where the raw .lua files are hosted (KEEP THE TRAILING SLASH).
--            This is the URL deploy.lua broadcasts to every turtle, and it must
--            match the BASE that install.lua bootstraps from.
--   GROUPS : which files each role pulls. The shared libs
--            (nav/control/updater/startup) ride along with every turtle so a
--            require() never comes up empty.
--
-- >>> EDIT BASE to your repo's raw URL. For GitHub that's:
--       https://raw.githubusercontent.com/<user>/<repo>/<branch>/
--     e.g. https://raw.githubusercontent.com/justin/cc-fleet/main/

return {
  BASE = "https://raw.githubusercontent.com/JustinTiano/ATM10CC/main/",

  GROUPS = {
    quarry    = { "nav.lua", "control.lua", "updater.lua", "startup.lua", "groups.lua", "quarry.lua" },
    stripmine = { "nav.lua", "control.lua", "updater.lua", "startup.lua", "groups.lua", "stripmine.lua" },
    oremine   = { "nav.lua", "control.lua", "updater.lua", "startup.lua", "groups.lua", "oremine.lua" },
    treefarm  = { "nav.lua", "control.lua", "updater.lua", "startup.lua", "groups.lua", "treefarm.lua" },
    -- The dashboard also carries the tooling (groups/deploy/install) so it can
    -- update its own deploy machinery over the air.
    dashboard = { "card.lua", "updater.lua", "startup.lua", "monitor.lua",
                  "groups.lua", "deploy.lua", "install.lua" },
  },
}
