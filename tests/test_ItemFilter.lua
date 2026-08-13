-- Prueba de humo standalone (no requiere el cliente de WoW). Ejecutar desde
-- la raíz del repo con cualquier intérprete Lua 5.1:
--   lua5.1 tests/test_ItemFilter.lua

local mockItems = {} -- [link] = { name, equipLoc, classID, subclassID }

_G.GetItemInfo = function(link)
	local item = mockItems[link]
	if not item then
		return nil
	end
	-- Respeta el orden real de retorno de GetItemInfo; solo se completan
	-- los campos que ItemFilter.lua realmente lee.
	return item.name, link, 1, 70, 1, "Armor", "Mock", 1, item.equipLoc, "icon", 100, item.classID, item.subclassID
end

-- Nivel 70 por defecto: máximo de armadura de todas las clases ya
-- entrenado, así los casos existentes (pensados para raideo) no necesitan
-- tocar mockLevel. El caso de leveo temprano (más abajo) lo cambia a mano.
local mockLevel = 70
_G.UnitLevel = function() return mockLevel end

local equipmentFrame
_G.CreateFrame = function()
	local frame = { RegisterEvent = function() end }
	function frame:SetScript(_, handler) frame.handler = handler end
	equipmentFrame = frame
	return frame
end

local ns = {}
assert(loadfile("ItemFilter.lua"))("PickItRight", ns)

local function assertEqual(actual, expected, label)
	assert(actual == expected, ("%s: esperado %s, obtenido %s"):format(label, tostring(expected), tostring(actual)))
end

local MAGE_PROFILE = { ITEM_MOD_SPELL_POWER_SHORT = 1.0, ITEM_MOD_INTELLECT_SHORT = 0.35 }
local ROGUE_PROFILE = { ITEM_MOD_ATTACK_POWER_SHORT = 1.0, ITEM_MOD_CRIT_MELEE_RATING_SHORT = 0.9 }

-- Caso 1: mago intenta equipar un pecho de placas -> rechazado.
mockItems.plateChest = { name = "Pechera de Placas", equipLoc = "INVTYPE_CHEST", classID = 4, subclassID = 4 }
ns.context = { class = "MAGE", role = "Caster" }
ns.GetActiveWeightProfile = function() return MAGE_PROFILE end

local eligible, reason = ns.IsEligible("plateChest", { ITEM_MOD_SPELL_POWER_SHORT = 20 })
assertEqual(eligible, false, "caso 1: placas en un mago debe rechazarse")
assert(reason:find("armadura"), "caso 1: motivo debe mencionar el tipo de armadura")

-- Caso 2: mago equipa un pecho de tela -> pasa el filtro de armadura.
mockItems.clothChest = { name = "Túnica", equipLoc = "INVTYPE_CHEST", classID = 4, subclassID = 1 }
eligible = ns.IsEligible("clothChest", { ITEM_MOD_SPELL_POWER_SHORT = 20 })
assertEqual(eligible, true, "caso 2: tela en un mago debe aceptarse")

-- Caso 3: guerrero equipa una Capa (subclass Cloth por la rareza de
-- itemización del juego) -> NO debe rechazarse por tipo de armadura.
mockItems.cloak = { name = "Capa", equipLoc = "INVTYPE_CLOAK", classID = 4, subclassID = 1 }
ns.context = { class = "WARRIOR", role = "Melee" }
ns.GetActiveWeightProfile = function() return { ITEM_MOD_ATTACK_POWER_SHORT = 1.0 } end
eligible = ns.IsEligible("cloak", { ITEM_MOD_ATTACK_POWER_SHORT = 10 })
assertEqual(eligible, true, "caso 3: la capa (Cloth) no debe bloquearse para un guerrero")

-- Caso 4: sacerdote intenta usar una espada (subclass 7, no entrenada) -> rechazado.
mockItems.sword = { name = "Espada", equipLoc = "INVTYPE_WEAPON", classID = 2, subclassID = 7 }
ns.context = { class = "PRIEST", role = "Healer" }
ns.GetActiveWeightProfile = function() return { ITEM_MOD_SPELL_POWER_SHORT = 1.0 } end
eligible, reason = ns.IsEligible("sword", { ITEM_MOD_SPELL_POWER_SHORT = 15 })
assertEqual(eligible, false, "caso 4: espada en un sacerdote debe rechazarse")
assert(reason:find("no entrenada"), "caso 4: motivo debe mencionar proficiencia de armas")

