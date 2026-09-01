local ADDON_NAME, ns = ...

-- Cache de stats por "item string" (item:id:enchant:...:suffixID:...), no
-- por itemLink decorado (color + nombre) ni por itemID base. Dos links que
-- decoran el mismo item+sufijo comparten cache; dos sufijos distintos del
-- mismo itemID NUNCA comparten cache, porque en TBC tienen stats distintas.
local statsCache = {}

-- [itemID] = { {itemLink=..., itemString=..., callback=fn}, ... } en espera
-- de que el cliente termine de descargar los datos del item.
local pending = {}

local function GetItemString(itemLink)
	return itemLink and itemLink:match("(item:[%-%d:]+)")
end

-- Compartido con LootIntegration.lua (Fase 5): necesita la misma clave
-- estable para no depender de la renumeración de slots del loot window.
ns.GetItemString = GetItemString

local function GetItemID(itemString)
	return itemString and tonumber(itemString:match("item:(%d+)"))
end

--[[
BONOS "EQUIP: X" — REVIERTE A PROPÓSITO LA REGLA ORIGINAL DE "NUNCA
PARSEAR TOOLTIP" (documentada desde la Fase 2)
=====================================================================
Motivo real, reportado por un jugador: comparando dos ítems de mago
Frost, el addon marcó "Mejora: +21.6" un cambio que en el tooltip real
del cliente perdía ~23 Poder con Hechizos y ~14 Crítico de Hechizos.
Causa verificada: `GetItemStats()` NO expone los bonos que vienen de
líneas "Equip: Improves/Increases X by Y" del tooltip — son efectos que
se disparan al equipar (spell adjunto al ítem), no stats crudos del
ítem, y estructuralmente `GetItemStats` no los ve. Afectaba a los DOS
ítems del caso reportado, en ambas direcciones (de/hacia el ítem
equipado), por eso el resultado salió tan mal.

Verificado el mecanismo (no una suposición): SharpiesGearJudge
(gear-scoring TBC real, instalado localmente) tiene un archivo dedicado
completo (Parse.lua, ~700 líneas) solo para esto — un scanner de
tooltip con tabla de términos + patrones regex, porque no hay otra
forma de ver estos bonos. Lo de acá es la MISMA técnica, con un alcance
mucho más chico: solo cubre los patrones "Equip: Improves/Increases...
by [up to] N" (los que motivaron el reporte) y solo mapea a stats que
StatScorer.lua realmente pondera en algún perfil — no se copió la tabla
de términos completa de esa fuente (resistencias, stats de mascota,
"all stats", habilidad de arma por tipo, etc. que ningún perfil de acá
usa).

LIMITACIONES CONOCIDAS de este enfoque, aceptadas a propósito:
1. Cliente en inglés únicamente. Los patrones y la tabla de términos de
   abajo son texto en inglés — en cualquier otro idioma no van a
   encontrar nada, y AddEquipEffectStats simplemente no suma nada extra
   (degradación con gracia: el ítem sigue teniendo sus stats crudos de
   GetItemStats, solo le faltan los bonos de Equip:, igual que antes de
   este cambio). Es la PRIMERA dependencia de idioma de todo el addon —
   antes de esto, todo corría por claves numéricas/ITEM_MOD_* que no
   dependen del idioma del cliente.
2. Un parche que cambie la redacción de una línea "Equip:" rompe el
   patrón correspondiente en silencio. No hay forma de detectar esto
   automáticamente — depende de QA manual/reportes de usuario, igual
   que como se encontró este bug.
]]

