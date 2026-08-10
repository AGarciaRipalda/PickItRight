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

print("OK: LootIntegration.lua supera la prueba de humo")
