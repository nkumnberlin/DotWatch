# AGENTS.md – DotWatch

Working guide for coding agents on this repo. **DotWatch** is a DoT and crowd-control timer addon for **World of Warcraft: Forever** (client 1.60.x); **DotProbe** (`DotProbe/`) is its logging-only diagnostic addon. The maintainer is Nico.

Read this file first. If a local `wow-forever-knowledge-base.md` exists in the repo root, read it too: it holds the environment paths, the current project state and the open TODO list. It is untracked on purpose (see [Local working notes](#local-working-notes)).

---

## 1. Hard rules

1. **Never write Blizzard globals or Blizzard tables**, not even `X = X or {}`. No `StaticPopupDialogs[...]`, no `tinsert(UISpecialFrames, ...)`. It taints Blizzard code and gets protected calls blamed on DotWatch.
2. **Never compare, do math on, or store secret values.** Hand them to game widgets (`SetText`, `StatusBar:SetMinMaxValues/SetValue`, `SetTimerDuration`) and let the game draw or compare them.
3. **Never read the geometry of anything that has ever shown a secret value** (`GetStringWidth`, `GetPoint`, `GetCenter`, `GetLeft` …). It stays secret afterwards, also for pooled/reused widgets. Anchor instead; keep positions in your own numbers.
4. **No combat log.** Registering `COMBAT_LOG_EVENT_UNFILTERED` triggers ADDON_ACTION_FORBIDDEN. Build on your own casts and on unit events.
5. **Probe before you build.** When it's unclear what Forever allows, write a DotProbe test (logging addon + test plan), let Nico run it, read the SavedVariables log, then decide.
6. **Wrap risky UI/API calls in `pcall`** (settings registration, reading plate fields, drawing). Cap repeated error logs.
7. **Lua 5.1, max 200 locals per chunk.** `DotWatch.lua` is close to the limit: put new code into namespaced tables (`CORE`, `LOOK`, `TRACK` …) or new files, not new top-level locals.
8. **Only Forever data for game facts** (spells, durations, talents). Retail/Midnight docs only for API comparison.
9. **Release only what Nico tested in game and explicitly OK'd**, and only the newest approved version.
10. **Before deleting anything:** list exactly which files/folders would go and wait for Nico's OK.
11. **Keep the TODO list current:** when a feature, decision or test result changes, update the open-features list in the local knowledge base.
12. **Classic Blizzard look**, game textures and icons only, nothing AI-generated.
13. **Class-neutral:** DotWatch serves every DoT class. No class-only comfort features (shard counters, proc alerts, curse reminders).

Docs and code comments are in **English**. Reply to Nico in the language he writes in (German or English, often dictated, so expect typos – "VOV" = WoW).

---

## 2. WoW Forever API: what addons can and can't do

Forever uses the modern (Mainline/"Midnight") UI architecture and its addon restrictions, including **secret values**. WeakAuras is not maintained for it → standalone addons.

### Readable in combat
- **Own casts:** `UNIT_SPELLCAST_SENT` (target *name*), `_START/_STOP/_SUCCEEDED/_FAILED`, `_CHANNEL_START/_STOP`; spellID and castGUID.
- **GUIDs** of target, mouseover, focus, nameplates – **in the open world**. Same-named mobs can be told apart.
- `UnitIsDead`, `UnitExists`, `UnitIsUnit("target","nameplateN")`, `C_NamePlate.GetNamePlateForUnit("target").namePlateUnitToken`.
- `NAME_PLATE_UNIT_ADDED/REMOVED` tokens (reliable; plates flicker in/out with range/LoS).
- **`UNIT_COMBAT`:** unit, action (WOUND/MISS/RESIST/IMMUNE/EVADE/DODGE/PARRY/HEAL), flags, school. **Amount is secret, source isn't given.**
- **`UNIT_AURA` payload:** empty lists readable, non-empty lists secret → you can tell *that* something was `added`/`updated`, not what.
- Spell tooltips, spellbook (`C_SpellBook`, `C_Spell.GetSpellName(id)`), talents (`GetTalentInfo`).

### Secret (can be drawn, not read)
- Enemy **health** (`UnitHealth`), HP %, `UNIT_COMBAT` amounts, **cooldowns** in combat.
- **In instances:** enemy **names and GUIDs** (even out of combat), and SENT's destName.
- Geometry of widgets that displayed secrets (rule 3).

### Blocked
- Combat log (`IsCombatLogRestricted = true`).
- **Aura reading in combat:** `GetUnitAuras`, `GetAuraDataByIndex`, `GetAuraSlots`, `AuraUtil.ForEachAura` → "Auras cannot be accessed when secret while tainted". Out of combat everything is readable (duration, auraInstanceID, sourceUnit, DurationObject).
- Nameplate **CVars** in combat (`ADDON_ACTION_BLOCKED`); out of combat settable. `plate:SetAlpha(0)` works in and out of combat.
- **Secure code can't see nameplate units:** not as a button `unit`, not as a macro argument (`/target nameplateN`), not in conditionals (`[@nameplateN,exists]` is false). → **No click-to-cast/target from addon rows.**
- `SetPropagateKeyboardInput` in combat; moving/showing secure buttons in combat.

### What works for "act on a non-target mob"
- `[@mouseover,harm,nodead]` is true in combat while hovering the **real mob or its nameplate**. A keybind macro `/cast [@mouseover,harm,nodead] <spell>` is the allowed path; DotWatch marks plates (letters, missing-DoT status) so the plate becomes the hover surface.

---

## 3. Proven techniques

**Cast-driven DoT timers** (no aura reading)
1. `UNIT_SPELLCAST_SENT`: take the target name → resolve the GUID via target/mouseover/focus/nameplates (target wins for same names).
2. `UNIT_SPELLCAST_SUCCEEDED`: start the timer from `GetTime()` + duration. Late SENT → use the SUCCEEDED time; no SENT within 0.15 s → current target.
3. Duration: parse the spell tooltip ("over 18 sec", "up to 20 sec", "for 2 min"; mind non-breaking spaces), fallback table, refine with durations learned from real auras **out of combat**. Never learn CC durations (diminishing returns shorten them).

**Resist/immune detection – same-frame rule**
- A failed DoT always gets `UNIT_COMBAT` MISS/RESIST/IMMUNE/EVADE on that GUID **in the same frame** as SUCCEEDED (≤ 0.02 s) and **no** `UNIT_AURA added`. Forever reports shadow resists as **MISS**; the school field is always 1 there.
- Pet melee misses arrive later (+0.2 s or more) → a wider window gives false resists.
- `added` in the same frame = reliable "landed". `updated` is ambiguous → not a refresh proof.
- On a failed refresh, restore the old timer. Store immunities per NPC ID + spell, but not while Banish-type CC makes the mob immune.

**Liveness signals**
- Ticks: `UNIT_COMBAT WOUND` with the DoT's school (32 shadow, 4 fire) → "lost?" if no tick for 1.5 × tick + 1 s while a unit token exists. Not source-attributed.
- Death: `UnitIsDead` + nameplate REMOVED with dead = true.
- Out-of-combat sync: read real debuffs after combat to correct end times and drop gone DoTs.

**Instances (hidden names/GUIDs)**
- `keyOf(unit)` = GUID if readable, else `Plate-N` (from NAME_PLATE_UNIT_ADDED until REMOVED), else `Target-N` for a plate-less target.
- 0.20.4: keys also stick to **anchor tokens** (`target`, `focus`, `pettarget`, `party1-4target`, `boss1-5`). `UnitIsUnit` compares them with plates although names/GUIDs are secret, so an enemy keeps its key across target switches, plate flicker and out-of-plate-range casts while any anchor still points at it; a returning plate inherits the key. Clear an anchor on its change event (PLAYER_TARGET_CHANGED, PLAYER_FOCUS_CHANGED, UNIT_TARGET, UNIT_PET, GROUP_ROSTER_UPDATE, INSTANCE_ENCOUNTER_ENGAGE_UNIT). Never merge two keys on a mismatch (a late change event would join two enemies). Party/pet targets get no unit events, so they don't count for "lost?".
- Hidden SENT name: the cast went to the first hostile, living unit of target → mouseover → focus → targettarget (a healer with a friendly target casts via macro).
- Enemy nameplates off (client default, V key) = dungeon tracking only via anchors; DotWatch says so once per session in an instance. Options › General › "Game nameplates" sets `nameplateShowEnemies` = 1 and `nameplateMaxDistance` = 60 (off by default, out of combat only, queued until PLAYER_REGEN_ENABLED, old value restored on untick if unchanged since; `CVAR` debug lines).
- Draw the secret name with `fs:SetText(UnitName(unit))`; anchor the next element to the name's right edge (never read its width).

**Comparing secret values without reading them** (the kill skull used this from 0.15 until it was removed in 0.21; idea from DoesItDie / Smooth Animated Bars, MIT)
- Hidden StatusBar: range = secret health, value = our plain remaining DoT damage (from tooltips). An icon rides the fill edge of a 10,000 px bar inside an icon-sized clip frame → visible only when damage ≥ health. The game does the comparison.
- Health bars: feed `UnitHealth`/`UnitHealthMax` straight into a StatusBar.

**Guessing events the client hides** (heuristics, always confirm later)
- Freezing Trap: first enemy with a new `UNIT_AURA added` (skip mobs we just cast on, 0.3 s).
- Fire traps: first enemy taking fire damage (WOUND school 4); Explosive also catches others hit within 0.5 s.
- Devouring Contagion (plague jumps on death): candidates = enemies with an aura change 0.6 s before to 1.0 s after the death, max 2; the jumped plague keeps the time that was left; confirm by the next shadow tick, drop silently after 6 s in view without one.

**Window handling with secrets**
- Position as your own numbers: `db.pos = {point, "BOTTOMLEFT", x, y}` in the window's scale; drag via `GetCursorPosition` (StartMoving breaks once the frame shows secret text).
- Tooltips: owner `UIParent`, anchored at the cursor.
- Escape: the window handles it itself (`EnableKeyboard` + `OnKeyDown`, `SetPropagateKeyboardInput(true)` for other keys). In combat let all keys through; re-enable on `PLAYER_REGEN_ENABLED`.
- Confirmations inline in our own window, not StaticPopup.

**Talents and pets (DotProbe 0.7)**
- The classic talent API (`GetNumTalentTabs`, `GetTalentInfo`) is missing on Forever. Check a talent with `IsPlayerSpell(<talent spell ID>)`. A talent spell's tooltip (`C_Spell.GetSpellDescription`) may show another rank's numbers.
- Pet casts are readable: `UNIT_SPELLCAST_START/SUCCEEDED` for `pet` with spell ID.
- Demonic Brand is a debuff on the enemy (`UNIT_AURA added` in Searing Pain's SUCCEEDED frame), not readable in combat. Each empowered pet attack = a fire/shadow `UNIT_COMBAT` hit + `UNIT_AURA updated` on that enemy in the same frame (the Imp's Firebolt hits twice, one update).
- `C_Spell.IsSpellInRange(id, unit)` is plain (1/0/nil) in combat, also for nameplates (open world); it ignores line of sight.

**Other**
- Spellbook rescans requested in combat (`SPELLS_CHANGED`) → run after combat ends.
- AddOns settings entry: `Settings.RegisterCanvasLayoutCategory` + `Settings.RegisterAddOnCategory` at PLAYER_LOGIN, fallback `InterfaceOptions_AddCategory`, all in `pcall`; a small panel with a button that opens our own window (DIALOG strata).
- Read plate fields (e.g. `plate.UnitFrame.healthBar`) read-only and in `pcall`.
- Text on light bar colors: black outline when brightness > 0.6.
- Sounds: look up by SOUNDKIT name with a classic ID fallback; offer a Test button.

### Proven impossible or not worth it (don't re-propose without new evidence)
- Click a list row to target/cast on that mob (tested twice in DotProbe).
- A target bar of secure buttons (only ever hits the current target; removed in 0.9).
- An exact "HP left after DoTs" number (the kill skull was the allowed version; Nico dropped it in 0.21).
- Tracking procs (poisons, Ignite, Deep Wounds) from casts; timers for channels.
- Seeing CC breaks in combat (only a guess possible).

---

## 4. Codebase conventions

- Files: `DotWatch.toc`, `DotWatch.lua` (main file, near the 200-locals limit), `Strings.lua` + `Strings_<lang>.lua` (UI text), `Locale.lua` + `Locale_<lang>.lua` (tooltip parsing), `.pkgmeta`, `.github/workflows/tag-release.yml`, `LICENSE`, `README.md`, `DotProbe/` (not packaged).
- TOC load order: Strings → Locale → DotWatch.lua.
- Namespaced feature tables: `CORE` (addon table `CORE.ns`, tooltip durations), `LOOK` (forward-declared, also the resist flash `LOOK.*Glow*`), `TRACK`, `SPELLS`, `CLASS_SLOTS`, `CLASS_SAMPLE`.
- Spell entries: `id` (rank-1 Forever ID), English `name` as the **saved key**, `loc` = client name, `class`, flags (`cc`, `calm`, `invuln`, `track = false`, group names like `sting`/`poly`). `rebuildDefs()` builds `DEF_BY_NAME`/`SLOT_ORDER` for the player's class only.
- Rendering through "canvases": the live window and the options preview share `drawCanvas`/`updateCanvas`; `drawCanvas` runs in `pcall`.
- SavedVariables `DotWatchDB`: settings, `stats[npcID]`, `immune`, `track`, `untracked`, `debug` (last 600 lines) + `debugPrev`.
- Debug log tags: SPELLBOOK, SENT, IGNORE, START, COMBAT, KEEP, FAIL, EXPIRED, REMOVE, SYNC, LEARNED, HP, LOST?, UNTRACKED, TALENT, CONTAGION, BRAND, RANGE, SIGHT, DRAW ERROR, SETTINGS.
- Slash commands: `/dw <cmd>` (`/dp` for DotProbe); every command gets a `help` line.
- Checks before a commit: compile every file with Lua 5.1 / LuaJIT (`loadstring` also catches the locals limit); logic can be mocked with Python + `lupa`.

---

## 5. UI and design

- **Classic Blizzard dialog look** (like Attune / AutoBiographer): dark marble background on a solid base, gold dialog border, gold titles, red buttons, navigation list on the left. Not the modern flat look.
- Game textures and icons only (e.g. `Spell_Shadow_EvilEye` minimap eye, `UI-TargetingFrame-Skull`).
- Every option that changes visuals gets a **live preview**.
- Options window: 700 × 520, navigation pages (General · Display · Look · Bars and time · Timers · Tracked spells · Enemies · Statistics), buttons Test · Reset position · Close.
- The unlocked state must look obviously different (gold edge + "Move mode" tab with a Lock button).
- Labels must fit in every language (shorten, full name in a tooltip).

---

## 6. Git, install and release workflow

1. Day-to-day: bump `## Version:` in `DotWatch.toc` → install into Nico's Forever AddOns folder (path in the local knowledge base) → commit + push to `main`. No release. Nico wants addons installed for him, not files to copy by hand.
2. **Experimental features** (anything built on a guess, e.g. Devouring Plague jumps) ship in a normal release **switched off** (`db.<flag> == true` only after the player ticks it) and labeled "(experimental)" in the options and README. Testers turn them on and get updates through CurseForge, no zips. Bigger test versions may still go on their own branch (e.g. `priest-0.20`) until Nico OKs the merge.
3. Nico tests in game and says OK ("release it").
4. `git push origin main:release` → `tag-release.yml` reads the TOC version and creates tag `v<version>` (once per version; also `workflow_dispatch`).
5. CurseForge (Automatic Packaging = tagged commits) builds the zip from the tag. `-beta`/`-alpha` in the tag → beta/alpha file. `.pkgmeta` packages one `DotWatch` folder without DotProbe and the repo docs.
6. Never zip releases by hand. Release only the newest approved version.
7. Update README / CurseForge text when features ship.
8. The game loads new addon files only on `/reload` or login (new files in the TOC need a restart); SavedVariables are written only on `/reload` or logout.
9. The CurseForge app on Nico's PC can overwrite a dev install with the released version. Check the installed version after app updates.
10. Commit identity: GitHub username + `nkumnberlin@users.noreply.github.com`, no personal email.

---

## 7. Localization

- Languages: English, German, Russian, Simplified + Traditional Chinese.
- Match spells **by spell ID** (`C_Spell.GetSpellName(id)`), keep the English name as the saved key so old SavedVariables keep working. Log IDs that return no name.
- Tooltip parsing per language in `Locale_*.lua` (derived from Smooth Animated Bars ← DoesItDie, MIT – keep the notices). German patterns are Classic Era wording, unverified on Forever.
- UI strings: `ns.L` with English fallback, keyed by the English text; language frozen at ADDON_LOADED (switch needs `/reload`); `/dw lang <auto|en|de|ru|zhCN|zhTW>`; English hint if the chosen language's glyphs aren't readable on the client.
- Before shipping: same keys in every language, every key used, `%s/%d/%02d/%%` and `|c…|r` identical and in order.
- Don't convert zhCN → zhTW mechanically; Taiwan terms: 名條, 悄悄話, 準備確認, 「」.
- Russian and Chinese still need a native speaker's check.

---

## 8. Testing

- **DotProbe** pattern: numbered questions (F1…) → test steps (T1…) with `/dp mark T<n> note` → `/dp stop` + `/reload` → read `DotProbe.lua` SavedVariables → results with a "consequences" section. Keep the log capped; drop noise.
- ADDON_ACTION_FORBIDDEN/BLOCKED in chat = taint.
- BugSack errors persist across sessions with a counter; compare `session`/`time` against install times before treating an error as current.
- Every release candidate gets an explicit "to test in game" checklist for Nico.
- Testers: ask them to `/reload` or log out and send their `DotWatch.lua` SavedVariables right away.

---

## 9. Class spell data (Forever, max-rank durations)

Source: WoW Forever Tools "Spells by Level" (wowforevertools.vercel.app, data from foreverchanges.pro) and its talents data.

| Class | DoTs (fixed rows) | CC / control (shown while active) |
|---|---|---|
| Warlock | Corruption 18 s, Immolate 15 s, Siphon Life 30 s, Bane of Agony 24 s (back-loaded ticks 0.5×/1×/1.5×) | Fear 20 s, Banish 30 s, Subjugate Demon (= Enslave, ID 1098), Death Coil 3 s, curses; Demonic Brand 10 s (Demonology talent 1293695, from Searing Pain; rank 3 = pet's next 6 attacks) |
| Priest | SW:Pain 18 s, Devouring Plague 24 s, Holy Fire 10 s | Shackle Undead 50 s, Chastise 2 s, Silence 5 s, Mind Soothe 15 s |
| Druid | Moonfire 12 s, Insect Swarm 12 s, Rake 9 s, Lacerate 15 s | Entangling Roots 27 s, Hibernate 40 s, Bash 4 s, Pounce 2 s, Feral Charge |
| Hunter | Serpent 15 s / Viper 8 s Sting, Lacerate 21 s, Immolation/Explosive Trap | Freezing Trap 20 s, Scare Beast 20 s, Scatter Shot 4 s, Counterattack 5 s |
| Rogue | Garrote 18 s | Sap 45 s, Blind 10 s, Gouge 4 s, Cheap Shot 4 s |
| Shaman | Flame Shock 12 s | – |
| Warrior | Rend 21 s | Intimidating Shout 8 s, Concussion Blow 5 s, Intercept 3 s |
| Mage | burns: Fireball 8 s, Pyroblast 12 s, Frostfire Bolt 9 s | Polymorph (+Cow) 50 s |
| Paladin | – | Hammer of Justice 6 s, Repentance 6 s, Turn Undead 20 s |

Not in Forever: Unstable Affliction, Shadowfury, Vampiric Touch. Tick intervals: 3 s (Corruption, Immolate, Siphon Life), 2 s (Agony).
"Calm" CC (no red blink): Banish, Subjugate Demon, Polymorph, Sap, Blind, Hibernate, Shackle Undead, Freezing Trap, Repentance. Fear still blinks.

---

## 10. References

- **DoesItDie** (Joe Greive, MIT) and **Smooth Animated Bars** (Jordan, MIT): the Forever-safe kill check and localized tooltip parsers.
- **CCTrack for WoW: Forever**: competitor (CC bars, English names only, no traps).
- Classic-era inspiration: DoTimer, Ellipsis, NugRunning, EventHorizon, CCWatch, DotPlates.
- API: warcraft.wiki.gg patch notes for Forever 1.60.1 and Midnight 12.0.5 (secrets, DurationObject, `StatusBar:SetTimerDuration`, `C_UnitAuras.GetAuraDuration`).
- Game data: wowforevertools.vercel.app, foreverchanges.pro, Wowhead Forever data.

---

## Local working notes

`wow-forever-knowledge-base.md` in the repo root is Nico's full knowledge base: environment and paths, SavedVariables location, project state, decisions and the open TODO list. It is listed in `.gitignore` and must **never be committed or uploaded**. Keep it current locally; when a lesson is durable and not personal, also add it here.
