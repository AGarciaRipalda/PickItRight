local ADDON_NAME, ns = ...

--[[
Las tres tablas de datos de este archivo (proficiencia de armadura, de
armas, y stats irrelevantes por rol) están reconstruidas de memoria sobre
las reglas de TBC Classic. Son exactamente el tipo de dato fácil de
equivocar en un detalle no obvio (ej. Hunter sin mazas, Shaman sin
espadas, Rogue sin armas a dos manos) — verificar cada fila contra el
cliente (intentar equipar) o una fuente de theorycrafting actualizada
antes de confiar en ellas para bloquear recomendaciones reales.

WEAPON_PROFICIENCY: verificada y corregida contra `SharpiesGearJudge`
(`Classes/TBC/<Clase>.lua`, tabla `<Clase>.ValidWeapons` — SÍ existe, la
nota anterior de que "ningún addon mantiene tabla propia" era incorrecta:
lo que pasa es que `Evaluator.lua` usa `IsEquippableItem` ADEMÁS de esta
tabla, no en su lugar — `MSC:Internal_ScanBestMainHand` exige ambas
condiciones juntas, señal de que `IsEquippableItem` por sí sola no basta
para proficiencia de TIPO de arma, solo cubre otras condiciones de
equipabilidad (nivel, facción, etc.). 6 de 9 clases coincidían exacto
(Guerrero, Paladín, Cazador, Sacerdote, Mago, Brujo); 2 discrepancias
reales corregidas: Pícaro tenía Hachas de una mano (`[0]`) que la fuente
NO permite (bug real, un Pícaro nunca pudo usar hachas en TBC); Druida le
faltaba Armas de Puño (`[13]`), que la fuente SÍ permite. Chamán tiene una
entrada extra en la fuente (`[6]`) marcada en su propio comentario como
"Technically Armor" (probablemente un hack interno para trackear
escudos, no una proficiencia de arma real) — no se portó.

ARMOR_PROFICIENCY (más abajo, GetMaxArmorTier) SÍ se reemplazó, tras un
bug real reportado: un Paladín tanque de nivel 10 (rol/pestaña dominante
detectados bien, confirmado con /pickitright context) veía CUALQUIER
pieza de Cuero rechazada como "Tipo de armadura incorrecto, tu clase usa
Plate" — cierto a nivel 70, pero Guerrero/Paladín no entrenan Plate hasta
nivel 40 (antes de eso, su máximo real es Malla), y el filtro exigía
coincidencia EXACTA con el máximo de nivel 70 en vez de "como máximo lo
que ya sabés usar". Verificado el mecanismo real y los umbrales exactos
contra `SharpiesGearJudge` (`Helpers.lua`, `MSC.IsItemUsable`): compara
`subClassID > maxArmor` (como máximo, no exacto), con
Guerrero/Paladín = Malla(3) hasta nivel 40 y Plate(4) desde ahí,
Chamán/Cazador = Cuero(2) hasta nivel 40 y Malla(3) desde ahí.
]]

-- itemSubClassID (classID=4 Armor) -> nombre de material, para el mensaje
-- de rechazo. [0] "Miscellaneous" no es un material real (anillos,
-- trinkets, reliquias) — nunca debería consultarse para estos slots, ver
-- ARMOR_MATERIAL_SLOTS abajo.
local ARMOR_SUBCLASS_TO_MATERIAL = {
	[1] = "Cloth",
	[2] = "Leather",
	[3] = "Mail",
	[4] = "Plate",
}

--- Nivel de armadura máximo que la clase puede EQUIPAR ahora mismo (no el
--- máximo teórico de nivel 70). Guerrero/Paladín y Chamán/Cazador
--- entrenan su material superior recién a nivel 40 — antes de eso, quedan
--- en el nivel anterior. nil si la clase no está mapeada (no bloquea nada).
local function GetMaxArmorTier(class, level)
	if class == "WARRIOR" or class == "PALADIN" then
		return (level >= 40) and 4 or 3
	elseif class == "HUNTER" or class == "SHAMAN" then
		return (level >= 40) and 3 or 2
	elseif class == "ROGUE" or class == "DRUID" then
		return 2
	elseif class == "PRIEST" or class == "MAGE" or class == "WARLOCK" then
		return 1
	end
	return nil
end

-- Slots donde el material de la armadura importa. La Capa (INVTYPE_CLOAK)
-- queda fuera A PROPÓSITO: en WoW TODAS las capas tienen itemSubType
-- "Cloth" sin importar quién las use — es una rareza real de itemización
-- del juego, no un error de esta tabla. Anillos/Collares/Trinkets/Escudos
-- tampoco entran aquí: su itemSubType no es un material (es
-- "Miscellaneous"/"Shields"), así que nunca deberían bloquearse por esto.
local ARMOR_MATERIAL_SLOTS = {
	INVTYPE_HEAD = true,
	INVTYPE_SHOULDER = true,
	INVTYPE_CHEST = true,
	INVTYPE_ROBE = true,
	INVTYPE_WRIST = true,
	INVTYPE_HAND = true,
	INVTYPE_WAIST = true,
	INVTYPE_LEGS = true,
	INVTYPE_FEET = true,
}

--[[
itemSubClassID (classID=2 Weapon), estable desde Classic:
  0 Hacha 1H     1 Hacha 2H     2 Arco         3 Arma de fuego
  4 Maza 1H      5 Maza 2H      6 Arma de asta 7 Espada 1H
  8 Espada 2H    10 Bastón      13 Arma de puño
  15 Daga        16 Arrojadiza  18 Ballesta    19 Varita
]]
local WEAPON_PROFICIENCY = {
	WARRIOR = { [0] = true, [1] = true, [2] = true, [3] = true, [4] = true, [5] = true,
		[6] = true, [7] = true, [8] = true, [10] = true, [13] = true, [15] = true, [16] = true, [18] = true },
	PALADIN = { [0] = true, [1] = true, [4] = true, [5] = true, [6] = true, [7] = true, [8] = true },
	HUNTER  = { [0] = true, [1] = true, [2] = true, [3] = true, [6] = true, [7] = true, [8] = true,
		[10] = true, [13] = true, [15] = true, [16] = true, [18] = true },
	ROGUE   = { [2] = true, [3] = true, [4] = true, [7] = true, [13] = true,
		[15] = true, [16] = true, [18] = true },
	PRIEST  = { [4] = true, [10] = true, [15] = true, [19] = true },
	SHAMAN  = { [0] = true, [1] = true, [4] = true, [5] = true, [10] = true, [13] = true, [15] = true },
	MAGE    = { [7] = true, [10] = true, [15] = true, [19] = true },
	WARLOCK = { [7] = true, [10] = true, [15] = true, [19] = true },
	DRUID   = { [4] = true, [5] = true, [10] = true, [13] = true, [15] = true },
}

-- Stats considerados contraproducentes/irrelevantes por rol (ns.context.role
-- de SpecDetector.lua). No es lo mismo que "sin peso en el perfil" de la
-- Fase 3 (eso solo se ignora al puntuar) — esta tabla es para RECHAZAR un
-- ítem que claramente fue itemizado para otro rol, no para penalizar un
-- stat suelto de relleno en un ítem por lo demás bueno (ver
-- HasIrrelevantStatProfile más abajo para el criterio exacto).
local IRRELEVANT_STATS_BY_ROLE = {
	Tank = {
		ITEM_MOD_SPELL_POWER_SHORT = true,
		ITEM_MOD_MANA_REGENERATION_SHORT = true,
	},
	Healer = {
		ITEM_MOD_ATTACK_POWER_SHORT = true,
		ITEM_MOD_HIT_MELEE_RATING_SHORT = true,
		ITEM_MOD_CRIT_MELEE_RATING_SHORT = true,
	},
	Melee = {
		ITEM_MOD_SPELL_POWER_SHORT = true,
		ITEM_MOD_SPIRIT_SHORT = true,
		ITEM_MOD_MANA_REGENERATION_SHORT = true,
		ITEM_MOD_DEFENSE_SKILL_RATING_SHORT = true,
		ITEM_MOD_DODGE_RATING_SHORT = true,
		ITEM_MOD_PARRY_RATING_SHORT = true,
		ITEM_MOD_BLOCK_RATING_SHORT = true,
	},
	Caster = {
		ITEM_MOD_ATTACK_POWER_SHORT = true,
		ITEM_MOD_DEFENSE_SKILL_RATING_SHORT = true,
		ITEM_MOD_DODGE_RATING_SHORT = true,
		ITEM_MOD_PARRY_RATING_SHORT = true,
		ITEM_MOD_BLOCK_RATING_SHORT = true,
		ITEM_MOD_HIT_MELEE_RATING_SHORT = true,
		ITEM_MOD_CRIT_MELEE_RATING_SHORT = true,
	},
}

--- true si el ítem está itemizado para OTRO rol: no aporta ningún stat que
--- el perfil de pesos activo valore, pero sí trae al menos uno de la lista
--- de irrelevantes para el rol actual. Un ítem híbrido (ej. dps con un
--- toque de Espíritu) NO cae acá porque sí tiene stats relevantes — ese
--- caso ya lo maneja bien la Fase 3 simplemente ignorando el Espíritu al
--- puntuar, no hace falta rechazarlo entero.
local function HasIrrelevantStatProfile(itemStats, role, weightProfile)
	local irrelevantSet = IRRELEVANT_STATS_BY_ROLE[role]
	if not irrelevantSet then
		return false
	end

	local hasRelevantStat = false
	local hasIrrelevantStat = false

	for statKey, value in pairs(itemStats) do
		if value ~= 0 then
			if weightProfile[statKey] then
				hasRelevantStat = true
			elseif irrelevantSet[statKey] then
				hasIrrelevantStat = true
			end
		end
	end

	return hasIrrelevantStat and not hasRelevantStat
end

-- Motivo exacto usado cuando el cliente todavía no descargó los datos del
-- item. Es una constante (no un literal repetido) porque EvaluateItem
-- necesita compararlo para NUNCA cachear este resultado en particular —
-- ver el cache de resultados más abajo.
local REASON_NOT_LOADED = "Datos del ítem aún no disponibles (reintentar)"

--- Filtro de elegibilidad previo al scoring de la Fase 3. Se detiene en la
--- primera regla que falla — la UI solo necesita UN motivo concreto por
--- ítem, no una lista acumulada.
--- Devuelve: eligible (boolean), reason (string, solo si eligible=false).
local function IsEligible(itemLink, itemStats)
	local context = ns.context
	local class = context and context.class
	local role = context and context.role
	if not class or not role then
		return false, "Contexto de personaje no disponible todavía"
	end

	local itemName, _, _, _, _, _, _, _, itemEquipLoc, _, _, classID, subclassID = GetItemInfo(itemLink)
	if not itemName then
		return false, REASON_NOT_LOADED
	end

	if not itemEquipLoc or itemEquipLoc == "" then
		return false, "El objeto no es equipable"
	end

	if ARMOR_MATERIAL_SLOTS[itemEquipLoc] then
		local maxTier = GetMaxArmorTier(class, UnitLevel("player"))
		if maxTier and subclassID and subclassID > maxTier then
			local itemMaterial = ARMOR_SUBCLASS_TO_MATERIAL[subclassID] or "?"
			local maxMaterial = ARMOR_SUBCLASS_TO_MATERIAL[maxTier] or "?"
			return false, ("Tipo de armadura incorrecto (%s, todavía no entrenás %s)"):format(itemMaterial, maxMaterial)
		end
	end

	if classID == 2 then -- Weapon
		local allowed = WEAPON_PROFICIENCY[class]
		if not (allowed and allowed[subclassID]) then
			return false, "Arma no entrenada para tu clase"
		end
	end

	local weightProfile = ns.GetActiveWeightProfile and ns.GetActiveWeightProfile()
	if not weightProfile then
		return false, "Sin datos de build para tu clase/spec/fase todavía"
	end

	if HasIrrelevantStatProfile(itemStats, role, weightProfile) then
		return false, "Stats incompatibles con tu rol"
	end

	return true
end

ns.IsEligible = IsEligible

--[[
CLASE/SPEC OBJETIVO DEL ÍTEM — distinto de "es mejora para VOS". Pedido
explícito del usuario, corrigiendo el alcance de la primera versión de
esta línea: esa mostraba la clase/spec DEL JUGADOR (`ns.context`, dato
que ya tiene mirando su panel de talentos), no para qué build está
pensado el ÍTEM en cuestión — lo que sí es información nueva.

TBC no tiene un "target spec" declarado por ítem (eso es de Retail).
Mecanismo: puntúa `itemStats` contra el perfil de Fase 1 (WEIGHT_PROFILES,
StatScorer.lua) de CADA clase/spec que en principio podría llegar a
equiparlo — mismo filtro grueso de proficiencia de armadura/arma que
IsEligible, pero SIN el gate de nivel (acá importa el máximo teórico de
la clase a nivel 70, no el nivel actual del personaje: un ítem de Plate
sigue "orientado a Guerrero/Paladín" aunque el jugador todavía no
entrene Plate) — y se queda con el que puntúa más alto, normalizado por
la suma de pesos de ese perfil (`score / weightSum`) para no favorecer
sistemáticamente a los perfiles cuyos números de peso son más altos en
general (ej. Pícaro pesa todo ~2x más que Guerrero en la fuente,
comparar el score crudo sin normalizar sesgaría todo hacia Pícaro).

SOLO Fase 1: es la única con cobertura real de las 27 combinaciones
clase/spec (ver StatScorer.lua) — usar la fase de contenido activa del
jugador dejaría sin comparar a cualquier clase/spec sin datos para esa
fase todavía, lo que rompería la comparación cruzada entre clases.

Limitación conocida, aceptada a propósito: es una inferencia sobre datos
reales ya sourced (los mismos WEIGHT_PROFILES de SharpiesGearJudge/Icy
Veins), no una clasificación oficial del juego. Un ítem genuinamente
multi-clase (ej. solo Aguante + Crítico, sin nada de casteo/curación)
puede terminar mostrando un ganador entre varios candidatos casi
empatados — no hay forma de expresar "esto sirve para varias specs por
igual" con un solo resultado, y agregar eso sería una fase aparte.
]]
local function GetItemTargetBuild(itemLink, itemStats)
	if not itemStats or not next(itemStats) then
		return nil
	end
	if not ns.SpecNames or not ns.WeightProfiles or not ns.ScoreStats then
		return nil
	end

	local _, _, _, _, _, _, _, _, itemEquipLoc, _, _, classID, subclassID = GetItemInfo(itemLink)
	if not itemEquipLoc then
		return nil
	end

	local bestClass, bestTab, bestScore

	for class, specNames in pairs(ns.SpecNames) do
		local canEquip = true
		if classID == 2 then -- Weapon
			canEquip = WEAPON_PROFICIENCY[class] and WEAPON_PROFICIENCY[class][subclassID] or false
		elseif ARMOR_MATERIAL_SLOTS[itemEquipLoc] then
			local maxTier = GetMaxArmorTier(class, 70) -- nivel 70: máximo teórico, no el del jugador
			canEquip = maxTier ~= nil and subclassID ~= nil and subclassID <= maxTier
		end

		if canEquip then
			for tabIndex, specName in ipairs(specNames) do
				local profile = ns.WeightProfiles[class] and ns.WeightProfiles[class][specName] and ns.WeightProfiles[class][specName][1]
				if profile then
					local weightSum = 0
					for _, weight in pairs(profile) do
						weightSum = weightSum + weight
					end
					if weightSum > 0 then
						local score = ns.ScoreStats(itemStats, profile) / weightSum
						if not bestScore or score > bestScore then
							bestClass, bestTab, bestScore = class, tabIndex, score
						end
					end
				end
			end
		end
	end

	if not bestScore or bestScore <= 0 then
		return nil
	end

	return bestClass, bestTab
end

ns.GetItemTargetBuild = GetItemTargetBuild

-- equipLoc -> nombre(s) de slot de inventario, para saber contra qué
-- comparar el score del candidato. Anillos/Trinkets/Armas (equipLoc
-- ambiguo, dos slots posibles) listan ambos: el candidato compite contra
-- el PEOR de los dos equipados, no contra ambos — solo necesita superar
-- al más flojo de tus dos anillos para contar como mejora.
local EQUIP_SLOTS = {
	INVTYPE_HEAD = { "HeadSlot" },
	INVTYPE_NECK = { "NeckSlot" },
	INVTYPE_SHOULDER = { "ShoulderSlot" },
	INVTYPE_CLOAK = { "BackSlot" },
	INVTYPE_CHEST = { "ChestSlot" },
	INVTYPE_ROBE = { "ChestSlot" },
	INVTYPE_WRIST = { "WristSlot" },
	INVTYPE_HAND = { "HandsSlot" },
	INVTYPE_WAIST = { "WaistSlot" },
	INVTYPE_LEGS = { "LegsSlot" },
	INVTYPE_FEET = { "FeetSlot" },
	INVTYPE_FINGER = { "Finger0Slot", "Finger1Slot" },
	INVTYPE_TRINKET = { "Trinket0Slot", "Trinket1Slot" },
	-- SOLO MainHandSlot, a propósito (bug real encontrado corriendo los
	-- tests por primera vez): a diferencia de anillos/trinkets, el
	-- SecondaryHandSlot NO es un slot simétrico intercambiable para la
	-- mayoría de los personajes — solo Guerrero/Pícaro/Cazador y Chamán
	-- con talento pueden poner un arma ahí. Con ambos slots listados, un
	-- offhand vacío (el caso común para todos los demás) se trataba como
	-- "0, cualquier cosa es mejora", así que CUALQUIER arma de una mano
	-- salía en verde "Mejora" sin importar si era peor que la que ya
	-- tenías puesta. Comparar solo contra MainHandSlot es correcto para
	-- la mayoría (no dual-wielders) y conservador para quienes sí pueden
	-- dual-wield (no detecta "esto llena tu offhand vacío" como mejora,
	-- pero tampoco miente). Para recuperar esa detección haría falta una
	-- tabla de qué clases/specs pueden dual-wield — no existe todavía.
	INVTYPE_WEAPON = { "MainHandSlot" },
	INVTYPE_2HWEAPON = { "MainHandSlot" },
	INVTYPE_WEAPONMAINHAND = { "MainHandSlot" },
	INVTYPE_WEAPONOFFHAND = { "SecondaryHandSlot" },
	INVTYPE_SHIELD = { "SecondaryHandSlot" },
	INVTYPE_HOLDABLE = { "SecondaryHandSlot" },
	INVTYPE_RANGED = { "RangedSlot" },
	INVTYPE_RANGEDRIGHT = { "RangedSlot" },
}

--[[
BONOS DE SET (2pc/4pc) — último punto de "en que mas areas podriamos
mejorar?" / "todos, uno a uno". Nuestro modelo suma stats ítem por ítem;
no tiene forma de valorar que la 2ª o 4ª pieza de un mismo set desbloquea
un bono extra (stat fijo, o directamente un "score" sin stat real detrás,
ej. un proc). Sin esto, un ítem que completa un 4pc real puede puntuar
por debajo de una pieza sin set con mejores stats crudos.

Fuente: SharpiesGearJudge (Data_Sets.lua, tablas `tbcSets` -- membresía
itemID->set -- y `tbcScores` -- valor por umbral de piezas, formato
`{stats={ITEM_MOD_X=N}}` o `{score=N}` cuando el bono es un proc/efecto
sin stat equivalente directo, mismo criterio que PROC_ITEM_STAT_OVERRIDES
en ItemStatsAnalyzer.lua). Alcance: SOLO sets de PvE (crafteados,
Dungeon Set 3, Tier 4/5/6, la legendaria Warglaives, y 3 sets "niche" de
mazmorra con bono numérico real) -- se excluyen a propósito los sets de
Arena (S1-S4) y Honor nivel 70: están tuneados para Resiliencia, un stat
que ningún WEIGHT_PROFILES de acá pondera de verdad, y la propia fuente
los marca "Approx Values" (confianza más baja que el resto de la tabla).
]]
local SET_ITEM_MEMBERSHIP = {}
local SET_BONUS_SCORES = {}

do
	-- [setID] = { itemID, itemID, ... } -- todas las piezas del set,
	-- cualquier cantidad de ellas cuenta para los umbrales de abajo.
	local SET_ITEMS = {
		-- Crafteados (Sastrería/Peletería/Herrería)
		[559] = { 24266, 24262 }, -- Spellstrike
		[571] = { 24264, 24261 }, -- Whitemend
		[619] = { 29525, 29527, 29526 }, -- Primalstrike
		[552] = { 21848, 21847, 21846 }, -- Wrath of Spellfire
		[554] = { 21874, 21875, 21873 }, -- Primal Mooncloth
		[570] = { 23574, 23576, 23575, 23577, 23572, 23573, 23571, 23570 }, -- Burning Rage
		[617] = { 29519, 29521, 29520 }, -- Netherstrike
		[618] = { 29522, 29523, 29524 }, -- Windhawk

		-- Dungeon Set 3
		[650] = { 28275, 27801, 28228, 27474, 27874 }, -- Beast Lord (Hunter)
		[653] = { 28350, 27803, 28205, 27475, 27977 }, -- Bold Armor (Plate Tank)
		[660] = { 28192, 27713, 28401, 27528, 27936 }, -- Desolation (Plate DPS)
		[659] = { 28224, 27797, 28264, 27531, 27837 }, -- Wastewalker (Rogue/Druid)
		[658] = { 28193, 27796, 28191, 27465, 27907 }, -- Mana-Etched (Mage/Lock)
		[662] = { 28413, 27775, 28230, 27536, 27875 }, -- Hallowed (Priest Heal)
		[644] = { 28415, 27778, 28232, 27537, 27948 }, -- Oblivion (Warlock/Shadow Priest)
		[620] = { 28414, 27776, 28204, 27509, 27908 }, -- Assassination (Rogue)
		[630] = { 28349, 27802, 28231, 27510, 27909 }, -- Tidefury (Shaman)
		[647] = { 28278, 27738, 28229, 27508, 27838 }, -- Incanter's (Mage)
		[637] = { 28348, 27737, 28202, 27468, 27873 }, -- Moonglade (Druid)
		[661] = { 27712, 27910, 28194, 28226, 27489 }, -- Doomplate (Warrior)
		[623] = { 28285, 27739, 28203, 27535, 27839 }, -- Righteous (Paladin)

		-- Tier 4
		[655] = { 29021, 29023, 29019, 29020, 29022 }, -- Warbringer DPS
		[654] = { 29011, 29016, 29012, 29017, 29015 }, -- Warbringer Tank
		[624] = { 29061, 29064, 29062, 29065, 29063 }, -- Justicar Tank
		[625] = { 29068, 29070, 29066, 29067, 29069 }, -- Justicar Heal
		[626] = { 29073, 29075, 29071, 29072, 29074 }, -- Justicar Ret
		[651] = { 29081, 29084, 29082, 29085, 29083 }, -- Demon Stalker (Hunter)
		[621] = { 29044, 29047, 29045, 29048, 29046 }, -- Netherblade (Rogue)
		[640] = { 29098, 29100, 29096, 29097, 29099 }, -- Malorne Feral
		[638] = { 29086, 29089, 29087, 29090, 29088 }, -- Malorne Balance
		[641] = { 29093, 29095, 29091, 29092, 29094 }, -- Malorne Resto
		[631] = { 29033, 29034, 29035, 29036, 29037 }, -- Cyclone Enh
		[633] = { 29028, 29031, 29029, 29032, 29030 }, -- Cyclone Ele
		[632] = { 29038, 29039, 29040, 29041, 29042 }, -- Cyclone Resto
		[648] = { 29076, 29079, 29077, 29080, 29078 }, -- Aldor (Mage)
		[645] = { 28963, 28967, 28964, 28968, 28966 }, -- Voidheart (Warlock)
		[663] = { 29049, 29054, 29050, 29055, 29053 }, -- Incarnate Shadow
		[664] = { 29058, 29060, 29056, 29057, 29059 }, -- Incarnate Heal

		-- Tier 5
		[656] = { 30115, 30117, 30113, 30114, 30116 }, -- Destroyer DPS
		[657] = { 30120, 30122, 30118, 30119, 30121 }, -- Destroyer Tank
		[627] = { 30136, 30138, 30134, 30135, 30137 }, -- Crystalforge Ret
		[628] = { 30125, 30127, 30123, 30124, 30126 }, -- Crystalforge Tank
		[629] = { 30131, 30133, 30129, 30130, 30132 }, -- Crystalforge Heal
		[652] = { 30141, 30143, 30139, 30140, 30142 }, -- Rift Stalker
		[622] = { 30146, 30149, 30144, 30145, 30148 }, -- Deathmantle
		[602] = { 30228, 30230, 30222, 30223, 30229 }, -- Nordrassil Resto
		[642] = { 30216, 30217, 30219, 30220, 30221 }, -- Nordrassil Feral
		[643] = { 30231, 30232, 30233, 30234, 30235 }, -- Nordrassil Balance
		[649] = { 30206, 30210, 30196, 30205, 30207 }, -- Tirisfal (Mage)
		[646] = { 30212, 30215, 30214, 30211, 30213 }, -- Corruptor (Warlock)
		[665] = { 30152, 30154, 30150, 30151, 30153 }, -- Avatar Heal
		[666] = { 30161, 30163, 30159, 30160, 30162 }, -- Avatar Shadow
		[634] = { 30166, 30168, 30164, 30165, 30167 }, -- Cataclysm Ele
		[635] = { 30185, 30189, 30190, 30192, 30194 }, -- Cataclysm Enh
		[636] = { 30171, 30172, 30173, 30169, 30170 }, -- Cataclysm Resto
		[677] = { 31040, 31046, 31049, 34446, 31037, 34554, 34571 }, -- Thunderheart Resto
		[678] = { 31035, 31041, 31045, 34445, 31043, 34555, 34572 }, -- Thunderheart Balance
		[674] = { 31061, 31064, 31065, 34434, 31067, 34562, 34525 }, -- Absolution Shadow
		[675] = { 31063, 31069, 31066, 34435, 31060, 34559, 34526 }, -- Absolution Heal
		[682] = { 31015, 31024, 31018, 34439, 31011, 34546, 34567 }, -- Skyshatter Ele
		[684] = { 31016, 31020, 31023, 34438, 31017, 34545, 34569 }, -- Skyshatter Resto

		-- Tier 6
		[669] = { 31003, 31006, 31004, 34443, 31001, 34549, 34570 }, -- Gronnstalker (Hunter)
		[668] = { 31027, 31030, 31028, 34448, 31026, 34558, 34575 }, -- Slayer (Rogue)
		[672] = { 30972, 30979, 30975, 34441, 30969, 34560, 34543 }, -- Onslaught DPS
		[673] = { 30974, 30980, 30976, 34442, 30970, 34561, 34544 }, -- Onslaught Tank
		[670] = { 31051, 31054, 31052, 34436, 31050, 34563, 34527 }, -- Malefic (Warlock)
		[671] = { 31056, 31059, 31057, 34447, 31055, 34557, 34574 }, -- Tempest (Mage)
		[681] = { 30988, 30996, 30992, 34432, 30983, 34565, 34530 }, -- Lightbringer Ret
		[676] = { 31039, 31048, 31042, 34444, 31034, 34556, 34573 }, -- Thunderheart Feral
		[683] = { 31012, 31019, 31022, 34437, 31014, 34547, 34568 }, -- Skyshatter Enh

		-- Legendaria
		[699] = { 32837, 32838 }, -- Warglaives of Azzinoth

		-- Niche (drops de mazmorra con bono numérico real en la fuente)
		[667] = { 32946, 32945 }, -- Fists of Fury (Hyjal trash)
		[616] = { 31749, 31750 }, -- Twin Stars (Mana Tombs)
		[615] = { 28189, 27901 }, -- Latro's Flurry (Deadmines)
	}
	for setID, items in pairs(SET_ITEMS) do
		for _, itemID in ipairs(items) do
			SET_ITEM_MEMBERSHIP[itemID] = setID
		end
	end
end

-- [setID] = { [cantidadDePiezas] = { stats = {...} } o { score = N } }.
-- `score` es un valor de puntaje YA CALCULADO (no una clave ITEM_MOD_X) --
-- se usa cuando el bono real es un proc/efecto sin stat equivalente
-- directo, la fuente ya hizo esa conversión (mismo criterio que
-- PROC_ITEM_STAT_OVERRIDES). Ambos umbrales de un mismo set son
-- acumulativos: con 4 piezas puestas, el bono de 2pc Y el de 4pc suman
-- juntos, tal como en el juego real.
SET_BONUS_SCORES = {
	[559] = { [2] = { stats = { ITEM_MOD_SPELL_POWER_SHORT = 25 } } },
	[571] = { [2] = { stats = { ITEM_MOD_SPELL_HEALING_DONE_SHORT = 35 } } },
	[619] = { [3] = { stats = { ITEM_MOD_ATTACK_POWER_SHORT = 40 } } },
	[552] = { [3] = { stats = { ITEM_MOD_SPELL_POWER_SHORT = 35 } } },
	[554] = { [3] = { stats = { ITEM_MOD_MANA_REGENERATION_SHORT = 10 } } },
	[570] = { [2] = { score = 20 } },
	[617] = { [3] = { stats = { ITEM_MOD_AGILITY_SHORT = 20 } } },
	[618] = { [3] = { stats = { ITEM_MOD_INTELLECT_SHORT = 20 } } },

	[650] = { [2] = { score = 20 }, [4] = { stats = { ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT = 40 } } },
	[653] = { [2] = { stats = { ITEM_MOD_STRENGTH_SHORT = 20 } }, [4] = { score = 40 } },
	[660] = { [2] = { stats = { ITEM_MOD_HIT_RATING_SHORT = 35 } }, [4] = { stats = { ITEM_MOD_ATTACK_POWER_SHORT = 20 } } },
	[659] = { [2] = { stats = { ITEM_MOD_HIT_RATING_SHORT = 35 } }, [4] = { stats = { ITEM_MOD_ATTACK_POWER_SHORT = 30 } } },
	[658] = { [2] = { stats = { ITEM_MOD_HIT_SPELL_RATING_SHORT = 35 } }, [4] = { stats = { ITEM_MOD_SPELL_POWER_SHORT = 30 } } },
	[662] = { [2] = { stats = { ITEM_MOD_MANA_REGENERATION_SHORT = 15 } }, [4] = { score = 35 } },
	[644] = { [2] = { stats = { ITEM_MOD_HIT_SPELL_RATING_SHORT = 35 } }, [4] = { score = 40 } },
	[620] = { [2] = { score = 25 }, [4] = { stats = { ITEM_MOD_ATTACK_POWER_SHORT = 20 } } },
	[630] = { [2] = { stats = { ITEM_MOD_MANA_REGENERATION_SHORT = 15 } }, [4] = { score = 40 } },
	[647] = { [2] = { score = 20 }, [4] = { stats = { ITEM_MOD_SPELL_POWER_SHORT = 25 } } },
	[637] = { [2] = { stats = { ITEM_MOD_MANA_REGENERATION_SHORT = 15 } }, [4] = { stats = { ITEM_MOD_SPELL_POWER_SHORT = 20 } } },
	[661] = { [2] = { score = 20 }, [4] = { score = 35 } },
	[623] = { [2] = { score = 25 }, [4] = { score = 40 } },

	[655] = { [2] = { score = 30 }, [4] = { score = 45 } },
	[654] = { [2] = { score = 25 }, [4] = { score = 50 } },
	[624] = { [2] = { score = 30 }, [4] = { stats = { ITEM_MOD_MANA_REGENERATION_SHORT = 10 } } },
	[625] = { [2] = { score = 35 }, [4] = { score = 50 } },
	[626] = { [2] = { score = 25 }, [4] = { score = 40 } },
	[651] = { [2] = { score = 30 }, [4] = { score = 60 } },
	[621] = { [2] = { score = 80 }, [4] = { score = 50 } },
	[640] = { [2] = { score = 30 }, [4] = { stats = { ITEM_MOD_STRENGTH_SHORT = 20 } } },
	[638] = { [2] = { score = 20 }, [4] = { score = 40 } },
	[641] = { [2] = { stats = { ITEM_MOD_MANA_REGENERATION_SHORT = 8 } }, [4] = { score = 45 } },
	[631] = { [2] = { stats = { ITEM_MOD_STRENGTH_SHORT = 20 } }, [4] = { score = 50 } },
	[633] = { [2] = { stats = { ITEM_MOD_MANA_REGENERATION_SHORT = 8 } }, [4] = { score = 45 } },
	[632] = { [2] = { score = 25 }, [4] = { stats = { ITEM_MOD_SPELL_POWER_SHORT = 40 } } },
	[648] = { [2] = { score = 15 }, [4] = { stats = { ITEM_MOD_SPELL_HASTE_RATING_SHORT = 35 } } },
	[645] = { [2] = { stats = { ITEM_MOD_SPELL_POWER_SHORT = 35 } }, [4] = { score = 80 } },
	[663] = { [2] = { score = 25 }, [4] = { score = 40 } },
	[664] = { [2] = { score = 25 }, [4] = { score = 40 } },

	[656] = { [2] = { score = 40 }, [4] = { stats = { ITEM_MOD_HASTE_RATING_SHORT = 50 } } },
	[657] = { [2] = { score = 40 }, [4] = { score = 60 } },
	[627] = { [2] = { score = 30 }, [4] = { score = 50 } },
	[628] = { [2] = { score = 40 }, [4] = { score = 60 } },
	[629] = { [2] = { score = 35 }, [4] = { score = 50 } },
	[652] = { [2] = { score = 50 }, [4] = { stats = { ITEM_MOD_CRIT_RATING_SHORT = 35 } } },
	[622] = { [2] = { score = 60 }, [4] = { score = 40 } },
	[602] = { [2] = { stats = { ITEM_MOD_MANA_REGENERATION_SHORT = 10 } }, [4] = { score = 50 } },
	[642] = { [2] = { score = 30 }, [4] = { score = 50 } },
	[643] = { [2] = { score = 25 }, [4] = { score = 45 } },
	[649] = { [2] = { score = 50 }, [4] = { stats = { ITEM_MOD_SPELL_CRIT_RATING_SHORT = 70 } } },
	[646] = { [2] = { score = 60 }, [4] = { score = 55 } },
	[665] = { [2] = { score = 25 }, [4] = { score = 40 } },
	[666] = { [2] = { score = 25 }, [4] = { score = 40 } },
	[634] = { [2] = { score = 25 }, [4] = { score = 45 } },
	[635] = { [2] = { score = 30 }, [4] = { score = 50 } },
	[636] = { [2] = { stats = { ITEM_MOD_MANA_REGENERATION_SHORT = 10 } }, [4] = { score = 50 } },
	[677] = { [2] = { score = 40 }, [4] = { score = 100 } },
	[678] = { [2] = { score = 30 }, [4] = { score = 90 } },
	[674] = { [2] = { score = 40 }, [4] = { score = 100 } },
	[675] = { [2] = { score = 35 }, [4] = { score = 100 } },
	[682] = { [2] = { score = 40 }, [4] = { score = 90 } },
	[684] = { [2] = { stats = { ITEM_MOD_MANA_REGENERATION_SHORT = 10 } }, [4] = { score = 85 } },

	[669] = { [2] = { score = 40 }, [4] = { score = 120 } },
	[668] = { [2] = { score = 50 }, [4] = { score = 100 } },
	[672] = { [2] = { score = 40 }, [4] = { score = 80 } },
	[673] = { [2] = { score = 45 }, [4] = { score = 110 } },
	[670] = { [2] = { score = 50 }, [4] = { score = 130 } },
	[671] = { [2] = { score = 40 }, [4] = { score = 125 } },
	[681] = { [2] = { score = 35 }, [4] = { score = 120 } },
	[676] = { [2] = { score = 50 }, [4] = { score = 110 } },
	[683] = { [2] = { score = 45 }, [4] = { score = 90 } },

	[699] = { [2] = { score = 500 } },

	[667] = { [2] = { score = 40 } },
	[616] = { [2] = { stats = { ITEM_MOD_HIT_SPELL_RATING_SHORT = 15, ITEM_MOD_HIT_RATING_SHORT = 15 } } },
	[615] = { [2] = { stats = { ITEM_MOD_ATTACK_POWER_SHORT = 30 } } },
}

local function GetItemIDFromLink(itemLink)
	local itemString = itemLink and ns.GetItemString and ns.GetItemString(itemLink)
	return itemString and ns.GetItemID and ns.GetItemID(itemString)
end

--- Cuenta piezas equipadas por set, contando TODOS los slots de bySlot
--- salvo `excludeSlotName` (el slot que se está por reemplazar -- no
--- corresponde contarlo dos veces, una vez como "lo que ya tenías" y otra
--- como parte del conteo base).
local function BuildSetCounts(bySlot, excludeSlotName)
	local counts = {}
	for slotName, equipped in pairs(bySlot) do
		if slotName ~= excludeSlotName and equipped.link then
			local setID = SET_ITEM_MEMBERSHIP[GetItemIDFromLink(equipped.link)]
			if setID then
				counts[setID] = (counts[setID] or 0) + 1
			end
		end
	end
	return counts
end

--- Suma los bonos de TODOS los umbrales que `count` alcanza o supera (2pc
--- Y 4pc si count>=4, acumulativos como en el juego real).
local function GetSetBonusValue(setID, count, weightProfile, currentStats)
	local thresholds = setID and SET_BONUS_SCORES[setID]
	if not thresholds then
		return 0
	end
	local total = 0
	for threshold, bonus in pairs(thresholds) do
		if count >= threshold then
			total = total + (bonus.score or (bonus.stats and ns.ScoreStats(bonus.stats, weightProfile, currentStats)) or 0)
		end
	end
	return total
end

--- Valor de "cuánto bono de set aporta tener esta pieza puesta en este
--- slot", dado el conteo del resto del equipo (`counts`, ya excluye el
--- slot en cuestión). 0 si el ítem no pertenece a ningún set.
local function SetPieceValue(setID, counts, weightProfile, currentStats)
	if not setID then
		return 0
	end
	return GetSetBonusValue(setID, (counts[setID] or 0) + 1, weightProfile, currentStats)
