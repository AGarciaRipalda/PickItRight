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
	SetQuestLogItem = function() end, -- presente en el mock: prueba el camino donde SÍ existe (ver el guard en UIIntegration.lua)
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
local mockQuestLogResults = {} -- ["tipo:índice"] = entry
ns.GetLootResult = function(itemLink) return mockLootResults[itemLink] end
ns.GetRollResult = function(rollID) return mockRollResults[rollID] end
ns.GetQuestRewardResult = function(kind, i) return mockQuestResults[kind .. ":" .. i] end
ns.GetBagItemResult = function(itemLink) return mockBagResults[itemLink] end
ns.GetQuestLogRewardResult = function(kind, i) return mockQuestLogResults[kind .. ":" .. i] end

local moduleEnabled = true -- normalmente de AddonSettings.lua (Fase 8)
ns.IsModuleEnabled = function() return moduleEnabled end

-- RAID_CLASS_COLORS es un global real del cliente (ver el comentario en
-- UIIntegration.lua) -- se mockea solo con la clase que usan los casos de
-- abajo, para no tener que transcribir la tabla completa de 9 clases.
_G.RAID_CLASS_COLORS = { MAGE = { r = 0.41, g = 0.8, b = 0.94 } }

assert(loadfile("UIIntegration.lua"))("PickItRight", ns)

local function assertEqual(actual, expected, label)
	assert(actual == expected, ("%s: esperado %s, obtenido %s"):format(label, tostring(expected), tostring(actual)))
end

