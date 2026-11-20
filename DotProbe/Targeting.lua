-- DotProbe 0.6: targeting and re-dotting alternatives (test plan: DotProbe/TEST-0.6.md)
--
-- After 0.5 ("a list row can't target or cast on a nameplate mob") this file probes the
-- ways that are left:
--   /dp who        cast attribution: which enemy did a cast really hit, and where did DotWatch book it?
--   /dp hover      cursor HUD: what the game counts as mouseover (mob model, plate, DotWatch bars)
--   /dp keys       DotProbe-owned key buttons (mouseover / soft target / focus casts, set focus)
--                  that log in advance which unit they will hit
--   /dp bind       put those buttons on keys (override bindings: gone after /reload or /dp unbind)
--   /dp rows       clickable rows for fixed units (focus, targettarget, pettarget, party1-4target, boss1-5)
--   /dp rows np    clickable rows for nameplate1-5 (out-of-combat check, closes the 0.5 gap)
--   /dp soft       action targeting on/off (CVar SoftTargetEnemy), old value restored on off
--   /dp units      logs which fixed units exist / are hostile for secure code, and their nameplate
--
-- Same rules as DotWatch: no secret value is compared, stored or concatenated; secret names
-- only go into SetText; no geometry of anything that showed a secret is read.

local _, ns = ...
local log, say, plain, issecret, nonEmpty = ns.log, ns.say, ns.plain, ns.issecret, ns.nonEmpty

local T = { whoChat = true, lastKey = nil, stats = {} }

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
-- short state text that never touches the content of a secret
local function st(v)
  if issecret(v) then return "S" end
  if v == nil then return "nil" end
  if v == true then return "1" end
  if v == false then return "0" end
  return tostring(v)
end

local function call(f, ...)
  if type(f) ~= "function" then return nil, "missing" end
  local ok, v = pcall(f, ...)
  if not ok then return nil, "ERR" end
  return v
end

local function q(f, ...)
  local v, err = call(f, ...)
  if err then return err end
  return st(v)
end

-- readable / secret / missing, for names and GUIDs
local function kind(f, u)
  local v, err = call(f, u)
  if err then return err end
  if issecret(v) then return "S" end
  if v == nil then return "nil" end
  return "ok"
end

-- what secure code (macros, secure buttons) sees: SecureCmdOptionParse from insecure code
local function cond(expr)
  if type(SecureCmdOptionParse) ~= "function" then return "n/a" end
  local ok, r = pcall(SecureCmdOptionParse, expr)
  if not ok then return "ERR" end
  return st(r)
end

-- H = hostile and alive for secure code, e = exists (friendly or dead), - = not there
local function secureState(u)
  return cond("[@" .. u .. ",harm,nodead] H; [@" .. u .. ",exists] e; -")
end

local function plateOf(u)
  if plain(UnitExists, u) ~= true then return nil end
  for i = 1, 40 do
    local np = "nameplate" .. i
    if plain(UnitExists, np) == true and plain(UnitIsUnit, u, np) == true then return np end
  end
  return nil
end

local function spellName(id)
  if issecret(id) or type(id) ~= "number" then return "spell ?" end
  local n = C_Spell and call(C_Spell.GetSpellName, id)
  if type(n) == "string" and not issecret(n) then return n end
  return "spell " .. id
end

local function unitLine(u)
  return string.format("%s api=%s secure=%s plate=%s isTarget=%s guid=%s name=%s", u, q(UnitExists, u),
    secureState(u), plateOf(u) or "-", q(UnitIsUnit, u, "target"), kind(UnitGUID, u), kind(UnitName, u))
end

local function inInstance()
  local ok, i, t = pcall(IsInInstance)
  return (ok and i and "instance/" .. tostring(t)) or "world"
end

local function getCVar(name)
  local fn = (C_CVar and C_CVar.GetCVar) or GetCVar
  local v = call(fn, name)
  if issecret(v) then return nil end
  return v
end

local function setCVar(name, value)
  local fn = (C_CVar and C_CVar.SetCVar) or SetCVar
  local ok, err = pcall(fn, name, value)
  local line = string.format("SetCVar(%s, %s) -> %s, now %s", name, value, ok and "ok" or ("ERR " .. tostring(err)),
    tostring(getCVar(name)))
  log("SOFT", line)
  return line
end