-- Términos en inglés -> ITEM_MOD_X, acotado a los stats que algún perfil
-- de WEIGHT_PROFILES (StatScorer.lua) realmente pondera. Agregar una fila
-- acá SOLO si también hay un peso real para esa clave en algún perfil —
-- si no, es una regex más que nunca va a cambiar nada.
local EQUIP_TEXT_TO_STAT = {
	["hit rating"] = "ITEM_MOD_HIT_RATING_SHORT",
	["spell hit rating"] = "ITEM_MOD_HIT_SPELL_RATING_SHORT",
	["chance to hit with spells"] = "ITEM_MOD_HIT_SPELL_RATING_SHORT",
	["critical strike rating"] = "ITEM_MOD_CRIT_RATING_SHORT",
	["spell critical strike rating"] = "ITEM_MOD_SPELL_CRIT_RATING_SHORT",
	["critical hit with spells"] = "ITEM_MOD_SPELL_CRIT_RATING_SHORT",
	["haste rating"] = "ITEM_MOD_HASTE_RATING_SHORT",
	["spell haste rating"] = "ITEM_MOD_SPELL_HASTE_RATING_SHORT",
	["armor penetration rating"] = "ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT",
	["attack power"] = "ITEM_MOD_ATTACK_POWER_SHORT",
	["ranged attack power"] = "ITEM_MOD_RANGED_ATTACK_POWER_SHORT",
	["feral attack power"] = "ITEM_MOD_FERAL_ATTACK_POWER_SHORT",
	["spell power"] = "ITEM_MOD_SPELL_POWER_SHORT",
	["spell damage and healing"] = "ITEM_MOD_SPELL_POWER_SHORT",
	["damage and healing done by magical spells and effects"] = "ITEM_MOD_SPELL_POWER_SHORT",
	["damage done by magical spells and effects"] = "ITEM_MOD_SPELL_POWER_SHORT",
	["healing done by spells and effects"] = "ITEM_MOD_SPELL_HEALING_DONE_SHORT",
	["healing done by magical spells and effects"] = "ITEM_MOD_SPELL_HEALING_DONE_SHORT",
	["damage done by shadow spells and effects"] = "ITEM_MOD_SHADOW_DAMAGE_SHORT",
	["damage done by fire spells and effects"] = "ITEM_MOD_FIRE_DAMAGE_SHORT",
	["damage done by frost spells and effects"] = "ITEM_MOD_FROST_DAMAGE_SHORT",
	["damage done by arcane spells and effects"] = "ITEM_MOD_ARCANE_DAMAGE_SHORT",
	["damage done by nature spells and effects"] = "ITEM_MOD_NATURE_DAMAGE_SHORT",
	["defense rating"] = "ITEM_MOD_DEFENSE_SKILL_RATING_SHORT",
	["dodge rating"] = "ITEM_MOD_DODGE_RATING_SHORT",
	["parry rating"] = "ITEM_MOD_PARRY_RATING_SHORT",
	["block rating"] = "ITEM_MOD_BLOCK_RATING_SHORT",
	["shield block rating"] = "ITEM_MOD_BLOCK_RATING_SHORT",
	["resilience rating"] = "ITEM_MOD_RESILIENCE_RATING_SHORT",
	["mana per 5 sec"] = "ITEM_MOD_MANA_REGENERATION_SHORT",
}

