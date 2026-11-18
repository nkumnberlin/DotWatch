-- DotWatch: other client languages for reading spell tooltips (0.16).
--
-- DotWatch.lua reads English descriptions ("822 Shadow damage over 18 sec"). Descriptions it
-- can't read go to the language files (Locale_deDE.lua, Locale_ruRU.lua, Locale_zhCN.lua,
-- which also reads Traditional Chinese / zhTW). Every language is asked in turn, whatever
-- GetLocale() says: one language's patterns can't match another's text.
--
-- The registry here is DotWatch's own; the language files are copied from Smooth Animated Bars
-- 1.11.0, which ported them from DoesItDie 0.9.3. Their notices:
--
-- MIT License
--
-- Copyright (c) 2026 Joe Greive  (DoesItDie)
-- Copyright (c) 2026 Jordan      (Smooth Animated Bars)
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
-- documentation files (the "Software"), to deal in the Software without restriction, including without
-- limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the
-- Software, and to permit persons to whom the Software is furnished to do so, subject to the following
-- conditions:
--
-- The above copyright notice and this permission notice shall be included in all copies or substantial portions
-- of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED
-- TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
-- THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
-- CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
-- DEALINGS IN THE SOFTWARE.

local _, ns = ...

local L = { languages = {} }
ns.locale = L

function L.register(language)
  if type(language) == "table" and type(language.tag) == "string" then
    table.insert(L.languages, language)
  end
end

-- The first language that reads `desc` as a DoT: total damage, school, duration, tick interval.
-- A reader tripping over text it wasn't written for only means it didn't read it.
function L.parseDot(desc, comboPoints)
  if type(desc) ~= "string" or desc == "" then return nil end
  for _, language in ipairs(L.languages) do
    if type(language.parseDot) == "function" then
      local ok, total, school, duration, interval = pcall(language.parseDot, desc, comboPoints)
      if ok and type(total) == "number" and type(duration) == "number" then
        return total, school, duration, interval
      end
    end
  end
end
