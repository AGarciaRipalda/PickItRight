-- Prueba de humo standalone (no requiere el cliente de WoW). Ejecutar desde
-- la raíz del repo con cualquier intérprete Lua 5.1:
--   lua5.1 tests/test_ItemStatsAnalyzer.lua

local loadedItems = {} -- [itemString] = true si "el cliente" ya lo tiene cacheado
local statsByLink = {} -- [itemLink] = stats simuladas devueltas por GetItemStats
local registeredHandler

_G.GetItemInfo = function(link)
	local itemString = link:match("(item:[%-%d:]+)")
	return loadedItems[itemString] and "MockItemName" or nil
end
_G.GetItemStats = function(link) return statsByLink[link] end

-- Mock del tooltip invisible que usa AddEquipEffectStats (Fase 10). Un
-- link mapea a un array de líneas de texto (línea 1 = nombre del ítem,
-- como en un tooltip real; el resto, lo que scanTooltip:NumLines() vería).
-- Sin entrada en mockTooltipLines[link] = tooltip "vacío" (0 líneas), no
-- error -- simula el caso normal de un item sin ningún bono "Equip:".
local mockTooltipLines = {}
local function MakeMockTooltip(name)
	local tip = { currentLines = {} }
	function tip:SetOwner() end
	function tip:ClearLines() self.currentLines = {} end
	function tip:SetHyperlink(link) self.currentLines = mockTooltipLines[link] or {} end
	function tip:NumLines() return #self.currentLines end
	for i = 1, 20 do
		_G[name .. "TextLeft" .. i] = { GetText = function() return tip.currentLines[i] end }
	end
	return tip
end

_G.WorldFrame = {}
_G.CreateFrame = function(frameType, name)
	if frameType == "GameTooltip" then
		return MakeMockTooltip(name)
	end
	return {
		RegisterEvent = function() end,
		SetScript = function(_, _, handler) registeredHandler = handler end,
	}
end

local ns = {}
assert(loadfile("ItemStatsAnalyzer.lua"))("PickItRight", ns)

local function assertEqual(actual, expected, label)
	assert(actual == expected, ("%s: esperado %s, obtenido %s"):format(label, tostring(expected), tostring(actual)))
end

-- Caso 1: item ya cacheado por el cliente -> resuelve de inmediato.
local linkA = "item:12345:0:0:0:0:0:100:0:70:0:0"
loadedItems[linkA] = true
statsByLink[linkA] = { ITEM_MOD_CRIT_RATING_SHORT = 10 }

local resultA
ns.RequestItemStats(linkA, function(stats) resultA = stats end)
assert(resultA, "caso 1: el callback no se llamó de inmediato")
assertEqual(resultA.ITEM_MOD_CRIT_RATING_SHORT, 10, "caso 1: stat esperado")

-- Caso 2: mismo itemID (12345), sufijo distinto -> cache separado, no se pisan.
local linkB = "item:12345:0:0:0:0:0:200:0:70:0:0"
loadedItems[linkB] = true
statsByLink[linkB] = { ITEM_MOD_CRIT_RATING_SHORT = 25 }

local resultB
ns.RequestItemStats(linkB, function(stats) resultB = stats end)
assertEqual(resultB.ITEM_MOD_CRIT_RATING_SHORT, 25, "caso 2: sufijo distinto no debe compartir cache")
assertEqual(resultA.ITEM_MOD_CRIT_RATING_SHORT, 10, "caso 2: el link original no debe haber cambiado")

-- Caso 3: item aún no descargado por el cliente -> espera a GET_ITEM_INFO_RECEIVED.
local linkC = "item:99999:0:0:0:0:0:0:0:70:0:0"
statsByLink[linkC] = { ITEM_MOD_STAMINA_SHORT = 15 }

local resultC, calledImmediately = nil, false
ns.RequestItemStats(linkC, function(stats)
	resultC = stats
	calledImmediately = true
end)
assert(not calledImmediately, "caso 3: no debía resolver antes de que el item esté cacheado")

loadedItems[linkC] = true -- "el cliente" ya terminó de descargar los datos
registeredHandler(nil, "GET_ITEM_INFO_RECEIVED", 99999, true)
assert(resultC, "caso 3: el reintento tras GET_ITEM_INFO_RECEIVED debía resolver el callback")
assertEqual(resultC.ITEM_MOD_STAMINA_SHORT, 15, "caso 3: stat esperado tras reintento")

