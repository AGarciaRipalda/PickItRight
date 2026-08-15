local ADDON_NAME, ns = ...

--[[
Las tres tablas de datos de este archivo (proficiencia de armadura, de
armas, y stats irrelevantes por rol) están reconstruidas de memoria sobre
las reglas de TBC Classic. Son exactamente el tipo de dato fácil de
equivocar en un detalle no obvio (ej. Hunter sin mazas, Shaman sin
espadas, Rogue sin armas a dos manos) — verificar cada fila contra el
cliente (intentar equipar) o una fuente de theorycrafting actualizada
antes de confiar en ellas para bloquear recomendaciones reales.

WEAPON_PROFICIENCY sigue SIN verificar: se revisaron dos addons TBC reales
instalados en esta máquina (SharpiesGearJudge, gear-scoring; Gargul, loot)
y ninguno mantiene una tabla de armas propia como esta — ambos delegan la
pregunta "¿puede este personaje usar este ítem?" al cliente
(`IsEquippableItem` o un wrapper propio). No reemplacé esta tabla por esa
llamada porque no verifiqué la semántica exacta de armas específicamente
— candidato para la próxima verificación.

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
	ROGUE   = { [0] = true, [2] = true, [3] = true, [4] = true, [7] = true, [13] = true,
		[15] = true, [16] = true, [18] = true },
	PRIEST  = { [4] = true, [10] = true, [15] = true, [19] = true },
	SHAMAN  = { [0] = true, [1] = true, [4] = true, [5] = true, [10] = true, [13] = true, [15] = true },
	MAGE    = { [7] = true, [10] = true, [15] = true, [19] = true },
	WARLOCK = { [7] = true, [10] = true, [15] = true, [19] = true },
	DRUID   = { [4] = true, [5] = true, [10] = true, [15] = true },
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

	local worstEquippedScore, worstEquippedStats
	for _, slotName in ipairs(slots) do
		local equipped = bySlot[slotName]
		local equippedScore = equipped and ns.ScoreStats(equipped.stats, weightProfile, currentStats) or 0
		if not worstEquippedScore or equippedScore < worstEquippedScore then
			worstEquippedScore = equippedScore
			worstEquippedStats = equipped and equipped.stats or {}
		end
	end

	return score > worstEquippedScore, worstEquippedScore, worstEquippedStats
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

	local eligible, reason = IsEligible(itemLink, itemStats)
	local result
	if not eligible then
		result = { eligible = false, reason = reason, score = nil, isUpgrade = nil, equippedScore = nil, topStat = nil }
	else
		local weightProfile = ns.GetActiveWeightProfile()
		local score = ns.ScoreStats(itemStats, weightProfile, currentStats)
		local isUpgrade, equippedScore, equippedStats = ComputeUpgradeInfo(itemLink, score, weightProfile, currentStats, bySlot)
		local topStat = isUpgrade and GetTopContributingStat(itemStats, equippedStats, weightProfile) or nil
		result = { eligible = true, reason = nil, score = score, isUpgrade = isUpgrade, equippedScore = equippedScore, topStat = topStat }
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