end

--- Diferencia neta de bono de set al reemplazar lo que hay en `worstSlotName`
--- (bySlot) por `candidateLink`. Si ambos pertenecen al mismo set, el
--- conteo total no cambia (se resta una pieza y se suma otra del mismo
--- set) y el resultado sale 0 automáticamente, sin necesitar un caso
--- especial. Positivo = el candidato suma/completa un umbral que el ítem
--- actual no tenía; negativo = equiparlo rompe un umbral que ya estaba
--- activo.
local function GetSetBonusSwapDelta(candidateLink, bySlot, worstSlotName, weightProfile, currentStats)
	local candidateSetID = SET_ITEM_MEMBERSHIP[GetItemIDFromLink(candidateLink)]
	local equippedLink = worstSlotName and bySlot[worstSlotName] and bySlot[worstSlotName].link
	local equippedSetID = SET_ITEM_MEMBERSHIP[GetItemIDFromLink(equippedLink)]
	if not candidateSetID and not equippedSetID then
		return 0
	end

	local counts = BuildSetCounts(bySlot, worstSlotName)
	return SetPieceValue(candidateSetID, counts, weightProfile, currentStats)
		- SetPieceValue(equippedSetID, counts, weightProfile, currentStats)
end

--- Compara `score` contra lo que el personaje ya tiene puesto en el slot
--- que le corresponde a `itemLink`. Devuelve:
---   isUpgrade: true/false, o nil si no se puede comparar (equipLoc sin
---              mapear en EQUIP_SLOTS)
---   equippedScore: el score de lo peor de lo equipado en ese slot (0 si
---              el slot está vacío), o nil junto con isUpgrade=nil
---   equippedStats: la tabla de stats de ESE slot (peor de los dos si es
---              simétrico), {} si el slot está vacío -- la usa
---              GetTopContributingStat para explicar el veredicto sin
---              tener que recorrer bySlot de nuevo.
--- `bySlot` es el segundo valor de ns.GetEquippedSnapshot() (Fase 2).
local function ComputeUpgradeInfo(itemLink, score, weightProfile, currentStats, bySlot)
	if not bySlot then
		return nil, nil
	end

	local _, _, _, _, _, _, _, _, itemEquipLoc = GetItemInfo(itemLink)
	local slots = EQUIP_SLOTS[itemEquipLoc]
	if not slots then
		return nil, nil
	end

	local worstEquippedScore, worstEquippedStats, worstSlotName
	for _, slotName in ipairs(slots) do
		local equipped = bySlot[slotName]
		local equippedScore = equipped and ns.ScoreStats(equipped.stats, weightProfile, currentStats) or 0
		if not worstEquippedScore or equippedScore < worstEquippedScore then
			worstEquippedScore = equippedScore
			worstEquippedStats = equipped and equipped.stats or {}
			worstSlotName = slotName
		end
	end

	-- Bono de set: no se muestra como número aparte (misma regla que el
	-- resto del score), solo desempata isUpgrade cuando completar/romper
	-- un 2pc/4pc pesa más que la diferencia de stats crudos del ítem.
	local setBonusDelta = GetSetBonusSwapDelta(itemLink, bySlot, worstSlotName, weightProfile, currentStats)

	return (score + setBonusDelta) > worstEquippedScore, worstEquippedScore, worstEquippedStats