-- Caso 5: sacerdote equipa una maza (subclass 4, entrenada) -> pasa.
mockItems.mace = { name = "Maza", equipLoc = "INVTYPE_WEAPON", classID = 2, subclassID = 4 }
eligible = ns.IsEligible("mace", { ITEM_MOD_SPELL_POWER_SHORT = 15 })
assertEqual(eligible, true, "caso 5: maza en un sacerdote debe aceptarse")

-- Caso 6: pícaro encuentra un ítem itemizado para healer (solo
-- Espíritu/MP5, sin nada relevante para dps físico) -> rechazado.
mockItems.healerTrinket = { name = "Trinket de Sanador", equipLoc = "INVTYPE_TRINKET", classID = 4, subclassID = 0 }
ns.context = { class = "ROGUE", role = "Melee" }
ns.GetActiveWeightProfile = function() return ROGUE_PROFILE end
eligible, reason = ns.IsEligible("healerTrinket", { ITEM_MOD_SPIRIT_SHORT = 20, ITEM_MOD_MANA_REGENERATION_SHORT = 8 })
assertEqual(eligible, false, "caso 6: item de puro espíritu/mp5 en un pícaro debe rechazarse")
assert(reason:find("rol"), "caso 6: motivo debe mencionar incompatibilidad de rol")

-- Caso 7: mismo pícaro, item dps con un TOQUE de espíritu de relleno ->
-- no debe rechazarse (tiene stat relevante, no es un ítem de otro rol).
eligible = ns.IsEligible("healerTrinket", { ITEM_MOD_ATTACK_POWER_SHORT = 30, ITEM_MOD_SPIRIT_SHORT = 5 })
assertEqual(eligible, true, "caso 7: dps con un stat de relleno irrelevante no debe rechazarse entero")

-- Caso 8: sin perfil de pesos activo (clase/fase sin datos) -> rechazado
-- con un motivo distinto al de stats incompatibles.
ns.GetActiveWeightProfile = function() return nil end
eligible, reason = ns.IsEligible("healerTrinket", { ITEM_MOD_ATTACK_POWER_SHORT = 30 })
assertEqual(eligible, false, "caso 8: sin perfil de pesos debe rechazarse")
assert(reason:find("build"), "caso 8: motivo debe distinguir 'sin datos' de 'stats incompatibles'")

-- Caso 9: item aún no cacheado por el cliente -> rechazado con motivo de reintento.
eligible, reason = ns.IsEligible("itemInexistente", {})
assertEqual(eligible, false, "caso 9: item no cacheado debe rechazarse")
assert(reason:find("disponibles"), "caso 9: motivo debe indicar que hay que reintentar")

-- --- EvaluateItem: solo llama a ScoreStats si el filtro pasó -------------

local scoreStatsCalled = false
ns.ScoreStats = function() scoreStatsCalled = true; return 42 end

ns.context = { class = "MAGE", role = "Caster" }
ns.GetActiveWeightProfile = function() return MAGE_PROFILE end

local result = ns.EvaluateItem("plateChest", { ITEM_MOD_SPELL_POWER_SHORT = 20 })
assertEqual(result.eligible, false, "caso 10: EvaluateItem respeta el rechazo del filtro")
assertEqual(result.score, nil, "caso 10: sin score cuando no es elegible")
assertEqual(scoreStatsCalled, false, "caso 10: ScoreStats no debe llamarse si el filtro rechaza el ítem")

result = ns.EvaluateItem("clothChest", { ITEM_MOD_SPELL_POWER_SHORT = 20 })
assertEqual(result.eligible, true, "caso 11: EvaluateItem acepta cuando el filtro pasa")
assertEqual(result.score, 42, "caso 11: score viene de ScoreStats")
assertEqual(scoreStatsCalled, true, "caso 11: ScoreStats sí debe llamarse cuando el filtro acepta")

-- --- isUpgrade: compara contra lo que ocupa el mismo slot ---------------
-- ScoreStats se reemplaza por un stub controlable: el "score" de cada
-- tabla de stats es directamente su campo SCORE, para poder fijar a mano
-- qué puntúa más alto sin depender de pesos reales.
ns.ScoreStats = function(stats) return (stats and stats.SCORE) or 0 end
ns.context = { class = "WARRIOR", role = "Melee" }
ns.GetActiveWeightProfile = function() return { SCORE = 1 } end