-- Caso 4: un link "decorado" (color + nombre) comparte cache con el mismo
-- item string plano, porque la key de cache es el item string, no el texto.
local plain = "item:55555:0:0:0:0:0:0:0:70:0:0"
local decorated = "|cff1eff00|Hitem:55555:0:0:0:0:0:0:0:70:0:0|h[Objeto Mock]|h|r"
loadedItems[plain] = true
statsByLink[plain] = { ITEM_MOD_AGILITY_SHORT = 8 }

local resultPlain
ns.RequestItemStats(plain, function(stats) resultPlain = stats end)

local resultDecorated
ns.RequestItemStats(decorated, function(stats) resultDecorated = stats end)
assertEqual(resultDecorated, resultPlain, "caso 4: link decorado debe compartir cache con su item string plano")

-- Caso 5: snapshot de equipo suma stats de varios slots y conserva el
-- desglose por slot.
local equipped = {
	HeadSlot = "item:1:0:0:0:0:0:0:0:70:0:0",
	ChestSlot = "item:2:0:0:0:0:0:0:0:70:0:0",
}
loadedItems[equipped.HeadSlot] = true
loadedItems[equipped.ChestSlot] = true
statsByLink[equipped.HeadSlot] = { ITEM_MOD_STAMINA_SHORT = 20, ITEM_MOD_CRIT_RATING_SHORT = 5 }
statsByLink[equipped.ChestSlot] = { ITEM_MOD_STAMINA_SHORT = 30 }

_G.GetInventorySlotInfo = function(name) return name end
_G.GetInventoryItemLink = function(_, slotID) return equipped[slotID] end

local totalStats, bySlot = ns.GetEquippedSnapshot()
assertEqual(totalStats.ITEM_MOD_STAMINA_SHORT, 50, "caso 5: suma de aguante entre slots")
assertEqual(totalStats.ITEM_MOD_CRIT_RATING_SHORT, 5, "caso 5: crítico solo viene del casco")
assertEqual(bySlot.HeadSlot.link, equipped.HeadSlot, "caso 5: el desglose por slot conserva el link")

-- --- Bonos "Equip: X" (Fase 10) --------------------------------------------
-- Regresión del caso real reportado: Shadowcast Tunic tenía +44 Poder con
-- Hechizos y +14 Crítico de Hechizos SOLO visibles en líneas "Equip:", que
-- GetItemStats no ve. Sin AddEquipEffectStats, esos números quedaban en 0.

-- Caso 6: una sola línea "Equip: Improves X by N" se suma sobre las stats
-- crudas de GetItemStats.
local critRing = "item:70001:0:0:0:0:0:0:0:70:0:0"
loadedItems[critRing] = true
statsByLink[critRing] = { ITEM_MOD_STAMINA_SHORT = 5 }
mockTooltipLines[critRing] = {
	"Mock Ring of Testing",
	"+5 Stamina",
	"Equip: Improves spell critical strike rating by 14.",
}
local ringResult
ns.RequestItemStats(critRing, function(stats) ringResult = stats end)
assertEqual(ringResult.ITEM_MOD_STAMINA_SHORT, 5, "caso 6: stat crudo de GetItemStats sigue presente")
assertEqual(ringResult.ITEM_MOD_SPELL_CRIT_RATING_SHORT, 14, "caso 6: bono de Equip: sumado encima")

-- Caso 7: el caso real reportado -- DOS líneas "Equip:" en el mismo ítem
-- (una con "by N", otra con "by up to N"), ambas deben capturarse.
local shadowcastTunic = "item:70002:0:0:0:0:0:0:0:70:0:0"
loadedItems[shadowcastTunic] = true
statsByLink[shadowcastTunic] = { ITEM_MOD_STAMINA_SHORT = 21, ITEM_MOD_INTELLECT_SHORT = 15 }
mockTooltipLines[shadowcastTunic] = {
	"Shadowcast Tunic",
	"122 Armor",
	"+21 Stamina",
	"+15 Intellect",
	"Durability 67 / 80",
	"Equip: Improves spell critical strike rating by 14.",
	"Equip: Increases damage and healing done by magical spells and effects by up to 44.",
}
local tunicResult
ns.RequestItemStats(shadowcastTunic, function(stats) tunicResult = stats end)
assertEqual(tunicResult.ITEM_MOD_STAMINA_SHORT, 21, "caso 7: Aguante crudo presente")
assertEqual(tunicResult.ITEM_MOD_INTELLECT_SHORT, 15, "caso 7: Intelecto crudo presente")
assertEqual(tunicResult.ITEM_MOD_SPELL_CRIT_RATING_SHORT, 14, "caso 7: crítico de hechizos capturado desde Equip:")
assertEqual(tunicResult.ITEM_MOD_SPELL_POWER_SHORT, 44, "caso 7: poder con hechizos ('by up to N') capturado desde Equip:")

