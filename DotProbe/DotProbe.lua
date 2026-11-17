-- DotProbe 0.4: diagnostic addon for WoW Forever.
-- No gameplay function. It only logs which data addons can read in combat
-- (or whether it is "secret"), so the real DoT tracker can be built on facts.
--
-- New in 0.2:
--  * Landing check: after every DoT cast it prints in chat whether the game
--    reported an aura change on that exact enemy (landed / no aura event).
--  * Nameplate tests: /dp hide cvar | /dp hide frame | /dp show
--  * Logs ADDON_ACTION_BLOCKED / ADDON_ACTION_FORBIDDEN
--  * Much less noise, higher line cap (40,000)
--
-- Commands: /dp help

local ADDON_NAME = ...
local MAX_LINES = 40000
local LAND_WINDOW = 0.5   -- seconds after SUCCEEDED to wait for the aura event

local issecret = issecretvalue or function() return false end
local db
local state = { recording = false, auras = true, cleuCount = 0, full = false, hideFrames = false }
local lastSnap = {}
local regNotes = {}

---------------------------------------------------------------------------
-- Formatting: never compute with or compare secret values
---------------------------------------------------------------------------
local function fmt(v)
  if issecret(v) then return "<SECRET>" end
  local t = type(v)
  if t == "nil" then return "nil" end
  if t == "string" then return '"' .. v .. '"' end
  if t == "number" or t == "boolean" then return tostring(v) end
  return "<" .. t .. ">"
end

local function args(...)
  local n = select("#", ...)
  local out = {}
  for i = 1, n do out[i] = fmt((select(i, ...))) end
  if n == 0 then return "(none)" end
  return table.concat(out, ", ")
end

-- calls f protected and returns the results as text
local function try(f, ...)
  if type(f) ~= "function" then return "<missing API>" end
  return (function(ok, ...)
    if not ok then return "<ERR " .. tostring((...)) .. ">" end
    return args(...)
  end)(pcall(f, ...))
end

-- returns a plain value or nil (if missing, error or secret)
local function plain(f, ...)
  if type(f) ~= "function" then return nil end
  local ok, v = pcall(f, ...)
  if not ok or issecret(v) then return nil end
  return v
end

local function safeGUID(unit)
  local g = plain(UnitGUID, unit)
  if type(g) == "string" then return g end
  return nil
end

local function shortGUID(g)
  if type(g) ~= "string" then return "?" end
  return g:sub(-6)
end

-- UNIT_AURA payload lists: in Forever, non-empty lists are secret, empty ones readable.
local function listState(t)
  if issecret(t) then return "S" end            -- secret = non-empty
  if type(t) == "table" and #t > 0 then return #t end
  return 0
end
local function nonEmpty(t)
  local s = listState(t)
  return s == "S" or (type(s) == "number" and s > 0)
end

---------------------------------------------------------------------------
-- Log (written to SavedVariables/DotProbe.lua on /reload or logout)
---------------------------------------------------------------------------
local function say(msg) print("|cff88aaffDotProbe:|r " .. msg) end

