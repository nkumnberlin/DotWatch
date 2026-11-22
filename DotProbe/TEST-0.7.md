# DotProbe 0.7 – range and Demonic Brand test plan

Two DotWatch features wait on facts only the game can give:

- **Range dimming** (#20): dim a row when its spell can't reach the enemy.
- **Demonic Brand**: a 10 s timer from Searing Pain, with the pet attacks ("charges") left.

0.7 adds `Probe07.lua`. The 0.6 targeting tests (`TEST-0.6.md`) are still in and still open; you can run both in one session.

## Questions

| # | Question | Why it matters |
|---|---|---|
| R1 | Which range APIs exist on 1.60.1, and what do they return for an enemy **in combat**: plain `1`/`0`, `nil`, or secret `S`? (`C_Spell.IsSpellInRange`, old `IsSpellInRange`, `C_ActionBar.IsActionInRange`, old `IsActionInRange`) | Plain = DotWatch can dim rows itself. Secret = only through the game's widgets. |
| R2 | Does it work for **nameplate units**, not only the target? | DotWatch needs it per enemy. |
| R3 | If secret: does `SetAlphaFromBoolean` exist and does the green square follow the range? | The fallback for secret answers. |
| R4 | Do the answers match reality (walk out of 30 / 20 yd, stand behind a pillar)? Does the API ignore line of sight? | Whether "out of sight" needs the error-message trick. |
| R5 | Do `CheckInteractDistance`, `UnitInRange`, `UnitDistanceSquared` work on enemies, or get blocked in combat? | Other range sources. |
| B1 | Is the talent readable (name, rank, max rank), and what does the brand tooltip say per rank (attack count)? | The charge count per rank (the web sources disagree: 2/4/6 or 3). |
| B2 | Is the brand a **debuff on the enemy** (`UNIT_AURA added` on the mob right after Searing Pain) or a **buff on the pet**? | Where to look for it. |
| B3 | Can any aura read see the brand **in combat** (`GetAuraDataByIndex`, `GetAuraDataBySpellName`, pet buffs)? `applications` readable? | An exact charge counter, no guessing. |
| B4 | Does every empowered pet attack show up as its own `UNIT_COMBAT` hit (school 4 fire / 32 shadow) on the branded enemy? When? | A charge counter from hits, if B3 fails. |
| B5 | Are pet casts readable (`UNIT_SPELLCAST_SUCCEEDED` for `pet`, Imp Firebolt)? | Count charges from pet casts. |
| B6 | Does the brand vanish when the charges are used up (aura removed before 10 s)? | End the timer early. |
| B7 | Same with a melee pet (Voidwalker / Felhunter / Succubus) as with the Imp? | Fire vs. shadow bonus, cast vs. melee. |

## Before you start

1. `/reload`, the chat says **DotProbe: 0.7 loaded**.
2. Put **Corruption**, **Fear** and **Death Coil** on an action bar (the action-bar checks need them there).
3. `/dp clear` then `/dp start 0.7`.
4. `/dp range Corruption, Fear, Death Coil`. A small grid appears at the top left: rows = target, focus, mouseover, enemy nameplates; a green square = "in range" for that spell. `S` in a cell = the answer is secret.
5. `/dp brand`. The chat says your Demonic Brand rank (or that it isn't found).

## Tests

**Range (R1–R5)**

- **T1 – out of combat, open world.** `/dp mark T1`. Target a mob about 40 yd away, walk slowly towards it until you are in melee range, then back out. Watch the squares change around 30 yd (Corruption) and 20 yd (Fear, Death Coil). Then `/dp range once`.
- **T2 – in combat, target.** `/dp mark T2`. Pull a mob with Corruption, then walk away and back again (or Fear it and let it run). Then `/dp range once` while still in combat.
- **T3 – in combat, nameplates.** `/dp mark T3`. Fight 2–3 mobs with plates. Keep one as target, the others move around. Do the nameplate rows change too?
- **T4 – line of sight.** `/dp mark T4`. In range of a mob, step behind a wall or pillar. Does the square stay green? Try to cast Corruption once (the error message is logged).
- **T5 – dungeon (optional).** `/dp mark T5`. A few pulls in a dungeon: do the rows still work there (hidden names)?

**Demonic Brand (B1–B7)** – needs the talent and a pet out

- **T6 – Imp.** `/dp mark T6 imp`. On one mob: Searing Pain, then let the Imp attack for 10 s without casting other fire or shadow spells (no Immolate, no Corruption; a wand is fine). A line at the top left shows "Brand #n: … hits on it … aura removed …". Do this 3 times (new mob or wait 10 s each).
- **T7 – Imp with DoTs.** `/dp mark T7`. Normal rotation with Searing Pain in between (to see if our own ticks mix in).
- **T8 – melee pet.** Summon the Voidwalker (or Felhunter / Succubus). `/dp mark T8 voidwalker`. Repeat T6 3 times.
- **T9 – end of combat.** After a fight with Searing Pain: `/dp brand scan` right after combat ends.

## Finish

1. `/dp range off`, `/dp stop`, `/reload`.
2. Tell me when the file is written (`WTF\Account\...\SavedVariables\DotProbe.lua`); I read it myself.
3. Please also note: your Demonic Brand rank, which pets you used, anything odd you saw in the grid.

## What the log lines mean

| Tag | Content |
|---|---|
| `RANGE` | a range answer changed: unit, spell, API, old → new, the unit's GUID |
| `RANGE1` | one-shot of every range API, the spell's stated range, which secret-boolean APIs exist |
| `RANGEBOOL` | how a secret range answer was drawn (`SetAlphaFromBoolean ok` / ERR / missing) |
| `RANGEEV` | `SPELL_RANGE_CHECK_UPDATE` events, if the game sends them |
| `BTALENT` | talent rows (row 4 of every tree), brand and Searing Pain tooltips, pet family |
| `BRAND` | a Searing Pain cast: enemy GUID, pet |
| `BREAD` | aura reads on target / pet / player at +0.05, 0.5, 2, 5, 9, 10.5, 12 s |
| `BHIT` | every `UNIT_COMBAT` on the branded enemy for 13 s: time, action, school |
| `BAURA` | `UNIT_AURA` on the branded enemy, the pet and you: added / updated / removed |
| `BPET` | pet casts during the brand window |
| `BOWN` | your own casts during the brand window (to tell their hits apart) |
| `BSCAN` | full aura scans (`/dp brand scan`, and after each fight with a brand) |