---------------------------------------------------------------------------
-- 1) Cast attribution (/dp who). Always on; chat lines can be switched off.
--    SENT: which units could the cast have gone to (and their plates)?
--    SUCCEEDED: which unit token got UNIT_AURA "added" (or a MISS/RESIST) in the same frame?
--    Then: what did DotWatch write in its SENT debug line ("via <unit>")?
---------------------------------------------------------------------------
local CAND = { "target", "mouseover", "focus", "softenemy", "targettarget", "pettarget",
  "party1target", "party2target", "party3target", "party4target", "boss1", "boss2", "boss3", "boss4", "boss5" }
local SAME_FRAME = 0.06
local FAILS = { MISS = true, RESIST = true, IMMUNE = true, EVADE = true, DODGE = true, PARRY = true,
  BLOCK = true, ABSORB = true, DEFLECT = true, REFLECT = true }

local auraAdd, auraUpd, failAt = {}, {}, {}  -- unit token -> time (failAt: { t, action })
local pend = {}                               -- castGUID -> entry

local function isEnemyToken(u)
  if issecret(u) or type(u) ~= "string" then return false end
  return u == "target" or u == "focus" or u == "mouseover" or u == "softenemy" or u:find("^nameplate%d+$") ~= nil
    or u:find("^boss%d$") ~= nil
end

-- the line DotWatch wrote for this cast (SENT ... via <unit>, or IGNORE ...)
local function dotWatchVia(tSent)
  local l = type(DotWatchDB) == "table" and DotWatchDB.debug
  if type(l) ~= "table" then return nil, "DotWatch not loaded" end
  for i = #l, math.max(1, #l - 60), -1 do
    local line = l[i]
    if type(line) == "string" then
      local ts, msg = line:match("^(%d+%.%d+) [C%-] (.*)$")
      local t = tonumber(ts)
      if t and t < tSent - 0.05 then break end
      if t and msg and t <= tSent + 0.05 then
        local via = msg:match("^SENT .- via (.+)$")
        if via then return (via:gsub("%s*%(.*%)$", "")), msg end
        if msg:find("^IGNORE ") then return "IGNORED", msg end
      end
    end
  end
  return nil, "no DotWatch SENT line (spell not tracked?)"
end

