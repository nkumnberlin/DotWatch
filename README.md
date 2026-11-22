# DotWatch

DoT and crowd-control timers per enemy for **World of Warcraft: Forever**, for every class that has DoTs.

> **Still in development.** DotWatch is young and moves fast. Warlock is tested in game the most, Priest is in testing now, and the other classes are built from the game's data but have barely been played with it. **We depend on your feedback**: bugs, wrong timers, missing spells, translation fixes and wishes are all welcome in the [issues](https://github.com/nkumnberlin/DotWatch/issues) or as a comment on [CurseForge](https://www.curseforge.com/wow/addons/dot-and-cc-watch). See [Feedback](#feedback) for what helps most.

| | Version | Where |
|---|---|---|
| **Current release** | **v0.20.3** | [CurseForge: Dot and CC Watch](https://www.curseforge.com/wow/addons/dot-and-cc-watch), tag `v0.20.3` |
| **Experimental** (off by default) | in v0.20.3 | Priest: follow Devouring Plague jumps, see [Experimental features](#experimental-features-off-by-default) |

Forever hides the combat log and doesn't let addons read enemy debuffs during combat. DotWatch works around that: it builds its timers from your own casts, and it detects resists and immunes from the events the game still sends.

## Features

- **Timers per enemy**, each enemy in its own row with your DoTs in fixed slots. A DoT that isn't up shows as a gray placeholder.
- **All DoT classes** (spells taken from WoW Forever's own data):

  | Class | DoTs (fixed rows) | Crowd control (shown while active) |
  |---|---|---|
  | Warlock | Corruption, Immolate, Siphon Life, Bane / Curse of Agony and the other banes and curses | Fear, Banish, Subjugate Demon, Death Coil |
  | Priest | Shadow Word: Pain, Devouring Plague, Holy Fire | Shackle Undead, Chastise, Silence, Mind Soothe |
  | Druid | Moonfire, Insect Swarm, Rake, Lacerate | Entangling Roots, Hibernate, Bash, Pounce, Feral Charge |
  | Hunter | Serpent / Viper Sting, Lacerate, Immolation and Explosive Trap | Freezing Trap, Scare Beast, Scatter Shot, Counterattack |
  | Rogue | Garrote | Sap, Blind, Gouge, Cheap Shot |
  | Shaman | Flame Shock | |
  | Warrior | Rend | Intimidating Shout, Concussion Blow, Intercept |
  | Mage | the burn after Fireball, Pyroblast, Frostfire Bolt | Polymorph |
  | Paladin | | Hammer of Justice, Repentance, Turn Undead |

  Not tracked on purpose: random procs (poisons, Deep Wounds, Ignite, …), combo-point finishers (Rupture, Rip, Kidney Shot), channeled spells, and area crowd control without a target.
- **Reads your spellbook**: only spells you know get a row.
- **Tracked spells page**: a checkbox for every spell DotWatch knows for your class, also for spells you haven't learned yet (gray name, faded icon), so you can choose ahead of time. Untracked spells get no timer, no placeholder, no red blink and no nameplate status. "Default list" puts everything back. Holy Fire is off by default (Shadow priests don't cast it).
- **Traps**: the timer starts on the enemy that sets the trap off, not when you place it.
- **Enemies stay until they die**: a living enemy keeps its row and health, even with no DoTs on it, and its name blinks softly red while one of your DoTs is missing. In the open world a row goes away as soon as the enemy's nameplate disappears dead. No blink while you keep it out of the fight on purpose (Banish, Polymorph, Sap, Mind Soothe, Shackle, …). Fear still blinks.
- **Dungeons**: Forever hides enemy names and IDs there, so DotWatch tells enemies apart by their nameplates, and (0.20.4) by your target, focus, your pet's and your party's targets and the boss frames. Keep enemy nameplates on: DotWatch says so once in a dungeon when they are off. Options › General › "Game nameplates" can switch them on for you ("Always show enemy plates") and show them as far away as the game allows ("Max plate range", 60 yards); both are off by default, change only out of combat and give back your old setting when unticked.
- **Resist and immune detection**: a resisted DoT starts no timer and shows a red "Resisted" or "Immune" line. A resisted refresh keeps the old timer running. Since 0.21 the enemy's block in the list also flashes twice (red, purple when immune), for crowd control too; Options › Timers › "Flash on resist" switches it to the whole window or off.
- **Same-named enemies**: three "Slave Workers" become A, B and C, in the list and as a letter on their nameplates (left of the health bar, or above the plate).
- **Enemy health** next to each name as percent, as a bar, or both, from green to yellow to red.
- **Nameplate status** (Enemies page, with a live preview of two nameplates): show missing DoTs right on the enemy's plate by coloring its letter, a red frame, a missing count, or **mini bars** for each DoT. The mini bars can be made taller or thinner, moved up or down (also above the plate, or below the enemy's cast bar), get the DoT's icon before or after them (grayed out while missing) and tick marks.
- **Crowd-control warning**: your crowd control blinks and turns red in its last seconds (2–10 s, default 5).
- **Five display styles**: bars, slim bars, icons with timers, table (one column per DoT, curse and crowd-control spell), and target big with others small, with a live preview in the options.
- **Move mode**: while the window is unlocked it has a purple background, a gold frame and a tab with a **Lock** button. Drag it into place, click Lock, and the list only shows up while timers run.
- **Refresh warning**: DoTs pulse in their last seconds, with an optional sound (ten game sounds, from a soft click to the raid warning horn).
- **Tick marks** on the bars, and a "lost?" mark when a DoT's ticks stop (not while the enemy is banished).
- **Look options**: font size, bar texture, a color per DoT (for your class), window size, growth direction, fading out of combat.
- **Demonic Brand** (Warlock, Demonology talent, 0.22): your Searing Pain starts a 10 s "Demonic Brand" timer on that enemy, shown while it runs, always as the enemy's first row (0.22.1). A gold number after the time shows how many of the pet's 6 empowered attacks are left (0.22.2: on by default; Options › Tracked spells). Forever doesn't tell addons which attack used a charge, so DotWatch counts a charge when the branded enemy takes fire or shadow damage and its debuffs change in the same moment, but not on your own DoT ticks and casts. At 0 the timer ends. Only with the talent learned.
- **Statistics** (optional): resists and immunes per enemy type and spell, and a short summary after each fight.
- **Languages**: English, German, Russian and Chinese (simplified and traditional) clients and interface, see [Languages](#languages).
- **Classic options window**: `/dw`, the minimap button (Eye of Kilrogg), or Escape › Options › AddOns › DotWatch. Pages: General, Display, Look, Timers, Tracked spells, Enemies, Statistics.

### Experimental features (off by default)

New features that rely on a guess ship switched off and marked "experimental", so testers can try them in a normal release while nothing changes for everyone else. Turn them on in the options; feedback decides whether they become a normal feature.

- **Follow Devouring Plague jumps** (Priest, talent Devouring Contagion), Options › Tracked spells › "Devouring Plague jumps (experimental)": when an enemy dies with your Devouring Plague, up to two nearby enemies get an estimated plague (flash "jumped") with the time that was left on the dead enemy. The next shadow tick confirms it; without a tick within 6 s in view it is dropped. The page also shows whether DotWatch found the talent.

## Languages

| Language | Spells recognized | Tooltips read (durations) | Interface |
|---|---|---|---|
| English | yes | yes | yes |
| German (deDE) | yes | yes (Classic Era wording, not yet checked on Forever) | yes |
| Russian (ruRU) | yes | yes | yes (not yet checked by a native speaker) |
| Chinese, simplified (zhCN) | yes | yes | yes (not yet checked by a native speaker) |
| Chinese, traditional (zhTW) | yes | yes | yes (not yet checked by a native speaker) |

- Spells are found by spell ID, so their names always come from the game in its own language. Other client languages (French, Spanish, Korean, …) work too, with an English interface. Crowd-control durations come from DotWatch's own table there.
- The interface follows the game's language. To choose another one: Options › General › Language, or `/dw lang de` (or `en`, `ru`, `zhCN`, `zhTW`), then `/reload`. `/dw lang auto` goes back to the game's language.
- Russian and Chinese need a game client whose font has those letters. If you pick one and see only boxes, type `/dw lang auto` and `/reload` (DotWatch reminds you of this in English at every login).
- Translations are machine-assisted. Corrections from native speakers are very welcome in the issues.

## Install

Easiest: install it from CurseForge. By hand: download the zip from the CurseForge files, and put the `DotWatch` folder into your Forever client's AddOns folder, so that this file exists:

```
World of Warcraft\_forever_\Interface\AddOns\DotWatch\DotWatch.toc
```

Then start the game or type `/reload`.

**Testing a version that isn't released yet** (rare, experimental features usually ship switched off in a release instead): use the files from the test branch, keep the folder name `DotWatch`, and switch off automatic updates for DotWatch in the CurseForge app, or it replaces the test version with the last release.

## Commands

| Command | What it does |
|---|---|
| `/dw` | Open the options |
| `/dw style <bars\|slim\|icons\|table\|focus>` | Change the display style |
| `/dw lock` | Lock or unlock the window (unlocked = move mode, drag it) |
| `/dw test` | Show sample timers, e.g. to position the window |
| `/dw spells` | Show the spells found in your spellbook |
| `/dw plates` | Letters on the nameplates of same-named enemies on/off |
| `/dw platedots` | DoT icons on nameplates on/off |
| `/dw platey <px>` | Move the nameplate icons up or down (can be negative) |
| `/dw chat` | Resist/immune messages in chat on/off |
| `/dw debug` | Debug lines in chat on/off (the debug log is saved either way) |
| `/dw reset` | Move the window back to its default spot |
| `/dw clear` | Remove all timers |
| `/dw learned` | Show the DoT durations learned from real debuffs |
| `/dw lang <auto\|en\|de\|ru\|zhCN\|zhTW>` | Interface language, applied after `/reload` |
| `/dw help` | List all commands |

## How it works

- **Start**: `UNIT_SPELLCAST_SENT` gives the enemy's name. DotWatch matches it to your target, mouseover, focus or a nameplate. `UNIT_SPELLCAST_SUCCEEDED` starts the timer, with the duration taken from the spell's tooltip.
- **Dungeons**: names and GUIDs are secret there, but `UnitIsUnit` and nameplate tokens stay readable, so an enemy is known by its nameplate from the moment it appears until it disappears. Since 0.20.4 a key also sticks to "anchor" tokens (target, focus, pet and party targets, boss frames), so an enemy keeps its timers across target switches, plates that flicker away and casts from outside nameplate range. A cast with a hidden name goes to the first hostile unit of target, mouseover, focus, target of target. The game draws the hidden name for us.
- **Resists**: when a DoT fails, the game sends `UNIT_COMBAT` with MISS, RESIST or IMMUNE on that enemy in the same frame as the successful cast. If no aura change arrives in that frame, the timer is cancelled.
- **Out of combat** the real debuffs are readable, so DotWatch corrects its timers and learns the exact DoT durations (not crowd control: diminishing returns would shorten them).
- **Health**: Forever keeps enemy health secret from addons, so DotWatch never compares it in Lua. Health goes straight into game-drawn bars. (The kill skull of 0.15–0.20, which let the game compare health with the damage your DoTs still deal, was removed in 0.21.)
- **Devouring Plague jumps** (experimental): the game doesn't say where a plague jumps. DotWatch takes the enemies whose auras changed right around the death as candidates and waits for a shadow tick on them to confirm.
- **Languages**: every spell has its spell ID; the game names it in its own language, and that name is matched against casts, the spellbook and auras. Saved settings (colors, statistics, immunities, tracked spells) stay keyed by the English name, so they survive a language change.
- **Banished enemies** are immune to everything; an "Immune" there is not stored as an immunity of that enemy type.
- **Secret values**: the window shows game-drawn values (health), so the game also keeps the window's own position secret. DotWatch keeps its own position numbers and drags the window itself.
- **No click-to-cast**: Forever lets an addon button reach only your current target (macro conditionals don't see nameplate units), so the target bar was removed in 0.9.

## Limits

- A resist is only visible while the enemy has a target or nameplate unit.
- DoTs cast at an enemy that isn't your target, mouseover, focus or a nameplate aren't tracked.
- In dungeons, an enemy whose nameplate disappears and that no target, focus, party target or boss frame points at can't be recognized again; it gets a new row next time. No statistics there.
- Freezing Trap starts on the first new debuff an enemy gets after the trap was placed; another player's debuff at that moment can set it off in DotWatch.
- Devouring Plague jumps are a guess until the first shadow tick confirms them; another player's debuff or shadow damage at that moment can mislead it.
- Classes other than Warlock and Priest are not much tested in game yet.
- Tick marks on the nameplate mini bars are skipped when the game keeps the plate's width secret.
- On German clients the tooltip wording (DoT durations) is from Classic Era and not yet checked on Forever. Crowd-control durations on non-English clients come from DotWatch's duration table.
- Russian and Chinese interface texts need a game client whose font has those letters.

## Feedback

DotWatch is still in development and gets better mostly through reports from players. Open an [issue](https://github.com/nkumnberlin/DotWatch/issues) or comment on CurseForge. What helps most:

- your **class**, **game language** and the **DotWatch version** (shown at login and in the options window),
- **what you did and what you expected**: which spell, which enemy, open world or dungeon,
- a **screenshot** of the window or nameplates, and any **BugSack** error,
- the **debug log**: right after the fight, type `/reload` once (that saves the log), then attach this file:
  ```
  World of Warcraft\_forever_\WTF\Account\<your account>\SavedVariables\DotWatch.lua
  ```
  It keeps the last 600 lines of the current session and the session before. A second `/reload` pushes the older one out, so send it soon. The file holds only DotWatch's own data: settings, statistics, enemy names and the log.

## DotProbe

`DotProbe` is the diagnostic addon used to find out what Forever lets addons read in combat. It has no gameplay function: it only writes a log to SavedVariables (`/dp help`). You only need it for development; it is not part of the CurseForge download.

## Development and releases

Work happens on `main`; nothing is released from there. Features that rely on a guess ship switched off and marked "experimental" until tester feedback confirms them; bigger test versions go on their own branch until they are approved. A version is released only after it was tested in game: `main` is pushed to the `release` branch, the GitHub Action in `.github/workflows/tag-release.yml` creates the tag `v<version>` from `DotWatch.toc`, and CurseForge packages it (see `.pkgmeta`: one `DotWatch` folder, without DotProbe and the repo docs).

Notes for contributors and coding agents (rules, what Forever allows, conventions) are in [AGENTS.md](AGENTS.md).

## License

MIT, see [LICENSE](LICENSE).
