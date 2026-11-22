# DotProbe 0.7 – results (2026-11-22)

Run by Nico (warlock, open world, client 1.60.1 build 71037), 3,734 log lines. Marks T1–T4, T6 (Imp), T9. T7 started with the Imp; the Imp died, so the rest of T7 and all of T8 ran with the **Succubus** (no own marks). T5 (dungeon) was skipped. 24 Searing Pain casts: 3 with the Imp, 21 with the Succubus.

## Range (R1–R5)

| # | Result |
|---|---|
| R1 | `C_Spell.IsSpellInRange(id, unit)` answers **plain** `1` / `0` / `nil`, also **in combat** (163 changes in combat, never secret). `C_ActionBar.IsActionInRange(slot, unit)` gives the same answers (needs the spell on a bar). Old `IsActionInRange(slot)`: target only. Old `IsSpellInRange(name, unit)`: missing. |
| R2 | Works on **nameplate units** and mouseover in combat, per enemy (87 nameplate changes in combat, matching each plate's own GUID). |
| R3 | Not needed: no answer was secret. `SetAlphaFromBoolean`, `SetVertexColorFromBoolean`, `C_CurveUtil.EvaluateColorFromBoolean`, `C_Spell.EnableSpellRangeCheck` exist (fallback for dungeons). |
| R4 | The answers follow the spell's range (Corruption 30 yd, Fear 20 yd, Death Coil 30 yd on Forever). **Line of sight is ignored**: behind a pillar the answer stayed `1` while every cast failed with `UI_ERROR_MESSAGE` 57 "Target not in line of sight" (+ `UNIT_SPELLCAST_FAILED`). Out of range gives error 402 "Out of range." |
| R5 | `CheckInteractDistance(unit, 1–4)` answered plain in combat (no BLOCKED). `UnitInRange` = secret. `UnitDistanceSquared` = 0 (useless). `SPELL_RANGE_CHECK_UPDATE` fires, target only. |

## Demonic Brand (B1–B7)

| # | Result |
|---|---|
| B1 | **The classic talent API is missing on Forever** (`GetNumTalentTabs` / `GetNumTalents` / `GetTalentInfo`). `IsPlayerSpell(1293695)` = true works as talent check. The tooltip of 1293695 says "next **3** attacks", but that is not the learned rank: Nico's in-game talent tooltip (Rank 3/3) says "Your pet's next **6** attacks against the target deal 115 to 119 Fire or Shadow damage" (screenshot, 2026-11-22). So the charges depend on the rank and the rank spells have other IDs. Searing Pain rank used: 17923. |
| B2 | A **debuff on the enemy**: `UNIT_AURA added` on the target in the same frame as Searing Pain's SUCCEEDED, 24 of 24 casts. Nothing on the pet. |
| B3 | Not readable in combat: `GetAuraDataByIndex` → "Auras cannot be accessed when secret while tainted" (target, pet and player). `GetAuraDataBySpellName` → nil. `GetUnitAuraBySpellID` and `GetAuraApplicationDisplayCount` exist but need the debuff's spell ID / instance ID (unknown, secret). Out of combat the brand was never on a living enemy, so its own spell ID is still unknown. |
| B4 | Each empowered pet attack is its own `UNIT_COMBAT WOUND` on the branded enemy **plus `UNIT_AURA updated` in the same frame**. Imp: every Firebolt during the brand hits **twice** (fire, 0.03–0.1 s apart), after the brand only once. Succubus: an extra shadow hit (school 32) with the update, about every 2 s, apart from her physical melee (school 1). |
| B5 | Pet casts are **readable**: `UNIT_SPELLCAST_START/SUCCEEDED` for `pet` with spell ID (Firebolt 11762, Lash of Pain 11780, Soothing Kiss 11784, Phase Shift 4511). |
| B6 | With **6 charges** (rank 3) the pet rarely uses them all in 10 s: Imp 4 Firebolts, Succubus 5 hits, then the brand ran out at 9.8–10.1 s. One window (#8) had 6 updates and the brand went away at 9.7 s together with the next pet hit – maybe the charges ran out, but an older DoT on that enemy can have caused one of the updates. Early end by charges: likely, not proven. |
| B7 | Imp: fire bonus (double Firebolt). Succubus: shadow bonus. Same 10 s window. |

## Consequences for DotWatch

1. **#20 range dimming can be built without guessing**: per row `C_Spell.IsSpellInRange(row spell ID, m.unit)`, polled with the 0.2 s ticker; `0` = dim the row, `nil` (no unit token / no range) = leave it. Keep `SetAlphaFromBoolean` as the path for a secret answer (dungeons, not tested).
2. **"Out of sight"** has no API: mark the enemy for a few seconds after `UNIT_SPELLCAST_FAILED` + `UI_ERROR_MESSAGE` with the game's own `SPELL_FAILED_LINE_OF_SIGHT` text, clear it on the next successful cast.
3. **Demonic Brand as a normal 10 s timer** (reliable: cast + `added` in the same frame, refresh on recast). Talent check by `IsPlayerSpell(1293695)`.
4. **Charges left: possible as an experimental counter** (corrected after Nico's rank 3/3 tooltip: 6 attacks). Start value from the learned rank's tooltip ("next (%d+) attacks"; find the rank spell by name with `IsPlayerSpell` near ID 1293695, fallback 6). One charge per `UNIT_AURA updated` on the branded enemy in the same frame as a fire/shadow `UNIT_COMBAT` hit (the Imp's double hit = one update = one charge), skipping our own DoT tick times and cast landings. End at 0 or after 10 s. Off by default until it matches in game.
5. **Side finding, talents**: DotWatch's Devouring Contagion check uses `GetTalentInfo`, which is missing → always "unknown". Switch to `IsPlayerSpell(<talent spell ID>)`.
6. **Side finding, pets**: pet casts with spell ID are readable → #9 pet spells (Seduction, Spell Lock, pet stuns) is possible from `UNIT_SPELLCAST_SUCCEEDED` on `pet` + `pettarget` as the enemy.