local function onSent(destName, castGUID, spellID)
  if issecret(castGUID) or type(castGUID) ~= "string" then return end
  local e = { t = GetTime(), id = spellID, spell = spellName(spellID), cand = {}, hostile = 0,
    dest = issecret(destName) and "SECRET" or (destName == nil and "nil" or ('"' .. tostring(destName) .. '"')) }
  for _, u in ipairs(CAND) do
    local s = secureState(u)
    if s ~= "-" or plain(UnitExists, u) == true then
      local c = { u = u, np = plateOf(u), s = s }
      local n = plain(UnitName, u)
      if type(n) == "string" and not issecret(destName) and n == destName then c.sameName = true end
      if s == "H" then e.hostile = e.hostile + 1 end
      e.cand[#e.cand + 1] = c
    end
  end
  e.moIsTarget = q(UnitIsUnit, "mouseover", "target")
  local k = T.lastKey
  if k and e.t - k.t < 0.5 then e.key = k T.lastKey = nil end
  pend[castGUID] = e
end

local function candText(e)
  local p = {}
  for _, c in ipairs(e.cand) do
    p[#p + 1] = string.format("%s=%s%s%s", c.u, c.np or "noplate", c.s == "H" and "" or ("(" .. c.s .. ")"),
      c.sameName and "*" or "")
  end
  return #p > 0 and table.concat(p, " ") or "no units"
end

local function near(tbl, tok, t0)
  local v = tbl[tok]
  if type(v) == "table" then v = v.t end
  return v ~= nil and math.abs(v - t0) <= SAME_FRAME
end

local function evaluate(e)
  local t0 = e.tS
  -- 1. which candidate units were hit (aura added, or a fail message) in the same frame?
  local hit, hitSet, how = {}, {}, nil
  for _, c in ipairs(e.cand) do
    local res
    if near(auraAdd, c.u, t0) or (c.np and near(auraAdd, c.np, t0)) then res = "added"
    elseif near(failAt, c.u, t0) then res = failAt[c.u].action
    elseif c.np and near(failAt, c.np, t0) then res = failAt[c.np].action
    elseif near(auraUpd, c.u, t0) or (c.np and near(auraUpd, c.np, t0)) then res = "updated?" end
    if res then
      c.res = res
      if res ~= "updated?" then hit[#hit + 1] = c.u hitSet[c.u] = true how = how or res end
    end
  end
  -- plates hit that no candidate explains
  local other = {}
  for tok, t in pairs(auraAdd) do
    if math.abs(t - t0) <= SAME_FRAME and tok:find("^nameplate") then
      local known = false
      for _, c in ipairs(e.cand) do if c.np == tok then known = true end end
      if not known then other[#other + 1] = tok end
    end
  end
  if #hit == 0 and #other == 0 and e.hostile == 0 then return end -- a buff or a self cast: no noise

  local actual
  if #hit > 0 then actual = table.concat(hit, "+") .. " (" .. how .. ")"
  elseif #other > 0 then actual = "unlisted " .. table.concat(other, "+")
  else actual = "unknown (no aura added, no fail; a refresh shows as updated?)" end

  -- 2. DotWatch's booking
  local via, dwLine = dotWatchVia(e.t)
  local verdict
  if not via then verdict = "no DotWatch line"
  elseif via == "IGNORED" then verdict = "DotWatch ignored it"
  elseif #hit == 0 then verdict = "unclear"
  else
    local ok = hitSet[via] == true
    if not ok then
      -- DotWatch may name a nameplate token: same plate as a hit unit?
      for _, c in ipairs(e.cand) do if hitSet[c.u] and c.np and c.np == via then ok = true end end
    end
    verdict = ok and "OK" or "MISMATCH"
  end

  -- 3. own key button: was the prediction right?
  local keyText = ""
  if e.key then
    local kOk = (e.key.pred ~= "none" and hitSet[e.key.pred]) and "OK" or (#hit == 0 and "unclear" or "WRONG")
    keyText = string.format(" | key %s predicted %s -> %s", e.key.id, e.key.pred, kOk)
    T.stats["key " .. e.key.id .. " " .. kOk] = (T.stats["key " .. e.key.id .. " " .. kOk] or 0) + 1
  end
  T.stats["DotWatch " .. verdict] = (T.stats["DotWatch " .. verdict] or 0) + 1

  local line = string.format("%s dest=%s %s | units: %s | mo=target:%s | hit: %s | DotWatch via %s -> %s%s",
    e.spell, e.dest, inInstance(), candText(e), e.moIsTarget, actual, tostring(via), verdict, keyText)
  log("WHO", line)
  if dwLine and via then log("WHO", "  DotWatch: " .. dwLine) end
  if T.whoChat then
    local color = (verdict == "MISMATCH" or keyText:find("WRONG")) and "|cffff5555"
      or (verdict == "OK" and "|cff55ff55" or "|cffffcc00")
    say(color .. "WHO " .. e.spell .. ": hit " .. actual .. " | DotWatch via " .. tostring(via) .. " -> " .. verdict ..
      keyText .. "|r")
  end
end

local wf = CreateFrame("Frame")
wf:RegisterUnitEvent("UNIT_SPELLCAST_SENT", "player")
wf:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
wf:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player")
wf:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player")
wf:RegisterEvent("UNIT_AURA")
wf:RegisterEvent("UNIT_COMBAT")
wf:SetScript("OnEvent", function(_, ev, a1, a2, a3, a4)
  if ev == "UNIT_AURA" then
    if not isEnemyToken(a1) or type(a2) ~= "table" or issecret(a2) then return end
    local now = GetTime()
    if nonEmpty(a2.addedAuras) then auraAdd[a1] = now end
    if nonEmpty(a2.updatedAuraInstanceIDs) then auraUpd[a1] = now end
  elseif ev == "UNIT_COMBAT" then
    if isEnemyToken(a1) and not issecret(a2) and FAILS[a2] then failAt[a1] = { t = GetTime(), action = a2 } end
  elseif ev == "UNIT_SPELLCAST_SENT" then
    onSent(a2, a3, a4)
  elseif ev == "UNIT_SPELLCAST_SUCCEEDED" then
    if issecret(a2) or type(a2) ~= "string" then return end
    local e = pend[a2]
    if not e then return end
    pend[a2] = nil
    e.tS = GetTime()
    C_Timer.After(0.25, function() evaluate(e) end)
  else
    if not issecret(a2) and type(a2) == "string" then pend[a2] = nil end
  end
end)

---------------------------------------------------------------------------
-- 2) Hover HUD (/dp hover): text next to the cursor, logged on every change
---------------------------------------------------------------------------
local function mouseFocusName()
  local fr
  if GetMouseFoci then
    local t = call(GetMouseFoci)
    if type(t) == "table" then fr = t[1] end
  elseif GetMouseFocus then
    fr = call(GetMouseFocus)
  end
  if not fr then return "none" end
  local n = call(fr.GetDebugName, fr) or call(fr.GetName, fr)
  if issecret(n) or type(n) ~= "string" or n == "" then return "<unnamed frame>" end
  return n
end

local hv = {}
local function hoverBuild()
  local f = CreateFrame("Frame", nil, UIParent)
  f:SetSize(300, 34)
  f:SetFrameStrata("TOOLTIP")
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, 0.7)
  hv.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  hv.text:SetPoint("TOPLEFT", 4, -4)
  hv.text:SetPoint("BOTTOMRIGHT", -4, 4)
  hv.text:SetJustifyH("LEFT")
  local acc = 0
  f:SetScript("OnUpdate", function(self, el)
    local x, y = GetCursorPosition()
    local s = UIParent:GetEffectiveScale()
    self:ClearAllPoints()
    self:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x / s + 18, y / s + 18)
    acc = acc + el
    if acc < 0.1 then return end
    acc = 0
    local exists = plain(UnitExists, "mouseover") == true
    local np = plateOf("mouseover")
    local harm = cond("[@mouseover,harm,nodead] yes; no")
    local over = mouseFocusName()
    local tgt = exists and q(UnitIsUnit, "mouseover", "target") or "-"
    local txt = string.format("mouseover: %s  harm+nodead: %s  is target: %s\nmouse over frame: %s",
      exists and (np or "no plate") or "none", harm, tgt, over)
    hv.text:SetText(txt)
    local sig = txt
    if sig ~= hv.last then
      hv.last = sig
      log("HOVER", (txt:gsub("\n", " | ")) .. " | combat=" .. tostring(InCombatLockdown()))
    end
  end)
  hv.frame = f
end

local function hoverCommand(rest)
  if rest == "off" then
    if hv.frame then hv.frame:Hide() end
    say("Hover HUD off.")
    return
  end
  if not hv.frame then hoverBuild() end
  hv.frame:Show()
  say("Hover HUD on: hover the mob, its nameplate, DotWatch letters/bars, the DotWatch list. /dp hover off")
end

---------------------------------------------------------------------------
-- 3) Own key buttons (/dp keys, /dp bind). The PreClick hook (insecure) asks the same
--    conditional the macro uses which unit it will hit -> exact attribution would be possible.
---------------------------------------------------------------------------
local KEYS = {
  mo = { name = "DotProbeKeyMO", cast = "[@mouseover,harm,nodead][]",
    pred = "[@mouseover,harm,nodead] mouseover; [@target,harm,nodead] target; none" },
  soft = { name = "DotProbeKeySoft", cast = "[@softenemy,harm,nodead][]",
    pred = "[@softenemy,harm,nodead] softenemy; [@target,harm,nodead] target; none" },
  focus = { name = "DotProbeKeyFocus", cast = "[@focus,harm,nodead][]",
    pred = "[@focus,harm,nodead] focus; [@target,harm,nodead] target; none" },
  setfocus = { name = "DotProbeKeySetFocus", macro = "/focus [@mouseover,harm,nodead]",
    pred = "[@mouseover,harm,nodead] mouseover; none" },
}
local KEY_ORDER = { "mo", "soft", "focus", "setfocus" }
local bindOwner = CreateFrame("Frame")
T.spell = "Corruption"

