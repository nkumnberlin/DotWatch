-- DotWatch 0.2: warlock DoT timers per enemy for WoW Forever.
--
-- How it works (based on the DotProbe test runs):
--  * Forever hides the combat log and blocks reading enemy debuffs in combat.
--  * So timers come from your own casts: UNIT_SPELLCAST_SENT gives the enemy
--    (matched to target/mouseover/focus to get its GUID), SUCCEEDED starts the
--    timer with the duration from the spell description.
--  * A resist/immune arrives as UNIT_COMBAT MISS/RESIST/IMMUNE on that enemy in
--    the same frame as SUCCEEDED. If no aura change arrived in that frame either,
--    the timer is cancelled (a failed refresh restores the old timer).
--  * Timers are removed when they run out, the enemy dies, or combat ends.
--  * Out of combat, real aura data is readable: used to learn exact durations.
--
-- New in 0.2:
--  * Reads your spellbook: every DoT you know gets a fixed row per enemy,
--    shown as a gray placeholder while it's not on that enemy.
--  * Known immunities show on the placeholder.
--  * A pet miss in the same frame no longer cancels a DoT that did land.
--  * Debug log in SavedVariables (/dw debug shows it live in chat).
--
-- New in 0.9: target bar removed (Forever only lets a click reach the current target).
-- New in 0.9.1: no StaticPopup / UISpecialFrames (they tainted Escape -> SpellStopCasting forbidden).
-- New in 0.8: refresh warning, tick marks, "DoT lost?", control timers, target bar like an
-- action bar + keybindings, Look page (font, texture, colors), growth direction,
-- out-of-combat fading, statistics and fight summary.
-- New in 0.7: target bar (click a DoT to cast/refresh it on your target), options
-- with a navigation list on the left.
-- New in 0.6: five display styles with a live preview in the options (Display tab).
-- New in 0.5: options window (/dw) and minimap button.
-- New in 0.4: HP % next to each enemy's name; casts whose SENT event comes late or
-- never are no longer lost.
-- New in 0.3: letter above each tracked enemy's nameplate (DoT icons optional: /dw platedots).
--
-- Commands: /dw help

local ADDON_NAME = ...
local VERSION = "0.11"

local issecret = issecretvalue or function() return false end
local db

---------------------------------------------------------------------------
-- Helpers (never compare or compute with secret values)
---------------------------------------------------------------------------
local function plain(f, ...)
  if type(f) ~= "function" then return nil end
  local ok, v = pcall(f, ...)
  if not ok or issecret(v) then return nil end
  return v
end

local function str(v)
  if issecret(v) or type(v) ~= "string" then return nil end
  return v
end

local function num(v)
  if issecret(v) or type(v) ~= "number" then return nil end
  return v
end

local function guidOf(unit) return str(plain(UnitGUID, unit)) end
local function nameOf(unit) return str(plain(UnitName, unit)) end