mockItems.newSword = { name = "Espada Nueva", equipLoc = "INVTYPE_WEAPON", classID = 2, subclassID = 7 }
mockItems.newRing = { name = "Anillo Nuevo", equipLoc = "INVTYPE_FINGER", classID = 4, subclassID = 0 }

result = ns.EvaluateItem("newSword", { SCORE = 10 }, {}, {})
assertEqual(result.isUpgrade, true, "caso 12: slot vacío es siempre mejora")
assertEqual(result.equippedScore, 0, "caso 12: slot vacío puntúa 0")

local bySlot = { MainHandSlot = { link = "oldSword", stats = { SCORE = 5 } } }
result = ns.EvaluateItem("newSword", { SCORE = 10 }, {}, bySlot)
assertEqual(result.isUpgrade, true, "caso 13: supera lo equipado en ese slot")

bySlot = { MainHandSlot = { link = "oldSword", stats = { SCORE = 20 } } }
result = ns.EvaluateItem("newSword", { SCORE = 10 }, {}, bySlot)
assertEqual(result.isUpgrade, false, "caso 14: no supera lo equipado en ese slot")

-- item ambiguo (dos slots posibles, ej. anillo): compara contra el PEOR
-- de los dos equipados, no contra ambos.
bySlot = {
	Finger0Slot = { link = "ring1", stats = { SCORE = 30 } },
	Finger1Slot = { link = "ring2", stats = { SCORE = 8 } },
}
result = ns.EvaluateItem("newRing", { SCORE = 10 }, {}, bySlot)
assertEqual(result.isUpgrade, true, "caso 15: supera al peor de los dos anillos equipados")

-- sin bySlot (llamada de 3 argumentos, compatibilidad con código anterior):
-- no se puede comparar, isUpgrade queda en nil, pero el score se calcula igual.
result = ns.EvaluateItem("newSword", { SCORE = 10 }, {})
assertEqual(result.isUpgrade, nil, "caso 16: sin bySlot no hay comparación posible")
assertEqual(result.score, 10, "caso 16: el score absoluto se calcula de todas formas")

-- --- Fase 7: cache de resultados por itemLink + perfil activo -----------
-- ns.GetItemString queda SIN stub hasta este punto a propósito: así los
-- casos 12-16 (arriba) pueden reevaluar el mismo itemLink con distinto
-- bySlot en cada llamada sin que el cache -inexistente hasta ahora- lo
-- impida. A partir de acá se habilita para probar el cache en sí.
ns.GetItemString = function(link) return link end

local scoreCallCount = 0
ns.ScoreStats = function(stats)
	scoreCallCount = scoreCallCount + 1
	return (stats and stats.SCORE) or 0
end
ns.context = { class = "WARRIOR", dominantTab = 1, role = "Melee" }
ns.GetActiveWeightProfile = function() return { SCORE = 1 } end
ns.GetContentPhase = function() return 1 end

mockItems.cacheItem = { name = "Item Repetido", equipLoc = "INVTYPE_WEAPON", classID = 2, subclassID = 7 }

local first = ns.EvaluateItem("cacheItem", { SCORE = 10 }, {}, {})
local callsAfterFirst = scoreCallCount
assert(callsAfterFirst > 0, "caso 17: la primera evaluación sí llama a ScoreStats")

-- Stats de entrada distintas (999 en vez de 10): no debería importar, la
-- segunda lectura del mismo item bajo el mismo perfil viene del cache.
local second = ns.EvaluateItem("cacheItem", { SCORE = 999 }, {}, {})
assertEqual(scoreCallCount, callsAfterFirst, "caso 17: la segunda evaluación no vuelve a llamar a ScoreStats")
assertEqual(second, first, "caso 17: devuelve la MISMA tabla de resultado cacheada")

assertEqual(ns.GetCachedResult("cacheItem"), first, "caso 18: GetCachedResult expone la misma entrada sin recalcular")