-- Caso 7b: regresión -- bug real encontrado cuando un usuario reportó que
-- el fix del caso 7 no cambiaba el veredicto en el cliente real. Causa:
-- algunas líneas de tooltip traen un código de color |cffXXXXXX...|r
-- embebido en el propio GetText(), no solo vía SetTextColor -- sin
-- limpiarlo antes de matchear, el ancla "^equip:" fallaba en silencio.
-- Mismo ítem que el caso 7, pero con la línea de crítico "coloreada".
local coloredEquipItem = "item:70006:0:0:0:0:0:0:0:70:0:0"
loadedItems[coloredEquipItem] = true
statsByLink[coloredEquipItem] = {}
mockTooltipLines[coloredEquipItem] = {
	"Colored Equip Line Item",
	"|cff1eff00Equip: Improves spell critical strike rating by 14.|r",
}
local coloredResult
ns.RequestItemStats(coloredEquipItem, function(stats) coloredResult = stats end)
assertEqual(coloredResult.ITEM_MOD_SPELL_CRIT_RATING_SHORT, 14,
	"caso 7b: línea 'Equip:' con código de color embebido sigue capturándose")

-- Caso 8: líneas que NO empiezan con "Equip:" (stat crudo en verde, bono de
-- socket, "Durability", etc.) no deben interpretarse como bono de Equip:.
local decoyItem = "item:70003:0:0:0:0:0:0:0:70:0:0"
loadedItems[decoyItem] = true
statsByLink[decoyItem] = {}
mockTooltipLines[decoyItem] = {
	"Decoy Item",
	"Socket Bonus: +5 Spell Damage and Healing", -- NO es una línea "Equip:", no debe contarse
	"Increases your spell power by 999 while sitting", -- sin prefijo "Equip:", tampoco cuenta
}
local decoyResult
ns.RequestItemStats(decoyItem, function(stats) decoyResult = stats end)
assertEqual(decoyResult.ITEM_MOD_SPELL_POWER_SHORT, nil, "caso 8: solo se parsean líneas que empiezan con 'Equip:'")

-- Caso 9: un bono "Equip: X" reconocido por el patrón pero con un término
-- que NO está en EQUIP_TEXT_TO_STAT (fuera del alcance acotado) se ignora
-- sin error, no rompe el resto del escaneo.
local unknownTermItem = "item:70004:0:0:0:0:0:0:0:70:0:0"
loadedItems[unknownTermItem] = true
statsByLink[unknownTermItem] = {}
mockTooltipLines[unknownTermItem] = {
	"Unknown Term Item",
	"Equip: Improves your fishing skill by 5.", -- término no mapeado, a propósito
	"Equip: Improves spell critical strike rating by 3.", -- este sí debe capturarse igual
}
local unknownTermResult
ns.RequestItemStats(unknownTermItem, function(stats) unknownTermResult = stats end)
assertEqual(unknownTermResult.ITEM_MOD_SPELL_CRIT_RATING_SHORT, 3,
	"caso 9: un término no mapeado no rompe el resto del escaneo")

-- Caso 10: item sin ninguna línea de tooltip simulada (mockTooltipLines
-- vacío para ese link) -- no debe arrojar error, GetItemStats solo.
local noTooltipItem = "item:70005:0:0:0:0:0:0:0:70:0:0"
loadedItems[noTooltipItem] = true
statsByLink[noTooltipItem] = { ITEM_MOD_AGILITY_SHORT = 3 }
local noTooltipResult
ns.RequestItemStats(noTooltipItem, function(stats) noTooltipResult = stats end)
assertEqual(noTooltipResult.ITEM_MOD_AGILITY_SHORT, 3, "caso 10: sin líneas de tooltip, solo GetItemStats, sin error")

