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

-- GetItemStats ya devuelve una tabla plana {ITEM_MOD_X = valor}; esta es la
-- única función que la llama. Nunca tocar el texto del tooltip aquí, ni
-- como fallback: es lento y depende del idioma del cliente.
local function ExtractStats(itemLink)
	return GetItemStats(itemLink) or {}
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
