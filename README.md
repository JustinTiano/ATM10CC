# Mining & Tree-Farm Fleet

A small fleet of CC:Tweaked turtles reporting to one dashboard computer, all
standardized on a **static 7×7 footprint** and a shared **charcoal fuel loop**.

| File          | Runs on                | Role |
|---------------|------------------------|------|
| `monitor.lua` | Advanced Computer      | Dashboard (modem + monitor + chatBox) |
| `quarry.lua`  | Mining turtle          | Digs a 7×7 shaft to bedrock |
| `stripmine.lua`| Mining turtle         | Branch tunnels at fixed Y levels (run after quarry) |
| `treefarm.lua`| Felling turtle         | 7×7 tree field (16 trees), harvest-from-above |
| `nav.lua`     | every turtle           | Shared library (movement, GPS, ender chests) — **must be present** |
| `control.lua` | every turtle           | START/STOP command listener for the dashboard buttons — **must be present** |
| `updater.lua` | every computer         | Over-the-air deploy listener (downloads + reboots on command) — **must be present** |
| `deploy.lua`  | dashboard (or any)     | Run to push an update to the fleet over rednet |
| `install.lua` | a fresh machine        | One-line bootstrap: `wget run <BASE>install.lua <role>` pulls just that role's files |
| `groups.lua`  | dashboard (hosted)     | Shared manifest: the host URL + which files each role pulls (read by deploy + install) |
| `startup.lua` | every computer         | Auto-runs the computer's role on boot |

> **Install:** the easy way is the one-line bootstrap (§5) —
> `wget run <BASE>install.lua <role>` drops exactly the files that role needs in
> the root `/` and sets `role.txt` for you. To place files by hand instead, put
> **all** the role's `.lua` files in the **same folder (the root `/`)** on each
> turtle — `quarry.lua` does `require("nav")` and `require("control")`, so both
> must sit beside it.
>
> **Dashboard buttons:** the monitor's START/STOP buttons broadcast to each
> turtle. STOP makes a turtle finish its current layer/level/sweep, park on the
> surface (mines) or at home (tree farm), and idle; START resumes it from there.

---

## 1. GPS constellation (one-time)

Every turtle locates itself via GPS, so this must be up first.

