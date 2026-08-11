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
		local equipLine = text and text:lower():match("^equip:%s*(.+)")
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

-- GetItemStats devuelve una tabla plana {ITEM_MOD_X = valor} para los
-- stats crudos del ítem; AddEquipEffectStats suma encima los bonos de
-- "Equip: X" que GetItemStats no ve (ver el comentario grande arriba).
local function ExtractStats(itemLink)
	local stats = GetItemStats(itemLink) or {}
	AddEquipEffectStats(itemLink, stats)
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