end

--- Entre los stats que el perfil activo pondera, cuál es el que más
--- explica por qué el candidato ganó (o no) contra lo equipado -- el de
--- mayor `(candidato - equipado) * peso`. Pensado para UIIntegration.lua:
--- mostrar "Por: +Crítico de Hechizos" es más útil que un score sin
--- contexto, sin volver a mostrar el número de score en sí (pedido
--- explícito de una fase anterior). nil si ningún stat ponderado mejora
--- (ej. la mejora viene solo de stats sin peso, o no hay con qué comparar).
local function GetTopContributingStat(itemStats, equippedStats, weightProfile)
	if not itemStats or not equippedStats or not weightProfile then
		return nil
	end

	local topStat, topContribution = nil, 0
	for statKey, weight in pairs(weightProfile) do
		local delta = (itemStats[statKey] or 0) - (equippedStats[statKey] or 0)
		local contribution = delta * weight
		if contribution > topContribution then
			topStat, topContribution = statKey, contribution
		end
	end

	return topStat
end

--[[
FASE 7: CACHE DE RESULTADOS YA EVALUADOS
=========================================
Clave conceptual: itemLink completo (con sufijo aleatorio, vía
ns.GetItemString) + perfil activo. Implementado como invalidación TOTAL de
la tabla cuando cambia el perfil, en vez de concatenar itemString+perfil en
una sola key — así no se acumulan en memoria resultados de perfiles/fases
viejos de la misma sesión, y sigue siendo, en la práctica, exactamente
"una entrada por item bajo el perfil activo".

Bug real reportado por un jugador, corrige la limitación que quedaba
documentada arriba como "no verificado en este pase": comparando "Terrorcloth
Mantle" contra el "Mantle of Magical Might" ya equipado, el addon marcó
"Equípatelo" un cambio que perdía 16 de Crítico de Hechizos y 8 de Poder con
Hechizos (confirmado con el propio panel de comparación de Blizzard) — una
diferencia clara bajo cualquier perfil de Mago (Frost o Arcane). Causa: la
clave de cache NO incluía el equipo actualmente puesto, así que un resultado
calculado ANTES de equipar el Mantle of Magical Might (con un slot de hombros
más débil o vacío) quedaba pegado para siempre, porque el itemString del
candidato no cambiaba. Fix: `equipmentRevision` (abajo) se suma a la key y
sube en `PLAYER_EQUIPMENT_CHANGED` — evento confirmado real (registrado sin
guard en SharpiesGearJudge, Dynamic_Engine.lua, para este mismo propósito de
invalidar cache al cambiar de equipo).
]]
local resultCache = {}
local cachedProfileKey