local function keyPre(id, button, down)
  local k = KEYS[id]
  local now = GetTime()
  if k.lastT and now - k.lastT < 0.25 then return end -- down + up of one press
  k.lastT = now
  local pred = cond(k.pred)
  local np = (pred ~= "none" and pred ~= "S" and pred ~= "ERR") and plateOf(pred) or nil
  T.lastKey = { id = id, t = now, pred = pred }
  local line = string.format("%s pressed (%s down=%s) combat=%s -> will hit %s (%s) | target plate=%s focus plate=%s",
    id, tostring(button), tostring(down), tostring(InCombatLockdown()), pred, np or "no plate",
    plateOf("target") or "-", plateOf("focus") or "-")
  log("KEY", line)
  if id == "setfocus" then
    C_Timer.After(0.3, function()
      local r = string.format("setfocus result: focus=%s secure=%s (mouseover was %s)", plateOf("focus") or "no plate",
        secureState("focus"), np or pred)
      log("KEY", r)
      say(r)
    end)
  end
end

local function keyBuild(spell)
  if InCombatLockdown() then say("Only out of combat.") return false end
  T.spell = spell or T.spell
  for _, id in ipairs(KEY_ORDER) do
    local k = KEYS[id]
    if not k.btn then
      local b = CreateFrame("Button", k.name, UIParent, "SecureActionButtonTemplate")
      b:SetSize(1, 1)
      b:SetPoint("TOPLEFT", UIParent, "BOTTOMRIGHT", 20, -20) -- off screen, keybind only
      b:RegisterForClicks("AnyUp", "AnyDown")
      b:SetAttribute("type", "macro")
      b:HookScript("PreClick", function(_, button, down) keyPre(id, button, down) end)
      k.btn = b
    end
    k.btn:SetAttribute("macrotext", k.macro or ("/cast " .. k.cast .. " " .. T.spell))
  end
  log("KEY", "buttons built, spell=" .. T.spell)
  return true
