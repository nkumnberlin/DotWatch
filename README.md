# DotWatch

Warlock DoT timers per enemy for **World of Warcraft: Forever**.

Forever hides the combat log and doesn't let addons read enemy debuffs during combat. DotWatch works around that: it builds its timers from your own casts, and it detects resists and immunes from the events the game still sends.

## Features

- **Timers per enemy**: Corruption, Immolate, Siphon Life (if learned), Unstable Affliction (if learned), banes and curses, each tracked per enemy.
- **Reads your spellbook**: only the DoTs you know get a row. Missing DoTs show as gray placeholders.
- **Resist and immune detection**: a resisted DoT starts no timer and shows a red "Resisted" or "Immune" line. A resisted refresh keeps the old timer running.
- **Same-named enemies**: three "Slave Workers" become A, B and C, in the list and as a letter above their nameplates.
- **Health %** next to each enemy's name, colored from green to yellow to red.
- **Five display styles**: bars, slim bars, icons with timers, table, and target big with others small. You can switch between them in the options, with a live preview.
- **Target bar**: one clickable button per DoT for your current target. A click casts the DoT, or refreshes it if it's already running. You can place the bar anywhere or dock it under your target frame.
- **Classic options window** and a minimap button with the Eye of Kilrogg icon.

## Install

Copy the `DotWatch` folder into your Forever client's AddOns folder, so that this file exists:

```
World of Warcraft\_forever_\Interface\AddOns\DotWatch\DotWatch.toc
```

Then start the game or type `/reload`.

## Commands

| Command | What it does |
|---|---|
| `/dw` | Open the options |
| `/dw style <bars\|slim\|icons\|table\|focus>` | Change the display style |
| `/dw lock` | Lock or unlock the window |
| `/dw test` | Show sample timers, e.g. to position the window |
| `/dw spells` | Show the DoTs found in your spellbook |
| `/dw help` | List all commands |

## How it works

- **Start**: `UNIT_SPELLCAST_SENT` gives the enemy's name. DotWatch matches it to your target, mouseover, focus or a nameplate to get the enemy's GUID. `UNIT_SPELLCAST_SUCCEEDED` starts the timer, with the duration taken from the spell's tooltip.
- **Resists**: when a DoT fails, the game sends `UNIT_COMBAT` with MISS, RESIST or IMMUNE on that enemy in the same frame as the successful cast. If no aura change arrives in that frame, the timer is cancelled.
- **Out of combat** the real debuffs are readable, so DotWatch corrects its timers and learns the exact durations.
- **Target bar**: secure spell buttons with `unit = target`. The game doesn't allow them to change during combat, so changes to the bar take effect after combat.

## Limits

- A resist is only visible while the enemy has a target or nameplate unit.
- DoTs cast at an enemy that isn't your target, mouseover, focus or a nameplate aren't tracked.
- Warlock only for now. The core works for any class, but the spell table is warlock-specific.

## DotProbe

`DotProbe` is the diagnostic addon used to find out what Forever lets addons read in combat. It has no gameplay function: it only writes a log to SavedVariables (`/dp help`). You only need it for development.
