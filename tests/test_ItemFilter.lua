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

-- Casos 5b-5c (bug real, verificado contra SharpiesGearJudge Classes/TBC/
-- <Clase>.lua ValidWeapons): Pícaro NUNCA pudo usar Hachas de una mano en
-- TBC real, pero nuestra tabla se lo permitía -- y a Druida le faltaban
-- Armas de Puño, que sí puede usar.
mockItems.axe1h = { name = "Hacha", equipLoc = "INVTYPE_WEAPON", classID = 2, subclassID = 0 }
ns.context = { class = "ROGUE", role = "Melee" }
ns.GetActiveWeightProfile = function() return { ITEM_MOD_ATTACK_POWER_SHORT = 1.0 } end
eligible, reason = ns.IsEligible("axe1h", { ITEM_MOD_ATTACK_POWER_SHORT = 10 })
assertEqual(eligible, false, "caso 5b: Pícaro no puede usar Hachas de una mano (bug real corregido)")
assert(reason:find("no entrenada"), "caso 5b: motivo debe mencionar proficiencia de armas")

mockItems.fistWeapon = { name = "Arma de Puño", equipLoc = "INVTYPE_WEAPON", classID = 2, subclassID = 13 }
ns.context = { class = "DRUID", role = "Melee" }
ns.GetActiveWeightProfile = function() return { ITEM_MOD_ATTACK_POWER_SHORT = 1.0 } end
eligible = ns.IsEligible("fistWeapon", { ITEM_MOD_ATTACK_POWER_SHORT = 10 })
assertEqual(eligible, true, "caso 5c: Druida SÍ puede usar Armas de Puño (faltaba en la tabla)")

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

-- --- Caso 26-28: topStat -- qué stat explica un "Equípatelo" -------------
-- ns.ScoreStats se reemplaza por una réplica simple del scoring real
-- (suma stat*peso), a diferencia del stub de SCORE=1 usado más arriba,
-- para que GetTopContributingStat tenga stats reales de qué elegir.
ns.ScoreStats = function(stats, profile)
	local total = 0
	for statKey, weight in pairs(profile) do
		total = total + (stats[statKey] or 0) * weight
	end
	return total
end
ns.context = { class = "MAGE", role = "Caster" }
ns.GetActiveWeightProfile = function()
	return { ITEM_MOD_SPELL_CRIT_RATING_SHORT = 0.6, ITEM_MOD_INTELLECT_SHORT = 0.5 }
end

mockItems.critHelm = { name = "Yelmo de Crítico", equipLoc = "INVTYPE_HEAD", classID = 4, subclassID = 1 }
local equippedHelm = { HeadSlot = { link = "oldHelm", stats = { ITEM_MOD_INTELLECT_SHORT = 20 } } }

result = ns.EvaluateItem("critHelm", { ITEM_MOD_SPELL_CRIT_RATING_SHORT = 23, ITEM_MOD_INTELLECT_SHORT = 3 }, {}, equippedHelm)
assertEqual(result.isUpgrade, true, "caso 26: mejora real bajo pesos reales (más crítico compensa menos intelecto)")
assertEqual(result.topStat, "ITEM_MOD_SPELL_CRIT_RATING_SHORT",
	"caso 26: topStat identifica el crítico como el stat que más explica la mejora")

mockItems.dullHelm = { name = "Yelmo Sin Gracia", equipLoc = "INVTYPE_HEAD", classID = 4, subclassID = 1 }
result = ns.EvaluateItem("dullHelm", { ITEM_MOD_INTELLECT_SHORT = 1 }, {}, equippedHelm)
assertEqual(result.isUpgrade, false, "caso 27: claramente peor que lo equipado")
assertEqual(result.topStat, nil, "caso 27: sin mejora, no se expone topStat")

-- --- Caso 29-30 ("todos, uno a uno" -- bonos de set 2pc/4pc) ------------
-- Réplica de un caso real: Mago con una pieza de un set crafteado real
-- (Spellstrike, itemID 24262) ya puesta en otro slot, evalúa la OTRA
-- pieza del mismo set (itemID 24266) para el pecho. Sola, esa pieza
-- pierde contra lo equipado (10 < 30 de Poder con Hechizos) -- pero
-- completa el 2pc del set (+25 Poder con Hechizos, valor real portado de
-- SharpiesGearJudge Data_Sets.lua), lo que la vuelve mejora real
-- (10 + 25 = 35 > 30).
ns.GetItemID = function(link)
	return ({ spellstrikeChestCandidate = 24266, spellstrikeChestCandidate2 = 24266, spellstrikeGlovesEquipped = 24262 })[link]
