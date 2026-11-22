-- DotProbe 0.7: range checks and Demonic Brand (test plan: DotProbe/TEST-0.7.md)
--
--   /dp range <spell>, <spell>, ...  live range grid for target, focus, mouseover and enemy
--                                   nameplates; logs every change (RANGE lines)
--   /dp range once                  one-shot of every range API we know (RANGE1 lines)
--   /dp range off
--   /dp brand                       talent + tooltip report, Demonic Brand watch on/off
--   /dp brand scan                  aura scan of target, pet and player now (BSCAN lines)
--
-- Questions (see TEST-0.7.md): can DotWatch dim a row when its spell can't reach the enemy, and
-- can it track Demonic Brand (10 s mark from Searing Pain, the pet's next attacks deal bonus
-- damage) with the charges left?
--
-- Same rules as DotWatch: no secret value is compared, stored or concatenated. Secret values
-- only go into widgets (SetAlphaFromBoolean ...). No geometry of anything that showed a secret
-- is read.

local _, ns = ...
local log, say, issecret = ns.log, ns.say, ns.issecret

local P = {
  range = { on = false, spells = {}, last = {}, cells = {}, elapsed = 0, boolNote = {} },
  brand = { on = true, n = 0, cur = nil, spName = nil, hudUntil = 0 },
}
local BRAND_ID = 1293695 -- Demonic Brand (talent spell, warcraftmaps, build 1.60.1.70938)
local SEARING_PAIN_ID = 5676 -- rank 1 in Classic; only used to get the client's spell name
local BRAND_WINDOW = 13 -- seconds after Searing Pain to log everything about that enemy

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
-- short state text that never touches the content of a secret
local function st(v)
  if issecret(v) then return "S" end
  if v == nil then return "nil" end
  if v == true then return "1" end
  if v == false then return "0" end
  if type(v) == "table" then return "table" end
  if type(v) == "function" then return "fn" end
  return tostring(v)
end

-- call f protected: returns "missing", "ERR <msg>" or st(first result), and the raw value
local function probe(f, ...)
  if type(f) ~= "function" then return "missing", nil end
  local ok, v = pcall(f, ...)
  if not ok then return "ERR " .. tostring(v):sub(1, 90), nil end
  return st(v), v
end

-- true only for a plain true (never tests a secret)
local function isTrue(v) return not issecret(v) and v == true end

local function plainStr(v)
  if issecret(v) or type(v) ~= "string" then return nil end
  return v
end
local function plainNum(v)
  if issecret(v) or type(v) ~= "number" then return nil end
  return v
end

local function guidOf(unit)
  if type(UnitGUID) ~= "function" then return nil end
  local ok, g = pcall(UnitGUID, unit)
  return ok and plainStr(g) or nil
end

local function spellNameOf(id)
  if C_Spell and C_Spell.GetSpellName then
    local ok, n = pcall(C_Spell.GetSpellName, id)
    if ok and plainStr(n) then return n end
  end
  if C_Spell and C_Spell.GetSpellInfo then
    local ok, info = pcall(C_Spell.GetSpellInfo, id)
    if ok and type(info) == "table" and not issecret(info) then return plainStr(info.name) end
  end
  return nil
end

local function spellDesc(id)
  if not (C_Spell and C_Spell.GetSpellDescription) then return "missing" end
  local ok, d = pcall(C_Spell.GetSpellDescription, id)
  if not ok then return "ERR" end
  if issecret(d) then return "S" end
  return tostring(d)
end

