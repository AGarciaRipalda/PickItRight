-- Prueba de humo standalone (no requiere el cliente de WoW). Ejecutar desde
-- la raíz del repo con cualquier intérprete Lua 5.1:
--   lua5.1 tests/test_AddonSettings.lua
--
-- PickItRightDB arranca como nil (proceso Lua fresco) para simular la primera
-- vez que el addon corre, sin SavedVariables guardadas todavía.

local printedMessages = {}
_G.print = function(msg) table.insert(printedMessages, msg) end

local function lastMessage()
	return printedMessages[#printedMessages]
end

_G.SlashCmdList = {} -- global real de WoW, siempre existe antes de que cargue cualquier addon

local currentPhase = 1
local ns = {}
ns.GetContentPhase = function() return currentPhase end
ns.SetContentPhase = function(phase) currentPhase = phase end

assert(loadfile("AddonSettings.lua"))("PickItRight", ns)

local function assertEqual(actual, expected, label)
	assert(actual == expected, ("%s: esperado %s, obtenido %s"):format(label, tostring(expected), tostring(actual)))
end

-- --- Inicialización segura (primer inicio, PickItRightDB vacía) --------------

assertEqual(type(PickItRightDB), "table", "PickItRightDB existe tras la primera carga")
assertEqual(PickItRightDB.contentPhase, 1, "fase por defecto es 1")
assertEqual(type(PickItRightDB.enabledModules), "table", "enabledModules existe de entrada")
assertEqual(type(PickItRightDB.statWeightOverrides), "table", "statWeightOverrides existe de entrada")

-- --- Módulos: activo por defecto sin entrada guardada --------------------

assertEqual(ns.IsModuleEnabled("LootIntegration"), true, "sin override guardado, un módulo conocido está activo")

-- --- Comando /pickitright phase ------------------------------------------------

SlashCmdList["PICKITRIGHT"]("phase 3")
assertEqual(currentPhase, 3, "phase 3 llama a ns.SetContentPhase(3)")
assert(lastMessage():find("3"), "confirma la fase fijada")

SlashCmdList["PICKITRIGHT"]("phase 9") -- fuera de rango
assertEqual(currentPhase, 3, "phase fuera de rango no cambia nada")
assert(lastMessage():find("Uso"), "fase inválida muestra el uso, no la acepta en silencio")

SlashCmdList["PICKITRIGHT"]("phase abc") -- no numérico
assertEqual(currentPhase, 3, "phase no numérico no cambia nada")

SlashCmdList["PICKITRIGHT"]("phase") -- sin argumento: consulta
assert(lastMessage():find("3"), "sin argumento, informa la fase activa")

-- --- Comando /pickitright weight -----------------------------------------------

SlashCmdList["PICKITRIGHT"]("weight ITEM_MOD_SPELL_POWER_SHORT 2.5")
assertEqual(ns.GetStatWeightOverrides().ITEM_MOD_SPELL_POWER_SHORT, 2.5, "override guardado")
assertEqual(PickItRightDB.statWeightOverrides.ITEM_MOD_SPELL_POWER_SHORT, 2.5, "visible directo en SavedVariables")

local versionAfterSet = ns.GetOverridesVersion()

SlashCmdList["PICKITRIGHT"]("weight ITEM_MOD_SPELL_POWER_SHORT clear")
assertEqual(ns.GetStatWeightOverrides().ITEM_MOD_SPELL_POWER_SHORT, nil, "clear elimina el override")
assert(ns.GetOverridesVersion() > versionAfterSet, "clear también sube la versión (invalida el cache de la Fase 7)")

SlashCmdList["PICKITRIGHT"]("weight ITEM_MOD_SPELL_POWER_SHORT nostring")
assert(lastMessage():find("número"), "valor no numérico se rechaza con un mensaje claro")

-- --- Comando /pickitright module ------------------------------------------------

SlashCmdList["PICKITRIGHT"]("module UIIntegration off")
assertEqual(ns.IsModuleEnabled("UIIntegration"), false, "module off desactiva")

SlashCmdList["PICKITRIGHT"]("module UIIntegration on")
assertEqual(ns.IsModuleEnabled("UIIntegration"), true, "module on reactiva")

SlashCmdList["PICKITRIGHT"]("module NoExiste on")
assert(lastMessage():find("Uso"), "módulo desconocido no crea una entrada nueva, muestra el uso")
assertEqual(PickItRightDB.enabledModules.NoExiste, nil, "no se guarda nada para un módulo inventado")

-- --- Comando sin argumentos / desconocido -----------------------------------

SlashCmdList["PICKITRIGHT"]("")
assert(lastMessage():find("phase"), "sin comando, muestra el resumen de uso")

-- --- Comando /pickitright inspect --------------------------------------------
-- Diagnóstico agregado para depurar un reporte real donde un ítem con
-- línea "Equip:" no puntuaba el bono ni siquiera después de dos fixes en
-- ItemStatsAnalyzer.lua. Prueba que el comando compara correctamente
-- GetItemStats() crudo contra lo que devuelve ns.RequestItemStats
-- (crudo + bonos de Equip: fusionados).

local mockItemLink = "|cffffffff|Hitem:12345:0:0:0:0:0:0:0:70:0:0|h[Mock Item]|h|r"
_G.GetItemInfo = function() return "Mock Item" end

-- Caso: sin link de ítem en el mensaje -> muestra uso, no explota.
printedMessages = {}
SlashCmdList["PICKITRIGHT"]("inspect")
assert(lastMessage():find("Uso"), "inspect sin link muestra el uso")

-- Caso: GetItemStats crudo y ns.RequestItemStats coinciden -> ningún bono
-- de Equip: detectado (el escenario que motivó el diagnóstico: si el
-- scanner de tooltip no encuentra nada, esto tiene que decirlo explícito).
_G.GetItemStats = function() return { ITEM_MOD_STAMINA_SHORT = 10 } end
ns.RequestItemStats = function(link, callback) callback({ ITEM_MOD_STAMINA_SHORT = 10 }) end
ns.GetActiveWeightProfile = function() return nil end

printedMessages = {}
SlashCmdList["PICKITRIGHT"]("inspect " .. mockItemLink)
local sawNoBonus, sawNoProfile = false, false
for _, msg in ipairs(printedMessages) do
	if msg:find("Ningún bono") then sawNoBonus = true end
	if msg:find("Sin perfil de pesos") then sawNoProfile = true end
end
assert(sawNoBonus, "inspect: sin diferencia entre crudo y fusionado, avisa que no encontró bonos de Equip:")
assert(sawNoProfile, "inspect: sin perfil de pesos activo, lo dice en vez de tirar error")

-- Caso: ns.RequestItemStats trae un stat de más (simula que
-- AddEquipEffectStats SÍ encontró un bono de Equip:) -> lo señala
-- explícitamente con el valor crudo vs el fusionado.
_G.GetItemStats = function() return { ITEM_MOD_STAMINA_SHORT = 10 } end
ns.RequestItemStats = function(link, callback)
	callback({ ITEM_MOD_STAMINA_SHORT = 10, ITEM_MOD_SPELL_CRIT_RATING_SHORT = 14 })
end
ns.GetActiveWeightProfile = function() return { ITEM_MOD_SPELL_CRIT_RATING_SHORT = 0.6 } end
ns.GetEquippedSnapshot = function() return {} end
ns.ScoreStats = function(stats, profile) return (stats.ITEM_MOD_SPELL_CRIT_RATING_SHORT or 0) * profile.ITEM_MOD_SPELL_CRIT_RATING_SHORT end

printedMessages = {}
SlashCmdList["PICKITRIGHT"]("inspect " .. mockItemLink)
local sawBonusDetected, sawScore = false, false
for _, msg in ipairs(printedMessages) do
	if msg:find("bono de Equip: detectado") and msg:find("ITEM_MOD_SPELL_CRIT_RATING_SHORT") then sawBonusDetected = true end
	if msg:find("Score final") and msg:find("8.4") then sawScore = true end
end
assert(sawBonusDetected, "inspect: stat solo presente en el fusionado se señala como bono de Equip: detectado")
assert(sawScore, "inspect: con perfil activo, calcula y muestra el score final")

print("OK: AddonSettings.lua supera la prueba de humo")