local equipmentRevision = 0
local equipmentWatcher = CreateFrame("Frame")
equipmentWatcher:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
equipmentWatcher:SetScript("OnEvent", function()
	equipmentRevision = equipmentRevision + 1
end)

-- Incluye ns.GetOverridesVersion (Fase 8, AddonSettings.lua): un override
-- manual de pesos cambia lo que GetActiveWeightProfile devuelve para la
-- MISMA clase/spec/fase, así que sin este componente en la key un
-- /pickitright weight no invalidaría nada hasta el próximo cambio de spec o
-- fase — quedaría sin efecto visible de inmediato, rompiendo la misma
-- garantía de "se actualiza al momento" que ya existe para la fase.
local function GetProfileKey()
	local context = ns.context
	local phase = ns.GetContentPhase and ns.GetContentPhase()
	local overridesVersion = ns.GetOverridesVersion and ns.GetOverridesVersion()
	return table.concat({ tostring(context and context.class), tostring(context and context.dominantTab),
		tostring(phase), tostring(overridesVersion), tostring(equipmentRevision) }, "|")
end

local function InvalidateCacheIfProfileChanged()
	local currentKey = GetProfileKey()
	if currentKey ~= cachedProfileKey then
		for key in pairs(resultCache) do
			resultCache[key] = nil
		end
		cachedProfileKey = currentKey
	end