local function log(tag, msg)
  if not (db and state.recording) then return end
  local l = db.log
  if #l >= MAX_LINES then
    if not state.full then
      state.full = true
      state.recording = false
      say("|cffff5555Log full (" .. MAX_LINES .. " lines). Recording stopped.|r /reload saves the file.")
    end
    return
  end
  local line = string.format("%.3f %s[%s] %s", GetTime(), InCombatLockdown() and "C" or "-", tag, msg)
  l[#l + 1] = line
  if db.echo then print("|cff88aaffDP|r " .. line) end
end

---------------------------------------------------------------------------
-- Units & spells
---------------------------------------------------------------------------
local function unitInfo(unit)
  return string.format("%s{exists=%s guid=%s name=%s dead=%s mark=%s}",
    unit, try(UnitExists, unit), try(UnitGUID, unit), try(UnitName, unit),
    try(UnitIsDead, unit), try(GetRaidTargetIndex, unit))
end

local spellNames = {}
local function spellName(id)
  if issecret(id) or type(id) ~= "number" then return nil end
  if spellNames[id] ~= nil then return spellNames[id] or nil end
  local name = false
  if C_Spell and C_Spell.GetSpellInfo then
    local ok, info = pcall(C_Spell.GetSpellInfo, id)
    if ok and not issecret(info) and type(info) == "table" and not issecret(info.name) then
      name = info.name
    end
  end
  spellNames[id] = name
  return name or nil
end

local loggedSpell = {}
local function logSpellOnce(id)
  if issecret(id) or type(id) ~= "number" or loggedSpell[id] then return end
  loggedSpell[id] = true
  local sub = (C_Spell and C_Spell.GetSpellSubtext) and try(C_Spell.GetSpellSubtext, id) or "<missing API>"
  local desc = (C_Spell and C_Spell.GetSpellDescription) and try(C_Spell.GetSpellDescription, id) or "<missing API>"
  log("SPELL", string.format("%d name=%s subtext=%s desc=%s", id, fmt(spellName(id)), sub, desc))
end

-- spells that should leave a debuff on the enemy -> chat output of the landing check
local DOT_PATTERNS = { "^Curse of", "^Bane of", "Corruption", "Immolate", "Siphon Life",
  "Unstable Affliction", "Drain Life", "Drain Soul", "Drain Mana", "Fear", "Death Coil", "Howl of Terror" }
local function isDot(name)
  if type(name) ~= "string" then return false end
  for _, p in ipairs(DOT_PATTERNS) do
    if name:find(p) then return true end
  end
  return false
end

local function countPlates()
  return try(function() return #C_NamePlate.GetNamePlates() end)
end

local function isWatchedUnit(unit)
  if issecret(unit) or type(unit) ~= "string" then return false end
  return unit == "target" or unit == "focus" or unit == "mouseover" or unit:find("^nameplate%d+$") ~= nil
end

-- nameplate unit that is also the current target -> the target line is enough
local function isTargetDuplicate(unit)
  if not unit:find("^nameplate%d+$") then return false end
  local a, b = safeGUID(unit), safeGUID("target")
  return a ~= nil and a == b
end

---------------------------------------------------------------------------
-- Landing check
---------------------------------------------------------------------------
local pendingByCast = {}   -- castGUID -> entry (from SENT)
local lastAuraChange = {}  -- enemy GUID -> { added = t, updated = t, removed = t }
local lastCombatEvent = {} -- enemy GUID -> { t = t, action = "RESIST" ... } (not WOUND/HEAL)
local landStats = {}       -- spell name -> { landed = n, none = n }

-- which unit did SENT mean? SENT only gives the name, so match it to target/mouseover/focus
local function resolveDest(destName)
  if issecret(destName) or type(destName) ~= "string" or destName == "" then return nil, nil end
  for _, u in ipairs({ "target", "mouseover", "focus" }) do
    local n = plain(UnitName, u)
    if n == destName then return safeGUID(u), u end
  end
  return nil, nil
end

local function evaluateLanding(e)
  local a = lastAuraChange[e.guid]
  local since = e.tSucc - 0.05
  local result
  if a and a.added and a.added >= since then
    result = "LANDED (aura added)"
  elseif a and a.updated and a.updated >= since then
    result = "LANDED (aura updated = refresh)"
  else
    result = "NO AURA EVENT"
  end
  local c = lastCombatEvent[e.guid]
  local extra = ""
  if c and c.t >= e.tSent - 0.05 then extra = " | UNIT_COMBAT " .. c.action end

  local line = string.format("%s -> %s [%s] via %s: %s%s (%.2fs after success)",
    e.spell or ("spell " .. tostring(e.id)), e.destName, shortGUID(e.guid), e.unit,
    result, extra, GetTime() - e.tSucc)
  log("LAND", line)

  local st = landStats[e.spell or "?"] or { landed = 0, none = 0 }
  landStats[e.spell or "?"] = st
  if result == "NO AURA EVENT" then st.none = st.none + 1 else st.landed = st.landed + 1 end

  if isDot(e.spell) and db.landChat ~= false then
    local color = (result == "NO AURA EVENT") and "|cffff5555" or "|cff55ff55"
    say(color .. line .. "|r")
  end
end

local function onSent(destName, castGUID, spellID)
  if issecret(castGUID) or type(castGUID) ~= "string" then return end
  local guid, unit = resolveDest(destName)
  if not guid then return end
  pendingByCast[castGUID] = { id = spellID, spell = spellName(spellID), guid = guid, unit = unit,
    destName = destName, tSent = GetTime() }
end

local function onSucceeded(castGUID)
  if issecret(castGUID) or type(castGUID) ~= "string" then return end
  local e = pendingByCast[castGUID]
  if not e then return end
  pendingByCast[castGUID] = nil
  e.tSucc = GetTime()
  C_Timer.After(LAND_WINDOW, function() evaluateLanding(e) end)
end

local function onCastEnd(castGUID)
  if issecret(castGUID) or type(castGUID) ~= "string" then return end
  pendingByCast[castGUID] = nil
end

---------------------------------------------------------------------------
-- Auras (only readable outside combat; in combat we only log the payload shape)
---------------------------------------------------------------------------
local AURA_FIELDS = { "name", "spellId", "icon", "applications", "duration", "expirationTime",
  "auraInstanceID", "sourceUnit", "isFromPlayerOrPlayerPet", "isHarmful" }

local function auraFieldStr(aura)
  local parts = {}
  for _, k in ipairs(AURA_FIELDS) do
    local ok, v = pcall(function() return aura[k] end)
    parts[#parts + 1] = k .. "=" .. (ok and fmt(v) or "<ERR>")
  end
  return table.concat(parts, " ")
end

local function snapshotAuras(unit, why)
  if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then
    log("AURA", "C_UnitAuras.GetAuraDataByIndex <missing API>")
    return
  end
  local found = 0
  for i = 1, 40 do
    local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HARMFUL|PLAYER")
    if not ok then log("AURA", unit .. " <ERR " .. tostring(aura):gsub("\n.*", "") .. ">") return end
    if issecret(aura) then log("AURA", unit .. " aura table <SECRET>") return end
    if not aura then break end
    found = found + 1
    log("AURA", string.format("%s (%s) #%d %s", unit, why, i, auraFieldStr(aura)))
  end
  log("AURA", string.format("%s (%s): %d own debuffs", unit, why, found))
end

local function onUnitAura(unit, info)
  if not isWatchedUnit(unit) then return end
  local guid = safeGUID(unit)
  local now = GetTime()
  local added, updated, removed = 0, 0, 0
  if type(info) == "table" and not issecret(info) then
    added, updated, removed = listState(info.addedAuras), listState(info.updatedAuraInstanceIDs),
      listState(info.removedAuraInstanceIDs)
    if guid then
      local a = lastAuraChange[guid] or {}
      lastAuraChange[guid] = a
      if nonEmpty(info.addedAuras) then a.added = now end
      if nonEmpty(info.updatedAuraInstanceIDs) then a.updated = now end
      if nonEmpty(info.removedAuraInstanceIDs) then a.removed = now end
    end
  end
  if not state.auras or isTargetDuplicate(unit) then return end
  log("UAURA", string.format("%s [%s] added=%s updated=%s removed=%s", unit, shortGUID(guid),
    tostring(added), tostring(updated), tostring(removed)))
  -- outside combat the details are readable: snapshot (throttled)
  if not InCombatLockdown() and (not lastSnap[unit] or now - lastSnap[unit] > 0.3) then
    lastSnap[unit] = now
    snapshotAuras(unit, "UNIT_AURA")
  end
end

local function snapshotAll(why)
  local combat = InCombatLockdown()
  for _, u in ipairs({ "target", "focus", "mouseover" }) do
    if plain(UnitExists, u) then
      log("SNAP", unitInfo(u))
      if not combat then snapshotAuras(u, why) end
    end
  end
  for i = 1, 40 do
    local u = "nameplate" .. i
    if plain(UnitExists, u) then
      local plate = C_NamePlate.GetNamePlateForUnit and plain(C_NamePlate.GetNamePlateForUnit, u)
      local alpha = plate and try(plate.GetAlpha, plate) or "?"
      log("SNAP", unitInfo(u) .. " plateAlpha=" .. alpha)
      if not combat then snapshotAuras(u, why) end
    end
  end
  log("SNAP", "Nameplates active: " .. countPlates() .. (combat and " (auras skipped: in combat)" or ""))
end

---------------------------------------------------------------------------
-- CVars & nameplate hiding
---------------------------------------------------------------------------
local CVARS = { "nameplateShowEnemies", "nameplateShowAll", "nameplateMaxDistance",
  "nameplateMinAlpha", "nameplateMaxAlpha", "nameplateOccludedAlphaMult", "nameplateNotSelectedAlpha" }
local HIDE_CVARS = { "nameplateMinAlpha", "nameplateMaxAlpha", "nameplateOccludedAlphaMult", "nameplateNotSelectedAlpha" }

local function getCVar(name)
  local fn = (C_CVar and C_CVar.GetCVar) or GetCVar
  return plain(fn, name)
end

local function setCVar(name, value)
  local fn = (C_CVar and C_CVar.SetCVar) or SetCVar
  local res = try(fn, name, value)
  local msg = string.format("SetCVar(%s, %s) inCombat=%s -> %s | now=%s",
    name, value, tostring(InCombatLockdown()), res, fmt(getCVar(name)))
  log("CVAR", msg)
  say(msg)
end

local function setPlateAlpha(unit, a)
  if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return "<missing API>" end
  local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
  if not ok then return "<ERR " .. tostring(plate) .. ">" end
  if not plate or issecret(plate) then return "no plate" end
  return try(plate.SetAlpha, plate, a) .. " alpha now " .. try(plate.GetAlpha, plate)
end

local function hideCVars()
  db.npOrig = db.npOrig or {}
  for _, c in ipairs(HIDE_CVARS) do
    local cur = getCVar(c)
    if cur == nil and db.npOrig[c] == nil then
      log("CVAR", c .. " does not exist on this client, skipped")
      say(c .. " does not exist on this client, skipped")
    else
      if db.npOrig[c] == nil then db.npOrig[c] = cur end
      setCVar(c, "0")
    end
  end
  say("Nameplates hidden via CVars. /dp show restores the old values.")
end

local function hideFrames(on)
  state.hideFrames = on
  for i = 1, 40 do
    local u = "nameplate" .. i
    if plain(UnitExists, u) then
      local r = setPlateAlpha(u, on and 0 or 1)
      log("NPHIDE", string.format("%s SetAlpha(%d) inCombat=%s -> %s", u, on and 0 or 1, tostring(InCombatLockdown()), r))
    end
  end
  say(on and "Nameplate frames set to alpha 0 (also new ones). /dp show to undo." or "Nameplate frames visible again.")
end

local function restoreAll()
  if db.npOrig then
    for c, v in pairs(db.npOrig) do
      if type(v) == "string" then setCVar(c, v) end
    end
    db.npOrig = nil
  end
  if state.hideFrames then hideFrames(false) end
  say("Nameplate settings restored.")
end

---------------------------------------------------------------------------
-- Environment (written at the top of the log on /dp start)
---------------------------------------------------------------------------
local function header()
  local h = {}
  h[#h + 1] = "DotProbe version 0.2"
  h[#h + 1] = "build: " .. try(GetBuildInfo)
  h[#h + 1] = "issecretvalue API: " .. (issecretvalue and "present" or "MISSING")
  h[#h + 1] = "C_CombatLog.IsCombatLogRestricted: " ..
    ((C_CombatLog and C_CombatLog.IsCombatLogRestricted) and try(C_CombatLog.IsCombatLogRestricted) or "<missing API>")
  h[#h + 1] = "C_Timer.After: " .. fmt(C_Timer and type(C_Timer.After))
  for _, n in ipairs(regNotes) do h[#h + 1] = n end
  for _, c in ipairs(CVARS) do h[#h + 1] = "CVar " .. c .. " = " .. fmt(getCVar(c)) end
  h[#h + 1] = "Nameplates active: " .. countPlates()
  return h
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local f = CreateFrame("Frame")

local function reg(ev, unit)
  local ok, err
  if unit then
    ok, err = pcall(f.RegisterUnitEvent, f, ev, unit)
  else
    ok, err = pcall(f.RegisterEvent, f, ev)
  end
  if not ok then regNotes[#regNotes + 1] = string.format("RegisterEvent %s: ERROR %s", ev, tostring(err)) end
end

-- 0.3: no COMBAT_LOG_EVENT_UNFILTERED any more. Forever forbids it (BugGrabber ADDON_ACTION_FORBIDDEN),
-- and run 1 already proved the combat log is closed.
f:RegisterEvent("ADDON_LOADED")
for _, ev in ipairs({ "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "PLAYER_TARGET_CHANGED",
  "PLAYER_FOCUS_CHANGED", "RAID_TARGET_UPDATE", "NAME_PLATE_UNIT_ADDED",
  "NAME_PLATE_UNIT_REMOVED", "UNIT_AURA", "UNIT_COMBAT", "UI_ERROR_MESSAGE",
  "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN" }) do
  reg(ev)
end
for _, ev in ipairs({ "UNIT_SPELLCAST_SENT", "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP",
  "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_FAILED_QUIET",
  "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_STOP" }) do
  reg(ev, "player")
end

-- UI errors that only come from button mashing
local NOISE_ERR = { [61] = true, [62] = true, [280] = true }

local function isClientFail(castGUID)
  -- "Cast-2-0-0-0-..." = rejected by the client before it was sent (GCD, mashing)
  return type(castGUID) == "string" and not issecret(castGUID) and castGUID:find("^Cast%-2%-") ~= nil
end

f:SetScript("OnEvent", function(self, event, ...)
  if event == "ADDON_LOADED" then
    if ... == ADDON_NAME then
      DotProbeDB = DotProbeDB or {}
      db = DotProbeDB
      db.log = db.log or {}
      if db.echo == nil then db.echo = false end
      say("0.4 loaded. /dp help for commands. Log: " .. #db.log .. " lines.")
      if db.npOrig then
        say("|cffffaa00Nameplate CVars are still changed from a hide test. /dp show restores them.|r")
      end
    end
    return
  end

  -- nameplate hiding must also work while not recording
  if event == "NAME_PLATE_UNIT_ADDED" and state.hideFrames then
    local unit = ...
    log("NPHIDE", unit .. " new plate SetAlpha(0) -> " .. setPlateAlpha(unit, 0))
  end
  if event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
    say("|cffff5555" .. event .. ": " .. args(...) .. "|r")
  end

  if not state.recording then return end

  if event == "UNIT_SPELLCAST_SENT" then
    local _, destName, castGUID, spellID = ...
    logSpellOnce(spellID)
    log("CAST", "SENT " .. args(...) .. " | " .. unitInfo("target"))
    onSent(destName, castGUID, spellID)
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
    local _, castGUID = ...
    log("CAST", "SUCCEEDED " .. args(...))
    onSucceeded(castGUID)
  elseif event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_FAILED_QUIET"
      or event == "UNIT_SPELLCAST_INTERRUPTED" then
    local _, castGUID = ...
    onCastEnd(castGUID)
    if not isClientFail(castGUID) and event ~= "UNIT_SPELLCAST_FAILED_QUIET" then
      log("CAST", event:sub(16) .. " " .. args(...))
    end
  elseif event:find("^UNIT_SPELLCAST_") then
    log("CAST", event:sub(16) .. " " .. args(...))
  elseif event == "UNIT_COMBAT" then
    local unit, action = ...
    if not isWatchedUnit(unit) then return end
    local guid = safeGUID(unit)
    if guid and not issecret(action) and action ~= "WOUND" and action ~= "HEAL" then
      lastCombatEvent[guid] = { t = GetTime(), action = tostring(action) }
    end
    if isTargetDuplicate(unit) then return end
    log("UCOMBAT", args(...) .. " | " .. unitInfo(unit))
  elseif event == "UNIT_AURA" then
    onUnitAura(...)
  elseif event == "NAME_PLATE_UNIT_ADDED" or event == "NAME_PLATE_UNIT_REMOVED" then
    local unit = ...
    log("NP", event:sub(17) .. " " .. unitInfo(unit) .. " active=" .. countPlates())
  elseif event == "PLAYER_TARGET_CHANGED" then
    log("UNIT", "target -> " .. unitInfo("target"))
  elseif event == "PLAYER_FOCUS_CHANGED" then
    log("UNIT", "focus -> " .. unitInfo("focus"))
  elseif event == "RAID_TARGET_UPDATE" then
    log("UNIT", "raid marks: target=" .. try(GetRaidTargetIndex, "target"))
  elseif event == "PLAYER_REGEN_DISABLED" then
    state.cleuCount = 0
    log("COMBAT", "=== combat starts ===")
  elseif event == "PLAYER_REGEN_ENABLED" then
    log("COMBAT", "=== combat ends ===")
  elseif event == "UI_ERROR_MESSAGE" then
    local id = ...
    if issecret(id) or not NOISE_ERR[id] then log("UIERR", args(...)) end
  elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
    log("BLOCKED", event .. " " .. args(...))
  elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
    if state.cleuCount < 30 then
      state.cleuCount = state.cleuCount + 1
      log("CLEU", try(CombatLogGetCurrentEventInfo))
    end
  end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local HELP = {
  "/dp start [note]   - start recording",
  "/dp stop           - stop recording",
  "/dp mark <text>    - write a marker into the log (e.g. test number)",
  "/dp snap           - snapshot: target/focus/mouseover/nameplates",
  "/dp np             - show nameplate CVars",
  "/dp npset <cvar> <value> - set a CVar",
  "/dp hide cvar      - hide nameplates via alpha CVars (= 0)",
  "/dp hide frame     - hide nameplates via frame:SetAlpha(0)",
  "/dp show           - undo both hide variants, restore CVars",
  "/dp land           - landing chat lines on/off; /dp landstats = summary",
  "/dp click [spell]  - click test: rows per enemy nameplate, left = cast there, right = target",
  "/dp click status   - why rows are missing (states, nameplates, conditional)",
  "/dp dots [off]     - dungeon test: your debuffs on the target, drawn by the game",
  "/dp echo | aura | status | clear | help",
}


---------------------------------------------------------------------------
-- 0.3: click test. Can a click on a list row cast on THAT mob (not the target)?
-- Secure buttons are fixed to nameplate1..40 (set once, out of combat).
-- Secure code (state drivers + restricted snippet) shows and sorts them in
-- combat; our own code only writes the names. Left click = spell, right = target.
---------------------------------------------------------------------------
local ck = { built = false, slots = {}, spell = nil }
local CK_MAX, CK_H = 8, 22

local CK_LAYOUT = [=[
  local y, n = 0, 0
  for i = 1, 40 do
    local b = self:GetFrameRef("s" .. i)
    if b then
      if self:GetAttribute("state-np" .. i) == "1" and n < 8 then
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", self, "TOPLEFT", 6, -24 - y)
        b:Show()
        y = y + 22
        n = n + 1
      else
        b:Hide()
      end
    end
  end
  self:SetHeight(30 + math.max(n, 1) * 22)
]=]

local function ckBuild()
  local h = CreateFrame("Frame", "DotProbeClickTest", UIParent, "SecureHandlerStateTemplate")
  h:SetSize(220, 52)
  h:SetPoint("CENTER", UIParent, "CENTER", -380, 120)
  h:SetFrameStrata("MEDIUM")
  local bg = h:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, 0.6)
  h.title = h:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  h.title:SetPoint("TOPLEFT", 6, -6)
  for i = 1, 40 do
    local b = CreateFrame("Button", "DotProbeClickSlot" .. i, h, "SecureActionButtonTemplate")
    b:RegisterForClicks("AnyUp", "AnyDown")
    b:SetSize(208, CK_H - 2)
    b:SetAttribute("type1", "spell")
    b:SetAttribute("type2", "target")
    b:SetAttribute("unit", "nameplate" .. i)
    local t = b:CreateTexture(nil, "BACKGROUND")
    t:SetAllPoints()
    t:SetColorTexture(0.35, 0.1, 0.4, 0.7)
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.label:SetPoint("LEFT", 4, 0)
    b.label:SetPoint("RIGHT", -4, 0)
    b.label:SetJustifyH("LEFT")
    b:Hide()
    b:HookScript("OnClick", function(self, button, down)
      local u = "nameplate" .. i
      log("CLICK", string.format("slot %d %s btn=%s down=%s combat=%s name=%s guid=%s target=%s",
        i, u, tostring(button), tostring(down), tostring(InCombatLockdown()),
        fmt(UnitName(u)), shortGUID(safeGUID(u)), tostring(UnitIsUnit(u, "target"))))
    end)
    h:SetFrameRef("s" .. i, b)
    h:SetAttribute("_onstate-np" .. i, CK_LAYOUT)
    RegisterStateDriver(h, "np" .. i, "[@nameplate" .. i .. ",harm,nodead] 1; 0")
    ck.slots[i] = b
  end
  -- our own (insecure) part: names + watching whether secure code moves rows in combat
  local lastSig, loggedCombatMove = nil, false
  local acc = 0
  h:SetScript("OnUpdate", function(self, el)
    acc = acc + el
    if acc < 0.2 then return end
    acc = 0
    local sig = {}
    for i, b in ipairs(ck.slots) do
      if b:IsShown() then
        local u = "nameplate" .. i
        local tgt = UnitIsUnit(u, "target") and " |cffff4040<target>|r" or ""
        b.label:SetText(string.format("np%d  %s%s", i, fmt(UnitName(u)), tgt))
        sig[#sig + 1] = i .. "@" .. math.floor((b:GetTop() or 0) + 0.5)
      end
    end
    local s = table.concat(sig, " ")
    if s ~= lastSig then
      if lastSig and InCombatLockdown() then
        log("CLICKLAYOUT", "rows changed IN COMBAT: " .. s)
        if not loggedCombatMove then say("Secure code reordered the rows in combat. Works.") loggedCombatMove = true end
      end
      lastSig = s
    end
  end)
  ck.header = h
  ck.built = true
end

local function ckCommand(rest)
  if InCombatLockdown() and rest ~= "status" then say("Only out of combat (secure buttons).") return end
  if rest == "status" then
    if not ck.header then say("Click test not built. /dp click first.") return end
    local h = ck.header
    say(string.format("header shown=%s h=%.0f", tostring(h:IsShown()), h:GetHeight() or -1))
    local any = false
    for i = 1, 40 do
      local u = "nameplate" .. i
      local st = h:GetAttribute("state-np" .. i)
      if UnitExists(u) or st == "1" or ck.slots[i]:IsShown() then
        any = true
        local line = string.format("np%d exists=%s enemy=%s dead=%s state=%s row=%s spell=%s name=%s",
          i, tostring(UnitExists(u)), tostring(UnitCanAttack("player", u)), tostring(UnitIsDead(u)),
          tostring(st), tostring(ck.slots[i]:IsShown()), tostring(ck.slots[i]:GetAttribute("spell1")), fmt(UnitName(u)))
        say(line)
        log("CLICKSTAT", line)
      end
    end
    if not any then say("No nameplate units and no states at all.") end
    -- manual check of the conditional itself, outside the state driver
    if SecureCmdOptionParse then
      for i = 1, 40 do
        if UnitExists("nameplate" .. i) then
          local r = SecureCmdOptionParse("[@nameplate" .. i .. ",harm,nodead] 1; 0")
          say("conditional np" .. i .. " -> " .. tostring(r))
          log("CLICKSTAT", "conditional np" .. i .. " -> " .. tostring(r))
        end
      end
    end
    return
  end
  if rest == "off" then
    if ck.header then ck.header:Hide() end
    say("Click test hidden.")
    return
  end
  local spell = (rest ~= "" and rest) or "Corruption"
  if not ck.built then ckBuild() end
  ck.spell = spell
  for _, b in ipairs(ck.slots) do b:SetAttribute("spell1", spell) end
  ck.header.title:SetText("DotProbe click test: " .. spell)
  ck.header:Show()
  log("CLICK", "test on, spell=" .. spell)
  say("Click test on. Left click a row = " .. spell .. " on THAT mob, right click = target it. /dp click off hides it.")
end


---------------------------------------------------------------------------
-- 0.4: aura test for dungeons. In instances Forever hides names and GUIDs.
-- Can the game still DRAW our debuffs (icon + timer) like it draws HP %?
-- /dp aura: panel for target + up to 4 nameplates, and an API report in the log.
---------------------------------------------------------------------------
local au = { built = false, rows = {}, lastReport = {} }
local AU_UNITS = { "target" }
local AU_FILTER = "HARMFUL|PLAYER"

local function auType(v)
  if issecret(v) then return "SECRET" end
  if v == nil then return "nil" end
  if type(v) == "table" then return "table" end
  return type(v) .. ":" .. tostring(v)
end

-- every way we know to get the player's debuffs on a unit; returns list, method, notes
local function auGet(unit)
  local notes = {}
  if C_UnitAuras and C_UnitAuras.GetUnitAuras then
    local ok, res = pcall(C_UnitAuras.GetUnitAuras, unit, AU_FILTER)
    if ok and type(res) == "table" and not issecret(res) then
      local okN, n = pcall(function() return #res end)
      notes[#notes + 1] = "GetUnitAuras ok n=" .. tostring(okN and n or "ERR")
      if okN then return res, "GetUnitAuras", notes end
    else
      notes[#notes + 1] = "GetUnitAuras " .. (ok and auType(res) or ("ERR " .. tostring(res)))
    end
  else
    notes[#notes + 1] = "GetUnitAuras missing"
  end
  if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
    local list, err = {}, nil
    for i = 1, 16 do
      local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, AU_FILTER)
      if not ok then err = a break end
      if a == nil then break end
      list[#list + 1] = a
    end
    notes[#notes + 1] = "GetAuraDataByIndex " .. (err and ("ERR " .. tostring(err)) or ("ok n=" .. #list))
    if not err then return list, "GetAuraDataByIndex", notes end
  end
  if AuraUtil and AuraUtil.ForEachAura then
    local list = {}
    local ok, err = pcall(AuraUtil.ForEachAura, unit, AU_FILTER, 16, function(a) list[#list + 1] = a end, true)
    notes[#notes + 1] = "ForEachAura " .. (ok and ("ok n=" .. #list) or ("ERR " .. tostring(err)))
    if ok then return list, "ForEachAura", notes end
  end
  return nil, "none", notes
end

local function auReport(unit, list, method, notes)
  local t = GetTime()
  if au.lastReport[unit] and t - au.lastReport[unit] < 6 then return end
  au.lastReport[unit] = t
  local inInst, instType = IsInInstance()
  log("AURA", string.format("%s instance=%s/%s exists=%s name=%s guid=%s | %s | via %s",
    unit, tostring(inInst), tostring(instType), tostring(UnitExists(unit)), auType(UnitName(unit)),
    auType(UnitGUID(unit)), table.concat(notes, "; "), method))
  if list and list[1] then
    local a = list[1]
    local okF, fields = pcall(function()
      return string.format("first aura: table=%s id=%s spellId=%s name=%s icon=%s dur=%s exp=%s src=%s",
        auType(a), auType(a.auraInstanceID), auType(a.spellId), auType(a.name), auType(a.icon),
        auType(a.duration), auType(a.expirationTime), auType(a.sourceUnit))
    end)
    log("AURA", unit .. " " .. (okF and fields or ("fields ERR " .. tostring(fields))))
    if C_UnitAuras and C_UnitAuras.GetAuraDuration then
      local ok, d = pcall(C_UnitAuras.GetAuraDuration, unit, a.auraInstanceID)
      log("AURA", unit .. " GetAuraDuration " .. (ok and auType(d) or ("ERR " .. tostring(d))))
    else
      log("AURA", "GetAuraDuration missing")
    end
  end
end

local function auSetTimer(cd, unit, a)
  -- 1) duration object, 2) plain numbers (outside dungeons), 3) secret numbers straight into the widget
  if C_UnitAuras and C_UnitAuras.GetAuraDuration and cd.SetCooldownFromDurationObject then
    local ok, d = pcall(C_UnitAuras.GetAuraDuration, unit, a.auraInstanceID)
    if ok and d and pcall(cd.SetCooldownFromDurationObject, cd, d) then return "durobj" end
  end
  local exp, dur = a.expirationTime, a.duration
  if not issecret(exp) and not issecret(dur) and type(exp) == "number" and type(dur) == "number" then
    cd:SetCooldown(exp - dur, dur)
    return "numbers"
  end
  if cd.SetCooldownFromExpirationTime and pcall(cd.SetCooldownFromExpirationTime, cd, exp, dur) then return "exptime" end
  return "none"
end

local function auBuild()
  local f = CreateFrame("Frame", "DotProbeAuraTest", UIParent)
  f:SetSize(260, 40 + #AU_UNITS * 40)
  f:SetPoint("CENTER", UIParent, "CENTER", -380, -60)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, 0.6)
  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  title:SetPoint("TOPLEFT", 6, -6)
  title:SetText("DotProbe aura test (drag me)")
  for r, unit in ipairs(AU_UNITS) do
    local row = { unit = unit, icons = {} }
    row.name = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("TOPLEFT", 6, -22 - (r - 1) * 40)
    row.name:SetWidth(240)
    row.name:SetJustifyH("LEFT")
    for i = 1, 6 do
      local ic = CreateFrame("Frame", nil, f)
      ic:SetSize(24, 24)
      ic:SetPoint("TOPLEFT", 6 + (i - 1) * 27, -34 - (r - 1) * 40)
      ic.tex = ic:CreateTexture(nil, "ARTWORK")
      ic.tex:SetAllPoints()
      ic.cd = CreateFrame("Cooldown", nil, ic, "CooldownFrameTemplate")
      ic.cd:SetAllPoints()
      ic.cd:SetReverse(true)
      if ic.cd.SetHideCountdownNumbers then ic.cd:SetHideCountdownNumbers(false) end
      ic:Hide()
      row.icons[i] = ic
    end
    au.rows[r] = row
  end
  local acc = 0
  f:SetScript("OnUpdate", function(self, el)
    acc = acc + el
    if acc < 0.25 then return end
    acc = 0
    for _, row in ipairs(au.rows) do
      local unit = row.unit
      if UnitExists(unit) then
        pcall(row.name.SetText, row.name, UnitName(unit)) -- secret names may be drawn
        local list, method, notes = auGet(unit)
        auReport(unit, list, method, notes)
        local how = {}
        for i, ic in ipairs(row.icons) do
          local a = list and list[i]
          if a then
            local okT = pcall(ic.tex.SetTexture, ic.tex, a.icon)
            local okC, m = pcall(auSetTimer, ic.cd, unit, a)
            how[#how + 1] = (okT and "icon" or "noicon") .. "/" .. (okC and m or "ERR")
            ic:Show()
          else
            ic:Hide()
          end
        end
        local key = table.concat(how, " ")
        if key ~= row.lastHow then
          row.lastHow = key
          log("AURA", unit .. " draw: " .. (key ~= "" and key or "no auras"))
        end
      else
        row.name:SetText(unit .. ": -")
        for _, ic in ipairs(row.icons) do ic:Hide() end
      end
    end
  end)
  au.frame = f
  au.built = true
end

local function auCommand(rest)
  if rest == "off" then
    if au.frame then au.frame:Hide() end
    say("Aura test hidden.")
    return
  end
  if not au.built then auBuild() end
  au.frame:Show()
  au.lastReport = {}
  log("AURA", "test on")
  say("Aura test on: shows YOUR debuffs on your target, drawn by the game. /dp dots off hides it.")
end

SLASH_DOTPROBE1 = "/dp"
SLASH_DOTPROBE2 = "/dotprobe"
SlashCmdList.DOTPROBE = function(msg)
  local cmd, rest = (msg or ""):match("^(%S*)%s*(.-)$")
  cmd = (cmd or ""):lower()
  if not db then say("not loaded yet") return end

  if cmd == "start" then
    state.recording = true
    state.full = false
    log("SESSION", "=== start === " .. rest)
    for _, l in ipairs(header()) do log("ENV", l) end
    say("Recording. Lines so far: " .. #db.log .. " of " .. MAX_LINES .. ".")
  elseif cmd == "stop" then
    log("SESSION", "=== stop ===")
    state.recording = false
    say("Recording stopped. /reload writes the file.")
  elseif cmd == "mark" then
    if not state.recording then say("Run /dp start first.") return end
    log("MARK", "##### " .. rest)
    say("Marked: " .. rest)
  elseif cmd == "snap" then
    if not state.recording then say("Run /dp start first.") return end
    snapshotAll("manual")
    say("Snapshot saved.")
  elseif cmd == "np" then
    for _, c in ipairs(CVARS) do
      local line = c .. " = " .. fmt(getCVar(c))
      say(line)
      log("CVAR", line)
    end
    say("Nameplates active: " .. countPlates())
  elseif cmd == "npset" then
    local n, v = rest:match("^(%S+)%s+(%S+)$")
    if n then setCVar(n, v) else say("Usage: /dp npset nameplateShowEnemies 1") end
  elseif cmd == "hide" then
    if rest == "cvar" then hideCVars()
    elseif rest == "frame" then hideFrames(true)
    else say("Usage: /dp hide cvar  or  /dp hide frame") end
  elseif cmd == "show" then
    restoreAll()
  elseif cmd == "land" then
    db.landChat = (db.landChat == false)
    say("Landing chat lines " .. (db.landChat and "on" or "off"))
  elseif cmd == "landstats" then
    local any = false
    for name, st in pairs(landStats) do
      any = true
      say(string.format("%s: landed %d, no aura event %d", name, st.landed, st.none))
      log("LANDSTAT", string.format("%s landed=%d none=%d", name, st.landed, st.none))
    end
    if not any then say("No landing checks yet.") end
  elseif cmd == "echo" then
    db.echo = not db.echo
    say("Chat echo " .. (db.echo and "on" or "off"))
  elseif cmd == "aura" then
    state.auras = not state.auras
    say("Aura log " .. (state.auras and "on" or "off"))
  elseif cmd == "clear" then
    wipe(db.log)
    state.full = false
    say("Log cleared.")
  elseif cmd == "dots" then
    auCommand(rest)
  elseif cmd == "click" then
    ckCommand(rest)
  elseif cmd == "status" then
    say(string.format("recording=%s lines=%d/%d echo=%s auras=%s plateHide=%s", tostring(state.recording),
      #db.log, MAX_LINES, tostring(db.echo), tostring(state.auras),
      (db.npOrig and "cvar " or "") .. (state.hideFrames and "frame" or "")))
  else
    for _, l in ipairs(HELP) do say(l) end
  end
end