local function npcID(guid)
  local id = guid and guid:match("^%a+%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
  return id and tonumber(id)
end

local function short(guid) return guid and guid:sub(-6) or "?" end

local function say(msg) print("|cffb48cffDotWatch:|r " .. msg) end

local DEBUG_MAX = 600
local function dbg(msg)
  if not db then return end
  local line = string.format("%.3f %s %s", GetTime(), InCombatLockdown() and "C" or "-", msg)
  local l = db.debug
  l[#l + 1] = line
  if #l > DEBUG_MAX then table.remove(l, 1) end
  if db.debugChat then print("|cff888888DW " .. line .. "|r") end
end

---------------------------------------------------------------------------
-- Tracked spells
---------------------------------------------------------------------------
-- group = only one per warlock per target (a new one replaces the old one)
-- slot  = fixed row per enemy (gray placeholder while not active); nil = only shown when active
local SPELLS = {
  -- tick = seconds between damage ticks, school = 32 shadow / 4 fire (for "DoT lost?")
  { name = "Corruption",            dur = 18,  color = { 0.62, 0.30, 0.95 }, slot = "corruption", tick = 3, school = 32 },
  { name = "Immolate",              dur = 15,  color = { 1.00, 0.50, 0.10 }, slot = "immolate", tick = 3, school = 4 },
  { name = "Siphon Life",           dur = 30,  color = { 0.30, 0.85, 0.40 }, slot = "siphon", tick = 3, school = 32 },
  { name = "Unstable Affliction",   dur = 18,  color = { 0.45, 0.70, 1.00 }, slot = "ua", tick = 3, school = 32 },
  { name = "Bane of Agony",         dur = 24,  color = { 0.85, 0.75, 0.20 }, group = "bane", slot = "bane", tick = 2, school = 32 },
  { name = "Bane of Doom",          dur = 60,  color = { 0.70, 0.10, 0.10 }, group = "bane", slot = "bane" },
  { name = "Bane of Havoc",         dur = 300, color = { 0.80, 0.30, 0.30 }, group = "bane", slot = "bane" },
  { name = "Curse of Agony",        dur = 24,  color = { 0.85, 0.75, 0.20 }, group = "curse", slot = "bane", tick = 2, school = 32 },
  { name = "Curse of Doom",         dur = 60,  color = { 0.70, 0.10, 0.10 }, group = "curse", slot = "bane" },
  { name = "Curse of Weakness",     dur = 120, color = { 0.60, 0.60, 0.60 }, group = "curse" },
  { name = "Curse of Recklessness", dur = 120, color = { 0.80, 0.40, 0.40 }, group = "curse" },
  { name = "Curse of Tongues",      dur = 30,  color = { 0.50, 0.50, 0.90 }, group = "curse" },
  { name = "Curse of the Elements", dur = 300, color = { 0.40, 0.60, 0.90 }, group = "curse" },
  { name = "Curse of Shadow",       dur = 300, color = { 0.50, 0.30, 0.70 }, group = "curse" },
  { name = "Curse of Exhaustion",   dur = 12,  color = { 0.40, 0.70, 0.70 }, group = "curse" },
  -- crowd control: shown while active, like curses (option "Control timers")
  { name = "Fear",                  dur = 20,  color = { 0.75, 0.35, 0.95 }, cc = true },
  { name = "Banish",                dur = 30,  color = { 0.45, 0.85, 1.00 }, cc = true },
  { name = "Enslave Demon",         dur = 300, color = { 0.95, 0.55, 0.15 }, cc = true },
  { name = "Death Coil",            dur = 3,   color = { 0.55, 0.20, 0.65 }, cc = true },
}
local DEF_BY_NAME = {}
for _, s in ipairs(SPELLS) do DEF_BY_NAME[s.name] = s end
local SLOT_ORDER = { "corruption", "immolate", "siphon", "ua", "bane" }

local spellCache = {} -- spellID -> info table or false
local nameByID = {}   -- spellID -> name (from the spellbook, readable out of combat)
local known = {}      -- spell name -> spellID of the known spell
local bookMethod = "not scanned"

local function parseDuration(desc)
  if type(desc) ~= "string" then return nil end
  local n = desc:match("over (%d+) sec") or desc:match("up to (%d+) sec") or desc:match("for (%d+) sec")
  if n then return tonumber(n) end
  n = desc:match("over (%d+) min") or desc:match("up to (%d+) min") or desc:match("for (%d+) min")
  if n then return tonumber(n) * 60 end
  return nil
end

local function iconOf(id)
  return (C_Spell and C_Spell.GetSpellTexture and plain(C_Spell.GetSpellTexture, id))
    or (GetSpellTexture and plain(GetSpellTexture, id)) or 136197
end

local function spellInfo(id)
  id = num(id)
  if not id then return nil end
  local c = spellCache[id]
  if c ~= nil then return c or nil end
  local name = nameByID[id]
  if not name and C_Spell and C_Spell.GetSpellInfo then
    local info = plain(C_Spell.GetSpellInfo, id)
    if type(info) == "table" then name = str(info.name) end
  end
  if not name and GetSpellInfo then name = str(plain(GetSpellInfo, id)) end
  if not name then return nil end -- don't cache, try again later
  local def = DEF_BY_NAME[name]
  if not def then spellCache[id] = false return nil end
  if def.cc and db and db.trackCC == false then return nil end
  local descDur = C_Spell and C_Spell.GetSpellDescription
    and parseDuration(str(plain(C_Spell.GetSpellDescription, id)))
  local info = { id = id, name = name, def = def, group = def.group, slot = def.slot, color = def.color,
    icon = iconOf(id), descDur = descDur }
  spellCache[id] = info
  return info
end

local function durationOf(info)
  return (db.learned and db.learned[info.id]) or info.descDur or info.def.dur
end

---------------------------------------------------------------------------
-- Spellbook: which DoTs does this warlock know?
---------------------------------------------------------------------------
local function addKnown(name, id)
  name, id = str(name), num(id)
  if not name or not DEF_BY_NAME[name] then return end
  if id then nameByID[id] = name end
  known[name] = id or known[name] or true
end

local function scanModern()
  if not (C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines and C_SpellBook.GetSpellBookItemInfo
      and C_SpellBook.GetSpellBookSkillLineInfo) then return false end
  local bank = (Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player) or 0
  local future = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.FutureSpell
  local lines = num(plain(C_SpellBook.GetNumSpellBookSkillLines))
  if not lines or lines == 0 then return false end
  local any = false
  for l = 1, lines do
    local li = plain(C_SpellBook.GetSpellBookSkillLineInfo, l)
    local off = type(li) == "table" and num(li.itemIndexOffset)
    local cnt = type(li) == "table" and num(li.numSpellBookItems)
    if off and cnt then
      for i = off + 1, off + cnt do
        local it = plain(C_SpellBook.GetSpellBookItemInfo, i, bank)
        if type(it) == "table" then
          any = true
          local isFuture = future ~= nil and it.itemType == future
          if not isFuture and it.isPassive ~= true then addKnown(it.name, it.spellID or it.actionID) end
        end
      end
    end
  end
  return any
end

local function scanClassic()
  if not (GetNumSpellTabs and GetSpellTabInfo and GetSpellBookItemInfo and GetSpellBookItemName) then return false end
  local tabs = num(plain(GetNumSpellTabs))
  if not tabs or tabs == 0 then return false end
  local book = BOOKTYPE_SPELL or "spell"
  local any = false
  for t = 1, tabs do
    local ok, _, _, off, cnt = pcall(GetSpellTabInfo, t)
    off, cnt = ok and num(off), ok and num(cnt)
    if off and cnt then
      for i = off + 1, off + cnt do
        local ok2, kind, id = pcall(GetSpellBookItemInfo, i, book)
        if ok2 then
          any = true
          if str(kind) == "SPELL" then
            local ok3, name = pcall(GetSpellBookItemName, i, book)
            if ok3 then addKnown(name, id) end
          end
        end
      end
    end
  end
  return any
end

local function scanByName()
  if not (C_Spell and C_Spell.GetSpellInfo) then return false end
  for _, s in ipairs(SPELLS) do
    local info = plain(C_Spell.GetSpellInfo, s.name)
    local id = type(info) == "table" and num(info.spellID)
    if id then
      local isKnown = (IsPlayerSpell and plain(IsPlayerSpell, id)) or (IsSpellKnown and plain(IsSpellKnown, id))
      if isKnown or not (IsPlayerSpell or IsSpellKnown) then addKnown(s.name, id) end
    end
  end
  return true
end

local dirty = true
local function scanSpellbook(why)
  wipe(known)
  if scanModern() then bookMethod = "C_SpellBook"
  elseif scanClassic() then bookMethod = "classic spellbook"
  elseif scanByName() then bookMethod = "name lookup"
  else bookMethod = "none" end
  -- spells seen in casts count as known too (in case the book scan misses one)
  for name in pairs(db.castKnown or {}) do if not known[name] then known[name] = true end end
  local list = {}
  for _, s in ipairs(SPELLS) do
    if known[s.name] then list[#list + 1] = s.name .. "=" .. tostring(known[s.name]) end
  end
  dbg("SPELLBOOK (" .. (why or "?") .. ") via " .. bookMethod .. ": " .. (#list > 0 and table.concat(list, ", ") or "nothing"))
  dirty = true
end

-- the spell shown on a slot's placeholder: first known spell of that slot
local function slotSpell(slot)
  for _, s in ipairs(SPELLS) do
    if s.slot == slot and known[s.name] then return s, known[s.name] end
  end
  return nil
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
-- mobs[guid] = { guid, name, letter, created, mark, dots = { [spellID] = dot }, flash = { ... } }
-- dot = { info, start, expires, prev, prevGroup, confirmed }
local mobs = {}
local pending = {}     -- castGUID -> { info, guid, name }
local lastFail = {}    -- guid -> { t, action }
local lastAura = {}    -- guid -> t of the last aura added/updated
local SAME_FRAME = 0.02

local FAIL = { MISS = "Resisted", RESIST = "Resisted", IMMUNE = "Immune", EVADE = "Evaded" }

-- counters for the optional fight summary
local fight = { start = 0, casts = 0, resisted = 0, immune = 0, refreshes = 0, lost = 0 }

-- statistics per enemy type (NPC ID) and spell: c = casts, r = resisted, i = immune
local function stat(guid, mobName, spellName, field)
  if db.recordStats == false then return end
  local npc = npcID(guid)
  if not npc then return end
  local e = db.stats[npc] or { name = mobName, s = {} }
  db.stats[npc] = e
  if mobName then e.name = mobName end
  local sp = e.s[spellName] or { c = 0, r = 0, i = 0 }
  e.s[spellName] = sp
  sp[field] = sp[field] + 1
end

local function now() return GetTime() end

local function getMob(guid, name)
  local m = mobs[guid]
  if m then return m end
  local used = {}
  for _, o in pairs(mobs) do
    if o.name == name then used[o.letter] = true end
  end
  local letter = 1
  while used[letter] do letter = letter + 1 end
  m = { guid = guid, name = name or "?", letter = letter, created = now(), dots = {}, flash = {} }
  if not name and not guid:find("%-%d+%-") then m.hidden = true end -- dungeon: key by nameplate
  mobs[guid] = m
  dirty = true
  return m
end

local function removeMob(guid, why)
  local m = mobs[guid]
  if m then
    mobs[guid] = nil
    dirty = true
    dbg("REMOVE " .. m.name .. " [" .. short(guid) .. "]: " .. why)
  end
  lastFail[guid] = nil
  lastAura[guid] = nil
end

local function addFlash(m, text, r, g, b)
  m.flash[#m.flash + 1] = { text = text, r = r, g = g, b = b, expires = now() + 2.5 }
  dirty = true
end

---------------------------------------------------------------------------
-- Who is who (0.10). Outside instances: the GUID. In dungeons Forever hides
-- names and GUIDs from addons, but UnitIsUnit and the nameplate tokens stay
-- readable (DotProbe npmap test, 2026-11-17). So there an enemy is known by
-- its nameplate: one key per nameplate, from NAME_PLATE_UNIT_ADDED until
-- REMOVED. A target without a nameplate gets a key until the target changes.
---------------------------------------------------------------------------
local plateKey = {}   -- "nameplateN" -> key
local keySerial = 0
local targetKey       -- key of a target that has no nameplate
local function newKey(prefix)
  keySerial = keySerial + 1
  return prefix .. keySerial
end
local function plateOf(unit)
  if unit:sub(1, 9) == "nameplate" then return unit end
  if C_NamePlate and C_NamePlate.GetNamePlateForUnit then
    local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
    if ok and plate and not issecret(plate) then
      local tok = plate.namePlateUnitToken or (plate.UnitFrame and plate.UnitFrame.unit)
      if type(tok) == "string" and not issecret(tok) then return tok end
    end
  end
  for i = 1, 40 do
    local u = "nameplate" .. i
    if plain(UnitIsUnit, unit, u) == true then return u end
  end
end
local function keyOf(unit)
  if not unit then return nil end
  local g = guidOf(unit)
  if g then return g end
  if plain(UnitExists, unit) ~= true then return nil end
  local tok = plateOf(unit)
  if tok then
    local k = plateKey[tok]
    if not k then k = newKey("Plate-") plateKey[tok] = k end
    return k, tok
  end
  if unit == "target" then
    targetKey = targetKey or newKey("Target-")
    return targetKey
  end
end

---------------------------------------------------------------------------
-- Cast handling
---------------------------------------------------------------------------
local function resolveDest(destName)
  if issecret(destName) then
    -- dungeon: the target's name is hidden; the cast went to the target (or a macro target we can't see)
    local k = keyOf("target")
    if k and plain(UnitIsDead, "target") ~= true then return k, "target (hidden name)" end
    return nil, "hidden target name and no target"
  end
  destName = str(destName)
  if not destName or destName == "" then return nil, "no readable target name" end
  for _, u in ipairs({ "target", "mouseover", "focus" }) do
    if nameOf(u) == destName then
      local g = guidOf(u)
      if g then return g, u end
    end
  end
  for i = 1, 40 do
    local u = "nameplate" .. i
    if nameOf(u) == destName then
      local g = guidOf(u)
      if g then return g, u end
    end
  end
  return nil, "no unit named '" .. destName .. "'"
end

local function failDot(m, d, action)
  local id = d.info.id
  if m.dots[id] == d then
    m.dots[id] = d.prev -- failed refresh: the old DoT keeps running
    if d.prevGroup then m.dots[d.prevGroup.info.id] = d.prevGroup end
  end
  local label = FAIL[action] or action
  addFlash(m, d.info.name .. ": " .. label, 1, 0.3, 0.3)
  if action == "IMMUNE" then
    fight.immune = fight.immune + 1
    stat(m.guid, m.name, d.info.name, "i")
  else
    fight.resisted = fight.resisted + 1
    stat(m.guid, m.name, d.info.name, "r")
  end
  dbg("FAIL " .. d.info.name .. " on " .. m.name .. " [" .. short(m.guid) .. "]: " .. action ..
    (d.prev and " (old timer kept)" or ""))
  if db.chat then say(string.format("|cffff5555%s %s|r on %s", d.info.name, label:lower(), m.hidden and "your target" or m.name)) end
  if action == "IMMUNE" then
    local npc = npcID(m.guid)
    if npc then
      db.immune[npc] = db.immune[npc] or {}
      db.immune[npc][d.info.name] = true
    end
  end
  dirty = true
end

-- runs shortly after SUCCEEDED, when every event of that frame has arrived
local function evaluate(m, d)
  if mobs[m.guid] ~= m or m.dots[d.info.id] ~= d then return end
  local f = lastFail[m.guid]
  local failed = f and math.abs(f.t - d.start) <= SAME_FRAME
  local a = lastAura[m.guid]
  local auraChanged = a and math.abs(a - d.start) <= SAME_FRAME
  if failed and not auraChanged then
    failDot(m, d, f.action)
  elseif failed then
    dbg("KEEP " .. d.info.name .. ": " .. f.action .. " in the same frame, but the aura changed too (pet miss?)")
  end
end

local orphans = {} -- castGUID -> { info, t }: SUCCEEDED that arrived before (or without) its SENT

local function startDot(info, guid, name, t, how)
  local m = getMob(guid, name)
  if not db.castKnown[info.name] then
    db.castKnown[info.name] = true
    if not known[info.name] then known[info.name] = info.id dirty = true end
  end
  local prev = m.dots[info.id]
  local dur = durationOf(info)
  local d = { info = info, start = t, expires = t + dur, prev = prev,
    confirmed = prev and prev.confirmed or false }
  if info.group then
    for id, other in pairs(m.dots) do
      if id ~= info.id and other.info.group == info.group then
        d.prevGroup = other
        m.dots[id] = nil
      end
    end
  end
  m.dots[info.id] = d
  fight.casts = fight.casts + 1
  if prev then fight.refreshes = fight.refreshes + 1 end
  stat(m.guid, m.name, info.name, "c")
  dbg(string.format("START %s on %s [%s] %ds%s%s", info.name, m.name, short(m.guid), dur,
    prev and " (refresh)" or "", how and (" " .. how) or ""))
  C_Timer.After(0.1, function() evaluate(m, d) end)
  dirty = true
end

local function onSent(destName, castGUID, spellID)
  castGUID = str(castGUID)
  local info = spellInfo(spellID)
  if not info then return end
  if not castGUID then dbg("IGNORE " .. info.name .. ": cast ID not readable") return end
  local guid, how = resolveDest(destName)
  if not guid then dbg("IGNORE " .. info.name .. ": " .. how) return end
  local o = orphans[castGUID]
  if o then
    -- SUCCEEDED already came first: start now, with the time it actually succeeded
    orphans[castGUID] = nil
    startDot(info, guid, str(destName), o.t, "(SENT arrived late)")
    return
  end
  pending[castGUID] = { info = info, guid = guid, name = str(destName) }
  dbg("SENT " .. info.name .. " -> " .. tostring(str(destName)) .. " [" .. short(guid) .. "] via " .. how)
end

local function onSucceeded(castGUID, spellID)
  castGUID = str(castGUID)
  if not castGUID then return end
  local p = pending[castGUID]
  if p then
    pending[castGUID] = nil
    startDot(p.info, p.guid, p.name, now())
    return
  end
  local info = spellInfo(spellID)
  if not info then return end
  -- no SENT (yet): wait a moment for a late SENT, then fall back to the current target
  local o = { info = info, t = now() }
  orphans[castGUID] = o
  C_Timer.After(0.15, function()
    if orphans[castGUID] ~= o then return end
    orphans[castGUID] = nil
    local g = keyOf("target")
    local hostile = plain(UnitCanAttack, "player", "target")
    if g and hostile ~= false and plain(UnitIsDead, "target") ~= true then
      startDot(info, g, nameOf("target"), o.t, "(no SENT, used target)")
    else
      dbg("IGNORE " .. info.name .. " SUCCEEDED without SENT and no enemy target")
    end
  end)
end

local function onUnitCombat(unit, action, _, _, school)
  action = str(action)
  if not action then return end
  if action == "WOUND" then
    local g = keyOf(unit)
    local m = g and mobs[g]
    school = num(school)
    if m and school then
      m.lastTick = m.lastTick or {}
      m.lastTick[school] = now()
    end
    return
  end
  if not FAIL[action] then return end
  local guid = keyOf(unit)
  if not guid then return end
  local t = now()
  local f = lastFail[guid]
  if f and f.t == t then return end -- same event via another unit token
  lastFail[guid] = { t = t, action = action }
  if mobs[guid] then dbg("COMBAT " .. action .. " on [" .. short(guid) .. "] via " .. tostring(unit)) end
end

local function onUnitAura(unit, info)
  local guid = keyOf(unit)
  if not guid then return end
  local m = mobs[guid]
  if type(info) == "table" and not issecret(info) then
    local added, updated = info.addedAuras, info.updatedAuraInstanceIDs
    local hasAdded = issecret(added) or (type(added) == "table" and #added > 0)
    local hasUpdated = issecret(updated) or (type(updated) == "table" and #updated > 0)
    if hasAdded or hasUpdated then lastAura[guid] = now() end
    if m and hasAdded then
      local t = now()
      for _, d in pairs(m.dots) do
        if math.abs(d.start - t) <= SAME_FRAME and not d.confirmed then
          d.confirmed = true
          dirty = true
        end
      end
    end
  end
  -- out of combat the real aura data is readable: learn exact durations
  if InCombatLockdown() or not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return end
  for i = 1, 40 do
    local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HARMFUL|PLAYER")
    if not ok or issecret(a) or not a then break end
    local id, dur, exp = num(a.spellId), num(a.duration), num(a.expirationTime)
    if id and not spellInfo(id) and not db.untracked[id] then
      db.untracked[id] = { name = str(a.name) or "?", dur = dur }
      dbg("UNTRACKED own debuff " .. tostring(str(a.name)) .. " (" .. id .. ") " .. tostring(dur) .. "s")
    end
    if id and dur and dur > 0 and spellInfo(id) then
      if db.learned[id] ~= dur then
        db.learned[id] = dur
        dbg("LEARNED " .. spellInfo(id).name .. " = " .. dur .. "s")
      end
      if m and m.dots[id] and exp then
        m.dots[id].expires = exp
        m.dots[id].confirmed = true
        dirty = true
      end
    end
  end
end

---------------------------------------------------------------------------
-- Cleanup: expired DoTs, dead mobs, raid marks
---------------------------------------------------------------------------
local TOKENS = { "target", "focus", "mouseover" }
for i = 1, 40 do TOKENS[#TOKENS + 1] = "nameplate" .. i end

-- Out of combat the real debuffs are readable: keep each timer in line with them.
-- (Replaces the old "clear everything when combat ends", which wiped DoTs when the
-- game briefly reported combat as over during a pull.)
local function syncOutOfCombat()
  if InCombatLockdown() or not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return end
  local seen = {}
  for _, u in ipairs(TOKENS) do
    local g = keyOf(u)
    local m = g and mobs[g]
    if m and not seen[g] then
      seen[g] = true
      local present, readable = {}, true
      for i = 1, 40 do
        local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, u, i, "HARMFUL|PLAYER")
        if not ok or issecret(a) then readable = false break end
        if not a then break end
        local id = num(a.spellId)
        if id then present[id] = num(a.expirationTime) or true end
      end
      if readable then
        local t = now()
        for id, d in pairs(m.dots) do
          local p = present[id]
          if p then
            if type(p) == "number" and p > 0 and math.abs(p - d.expires) > 0.3 then
              d.expires = p
              dirty = true
            end
            d.confirmed = true
          elseif t - d.start > 1.5 then -- give a fresh cast time to show up on the enemy
            m.dots[id] = nil
            dirty = true
            dbg("SYNC " .. d.info.name .. " not on " .. m.name .. " [" .. short(g) .. "] anymore, removed")
          end
        end
      end
    end
  end
end

local function scan()
  if next(mobs) == nil then return end
  for _, m in pairs(mobs) do m.unit = nil end
  for _, u in ipairs(TOKENS) do
    local g = keyOf(u)
    local m = g and mobs[g]
    if m then
      if not m.unit then m.unit = u end -- token used for the HP display (target first)
      if m.hidden then -- a hidden (secret) name can still be drawn
        if not m.shownName then dirty = true end
        m.shownName = UnitName(u)
      end
      if plain(UnitIsDead, u) == true then
        removeMob(g, "dead")
      else
        local ok, mark = pcall(GetRaidTargetIndex, u)
        if ok and not issecret(mark) and mark ~= m.mark and (mark == nil or type(mark) == "number") then
          m.mark = mark
          dirty = true
        end
      end
    end
  end
  syncOutOfCombat()
  local t = now()
  for g, m in pairs(mobs) do
    -- "DoT lost?": its school's ticks stopped although the enemy is in view
    if m.unit then m.tokenSince = m.tokenSince or t else m.tokenSince = nil end
    if db.lostCheck ~= false then
      for _, d in pairs(m.dots) do
        local iv, sch = d.info.def.tick, d.info.def.school
        if iv and sch then
          local last = m.lastTick and m.lastTick[sch] or 0
          local ref = math.max(d.start, m.tokenSince or math.huge, last)
          if not d.lost and m.tokenSince and t - ref > iv * 1.5 + 1 and t - d.start > iv + 1 then
            d.lost, d.lostAt = true, t
            fight.lost = fight.lost + 1
            dirty = true
            dbg("LOST? " .. d.info.name .. " on " .. m.name .. " [" .. short(g) .. "]: no ticks for " .. string.format("%.1f", t - ref) .. "s")
          elseif d.lost and last > d.lostAt then
            d.lost = false
            dirty = true
          end
        end
      end
    end
    for id, d in pairs(m.dots) do
      if d.expires <= t then
        m.dots[id] = nil
        dirty = true
        dbg("EXPIRED " .. d.info.name .. " on " .. m.name .. " [" .. short(g) .. "]")
      end
    end
    for i = #m.flash, 1, -1 do
      if m.flash[i].expires <= t then table.remove(m.flash, i) dirty = true end
    end
    if next(m.dots) == nil and #m.flash == 0 then removeMob(g, "nothing left") end
  end
end

---------------------------------------------------------------------------
-- Display (plain for now; the visual design comes later)
---------------------------------------------------------------------------
local ROW_H, WIDTH, GAP = 16, 220, 6

-- look settings (font size, bar texture, colors per DoT, combat state)
local LOOK = {
  FONTS = {
    small  = { hdr = "GameFontNormalSmall", txt = "GameFontHighlightSmall", row = 16, head = 15, label = "Small" },
    normal = { hdr = "GameFontNormal", txt = "GameFontHighlight", row = 19, head = 17, label = "Normal" },
    large  = { hdr = "GameFontNormalLarge", txt = "GameFontHighlightLarge", row = 23, head = 21, label = "Large" },
  },
  FONT_ORDER = { "small", "normal", "large" },
  TEXTURES = {
    { key = "classic", file = "Interface\\TargetingFrame\\UI-StatusBar", label = "Classic" },
    { key = "smooth", file = "Interface\\RaidFrame\\Raid-Bar-Hp-Fill", label = "Smooth" },
    { key = "skill", file = "Interface\\PaperDollInfoFrame\\UI-Character-Skills-Bar", label = "Skill bar" },
    { key = "flat", file = "Interface\\Buttons\\WHITE8X8", label = "Flat" },
  },
  inCombat = false,
}
function LOOK.font() return LOOK.FONTS[db and db.fontSize or "small"] or LOOK.FONTS.small end
function LOOK.tex()
  for _, t in ipairs(LOOK.TEXTURES) do
    if t.key == (db and db.texture) then return t.file end
  end
  return LOOK.TEXTURES[1].file
end
function LOOK.color(info)
  local c = db and db.colors and db.colors[info.name]
  return c or info.color
end
-- 0.55..1 pulse while a DoT is about to run out (refresh warning)
function LOOK.pulse(d, left, t)
  if d.lost or not db or db.warn == false then return 1 end
  if left > 0 and left <= (db.warnTime or 3) then return 0.55 + 0.45 * math.abs(math.sin(t * 6)) end
  return 1
end
local LETTERS = "ABCDEFGHIJ"

local frame = CreateFrame("Frame", "DotWatchFrame", UIParent)
frame:SetSize(WIDTH, ROW_H)
frame:SetMovable(true)
frame:SetClampedToScreen(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", function(self) if not db.locked then self:StartMoving() end end)
-- growth direction: which point of the list stays put when it gets longer
-- ("middle" = center, the old behavior; "down" = top edge; "up" = bottom edge)
function LOOK.anchor()
  local grow = db.grow or "middle"
  local l, t, b = frame:GetLeft(), frame:GetTop(), frame:GetBottom()
  if not (l and t and b) then return end
  frame:ClearAllPoints()
  if grow == "down" then
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l, t)
    db.pos = { "TOPLEFT", "BOTTOMLEFT", l, t }
  elseif grow == "up" then
    frame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", l, b)
    db.pos = { "BOTTOMLEFT", "BOTTOMLEFT", l, b }
  else
    local cx, cy = frame:GetCenter()
    frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx, cy)
    db.pos = { "CENTER", "BOTTOMLEFT", cx, cy }
  end
end

frame:SetScript("OnDragStop", function(self)
  self:StopMovingOrSizing()
  local p, _, rp, x, y = self:GetPoint()
  db.pos = { p, rp, x, y }
  LOOK.anchor()
end)

local anchorBg = frame:CreateTexture(nil, "BACKGROUND")
anchorBg:SetAllPoints()
anchorBg:SetColorTexture(0.3, 0.1, 0.5, 0.5)
local anchorText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
anchorText:SetPoint("CENTER")
anchorText:SetText("DotWatch (drag me, /dw lock)")

-- A "canvas" holds one set of widget pools. The real window has one, the
-- preview in the options window has another; both are drawn by the same code.
local function newCanvas(parentFrame)
  return { frame = parentFrame, headers = {}, bars = {}, flashes = {}, slims = {}, cells = {},
    minis = {}, tcells = {}, texts = {}, lines = {} }
end
local main = newCanvas(frame)

local function fmtTime(left)
  if left < 0 then left = 0 end
  return left >= 10 and string.format("%d", left) or string.format("%.1f", left)
end
local function timeColor(fs, left)
  if left < 3 then fs:SetTextColor(1, 0.35, 0.3) else fs:SetTextColor(1, 1, 1) end
end

local function getHeader(cv, i)
  local h = cv.headers[i]
  if h then return h end
  h = cv.frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  h:SetJustifyH("LEFT")
  h.hp = cv.frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  h.hp:SetJustifyH("LEFT")
  cv.headers[i] = h
  return h
end

local function getFlash(cv, i)
  local fl = cv.flashes[i]
  if fl then return fl end
  fl = cv.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fl:SetJustifyH("LEFT")
  cv.flashes[i] = fl
  return fl
end

local function getText(cv, i)
  local t = cv.texts[i]
  if t then return t end
  t = cv.frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  t:SetJustifyH("LEFT")
  cv.texts[i] = t
  return t
end

local function getLine(cv, i)
  local l = cv.lines[i]
  if l then return l end
  l = cv.frame:CreateTexture(nil, "ARTWORK")
  l:SetColorTexture(1, 0.82, 0, 0.2)
  l:SetHeight(1)
  cv.lines[i] = l
  return l
end

-- style 1: full bar with icon, name and time
local function getBar(cv, i)
  local b = cv.bars[i]
  if b then return b end
  b = CreateFrame("StatusBar", nil, cv.frame)
  b:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  b.bg = b:CreateTexture(nil, "BACKGROUND")
  b.bg:SetAllPoints()
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetSize(ROW_H - 2, ROW_H - 2)
  b.icon:SetPoint("RIGHT", b, "LEFT", -2, 0)
  b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.label:SetPoint("LEFT", 3, 0)
  b.time = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.time:SetPoint("RIGHT", -3, 0)
  cv.bars[i] = b
  return b
end

-- style 2: icon, thin bar, time
local function getSlim(cv, i)
  local b = cv.slims[i]
  if b then return b end
  b = CreateFrame("Frame", nil, cv.frame)
  b:SetHeight(14)
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetSize(14, 14)
  b.icon:SetPoint("LEFT")
  b.time = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.time:SetPoint("RIGHT")
  b.time:SetWidth(28)
  b.time:SetJustifyH("RIGHT")
  b.border = b:CreateTexture(nil, "BACKGROUND")
  b.border:SetColorTexture(0, 0, 0, 0.9)
  b.border:SetPoint("LEFT", b.icon, "RIGHT", 4, 0)
  b.border:SetPoint("RIGHT", b.time, "LEFT", -4, 0)
  b.border:SetHeight(7)
  b.bar = CreateFrame("StatusBar", nil, b)
  b.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  b.bar:SetPoint("TOPLEFT", b.border, "TOPLEFT", 1, -1)
  b.bar:SetPoint("BOTTOMRIGHT", b.border, "BOTTOMRIGHT", -1, 1)
  cv.slims[i] = b
  return b
end

-- styles 3, 4 and 5: icon with a cooldown sweep and the seconds on top
local function getCell(cv, i)
  local c = cv.cells[i]
  if c then return c end
  c = CreateFrame("Frame", nil, cv.frame)
  c.border = c:CreateTexture(nil, "BACKGROUND")
  c.border:SetColorTexture(0, 0, 0, 1)
  c.border:SetPoint("TOPLEFT", -1, 1)
  c.border:SetPoint("BOTTOMRIGHT", 1, -1)
  c.icon = c:CreateTexture(nil, "ARTWORK")
  c.icon:SetAllPoints()
  c.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  local ok, cd = pcall(CreateFrame, "Cooldown", nil, c, "CooldownFrameTemplate")
  if not ok then cd = CreateFrame("Cooldown", nil, c) end
  cd:SetAllPoints()
  pcall(cd.SetHideCountdownNumbers, cd, true)
  pcall(cd.SetDrawEdge, cd, false)
  c.cd = cd
  c.textHolder = CreateFrame("Frame", nil, c)
  c.textHolder:SetAllPoints()
  c.textHolder:SetFrameLevel((cd:GetFrameLevel() or 1) + 2)
  c.time = c.textHolder:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
  c.time:SetPoint("CENTER", 0, 0)
  cv.cells[i] = c
  return c
end

-- style 5 (others): small icon + seconds next to it
local function getMini(cv, i)
  local m = cv.minis[i]
  if m then return m end
  m = CreateFrame("Frame", nil, cv.frame)
  m:SetSize(40, 12)
  m.icon = m:CreateTexture(nil, "ARTWORK")
  m.icon:SetSize(12, 12)
  m.icon:SetPoint("LEFT")
  m.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  m.time = m:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  m.time:SetPoint("LEFT", m.icon, "RIGHT", 2, 0)
  cv.minis[i] = m
  return m
end

-- style 4: table cell, seconds with a colored line under it
local function getTcell(cv, i)
  local c = cv.tcells[i]
  if c then return c end
  c = CreateFrame("Frame", nil, cv.frame)
  c:SetSize(38, 18)
  c.time = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  c.time:SetPoint("CENTER", 0, 1)
  c.line = c:CreateTexture(nil, "ARTWORK")
  c.line:SetHeight(2)
  c.line:SetPoint("BOTTOMLEFT")
  c.line:SetPoint("BOTTOMRIGHT")
  cv.tcells[i] = c
  return c
end

local function sameNameCount(name, list)
  local count = 0
  if list then
    for _, m in ipairs(list) do if m.name == name then count = count + 1 end end
  else
    for _, m in pairs(mobs) do if m.name == name then count = count + 1 end end
  end
  return count
end

local function sortedMobs()
  local list = {}
  for _, m in pairs(mobs) do list[#list + 1] = m end
  local tg = keyOf("target")
  -- stable order: first dotted stays on top; the target is only highlighted, never moved
  table.sort(list, function(a, b)
    if a.created ~= b.created then return a.created < b.created end
    return a.guid < b.guid
  end)
  return list, tg
end

-- rows for one enemy: fixed slots (active or placeholder), then active slot-less curses
local function rowsFor(m, forcePlaceholders)
  local rows = {}
  local immune = db.immune[npcID(m.guid) or 0] or {}
  for _, slot in ipairs(SLOT_ORDER) do
    local active
    for _, d in pairs(m.dots) do
      if d.info.slot == slot and (not active or d.start > active.start) then active = d end
    end
    if active then
      rows[#rows + 1] = { dot = active, slot = slot }
    else
      local s, id = slotSpell(slot)
      if s and (forcePlaceholders or db.showPlaceholders ~= false) then
        rows[#rows + 1] = { name = s.name, id = id, immune = immune[s.name], slot = slot }
      end
    end
  end
  local extra = {}
  for _, d in pairs(m.dots) do
    if not d.info.slot then extra[#extra + 1] = d end
  end
  table.sort(extra, function(a, b) return a.start < b.start end)
  for _, d in ipairs(extra) do rows[#rows + 1] = { dot = d, slot = "curse" } end
  return rows
end

local function rowIcon(r)
  if r.dot then return r.dot.info.icon end
  return type(r.id) == "number" and iconOf(r.id) or 136197
end

---------------------------------------------------------------------------
-- Nameplate overlay: letter + running DoTs above each tracked enemy's plate
---------------------------------------------------------------------------
local ICON = 18
local overlays = {} -- pool, index -> frame
local plateTimes = {} -- list of { fontstring, dot } updated every frame

local function getOverlay(i)
  local o = overlays[i]
  if o then return o end
  o = CreateFrame("Frame", nil, UIParent)
  o:SetSize(ICON, ICON)
  o:SetFrameStrata("LOW")
  o.letter = o:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  o.letter:SetPoint("LEFT", o, "LEFT", 0, 0)
  o.letter:SetTextColor(1, 0.82, 0)
  o.icons = {}
  overlays[i] = o
  return o
end

local function getIcon(o, i)
  local ic = o.icons[i]
  if ic then return ic end
  ic = CreateFrame("Frame", nil, o)
  ic:SetSize(ICON, ICON)
  ic.tex = ic:CreateTexture(nil, "ARTWORK")
  ic.tex:SetAllPoints()
  ic.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  ic.border = ic:CreateTexture(nil, "BACKGROUND")
  ic.border:SetPoint("TOPLEFT", -1, 1)
  ic.border:SetPoint("BOTTOMRIGHT", 1, -1)
  ic.time = ic:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  ic.time:SetPoint("TOP", ic, "BOTTOM", 0, -1)
  o.icons[i] = ic
  return ic
end

local function plateDots(m)
  local list = {}
  for _, slot in ipairs(SLOT_ORDER) do
    local best
    for _, d in pairs(m.dots) do
      if d.info.slot == slot and (not best or d.start > best.start) then best = d end
    end
    if best then list[#list + 1] = best end
  end
  local extra = {}
  for _, d in pairs(m.dots) do if not d.info.slot then extra[#extra + 1] = d end end
  table.sort(extra, function(a, b) return a.start < b.start end)
  for _, d in ipairs(extra) do list[#list + 1] = d end
  return list
end

local function layoutPlates(sameNameCount, LETTERS)
  for _, o in ipairs(overlays) do o:Hide() end
  wipe(plateTimes)
  if not db.plates or not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return end
  local n = 0
  for i = 1, 40 do
    local u = "nameplate" .. i
    local g = keyOf(u)
    local m = g and mobs[g]
    if m then
      local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, u)
      if ok and plate and not issecret(plate) then
        local dots = db.plateDots and plateDots(m) or {}
        local showLetter = sameNameCount(m.name) > 1 and not m.hidden
        if #dots > 0 or showLetter then
          n = n + 1
          local o = getOverlay(n)
          o:ClearAllPoints()
          if pcall(o.SetPoint, o, "BOTTOM", plate, "TOP", 0, db.plateY) then
            local x = 0
            if showLetter then
              o.letter:SetText(LETTERS:sub(m.letter, m.letter))
              o.letter:ClearAllPoints()
              if #dots == 0 then
                o.letter:SetPoint("CENTER", o, "CENTER", 0, 0)
              else
                o.letter:SetPoint("LEFT", o, "LEFT", 0, 0)
              end
              o.letter:Show()
              x = 16
            else
              o.letter:Hide()
            end
            for _, ic in ipairs(o.icons) do ic:Hide() end
            for k, d in ipairs(dots) do
              local ic = getIcon(o, k)
              ic:ClearAllPoints()
              ic:SetPoint("LEFT", o, "LEFT", x, 0)
              ic.tex:SetTexture(d.info.icon)
              local c = LOOK.color(d.info)
              ic.border:SetColorTexture(c[1], c[2], c[3], 1)
              ic:SetAlpha(d.confirmed and 1 or 0.7)
              ic:Show()
              plateTimes[#plateTimes + 1] = { ic.time, d }
              x = x + ICON + 3
            end
            o:SetWidth(math.max(x - 3, ICON))
            o:Show()
          end
        end
      end
    end
  end
end

local function updatePlateTimes(t)
  for _, pt in ipairs(plateTimes) do
    local left = pt[2].expires - t
    if left < 0 then left = 0 end
    pt[1]:SetText(left >= 10 and string.format("%d", left) or string.format("%.1f", left))
    if left < 3 then pt[1]:SetTextColor(1, 0.3, 0.3) else pt[1]:SetTextColor(1, 1, 1) end
  end
end

local STYLES = { "bars", "slim", "icons", "table", "focus" }
local STYLE_NAMES = { bars = "Bars", slim = "Slim bars", icons = "Icons with timers",
  table = "Table", focus = "Target big, others small" }
local SIZES = {
  { 0.8, "Small", "A compact list that takes little room." },
  { 1.0, "Medium", "The normal size." },
  { 1.2, "Large", "Easier to read from a distance." },
  { 1.4, "Extra large", "For high resolutions or big screens." },
}
local STYLE_WIDTH = { bars = 220, slim = 200, icons = 180, table = 240, focus = 210 }

local n, cv, curList -- per-layout counters, canvas, enemy list

local function placeHeader(m, tg, x, y, big)
  n.h = n.h + 1
  local h = getHeader(cv, n.h)
  local f = LOOK.font()
  local font = big and "GameFontNormalLarge" or f.hdr
  h:SetFontObject(font)
  h.hp:SetFontObject(font)
  local label = m.name
  if sameNameCount(m.name, curList) > 1 and not m.hidden then label = label .. " " .. LETTERS:sub(m.letter, m.letter) end
  if m.mark then label = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_" .. m.mark .. ":0|t " .. label end
  if m.hidden then
    -- dungeon: the game draws the hidden name for us (like the HP %)
    if not (m.shownName and pcall(h.SetText, h, m.shownName)) then h:SetText("Enemy " .. LETTERS:sub(m.letter, m.letter)) end
  else
    h:SetText(label)
  end
  h.mob = m
  if m.guid == tg then h:SetTextColor(1, 0.82, 0) else h:SetTextColor(0.75, 0.75, 0.75) end
  h:ClearAllPoints()
  h:SetPoint("TOPLEFT", cv.frame, "TOPLEFT", x, -y)
  h:Show()
  h.hp:ClearAllPoints()
  -- 0.10.1: never read the name's width. Once a header showed a hidden (secret) dungeon
  -- name, the game keeps its width secret, and reading it broke the whole window.
  h.hp:SetPoint("LEFT", h, "RIGHT", 5, 0)
  h.hp:Show()
  if m.fakeHP then
    h.hp:SetFormattedText("%d%%", m.fakeHP)
    local p = m.fakeHP / 100
    if p >= 0.5 then h.hp:SetTextColor((1 - p) * 2, 1, 0.15) else h.hp:SetTextColor(1, p * 2, 0.15) end
  end
  return big and 21 or f.head
end

local function placeFlashes(m, x, y)
  local dy = 0
  for _, fx in ipairs(m.flash) do
    n.f = n.f + 1
    local fl = getFlash(cv, n.f)
    fl:SetFontObject(LOOK.font().txt)
    fl:SetText(fx.text)
    fl:SetTextColor(fx.r, fx.g, fx.b)
    fl:ClearAllPoints()
    fl:SetPoint("TOPLEFT", cv.frame, "TOPLEFT", x, -(y + dy))
    fl:Show()
    dy = dy + LOOK.font().row - 3
  end
  return dy
end

local function setCell(c, r, size)
  c:SetSize(size, size)
  c.icon:SetTexture(rowIcon(r))
  c.time:SetFontObject(size >= 40 and "NumberFontNormalLarge" or "NumberFontNormal")
  if r.dot then
    c.dot = r.dot
    c.icon:SetDesaturated(r.dot.lost and true or false)
    c.icon:SetAlpha(1)
    c.cd:Show()
    pcall(c.cd.SetCooldown, c.cd, r.dot.start, r.dot.expires - r.dot.start)
    c.time:SetText("")
  else
    c.dot = nil
    c.icon:SetDesaturated(true)
    c.icon:SetAlpha(0.35)
    c.cd:Hide()
    if r.immune then
      c.time:SetText("|cffcc5555imm|r")
    else
      c.time:SetText("")
    end
  end
end

local render = {}

render.bars = function(list, tg, W)
  local y = 0
  for idx, m in ipairs(list) do
    if idx > 1 then y = y + GAP end
    y = y + placeHeader(m, tg, 0, y)
    for _, r in ipairs(rowsFor(m)) do
      n.b = n.b + 1
      local b = getBar(cv, n.b)
      b:SetSize(W - ROW_H - 2, ROW_H - 2)
      b.icon:SetSize(ROW_H - 2, ROW_H - 2)
      b:SetStatusBarTexture(LOOK.tex())
      b.label:SetFontObject(LOOK.font().txt)
      b.time:SetFontObject(LOOK.font().txt)
      b.icon:SetTexture(rowIcon(r))
      if r.dot then
        b.dot = r.dot
        b.icon:SetDesaturated(false)
        b.icon:SetAlpha(1)
        b.bg:SetColorTexture(0, 0, 0, 0.5)
        b.label:SetText(r.dot.info.name)
        b.label:SetTextColor(1, 1, 1)
        local c = LOOK.color(r.dot.info)
        if r.dot.lost then
          b:SetStatusBarColor(0.4, 0.4, 0.4)
          b.icon:SetDesaturated(true)
        else
          b:SetStatusBarColor(c[1], c[2], c[3])
        end
      else
        b.dot = nil
        b.icon:SetDesaturated(true)
        b.icon:SetAlpha(0.35)
        b.bg:SetColorTexture(0.2, 0.2, 0.2, 0.25)
        b:SetMinMaxValues(0, 1)
        b:SetValue(0)
        b:SetAlpha(1)
        b.label:SetText(r.name)
        if r.immune then
          b.label:SetTextColor(0.6, 0.3, 0.3)
          b.time:SetText("immune")
          b.time:SetTextColor(0.6, 0.3, 0.3)
        else
          b.label:SetTextColor(0.45, 0.45, 0.45)
          b.time:SetText("")
        end
      end
      b:ClearAllPoints()
      b:SetPoint("TOPLEFT", cv.frame, "TOPLEFT", ROW_H + 2, -y - 1)
      b:Show()
      y = y + ROW_H
    end
    y = y + placeFlashes(m, ROW_H + 2, y)
  end
  return y
end

render.slim = function(list, tg, W)
  local y = 0
  for idx, m in ipairs(list) do
    if idx > 1 then y = y + GAP end
    y = y + placeHeader(m, tg, 0, y)
    for _, r in ipairs(rowsFor(m)) do
      n.s = n.s + 1
      local b = getSlim(cv, n.s)
      b:SetWidth(W)
      b:SetHeight(ROW_H - 2)
      b.icon:SetSize(ROW_H - 2, ROW_H - 2)
      b.bar:SetStatusBarTexture(LOOK.tex())
      b.time:SetFontObject(LOOK.font().txt)
      b.time:SetWidth(ROW_H * 2)
      b.icon:SetTexture(rowIcon(r))
      if r.dot then
        b.dot = r.dot
        b.icon:SetDesaturated(false)
        b.icon:SetAlpha(1)
        b.border:SetColorTexture(0, 0, 0, 0.9)
        b.bar:Show()
        local c = LOOK.color(r.dot.info)
        if r.dot.lost then
          b.bar:SetStatusBarColor(0.4, 0.4, 0.4)
          b.icon:SetDesaturated(true)
        else
          b.bar:SetStatusBarColor(c[1], c[2], c[3])
        end
      else
        b.dot = nil
        b.icon:SetDesaturated(true)
        b.icon:SetAlpha(0.35)
        b.border:SetColorTexture(0.25, 0.25, 0.25, 0.3)
        b.bar:Hide()
        b.time:SetText(r.immune and "|cffcc5555imm|r" or "")
      end
      b:ClearAllPoints()
      b:SetPoint("TOPLEFT", cv.frame, "TOPLEFT", 0, -y)
      b:Show()
      y = y + ROW_H
    end
    y = y + placeFlashes(m, ROW_H + 2, y)
  end
  return y
end

render.icons = function(list, tg, W)
  local y, maxW = 0, W
  for idx, m in ipairs(list) do
    if idx > 1 then y = y + GAP + 2 end
    y = y + placeHeader(m, tg, 0, y) + 2
    local x = 0
    for _, r in ipairs(rowsFor(m)) do
      n.c = n.c + 1
      local c = getCell(cv, n.c)
      setCell(c, r, 30)
      c:ClearAllPoints()
      c:SetPoint("TOPLEFT", cv.frame, "TOPLEFT", x + 1, -y - 1)
      c:Show()
      x = x + 34
    end
    if x > maxW then maxW = x end
    y = y + 34
    y = y + placeFlashes(m, 0, y)
  end
  return y, maxW
end

render.table = function(list, tg, W)
  -- columns: every known slot, plus one for curses if any curse is running
  local cols = {}
  for _, slot in ipairs(SLOT_ORDER) do
    local s, id = slotSpell(slot)
    local active
    for _, m in ipairs(list) do
      for _, d in pairs(m.dots) do if d.info.slot == slot then active = d end end
    end
    if s or active then cols[#cols + 1] = { slot = slot, icon = active and active.info.icon or iconOf(id) } end
  end
  local curseIcon
  for _, m in ipairs(list) do
    for _, d in pairs(m.dots) do if not d.info.slot then curseIcon = d.info.icon end end
  end
  if curseIcon then cols[#cols + 1] = { slot = "curse", icon = curseIcon } end

  local colW = 40
  local nameW = W - #cols * colW
  -- header row: spell icons
  for i, col in ipairs(cols) do
    n.c = n.c + 1
    local c = getCell(cv, n.c)
    setCell(c, { id = nil }, 16)
    c.icon:SetTexture(col.icon)
    c.icon:SetDesaturated(false)
    c.icon:SetAlpha(1)
    c:ClearAllPoints()
    c:SetPoint("TOP", cv.frame, "TOPLEFT", nameW + (i - 0.5) * colW, -1)
    c:Show()
  end
  local y = 22
  for _, m in ipairs(list) do
    local rowY = y
    local hh = placeHeader(m, tg, 0, rowY + 2)
    local fy = placeFlashes(m, 0, rowY + 2 + hh)
    local bySlot = {}
    for _, r in ipairs(rowsFor(m, true)) do bySlot[r.slot] = r end
    for i, col in ipairs(cols) do
      n.t = n.t + 1
      local c = getTcell(cv, n.t)
      local r = bySlot[col.slot]
      if r and r.dot then
        c.dot = r.dot
        local cc = LOOK.color(r.dot.info)
        c.line:SetColorTexture(cc[1], cc[2], cc[3], 1)
      else
        c.dot = nil
        c.time:SetText(r and r.immune and "|cffcc5555imm|r" or "|cff5c5c5c–|r")
        c.line:SetColorTexture(0.35, 0.35, 0.35, 0.35)
      end
      c:ClearAllPoints()
      c:SetPoint("TOP", cv.frame, "TOPLEFT", nameW + (i - 0.5) * colW, -rowY)
      c:Show()
    end
    y = y + math.max(22, hh + fy + 6)
  end
  return y
end

render.focus = function(list, tg, W)
  local y = 0
  local target, others = nil, {}
  for _, m in ipairs(list) do
    if m.guid == tg then target = m else others[#others + 1] = m end
  end
  if target then
    y = y + placeHeader(target, tg, 0, y, true) + 3
    local x = 0
    for _, r in ipairs(rowsFor(target)) do
      n.c = n.c + 1
      local c = getCell(cv, n.c)
      setCell(c, r, 42)
      c:ClearAllPoints()
      c:SetPoint("TOPLEFT", cv.frame, "TOPLEFT", x + 1, -y - 1)
      c:Show()
      x = x + 47
    end
    y = y + 46
    y = y + placeFlashes(target, 0, y)
    if #others > 0 then
      y = y + 6
      n.l = n.l + 1
      local l = getLine(cv, n.l)
      l:ClearAllPoints()
      l:SetPoint("TOPLEFT", cv.frame, "TOPLEFT", 0, -y)
      l:SetWidth(W)
      l:Show()
      y = y + 4
      n.x = n.x + 1
      local t = getText(cv, n.x)
      t:SetText("Others")
      t:ClearAllPoints()
      t:SetPoint("TOPLEFT", cv.frame, "TOPLEFT", 0, -y)
      t:Show()
      y = y + 14
    end
  end
  for idx, m in ipairs(others) do
    if idx > 1 then y = y + 4 end
    y = y + placeHeader(m, tg, 0, y)
    local x = 0
    for _, r in ipairs(rowsFor(m, true)) do
      n.m = n.m + 1
      local mi = getMini(cv, n.m)
      mi.icon:SetTexture(rowIcon(r))
      if r.dot then
        mi.dot = r.dot
        mi.icon:SetDesaturated(false)
        mi.icon:SetAlpha(1)
      else
        mi.dot = nil
        mi.icon:SetDesaturated(true)
        mi.icon:SetAlpha(0.35)
        mi.time:SetText(r.immune and "|cffcc5555imm|r" or "|cff5c5c5c–|r")
      end
      mi:ClearAllPoints()
      mi:SetPoint("TOPLEFT", cv.frame, "TOPLEFT", x, -y)
      mi:Show()
      x = x + 44
    end
    y = y + 14
    y = y + placeFlashes(m, 0, y)
  end
  return y
end

-- draw a list of enemies into a canvas in the given style; returns height, width
local function drawCanvas(canvas, list, tg, style)
  for _, h in ipairs(canvas.headers) do h:Hide() h.hp:Hide() h.mob = nil end
  for _, pool in ipairs({ canvas.bars, canvas.slims, canvas.cells, canvas.minis, canvas.tcells }) do
    for _, w in ipairs(pool) do w:Hide() w.dot = nil end
  end
  for _, pool in ipairs({ canvas.flashes, canvas.texts, canvas.lines }) do
    for _, w in ipairs(pool) do w:Hide() end
  end
  style = STYLE_NAMES[style] and style or "bars"
  ROW_H = LOOK.font().row
  local W = STYLE_WIDTH[style] + (ROW_H - 16) * 4
  if #list == 0 then return 0, W end
  cv, curList = canvas, list
  n = { h = 0, b = 0, s = 0, c = 0, m = 0, t = 0, f = 0, x = 0, l = 0 }
  local h, w = render[style](list, tg, W)
  return h, w or W
end

-- tick marks on a bar: one thin line per damage tick still to come
local function placeTicks(b, bar, d, t, total)
  b.ticks = b.ticks or {}
  local iv = d.info.def.tick
  local count = 0
  if iv and db.ticks ~= false and not d.lost and total > 0 then
    local w = bar:GetWidth() or 0
    for k = 1, 30 do
      local tickAt = d.start + k * iv
      if tickAt >= d.expires - 0.05 then break end
      if tickAt > t then
        count = count + 1
        local mark = b.ticks[count]
        if not mark then
          mark = bar:CreateTexture(nil, "OVERLAY")
          mark:SetColorTexture(0, 0, 0, 0.7)
          mark:SetWidth(1)
          b.ticks[count] = mark
        end
        mark:ClearAllPoints()
        mark:SetPoint("TOP", bar, "TOPLEFT", (d.expires - tickAt) / total * w, 0)
        mark:SetPoint("BOTTOM", bar, "BOTTOMLEFT", (d.expires - tickAt) / total * w, 0)
        mark:Show()
      end
    end
  end
  for k = count + 1, #b.ticks do b.ticks[k]:Hide() end
end

local function timeText(fs, d, left)
  if d.lost then
    fs:SetText("lost?")
    fs:SetTextColor(1, 0.6, 0.2)
  else
    fs:SetText(fmtTime(left))
    timeColor(fs, left)
  end
end

local function updateCanvas(canvas, t)
  for _, b in ipairs(canvas.bars) do
    local d = b.dot
    if d and b:IsShown() then
      local total = d.expires - d.start
      local left = d.expires - t
      b:SetMinMaxValues(0, total > 0 and total or 1)
      b:SetValue(left > 0 and left or 0)
      timeText(b.time, d, left)
      b:SetAlpha((d.confirmed and 1 or 0.75) * (d.lost and 0.6 or 1) * LOOK.pulse(d, left, t))
      placeTicks(b, b, d, t, total)
    elseif b.ticks then
      for _, mark in ipairs(b.ticks) do mark:Hide() end
    end
  end
  for _, b in ipairs(canvas.slims) do
    local d = b.dot
    if d and b:IsShown() then
      local total = d.expires - d.start
      local left = d.expires - t
      b.bar:SetMinMaxValues(0, total > 0 and total or 1)
      b.bar:SetValue(left > 0 and left or 0)
      timeText(b.time, d, left)
      b:SetAlpha((d.confirmed and 1 or 0.75) * (d.lost and 0.6 or 1) * LOOK.pulse(d, left, t))
      placeTicks(b, b.bar, d, t, total)
    elseif b.ticks then
      for _, mark in ipairs(b.ticks) do mark:Hide() end
    end
  end
  for _, pool in ipairs({ canvas.cells, canvas.minis, canvas.tcells }) do
    for _, c in ipairs(pool) do
      local d = c.dot
      if d and c:IsShown() then
        local left = d.expires - t
        timeText(c.time, d, left)
        c:SetAlpha((d.confirmed and 1 or 0.8) * (d.lost and 0.6 or 1) * LOOK.pulse(d, left, t))
      end
    end
  end
end

-- warning sounds, from soft to loud (0.11). Game sounds only: looked up by their
-- SOUNDKIT name, with the classic ID as fallback.
local SOUNDS = {
  { key = "click",   label = "Soft click",          kit = "IG_MAINMENU_OPTION_CHECKBOX_ON", id = 856 },
  { key = "page",    label = "Page turn",           kit = "IG_QUEST_LIST_OPEN",             id = 875 },
  { key = "whisper", label = "Whisper",             kit = "TELL_MESSAGE",                   id = 3081 },
  { key = "ping",    label = "Map ping",            kit = "MAP_PING",                       id = 3175 },
  { key = "clock1",  label = "Alarm clock (soft)",  kit = "ALARM_CLOCK_WARNING_3",          id = 12889 },
  { key = "clock2",  label = "Alarm clock",         kit = "ALARM_CLOCK_WARNING_2",          id = 12867 },
  { key = "ready",   label = "Ready check",         kit = "READY_CHECK",                    id = 8960 },
  { key = "emote",   label = "Boss emote",          kit = "RAID_BOSS_EMOTE_WARNING",        id = 12197 },
  { key = "pvp",     label = "Battleground ready",  kit = "PVP_THROUGH_QUEUE",              id = 8458 },
  { key = "horn",    label = "Raid warning (horn)", kit = "RAID_WARNING",                   id = 8959 },
}
local function soundIndex()
  for i, snd in ipairs(SOUNDS) do if snd.key == db.warnSoundKey then return i end end
  return #SOUNDS -- default: the horn, as before
end
local function playWarnSound(i)
  local snd = SOUNDS[i or soundIndex()]
  local id = (SOUNDKIT and SOUNDKIT[snd.kit]) or snd.id
  pcall(PlaySound, id, "Master")
end

-- refresh warning sound: once per DoT when it drops under the warning time
local function checkWarnings(t)
  if db.warn == false or not db.warnSound then return end
  local tg = keyOf("target")
  for g, m in pairs(mobs) do
    for _, d in pairs(m.dots) do
      local left = d.expires - t
      if not d.warned and left > 0 and left <= (db.warnTime or 3) and not d.lost and not d.info.def.cc then
        d.warned = true
        if not db.warnTargetOnly or g == tg then
          playWarnSound()
        end
      end
    end
  end
end

local drawErrors = 0
local preview -- set up by the options window: { canvas, box, list, tg }

local function layout()
  dirty = false
  local list, tg = sortedMobs()
  local okD, h, w = pcall(drawCanvas, main, list, tg, db.style)
  if not okD then
    -- one bad draw must not take the window down for the rest of the session
    if drawErrors < 5 then dbg("DRAW ERROR " .. tostring(h)) end
    drawErrors = drawErrors + 1
    h, w = 0, 200
  end
  local empty = #list == 0
  anchorBg:SetShown(not db.locked)
  anchorText:SetShown(not db.locked and empty)
  frame:EnableMouse(not db.locked)
  frame:SetSize(math.max(w, 160), math.max(h, ROW_H))
  local ooc = not LOOK.inCombat and db.locked
  frame:SetShown((not empty or not db.locked) and not (ooc and db.ooc == "hide"))
  frame:SetAlpha(ooc and db.ooc == "fade" and 0.4 or 1)
  layoutPlates(function(name) return sameNameCount(name) end, LETTERS)
  if preview and preview.box:IsVisible() then preview.redraw() end
end

local function updateBars()
  local t = now()
  updatePlateTimes(t)
  updateCanvas(main, t)
  checkWarnings(t)
  if preview and preview.box:IsVisible() then preview.tick(t) end
end

---------------------------------------------------------------------------
-- HP % next to each enemy's name (green -> yellow -> red)
---------------------------------------------------------------------------
-- Forever keeps enemy health secret. Plain numbers are used if readable; otherwise
-- the secret percentage is handed straight to the font string (the game may draw
-- secret values even though addons can't read them). The first result is logged.
local hpLogged = {}
local function hpLog(key, msg)
  if hpLogged[key] then return end
  hpLogged[key] = true
  dbg("HP " .. msg)
end

local PCT_CURVE = CurveConstants and CurveConstants.ScaleTo100
local colorCurve
if C_CurveUtil and C_CurveUtil.CreateColorCurve and CreateColor then
  local ok, c = pcall(C_CurveUtil.CreateColorCurve)
  if ok and c then
    pcall(function()
      c:AddPoint(0.0, CreateColor(1.0, 0.15, 0.15))
      c:AddPoint(0.5, CreateColor(1.0, 0.95, 0.10))
      c:AddPoint(1.0, CreateColor(0.15, 1.0, 0.15))
    end)
    colorCurve = c
  end
end

local function gradient(p)
  if p >= 0.5 then return (1 - p) * 2, 1, 0.15 end
  return 1, p * 2, 0.15
end

local function setHP(fs, unit)
  if not unit then fs:SetText("") return end
  local ok1, cur = pcall(UnitHealth, unit)
  local ok2, max = pcall(UnitHealthMax, unit)
  if ok1 and ok2 and num(cur) and num(max) and max > 0 then
    local p = cur / max
    fs:SetFormattedText("%d%%", math.floor(p * 100 + 0.5))
    fs:SetTextColor(gradient(p))
    hpLog("plain", "readable: UnitHealth/UnitHealthMax")
    return
  end
  if UnitHealthPercent then
    local ok, p = pcall(UnitHealthPercent, unit, false, PCT_CURVE)
    if ok and p ~= nil then
      if num(p) then
        local frac = PCT_CURVE and p / 100 or (p <= 1 and p or p / 100)
        fs:SetFormattedText("%d%%", math.floor(frac * 100 + 0.5))
        fs:SetTextColor(gradient(frac))
        hpLog("pct", "readable: UnitHealthPercent")
        return
      elseif PCT_CURVE then
        local okText, err = pcall(fs.SetFormattedText, fs, "%.0f%%", p)
        if okText then
          local colored = false
          if colorCurve then
            local okC, c = pcall(UnitHealthPercent, unit, false, colorCurve)
            if okC and c then colored = pcall(function() fs:SetTextColor(c:GetRGB()) end) end
          end
          if not colored then fs:SetTextColor(1, 1, 1) end
          hpLog("secret", "secret percentage drawn by the game" .. (colored and ", color via curve" or ", no color"))
          return
        end
        hpLog("secretfail", "secret percentage could not be drawn: " .. tostring(err))
      else
        hpLog("nocurve", "UnitHealthPercent is secret and no ScaleTo100 curve exists")
      end
    elseif not ok then
      hpLog("pcterr", "UnitHealthPercent error: " .. tostring(p))
    end
  else
    hpLog("none", "health is secret and UnitHealthPercent does not exist")
  end
  fs:SetText("")
end

local function updateHP()
  for _, h in ipairs(main.headers) do
    local m = h.mob
    if m and h:IsShown() then setHP(h.hp, db.showHP ~= false and m.unit or nil) end
  end
end

local scanElapsed = 0
local ticker = CreateFrame("Frame") -- separate, so it keeps running while the window is hidden
ticker:SetScript("OnUpdate", function(_, elapsed)
  if not db then return end
  scanElapsed = scanElapsed + elapsed
  if scanElapsed >= 0.2 then
    scanElapsed = 0
    scan()
    updateHP()
  end
  if dirty then layout() end
  updateBars()
end)

local initSettings, openOptions -- defined with the options window further down

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
local function reg(e) pcall(ev.RegisterEvent, ev, e) end
for _, e in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED", "PLAYER_TARGET_CHANGED",
  "UNIT_COMBAT", "UNIT_AURA", "SPELLS_CHANGED", "LEARNED_SPELL_IN_TAB", "CHARACTER_POINTS_CHANGED",
  "PLAYER_TALENT_UPDATE", "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED" }) do
  reg(e)
end
for _, e in ipairs({ "UNIT_SPELLCAST_SENT", "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_FAILED",
  "UNIT_SPELLCAST_FAILED_QUIET", "UNIT_SPELLCAST_INTERRUPTED" }) do
  pcall(ev.RegisterUnitEvent, ev, e, "player")
end

local bookTimer
local function scheduleBookScan(why)
  if bookTimer then return end
  bookTimer = true
  C_Timer.After(0.5, function()
    bookTimer = nil
    scanSpellbook(why)
  end)
end

ev:SetScript("OnEvent", function(_, event, ...)
  if event == "ADDON_LOADED" then
    if ... ~= ADDON_NAME then return end
    DotWatchDB = DotWatchDB or {}
    db = DotWatchDB
    db.learned = db.learned or {}
    db.immune = db.immune or {}
    db.castKnown = db.castKnown or {}
    db.debugPrev = db.debug -- the previous session's log stays readable after a /reload
    db.debug = {}
    if db.chat == nil then db.chat = true end
    if db.locked == nil then db.locked = false end
    if db.plates == nil then db.plates = true end
    if db.plateDots == nil then db.plateDots = false end
    db.plateY = db.plateY or 4
    -- 0.1 stored immunities per spell ID; 0.2 stores them per spell name
    for npc, t in pairs(db.immune) do
      for k in pairs(t) do if type(k) == "number" then t[k] = nil end end
    end
    frame:ClearAllPoints()
    if db.pos then
      frame:SetPoint(db.pos[1], UIParent, db.pos[2], db.pos[3], db.pos[4])
    else
      frame:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
    end
    initSettings()
    dirty = true
    dbg("LOADED " .. VERSION)
    say(VERSION .. " loaded. /dw for options, /dw help for commands.")
    return
  end
  if not db then return end

  if event == "UNIT_SPELLCAST_SENT" then
    local _, destName, castGUID, spellID = ...
    onSent(destName, castGUID, spellID)
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
    local _, castGUID, spellID = ...
    onSucceeded(castGUID, spellID)
  elseif event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_FAILED_QUIET"
      or event == "UNIT_SPELLCAST_INTERRUPTED" then
    local _, castGUID = ...
    castGUID = str(castGUID)
    if castGUID then pending[castGUID] = nil end
  elseif event == "UNIT_COMBAT" then
    onUnitCombat(...)
  elseif event == "UNIT_AURA" then
    onUnitAura(...)
  elseif event == "PLAYER_TARGET_CHANGED" then
    targetKey = nil
    dirty = true
  elseif event == "NAME_PLATE_UNIT_ADDED" then
    local u = ...
    if type(u) == "string" and not issecret(u) then plateKey[u] = nil end -- a new enemy on this token
    dirty = true
  elseif event == "NAME_PLATE_UNIT_REMOVED" then
    local u = ...
    if type(u) == "string" and not issecret(u) then
      local k = plateKey[u]
      plateKey[u] = nil
      if k and mobs[k] then
        if plain(UnitIsDead, u) == true then
          removeMob(k, "dead (nameplate gone)")
        else
          mobs[k].offPlate = true -- out of sight: keep its timers, it can't be recognized again
        end
      end
    end
    dirty = true
  elseif event == "PLAYER_REGEN_DISABLED" then
    LOOK.inCombat = true
    fight.start, fight.casts, fight.resisted, fight.immune, fight.refreshes, fight.lost = now(), 0, 0, 0, 0, 0
    dirty = true
  elseif event == "PLAYER_REGEN_ENABLED" then
    LOOK.inCombat = false
    -- don't wipe: the out-of-combat sync checks the real debuffs instead
    if next(mobs) then dbg("COMBAT END: timers kept, checking real debuffs") end
    wipe(pending)
    if db.summary and fight.casts > 0 then
      local secs = math.floor(now() - fight.start + 0.5)
      say(string.format("Fight %d:%02d - %d DoTs cast, %d refreshed, %d resisted, %d immune%s",
        math.floor(secs / 60), secs % 60, fight.casts, fight.refreshes, fight.resisted, fight.immune,
        fight.lost > 0 and (", " .. fight.lost .. " lost?") or ""))
    end
    dirty = true
  elseif event == "PLAYER_LOGIN" then
    scanSpellbook("login")
  else
    scheduleBookScan(event)
  end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local function testBars()
  local t = now()
  local samples = {
    { "Test-0-0-0-0-1-AAA", "Glassweb Spider", { "Corruption", "Bane of Agony" }, { 6, 2 } },
    { "Test-0-0-0-0-1-BBB", "Glassweb Spider", { "Immolate" }, { 9 } },
    { "Test-0-0-0-0-2-CCC", "Blackrock Bootlegger", { "Corruption" }, { 1 } },
  }
  for _, s in ipairs(samples) do
    local m = getMob(s[1], s[2])
    for i, name in ipairs(s[3]) do
      local id = type(known[name]) == "number" and known[name] or nil
      local def = DEF_BY_NAME[name]
      local info = (id and spellInfo(id)) or { id = -i, name = name, def = def, slot = def.slot,
        group = def.group, color = def.color, icon = 136197 }
      local dur = id and durationOf(info) or def.dur
      m.dots[info.id] = { info = info, start = t - s[4][i], expires = t - s[4][i] + dur, confirmed = true }
    end
  end
  addFlash(mobs["Test-0-0-0-0-2-CCC"], "Bane of Agony: Resisted", 1, 0.3, 0.3)
  say("Test timers shown. They run out on their own or end when you leave combat.")
end

---------------------------------------------------------------------------
-- Options window (classic look: marble background, gold dialog border,
-- header plate, classic checkboxes, slider and red buttons)
---------------------------------------------------------------------------
local BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil
local opt -- the options frame
local controls = {}

local function tryTemplate(kind, parent, template)
  local ok, f = pcall(CreateFrame, kind, nil, parent, template)
  if ok and f then return f, true end
  return CreateFrame(kind, nil, parent), false
end

local function tip(widget, title, text)
  widget:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(title, 1, 0.82, 0)
    if text then GameTooltip:AddLine(text, 1, 1, 1, true) end
    GameTooltip:Show()
  end)
  widget:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function makeButton(parent, label, width, onClick)
  local b, templated = tryTemplate("Button", parent, "UIPanelButtonTemplate")
  b:SetSize(width, 22)
  if not templated then
    b:SetNormalTexture("Interface\\Buttons\\UI-Panel-Button-Up")
    b:SetPushedTexture("Interface\\Buttons\\UI-Panel-Button-Down")
    b:SetHighlightTexture("Interface\\Buttons\\UI-Panel-Button-Highlight", "ADD")
    for _, t in ipairs({ b:GetNormalTexture(), b:GetPushedTexture(), b:GetHighlightTexture() }) do
      t:SetTexCoord(0, 0.625, 0, 0.6875)
    end
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("CENTER")
    b:SetFontString(fs)
  end
  b:SetText(label)
  b:SetScript("OnClick", onClick)
  return b
end

local function makeCheck(parent, label, help, get, set)
  local cb = CreateFrame("CheckButton", nil, parent)
  cb:SetSize(26, 26)
  cb:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
  cb:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
  cb:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
  cb:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
  cb.text = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  cb.text:SetPoint("LEFT", cb, "RIGHT", 2, 1)
  cb.text:SetText(label)
  cb:SetHitRectInsets(0, -(cb.text:GetStringWidth() + 6), 0, 0)
  cb:SetScript("OnClick", function(self)
    set(self:GetChecked() and true or false)
    dirty = true
  end)
  tip(cb, label, help)
  cb.refresh = function() cb:SetChecked(get() and true or false) end
  controls[#controls + 1] = cb
  return cb
end

local function makeSlider(parent, label, minV, maxV, step, fmt, get, set)
  local show = type(fmt) == "function" and fmt or function(v) return string.format(fmt, v) end
  local s = CreateFrame("Slider", nil, parent, BACKDROP_TEMPLATE)
  s:SetOrientation("HORIZONTAL")
  s:SetSize(220, 17)
  s:SetMinMaxValues(minV, maxV)
  s:SetValueStep(step)
  pcall(s.SetObeyStepOnDrag, s, true)
  s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
  if s.SetBackdrop then
    s:SetBackdrop({ bgFile = "Interface\\Buttons\\UI-SliderBar-Background",
      edgeFile = "Interface\\Buttons\\UI-SliderBar-Border", tile = true, tileSize = 8, edgeSize = 8,
      insets = { left = 3, right = 3, top = 6, bottom = 6 } })
  else
    local bg = s:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Buttons\\UI-SliderBar-Background")
    bg:SetPoint("TOPLEFT", 3, -6)
    bg:SetPoint("BOTTOMRIGHT", -3, 6)
  end
  s.title = s:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  s.title:SetPoint("BOTTOMLEFT", s, "TOPLEFT", 0, 3)
  s.title:SetText(label)
  s.value = s:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  s.value:SetPoint("LEFT", s, "RIGHT", 8, 0)
  local lo = s:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  lo:SetPoint("TOPLEFT", s, "BOTTOMLEFT", 2, 0)
  lo:SetText(show(minV))
  local hi = s:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hi:SetPoint("TOPRIGHT", s, "BOTTOMRIGHT", -2, 0)
  hi:SetText(show(maxV))
  local busy = false
  s:SetScript("OnValueChanged", function(self, v)
    v = math.floor(v / step + 0.5) * step
    self.value:SetText(show(v))
    if not busy then set(v) dirty = true end
  end)
  s.refresh = function()
    busy = true
    s:SetValue(get())
    s.value:SetText(show(get()))
    busy = false
  end
  controls[#controls + 1] = s
  return s
end

-- section heading with a thin gold line; x/lineEnd let a page have two columns
local function makeSection(parent, label, y, x, lineEnd)
  local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x or 24, y)
  fs:SetText(label)
  local line = parent:CreateTexture(nil, "ARTWORK")
  line:SetColorTexture(1, 0.82, 0, 0.25)
  line:SetHeight(1)
  line:SetPoint("LEFT", fs, "RIGHT", 8, 0)
  if lineEnd then
    line:SetPoint("RIGHT", parent, "LEFT", lineEnd, 0)
  else
    line:SetPoint("RIGHT", parent, "RIGHT", -24, 0)
  end
  return fs
end

local updateMinimapButton -- set below

local function applySettings()
  frame:SetScale(db.scale or 1)
  if updateMinimapButton then updateMinimapButton() end
  dirty = true
end

local function knownList()
  local names = {}
  for _, s in ipairs(SPELLS) do
    if known[s.name] then names[#names + 1] = s.name end
  end
  if #names == 0 then return "|cff888888nothing found yet|r" end
  local text = table.concat(names, ", ")
  if not known["Siphon Life"] then text = text .. "  |cff888888(no Siphon Life)|r" end
  return text
end

local function makeRadio(parent, label, help, value, get, set)
  local rb = CreateFrame("CheckButton", nil, parent)
  rb:SetSize(16, 16)
  rb:SetNormalTexture("Interface\\Buttons\\UI-RadioButton")
  rb:GetNormalTexture():SetTexCoord(0, 0.25, 0, 1)
  rb:SetCheckedTexture("Interface\\Buttons\\UI-RadioButton")
  rb:GetCheckedTexture():SetTexCoord(0.25, 0.5, 0, 1)
  rb:SetHighlightTexture("Interface\\Buttons\\UI-RadioButton", "ADD")
  rb:GetHighlightTexture():SetTexCoord(0.5, 0.75, 0, 1)
  rb.text = rb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  rb.text:SetPoint("LEFT", rb, "RIGHT", 4, 0)
  rb.text:SetText(label)
  rb:SetHitRectInsets(0, -(rb.text:GetStringWidth() + 6), -2, -2)
  rb:SetScript("OnClick", function()
    set(value)
    for _, c in ipairs(controls) do c.refresh() end
    dirty = true
  end)
  tip(rb, label, help)
  rb.refresh = function() rb:SetChecked(get() == value) end
  controls[#controls + 1] = rb
  return rb
end

-- sample fight for the preview: same three enemies as the mockups
local function buildSample()
  local t = now()
  local function info(name)
    local id = type(known[name]) == "number" and known[name] or nil
    local i = id and spellInfo(id)
    if i then return i end
    local def = DEF_BY_NAME[name]
    return { id = -#name, name = name, def = def, slot = def.slot, group = def.group, color = def.color, icon = 136197 }
  end
  local function dot(name, left, total)
    local i = info(name)
    return i.id, { info = i, start = t - (total - left), expires = t + left, confirmed = true }
  end
  local banes = { "Bane of Agony", "Curse of Agony" }
  local bane = known["Bane of Agony"] and banes[1] or (known["Curse of Agony"] and banes[2]) or banes[1]
  local function mob(guid, name, letter, hp, created, spec, flash)
    local m = { guid = guid, name = name, letter = letter, created = created, fakeHP = hp, dots = {}, flash = {} }
    for _, x in ipairs(spec) do
      local id, d = dot(x[1], x[2], x[3])
      m.dots[id] = d
    end
    if flash then m.flash[1] = { text = flash, r = 1, g = 0.3, b = 0.3, expires = t + 9999 } end
    return m
  end
  local list = {
    mob("preview-A", "Slave Worker", 1, 72, 1, { { "Corruption", 11.4, 18 }, { bane, 19.2, 24 } }),
    mob("preview-B", "Slave Worker", 2, 45, 2, { { "Corruption", 4.2, 18 }, { "Immolate", 9.6, 15 }, { bane, 2.1, 24 } }),
    mob("preview-C", "Dark Iron Taskmaster", 1, 18, 3, { { bane, 14.0, 24 } }, "Immolate: Resisted"),
  }
  if known["Siphon Life"] then
    local id, d = dot("Siphon Life", 22, 30)
    list[1].dots[id] = d
  end
  return list, "preview-A"
end

-- a row of radio buttons with a label in front: { {value, label, help}, ... }
local function radioRow(parent, label, x, y, items, get, set)
  local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  fs:SetPoint("TOPLEFT", x, y - 2)
  fs:SetText(label)
  local rx = x + 96
  for _, it in ipairs(items) do
    local rb = makeRadio(parent, it[2], it[3], it[1], get, set)
    rb:SetPoint("TOPLEFT", rx, y)
    rx = rx + 26 + rb.text:GetStringWidth() + 14
  end
end

-- the game's color picker (old and new API)
local function pickColor(r, g, b, onChange)
  local cpf = ColorPickerFrame
  if not cpf then return end
  local function cur() return cpf:GetColorRGB() end
  if cpf.SetupColorPickerAndShow then
    cpf:SetupColorPickerAndShow({ r = r, g = g, b = b, hasOpacity = false,
      swatchFunc = function() onChange(cur()) end, cancelFunc = function() onChange(r, g, b) end })
  else
    cpf.hasOpacity = false
    cpf.previousValues = { r, g, b }
    cpf.func = function() onChange(cur()) end
    cpf.cancelFunc = function() onChange(r, g, b) end
    cpf:SetColorRGB(r, g, b)
    cpf:Hide()
    cpf:Show()
  end
  pcall(cpf.SetFrameStrata, cpf, "FULLSCREEN_DIALOG")
end

-- page: Look (font size, bar texture, colors per DoT); the preview sits on the right
local function buildLookPage(pg, COL)
  makeSection(pg, "Font size", -54, 24, COL)
  local rx = 28
  for _, key in ipairs(LOOK.FONT_ORDER) do
    local rb = makeRadio(pg, LOOK.FONTS[key].label, "Text size in the list.", key,
      function() return db.fontSize or "small" end, function(v) db.fontSize = v end)
    rb:SetPoint("TOPLEFT", rx, -78)
    rx = rx + 26 + rb.text:GetStringWidth() + 10
  end

  makeSection(pg, "Bar texture", -110, 24, COL)
  local ty = -134
  for _, t in ipairs(LOOK.TEXTURES) do
    makeRadio(pg, t.label, "Texture of the bars (Bars and Slim bars styles).", t.key,
      function() return db.texture or "classic" end, function(v) db.texture = v end):SetPoint("TOPLEFT", 28, ty)
    local sw = pg:CreateTexture(nil, "ARTWORK")
    sw:SetTexture(t.file)
    sw:SetVertexColor(0.62, 0.30, 0.95)
    sw:SetSize(70, 10)
    sw:SetPoint("TOPLEFT", 140, ty - 3)
    ty = ty - 22
  end

  makeSection(pg, "DoT colors", ty - 10, 24, COL)
  ty = ty - 34
  local swatches = {}
  local col = 0
  for _, sp in ipairs(SPELLS) do
    local sx = 28 + col * 104
    local btn = CreateFrame("Button", nil, pg)
    btn:SetSize(100, 18)
    btn:SetPoint("TOPLEFT", sx, ty)
    btn.sw = btn:CreateTexture(nil, "ARTWORK")
    btn.sw:SetSize(14, 14)
    btn.sw:SetPoint("LEFT")
    btn.edge = btn:CreateTexture(nil, "BACKGROUND")
    btn.edge:SetColorTexture(0, 0, 0, 1)
    btn.edge:SetPoint("TOPLEFT", btn.sw, -1, 1)
    btn.edge:SetPoint("BOTTOMRIGHT", btn.sw, 1, -1)
    btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btn.text:SetPoint("LEFT", btn.sw, "RIGHT", 4, 0)
    btn.text:SetWidth(80)
    btn.text:SetJustifyH("LEFT")
    btn.text:SetText((sp.name:gsub("^Curse of ", "C. of "):gsub("^Bane of ", "B. of ")))
    btn:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    btn.sp = sp
    btn:SetScript("OnClick", function(self)
      local c = LOOK.color(self.sp)
      pickColor(c[1], c[2], c[3], function(r, g, b)
        db.colors[self.sp.name] = { r, g, b }
        self.sw:SetColorTexture(r, g, b)
        dirty = true
      end)
    end)
    tip(btn, sp.name, "Click to pick its color.")
    btn.refresh = function()
      local c = LOOK.color(btn.sp)
      btn.sw:SetColorTexture(c[1], c[2], c[3])
      btn:SetShown(known[btn.sp.name] ~= nil)
    end
    controls[#controls + 1] = btn
    swatches[#swatches + 1] = btn
  end
  -- lay out only the known spells, two per row
  pg:HookScript("OnShow", function()
    local i, y0 = 0, ty
    for _, btn in ipairs(swatches) do
      btn.refresh()
      if btn:IsShown() then
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", 28 + (i % 2) * 104, y0 - math.floor(i / 2) * 20)
        i = i + 1
      end
    end
  end)
  local reset = makeButton(pg, "Default colors", 120, function()
    wipe(db.colors)
    for _, c in ipairs(controls) do c.refresh() end
    dirty = true
  end)
  reset:SetPoint("BOTTOMLEFT", 24, 6)
end

-- page: Timers (refresh warning, ticks, lost, control spells)
local function buildTimersPage(pg)
  local y = -54
  makeSection(pg, "Refresh warning", y)
  y = y - 22
  makeCheck(pg, "Pulse DoTs that are about to run out", "The DoT blinks softly in the last seconds.",
    function() return db.warn ~= false end, function(v) db.warn = v end):SetPoint("TOPLEFT", 26, y)
  y = y - 44
  makeSlider(pg, "Warn when less than", 1, 6, 1, "%d s",
    function() return db.warnTime or 3 end, function(v) db.warnTime = v end):SetPoint("TOPLEFT", 30, y)
  y = y - 36
  makeCheck(pg, "Play a sound", "A short warning sound once per DoT.",
    function() return db.warnSound end, function(v) db.warnSound = v end):SetPoint("TOPLEFT", 26, y)
  makeCheck(pg, "Sound only for my target", "No sounds for the other enemies.",
    function() return db.warnTargetOnly ~= false end, function(v) db.warnTargetOnly = v end):SetPoint("TOPLEFT", 250, y)
  y = y - 32
  -- sound choice: < name > and a test button, list goes from soft to loud
  local sl = pg:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  sl:SetPoint("TOPLEFT", 32, y - 5)
  sl:SetText("Sound:")
  local name = pg:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  local pos = pg:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  local function show()
    local i = soundIndex()
    name:SetText(SOUNDS[i].label)
    pos:SetText(i .. " / " .. #SOUNDS .. "  (soft > loud)")
  end
  local function step(dir)
    local i = soundIndex() + dir
    if i < 1 then i = #SOUNDS elseif i > #SOUNDS then i = 1 end
    db.warnSoundKey = SOUNDS[i].key
    show()
    playWarnSound(i)
  end
  local prevB = makeButton(pg, "<", 26, function() step(-1) end)
  prevB:SetPoint("TOPLEFT", 80, y)
  name:SetPoint("LEFT", prevB, "RIGHT", 8, 0)
  name:SetWidth(150)
  name:SetJustifyH("CENTER")
  local nextB = makeButton(pg, ">", 26, function() step(1) end)
  nextB:SetPoint("LEFT", prevB, "RIGHT", 166, 0)
  local testB = makeButton(pg, "Test", 60, function() playWarnSound() end)
  testB:SetPoint("LEFT", nextB, "RIGHT", 10, 0)
  pos:SetPoint("LEFT", testB, "RIGHT", 10, 0)
  pg:HookScript("OnShow", show)
  show()
  y = y - 36

  makeSection(pg, "Ticks", y)
  y = y - 22
  makeCheck(pg, "Tick marks on the bars", "A thin line for every damage tick still to come (Bars and Slim bars).",
    function() return db.ticks ~= false end, function(v) db.ticks = v end):SetPoint("TOPLEFT", 26, y)
  y = y - 26
  makeCheck(pg, "Mark DoTs as \"lost?\" when their ticks stop", "If an enemy you can see takes no more ticks of a DoT's school, the DoT was probably removed.",
    function() return db.lostCheck ~= false end, function(v) db.lostCheck = v end):SetPoint("TOPLEFT", 26, y)
  y = y - 36

  makeSection(pg, "Control", y)
  y = y - 22
  makeCheck(pg, "Timers for Fear, Banish, Enslave Demon and Death Coil", "Shown like curses, below the DoTs of that enemy.",
    function() return db.trackCC ~= false end, function(v) db.trackCC = v wipe(spellCache) end):SetPoint("TOPLEFT", 26, y)
end

-- page: Statistics (resists per enemy type, fight summary)
local function buildStatsPage(pg)
  local y = -54
  makeSection(pg, "Statistics", y)
  y = y - 22
  makeCheck(pg, "Record resists per enemy type", "Counts casts, resists and immunes per enemy type and spell.",
    function() return db.recordStats ~= false end, function(v) db.recordStats = v end):SetPoint("TOPLEFT", 26, y)
  makeCheck(pg, "Fight summary in chat", "One line after each fight: DoTs cast, refreshed, resisted, immune.",
    function() return db.summary end, function(v) db.summary = v end):SetPoint("TOPLEFT", 250, y)
  y = y - 34

  local box = CreateFrame("Frame", nil, pg, BACKDROP_TEMPLATE)
  box:SetPoint("TOPLEFT", 24, y)
  box:SetPoint("BOTTOMRIGHT", -24, 36)
  if box.SetBackdrop then
    box:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    box:SetBackdropColor(0.08, 0.06, 0.04, 0.9)
    box:SetBackdropBorderColor(0.6, 0.5, 0.3, 1)
  end
  local ok, sf = pcall(CreateFrame, "ScrollFrame", "DotWatchStatsScroll", box, "UIPanelScrollFrameTemplate")
  if not ok then sf = CreateFrame("ScrollFrame", nil, box) end
  sf:SetPoint("TOPLEFT", 8, -8)
  sf:SetPoint("BOTTOMRIGHT", -28, 8)
  local content = CreateFrame("Frame", nil, sf)
  content:SetSize(440, 10)
  sf:SetScrollChild(content)
  local text = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  text:SetPoint("TOPLEFT")
  text:SetWidth(430)
  text:SetJustifyH("LEFT")
  text:SetSpacing(2)

  local function fill()
    local rows = {}
    for npc, e in pairs(db.stats) do
      local total = 0
      for _, sp in pairs(e.s) do total = total + sp.c end
      rows[#rows + 1] = { e = e, total = total }
    end
    table.sort(rows, function(a, b) return a.total > b.total end)
    local lines = {}
    for _, r in ipairs(rows) do
      lines[#lines + 1] = "|cffffd100" .. (r.e.name or "?") .. "|r"
      local names = {}
      for name in pairs(r.e.s) do names[#names + 1] = name end
      table.sort(names)
      for _, name in ipairs(names) do
        local sp = r.e.s[name]
        local resisted = sp.c > 0 and math.floor(sp.r / sp.c * 100 + 0.5) or 0
        local parts = { string.format("%d cast%s", sp.c, sp.c == 1 and "" or "s") }
        if sp.r > 0 then parts[#parts + 1] = string.format("|cffff7755%d resisted (%d%%)|r", sp.r, resisted) end
        if sp.i > 0 then parts[#parts + 1] = string.format("|cffcc5555%d immune|r", sp.i) end
        lines[#lines + 1] = "    " .. name .. ": " .. table.concat(parts, ", ")
      end
    end
    if #lines == 0 then lines[1] = "|cff888888Nothing recorded yet. Fight something!|r" end
    text:SetText(table.concat(lines, "\n"))
    content:SetHeight(math.max((text:GetStringHeight() or 0) + 10, 10))
  end
  pg:HookScript("OnShow", fill)

  -- 0.9.1: inline confirmation instead of a StaticPopup. Writing to the global
  -- StaticPopupDialogs tainted Blizzard's Escape handling (SpellStopCasting forbidden).
  local reset, yes, no, ask
  local function setAsking(on)
    reset:SetShown(not on)
    yes:SetShown(on) no:SetShown(on) ask:SetShown(on)
  end
  reset = makeButton(pg, "Reset statistics", 140, function() setAsking(true) end)
  reset:SetPoint("BOTTOMLEFT", 24, 6)
  ask = pg:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  ask:SetPoint("BOTTOMLEFT", 26, 11)
  ask:SetText("Delete all statistics and known immunities?")
  yes = makeButton(pg, YES or "Yes", 60, function()
    wipe(db.stats) wipe(db.immune) fill() dirty = true
    setAsking(false)
  end)
  yes:SetPoint("LEFT", ask, "RIGHT", 10, 0)
  no = makeButton(pg, NO or "No", 60, function() setAsking(false) end)
  no:SetPoint("LEFT", yes, "RIGHT", 4, 0)
  setAsking(false)
  pg:HookScript("OnHide", function() setAsking(false) end)
end

local function buildOptions()
  local f = CreateFrame("Frame", "DotWatchOptions", UIParent, BACKDROP_TEMPLATE)
  f:SetSize(700, 480)
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  f:SetToplevel(true)
  f:EnableMouse(true)
  f:SetMovable(true)
  f:SetClampedToScreen(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  if f.SetBackdrop then
    f:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 32,
      insets = { left = 11, right = 12, top = 12, bottom = 11 } })
  else
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Background-Dark")
    bg:SetPoint("TOPLEFT", 11, -12)
    bg:SetPoint("BOTTOMRIGHT", -12, 11)
  end
  -- Escape closes it. 0.9.1: no longer via UISpecialFrames (an addon entry there is
  -- tainted data that Blizzard's Escape code reads). The window catches Escape itself;
  -- SetPropagateKeyboardInput is blocked in combat, so in combat it lets every key through.
  f:SetScript("OnKeyDown", function(self, key)
    if InCombatLockdown() then return end
    if key == "ESCAPE" then
      self:SetPropagateKeyboardInput(false)
      self:Hide()
    else
      self:SetPropagateKeyboardInput(true)
    end
  end)
  f:RegisterEvent("PLAYER_REGEN_DISABLED")
  f:SetScript("OnEvent", function(self) self:EnableKeyboard(false) end)

  local header = f:CreateTexture(nil, "ARTWORK")
  header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
  header:SetSize(300, 64)
  header:SetPoint("TOP", 0, 12)
  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOP", header, "TOP", 0, -14)
  title:SetText("DotWatch")

  local close, templated = tryTemplate("Button", f, "UIPanelCloseButton")
  if not templated then
    close:SetSize(32, 32)
    close:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
    close:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
    close:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight", "ADD")
  end
  close:SetPoint("TOPRIGHT", -6, -6)
  close:SetScript("OnClick", function() f:Hide() end)

  local sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  sub:SetPoint("TOP", 0, -30)
  sub:SetText("Your damage over time, per enemy.  |cff888888v" .. VERSION .. "|r")

  -- pages on the right, chosen in the list on the left
  local NAV_W = 160
  local pages = {}
  for i = 1, 5 do
    local pg = CreateFrame("Frame", nil, f)
    pg:SetPoint("TOPLEFT", NAV_W, 0)
    pg:SetPoint("BOTTOMRIGHT", 0, 50)
    pages[i] = pg
  end

  ---------------- page 1: General ----------------
  local g = pages[1]
  local y = -54
  makeSection(g, "Window", y)
  y = y - 22
  makeCheck(g, "Lock window", "Locked: the window only shows up while timers run and can't be dragged.",
    function() return db.locked end, function(v) db.locked = v end):SetPoint("TOPLEFT", 26, y)
  y = y - 30
  radioRow(g, "Grows", 30, y, {
    { "middle", "From the middle", "The list grows up and down from its center." },
    { "down", "Downward", "The top edge stays put." },
    { "up", "Upward", "The bottom edge stays put." },
  }, function() return db.grow or "middle" end, function(v) db.grow = v LOOK.anchor() end)
  y = y - 24
  radioRow(g, "Out of combat", 30, y, {
    { "show", "Show", "The list stays as it is." },
    { "fade", "Fade", "The list turns see-through out of combat (while locked)." },
    { "hide", "Hide", "The list only shows up in combat (while locked)." },
  }, function() return db.ooc or "show" end, function(v) db.ooc = v end)
  y = y - 34

  makeSection(g, "Nameplates", y)
  y = y - 22
  makeCheck(g, "Letter above the plate", "When several enemies share a name, show A, B, C … above their nameplates.",
    function() return db.plates end, function(v) db.plates = v end):SetPoint("TOPLEFT", 26, y)
  makeCheck(g, "DoT icons on plates", "Also show your running DoTs as small icons above the nameplate.",
    function() return db.plateDots end, function(v) db.plateDots = v end):SetPoint("TOPLEFT", 250, y)
  y = y - 44
  makeSlider(g, "Height above the plate", -20, 40, 1, "%d px",
    function() return db.plateY or 4 end, function(v) db.plateY = v end):SetPoint("TOPLEFT", 30, y)
  y = y - 40

  makeSection(g, "Messages", y)
  y = y - 22
  makeCheck(g, "Resists in chat", "Write a chat line when a DoT is resisted or the enemy is immune.",
    function() return db.chat end, function(v) db.chat = v end):SetPoint("TOPLEFT", 26, y)
  makeCheck(g, "Debug lines in chat", "For troubleshooting. The debug log is saved either way.",
    function() return db.debugChat end, function(v) db.debugChat = v end):SetPoint("TOPLEFT", 250, y)
  y = y - 26
  makeCheck(g, "Minimap button", "Show the eye at the minimap. /dw opens this window either way.",
    function() return not db.minimap.hide end, function(v) db.minimap.hide = not v applySettings() end):SetPoint("TOPLEFT", 26, y)
  y = y - 36

  makeSection(g, "Spells found", y)
  y = y - 20
  local spells = g:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  spells:SetPoint("TOPLEFT", 28, y)
  spells:SetPoint("RIGHT", g, "RIGHT", -28, 0)
  spells:SetJustifyH("LEFT")
  f.spells = spells

  ---------------- page 2: Display ----------------
  local dp = pages[2]
  local COL = 232 -- left column ends here, the preview starts after it
  makeSection(dp, "Style", -54, 24, COL)
  local ry = -78
  local helps = {
    bars = "A full bar per DoT with its name. Easiest to read, takes the most space.",
    slim = "Thin bars without names: the icon says which DoT. About half the height.",
    icons = "Like action-bar cooldowns: a dark sweep shows the time used, seconds on the icon.",
    table = "One line per enemy, one column per DoT. Best when you dot many mobs.",
    focus = "Your current target gets big icons, every other enemy one short line.",
  }
  for _, st in ipairs(STYLES) do
    makeRadio(dp, STYLE_NAMES[st], helps[st], st, function() return db.style or "bars" end,
      function(v) db.style = v end):SetPoint("TOPLEFT", 28, ry)
    ry = ry - 24
  end
  ry = ry - 10
  makeCheck(dp, "Gray placeholders", "Show the DoTs that are not on an enemy in gray.",
    function() return db.showPlaceholders ~= false end, function(v) db.showPlaceholders = v end):SetPoint("TOPLEFT", 24, ry)
  ry = ry - 26
  makeCheck(dp, "Health % next to the name", "Green when healthy, yellow at half, red when low.",
    function() return db.showHP ~= false end, function(v) db.showHP = v end):SetPoint("TOPLEFT", 24, ry)
  ry = ry - 36
  makeSection(dp, "Window size", ry, 24, COL)
  ry = ry - 24
  local function nearestSize()
    local best, bestD = 1, math.huge
    for _, sz in ipairs(SIZES) do
      local d = math.abs((db.scale or 1) - sz[1])
      if d < bestD then best, bestD = sz[1], d end
    end
    return best
  end
  for _, sz in ipairs(SIZES) do
    makeRadio(dp, sz[2], sz[3], sz[1], nearestSize,
      function(v) db.scale = v applySettings() end):SetPoint("TOPLEFT", 28, ry)
    ry = ry - 24
  end

  -- preview box on the right
  local box = CreateFrame("Frame", nil, dp, BACKDROP_TEMPLATE)
  box:SetPoint("TOPLEFT", COL + 16, -76)
  box:SetPoint("BOTTOMRIGHT", -22, 6)
  if box.SetBackdrop then
    box:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    box:SetBackdropColor(0.08, 0.06, 0.04, 0.9)
    box:SetBackdropBorderColor(0.6, 0.5, 0.3, 1)
  end
  makeSection(dp, "Preview", -54, COL + 16)
  local holder = CreateFrame("Frame", nil, box)
  holder:SetPoint("TOPLEFT", 12, -12)
  holder:SetSize(220, 300)
  local pv = { canvas = newCanvas(holder), box = box }
  pv.redraw = function()
    pv.list, pv.tg = buildSample()
    local h, w = drawCanvas(pv.canvas, pv.list, pv.tg, db.style)
    -- shrink the sample to fit the box
    local availW, availH = (box:GetWidth() or 240) - 24, (box:GetHeight() or 320) - 24
    local scale = math.min(1, availW / math.max(w, 1), availH / math.max(h, 1))
    holder:SetScale(scale > 0 and scale or 1)
    holder:SetSize(w, h)
  end
  pv.tick = function(t)
    for _, m in ipairs(pv.list or {}) do
      for _, d in pairs(m.dots) do
        if d.expires <= t then pv.redraw() return end -- loop the sample
      end
    end
    updateCanvas(pv.canvas, t)
  end
  preview = pv
  box:SetScript("OnShow", function() pv.redraw() end)

  ---------------- page 3: Look ----------------
  buildLookPage(pages[3], 232)
  makeSection(pages[3], "Preview", -54, 248)

  ---------------- page 4: Timers ----------------
  buildTimersPage(pages[4])

  ---------------- page 5: Statistics ----------------
  buildStatsPage(pages[5])

  ---------------- navigation list on the left ----------------
  local navBg = CreateFrame("Frame", nil, f, BACKDROP_TEMPLATE)
  navBg:SetPoint("TOPLEFT", 16, -50)
  navBg:SetPoint("BOTTOMRIGHT", f, "BOTTOMLEFT", NAV_W - 6, 50)
  if navBg.SetBackdrop then
    navBg:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    navBg:SetBackdropColor(0.05, 0.04, 0.03, 0.85)
    navBg:SetBackdropBorderColor(0.6, 0.5, 0.3, 1)
  end
  local navItems = {}
  local function select(i)
    for k, pg in ipairs(pages) do pg:SetShown(k == i) end
    for k, it in ipairs(navItems) do
      it.sel:SetShown(k == i)
      it.mark:SetShown(k == i)
      if k == i then it.label:SetTextColor(1, 1, 1) else it.label:SetTextColor(1, 0.82, 0) end
    end
    f.page = i
    if i == 2 or i == 3 then
      -- one preview, shown on the Display and the Look page
      box:SetParent(pages[i])
      box:ClearAllPoints()
      box:SetPoint("TOPLEFT", pages[i], "TOPLEFT", 248, -76)
      box:SetPoint("BOTTOMRIGHT", pages[i], "BOTTOMRIGHT", -22, 6)
      box:Show()
      pv.redraw()
    end
  end
  for i, label in ipairs({ "General", "Display", "Look", "Timers", "Statistics" }) do
    local it = CreateFrame("Button", nil, navBg)
    it:SetSize(NAV_W - 34, 24)
    it:SetPoint("TOPLEFT", 9, -10 - (i - 1) * 26)
    it.sel = it:CreateTexture(nil, "BACKGROUND")
    it.sel:SetAllPoints()
    it.sel:SetTexture("Interface\\QuestFrame\\UI-QuestLogTitleHighlight")
    it.sel:SetVertexColor(1, 0.82, 0, 0.45)
    it.sel:SetBlendMode("ADD")
    it.mark = it:CreateTexture(nil, "ARTWORK")
    it.mark:SetColorTexture(1, 0.82, 0, 1)
    it.mark:SetSize(2, 18)
    it.mark:SetPoint("LEFT", 0, 0)
    it.mark:SetShown(false)
    it:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    it.label = it:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    it.label:SetPoint("LEFT", 10, 0)
    it.label:SetText(label)
    it:SetScript("OnClick", function() select(i) end)
    navItems[i] = it
  end

  ---------------- buttons ----------------
  local bClose = makeButton(f, "Close", 100, function() f:Hide() end)
  bClose:SetPoint("BOTTOMRIGHT", -22, 18)
  local bReset = makeButton(f, "Reset position", 120, function()
    db.pos = nil
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
  end)
  bReset:SetPoint("RIGHT", bClose, "LEFT", -6, 0)
  local bTest = makeButton(f, "Test", 100, function() testBars() end)
  bTest:SetPoint("RIGHT", bReset, "LEFT", -6, 0)
  tip(bTest, "Test", "Shows sample timers in the real window so you can place it.")

  f:SetScript("OnShow", function(self)
    if InCombatLockdown() then
      self:EnableKeyboard(false)
    else
      self:EnableKeyboard(true)
      self:SetPropagateKeyboardInput(true)
    end
    for _, c in ipairs(controls) do c.refresh() end
    self.spells:SetText(knownList())
    select(self.page or 1)
  end)
  f:Hide()
  return f
end

local function toggleOptions()
  opt = opt or buildOptions()
  if opt:IsShown() then opt:Hide() else opt:Show() end
end

---------------------------------------------------------------------------
-- Minimap button: Eye of Kilrogg in the classic round tracking border
---------------------------------------------------------------------------
local mm
local function placeMinimapButton()
  local a = math.rad(db.minimap.angle or 200)
  local r = (Minimap:GetWidth() / 2) + 10
  mm:ClearAllPoints()
  mm:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end

local function createMinimapButton()
  if mm or not Minimap then return end
  mm = CreateFrame("Button", "DotWatchMinimapButton", Minimap)
  mm:SetSize(31, 31)
  mm:SetFrameStrata("MEDIUM")
  mm:SetFrameLevel(8)
  mm:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  mm:RegisterForDrag("LeftButton")
  mm:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  local overlay = mm:CreateTexture(nil, "OVERLAY")
  overlay:SetSize(53, 53)
  overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  overlay:SetPoint("TOPLEFT")
  local bg = mm:CreateTexture(nil, "BACKGROUND")
  bg:SetSize(20, 20)
  bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  bg:SetPoint("TOPLEFT", 7, -5)
  local icon = mm:CreateTexture(nil, "ARTWORK")
  icon:SetSize(17, 17)
  icon:SetTexture("Interface\\Icons\\Spell_Shadow_EvilEye")
  icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
  icon:SetPoint("TOPLEFT", 7, -6)
  mm.icon = icon

  mm:SetScript("OnClick", function(_, button)
    if button == "RightButton" then
      db.locked = not db.locked
      say(db.locked and "Window locked." or "Window unlocked, drag the purple box.")
      dirty = true
    else
      toggleOptions()
    end
  end)
  mm:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local px, py = GetCursorPosition()
      local s = Minimap:GetEffectiveScale()
      db.minimap.angle = math.deg(math.atan2(py / s - my, px / s - mx))
      placeMinimapButton()
    end)
  end)
  mm:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  mm:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("DotWatch", 1, 0.82, 0)
    GameTooltip:AddLine("Left-click: options", 1, 1, 1)
    GameTooltip:AddLine("Right-click: lock / unlock the window", 1, 1, 1)
    GameTooltip:AddLine("Drag: move this button", 0.6, 0.6, 0.6)
    GameTooltip:Show()
  end)
  mm:SetScript("OnLeave", function() GameTooltip:Hide() end)
  placeMinimapButton()
end

updateMinimapButton = function()
  if db.minimap.hide then
    if mm then mm:Hide() end
  else
    createMinimapButton()
    if mm then
      placeMinimapButton()
      mm:Show()
    end
  end
end

initSettings = function()
  db.minimap = db.minimap or {}
  if db.showPlaceholders == nil then db.showPlaceholders = true end
  if db.showHP == nil then db.showHP = true end
  db.scale = db.scale or 1
  db.style = db.style or "bars"
  -- 0.9: the target bar is gone (clicking can only ever reach the current target in Forever)
  for _, k in ipairs({ "targetBar", "tbAction", "tbLabel", "tbSize", "tbDockX", "tbDockY", "tbPos" }) do db[k] = nil end
  db.stats = db.stats or {}
  db.untracked = db.untracked or {}
  db.colors = db.colors or {}
  if db.warn == nil then db.warn = true end
  db.warnTime = db.warnTime or 3
  if db.warnTargetOnly == nil then db.warnTargetOnly = true end
  if db.ticks == nil then db.ticks = true end
  if db.lostCheck == nil then db.lostCheck = true end
  if db.trackCC == nil then db.trackCC = true end
  if db.recordStats == nil then db.recordStats = true end
  db.fontSize = db.fontSize or "small"
  db.texture = db.texture or "classic"
  db.grow = db.grow or "middle"
  db.ooc = db.ooc or "show"
  LOOK.inCombat = UnitAffectingCombat and plain(UnitAffectingCombat, "player") == true or false
  applySettings()
end
openOptions = toggleOptions

SLASH_DOTWATCH1 = "/dw"
SLASH_DOTWATCH2 = "/dotwatch"
SlashCmdList.DOTWATCH = function(msg)
  local cmd = ((msg or ""):match("^(%S*)") or ""):lower()
  if not db then return end
  if cmd == "" or cmd == "options" or cmd == "config" then
    openOptions()
  elseif cmd == "style" then
    local st = ((msg or ""):match("^%S+%s+(%S+)") or ""):lower()
    if STYLE_NAMES[st] then
      db.style = st
      dirty = true
      say("Style: " .. STYLE_NAMES[st])
    else
      say("Styles: " .. table.concat(STYLES, ", ") .. "  (e.g. /dw style icons)")
    end
  elseif cmd == "lock" then
    db.locked = not db.locked
    say(db.locked and "Locked. The window only shows up when timers run." or "Unlocked. Drag the purple box to move it.")
  elseif cmd == "reset" then
    db.pos = nil
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
    say("Position reset.")
  elseif cmd == "chat" then
    db.chat = not db.chat
    say("Resist/immune chat messages " .. (db.chat and "on" or "off"))
  elseif cmd == "test" then
    testBars()
  elseif cmd == "clear" then
    wipe(mobs)
    say("Timers cleared.")
  elseif cmd == "spells" then
    scanSpellbook("command")
    say("Spellbook read via " .. bookMethod .. ".")
    for _, s in ipairs(SPELLS) do
      if known[s.name] then say("  " .. s.name .. (type(known[s.name]) == "number" and (" (" .. known[s.name] .. ")") or "")) end
    end
    if not known["Siphon Life"] then say("  Siphon Life: not known") end
  elseif cmd == "learned" then
    local any = false
    for id, dur in pairs(db.learned) do
      any = true
      local info = spellInfo(id)
      say(string.format("%s (%d): %s sec", info and info.name or "?", id, tostring(dur)))
    end
    if not any then say("No durations learned yet (happens out of combat).") end
  elseif cmd == "plates" then
    db.plates = not db.plates
    say("Nameplate letters " .. (db.plates and "on" or "off"))
  elseif cmd == "platedots" then
    db.plateDots = not db.plateDots
    say("DoT icons on nameplates " .. (db.plateDots and "on" or "off") .. " (the letter stays)")
  elseif cmd == "platey" then
    local y = tonumber((msg or ""):match("^%S+%s+(%-?%d+)"))
    if y then
      db.plateY = y
      say("Nameplate letters now " .. y .. " px above the plate.")
    else
      say("Usage: /dw platey 10  (pixels above the nameplate, can be negative)")
    end
  elseif cmd == "debug" then
    db.debugChat = not db.debugChat
    say("Debug lines in chat " .. (db.debugChat and "on" or "off") .. ". They are always saved on /reload.")
  else
    say("/dw - options window")
    say("/dw style <bars|slim|icons|table|focus> - display style")
    say("/dw lock - lock/unlock the window (unlocked = drag it)")
    say("/dw test - show sample timers")
    say("/dw spells - show which DoTs were found in your spellbook")
    say("/dw plates - letter on nameplates on/off")
    say("/dw platedots - also show DoT icons on nameplates on/off")
    say("/dw platey <px> - move the nameplate icons up/down")
    say("/dw chat - resist/immune messages in chat on/off")
    say("/dw debug - show debug lines in chat on/off")
    say("/dw reset - reset the window position")
    say("/dw clear - remove all timers")
    say("/dw learned - show durations learned from real aura data")
  end
  dirty = true
end