end

mockItems.spellstrikeChestCandidate = { name = "Pechera Spellstrike", equipLoc = "INVTYPE_CHEST", classID = 4, subclassID = 1 }
mockItems.spellstrikeChestCandidate2 = mockItems.spellstrikeChestCandidate
ns.context = { class = "MAGE", role = "Caster" }
ns.GetActiveWeightProfile = function() return { ITEM_MOD_SPELL_POWER_SHORT = 1.0 } end

local setBySlot = {
	HandsSlot = { link = "spellstrikeGlovesEquipped", stats = {} },
	ChestSlot = { link = "oldChest", stats = { ITEM_MOD_SPELL_POWER_SHORT = 30 } },
}
result = ns.EvaluateItem("spellstrikeChestCandidate", { ITEM_MOD_SPELL_POWER_SHORT = 10 }, {}, setBySlot)
assertEqual(result.isUpgrade, true, "caso 29: pierde en stats crudos pero completa un 2pc real, se vuelve mejora")

-- Caso 30: mismo candidato, pero SIN la otra pieza del set equipada en
-- ningún lado -- confirma que el bono depende de verdad del conteo de
-- piezas, no se aplica solo porque el ítem pertenezca a un set.
setBySlot = { ChestSlot = { link = "oldChest", stats = { ITEM_MOD_SPELL_POWER_SHORT = 30 } } }
result = ns.EvaluateItem("spellstrikeChestCandidate2", { ITEM_MOD_SPELL_POWER_SHORT = 10 }, {}, setBySlot)
assertEqual(result.isUpgrade, false, "caso 30: sin la otra pieza del set puesta, no hay bono que compense la diferencia de stats")

-- --- Casos 31-35 (pedido explícito del usuario): GetItemTargetBuild -----
-- Corrige el alcance de la línea "Clase Especialización": debe decir para
-- qué build está pensado el ÍTEM, no cuál es la clase/spec del jugador.
-- Perfiles chicos (no los reales de StatScorer.lua) para aislar la lógica
-- de ItemFilter.lua sin depender del archivo real.
ns.SpecNames = {
	MAGE = { "Arcane", "Fire", "Frost" },
	WARRIOR = { "Arms", "Fury", "Protection" },
}
ns.WeightProfiles = {
	MAGE = {
		Arcane = { [1] = { ITEM_MOD_SPELL_POWER_SHORT = 1.0 } },
		Fire = { [1] = { ITEM_MOD_SPELL_POWER_SHORT = 1.0, ITEM_MOD_SPELL_CRIT_RATING_SHORT = 1.5 } },
		Frost = { [1] = { ITEM_MOD_SPELL_POWER_SHORT = 1.0, ITEM_MOD_FROST_DAMAGE_SHORT = 1.0 } },
	},
	WARRIOR = {
		Arms = { [1] = { ITEM_MOD_STRENGTH_SHORT = 1.0, ITEM_MOD_ATTACK_POWER_SHORT = 1.0 } },
		Fury = { [1] = { ITEM_MOD_STRENGTH_SHORT = 1.0 } },
		Protection = { [1] = { ITEM_MOD_STAMINA_SHORT = 1.0 } },
	},
}

-- Caso 31: pecho de tela con Poder con Hechizos -> objetivo Mago (Arcano,
-- el perfil con el score normalizado más alto: 20/1.0 = 20, contra
-- 35/2.5 = 14 de Fuego). Guerrero queda con score 0 (ningún perfil suyo
-- pondera Poder con Hechizos), nunca gana pese a poder "equipar" tela.
mockItems.casterChest = { name = "Túnica Objetivo", equipLoc = "INVTYPE_CHEST", classID = 4, subclassID = 1 }
local targetClass, targetTab = ns.GetItemTargetBuild("casterChest", { ITEM_MOD_SPELL_POWER_SHORT = 20 })
assertEqual(targetClass, "MAGE", "caso 31: ítem de Poder con Hechizos apunta a Mago, no a Guerrero")
assertEqual(targetTab, 1, "caso 31: dentro de Mago, Arcano gana por score normalizado más alto")

-- Caso 32: varita (arma no entrenada para Guerrero, WEAPON_PROFICIENCY
-- real) con SOLO Fuerza -- sin el filtro de proficiencia, Guerrero Furia
-- ganaría (score normalizado 20 contra 0 de cualquier perfil de Mago).
-- Con el filtro, Guerrero queda afuera antes de puntuar -- ningún perfil
-- de Mago pondera Fuerza, así que no hay ganador.
mockItems.wandStrength = { name = "Varita Rara", equipLoc = "INVTYPE_RANGEDRIGHT", classID = 2, subclassID = 19 }
assertEqual(ns.GetItemTargetBuild("wandStrength", { ITEM_MOD_STRENGTH_SHORT = 20 }), nil,
	"caso 32: el filtro de proficiencia de arma excluye a Guerrero de una varita, y ningún perfil de Mago pondera Fuerza")

