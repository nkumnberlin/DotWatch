-- DotWatch: interface texts in other languages (0.18).
--
-- DotWatch.lua writes its texts in English and looks each one up here: L["Lock window"].
-- A text without a translation stays English. The language files (Strings_deDE.lua,
-- Strings_ruRU.lua, Strings_zhCN.lua, Strings_zhTW.lua) fill ns.STRINGS[tag] with
-- { [English text] = translation }.
--
-- Which language: the option "Language" (DotWatchDB.lang), else the client's (GetLocale).
-- The saved option is only known after the saved variables load, so the few texts made
-- while the addon loads are set again by DotWatch.lua after ADDON_LOADED, and a change of
-- the option needs a /reload.
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

local function clientTag()
  local tag = GetLocale and GetLocale() or "enUS"
  if tag == "enGB" then tag = "enUS" end
  return tag
end

-- the language in use: the saved choice if there is one, else the client's
function ns.languageTag()
  local db = DotWatchDB
  local choice = type(db) == "table" and db.lang
  if type(choice) == "string" and choice ~= "auto" and (choice == "enUS" or ns.STRINGS[choice]) then
    return choice
  end
  return clientTag()
end

ns.L = setmetatable({}, {
  __index = function(_, key)
    if key == nil then return "" end
    local dict = ns.STRINGS[ns.languageTag()]
    local text = dict and dict[key]
    if text == nil or text == "" then return key end
    return text
  end,
})