end

local function keysCommand(rest)
  if not keyBuild(rest ~= "" and rest or nil) then return end
  say("Key buttons ready for " .. T.spell .. ". Put them on keys: /dp bind mo <KEY>, /dp bind soft <KEY>, " ..
    "/dp bind focus <KEY>, /dp bind setfocus <KEY>. Or in a macro: /click DotProbeKeyMO")
end

local function bindCommand(rest)
  local id, key = rest:match("^(%S+)%s+(%S+)$")
  id = id and id:lower()
  if not (id and KEYS[id]) then say("Usage: /dp bind <mo|soft|focus|setfocus> <KEY>  e.g. /dp bind mo F") return end
  if InCombatLockdown() then say("Only out of combat.") return end
  if not KEYS[id].btn and not keyBuild() then return end
  key = key:upper()
  local ok, err = pcall(SetOverrideBindingClick, bindOwner, true, key, KEYS[id].name, "LeftButton")
  local line = string.format("bind %s -> %s: %s", key, KEYS[id].name, ok and "ok" or ("ERR " .. tostring(err)))
  log("KEY", line)
  say(line .. " (temporary: /dp unbind or /reload removes it)")
end

local function unbindCommand()
  if InCombatLockdown() then say("Only out of combat.") return end
  pcall(ClearOverrideBindings, bindOwner)
  say("DotProbe key bindings removed. Your normal bindings are back.")
end

---------------------------------------------------------------------------
-- 4) Clickable rows (/dp rows [spell] | /dp rows np | /dp rows off)
--    Left click = target that unit, right click = cast the spell on it.
--    Fixed units are shown by the game (RegisterUnitWatch, works in combat);
--    nameplate rows are just shown (out-of-combat test only).
---------------------------------------------------------------------------
local ROW_UNITS = { "focus", "targettarget", "pettarget", "party1target", "party2target", "party3target",
  "party4target", "boss1", "boss2", "boss3", "boss4", "boss5" }
local NP_UNITS = { "nameplate1", "nameplate2", "nameplate3", "nameplate4", "nameplate5" }
local ROW_H = 20
local panels = {}

local function rowClicked(u, button)
  local before = plateOf("target") or (plain(UnitExists, "target") and "noplate" or "none")
  local was = plain(UnitIsUnit, "target", u)
  if button == "RightButton" then
    T.lastKey = { id = "row " .. u, t = GetTime(), pred = u }
  end
  C_Timer.After(0.3, function()
    local line
    if button == "RightButton" then
      line = string.format("row %s RIGHT (cast) combat=%s: see the WHO line", u, tostring(InCombatLockdown()))
    else
      local now = plain(UnitIsUnit, "target", u)
      local res = (was == true and "na (was already your target)") or (now == true and "OK" or "BAD")
      line = string.format("row %s LEFT (target) combat=%s -> %s | unit secure=%s, target before=%s after=%s",
        u, tostring(InCombatLockdown()), res, secureState(u), before, plateOf("target") or "?")
    end
    log("ROW", line)
    say(line)
  end)