-- Caso 33: pecho de Placas con Fuerza+Poder de Ataque -> objetivo Guerrero
-- (Mago queda afuera por proficiencia de armadura: máximo Cloth a nivel
-- 70, Placas no entra). Empate Armas/Furia (ambos normalizan a 20) se
-- resuelve por orden de pestaña -- Armas es la [1].
mockItems.plateChestTarget = { name = "Pechera de Placas Objetivo", equipLoc = "INVTYPE_CHEST", classID = 4, subclassID = 4 }
targetClass, targetTab = ns.GetItemTargetBuild("plateChestTarget", { ITEM_MOD_STRENGTH_SHORT = 20, ITEM_MOD_ATTACK_POWER_SHORT = 20 })
assertEqual(targetClass, "WARRIOR", "caso 33: ítem de Fuerza/Poder de Ataque en Placas apunta a Guerrero")
assertEqual(targetTab, 1, "caso 33: empate Armas/Furia se resuelve a favor del primero encontrado (Armas)")

-- Caso 34: ítem sin stats -> sin build objetivo (no hay nada que comparar).
assertEqual(ns.GetItemTargetBuild("plateChestTarget", {}), nil, "caso 34: sin stats no hay build objetivo que inferir")

-- Caso 35 (integración vía EvaluateItem): el target del ÍTEM es
-- independiente de si ESTE jugador puede usarlo -- un Sacerdote no puede
-- equipar Placas (eligible=false), pero el ítem sigue "orientado a
-- Guerrero" para cualquiera que lo mire.
ns.context = { class = "PRIEST", role = "Healer" }
ns.GetActiveWeightProfile = function() return { ITEM_MOD_SPIRIT_SHORT = 1.0 } end
result = ns.EvaluateItem("plateChestTarget", { ITEM_MOD_STRENGTH_SHORT = 20, ITEM_MOD_ATTACK_POWER_SHORT = 20 })
assertEqual(result.eligible, false, "caso 35: Sacerdote no puede equipar Placas, sigue siendo no elegible para él")
assertEqual(result.targetClass, "WARRIOR", "caso 35: pero el target del ítem no depende de la elegibilidad del jugador actual")

-- --- Caso 36 (bug real vía /pickitright inspect: Veteran's Silk Belt) -----
-- "Classes: Priest, Mage, Warlock" en el tooltip excluye a Pícaro incluso
-- cuando su proficiencia de armadura (tela) lo dejaría pasar en general.
mockItems.restrictedCasterBelt = { name = "Cinturón Restringido", equipLoc = "INVTYPE_WAIST", classID = 4, subclassID = 1 }
ns.GetItemClassRestriction = function() return { PRIEST = true, MAGE = true, WARLOCK = true } end
targetClass, targetTab = ns.GetItemTargetBuild("restrictedCasterBelt", { ITEM_MOD_SPELL_POWER_SHORT = 20 })
assertEqual(targetClass, "MAGE", "caso 36: con restricción de clase, el ganador sale de las clases PERMITIDAS")

-- Réplica exacta del bug: mismo ítem, pero el perfil (mock) de Mago no
-- pondera Poder con Hechizos -- si el filtro de restricción NO se
-- aplicara, Guerrero (Placas descartada por armadura, pero Fuerza/AP no
-- están en este ítem tampoco) o cualquier otra clase no listada podría
-- colarse. Acá confirmamos explícitamente que Guerrero (NO listado en
-- Classes:) nunca gana pese a que ns.SpecNames lo sigue teniendo.
ns.GetItemClassRestriction = function() return { PRIEST = true, MAGE = true, WARLOCK = true } end
targetClass = ns.GetItemTargetBuild("restrictedCasterBelt", { ITEM_MOD_STRENGTH_SHORT = 20, ITEM_MOD_ATTACK_POWER_SHORT = 20 })
assertEqual(targetClass, nil, "caso 36b: Guerrero puntuaría alto por Fuerza/Ataque, pero la restricción de clase lo excluye -- sin ganador")
ns.GetItemClassRestriction = nil -- deja el estado limpio para el resto de las pruebas

print("OK: ItemFilter.lua supera la prueba de humo")
