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

print("OK: AddonSettings.lua supera la prueba de humo")