- Use **4 computers**, each with a **wireless modem**.
- Put them **high** (y≈120+) and **spread out**, with **different Y values**
  (don't put all four on one flat plane).
- Standard wireless ≈ 64 blocks; an **Ender Modem** reaches infinitely — worth it
  if the farm is far from the hosts.

On each host, with that computer's real coordinates:

```
gps host <x> <y> <z>
```

Make it reboot-proof with a `startup.lua` on each host:

```lua
-- startup.lua on a GPS host
shell.run("gps", "host", "<x>", "<y>", "<z>")
```

Verify from a nearby modem turtle: `gps locate` should print a position. "Could
not determine position" means fewer than 4 hosts are in range.

---

## 2. The fuel loop (ender chests)

The tree farm produces logs → external **furnaces** smelt them to **charcoal** →
every turtle pulls that charcoal from a shared **fuel ender chest**. No human in
the fuel path. This uses **three EnderStorage color channels** (pick three
distinct 3-wool codes):

| Channel | Carried by        | Direction | Feeds |
|---------|-------------------|-----------|-------|
| **FUEL**| every turtle      | charcoal **in** | turtles refuel from it |
| **DUMP**| miners            | blocks **out**  | your storage / sorter |
| **LOGS**| tree farm         | logs **out**    | the furnace array → charcoal → FUEL |

Wire it up (outside Lua): LOGS chest → furnaces (need their own fuel to start) →
charcoal → FUEL chest. Until charcoal is flowing, top up the FUEL chest by hand.

### Reserved turtle slots (important)

The turtles identify their two ender chests **by slot**, because EnderStorage
chests are indistinguishable by item name. Load them exactly:

- **Slot 16** = **FUEL**-channel ender chest
- **Slot 15** = **DUMP**-channel ender chest (miners) / **LOGS**-channel (tree)
- Slots **1–14** = working space (mined blocks; plus saplings + charcoal on the tree)

If a turtle reports `dump_chest_missing` / `fuel_empty`, the chest fell out of
its reserved slot or the channel is dry.

---

## 3. Place & run each turtle

All turtles: attach a **wireless modem** (any side), drop `nav.lua` +
`<role>.lua` + `startup.lua` in root, and create a one-word `role.txt`:

```
echo quarry > role.txt        # or: stripmine / treefarm
```

`startup.lua` then runs that role on boot, but only if the turtle is supposed to
be working. It reads a `runstate.txt` written by the dashboard buttons:

- **missing / `run`** → launch and **resume** automatically (GPS recovery +
  on-disk state). This is the first-run and normal-operation case.
- **`stopped`** (you hit STOP) → the turtle does **not** dig; it parks and waits,
  listening for a START from the dashboard. A reboot keeps it parked instead of
  digging back into your base.
- **`done`** (job finished cleanly) → drops to the shell; nothing to resume.

First run can also be started by hand. At each launch `startup.lua` gives a 3s
**Ctrl+T to cancel** window (and another on each crash-retry); cancelling parks
the turtle so it won't relaunch on the next boot.

### Quarry
Stand on a **corner** of the 7×7 area, **on the surface**, **facing into** the
area. Slots 15/16 = DUMP/FUEL chests, plus some charcoal to bootstrap. Run
`quarry.lua` (or reboot with `role.txt=quarry`). It anchors via GPS, auto-detects
surface Y, digs to bedrock, dumping/refuelling in place, and returns home.

> **Use an Ender Modem on any deep miner.** A standard wireless modem's range
> shrinks at low altitude, so a quarry digging toward bedrock goes out of range
> of the dashboard (and of the GPS hosts) partway down — the panel stops
> updating and reboot-recovery can't get a fix. An Ender Modem reaches
> infinitely and fixes both. For rock-solid deep GPS, give the **GPS hosts**
> Ender Modems too (or mount them high). The dig itself still runs fine on
> dead-reckoning if the signal drops; only live reporting and mid-dig reboots
> need the range.

### Strip miner — run **after** the quarry
Place at the **same corner, facing the same way**. It uses the quarry shaft to
transit between Y levels and carves 2-tall branch corridors out of the front and
back walls. Defaults (edit constants at the top of `stripmine.lua`):
`TUN_LEN=32`, `BRANCH_LEN=16`, `BRANCH_SPC=3`,
`Y_LEVELS = 48,15,0,-16,-40,-59`.

### Tree farm
Stand on the **front-left corner** of the field, **on the ground** (dirt/grass),
**facing into** the field. Slot 16 = FUEL chest, Slot 15 = LOGS chest, plus
saplings + charcoal. Ground across the whole 7×7 must be soil.

```
   7x7 footprint -> 16 trees (every-other block)
   T . T . T . T
   . . . . . . .
   T . T . T . T
   . . . . . . .
   T . T . T . T
   . . . . . . .
   T . T . T . T
   ^ turtle starts here, facing into field
```

Run `treefarm.lua`. First run captures home + heading from GPS (no prompts) and
saves `tree_config.txt`; later runs are silent.

**Periodic full clear.** The normal harvest only digs straight down each trunk,
so big/branchy trees (large oaks especially) leave stray logs between columns and
leaves that won't decay. Every `CLEAR_EVERY` sweeps (default **6**) the turtle
visits every column of the field grid and clears it **top-down and targeted**: it
digs only logs/leaves, free-falls through air, and stops a column once its canopy
is cleared (a short run of air below the last wood) rather than plowing the empty
trunk space to the ground. Standing saplings, the soil, and anything it doesn't
recognize (e.g. a wall you built in the field) are left alone. It **sucks up the
sapling/apple drops** as it follows them down each column and finishes with a low
pass just above the field, so they come home instead of needing hand-collection.
Removing the logs also lets leaves overhanging past the field decay on their own.
Tunables at the top of `treefarm.lua`: `CLEAR_EVERY` (0 = never), `CLEAR_HEIGHT`
(scan height above ground — set it to roughly your tallest tree), `CLEAR_MARGIN`
(how far past the trees to reach). **Keep `CLEAR_HEIGHT` below anything you've
built over the farm** (GPS hosts, walls). The dashboard shows `clearing` and chats
once when a clear starts.

---

## 4. Dashboard

Run `monitor.lua` on the Advanced Computer (modem + monitor required; a
**chatBox** optional, for in-game chat alerts). It shows live status for all
three turtles and sends a chat message on state changes — when a turtle starts,
stops, finishes, or a warning appears. A warning chats once when it first appears
(and again if it changes to a different problem), so it won't spam. The key
human-action alerts are **`LOW FUEL`** (`fuel_empty`) — feed the furnaces — and
**`STUCK`** (`blocked`), which means a turtle hit an unbreakable block. When a
quarry hits one it parks at the surface and waits; clear the block, then press
**START** to resume. Tap a card to acknowledge its warning (red → orange).

Set the dashboard's `role.txt` to `monitor` so `startup.lua` relaunches
`monitor.lua` on boot — required for the dashboard to come back after an
over-the-air self-update (below).

The cards' **START/STOP** buttons broadcast to each turtle: STOP makes a turtle
finish its current layer/level/sweep, park safe, and idle; START resumes it.

A **dashboard self-card** (purple) shows this computer's own status and update
state alongside the turtles.

### Update token (per-card OTA, from the dashboard)

Each card carries its own update control so you never have to drop to the shell
to push code. Every 5 minutes the dashboard compares the code each machine is
running against what's published at `BASE` (a content hash — no version numbers
to maintain) and, when a machine is behind, shows a yellow **`[^]`** token in
that card's title bar.

