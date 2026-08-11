-- Prueba de humo standalone (no requiere el cliente de WoW). Ejecutar desde
-- la raíz del repo con cualquier intérprete Lua 5.1:
--   lua5.1 tests/test_LootIntegration.lua

local registeredHandler
_G.CreateFrame = function()
	return {
		RegisterEvent = function() end,
		SetScript = function(_, _, handler) registeredHandler = handler end,
	}
end

local mockLootSlots = {} -- array de itemLinks, índice = número de slot
_G.GetNumLootItems = function() return #mockLootSlots end
_G.GetLootSlotLink = function(slot) return mockLootSlots[slot] end

local mockRollLinks = {} -- [rollID] = itemLink
_G.GetLootRollItemLink = function(rollID) return mockRollLinks[rollID] end

local mockQuestChoices, mockQuestRewards = {}, {} -- arrays de itemLinks
_G.GetNumQuestChoices = function() return #mockQuestChoices end
_G.GetNumQuestRewards = function() return #mockQuestRewards end
_G.GetQuestItemLink = function(kind, i)
	if kind == "choice" then return mockQuestChoices[i] end
	if kind == "reward" then return mockQuestRewards[i] end
end

local mockQuestLog = { choice = {}, reward = {} } -- [tipo] = array de itemLinks (sin función de conteo real, ver ScanQuestLogKind)
_G.GetQuestLogItemLink = function(kind, i) return mockQuestLog[kind] and mockQuestLog[kind][i] end

_G.NUM_BAG_SLOTS = 4
-- Capacidad y contenido separados a propósito: un table constructor con un
-- "hueco" (nil en medio) deja indefinido qué devuelve el operador # de Lua,
-- así que la capacidad del bolsillo NO se deriva de contar itemLinks.
local mockBagCapacity = {} -- [bagID] = cantidad de slots
local mockBagItems = {} -- [bagID] = {[slot] = itemLink}
_G.GetContainerNumSlots = function(bag) return mockBagCapacity[bag] or 0 end
_G.GetContainerItemLink = function(bag, slot) return mockBagItems[bag] and mockBagItems[bag][slot] end

local ns = {}
ns.GetItemString = function(link) return link end -- identidad: simplifica el test
ns.RequestItemStats = function(link, callback) callback({ ITEM_MOD_SPELL_POWER_SHORT = 10 }) end -- síncrono
ns.GetEquippedSnapshot = function() return {} end
ns.IsModuleEnabled = function() return true end -- normalmente de AddonSettings.lua (Fase 8)

-- Cache de resultados de la Fase 7 (normalmente expuesto por
-- ItemFilter.lua). nil = miss, para que los casos 1-7 (que no lo tocan)
-- sigan pasando por RequestItemStats como antes.
local mockCachedResult = nil
ns.GetCachedResult = function() return mockCachedResult end

local evaluateCalls = {}
ns.EvaluateItem = function(itemLink)
	table.insert(evaluateCalls, itemLink)
	return { eligible = true, reason = nil, score = 99 }
end

assert(loadfile("LootIntegration.lua"))("PickItRight", ns)

local function assertEqual(actual, expected, label)
	assert(actual == expected, ("%s: esperado %s, obtenido %s"):format(label, tostring(expected), tostring(actual)))
end

