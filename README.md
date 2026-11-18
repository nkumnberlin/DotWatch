# DotWatch

DoT and crowd-control timers per enemy for **World of Warcraft: Forever**, for every class that has DoTs.

Current release: **v0.14.2** (on CurseForge as [Dot and CC Watch](https://www.curseforge.com/wow/addons/dot-and-cc-watch), and as a tag here). On `main`, not released yet: 0.14.3 (Priest Mind Soothe), 0.15 (kill skull), 0.16–0.18.1 (German, Russian and Chinese clients and interface). Work in progress: Warlock is tested in game the most; Priest has been tested too, the other classes are new in 0.13/0.14. Feedback and wishes are welcome in the issues.

Forever hides the combat log and doesn't let addons read enemy debuffs during combat. DotWatch works around that: it builds its timers from your own casts, and it detects resists and immunes from the events the game still sends.

## Features

- **Timers per enemy**, each enemy in its own row with your DoTs in fixed slots. A DoT that isn't up shows as a gray placeholder.
- **All DoT classes** (spells taken from WoW Forever's own data):

  | Class | DoTs (fixed rows) | Crowd control (shown while active) |
  |---|---|---|
  | Warlock | Corruption, Immolate, Siphon Life, Unstable Affliction, banes and curses | Fear, Banish, Enslave Demon, Death Coil |
  | Priest | Shadow Word: Pain, Devouring Plague, Holy Fire | Shackle Undead, Chastise, Silence, Mind Soothe |
  | Druid | Moonfire, Insect Swarm, Rake, Lacerate | Entangling Roots, Hibernate, Bash, Pounce, Feral Charge |
  | Hunter | Serpent / Viper Sting, Lacerate, Immolation and Explosive Trap | Freezing Trap, Scare Beast, Scatter Shot, Counterattack |
  | Rogue | Garrote | Sap, Blind, Gouge, Cheap Shot |
  | Shaman | Flame Shock | |
  | Warrior | Rend | Intimidating Shout, Concussion Blow, Intercept |
  | Mage | the burn after Fireball, Pyroblast, Frostfire Bolt | Polymorph |
  | Paladin | | Hammer of Justice, Repentance, Turn Undead |

  Not tracked on purpose: random procs (poisons, Deep Wounds, Ignite, …), combo-point finishers (Rupture, Rip, Kidney Shot), channeled spells, and area crowd control without a target.
- **Traps**: the timer starts on the enemy that sets the trap off, not when you place it.
- **Reads your spellbook**: only spells you know get a row.
- **Enemies stay until they die**: a living enemy keeps its row and health, even with no DoTs on it, and its name blinks softly red while one of your DoTs is missing. No blink while you keep it out of the fight on purpose (Banish, Polymorph, Sap, Mind Soothe, Shackle, …). Fear still blinks.
- **Dungeons**: Forever hides enemy names and IDs there, so DotWatch tells enemies apart by their nameplates. Keep enemy nameplates on.
- **Resist and immune detection**: a resisted DoT starts no timer and shows a red "Resisted" or "Immune" line. A resisted refresh keeps the old timer running.
- **Same-named enemies**: three "Slave Workers" become A, B and C, in the list and as a letter on their nameplates (left of the health bar, or above the plate).
- **Health %** next to each enemy's name, from green to yellow to red.
- **Five display styles**: bars, slim bars, icons with timers, table (one column per DoT, curse and crowd-control spell), and target big with others small, with a live preview in the options.
- **Move mode**: while the window is unlocked it has a purple background, a gold frame and a tab with a **Lock** button. Drag it into place, click Lock, and the list only shows up while timers run.
- **Refresh warning**: DoTs pulse in their last seconds, with an optional sound (ten game sounds, from a soft click to the raid warning horn).
- **Tick marks** on the bars, and a "lost?" mark when a DoT's ticks stop (not while the enemy is banished).
- **Look options**: font size, bar texture, a color per DoT (for your class), window size, growth direction, fading out of combat.
- **Statistics** (optional): resists and immunes per enemy type and spell, and a short summary after each fight.
- **Kill skull** next to each enemy's health: bright when the damage your running DoTs still deal will finish it, dim when not.
- **Languages**: works on English, German, Russian and Chinese (simplified and traditional) clients: spells are found by spell ID and tooltips are read in those languages. The interface is in English, German, Russian and Chinese too: it follows the client language, or choose one under General › Language (or `/dw lang`), then `/reload`. Russian and Chinese texts are machine-assisted and not yet checked by native speakers; corrections are welcome.
- **Classic options window**: `/dw`, the minimap button (Eye of Kilrogg), or Escape › Options › AddOns › DotWatch.

## Install

Easiest: install it from CurseForge. By hand: download the zip from the CurseForge files, and put the `DotWatch` folder into your Forever client's AddOns folder, so that this file exists:

```
World of Warcraft\_forever_\Interface\AddOns\DotWatch\DotWatch.toc
```

Then start the game or type `/reload`.

## Commands

| Command | What it does |
|---|---|
| `/dw` | Open the options |
| `/dw style <bars\|slim\|icons\|table\|focus>` | Change the display style |
| `/dw lock` | Lock or unlock the window (unlocked = move mode, drag it) |
| `/dw test` | Show sample timers, e.g. to position the window |
| `/dw spells` | Show the spells found in your spellbook |
| `/dw reset` | Move the window back to its default spot |
| `/dw lang <auto\|en\|de\|ru\|zhCN\|zhTW>` | Interface language, applied after `/reload`. `/dw lang auto` goes back to the game's language (e.g. if a chosen one can't be read) |
| `/dw help` | List all commands |

## How it works

- **Start**: `UNIT_SPELLCAST_SENT` gives the enemy's name. DotWatch matches it to your target, mouseover, focus or a nameplate. `UNIT_SPELLCAST_SUCCEEDED` starts the timer, with the duration taken from the spell's tooltip.
- **Dungeons**: names and GUIDs are secret there, but `UnitIsUnit` and nameplate tokens stay readable, so an enemy is known by its nameplate from the moment it appears until it disappears. The game draws the hidden name for us.
- **Resists**: when a DoT fails, the game sends `UNIT_COMBAT` with MISS, RESIST or IMMUNE on that enemy in the same frame as the successful cast. If no aura change arrives in that frame, the timer is cancelled.
- **Out of combat** the real debuffs are readable, so DotWatch corrects its timers and learns the exact DoT durations (not crowd control: diminishing returns would shorten them).
- **Banished enemies** are immune to everything; an "Immune" there is not stored as an immunity of that enemy type.
- **Secret values**: the window shows game-drawn values (health), so the game also keeps the window's own position secret. DotWatch keeps its own position numbers and drags the window itself.
- **No click-to-cast**: Forever lets an addon button reach only your current target (macro conditionals don't see nameplate units), so the target bar was removed in 0.9.

## Limits

- A resist is only visible while the enemy has a target or nameplate unit.
- DoTs cast at an enemy that isn't your target, mouseover, focus or a nameplate aren't tracked.
- In dungeons, an enemy whose nameplate disappears can't be recognized again; it gets a new row next time. No statistics there.
- Freezing Trap starts on the first new debuff an enemy gets after the trap was placed; another player's debuff at that moment can set it off in DotWatch.
- Classes other than Warlock are not much tested in game yet.
- On German clients the tooltip wording (kill skull damage, DoT durations) is from Classic Era and not yet checked on Forever. Crowd-control durations on non-English clients come from DotWatch's duration table.
- Russian and Chinese interface texts need a game client whose font has those letters.

## DotProbe

`DotProbe` is the diagnostic addon used to find out what Forever lets addons read in combat. It has no gameplay function: it only writes a log to SavedVariables (`/dp help`). You only need it for development; it is not part of the CurseForge download.

## Releases

Work happens on `main`; nothing is released from there. A version is released only after it was tested in game: `main` is pushed to the `release` branch, the GitHub Action in `.github/workflows/tag-release.yml` creates the tag `v<version>` from `DotWatch.toc`, and CurseForge packages it (see `.pkgmeta`: one `DotWatch` folder, without DotProbe).

## License

MIT, see [LICENSE](LICENSE).