- **Tap `[^]` on an idle/parked machine** → it updates immediately (the turtle
  downloads its files and reboots; the dashboard self-updates and reboots).
- **Tap `[^]` on a working turtle** → it turns red **`[^!]`** (armed); tap again
  within 5s to confirm. This guard stops a stray tap from rebooting a turtle
  mid-dig. (A reboot is resume-safe — it re-anchors via GPS and continues from
  its `.state` — but it does interrupt the current pass, so update when idle.)

The token clears itself once the machine reports the new code. Because of the
~5-min raw-GitHub cache, a freshly pushed change can take a few minutes to light
up the token. The shell `deploy` command (below) still works and does the same
thing fleet-wide.

---

## 5. Hosting + over-the-air deploy (`groups.lua` + `install.lua` + `deploy.lua`)

All the `.lua` lives in **one hosted place** (a GitHub repo's raw tree, or your
own web server) so updating the fleet is "edit → push → `deploy`", and anyone on
the server can grab the scripts for themselves.

### One-time setup

1. Put this folder in a GitHub repo (or any **path-based** host) and note its raw
   base URL — for GitHub:
   `https://raw.githubusercontent.com/<user>/<repo>/<branch>/`
2. Set that URL as `BASE` in **`groups.lua`** *and* in **`install.lua`** (the
   installer needs it before it can read anything). They must match.
   - A plain paste host (paste.rs/pastebin) **won't** work — those use opaque
     codes, not filenames, so `BASE .. "nav.lua"` can't resolve.
   - HTTP is on by default in CC:Tweaked. Raw GitHub has a ~5-min CDN cache, so a
     fresh `git push` can take a few minutes to show up in-game.

`groups.lua` is the single source of truth: the host URL plus which files each
role pulls. Both `install.lua` and `deploy.lua` read it, so adding a role or a
file is a one-place edit.

### Bootstrapping a fresh machine

On a brand-new turtle/computer with a modem and HTTP, run one line:

```
wget run <BASE>install.lua quarry      # or: stripmine / treefarm / dashboard
```

It downloads **only** that role's files (shared libs + the role script), writes
`role.txt` for you (dashboard → `monitor`), and tells you to reboot. Run it with
no role to get a prompt. This is the cold-start `updater.lua` can't do for itself
— after this first install, `deploy` keeps the machine current.

### Pushing updates to running machines

Every computer runs `updater.lua` in parallel with its main program, listening
for a deploy command. On the dashboard:

- `deploy`            — update **every** group
- `deploy quarry`     — update just the quarry turtle
- `deploy dashboard`  — update the dashboard (incl. its own deploy tooling)

Each targeted computer downloads its files (to `*.new` first, so a bad download
never bricks it), then **reboots into the new code**.

---

## How it stays reboot-safe

Each turtle saves progress to disk (`quarry.state`, `stripmine.state`,
`tree_config.txt`) plus an intent flag (`runstate.txt`). On a chunk reload or
server restart, `startup.lua` re-runs the role **only if `runstate` is `run`**;
the script re-locates via GPS, recovers its exact position **and facing**, and
continues from the last checkpoint — no input needed. If you'd hit STOP, the
turtle stays parked across the reboot and waits for a START instead of resuming.
