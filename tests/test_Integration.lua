-- Prueba de INTEGRACIÓN standalone (no requiere el cliente de WoW). A
-- diferencia de tests/test_*.lua por módulo (que stubean las funciones de
-- otros módulos a mano), esta carga los .lua REALES en el mismo orden que
-- PickItRight.toc y los deja llamarse entre sí de verdad — es la red de
-- seguridad de la Fase 9 contra bugs de integración que los tests por
-- módulo no pueden ver (ej. el bySlot que se perdía entre LootIntegration
-- e ItemFilter en la Fase 6, detectado recién al conectar los módulos de
-- verdad). Ejecutar desde la raíz del repo:
--   lua5.1 tests/test_Integration.lua

-- --- Stubs mínimos de la API real de WoW (no de otros módulos) ----------

local frames = {}
-- Tooltip invisible que usa AddEquipEffectStats (Fase 10, ItemStatsAnalyzer.lua).
-- Este archivo no necesita probar el parseo de líneas "Equip:" en sí --
-- eso ya lo cubre test_ItemStatsAnalyzer.lua -- solo necesita que
-- CreateFrame("GameTooltip", ...) no explote; un tooltip mock "vacío"
-- (0 líneas) es correcto acá.
_G.WorldFrame = {}
_G.CreateFrame = function(frameType, name)
	if frameType == "GameTooltip" then
		local tip = {}
		function tip:SetOwner() end
		function tip:ClearLines() end
		function tip:SetHyperlink() end
		function tip:NumLines() return 0 end
		return tip
	end

	local frame = { events = {} }
	function frame:RegisterEvent(event) self.events[event] = true end
	function frame:SetScript(_, handler) self.handler = handler end
	table.insert(frames, frame)
	return frame
end

local function FireEvent(event, ...)
	for _, frame in ipairs(frames) do
		if frame.events[event] and frame.handler then
			frame.handler(frame, event, ...)
		end
	end
end

local mockClass, mockRace, mockPoints = "MAGE", "Human", { 0, 0, 0 }
_G.UnitClass = function() return "mock", mockClass end
_G.UnitRace = function() return "mock", mockRace end
_G.GetNumTalentTabs = function() return 3 end
_G.GetTalentTabInfo = function(i) return "tab", "icon", mockPoints[i] end

-- Registro único de items simulados, compartido por GetItemInfo y
-- GetItemStats -- así ambas API ven la misma "verdad" para cada link,
-- igual que en el cliente real.
local mockItems = {} -- [itemLink] = { name, equipLoc, classID, subclassID, stats }
_G.GetItemInfo = function(link)
	local item = mockItems[link]
	if not item then
		return nil
	end
	return item.name, link, 1, 70, 1, "Armor", "Mock", 1, item.equipLoc, "icon", 100, item.classID, item.subclassID
end
_G.GetItemStats = function(link)
	local item = mockItems[link]
	return item and item.stats
end

_G.GetInventorySlotInfo = function(name) return name end
_G.GetInventoryItemLink = function() return nil end -- personaje sin nada equipado

local mockLootSlots = {}
_G.GetNumLootItems = function() return #mockLootSlots end
_G.GetLootSlotLink = function(slot) return mockLootSlots[slot] end
_G.GetLootRollItemLink = function() return nil end

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
	AddLine = function(self, text) table.insert(self.lines, text) end,
	Show = function() end,
}
_G.GameTooltip = GameTooltip

_G.SlashCmdList = {}
_G.print = function() end -- silenciar los mensajes de /pickitright durante la prueba

-- --- Carga de los módulos reales, mismo orden que PickItRight.toc ----------

local ns = {}
local MODULE_FILES = {
	"Localization.lua",
	"SpecDetector.lua",
	"ItemStatsAnalyzer.lua",
	"StatScorer.lua",
	"ItemFilter.lua",
	"LootIntegration.lua",
	"UIIntegration.lua",
	"AddonSettings.lua",
}
for _, file in ipairs(MODULE_FILES) do
	local chunk, err = loadfile(file)
	assert(chunk, ("no se pudo cargar %s: %s"):format(file, tostring(err)))
	chunk("PickItRight", ns)
end

local function assertEqual(actual, expected, label)
	assert(actual == expected, ("%s: esperado %s, obtenido %s"):format(label, tostring(expected), tostring(actual)))
end

--------------------------------------------------------------------------
-- Escenario 1: build híbrida (Feral Druid) no rompe la detección de rol.
-- Es la limitación conocida y documentada del plan: mismo árbol cubre
-- Tank (oso) y Melee (gato); lo que hay que garantizar es que resuelve a
-- ALGO válido de forma determinística, no que arroje un error de Lua ni
-- que devuelva nil.
--------------------------------------------------------------------------

mockClass, mockPoints = "DRUID", { 5, 40, 3 } -- Feral dominante
FireEvent("PLAYER_ENTERING_WORLD")
assertEqual(ns.context.class, "DRUID", "escenario 1: contexto detecta la clase")
assertEqual(ns.context.role, "Melee", "escenario 1: Feral resuelve al default documentado, sin error")