-- enemy units the range grid looks at: target, focus, mouseover, enemy nameplates (max 8)
local function enemyUnits()
  local out = { "target", "focus", "mouseover" }
  local plates = 0
  for i = 1, 40 do
    local u = "nameplate" .. i
    local ok, ex = pcall(UnitExists, u)
    if ok and isTrue(ex) then
      local okA, hostile = pcall(UnitCanAttack, "player", u)
      if okA and isTrue(hostile) then
        out[#out + 1] = u
        plates = plates + 1
        if plates >= 8 then break end
      end
    end
  end
  return out
end

---------------------------------------------------------------------------
-- R: range checks
---------------------------------------------------------------------------
-- one spell: id, name, action slot (if it is on an action bar), stated range
local function resolveSpell(text)
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return nil end
  local id = tonumber(text)
  local info
  if C_Spell and C_Spell.GetSpellInfo then
    local ok, v = pcall(C_Spell.GetSpellInfo, id or text)
    if ok and type(v) == "table" and not issecret(v) then info = v end
  end
  if not info then return nil end
  local s = { id = plainNum(info.spellID), name = plainStr(info.name) or text,
    minR = st(info.minRange), maxR = st(info.maxRange) }
  if not s.id then return nil end
  if C_ActionBar and C_ActionBar.FindSpellActionButtons then
    local ok, slots = pcall(C_ActionBar.FindSpellActionButtons, s.id)
    if ok and type(slots) == "table" and not issecret(slots) then s.slot = plainNum(slots[1]) end
  end
  return s
end

-- every range API we know; each returns the raw value (maybe secret) for spell s on unit u
local RANGE_APIS = {
  { key = "cspell", has = function() return C_Spell and C_Spell.IsSpellInRange end,
    get = function(s, u) return C_Spell.IsSpellInRange(s.id, u) end },
  { key = "oldname", has = function() return IsSpellInRange end,
    get = function(s, u) return IsSpellInRange(s.name, u) end },
  { key = "action", has = function() return C_ActionBar and C_ActionBar.IsActionInRange end,
    get = function(s, u) if s.slot then return C_ActionBar.IsActionInRange(s.slot, u) end return "noslot" end },
  { key = "oldaction", has = function() return IsActionInRange end,
    get = function(s, u)
      if not s.slot then return "noslot" end
      if u ~= "target" then return "target only" end
      return IsActionInRange(s.slot)
    end },
}

local function rangeValue(api, s, u)
  if not api.has() then return "missing", nil end
  local ok, v = pcall(api.get, s, u)
  if not ok then return "ERR " .. tostring(v):sub(1, 60), nil end
  return st(v), v
end

-- the grid: one row per unit, one cell (text + square) per spell. The square shows the
-- C_Spell.IsSpellInRange answer: plain -> our own alpha, secret -> SetAlphaFromBoolean.
local function hudBuild()
  if P.hud then return P.hud end
  local fr = CreateFrame("Frame", "DotProbeRangeHUD", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  fr:SetSize(330, 40)
  fr:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 40, -220)
  if fr.SetBackdrop then
    fr:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 12,
      insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    fr:SetBackdropColor(0, 0, 0, 0.75)
  end
  fr.title = fr:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  fr.title:SetPoint("TOPLEFT", 8, -6)
  fr.rows = {}
  P.hud = fr
  return fr
end

local function hudRow(i)
  local fr = hudBuild()
  local r = fr.rows[i]
  if r then return r end
  r = { cells = {} }
  r.label = fr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.label:SetPoint("TOPLEFT", 8, -22 - (i - 1) * 16)
  r.label:SetWidth(96)
  r.label:SetJustifyH("LEFT")
  for c = 1, 4 do
    local cell = {}
    cell.sq = fr:CreateTexture(nil, "OVERLAY")
    cell.sq:SetColorTexture(0.2, 1, 0.3, 1)
    cell.sq:SetSize(10, 10)
    cell.sq:SetPoint("TOPLEFT", 108 + (c - 1) * 56, -24 - (i - 1) * 16)
    cell.text = fr:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cell.text:SetPoint("LEFT", cell.sq, "RIGHT", 3, 0)
    r.cells[c] = cell
  end
  fr.rows[i] = r
  return r
end

-- square for one secret/plain boolean; logs once per API how a secret was handled
local function paintSquare(sq, txt, v)
  if issecret(v) then
    local how
    if sq.SetAlphaFromBoolean then
      local ok, err = pcall(sq.SetAlphaFromBoolean, sq, v, 1, 0.15)
      how = ok and "SetAlphaFromBoolean ok" or ("SetAlphaFromBoolean ERR " .. tostring(err):sub(1, 60))
    elseif C_CurveUtil and C_CurveUtil.EvaluateColorFromBoolean and CreateColor then
      local ok, err = pcall(function()
        local c = C_CurveUtil.EvaluateColorFromBoolean(v, CreateColor(0.2, 1, 0.3, 1), CreateColor(0.2, 1, 0.3, 0.15))
        sq:SetVertexColor(c:GetRGBA())
      end)
      how = ok and "EvaluateColorFromBoolean ok" or ("EvaluateColorFromBoolean ERR " .. tostring(err):sub(1, 60))
    else
      how = "no secret-boolean API"
      sq:SetAlpha(0.5)
    end
    if not P.range.boolNote[how] then
      P.range.boolNote[how] = true
      log("RANGEBOOL", how)
      say("Range answer is secret: " .. how)
    end
    sq:Show()
    txt:SetText("S")
  elseif v == true or v == 1 then
    sq:SetAlpha(1) sq:Show() txt:SetText("1")
  elseif v == false or v == 0 then
    sq:SetAlpha(0.15) sq:Show() txt:SetText("0")
  else
    sq:Hide() txt:SetText(st(v))
  end
end

local function rangeTick()
  local R = P.range
  local units = enemyUnits()
  local fr = hudBuild()
  local combat = InCombatLockdown() and "C" or "-"
  local row = 0
  for _, u in ipairs(units) do
    local ok, ex = pcall(UnitExists, u)
    if ok and isTrue(ex) then
      row = row + 1
      local r = hudRow(row)
      local tgt
      if u ~= "target" then
        local okT, v = pcall(UnitIsUnit, u, "target")
        if okT then tgt = v end
      end
      r.label:SetText(u .. (isTrue(tgt) and " =T" or (issecret(tgt) and " =?" or "")))
      r.label:Show()
      for c = 1, 4 do
        local s = R.spells[c]
        local cell = r.cells[c]
        if s then
          for _, api in ipairs(RANGE_APIS) do
            local txt, raw = rangeValue(api, s, u)
            local key = u .. "|" .. s.id .. "|" .. api.key
            if R.last[key] ~= txt then
              -- the plate token can point at a new enemy: log its GUID with each change
              log("RANGE", string.format("%s %s %s: %s -> %s guid=%s isTarget=%s", u, s.name, api.key,
                tostring(R.last[key]), txt, st(guidOf(u)), st(tgt)))
              R.last[key] = txt
            end
            if api.key == "cspell" then paintSquare(cell.sq, cell.text, raw) end
          end
        else
          cell.sq:Hide() cell.text:SetText("")
        end
      end
    end
  end
  for i = row + 1, #fr.rows do
    local r = fr.rows[i]
    r.label:Hide()
    for _, cell in ipairs(r.cells) do cell.sq:Hide() cell.text:SetText("") end
  end
  fr:SetHeight(30 + math.max(row, 1) * 16)
  local names = {}
  for _, s in ipairs(R.spells) do names[#names + 1] = s.name end
  fr.title:SetText("DotProbe range " .. combat .. ": " .. table.concat(names, " | "))
end

local function rangeOnce()
  local R = P.range
  if #R.spells == 0 then say("Give spells first: /dp range Corruption, Fear") return end
  for _, s in ipairs(R.spells) do
    log("RANGE1", string.format("spell %s id=%d slot=%s minRange=%s maxRange=%s SpellHasRange=%s",
      s.name, s.id, st(s.slot), s.minR, s.maxR, (probe(C_Spell and C_Spell.SpellHasRange, s.id))))
  end
  for _, u in ipairs(enemyUnits()) do
    local ok, ex = pcall(UnitExists, u)
    if ok and isTrue(ex) then
      local parts = {}
      for _, s in ipairs(R.spells) do
        for _, api in ipairs(RANGE_APIS) do
          parts[#parts + 1] = s.name .. "/" .. api.key .. "=" .. (rangeValue(api, s, u))
        end
      end
      -- older checks; CheckInteractDistance may be blocked in combat (watch for BLOCKED lines)
      for i = 1, 4 do parts[#parts + 1] = "interact" .. i .. "=" .. (probe(CheckInteractDistance, u, i)) end
      parts[#parts + 1] = "UnitInRange=" .. (probe(UnitInRange, u))
      parts[#parts + 1] = "UnitDistanceSquared=" .. (probe(UnitDistanceSquared, u))
      log("RANGE1", u .. " guid=" .. st(guidOf(u)) .. " | " .. table.concat(parts, " "))
    end
  end
  local apis = {}
  for _, n in ipairs({ "SetAlphaFromBoolean", "SetVertexColorFromBoolean", "SetShownFromBoolean" }) do
    local tex = hudBuild().title
    apis[#apis + 1] = n .. "=" .. (tex[n] and "yes" or "no")
  end
  apis[#apis + 1] = "EvaluateColorFromBoolean=" .. ((C_CurveUtil and C_CurveUtil.EvaluateColorFromBoolean) and "yes" or "no")
  apis[#apis + 1] = "EnableSpellRangeCheck=" .. ((C_Spell and C_Spell.EnableSpellRangeCheck) and "yes" or "no")
  log("RANGE1", "APIs: " .. table.concat(apis, " "))
  say("Range one-shot logged (RANGE1 lines).")
end

local ev = CreateFrame("Frame")
local function regEvent(e, unit)
  local ok
  if unit then ok = pcall(ev.RegisterUnitEvent, ev, e, unit) else ok = pcall(ev.RegisterEvent, ev, e) end
  if not ok then log("P07", "RegisterEvent " .. e .. " failed") end
  return ok
end

local function setRangeChecks(on)
  if not (C_Spell and C_Spell.EnableSpellRangeCheck) then return end
  for _, s in ipairs(P.range.spells) do pcall(C_Spell.EnableSpellRangeCheck, s.id, on) end
end

local function rangeCommand(rest)
  local R = P.range
  rest = rest or ""
  if rest == "off" then
    R.on = false
    setRangeChecks(false)
    if P.hud then P.hud:Hide() end
    say("Range grid off.")
    return
  elseif rest == "once" then
    rangeOnce()
    return
  end
  if rest ~= "" then
    setRangeChecks(false)
    wipe(R.spells)
    for part in rest:gmatch("[^,]+") do
      local s = resolveSpell(part)
      if s and #R.spells < 4 then
        R.spells[#R.spells + 1] = s
      elseif not s then
        say("Unknown spell: " .. part)
      end
    end
  end
  if #R.spells == 0 then say("Usage: /dp range Corruption, Fear, Death Coil  (max 4)") return end
  wipe(R.last)
  R.on = true
  setRangeChecks(true)
  hudBuild():Show()
  for _, s in ipairs(R.spells) do
    log("RANGE", string.format("watch %s id=%d slot=%s minRange=%s maxRange=%s", s.name, s.id, st(s.slot), s.minR, s.maxR))
    if not s.slot then say(s.name .. " is not on an action bar: the action-bar checks show 'noslot'.") end
  end
  say("Range grid on (" .. #R.spells .. " spells). Green square = in range for C_Spell.IsSpellInRange.")
end

---------------------------------------------------------------------------
-- B: Demonic Brand
---------------------------------------------------------------------------
local function brandName() return spellNameOf(BRAND_ID) or "Demonic Brand" end
local function searingPainName()
  P.brand.spName = P.brand.spName or spellNameOf(SEARING_PAIN_ID) or "Searing Pain"
  return P.brand.spName
end

-- talents: every row-4 talent (any language), plus the one named like the brand
local function talentReport()
  local found = false
  if GetNumTalentTabs and GetNumTalents and GetTalentInfo then
    for tab = 1, plainNum(select(2, pcall(GetNumTalentTabs))) or 0 do
      for i = 1, plainNum(select(2, pcall(GetNumTalents, tab))) or 0 do
        local ok, name, _, tier, column, rank, maxRank = pcall(GetTalentInfo, tab, i)
        local pname = ok and plainStr(name)
        if ok and (plainNum(tier) == 4 or pname == brandName() or pname == "Demonic Brand") then
          log("BTALENT", string.format("tab=%d i=%d tier=%s col=%s name=%s rank=%s/%s", tab, i, st(tier),
            st(column), st(name), st(rank), st(maxRank)))
          if pname and (pname == brandName() or pname == "Demonic Brand") then
            found = true
            say(string.format("Talent %s: rank %s of %s (tab %d, #%d)", st(name), st(rank), st(maxRank), tab, i))
          end
        end
      end
    end
  else
    log("BTALENT", "talent API missing")
  end
  if not found then say("Demonic Brand not found in the talent tree (see BTALENT lines).") end
  log("BTALENT", string.format("IsPlayerSpell(%d)=%s IsSpellKnown=%s name=%s", BRAND_ID,
    (probe(IsPlayerSpell, BRAND_ID)), (probe(IsSpellKnown, BRAND_ID)), st(spellNameOf(BRAND_ID))))
  log("BTALENT", "brand tooltip: " .. spellDesc(BRAND_ID))
  log("BTALENT", "Searing Pain name=" .. searingPainName() .. " tooltip: " .. spellDesc(SEARING_PAIN_ID))
  local fam = select(2, pcall(UnitCreatureFamily, "pet"))
  log("BTALENT", "pet exists=" .. st(select(2, pcall(UnitExists, "pet"))) .. " family=" .. st(fam))
end

local function auraFields(a)
  if issecret(a) then return "S" end
  if type(a) ~= "table" then return st(a) end
  local ok, s = pcall(function()
    return string.format("{id=%s name=%s apps=%s charges=%s dur=%s exp=%s src=%s inst=%s}", st(a.spellId), st(a.name),
      st(a.applications), st(a.charges), st(a.duration), st(a.expirationTime), st(a.sourceUnit), st(a.auraInstanceID))
  end)
  return ok and s or ("fields ERR " .. tostring(s):sub(1, 60))
end

-- every aura read we know, for one unit; filter HARMFUL (enemy) or HELPFUL (pet, player)
local function readAuras(unit, filter, tag, prefix)
  local U = C_UnitAuras
  local parts = {}
  if U and U.GetAuraDataByIndex then
    local list, err = {}, nil
    for i = 1, 20 do
      local ok, a = pcall(U.GetAuraDataByIndex, unit, i, filter)
      if not ok then err = tostring(a):sub(1, 70) break end
      if a == nil then break end
      list[#list + 1] = a
    end
    if err then
      parts[#parts + 1] = "byIndex ERR " .. err
    else
      local shown = {}
      for k = 1, math.min(#list, 8) do shown[#shown + 1] = auraFields(list[k]) end
      parts[#parts + 1] = "byIndex n=" .. #list .. " " .. table.concat(shown, " ")
    end
  else
    parts[#parts + 1] = "byIndex missing"
  end
  local txt, raw = probe(U and U.GetAuraDataBySpellName, unit, brandName(), filter)
  parts[#parts + 1] = "bySpellName=" .. (type(raw) == "table" and auraFields(raw) or txt)
  if unit == "player" then
    txt, raw = probe(U and U.GetPlayerAuraBySpellID, BRAND_ID)
    parts[#parts + 1] = "playerBySpellID=" .. (type(raw) == "table" and auraFields(raw) or txt)
  end
  parts[#parts + 1] = "GetUnitAuraBySpellID=" .. ((U and U.GetUnitAuraBySpellID) and "yes" or "no")
  parts[#parts + 1] = "GetAuraApplicationDisplayCount=" .. ((U and U.GetAuraApplicationDisplayCount) and "yes" or "no")
  log(tag, prefix .. unit .. " " .. filter .. " | " .. table.concat(parts, " | "))
end

local function scanAll(prefix)
  readAuras("target", "HARMFUL", "BSCAN", prefix)
  readAuras("target", "HARMFUL|PLAYER", "BSCAN", prefix)
  readAuras("pet", "HELPFUL", "BSCAN", prefix)
  readAuras("player", "HELPFUL", "BSCAN", prefix)
end

local function brandActive()
  local b = P.brand.cur
  return b and GetTime() - b.t <= BRAND_WINDOW and b or nil
end

local function isBrandUnit(b, unit)
  local g = guidOf(unit)
  if b.guid and g then return g == b.guid end
  if b.guid == nil then
    local ok, same = pcall(UnitIsUnit, unit, "target")
    return ok and isTrue(same)
  end
  return false
end

local function onSearingPain()
  local B = P.brand
  B.n = B.n + 1
  local b = { n = B.n, t = GetTime(), guid = guidOf("target"), hits = 0, fs = 0, lastKey = nil, removedAt = nil }
  B.cur = b
  B.hudUntil = b.t + BRAND_WINDOW + 3
  local fam = select(2, pcall(UnitCreatureFamily, "pet"))
  log("BRAND", string.format("#%d Searing Pain on guid=%s pet=%s family=%s", b.n, st(b.guid),
    st(select(2, pcall(UnitExists, "pet"))), st(fam)))
  for _, dt in ipairs({ 0.05, 0.5, 2, 5, 9, 10.5, 12 }) do
    C_Timer.After(dt, function()
      if B.cur ~= b then return end
      local pre = string.format("#%d +%.2f ", b.n, GetTime() - b.t)
      readAuras("target", "HARMFUL", "BREAD", pre)
      readAuras("pet", "HELPFUL", "BREAD", pre)
      if dt == 0.5 then readAuras("player", "HELPFUL", "BREAD", pre) end
    end)
  end
end

-- brand HUD: one line near the range grid, shown while a brand window runs
local function brandHud()
  if P.bhud then return P.bhud end
  local t = UIParent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  t:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 40, -190)
  P.bhud = t
  return t
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
regEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
regEvent("UNIT_COMBAT")
regEvent("UNIT_AURA")
regEvent("PLAYER_REGEN_ENABLED")
local hasRangeEvent = regEvent("SPELL_RANGE_CHECK_UPDATE")
local petFrame = CreateFrame("Frame")
pcall(petFrame.RegisterUnitEvent, petFrame, "UNIT_SPELLCAST_SUCCEEDED", "pet")
pcall(petFrame.RegisterUnitEvent, petFrame, "UNIT_SPELLCAST_START", "pet")

petFrame:SetScript("OnEvent", function(_, event, unit, castGUID, spellID)
  local b = brandActive()
  if not b then return end
  log("BPET", string.format("#%d +%.2f %s %s id=%s name=%s", b.n, GetTime() - b.t, event:sub(16), st(unit),
    st(spellID), st(plainNum(spellID) and spellNameOf(spellID))))
end)

ev:SetScript("OnEvent", function(_, event, ...)
  if event == "UNIT_SPELLCAST_SUCCEEDED" then
    local _, _, spellID = ...
    local id = plainNum(spellID)
    local name = id and spellNameOf(id)
    if P.brand.on and name and name == searingPainName() then onSearingPain() end
    local b = brandActive()
    if b and name then log("BOWN", string.format("#%d +%.2f own cast %s id=%d", b.n, GetTime() - b.t, name, id)) end
  elseif event == "UNIT_COMBAT" then
    local unit, action, flags, amount, school = ...
    local b = brandActive()
    if not b or not isBrandUnit(b, unit) then return end
    local t = GetTime()
    -- the same hit arrives for target and its nameplate: log it once
    local key = string.format("%.3f|%s|%s|%s", t, st(action), st(flags), st(school))
    if key == b.lastKey then return end
    b.lastKey = key
    b.hits = b.hits + 1
    local sch = plainNum(school)
    if sch == 4 or sch == 32 then b.fs = b.fs + 1 end
    log("BHIT", string.format("#%d +%.3f %s action=%s flags=%s amount=%s school=%s", b.n, t - b.t, st(unit),
      st(action), st(flags), issecret(amount) and "S" or st(amount), st(school)))
  elseif event == "UNIT_AURA" then
    local unit, info = ...
    local b = brandActive()
    if not b then return end
    local isPet, isPlayer = unit == "pet", unit == "player"
    if not (isPet or isPlayer or isBrandUnit(b, unit)) then return end
    local a, u, r, full = "?", "?", "?", "?"
    if type(info) == "table" and not issecret(info) then
      local function ls(x) if issecret(x) then return "S" end return type(x) == "table" and tostring(#x) or "0" end
      a, u, r, full = ls(info.addedAuras), ls(info.updatedAuraInstanceIDs), ls(info.removedAuraInstanceIDs), st(info.isFullUpdate)
      if not isPet and not isPlayer and r ~= "0" and not b.removedAt then b.removedAt = GetTime() - b.t end
    elseif issecret(info) then
      a = "S(info)"
    end
    log("BAURA", string.format("#%d +%.3f %s added=%s updated=%s removed=%s full=%s", b.n, GetTime() - b.t,
      st(unit), a, u, r, full))
  elseif event == "PLAYER_REGEN_ENABLED" then
    if P.brand.on and P.brand.n > 0 then scanAll("after combat ") end
  elseif event == "SPELL_RANGE_CHECK_UPDATE" then
    local spell, inRange, checks = ...
    if P.range.on then log("RANGEEV", string.format("spell=%s inRange=%s checksRange=%s", st(spell), st(inRange), st(checks))) end
  end
end)

local ticker = CreateFrame("Frame")
ticker:SetScript("OnUpdate", function(_, elapsed)
  local R = P.range
  if R.on then
    R.elapsed = R.elapsed + elapsed
    if R.elapsed >= 0.25 then
      R.elapsed = 0
      local ok, err = pcall(rangeTick)
      if not ok and not R.err then R.err = true log("P07", "range tick ERR " .. tostring(err)) say("Range tick error, see log.") end
    end
  end
  local B = P.brand
  if B.hudUntil > 0 then
    local hud = brandHud()
    local b = B.cur
    if b and GetTime() < B.hudUntil then
      hud:SetText(string.format("Brand #%d: %.1f s  hits on it: %d (fire/shadow %d)  aura removed: %s", b.n,
        GetTime() - b.t, b.hits, b.fs, b.removedAt and string.format("+%.1f s", b.removedAt) or "-"))
      hud:Show()
    else
      hud:Hide()
      B.hudUntil = 0
    end
  end
end)

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------
ns.cmd.range = rangeCommand
ns.cmd.brand = function(rest)
  rest = rest or ""
  if rest == "scan" then
    scanAll("manual ")
    say("Aura scan logged (BSCAN lines).")
  elseif rest == "off" then
    P.brand.on = false
    say("Brand watch off.")
  else
    P.brand.on = true
    talentReport()
    say("Brand watch on: every " .. searingPainName() .. " logs 13 s of hits, auras and pet casts on that enemy.")
  end
end

for _, l in ipairs({
  "/dp range <spell>, <spell>  - 0.7: live range grid (target, focus, mouseover, plates), RANGE lines",
  "/dp range once | off        - one-shot of every range API (RANGE1) / grid off",
  "/dp brand [off|scan]        - 0.7: Demonic Brand talent report + watch, aura scan now",
}) do ns.HELP[#ns.HELP + 1] = l end

if not hasRangeEvent then P.range.noEvent = true end