end

local function buildPanel(key, units, title, x, y, watch)
  local p = CreateFrame("Frame", "DotProbeRows_" .. key, UIParent)
  p:SetSize(250, 26 + #units * ROW_H)
  p:SetPoint("CENTER", UIParent, "CENTER", x, y)
  p:SetMovable(true)
  p:EnableMouse(true)
  p:RegisterForDrag("LeftButton")
  p:SetScript("OnDragStart", function(self) if not InCombatLockdown() then self:StartMoving() end end)
  p:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  local bg = p:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, 0.6)
  p.title = p:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  p.title:SetPoint("TOPLEFT", 6, -6)
  p.title:SetText(title)
  p.rows = {}
  for i, u in ipairs(units) do
    local b = CreateFrame("Button", "DotProbeRow_" .. key .. i, p, "SecureActionButtonTemplate")
    b:SetSize(238, ROW_H - 2)
    b:SetPoint("TOPLEFT", 6, -22 - (i - 1) * ROW_H)
    b:RegisterForClicks("AnyUp", "AnyDown")
    b:SetAttribute("unit", u)
    b:SetAttribute("type1", "target")
    b:SetAttribute("type2", "spell")
    b:SetAttribute("spell", T.spell)
    local t = b:CreateTexture(nil, "BACKGROUND")
    t:SetAllPoints()
    t:SetColorTexture(0.35, 0.1, 0.4, 0.7)
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    b.unitText = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.unitText:SetPoint("LEFT", 4, 0)
    b.unitText:SetWidth(150)
    b.unitText:SetJustifyH("LEFT")
    -- the (maybe secret) name gets its own string, anchored, never measured
    b.nameText = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.nameText:SetPoint("LEFT", 156, 0)
    b.nameText:SetPoint("RIGHT", -4, 0)
    b.nameText:SetJustifyH("LEFT")
    local lastClick = 0
    b:HookScript("OnClick", function(_, button)
      local now = GetTime()
      if now - lastClick < 0.2 then return end -- down + up of one click
      lastClick = now
      rowClicked(u, button)
    end)
    if watch then RegisterUnitWatch(b) else b:Show() end
    p.rows[i] = { b = b, u = u }
  end
  local acc = 0
  p:SetScript("OnUpdate", function(_, el)
    acc = acc + el
    if acc < 0.3 then return end
    acc = 0
    for _, r in ipairs(p.rows) do
      local u = r.u
      r.b.unitText:SetText(string.format("%s %s %s", u, secureState(u), plateOf(u) or ""))
      if plain(UnitExists, u) == true then
        pcall(r.b.nameText.SetText, r.b.nameText, (UnitName(u)))
      else
        r.b.nameText:SetText("-")
      end
    end
  end)
  panels[key] = p
  return p
end

local function rowsCommand(rest)
  if InCombatLockdown() then say("Only out of combat (secure buttons).") return end
  if rest == "off" then
    for _, p in pairs(panels) do p:Hide() end
    say("Rows hidden.")
    return
  end
  if rest == "np" then
    local p = panels.np or buildPanel("np", NP_UNITS, "DotProbe: nameplate1-5 (out of combat)", -380, -120, false)
    p:Show()
    log("ROW", "nameplate rows on")
    say("Nameplate rows on. OUT of combat: left click = target, right click = " .. T.spell .. ".")
    return
  end
  if rest ~= "" then T.spell = rest end
  local p = panels.fixed or buildPanel("fixed", ROW_UNITS, "DotProbe: fixed units (L target, R cast)", -380, 160, true)
  for _, r in ipairs(p.rows) do r.b:SetAttribute("spell", T.spell) end
  if panels.np then for _, r in ipairs(panels.np.rows) do r.b:SetAttribute("spell", T.spell) end end
  p:Show()
  log("ROW", "fixed rows on, spell=" .. T.spell)
  say("Fixed-unit rows on (" .. T.spell .. "). A row appears while its unit exists. Left = target, right = cast.")
end