-- Collar sin restricciones de armadura/arma, para que IsEligible llegue
-- hasta el chequeo de "hay perfil de pesos" en vez de frenar antes por
-- "item no cacheado" (el link tiene que estar registrado para eso).
mockItems["item:cualquiera"] = {
	name = "Collar Cualquiera", equipLoc = "INVTYPE_NECK", classID = 4, subclassID = 0,
}

-- Druida ya tiene perfil de pesos real (Fase 9: WEIGHT_PROFILES expandido a
-- las 9 clases con SharpiesGearJudge como fuente), así que el ítem SÍ debe
-- quedar elegible acá -- confirma que la build híbrida no solo resuelve rol
-- sin romper, sino que además puntúa de verdad. El camino de "sin datos de
-- build" para una clase/tab realmente sin mapear ya está cubierto a nivel
-- unitario en test_StatScorer.lua y test_ItemFilter.lua (fijan ns.context a
-- mano) -- acá no hay forma de forzarlo sin también romper la detección de
-- rol de SpecDetector, que depende del mismo mapeo.
local hybridResult = ns.EvaluateItem("item:cualquiera", {})
assertEqual(hybridResult.eligible, true, "escenario 1: Druida Feral ya tiene perfil de pesos, debe ser elegible")

--------------------------------------------------------------------------
-- Escenario 2: dos ítems de mundo con el MISMO itemID base pero distinto
-- sufijo aleatorio (formato real: item:id:...:suffixID:...) deben
-- analizarse y puntuarse por separado en TODO el pipeline, no solo en el
-- cache de stats de la Fase 2 (que ya se prueba aislado en
-- test_ItemStatsAnalyzer.lua) -- acá se verifica de punta a punta: loot
-- window -> stats -> filtro -> score -> tooltip.
--------------------------------------------------------------------------

mockClass, mockPoints = "MAGE", { 5, 40, 5 } -- Fuego dominante
FireEvent("CHARACTER_POINTS_CHANGED")
assertEqual(ns.context.role, "Caster", "escenario 2: contexto ahora es Mago Fuego")

local ringLowSuffix = "item:30234:0:0:0:0:0:100:0:70:0:0"
local ringHighSuffix = "item:30234:0:0:0:0:0:200:0:70:0:0"
mockItems[ringLowSuffix] = {
	name = "Anillo de Fuego del Fugitivo",
	equipLoc = "INVTYPE_FINGER",
	classID = 4,
	subclassID = 0,
	stats = { ITEM_MOD_SPELL_POWER_SHORT = 20 },
}
mockItems[ringHighSuffix] = {
	name = "Anillo de Fuego del Fugitivo",
	equipLoc = "INVTYPE_FINGER",
	classID = 4,
	subclassID = 0,
	stats = { ITEM_MOD_SPELL_POWER_SHORT = 35 },
}

mockLootSlots = { ringLowSuffix, ringHighSuffix }
FireEvent("LOOT_OPENED")

local lowResult = ns.GetLootResult(ringLowSuffix)
local highResult = ns.GetLootResult(ringHighSuffix)
assert(lowResult and highResult, "escenario 2: ambos sufijos se analizaron sin error de Lua")
assertEqual(lowResult.result.eligible, true, "escenario 2: sufijo bajo es elegible (anillo, sin restricción de armadura/arma)")
assertEqual(highResult.result.eligible, true, "escenario 2: sufijo alto también es elegible")
assert(lowResult.result.score ~= highResult.result.score,
	"escenario 2: distinto sufijo -> distinto score, no comparten resultado cacheado")
assert(highResult.result.score > lowResult.result.score,
	"escenario 2: el sufijo con más Poder con Hechizos puntúa más alto")

-- El tooltip debe poder anotarse sobre cualquiera de los dos sin error.
GameTooltip:SetLootItem(1)
assert(#GameTooltip.lines > 0, "escenario 2: el hook de tooltip agregó una línea sin arrojar error")

--------------------------------------------------------------------------
-- Escenario 3: un ítem que el filtro estricto rechaza (placas en un mago)
-- también debe recorrer el pipeline completo sin error, y el tooltip debe
-- mostrar el motivo exacto en rojo.
--------------------------------------------------------------------------

local plateChest = "item:99999:0:0:0:0:0:0:0:70:0:0"
mockItems[plateChest] = {
	name = "Pechera de Placas",
	equipLoc = "INVTYPE_CHEST",
	classID = 4,
	subclassID = 4, -- Plate
	stats = { ITEM_MOD_STAMINA_SHORT = 40 },
}

mockLootSlots = { plateChest }
FireEvent("LOOT_CLOSED") -- limpia la ventana anterior antes de abrir una nueva
FireEvent("LOOT_OPENED")

local rejected = ns.GetLootResult(plateChest)
assert(rejected, "escenario 3: el ítem rechazado también queda registrado")
assertEqual(rejected.result.eligible, false, "escenario 3: placas en un mago se rechaza")
assert(rejected.result.reason:find("armadura"), "escenario 3: motivo correcto")

GameTooltip:SetLootItem(1)
local lastLine = GameTooltip.lines[#GameTooltip.lines]
assert(lastLine:find("|cffff4444"), "escenario 3: el tooltip muestra el rechazo en rojo, sin errores de Lua")
assert(lastLine:find("armadura"), "escenario 3: y con el motivo real, no un mensaje genérico")

print("OK: test_Integration.lua supera la prueba de integración de punta a punta")
