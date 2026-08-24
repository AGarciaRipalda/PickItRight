-- Prueba de humo standalone (no requiere el cliente de WoW). Ejecutar desde
-- la raíz del repo con cualquier intérprete Lua 5.1:
--   lua5.1 tests/test_StatScorer.lua
--
-- StatScorer.lua no llama ninguna API de WoW aparte del global PickItRightDB
-- (SavedVariables), así que no hace falta stubear CreateFrame ni eventos.

local ns = {}
assert(loadfile("StatScorer.lua"))("PickItRight", ns)

local function assertClose(actual, expected, label)
	assert(math.abs(actual - expected) < 0.0001,
		("%s: esperado %s, obtenido %s"):format(label, tostring(expected), tostring(actual)))
end

local function assertEqual(actual, expected, label)
	assert(actual == expected, ("%s: esperado %s, obtenido %s"):format(label, tostring(expected), tostring(actual)))
end

-- --- EvaluateCappedValue ---------------------------------------------

assertEqual(ns.EvaluateCappedValue("ITEM_MOD_SPELL_POWER_SHORT", 50, 9999), 50,
	"stat sin regla de cap vale su valor completo")

assertEqual(ns.EvaluateCappedValue("ITEM_MOD_HIT_SPELL_RATING_SHORT", 20, 202), 0,
	"ya capeado sin el item: el aporte extra no vale nada")

assertEqual(ns.EvaluateCappedValue("ITEM_MOD_HIT_SPELL_RATING_SHORT", 5, 190), 5,
	"aporte que no llega al cap vale su valor completo")

-- currentValue=190, cap=202 -> quedan 12 antes del cap; itemValue=25 lo cruza
assertClose(ns.EvaluateCappedValue("ITEM_MOD_HIT_SPELL_RATING_SHORT", 25, 190), 12,
	"aporte que cruza el cap solo cuenta hasta el cap")

-- --- ScoreStats --------------------------------------------------------

local profile = {
	ITEM_MOD_SPELL_POWER_SHORT = 1.0,
	ITEM_MOD_HIT_SPELL_RATING_SHORT = 1.3,
}

assertClose(ns.ScoreStats({ ITEM_MOD_SPELL_POWER_SHORT = 20 }, profile), 20,
	"puntaje simple sin caps de por medio")

assertClose(ns.ScoreStats({ ITEM_MOD_STAMINA_SHORT = 100 }, profile), 0,
	"stat sin peso en el perfil se ignora, no resta ni suma")

-- currentStats ya tiene 190 de golpe (12 antes del cap de 202); el item
-- aporta 25 golpe + 20 poder con hechizos.
local itemStats = { ITEM_MOD_HIT_SPELL_RATING_SHORT = 25, ITEM_MOD_SPELL_POWER_SHORT = 20 }
local currentStats = { ITEM_MOD_HIT_SPELL_RATING_SHORT = 190 }
-- efectivo: 12*1.3 (golpe capeado) + 20*1.0 (poder con hechizos) = 35.6
assertClose(ns.ScoreStats(itemStats, profile, currentStats), 35.6,
	"puntaje respeta el cap de golpe usando las stats actuales del personaje")

assertClose(ns.ScoreStats({}, profile), 0, "sin stats no hay puntaje")
assertClose(ns.ScoreStats({ ITEM_MOD_SPELL_POWER_SHORT = 10 }, nil), 0, "sin perfil activo no hay puntaje")

-- --- Selector de fase (SavedVariables) ----------------------------------

assertEqual(ns.GetContentPhase(), 1, "fase por defecto es 1")
ns.SetContentPhase(2)
assertEqual(ns.GetContentPhase(), 2, "SetContentPhase persiste en PickItRightDB")
assertEqual(PickItRightDB.contentPhase, 2, "el valor persistido es visible directamente en PickItRightDB")
ns.SetContentPhase(1) -- deja el estado limpio para el resto de las pruebas

-- --- GetActiveWeightProfile ----------------------------------------------

ns.context = { class = "MAGE", dominantTab = 2 } -- índice 2 = Fire en SPEC_NAMES.MAGE
local activeProfile = ns.GetActiveWeightProfile()
assert(activeProfile, "debía resolver el perfil de Mago Fuego, Fase 1")
assertEqual(activeProfile.ITEM_MOD_SPELL_POWER_SHORT, 1.0, "perfil resuelto es el de Fuego Fase 1")

ns.SetContentPhase(2) -- no hay datos de Fuego para la fase 2 todavía
assertEqual(ns.GetActiveWeightProfile(), nil, "fase sin perfil cargado no debe caer de vuelta a otra fase")
ns.SetContentPhase(1)

-- Las 9 clases de TBC ya tienen perfil (Fase 9: expandido con SharpiesGearJudge
-- como fuente real) -- "DEATHKNIGHT" no existe en TBC, sirve para seguir
-- probando que una clase genuinamente sin mapear se degrada con gracia.
ns.context = { class = "DEATHKNIGHT", dominantTab = 1 }
assertEqual(ns.GetActiveWeightProfile(), nil, "clase sin perfil (inexistente en TBC) devuelve nil")

-- Índice de árbol fuera de rango para una clase que SÍ tiene perfil: mismo
-- camino de "no encontrado", no debería explotar ni devolver cualquier cosa.
ns.context = { class = "WARRIOR", dominantTab = 4 }
assertEqual(ns.GetActiveWeightProfile(), nil, "árbol fuera de rango (4, solo hay 3) devuelve nil")