end

--- Consulta el cache sin disparar ningún trabajo (ni siquiera GetItemInfo).
--- nil si no hay nada cacheado para este item bajo el perfil activo ahora
--- mismo. Pensado para que LootIntegration.lua (Fase 5) lo consulte ANTES
--- de llamar a ns.RequestItemStats, para que un item repetido en un pull
--- de raid (40 lobos, mismo trash) tenga coste de CPU cero de punta a
--- punta, no solo en el paso de scoring.
local function GetCachedResult(itemLink)
	InvalidateCacheIfProfileChanged()
	local itemString = ns.GetItemString and ns.GetItemString(itemLink)
	return itemString and resultCache[itemString]
end

ns.GetCachedResult = GetCachedResult

--- Punto de entrada combinado de las Fases 3+4: corre el filtro primero y
--- SOLO llama a ScoreStats si el ítem lo pasa. Esta es la función que debe
--- usar la Fase 5 (integración de loot) en vez de llamar a IsEligible y
--- ScoreStats por separado, para no poder saltarse el filtro por error.
--- `bySlot` es opcional (segundo valor de ns.GetEquippedSnapshot()); sin
--- él, isUpgrade/equippedScore quedan en nil y solo se devuelve el score
--- absoluto del ítem. Cachea el resultado (ver GetCachedResult arriba),
--- salvo cuando el motivo fue "datos aún no disponibles" — cachear ESE
--- resultado dejaría un item atascado en "reintentar" para siempre y
--- rompería el reintento automático de la Fase 2.
local function EvaluateItem(itemLink, itemStats, currentStats, bySlot)
	local cached = GetCachedResult(itemLink)
	if cached then
		return cached
	end

	-- Independiente de la elegibilidad del jugador actual: es sobre el
	-- ítem, no sobre si ESTE personaje puede usarlo.
	local targetClass, targetTab = GetItemTargetBuild(itemLink, itemStats)

	local eligible, reason = IsEligible(itemLink, itemStats)
	local result
	if not eligible then
		result = { eligible = false, reason = reason, score = nil, isUpgrade = nil, equippedScore = nil, topStat = nil, targetClass = targetClass, targetTab = targetTab }
	else
		local weightProfile = ns.GetActiveWeightProfile()
		local score = ns.ScoreStats(itemStats, weightProfile, currentStats)
		local isUpgrade, equippedScore, equippedStats = ComputeUpgradeInfo(itemLink, score, weightProfile, currentStats, bySlot)
		local topStat = isUpgrade and GetTopContributingStat(itemStats, equippedStats, weightProfile) or nil
		result = { eligible = true, reason = nil, score = score, isUpgrade = isUpgrade, equippedScore = equippedScore, topStat = topStat, targetClass = targetClass, targetTab = targetTab }
	end

	if reason ~= REASON_NOT_LOADED then
		local itemString = ns.GetItemString and ns.GetItemString(itemLink)
		if itemString then
			resultCache[itemString] = result
		end
	end

	return result
end

ns.EvaluateItem = EvaluateItem