-- Caso 1: LOOT_OPENED escanea todos los slots y guarda un resultado por item.
mockLootSlots = { "item:1", "item:2" }
registeredHandler(nil, "LOOT_OPENED")
assertEqual(ns.currentLootResults["item:1"].result.score, 99, "caso 1: item 1 analizado")
assertEqual(ns.currentLootResults["item:2"].result.score, 99, "caso 1: item 2 analizado")
assertEqual(#evaluateCalls, 2, "caso 1: se evaluaron ambos items")

-- Caso 2: reabrir LOOT_OPENED sin cambios no vuelve a evaluar los mismos items.
registeredHandler(nil, "LOOT_OPENED")
assertEqual(#evaluateCalls, 2, "caso 2: items ya analizados no se re-evalúan")

-- Caso 3: LOOT_CLOSED limpia el estado de la ventana de loot.
registeredHandler(nil, "LOOT_CLOSED")
assertEqual(next(ns.currentLootResults), nil, "caso 3: LOOT_CLOSED vacía los resultados")

-- Caso 4: START_LOOT_ROLL analiza el item de la tirada.
mockRollLinks[42] = "item:42"
registeredHandler(nil, "START_LOOT_ROLL", 42, 30)
assertEqual(ns.currentRollResults[42].result.score, 99, "caso 4: tirada 42 analizada")
assertEqual(#evaluateCalls, 3, "caso 4: se evaluó el item de la tirada")

-- Caso 5: CONFIRM_LOOT_ROLL para una tirada ya analizada no la re-evalúa.
registeredHandler(nil, "CONFIRM_LOOT_ROLL", 42, 0)
assertEqual(#evaluateCalls, 3, "caso 5: tirada ya analizada no se re-evalúa")

-- Caso 6: CONFIRM_LOOT_ROLL para una tirada que START_LOOT_ROLL no capturó
-- (ej. addon recargado a mitad de una tirada) sí la analiza.
mockRollLinks[7] = "item:7"
registeredHandler(nil, "CONFIRM_LOOT_ROLL", 7, 0)
assertEqual(ns.currentRollResults[7].result.score, 99, "caso 6: CONFIRM_LOOT_ROLL analiza tiradas no vistas antes")
assertEqual(#evaluateCalls, 4, "caso 6: se evaluó el item de la tirada no vista")

-- Caso 7: helpers de consulta
assertEqual(ns.GetRollResult(7).itemLink, "item:7", "caso 7: GetRollResult devuelve la tirada correcta")
assertEqual(ns.GetRollResult(999), nil, "caso 7: tirada inexistente devuelve nil")

-- Caso 8 (Fase 7): si el cache de resultados ya tiene el item, ni siquiera
-- se llama a RequestItemStats -- el caso real es el mismo trash cayendo de
-- muchos corpses distintos en un pull de raid, coste de CPU cero.
registeredHandler(nil, "LOOT_CLOSED")
local requestStatsCalled = false
local originalRequestItemStats = ns.RequestItemStats
ns.RequestItemStats = function(...)
	requestStatsCalled = true
	return originalRequestItemStats(...)
end

mockCachedResult = { eligible = true, isUpgrade = true, score = 77 }
mockLootSlots = { "item:cached" }
registeredHandler(nil, "LOOT_OPENED")
assertEqual(ns.currentLootResults["item:cached"].result.score, 77, "caso 8: usa el resultado del cache de la Fase 7")
assertEqual(requestStatsCalled, false, "caso 8: no llama a RequestItemStats cuando el cache ya tiene el item")

-- Caso 9 (Fase 8): /pickitright module LootIntegration off -- el frame sigue
-- registrado (no se puede des-registrar en caliente), pero el handler no
-- hace nada.
registeredHandler(nil, "LOOT_CLOSED")
ns.IsModuleEnabled = function() return false end
mockLootSlots = { "item:deberia-ignorarse" }
registeredHandler(nil, "LOOT_OPENED")
assertEqual(next(ns.currentLootResults), nil, "caso 9: módulo desactivado no analiza ni guarda nada")
ns.IsModuleEnabled = function() return true end

-- --- Recompensas de misión (QUEST_DETAIL / QUEST_COMPLETE) ---------------
mockCachedResult = nil -- el caso 8 lo dejó fijo; no debe filtrarse acá

-- Caso 10: QUEST_DETAIL analiza tanto las recompensas elegibles como las
-- garantizadas, cada una bajo su propia clave "tipo:índice".
mockQuestChoices = { "item:choiceA", "item:choiceB" }
mockQuestRewards = { "item:rewardA" }
local evaluateCallsBeforeQuest = #evaluateCalls
registeredHandler(nil, "QUEST_DETAIL")
assertEqual(ns.GetQuestRewardResult("choice", 1).itemLink, "item:choiceA", "caso 10: choice 1 analizado")
assertEqual(ns.GetQuestRewardResult("choice", 2).itemLink, "item:choiceB", "caso 10: choice 2 analizado")
assertEqual(ns.GetQuestRewardResult("reward", 1).itemLink, "item:rewardA", "caso 10: reward 1 analizado")
assertEqual(ns.GetQuestRewardResult("reward", 1).result.score, 99, "caso 10: score real, no un placeholder")
assertEqual(#evaluateCalls, evaluateCallsBeforeQuest + 3, "caso 10: se evaluaron las 3 recompensas")

-- Caso 11: mismo evento (QUEST_COMPLETE, misma misión) con los mismos
-- ítems no vuelve a evaluar nada -- dedupe por identidad de itemLink.
registeredHandler(nil, "QUEST_COMPLETE")
assertEqual(#evaluateCalls, evaluateCallsBeforeQuest + 3, "caso 11: recompensas sin cambios no se re-evalúan")

-- Caso 12: otra misión reutiliza el mismo índice "reward:1" con un ítem
-- distinto -- SÍ debe re-evaluar (la clave no es un candado permanente).
mockQuestRewards = { "item:rewardA_nueva_mision" }
registeredHandler(nil, "QUEST_COMPLETE")
assertEqual(ns.GetQuestRewardResult("reward", 1).itemLink, "item:rewardA_nueva_mision",
	"caso 12: mismo índice, misión distinta, se re-evalúa con el ítem nuevo")
assertEqual(#evaluateCalls, evaluateCallsBeforeQuest + 4, "caso 12: se evaluó el ítem nuevo")

-- Caso 13: índice sin recompensa (misión sin elección) devuelve nil, no error.
assertEqual(ns.GetQuestRewardResult("choice", 99), nil, "caso 13: índice inexistente devuelve nil")

-- Caso 14: módulo desactivado -- tampoco escanea recompensas de misión.
ns.IsModuleEnabled = function() return false end
mockQuestChoices = { "item:deberia-ignorarse-tambien" }
local evaluateCallsBeforeDisabled = #evaluateCalls
registeredHandler(nil, "QUEST_DETAIL")
assertEqual(#evaluateCalls, evaluateCallsBeforeDisabled, "caso 14: módulo desactivado no analiza recompensas de misión")
ns.IsModuleEnabled = function() return true end

-- --- Ítems de la mochila (BAG_UPDATE_DELAYED) -----------------------------

-- Caso 15: recorre todos los bolsillos (0..NUM_BAG_SLOTS) y analiza cada
-- ítem, dejando huecos (slots vacíos) sin romper el escaneo.
mockBagCapacity = { [0] = 3, [1] = 1 }
mockBagItems = {
	[0] = { [1] = "item:bag0-a", [3] = "item:bag0-c" }, -- slot 2 vacío
	[1] = { [1] = "item:bag1-a" },
}
local evaluateCallsBeforeBags = #evaluateCalls
registeredHandler(nil, "BAG_UPDATE_DELAYED")
assertEqual(ns.GetBagItemResult("item:bag0-a").result.score, 99, "caso 15: item de bolsillo 0 analizado")
assertEqual(ns.GetBagItemResult("item:bag0-c").result.score, 99, "caso 15: slot vacío en medio no rompe el escaneo")
assertEqual(ns.GetBagItemResult("item:bag1-a").result.score, 99, "caso 15: item de bolsillo 1 (bolsa equipada) analizado")
assertEqual(#evaluateCalls, evaluateCallsBeforeBags + 3, "caso 15: se evaluaron los 3 ítems de mochila")

-- Caso 16: volver a disparar el evento sin cambios en la mochila no
-- re-evalúa los mismos ítems -- a diferencia de loot, esta tabla nunca se
-- limpia, así que la dedupe por itemString es lo único que evita
-- reanalizar en cada BAG_UPDATE_DELAYED (que puede disparar seguido).
registeredHandler(nil, "BAG_UPDATE_DELAYED")
assertEqual(#evaluateCalls, evaluateCallsBeforeBags + 3, "caso 16: ítems ya analizados no se re-evalúan")

-- Caso 17: un ítem vendido/movido (ya no está en la mochila) deja de
-- aparecer en el escaneo, pero su entrada vieja no se borra ni causa error
-- -- simplemente queda huérfana (ver comentario ponytail en el código).
mockBagItems[1] = {}
registeredHandler(nil, "BAG_UPDATE_DELAYED")
assertEqual(ns.GetBagItemResult("item:bag1-a").result.score, 99, "caso 17: entrada huérfana sigue accesible, no se borra")
assertEqual(#evaluateCalls, evaluateCallsBeforeBags + 3, "caso 17: no hay nada nuevo que analizar")

-- Caso 18: helper de consulta con ítem que nunca estuvo en la mochila.
assertEqual(ns.GetBagItemResult("item:nunca-existio"), nil, "caso 18: ítem no visto devuelve nil")

-- Caso 19: módulo desactivado -- tampoco escanea la mochila.
ns.IsModuleEnabled = function() return false end
mockBagCapacity[2] = 1
mockBagItems[2] = { [1] = "item:deberia-ignorarse-bolsa" }
local evaluateCallsBeforeBagsDisabled = #evaluateCalls
registeredHandler(nil, "BAG_UPDATE_DELAYED")
assertEqual(#evaluateCalls, evaluateCallsBeforeBagsDisabled, "caso 19: módulo desactivado no analiza la mochila")
ns.IsModuleEnabled = function() return true end

-- --- Recompensas de misión desde el diario (QUEST_LOG_UPDATE) ------------
-- Sin GetNumQuestLogChoices/Rewards verificado (ver comentario en
-- LootIntegration.lua) -- el escaneo corta en el primer índice sin ítem,
-- así que estos casos son los que confirman que ESE corte funciona.

-- Caso 20: QUEST_LOG_UPDATE analiza elegibles y garantizadas de la misión
-- seleccionada, cortando apenas GetQuestLogItemLink devuelve nil.
mockQuestLog.choice = { "item:logchoiceA" }
mockQuestLog.reward = { "item:logrewardA", "item:logrewardB" }
local evaluateCallsBeforeQuestLog = #evaluateCalls
registeredHandler(nil, "QUEST_LOG_UPDATE")
assertEqual(ns.GetQuestLogRewardResult("choice", 1).itemLink, "item:logchoiceA", "caso 20: choice 1 del diario analizado")
assertEqual(ns.GetQuestLogRewardResult("reward", 1).itemLink, "item:logrewardA", "caso 20: reward 1 del diario analizado")
assertEqual(ns.GetQuestLogRewardResult("reward", 2).itemLink, "item:logrewardB", "caso 20: reward 2 del diario analizado")
assertEqual(ns.GetQuestLogRewardResult("reward", 3), nil, "caso 20: no sigue de largo después del último ítem real")
assertEqual(#evaluateCalls, evaluateCallsBeforeQuestLog + 3, "caso 20: se evaluaron exactamente 3, no MAX_QUEST_LOG_REWARDS")

-- Caso 21: questLogResults es una tabla separada de questResults (misma
-- clave "reward:1", pero namespaces distintos) -- no deben pisarse.
assertEqual(ns.GetQuestRewardResult("reward", 1).itemLink, "item:rewardA_nueva_mision",
	"caso 21: el diario no pisó el resultado de la ventana de aceptar/entregar bajo la misma clave")

-- Caso 22: cambiar de misión seleccionada en el diario (mismo índice,
-- ítem distinto) sí re-evalúa -- mismo criterio de dedupe que las otras
-- fuentes de recompensas.
mockQuestLog.reward = { "item:logrewardA_otra_mision" }
registeredHandler(nil, "QUEST_LOG_UPDATE")
assertEqual(ns.GetQuestLogRewardResult("reward", 1).itemLink, "item:logrewardA_otra_mision",
	"caso 22: misión distinta seleccionada, se re-evalúa con el ítem nuevo")

-- Caso 23: módulo desactivado -- tampoco escanea el diario de misiones.
ns.IsModuleEnabled = function() return false end
mockQuestLog.choice = { "item:deberia-ignorarse-diario" }
local evaluateCallsBeforeQuestLogDisabled = #evaluateCalls
registeredHandler(nil, "QUEST_LOG_UPDATE")
assertEqual(#evaluateCalls, evaluateCallsBeforeQuestLogDisabled, "caso 23: módulo desactivado no analiza el diario de misiones")
ns.IsModuleEnabled = function() return true end

print("OK: LootIntegration.lua supera la prueba de humo")