---------------------------------------------------------------------------
-- 5) Soft targeting (/dp soft on|off|status)
---------------------------------------------------------------------------
local function softCommand(rest)
  local cur = getCVar("SoftTargetEnemy")
  if rest == "status" or rest == "" then
    local line = string.format("SoftTargetEnemy=%s | %s", tostring(cur), unitLine("softenemy"))
    say(line)
    log("SOFT", line)
    return
  end
  if InCombatLockdown() then say("Only out of combat (CVars).") return end
  if cur == nil then say("SoftTargetEnemy does not exist on this client.") log("SOFT", "CVar missing") return end
  local db = DotProbeDB
  if rest == "on" then
    if db.softOrig == nil then db.softOrig = cur end
    say(setCVar("SoftTargetEnemy", "3") .. " (old value " .. tostring(db.softOrig) .. " kept for /dp soft off)")
  elseif rest == "off" then
    say(setCVar("SoftTargetEnemy", db.softOrig or "0"))
    db.softOrig = nil
  else
    say("Usage: /dp soft on | off | status")
  end
end

---------------------------------------------------------------------------
-- 6) Unit monitor (/dp units [off]): logs every change of the fixed units
---------------------------------------------------------------------------
local MON = { "target", "focus", "targettarget", "focustarget", "mouseovertarget", "pet", "pettarget",
  "party1target", "party2target", "party3target", "party4target", "boss1", "boss2", "boss3", "boss4", "boss5",
  "softenemy", "softinteract", "anyenemy" }
local um = { on = false, last = {} }

local function umBuild()
  local f = CreateFrame("Frame", nil, UIParent)
  f:SetSize(250, 40)
  f:SetPoint("CENTER", UIParent, "CENTER", 380, 160)
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, 0.6)
  um.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  um.text:SetPoint("TOPLEFT", 6, -6)
  um.text:SetJustifyH("LEFT")
  local acc = 0
  f:SetScript("OnUpdate", function(self, el)
    acc = acc + el
    if acc < 0.5 then return end
    acc = 0
    local shown = { "DotProbe units (H = hostile for macros)" }
    for _, u in ipairs(MON) do
      local line = unitLine(u)
      if line ~= um.last[u] then
        um.last[u] = line
        log("UNITS", line .. " | " .. inInstance())
      end
      local s = secureState(u)
      if s ~= "-" or plain(UnitExists, u) == true then
        shown[#shown + 1] = string.format("%s  %s  %s", u, s, plateOf(u) or "no plate")
      end
    end
    um.text:SetText(table.concat(shown, "\n"))
    self:SetHeight(14 + #shown * 13)
  end)
  um.frame = f
end

local function unitsCommand(rest)
  if rest == "off" then
    if um.frame then um.frame:Hide() end
    say("Unit monitor off.")
    return
  end
  if not um.frame then umBuild() end
  um.last = {}
  um.frame:Show()
  log("UNITS", "monitor on | " .. inInstance())
  say("Unit monitor on (logs every change). /dp units off")
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------
ns.cmd.who = function(rest)
  if rest == "stats" then
    local any = false
    for k, n in pairs(T.stats) do any = true say(k .. ": " .. n) log("WHOSTAT", k .. "=" .. n) end
    if not any then say("No attributed casts yet.") end
    return
  end
  T.whoChat = not T.whoChat
  say("WHO chat lines " .. (T.whoChat and "on" or "off") .. " (the log always gets them while recording)")
end
ns.cmd.hover = hoverCommand
ns.cmd.keys = keysCommand
ns.cmd.bind = bindCommand
ns.cmd.unbind = unbindCommand
ns.cmd.rows = rowsCommand
ns.cmd.soft = softCommand
ns.cmd.units = unitsCommand

for _, l in ipairs({
  "--- 0.6 targeting tests (DotProbe/TEST-0.6.md) ---",
  "/dp who            - WHO chat lines on/off; /dp who stats = summary",
  "/dp hover [off]    - cursor HUD: what counts as mouseover",
  "/dp keys [spell]   - build key buttons (mouseover/soft/focus cast, set focus)",
  "/dp bind <mo|soft|focus|setfocus> <KEY> - temporary key binding; /dp unbind",
  "/dp rows [spell|np|off] - clickable rows: fixed units / nameplate1-5",
  "/dp soft <on|off|status> - action targeting CVar (restored on off)",
  "/dp units [off]    - log fixed units (focus, party targets, boss, softenemy)",
}) do ns.HELP[#ns.HELP + 1] = l end