local function lastLine()
	return GameTooltip.lines[#GameTooltip.lines]
end

-- --- FormatScoreLine (función pura) --------------------------------------
-- A pedido explícito: nunca se muestra el número de score, solo el
-- veredicto -- estos asserts confirman que el texto NO incluye ningún
-- número, además del texto/color esperado.

local upgradeLine = ns.FormatScoreLine({ isUpgrade = true, score = 12.34 })
assert(upgradeLine:find("|cff33ff33"), "verde: color de mejora clara")
assert(upgradeLine:find("Equípatelo"), "verde: texto 'Equípatelo'")
assert(not upgradeLine:find("12%.3"), "verde: NO incluye el score")

local notUpgradeLine = ns.FormatScoreLine({ isUpgrade = false, score = 5, equippedScore = 20 })
assert(notUpgradeLine:find("|cff999999"), "gris: color de no-mejora")
assert(notUpgradeLine:find("No es mejora"), "gris: texto 'No es mejora'")
assert(not notUpgradeLine:find("5%.0") and not notUpgradeLine:find("20%.0"), "gris: NO incluye ningún score")

local noComparisonLine = ns.FormatScoreLine({ isUpgrade = nil, score = 7 })
assert(noComparisonLine:find("|cff999999"), "gris: color cuando no hay comparación")
assert(noComparisonLine:find("Elegible"), "gris: rotulado como elegible, no mejora/no-mejora")
assert(not noComparisonLine:find("7%.0"), "gris: NO incluye el score")

-- --- FormatContextLine: segunda línea "Por: <stat>" solo para "Equípatelo" ---
-- Pedido explícito: además del veredicto, indicar qué stat concreto explica
-- la mejora y para qué sirve -- sin volver a mostrar el score.

local statLine = ns.FormatContextLine({ isUpgrade = true, topStat = "ITEM_MOD_SPELL_CRIT_RATING_SHORT" })
assert(statLine, "topStat mapeado en una mejora: sí genera segunda línea")
assert(statLine:find("Por:"), "segunda línea: empieza con 'Por:'")
assert(statLine:find("Crítico de Hechizos"), "segunda línea: nombra el stat en español")

assertEqual(ns.FormatContextLine({ isUpgrade = false, topStat = "ITEM_MOD_SPELL_CRIT_RATING_SHORT" }), nil,
	"sin mejora (isUpgrade=false), no hay segunda línea aunque topStat venga seteado")
assertEqual(ns.FormatContextLine({ isUpgrade = nil, topStat = "ITEM_MOD_SPELL_CRIT_RATING_SHORT" }), nil,
	"sin comparación posible (isUpgrade=nil), no hay segunda línea")
assertEqual(ns.FormatContextLine({ isUpgrade = true, topStat = nil }), nil,
	"mejora sin topStat calculado, no hay segunda línea")
assertEqual(ns.FormatContextLine({ isUpgrade = true, topStat = "ITEM_MOD_STAT_INVENTADO" }), nil,
	"topStat sin mapear en STAT_CONTEXT, no hay segunda línea (no inventa texto)")

-- --- FormatTargetBuildLine: "Clase Especialización" arriba del veredicto ---
-- Corrige el alcance de la primera versión: debe decir para qué build está
-- pensado el ÍTEM (result.targetClass/targetTab, calculado en
-- ItemFilter.lua/GetItemTargetBuild), NO la clase/spec del jugador actual
-- (ns.context) -- pedido explícito del usuario tras la primera entrega.

ns.L = { CLASS_NAMES = { MAGE = "Mago" }, SPEC_NAMES = { MAGE = { "Arcano", "Fuego", "Escarcha" } } }

assertEqual(ns.FormatTargetBuildLine(nil), nil, "sin resultado, no hay línea")
assertEqual(ns.FormatTargetBuildLine({}), nil, "ítem sin target inferido (targetClass=nil), no hay línea")

local targetLine = ns.FormatTargetBuildLine({ targetClass = "MAGE", targetTab = 2 }) -- Fuego
assert(targetLine:find("Mago Fuego"), "línea de target: nombra clase y especialización en español")
-- r=0.41,g=0.8,b=0.94 -> floor(104.55)=68, floor(204)=cc, floor(239.7)=ef
assert(targetLine:find("|cff68ccef", 1, true), "línea de target: usa el color real de RAID_CLASS_COLORS.MAGE")

assertEqual(ns.FormatTargetBuildLine({ targetClass = "DEATHKNIGHT", targetTab = 1 }), nil,
	"clase sin SPEC_NAMES mapeado, no hay línea (no rompe, no inventa texto)")

-- Integración completa: la línea aparece EN el tooltip, arriba del veredicto,
-- usando el target del ÍTEM (no ns.context, que ni siquiera está seteado acá).
mockLootLinks[5] = "item:5"
mockLootResults["item:5"] = { result = { eligible = true, isUpgrade = true, score = 9, targetClass = "MAGE", targetTab = 2 } }
local linesBeforeTarget = #GameTooltip.lines
GameTooltip:SetLootItem(5)
assertEqual(#GameTooltip.lines, linesBeforeTarget + 2, "loot: agrega la línea de target MÁS el veredicto")
assert(GameTooltip.lines[#GameTooltip.lines - 1]:find("Mago Fuego"), "loot: la línea de target queda ARRIBA del veredicto")
assert(lastLine():find("Equípatelo"), "loot: el veredicto sigue siendo la última línea agregada")

-- También aparece cuando el ítem fue rechazado para ESTE jugador -- el
-- target del ítem no depende de si el jugador actual puede usarlo.
mockLootLinks[6] = "item:6"
mockLootResults["item:6"] = { result = { eligible = false, reason = "Tipo de armadura incorrecto", targetClass = "MAGE", targetTab = 2 } }
local linesBeforeRejected = #GameTooltip.lines
GameTooltip:SetLootItem(6)
assertEqual(#GameTooltip.lines, linesBeforeRejected + 2, "loot rechazado: también agrega la línea de target")
assert(GameTooltip.lines[#GameTooltip.lines - 1]:find("Mago Fuego"), "loot rechazado: línea de target arriba del motivo de rechazo")

ns.L = nil -- deja el estado limpio para el resto de las pruebas

-- --- Hook de la ventana de loot (SetLootItem) -----------------------------

mockLootLinks[1] = "item:1"
mockLootResults["item:1"] = { result = { eligible = true, isUpgrade = true, score = 15 } }
GameTooltip:SetLootItem(1)
assert(lastLine():find("|cff33ff33"), "loot: item elegible y mejora sale en verde")

-- Con topStat mapeado, AppendAnalysis agrega una SEGUNDA línea explicando
-- el veredicto -- confirma la integración completa (ItemFilter.lua calcula
-- topStat -> UIIntegration.lua lo muestra), no solo la función pura de arriba.
mockLootLinks[4] = "item:4"
mockLootResults["item:4"] = {
	result = { eligible = true, isUpgrade = true, score = 20, topStat = "ITEM_MOD_SPELL_CRIT_RATING_SHORT" },
}
local linesBeforeCritHelm = #GameTooltip.lines
GameTooltip:SetLootItem(4)
assertEqual(#GameTooltip.lines, linesBeforeCritHelm + 2, "loot con topStat: agrega veredicto + segunda línea explicativa")
assert(lastLine():find("Por:") and lastLine():find("Crítico de Hechizos"),
	"loot con topStat: la segunda línea explica qué stat impulsa la mejora")

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

-- --- Hook de recompensas de misión desde el diario (SetQuestLogItem) -----

mockQuestLogResults["reward:1"] = { result = { eligible = true, isUpgrade = true, score = 30 } }
GameTooltip:SetQuestLogItem("reward", 1)
assert(lastLine():find("|cff33ff33"), "diario: recompensa elegible en verde")

-- El diario y la ventana de aceptar/entregar leen tablas SEPARADAS aunque
-- compartan el mismo formato de clave -- confirma que no se pisan.
assertEqual(mockQuestResults["reward:1"].result.eligible, false,
	"diario: la tabla de SetQuestItem sigue con su propio resultado, sin pisarse")

-- --- Fase 8: /pickitright module UIIntegration off ----------------------------

moduleEnabled = false
local lineCountBefore = #GameTooltip.lines
GameTooltip:SetLootItem(1)
GameTooltip:SetLootRollItem(99)
GameTooltip:SetQuestItem("choice", 1)
GameTooltip:SetBagItem(0, 1)
GameTooltip:SetQuestLogItem("reward", 1)
assertEqual(#GameTooltip.lines, lineCountBefore, "módulo desactivado: no agrega ninguna línea nueva")
moduleEnabled = true

print("OK: UIIntegration.lua supera la prueba de humo")
