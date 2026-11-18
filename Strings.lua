-- DotWatch: interface texts in other languages (0.18).
--
-- DotWatch.lua writes its texts in English and looks each one up here: L["Lock window"].
-- A text without a translation stays English. The language files (Strings_deDE.lua,
-- Strings_ruRU.lua, Strings_zhCN.lua, Strings_zhTW.lua) fill ns.STRINGS[tag] with
-- { [English text] = translation }.
--
-- Which language: the option "Language" (DotWatchDB.lang), else the client's (GetLocale).
-- 0.18.1: the language is fixed once the saved variables are loaded (ns.freezeLanguage, called
-- by DotWatch.lua on ADDON_LOADED) and only changes with a /reload. Before that, lookups use the
-- client language; DotWatch.lua sets the few texts made while loading again after ADDON_LOADED.
-- /dw lang auto brings back the client language if a chosen one can't be read.
--
-- Spell names never come from here: the game names them in its own language.

local _, ns = ...

ns.STRINGS = {}
ns.LANGUAGES = {
  { tag = "auto", label = "Automatic (client language)" },
  { tag = "enUS", label = "English" },
  { tag = "deDE", label = "Deutsch (German)" },
  { tag = "ruRU", label = "Русский (Russian)" },
  { tag = "zhCN", label = "简体中文 (Chinese, simplified)" },
  { tag = "zhTW", label = "繁體中文 (Chinese, traditional)" },
}

function ns.clientTag()
  local tag = GetLocale and GetLocale() or "enUS"
  if tag == "enGB" then tag = "enUS" end
  return tag
end

-- the language to use: the saved choice if there is one, else the client's
function ns.languageTag()
  local db = DotWatchDB
  local choice = type(db) == "table" and db.lang
  if type(choice) == "string" and choice ~= "auto" and (choice == "enUS" or ns.STRINGS[choice]) then
    return choice
  end
  return ns.clientTag()
end

-- Russian and Chinese need a client whose font has those letters (a Russian or Chinese one)
function ns.readable(tag)
  local client = ns.clientTag()
  if tag == "ruRU" then return client == "ruRU" end
  if tag == "zhCN" or tag == "zhTW" then return client == "zhCN" or client == "zhTW" end
  return true
end

-- "de", "DEDE", "zh-tw", "cn" ... -> a tag from ns.LANGUAGES, or nil
local ALIASES = { auto = "auto", en = "enUS", enus = "enUS", engb = "enUS", english = "enUS",
  de = "deDE", dede = "deDE", deutsch = "deDE", german = "deDE",
  ru = "ruRU", ruru = "ruRU", russian = "ruRU",
  zh = "zhCN", cn = "zhCN", zhcn = "zhCN", tw = "zhTW", zhtw = "zhTW" }
function ns.findLanguage(word)
  word = type(word) == "string" and word:lower():gsub("[%-_ ]", "") or ""
  return ALIASES[word]
end

local active, dict -- nil until ns.freezeLanguage()
function ns.freezeLanguage()
  active = ns.languageTag()
  dict = ns.STRINGS[active]
  ns.active = active
  return active
end

ns.L = setmetatable({}, {
  __index = function(cache, key)
    if key == nil then return "" end
    local d = dict
    if not active then d = ns.STRINGS[ns.languageTag()] end
    local text = d and d[key]
    if text == nil or text == "" then text = key end
    if active and type(key) == "string" then rawset(cache, key, text) end -- fixed language: remember
    return text
  end,
})