-- Caso 11 (bug real): GetItemStats() devuelve el Armor base del ítem bajo
-- la clave "RESISTANCE0_NAME" en este cliente, no ITEM_MOD_ARMOR_SHORT --
-- confirmado contra SharpiesGearJudge (Database.lua, MSC.ShortNames). Sin
-- remapearla, el peso de Armadura de Paladín Protección (StatScorer.lua)
-- nunca aplicaba: reportado por un usuario cuya capa (solo Armor, nada
-- más) puntuaba 0.0 y salía "No es mejora" contra un slot vacío.
local armorCloak = "item:70007:0:0:0:0:0:0:0:70:0:0"
loadedItems[armorCloak] = true
statsByLink[armorCloak] = { RESISTANCE0_NAME = 15 }
local armorResult
ns.RequestItemStats(armorCloak, function(stats) armorResult = stats end)
assertEqual(armorResult.ITEM_MOD_ARMOR_SHORT, 15, "caso 11: RESISTANCE0_NAME se remapea a ITEM_MOD_ARMOR_SHORT")
assertEqual(armorResult.RESISTANCE0_NAME, nil, "caso 11: la clave cruda no debe quedar duplicada")

-- Caso 12: si el ítem YA trae ITEM_MOD_ARMOR_SHORT (poco común, pero no
-- debe perderse) y ADEMÁS RESISTANCE0_NAME, se suman en vez de pisarse.
local doubleArmorItem = "item:70008:0:0:0:0:0:0:0:70:0:0"
loadedItems[doubleArmorItem] = true
statsByLink[doubleArmorItem] = { ITEM_MOD_ARMOR_SHORT = 10, RESISTANCE0_NAME = 15 }
local doubleArmorResult
ns.RequestItemStats(doubleArmorItem, function(stats) doubleArmorResult = stats end)
assertEqual(doubleArmorResult.ITEM_MOD_ARMOR_SHORT, 25, "caso 12: RESISTANCE0_NAME se suma sobre un ITEM_MOD_ARMOR_SHORT ya existente")

-- --- Trinkets/procs con valor proxy por item ID (investigación sobre --------
-- AtlasLootClassic_TBCA_BIS a pedido del usuario) --------------------------
-- Caso 13: Wolfshead Helm (8345) -- el caso real que motivó esto. Su valor
-- real es 100% el efecto "Powershift: Energy Refund", que GetItemStats()
-- no expone y que ni siquiera tiene una línea "Equip:" parseable -- sin
-- PROC_ITEM_STAT_OVERRIDES, este ítem puntuaría 0 siempre.
local wolfsheadHelm = "item:8345:0:0:0:0:0:0:0:70:0:0"
loadedItems[wolfsheadHelm] = true
statsByLink[wolfsheadHelm] = {} -- sin stats crudos, como en el juego real
local wolfsheadResult
ns.RequestItemStats(wolfsheadHelm, function(stats) wolfsheadResult = stats end)
assertEqual(wolfsheadResult.ITEM_MOD_FERAL_ATTACK_POWER_SHORT, 80,
	"caso 13: Wolfshead Helm recibe el valor proxy real (80 Ataque Feral) por su efecto de Powershift")

-- Caso 14: un ítem con stats crudos reales Y un override de proc -- se
-- suman, no se pisan (mismo criterio que Armor en el caso 12).
local dragonspineTrophy = "item:28830:0:0:0:0:0:0:0:70:0:0"
loadedItems[dragonspineTrophy] = true
statsByLink[dragonspineTrophy] = { ITEM_MOD_CRIT_RATING_SHORT = 15 }
local dragonspineResult
ns.RequestItemStats(dragonspineTrophy, function(stats) dragonspineResult = stats end)
assertEqual(dragonspineResult.ITEM_MOD_CRIT_RATING_SHORT, 15, "caso 14: stat crudo del trinket sigue presente")
assertEqual(dragonspineResult.ITEM_MOD_HASTE_RATING_SHORT, 160, "caso 14: valor proxy del proc (Dragonspine Trophy) se suma aparte")

-- Caso 15: un ítem que NO está en la tabla curada no debe agregar nada --
-- PROC_ITEM_STAT_OVERRIDES es una lista curada, no un fallback genérico.
local plainRing = "item:70009:0:0:0:0:0:0:0:70:0:0"
loadedItems[plainRing] = true
statsByLink[plainRing] = { ITEM_MOD_INTELLECT_SHORT = 12 }
local plainRingResult
ns.RequestItemStats(plainRing, function(stats) plainRingResult = stats end)
assertEqual(plainRingResult.ITEM_MOD_INTELLECT_SHORT, 12, "caso 15: ítem fuera de la tabla curada no se altera")
local plainRingKeys = 0
for _ in pairs(plainRingResult) do plainRingKeys = plainRingKeys + 1 end
assertEqual(plainRingKeys, 1, "caso 15: y no gana ninguna clave extra")

-- --- Casos 16-18 (bugs reales, encontrados analizando capturas reales que --
-- el usuario comparó contra AtlasLootClassic_TBCA_BIS) ---------------------