-- Cambiar de spec (mismo personaje, otro árbol dominante) invalida TODO
-- el cache, no solo la entrada de este item.
ns.context = { class = "WARRIOR", dominantTab = 3, role = "Tank" }
local third = ns.EvaluateItem("cacheItem", { SCORE = 10 }, {}, {})
assert(scoreCallCount > callsAfterFirst, "caso 19: cambiar de spec invalida el cache y vuelve a puntuar")
assertEqual(ns.GetCachedResult("cacheItem"), third, "caso 19: el cache ahora refleja el resultado bajo el nuevo perfil")

-- El resultado "datos aún no disponibles" nunca se cachea: si quedara
-- pegado, rompería el reintento automático de la Fase 2 para siempre.
local notLoaded = ns.EvaluateItem("itemInexistente", {})
assertEqual(notLoaded.eligible, false, "caso 20: item sin cargar sigue siendo no elegible")
assertEqual(ns.GetCachedResult("itemInexistente"), nil, "caso 20: y nunca queda cacheado")

-- Caso 21 (Fase 8): un override de pesos también debe invalidar el cache,
-- no solo un cambio de spec/fase -- si no, /pickitright weight no tendría
-- efecto inmediato.
local overridesVersion = 1
ns.GetOverridesVersion = function() return overridesVersion end
local beforeOverride = ns.EvaluateItem("cacheItem", { SCORE = 10 }, {}, {})
local callsBeforeOverride = scoreCallCount

overridesVersion = 2 -- simula /pickitright weight ...
local afterOverride = ns.EvaluateItem("cacheItem", { SCORE = 10 }, {}, {})
assert(scoreCallCount > callsBeforeOverride, "caso 21: cambiar la versión de overrides invalida el cache")

-- Caso 22 (bug real): cambiar de equipo (sin cambiar spec/fase/overrides)
-- también debe invalidar el cache -- un ítem evaluado ANTES de equipar una
-- pieza mejor no debe seguir diciendo "Equípatelo" para siempre solo porque
-- su itemString no cambió. PLAYER_EQUIPMENT_CHANGED (confirmado real vía
-- SharpiesGearJudge) es lo que dispara esto.
local beforeEquip = ns.EvaluateItem("cacheItem", { SCORE = 10 }, {}, {})
local callsBeforeEquip = scoreCallCount

equipmentFrame.handler() -- simula PLAYER_EQUIPMENT_CHANGED
local afterEquip = ns.EvaluateItem("cacheItem", { SCORE = 10 }, {}, {})
assert(scoreCallCount > callsBeforeEquip, "caso 22: cambiar de equipo invalida el cache aunque spec/fase/overrides no cambien")

-- --- Caso 23-25 (bug real): proficiencia de armadura por NIVEL, no por --
-- máximo teórico de nivel 70 -- reportado por un Paladín tanque real de
-- nivel 10: toda pieza de Cuero (lo único usable a ese nivel, Malla/Plate
-- ni entrenados) se rechazaba como "tu clase usa Plate".
mockItems.leatherLegs = { name = "Calzas de Cuero", equipLoc = "INVTYPE_LEGS", classID = 4, subclassID = 2 }
mockItems.mailLegs = { name = "Calzas de Malla", equipLoc = "INVTYPE_LEGS", classID = 4, subclassID = 3 }
mockItems.plateLegs = { name = "Calzas de Placas", equipLoc = "INVTYPE_LEGS", classID = 4, subclassID = 4 }
ns.context = { class = "PALADIN", role = "Tank" }
ns.GetActiveWeightProfile = function() return { ITEM_MOD_STAMINA_SHORT = 1.0 } end

mockLevel = 10
eligible = ns.IsEligible("leatherLegs", { ITEM_MOD_STAMINA_SHORT = 10 })
assertEqual(eligible, true, "caso 23: Paladín nivel 10 SÍ puede usar Cuero (Plate/Malla ni entrenados todavía)")

eligible, reason = ns.IsEligible("plateLegs", { ITEM_MOD_STAMINA_SHORT = 10 })
assertEqual(eligible, false, "caso 24: Paladín nivel 10 NO puede usar Plate (se entrena recién a nivel 40)")
assert(reason:find("armadura"), "caso 24: motivo debe mencionar el tipo de armadura")

mockLevel = 40
eligible = ns.IsEligible("plateLegs", { ITEM_MOD_STAMINA_SHORT = 10 })
assertEqual(eligible, true, "caso 25: Paladín nivel 40 SÍ puede usar Plate")
mockLevel = 70

print("OK: ItemFilter.lua supera la prueba de humo")