-- Patrones "Equip: X" en inglés, del más al menos específico (el primero
-- que matchea gana, no se sigue probando). Mismo repertorio reducido que
-- SharpiesGearJudge (Parse.lua, MSC.Scanner.EquipPatterns), acotado a
-- "improves/increases ... by [up to] N" — cubre los dos casos reales que
-- motivaron esto ("Improves spell critical strike rating by 14" e
-- "Increases damage and healing done by magical spells and effects by up
-- to 44").
local EQUIP_LINE_PATTERNS = {
	"increases (.-) by up to (%d+)",
	"increases your (.-) by (%d+)",
	"increases (.-) by (%d+)",
	"improves your (.-) by (%d+)",
	"improves (.-) by (%d+)",
}

-- Reutiliza siempre el mismo frame (creado una vez, la primera llamada) —
-- mismo patrón que MSC_ScannerTooltip en SharpiesGearJudge. Crear un
-- GameTooltip nuevo por ítem desperdiciaría memoria sin ninguna ganancia.
local scanTooltip

--- Recorre las líneas del tooltip de `itemLink` buscando bonos "Equip:"
--- que correspondan a algún stat de EQUIP_TEXT_TO_STAT, y los suma sobre
--- `stats` (in-place). Usa un GameTooltip invisible reutilizable —
--- `CreateFrame("GameTooltip", nombre, nil, "GameTooltipTemplate")` +
--- `SetOwner(WorldFrame, "ANCHOR_NONE")` + `SetHyperlink` +
--- `_G[nombre.."TextLeft"..i]:GetText()` — verificado contra
--- SharpiesGearJudge (Helpers.lua, Parse.lua): es la forma estándar de
--- leer un tooltip sin mostrarlo en pantalla, no algo inventado acá.
local function AddEquipEffectStats(itemLink, stats)
	scanTooltip = scanTooltip or CreateFrame("GameTooltip", "PickItRightScanTooltip", nil, "GameTooltipTemplate")
	scanTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")
	scanTooltip:ClearLines()

	if not pcall(scanTooltip.SetHyperlink, scanTooltip, itemLink) then
		return
	end

	for i = 2, scanTooltip:NumLines() do
		local fontString = _G["PickItRightScanTooltipTextLeft" .. i]
		local text = fontString and fontString:GetText()
		if text then
			-- Limpieza defensiva antes de matchear "^equip:" -- mismo orden de
			-- pasos que MSC.Scanner.ParseEquipLine (SharpiesGearJudge): algunas
			-- líneas de tooltip traen códigos de color |cffXXXXXX...|r inline
			-- en el propio GetText(), no solo vía SetTextColor -- sin esta
			-- limpieza, un código de color al principio de la línea rompe el
			-- ancla "^equip:" en silencio y la línea completa queda invisible
			-- para el scanner, sin ningún error. Bug real: encontrado cuando
			-- un usuario reportó que el fix de esta misma fase no cambiaba el
			-- veredicto para un ítem que SÍ tenía línea "Equip:".
			text = text:lower()
				:gsub("|c%x%x%x%x%x%x%x%x", "")
				:gsub("|r", "")
				:gsub("\n", " ")
				:gsub("%s+", " ")
		end
		local equipLine = text and text:match("^%s*equip:%s*(.+)")
		if equipLine then
			for _, pattern in ipairs(EQUIP_LINE_PATTERNS) do
				local name, value = equipLine:match(pattern)
				if name and value then
					local statKey = EQUIP_TEXT_TO_STAT[name]
					if statKey then
						stats[statKey] = (stats[statKey] or 0) + tonumber(value)
					end
					break
				end
			end
		end
	end
end

-- Bug real de GetItemStats() en este cliente: el valor de Armadura base del
-- ítem viene bajo la clave literal "RESISTANCE0_NAME" (índice de escuela 0 =
-- Física/Armadura en el enum interno de WoW), no bajo ITEM_MOD_ARMOR_SHORT.
-- Confirmado real, no adivinado: SharpiesGearJudge (Database.lua,
-- MSC.ShortNames) mapea exactamente esa clave a "Armor" para mostrarla en su
-- UI -- y solo esa, ninguna RESISTANCE1_NAME..6_NAME (las resistencias
-- elementales sí llegan con su ITEM_MOD_X_RESISTANCE_SHORT normal). Sin este
-- remap, el peso de Armadura que algunos perfiles sí tienen (ej. Paladín
-- Protección, 0.12, StatScorer.lua) nunca se aplicaba: la clave cruda no
-- coincidía con ningún ITEM_MOD_X del perfil, puntuaba 0 en silencio -- bug
-- real reportado por un usuario (Paladín tanque, capa con solo Armadura
-- marcada "No es mejora" contra un slot vacío).
--[[
TRINKETS/PROCS/EFECTOS ON-USE — VALOR PROXY POR ITEM ID
=========================================================
Investigación a pedido del usuario: analizar `AtlasLootClassic_TBCA_BIS`
(listas de BiS reales de la comunidad, addon instalado) reveló que ~6% de
los ítems rank-1 se mantienen BiS en 3+ fases de contenido seguidas — la
señal de que su valor viene de un efecto especial (on-use, proc, "Powershift:
Energy Refund", etc.), no de sus stats crudos, porque ningún stat crudo
posterior los supera. El caso más extremo: Wolfshead Helm (ítem 8345), BiS
de cabeza para Druida Gato en las Fases 1-4 pese a ser un ítem de nivel
bajísimo — su valor real es 100% el efecto "Powershift: reembolsa energía",
que `GetItemStats()` no expone y que `AddEquipEffectStats` (bonos "Equip:
X" de tooltip) tampoco puede mapear, porque no es un stat fijo tipo
ITEM_MOD_X sino un efecto de mecánica específica.

Nuestro modelo de scoring (suma de stats ponderados) no tiene forma de
valorar esto por sí solo — necesita que ALGUIEN haga la conversión "este
efecto vale aproximadamente N puntos de tal stat". SharpiesGearJudge
(gear-scoring TBC real, instalado localmente) YA tiene esa conversión
hecha, curada a mano ítem por ítem (`Database.lua`, tabla pasada a
`AddOverrides` -> `MSC.TrinketDB`/`MSC.ItemOverrides`, campo `_AUTO_PROC`),
con la matemática documentada en cada nota (ej. "Use: 43.3 Avg AP (2m CD)"
= 260 AP de duración / tiempo de reutilización, promediado). Se porta esa
tabla completa (~90 ítems reales, no un subconjunto arbitrario) tal cual,
misma idea que ya usamos para pesos y caps: no inventar números propios
cuando existe una fuente real ya verificada.

Formato: [itemID] = { stat = "ITEM_MOD_X", val = N }. Wolfshead Helm
(8345) es el caso que motivó esto: `ITEM_MOD_FERAL_ATTACK_POWER_SHORT`+80,
el valor que SharpiesGearJudge asigna a su reembolso de energía.
]]
local PROC_ITEM_STAT_OVERRIDES = {
	[9449]   = { stat = "ITEM_MOD_HASTE_RATING_SHORT", val = 150 }, -- Use: 50% Haste, burst
	[8345]   = { stat = "ITEM_MOD_FERAL_ATTACK_POWER_SHORT", val = 80 }, -- Wolfshead Helm: Powershift Energy Refund
	[833]    = { stat = "ITEM_MOD_HEALTH_REGENERATION_SHORT", val = 1.38 }, -- Lifestone
	[11819]  = { stat = "ITEM_MOD_MANA_REGENERATION_SHORT", val = 1.67 },
	[11832]  = { stat = "ITEM_MOD_MANA_REGENERATION_SHORT", val = 2.8 }, -- Burst of Knowledge
	[17759]  = { stat = "ITEM_MOD_HEALTH_REGENERATION_SHORT", val = 1.39 },
	[21777]  = { stat = "ITEM_MOD_MANA_REGENERATION_SHORT", val = 12 },
	[24390]  = { stat = "ITEM_MOD_MANA_REGENERATION_SHORT", val = 6 }, -- Auslese's Light Channeler
	[30841]  = { stat = "ITEM_MOD_MANA_REGENERATION_SHORT", val = 18.3 }, -- Lower City Prayerbook
	[18354]  = { stat = "ITEM_MOD_SPELL_POWER_SHORT", val = 10 }, -- Imp Firebolt Dmg proxy
	[18355]  = { stat = "ITEM_MOD_ATTACK_POWER_SHORT", val = 20 }, -- Pet Dmg +4% proxy
	[18815]  = { stat = "ITEM_MOD_SPELL_POWER_SHORT", val = 15 }, -- Fire Thorns proxy
	[18951]  = { stat = "ITEM_MOD_AGILITY_SHORT", val = 1 }, -- Reduced Fall Dmg proxy
	[23836]  = { stat = "ITEM_MOD_ATTACK_POWER_SHORT", val = 140 },
	[10577]  = { stat = "ITEM_MOD_ATTACK_POWER_SHORT", val = 10.5 },
	[21756]  = { stat = "ITEM_MOD_AGILITY_SHORT", val = 5 }, -- Speed + Snare Immune proxy
	[21758]  = { stat = "ITEM_MOD_ATTACK_POWER_SHORT", val = 4.5 },
	[21760]  = { stat = "ITEM_MOD_BLOCK_VALUE_SHORT", val = 1.33 },
	[21763]  = { stat = "ITEM_MOD_ATTACK_POWER_SHORT", val = 14 }, -- Summon Truesilver Boar
	[21784]  = { stat = "ITEM_MOD_BLOCK_VALUE_SHORT", val = 2.33 },
	[22954]  = { stat = "ITEM_MOD_HASTE_RATING_SHORT", val = 25 },
	[23001]  = { stat = "ITEM_MOD_AGILITY_SHORT", val = 5 }, -- Threat Reduction proxy
	[23040]  = { stat = "ITEM_MOD_BLOCK_VALUE_SHORT", val = 39.2 },
	[22321]  = { stat = "ITEM_MOD_ATTACK_POWER_SHORT", val = 35 }, -- Heart of Wyrmthalak
	[23206]  = { stat = "ITEM_MOD_ATTACK_POWER_SHORT", val = 150 }, -- Mark of the Champion (Melee)
	[23207]  = { stat = "ITEM_MOD_SPELL_POWER_SHORT", val = 85 }, -- Mark of the Champion (Caster)
	[23041]  = { stat = "ITEM_MOD_ATTACK_POWER_SHORT", val = 43.3 }, -- Slayer's Crest
	[23046]  = { stat = "ITEM_MOD_SPELL_POWER_SHORT", val = 21.7 }, -- Restrained Essence of Sapphiron
	[24124]  = { stat = "ITEM_MOD_ATTACK_POWER_SHORT", val = 20 }, -- Figurine: Felsteel Boar
	[28288]  = { stat = "ITEM_MOD_HASTE_RATING_SHORT", val = 21.7 }, -- Abacus of Violent Odds
	[29383]  = { stat = "ITEM_MOD_ATTACK_POWER_SHORT", val = 46.3 }, -- Bloodlust Brooch
	[29776]  = { stat = "ITEM_MOD_ATTACK_POWER_SHORT", val = 33.3 }, -- Core of Ar'kelos
	[30293]  = { stat = "ITEM_MOD_SPELL_HEALING_DONE_SHORT", val = 39.7 }, -- Heavenly Inspiration
	[30665]  = { stat = "ITEM_MOD_SPIRIT_SHORT", val = 50 }, -- Earring of Soulful Meditation
	[23047]  = { stat = "ITEM_MOD_SPELL_HEALING_DONE_SHORT", val = 37.5 }, -- Eye of the Dead
	[25619]  = { stat = "ITEM_MOD_SPELL_POWER_SHORT", val = 17.3 }, -- Glowing Crystal Insignia (Horde)
	[25620]  = { stat = "ITEM_MOD_SPELL_POWER_SHORT", val = 17.3 }, -- Ancient Crystal Talisman (Alliance)
	[25628]  = { stat = "ITEM_MOD_ATTACK_POWER_SHORT", val = 23.1 }, -- Ogre Mauler's Badge
	[25633]  = { stat = "ITEM_MOD_ATTACK_POWER_SHORT", val = 23.1 }, -- Uniting Charm
	[25634]  = { stat = "ITEM_MOD_SPELL_HEALING_DONE_SHORT", val = 35.5 }, -- Oshu'gun Relic
	[27828]  = { stat = "ITEM_MOD_SPELL_HEALING_DONE_SHORT", val = 47 }, -- Warp-Scarab Brooch
	[26055]  = { stat = "ITEM_MOD_MANA_REGENERATION_SHORT", val = 37.5 }, -- Oculus of the Hidden Eye
	[27416]  = { stat = "ITEM_MOD_HEALTH_REGENERATION_SHORT", val = 37.5 }, -- Fetish of the Fallen
	[28108]  = { stat = "ITEM_MOD_MANA_REGENERATION_SHORT", val = 100 }, -- Power Infused Mushroom
	[28109]  = { stat = "ITEM_MOD_HEALTH_REGENERATION_SHORT", val = 100 }, -- Essence Infused Mushroom
	[27920]  = { stat = "ITEM_MOD_MANA_REGENERATION_SHORT", val = 10 }, -- Mark of Conquest
	[27921]  = { stat = "ITEM_MOD_MANA_REGENERATION_SHORT", val = 10 }, -- Mark of Conquest
	[28590]  = { stat = "ITEM_MOD_SPELL_HEALING_DONE_SHORT", val = 30 }, -- Ribbon of Sacrifice
	[30446]  = { stat = "ITEM_MOD_ATTACK_POWER_SHORT", val = 70 }, -- Solarian's Sapphire
	[30448]  = { stat = "ITEM_MOD_RANGED_ATTACK_POWER_SHORT", val = 40 }, -- Talon of Al'ar
	[30621]  = { stat = "ITEM_MOD_AGILITY_SHORT", val = 5 }, -- Prism of Inner Calm
	[30720]  = { stat = "ITEM_MOD_SPELL_POWER_SHORT", val = 28.1 }, -- Serpent-Coil Braid
	[32483]  = { stat = "ITEM_MOD_SPELL_HASTE_RATING_SHORT", val = 29.2 }, -- The Skull of Gul'dan
	[32654]  = { stat = "ITEM_MOD_ATTACK_POWER_SHORT", val = 36 }, -- Crystalforged Trinket
	[33828]  = { stat = "ITEM_MOD_SPELL_HEALING_DONE_SHORT", val = 66 }, -- Tome of Diabolic Remedy
	[33829]  = { stat = "ITEM_MOD_SPELL_POWER_SHORT", val = 35.2 }, -- Hex Shrunken Head
	[33831]  = { stat = "ITEM_MOD_ATTACK_POWER_SHORT", val = 60 }, -- Berserker's Call
	[34430]  = { stat = "ITEM_MOD_MANA_REGENERATION_SHORT", val = 33.3 }, -- Glimmering Naaru Sliver
	[33832]  = { stat = "ITEM_MOD_HEALTH_SHORT", val = 145.8 }, -- Battlemaster's Determination
	[34049]  = { stat = "ITEM_MOD_HEALTH_SHORT", val = 145.8 }, -- Battlemaster's Audacity
	[34050]  = { stat = "ITEM_MOD_HEALTH_SHORT", val = 145.8 }, -- Battlemaster's Perseverance
	[34578]  = { stat = "ITEM_MOD_HEALTH_SHORT", val = 145.8 }, -- Battlemaster's Determination
	[34579]  = { stat = "ITEM_MOD_HEALTH_SHORT", val = 145.8 }, -- Battlemaster's Audacity
	[34580]  = { stat = "ITEM_MOD_HEALTH_SHORT", val = 145.8 }, -- Battlemaster's Perseverance
	[35694]  = { stat = "ITEM_MOD_ATTACK_POWER_SHORT", val = 20 }, -- Figurine: Khorium Boar
	[35702]  = { stat = "ITEM_MOD_ATTACK_POWER_SHORT", val = 53.3 }, -- Figurine: Shadowsong Panther
	[35703]  = { stat = "ITEM_MOD_MANA_REGENERATION_SHORT", val = 25 }, -- Figurine: Seaspray Albatross
	[38287]  = { stat = "ITEM_MOD_ATTACK_POWER_SHORT", val = 46.3 }, -- Empty Mug of Direbrew
	[38288]  = { stat = "ITEM_MOD_SPELL_HEALING_DONE_SHORT", val = 49.5 }, -- Direbrew Hops
	[38289]  = { stat = "ITEM_MOD_BLOCK_VALUE_SHORT", val = 33.3 }, -- Coren's Lucky Coin
	[38290]  = { stat = "ITEM_MOD_SPELL_POWER_SHORT", val = 25.8 }, -- Dark Iron Smoking Pipe
	[185988] = { stat = "ITEM_MOD_HEALTH_REGENERATION_SHORT", val = 3.3 }, -- Communal Stone of Stoicism
	-- TBC: trinkets/armas de proc con uptime promediado
	[28830]  = { stat = "ITEM_MOD_HASTE_RATING_SHORT", val = 160 }, -- Dragonspine Trophy
	[27683]  = { stat = "ITEM_MOD_SPELL_HASTE_RATING_SHORT", val = 42 }, -- Quagmirran's Eye
	[30626]  = { stat = "ITEM_MOD_SPELL_POWER_SHORT", val = 63 }, -- Sextant of Unstable Currents
	[30627]  = { stat = "ITEM_MOD_ATTACK_POWER_SHORT", val = 75 }, -- Tsunami Talisman
	[32505]  = { stat = "ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT", val = 186 }, -- Madness of the Betrayer
	[34472]  = { stat = "ITEM_MOD_ATTACK_POWER_SHORT", val = 102 }, -- Shard of Contempt
	[28773]  = { stat = "ITEM_MOD_ATTACK_POWER_SHORT", val = 55 }, -- Don Santos' Famous Hunting Rifle
	[28573]  = { stat = "ITEM_MOD_ATTACK_POWER_SHORT", val = 60 }, -- Despair
	[28729]  = { stat = "ITEM_MOD_ATTACK_POWER_SHORT", val = 50 }, -- Blight
	[32262]  = { stat = "ITEM_MOD_ATTACK_POWER_SHORT", val = 60 }, -- Syphon of the Nathrezim
	[29301]  = { stat = "ITEM_MOD_ATTACK_POWER_SHORT", val = 26 }, -- Band of Eternal Champion
	[29305]  = { stat = "ITEM_MOD_SPELL_POWER_SHORT", val = 21 }, -- Band of Eternal Sage
	[29309]  = { stat = "ITEM_MOD_SPELL_HEALING_DONE_SHORT", val = 37 }, -- Band of Eternal Restorer
	[29313]  = { stat = "ITEM_MOD_ARMOR_SHORT", val = 133 }, -- Band of Eternal Defender
}

--- Suma el valor proxy de PROC_ITEM_STAT_OVERRIDES sobre `stats` (in-place),
--- si `itemLink` corresponde a un ítem de la tabla. A diferencia de
--- AddEquipEffectStats (parsea CUALQUIER línea "Equip:" con patrón
--- genérico), esto es una lista curada ítem por ítem — solo aplica a los
--- ~90 ítems reales portados de SharpiesGearJudge.
local function AddProcItemStats(itemLink, stats)
	local itemString = GetItemString(itemLink)
	local itemID = itemString and GetItemID(itemString)
	local override = itemID and PROC_ITEM_STAT_OVERRIDES[itemID]
	if override then
		stats[override.stat] = (stats[override.stat] or 0) + override.val
	end
end

local function NormalizeArmorKey(stats)
	local armorFromResistance0 = stats["RESISTANCE0_NAME"]
	if armorFromResistance0 then
		stats["ITEM_MOD_ARMOR_SHORT"] = (stats["ITEM_MOD_ARMOR_SHORT"] or 0) + armorFromResistance0
		stats["RESISTANCE0_NAME"] = nil
	end
end

-- GetItemStats devuelve una tabla plana {ITEM_MOD_X = valor} para los
-- stats crudos del ítem; AddEquipEffectStats suma encima los bonos de
-- "Equip: X" que GetItemStats no ve (ver el comentario grande arriba).
local function ExtractStats(itemLink)
	local stats = GetItemStats(itemLink) or {}
	NormalizeArmorKey(stats)
	AddEquipEffectStats(itemLink, stats)
	AddProcItemStats(itemLink, stats)
	return stats
end

--- Pide las stats de un itemLink. Si el cliente ya tiene el item cacheado,
--- llama a callback(stats) de inmediato; si no, reintenta cuando llegue
--- GET_ITEM_INFO_RECEIVED. `stats` siempre es una tabla (vacía si el link
--- no es un item equipable con stats), lista para pasarse tal cual al
--- motor de pesos de la Fase 3.
local function RequestItemStats(itemLink, callback)
	local itemString = GetItemString(itemLink)
	if not itemString then
		callback({})
		return
	end

	local cached = statsCache[itemString]
	if cached then
		callback(cached)
		return
	end

	if GetItemInfo(itemLink) then
		local stats = ExtractStats(itemLink)
		statsCache[itemString] = stats
		callback(stats)
		return
	end

	local itemID = GetItemID(itemString)
	if not itemID then
		callback({})
		return
	end

	pending[itemID] = pending[itemID] or {}
	table.insert(pending[itemID], { itemLink = itemLink, itemString = itemString, callback = callback })
end

ns.RequestItemStats = RequestItemStats

local frame = CreateFrame("Frame")
frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
frame:SetScript("OnEvent", function(_, _, itemID, success)
	local queue = pending[itemID]
	if not queue then
		return
	end
	pending[itemID] = nil

	for _, entry in ipairs(queue) do
		local stats = success and ExtractStats(entry.itemLink) or {}
		statsCache[entry.itemString] = stats
		entry.callback(stats)
	end
end)

-- Slots de equipo con stats reales. A diferencia de Retail, TBC conserva un
-- slot de Ranged con itemización propia (arcos/armas de fuego/varitas), así
-- que va incluido. Shirt/Tabard quedan fuera: son cosméticos, sin stats.
local EQUIPPED_SLOTS = {
	"HeadSlot", "NeckSlot", "ShoulderSlot", "BackSlot", "ChestSlot",
	"WristSlot", "HandsSlot", "WaistSlot", "LegsSlot", "FeetSlot",
	"Finger0Slot", "Finger1Slot", "Trinket0Slot", "Trinket1Slot",
	"MainHandSlot", "SecondaryHandSlot", "RangedSlot",
}

--- Snapshot del equipo actual. Devuelve dos tablas:
---   totalStats: {ITEM_MOD_X = suma de todas las piezas equipadas}
---   bySlot: {slotName = {link=itemLink, stats=tabla}}, para comparar un
---           item nuevo contra lo que ocupa su mismo slot en la Fase 3/4,
---           no contra el total del personaje.
--- Es síncrono: el equipo puesto ya está cacheado por el cliente casi
--- siempre (tuvo que cargar sus datos para dibujar al personaje). Si en el
--- juego real aparece algún hueco, envolver la llamada con RequestItemStats
--- en vez de reintroducir un GetItemInfo síncrono aquí.
local function GetEquippedSnapshot()
	local totalStats = {}
	local bySlot = {}

	for _, slotName in ipairs(EQUIPPED_SLOTS) do
		local slotID = GetInventorySlotInfo(slotName)
		local itemLink = GetInventoryItemLink("player", slotID)
		if itemLink then
			local itemString = GetItemString(itemLink)
			local stats = (itemString and statsCache[itemString]) or ExtractStats(itemLink)
			if itemString then
				statsCache[itemString] = stats
			end

			bySlot[slotName] = { link = itemLink, stats = stats }
			for stat, value in pairs(stats) do
				totalStats[stat] = (totalStats[stat] or 0) + value
			end
		end
	end

	return totalStats, bySlot
end

ns.GetEquippedSnapshot = GetEquippedSnapshot