-- Caso 16 ("HYBRID HEAL/DAMAGE SPLIT", verificado contra SharpiesGearJudge
-- Parse.lua ~308-320): Serpentcrest Life-Staff, "Equip: Increases healing
-- done by up to 227 and damage done by up to 76 for all magical spells and
-- effects." -- antes de este fix, la línea entera quedaba sin sumar nada
-- (ningún patrón capturaba los DOS números, y el primer nombre capturado
-- "healing done" no coincidía con ninguna clave de EQUIP_TEXT_TO_STAT).
local serpentcrestStaff = "item:70010:0:0:0:0:0:0:0:70:0:0"
loadedItems[serpentcrestStaff] = true
statsByLink[serpentcrestStaff] = { ITEM_MOD_STAMINA_SHORT = 27, ITEM_MOD_INTELLECT_SHORT = 27, ITEM_MOD_SPIRIT_SHORT = 46 }
mockTooltipLines[serpentcrestStaff] = {
	"Serpentcrest Life-Staff",
	"+27 Stamina",
	"+27 Intellect",
	"+46 Spirit",
	"Equip: Increases healing done by up to 227 and damage done by up to 76 for all magical spells and effects.",
}
local serpentcrestResult
ns.RequestItemStats(serpentcrestStaff, function(stats) serpentcrestResult = stats end)
assertEqual(serpentcrestResult.ITEM_MOD_SPIRIT_SHORT, 46, "caso 16: stats crudas siguen presentes")
assertEqual(serpentcrestResult.ITEM_MOD_SPELL_POWER_SHORT, 76, "caso 16: el valor de daño (76) se suma como Poder con Hechizos (pool compartido en TBC)")
assertEqual(serpentcrestResult.ITEM_MOD_SPELL_HEALING_DONE_SHORT, 151, "caso 16: solo el EXCEDENTE de curación (227-76=151) se suma aparte")

-- Caso 17: Splintering Greatstaff of the Beast, "Equip: Increases attack
-- power by 390 in Cat, Bear, Dire Bear, and Moonkin forms only." -- antes
-- de este fix, se leía como Poder de Ataque UNIVERSAL (inflando el score
-- de clases físicas que ni pueden usar el bono, no se transforman) en vez
-- de Poder de Ataque FERAL (el stat real para bonos atados a forma).
local splinteringGreatstaff = "item:70011:0:0:0:0:0:0:0:70:0:0"
loadedItems[splinteringGreatstaff] = true
statsByLink[splinteringGreatstaff] = { ITEM_MOD_STRENGTH_SHORT = 28, ITEM_MOD_AGILITY_SHORT = 28, ITEM_MOD_STAMINA_SHORT = 43 }
mockTooltipLines[splinteringGreatstaff] = {
	"Splintering Greatstaff of the Beast",
	"+28 Strength",
	"+28 Agility",
	"+43 Stamina",
	"Equip: Increases attack power by 390 in Cat, Bear, Dire Bear, and Moonkin forms only.",
}
local splinteringResult
ns.RequestItemStats(splinteringGreatstaff, function(stats) splinteringResult = stats end)
assertEqual(splinteringResult.ITEM_MOD_FERAL_ATTACK_POWER_SHORT, 390, "caso 17: bono atado a forma se mapea a Ataque Feral, no universal")
assertEqual(splinteringResult.ITEM_MOD_ATTACK_POWER_SHORT, nil, "caso 17: NO debe quedar también como Poder de Ataque universal")

-- Caso 18: un bono de Poder de Ataque SIN calificador de forma (el caso
-- normal, ej. un trinket cualquiera) sigue mapeando a universal -- el
-- redirect de forma feral es condicional, no reemplaza el mapeo normal.
local normalAPItem = "item:70012:0:0:0:0:0:0:0:70:0:0"
loadedItems[normalAPItem] = true
statsByLink[normalAPItem] = {}
mockTooltipLines[normalAPItem] = {
	"Normal AP Trinket",
	"Equip: Increases attack power by 100.",
}
local normalAPResult
ns.RequestItemStats(normalAPItem, function(stats) normalAPResult = stats end)
assertEqual(normalAPResult.ITEM_MOD_ATTACK_POWER_SHORT, 100, "caso 18: sin calificador de forma, sigue siendo Poder de Ataque universal")
assertEqual(normalAPResult.ITEM_MOD_FERAL_ATTACK_POWER_SHORT, nil, "caso 18: no se redirige de más sin la palabra de forma")

print("OK: ItemStatsAnalyzer.lua supera la prueba de humo")
