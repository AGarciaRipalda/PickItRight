-- Prueba de humo standalone (no requiere el cliente de WoW). Ejecutar desde
-- la raíz del repo con cualquier intérprete Lua 5.1:
--   lua5.1 tests/test_UIIntegration.lua

_G.hooksecurefunc = function(tbl, name, hookFn)
	local original = tbl[name]
	tbl[name] = function(self, ...)
		if original then
			original(self, ...)
		end
		hookFn(self, ...)
	end
end

local GameTooltip = {
	lines = {},
	SetLootItem = function() end,
	SetLootRollItem = function() end,
	SetQuestItem = function() end,
	SetBagItem = function() end,
	AddLine = function(self, text) table.insert(self.lines, text) end,
	Show = function() end,
}
_G.GameTooltip = GameTooltip

local mockLootLinks = {} -- [slot] = itemLink
_G.GetLootSlotLink = function(slot) return mockLootLinks[slot] end

local mockBagLinks = {} -- [bag] = {[slot] = itemLink}
_G.GetContainerItemLink = function(bag, slot) return mockBagLinks[bag] and mockBagLinks[bag][slot] end

local ns = {}
local mockLootResults = {} -- [itemLink] = entry
local mockRollResults = {} -- [rollID] = entry
local mockQuestResults = {} -- ["tipo:índice"] = entry
local mockBagResults = {} -- [itemLink] = entry
ns.GetLootResult = function(itemLink) return mockLootResults[itemLink] end
ns.GetRollResult = function(rollID) return mockRollResults[rollID] end
ns.GetQuestRewardResult = function(kind, i) return mockQuestResults[kind .. ":" .. i] end
ns.GetBagItemResult = function(itemLink) return mockBagResults[itemLink] end

local moduleEnabled = true -- normalmente de AddonSettings.lua (Fase 8)
ns.IsModuleEnabled = function() return moduleEnabled end

assert(loadfile("UIIntegration.lua"))("PickItRight", ns)

local function assertEqual(actual, expected, label)
	assert(actual == expected, ("%s: esperado %s, obtenido %s"):format(label, tostring(expected), tostring(actual)))
end

local function lastLine()
	return GameTooltip.lines[#GameTooltip.lines]
end

-- --- FormatScoreLine (función pura) --------------------------------------

local upgradeLine = ns.FormatScoreLine({ isUpgrade = true, score = 12.34 })
assert(upgradeLine:find("|cff33ff33"), "verde: color de mejora clara")
assert(upgradeLine:find("12.3"), "verde: incluye el score")

local notUpgradeLine = ns.FormatScoreLine({ isUpgrade = false, score = 5, equippedScore = 20 })
assert(notUpgradeLine:find("|cff999999"), "gris: color de no-mejora")
assert(notUpgradeLine:find("5.0") and notUpgradeLine:find("20.0"), "gris: incluye ambos scores")

local noComparisonLine = ns.FormatScoreLine({ isUpgrade = nil, score = 7 })
assert(noComparisonLine:find("|cff999999"), "gris: color cuando no hay comparación")
assert(noComparisonLine:find("Puntaje"), "gris: rotulado como puntaje simple, no mejora/no-mejora")

-- --- Hook de la ventana de loot (SetLootItem) -----------------------------

mockLootLinks[1] = "item:1"
mockLootResults["item:1"] = { result = { eligible = true, isUpgrade = true, score = 15 } }
GameTooltip:SetLootItem(1)
assert(lastLine():find("|cff33ff33"), "loot: item elegible y mejora sale en verde")

mockLootLinks[2] = "item:2"
mockLootResults["item:2"] = { result = { eligible = false, reason = "Tipo de armadura incorrecto" } }
GameTooltip:SetLootItem(2)
assertEqual(lastLine(), "|cffff4444Tipo de armadura incorrecto|r", "loot: item rechazado sale en rojo con el motivo exacto")

mockLootLinks[3] = "item:3" -- sin entrada en mockLootResults todavía (hueco async)
GameTooltip:SetLootItem(3)
assert(lastLine():find("analizando"), "loot: sin resultado todavía muestra placeholder, no error")

-- --- Hook de tiradas de grupo (SetLootRollItem) ---------------------------

mockRollResults[99] = { result = { eligible = true, isUpgrade = false, score = 3, equippedScore = 9 } }
GameTooltip:SetLootRollItem(99)
assert(lastLine():find("|cff999999"), "tirada: no-mejora sale en gris")

-- --- Hook de recompensas de misión (SetQuestItem) -------------------------

mockQuestResults["choice:1"] = { result = { eligible = true, isUpgrade = true, score = 42 } }
GameTooltip:SetQuestItem("choice", 1)
assert(lastLine():find("|cff33ff33"), "misión: recompensa elegible en verde")

mockQuestResults["reward:1"] = { result = { eligible = false, reason = "Arma no entrenada para tu clase" } }
GameTooltip:SetQuestItem("reward", 1)
assertEqual(lastLine(), "|cffff4444Arma no entrenada para tu clase|r", "misión: recompensa rechazada en rojo con el motivo exacto")

GameTooltip:SetQuestItem("choice", 2) -- sin entrada todavía (hueco async)
assert(lastLine():find("analizando"), "misión: sin resultado todavía muestra placeholder, no error")

-- --- Hook de ítems de mochila (SetBagItem) ---------------------------------

mockBagLinks[0] = { [1] = "item:bag0-1" }
mockBagResults["item:bag0-1"] = { result = { eligible = true, isUpgrade = false, score = 8, equippedScore = 20 } }
GameTooltip:SetBagItem(0, 1)
assert(lastLine():find("|cff999999"), "mochila: no-mejora sale en gris")

local lineCountBeforeEmptySlot = #GameTooltip.lines
GameTooltip:SetBagItem(0, 2) -- slot vacío, GetContainerItemLink devuelve nil
assertEqual(#GameTooltip.lines, lineCountBeforeEmptySlot,
	"mochila: slot vacío no agrega ninguna línea (corta antes de llegar a AppendAnalysis)")

-- --- Fase 8: /pickitright module UIIntegration off ----------------------------

moduleEnabled = false
local lineCountBefore = #GameTooltip.lines
GameTooltip:SetLootItem(1)
GameTooltip:SetLootRollItem(99)
GameTooltip:SetQuestItem("choice", 1)
GameTooltip:SetBagItem(0, 1)
assertEqual(#GameTooltip.lines, lineCountBefore, "módulo desactivado: no agrega ninguna línea nueva")
moduleEnabled = true

print("OK: UIIntegration.lua supera la prueba de humo")
