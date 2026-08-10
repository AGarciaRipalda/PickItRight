local ADDON_NAME, ns = ...

-- TBC Classic no tiene loot personal ni bonus rolls (son de Retail): todo
-- objeto lootable pasa por la ventana de loot estándar (LOOT_OPENED) o por
-- una tirada de grupo need/greed (START_LOOT_ROLL/CONFIRM_LOOT_ROLL). No
-- hay más caminos que cubrir.

-- {[itemString] = {itemLink=, result={eligible=, reason=, score=}}}
-- Vive solo mientras la ventana de loot actual está abierta.
local lootResults = {}

-- {[rollID] = {itemLink=, result={eligible=, reason=, score=}}}
-- ponytail: nunca se limpia (no escuchamos CANCEL_LOOT_ROLL); no es un
-- problema real de memoria para una sesión de juego — cada entrada es
-- diminuta y una noche de raid no genera miles de tiradas. Añadir limpieza
-- si algún día se vuelve un problema real.
local rollResults = {}

local function ClearTable(t)
	for k in pairs(t) do
		t[k] = nil
	end
end

--- Corre el pipeline completo de las Fases 2+3+4 sobre un itemLink y
--- guarda el resultado con `store(result)` cuando esté listo. Primero
--- consulta el cache de resultados de la Fase 7 (ns.GetCachedResult): un
--- item ya evaluado bajo el perfil activo se resuelve sin llamar siquiera
--- a RequestItemStats — el caso real que esto cubre es un pull de raid
--- donde 40 lobos sueltan el mismo trash, no solo el mismo corpse.
--- Async-safe cuando no hay cache: si el item ya está en el cache de stats
--- de la Fase 2, `store` se llama de inmediato; si no, cuando
--- ItemStatsAnalyzer resuelva el reintento vía GET_ITEM_INFO_RECEIVED.
local function AnalyzeAndStore(itemLink, store)
	local cached = ns.GetCachedResult(itemLink)
	if cached then
		store(cached)
		return
	end

	ns.RequestItemStats(itemLink, function(stats)
		local currentStats, bySlot = ns.GetEquippedSnapshot()
		local result = ns.EvaluateItem(itemLink, stats, currentStats, bySlot)
		store(result)
	end)
end

--- Recorre la ventana de loot abierta y analiza cada objeto nuevo. Se
--- guarda por item string (no por número de slot): los slots se pueden
--- renumerar al lootear un objeto de en medio, el link no cambia.
local function ScanLootWindow()
	for slot = 1, GetNumLootItems() do
		local itemLink = GetLootSlotLink(slot)
		if itemLink then
			local itemString = ns.GetItemString(itemLink)
			if itemString and not lootResults[itemString] then
				AnalyzeAndStore(itemLink, function(result)
					lootResults[itemString] = { itemLink = itemLink, result = result }
				end)
			end
		end
	end
end

--- Analiza la tirada `rollID` si todavía no se hizo. Se usa tanto desde
--- START_LOOT_ROLL (caso normal) como desde CONFIRM_LOOT_ROLL — cubre el
--- caso borde de que el addon se cargue/recargue a mitad de una tirada y
--- se pierda el START_LOOT_ROLL original; la guarda de "ya analizado" hace
--- que llamarla dos veces para la misma tirada sea gratis.
local function AnalyzeRoll(rollID)
	if not rollID or rollResults[rollID] then
		return
	end

	local itemLink = GetLootRollItemLink(rollID)
	if not itemLink then
		return
	end

	AnalyzeAndStore(itemLink, function(result)
		rollResults[rollID] = { itemLink = itemLink, result = result }
	end)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("LOOT_OPENED")
frame:RegisterEvent("LOOT_CLOSED")
frame:RegisterEvent("START_LOOT_ROLL")
frame:RegisterEvent("CONFIRM_LOOT_ROLL")
frame:SetScript("OnEvent", function(_, event, ...)
	-- Fase 8: /pickitright module LootIntegration off. No se puede des-registrar
	-- el frame en caliente, así que el apagado vive acá, al principio de
	-- cada evento.
	if not ns.IsModuleEnabled("LootIntegration") then
		return
	end

	if event == "LOOT_OPENED" then
		ScanLootWindow()
	elseif event == "LOOT_CLOSED" then
		ClearTable(lootResults)
	elseif event == "START_LOOT_ROLL" or event == "CONFIRM_LOOT_ROLL" then
		local rollID = ...
		AnalyzeRoll(rollID)
	end
end)

-- Almacenamiento temporal que consumirá el módulo de UI (próxima fase). Se
-- exponen las tablas directamente (se mutan in-place, nunca se reasignan,
-- así que la referencia siempre queda vigente) más un par de helpers de
-- consulta para no tener que conocer el detalle de itemString por fuera.
ns.currentLootResults = lootResults
ns.currentRollResults = rollResults

function ns.GetLootResult(itemLink)
	local itemString = ns.GetItemString(itemLink)
	return itemString and lootResults[itemString]
end

function ns.GetRollResult(rollID)
	return rollResults[rollID]
end