-- --- Chequeo puntual de las 8 clases nuevas (Fase 9, fuente SharpiesGearJudge) ---
-- No exhaustivo (27 combinaciones clase/spec en total) -- solo confirma que
-- la tabla resuelve y que un par de valores de referencia no se transcribieron
-- mal, para las clases con más superficie de riesgo (arma+armadura, caster
-- de daño por escuela, y el caso Cazador con Ranged Attack Power aparte).
ns.context = { class = "WARRIOR", dominantTab = 1 } -- Arms
local warriorArms = ns.GetActiveWeightProfile()
assert(warriorArms, "Guerrero Armas debía resolver perfil")
assertEqual(warriorArms.ITEM_MOD_STRENGTH_SHORT, 2.3, "Guerrero Armas: fuerza")
-- Bug real: se excluía Expertise asumiendo que era un stat de WotLK sin
-- existencia en TBC -- refutado (ver el punto 2 de la cabecera de
-- WEIGHT_PROFILES en StatScorer.lua): la propia fuente (SharpiesGearJudge)
-- la lee en vivo vía GetCombatRating(24) y varias filas traen el comentario
-- "Added TBC Stat". Restaurada con el valor real de la fuente.
assertEqual(warriorArms.ITEM_MOD_EXPERTISE_RATING_SHORT, 2.0, "Guerrero Armas: Expertise restaurada con el valor real de la fuente")

ns.context = { class = "PRIEST", dominantTab = 3 } -- Shadow
local priestShadow = ns.GetActiveWeightProfile()
assert(priestShadow, "Sacerdote Sombras debía resolver perfil")
assertEqual(priestShadow.ITEM_MOD_SHADOW_DAMAGE_SHORT, 1.2, "Sacerdote Sombras: daño de sombras")
assertEqual(priestShadow.ITEM_MOD_HIT_SPELL_RATING_SHORT, 1.4, "Sacerdote Sombras: golpe de hechizos")

ns.context = { class = "HUNTER", dominantTab = 1 } -- Beast Mastery
local hunterBM = ns.GetActiveWeightProfile()
assert(hunterBM, "Cazador Bestias debía resolver perfil")
assertEqual(hunterBM.ITEM_MOD_RANGED_ATTACK_POWER_SHORT, 1.0, "Cazador Bestias: poder de ataque a distancia (stat separado en TBC)")

ns.context = { class = "DRUID", dominantTab = 2 } -- Feral
local druidFeral = ns.GetActiveWeightProfile()
assert(druidFeral, "Druida Feral debía resolver perfil")
assertEqual(druidFeral.ITEM_MOD_FERAL_ATTACK_POWER_SHORT, 1.0, "Druida Feral: poder de ataque feral")

-- --- Bug real reportado por un Paladín tanque: el DPS del arma no pesaba --
-- nada, así que un arma con MENOS daño por segundo (pero un poco más de
-- Agilidad) puntuaba como mejora. GetItemStats() SÍ expone el DPS del arma
-- bajo ITEM_MOD_DAMAGE_PER_SECOND_SHORT (confirmado con /pickitright
-- inspect) -- faltaba el peso correspondiente en el perfil. Portado desde
-- SharpiesGearJudge (Paladin.lua, PROT_DEEP.MSC_WEAPON_DPS = 0.2 -- su
-- propio cálculo de DPS, no una clave de GetItemStats, pero el mismo valor
-- de peso aplica igual de bien a la clave real).
ns.context = { class = "PALADIN", dominantTab = 2 } -- Protection
local paladinProt = ns.GetActiveWeightProfile()
assertEqual(paladinProt.ITEM_MOD_DAMAGE_PER_SECOND_SHORT, 0.2, "Paladín Protección: peso de DPS de arma")

-- Antes del fix, el DPS del arma contribuía CERO al score (clave sin peso
-- en ningún perfil) -- este caso confirma que ahora sí aporta, proporcional
-- al peso. NO se afirma qué arma "gana" en el caso real reportado (Slatemetal
-- Cutlass vs Darkwater Talwar): con estos pesos puntuales (Agilidad pesa 3x
-- más que DPS para Paladín Protección) el resultado real queda muy cerca
-- (diferencia de ~0.13 sobre una base de ~3.7-3.9) -- afirmar un ganador
-- sin verificarlo a mano sería el mismo error que causó este bug.
local dpsOnly16 = { ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 16.6 }
local dpsOnly12 = { ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 12.27 }
assertClose(ns.ScoreStats(dpsOnly16, paladinProt) - ns.ScoreStats(dpsOnly12, paladinProt), (16.6 - 12.27) * 0.2,
	"el DPS del arma ahora aporta al score, proporcional a su peso (antes del fix, contribuía 0)")

-- --- Overrides manuales (Fase 8, normalmente de AddonSettings.lua) -------

ns.context = { class = "MAGE", dominantTab = 2 }

ns.GetStatWeightOverrides = function() return {} end
assertEqual(ns.GetActiveWeightProfile(), ns.WeightProfiles.MAGE.Fire[1],
	"sin overrides, devuelve la MISMA tabla base (sin copiar de más)")

ns.GetStatWeightOverrides = function() return { ITEM_MOD_SPELL_POWER_SHORT = 2.0 } end
local overridden = ns.GetActiveWeightProfile()
assertEqual(overridden.ITEM_MOD_SPELL_POWER_SHORT, 2.0, "el override pisa el peso base")
assertEqual(overridden.ITEM_MOD_HIT_SPELL_RATING_SHORT, 1.3, "los stats sin override conservan su peso base")
assertEqual(ns.WeightProfiles.MAGE.Fire[1].ITEM_MOD_SPELL_POWER_SHORT, 1.0,
	"la tabla base NUNCA se muta, el override vive en una copia nueva")

print("OK: StatScorer.lua supera la prueba de humo")
