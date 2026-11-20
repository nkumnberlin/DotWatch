# DotProbe 0.6 – targeting and re-dotting test plan

0.5 settled it: a list row can't target or cast on a nameplate mob. 0.6 checks what is left for "DoT a mob that is not my target" and whether DotWatch books those casts on the right enemy.

Everything here is temporary. Key bindings from `/dp bind` disappear on `/reload`. `/dp soft off` restores the action-targeting setting. Nothing touches your saved key bindings or macros.

## Questions

| # | Question | Why it matters |
|---|---|---|
| F1 | Does a mouseover key put a DoT on a non-target mob in combat (mob model and nameplate, open world and dungeon)? | The real replacement for "click a row". |
| F2 | Does DotWatch book a mouseover DoT on the right enemy? Open world with same-named mobs, dungeon with hidden names. | Suspected DotWatch bug: with a hidden or duplicate name the *target* wins, even when the cast went to the mouseover. |
| F3 | Can addon code tell in advance which unit its own key button will hit (PreClick + the macro conditional)? | If yes, DotWatch could ship its own "DoT on mouseover" key bindings with exact booking. |
| F4 | Does "set focus on mouseover" work in combat, and do a focus key and a clickable focus row work? | One clickable row for a second mob. |
| F5 | Action targeting: does `softenemy` exist, is it hostile for macros, which plate is it, and does `[@softenemy]` cast there? | Hit the mob you look at, no target switch. |
| F6 | Which fixed units exist and can be clicked: `targettarget`, `pettarget`, `party1-4target`, `boss1-5`? | Fixed clickable rows ("tank's target", boss rows). |
| F7 | Nameplate rows **out of** combat: does a click target or cast? | Closes the last gap from 0.5. Expected: no. |
| F8 | Hovering DotWatch's plate letters and mini bars: does the plate still count as mouseover? | The plate is the hover surface; our drawings must not get in the way. |

## Before you start

1. `/reload`, check the chat says **DotProbe: 0.6 loaded**.
2. DotWatch on, enemy nameplates on (as usual).
3. `/dp clear` then `/dp start 0.6`.
4. `/dp keys Corruption` (out of combat): builds the test key buttons.
5. Bind them (out of combat; pick free keys, examples):
   - `/dp bind mo F` – Corruption on the mouseover, else the target
   - `/dp bind setfocus G` – focus on the mouseover
   - `/dp bind focus H` – Corruption on the focus, else the target
   - `/dp bind soft J` – Corruption on the soft target, else the target (only for T7)

Every DoT cast on an enemy prints a **WHO** line in chat:
`WHO Corruption: hit mouseover (added) | DotWatch via target -> MISMATCH | key mo predicted mouseover -> OK`
- *hit* = where the game put the debuff (or MISS/RESIST) in the same frame
- *DotWatch via* = where DotWatch booked it; **red MISMATCH = DotWatch bug**
- *key … predicted* = what the addon knew before the cast

Put a mark before each step: `/dp mark T1 open world plain macro`.

## Steps

**T1 – plain macro, no addon (F1).** Make a normal macro `/cast [@mouseover,harm,nodead] Corruption` on a key. In combat: target mob A, hover mob B's **model**, press. Then hover B's **nameplate**, press. Check B's debuff on its plate or in DotWatch.

**T2 – DotProbe key (F1, F3).** Same as T1 with the `mo` key (F). Chat should show `key mo predicted mouseover -> OK`. Also press once while hovering nothing (should hit the target).

**T3 – same-named mobs, open world (F2).** Find 2–3 mobs with the same name (e.g. a camp of identical mobs). Target A, mouseover B, press F. Watch the WHO line and DotWatch's rows: on which row did the timer start?

**T4 – dungeon (F1, F2).** Repeat T2 + T3 in a dungeon:
- a) enemy nameplates on
- b) enemy nameplates off (V): mouseover the model only

**T5 – hover HUD (F8).** `/dp hover`. Hover in turn, with a mark each: the mob model, its nameplate bar, the DotWatch letter on the plate, the DotWatch mini bars under/over the plate, the DotWatch list window. The HUD at the cursor says what the game counts as mouseover. `/dp hover off` afterwards.

**T6 – focus (F4).** `/dp rows Corruption` (out of combat) shows a panel of fixed units. In combat: hover mob B, press G (set focus): chat prints the setfocus result and a **focus** row appears. Then:
- press H (Corruption on focus) while targeting A
- left-click the focus row (target it?)
- right-click the focus row (Corruption on it?)
Chat prints `row focus LEFT … -> OK/BAD` and the WHO line for the cast.

**T7 – action targeting (F5).** Out of combat: `/dp soft on`, `/dp units`. In combat: keep target A, *look* at mob B (face it, cursor anywhere). Does the unit panel show `softenemy H nameplateN`? Press J. Afterwards, out of combat: **`/dp soft off`** (restores your setting).

**T8 – fixed units (F6).** With `/dp units` and `/dp rows` on, whichever you can do:
- your pet attacks another mob (`pettarget`)
- in a group: the tank targets a mob (`party1target` …)
- dungeon boss fight (`boss1`)
- target a mob that targets someone (`targettarget`)

Left/right-click the rows that appear, in combat.

**T9 – nameplate rows out of combat (F7).** Out of combat with a few mobs in view: `/dp rows np`. Left-click and right-click rows 1–5.

## At the end

1. `/dp who stats`
2. `/dp stop`
3. `/dp soft off` (if you used T7) and `/dp unbind`
4. `/reload` – this writes `DotProbe.lua` and `DotWatch.lua` to SavedVariables. Tell Claude; the logs are read from your PC.

## What the results would mean

| Result | Consequence |
|---|---|
| F1 yes | Document mouseover macros (README / tooltip); the plate is the "row". |
| F2 MISMATCH | DotWatch fix: when mouseover and target are different hostile enemies, book the cast on whichever plate gets `UNIT_AURA added` (or MISS/RESIST) in the same frame instead of always the target. |
| F3 OK | Option: DotWatch's own key bindings ("DoT 1–4 on mouseover") with exact booking, class-neutral from the fixed slots. |
| F4 OK | Option: a clickable focus row in DotWatch (+ "set focus" binding). |
| F5 OK | Option: soft-target binding as an alternative to mouseover. |
| F6 OK | Option: clickable rows for the tank's target / boss units. |
| F7 no | Confirms 0.5, nothing more to try with nameplate rows. |
| F8 blocked | Make DotWatch's plate drawings smaller or move them off the plate's hover area. |
