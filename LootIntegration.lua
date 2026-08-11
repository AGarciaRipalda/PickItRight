local ADDON_NAME, ns = ...

-- TBC Classic no tiene loot personal ni bonus rolls (son de Retail): todo
-- objeto lootable pasa por la ventana de loot estándar (LOOT_OPENED) o por
-- una tirada de grupo need/greed (START_LOOT_ROLL/CONFIRM_LOOT_ROLL). No
-- hay más caminos que cubrir.

-- Bug real encontrado en juego (Fase 9): en el cliente TBC Anniversary
-- (arquitectura moderna, ver el comentario "11.x" de SharpiesGearJudge en
-- TooltipManager.lua) los globals clásicos GetContainerNumSlots/
-- GetContainerItemLink NO existen — solo la variante namespaced
-- C_Container.*. Sin este shim, ScanBags tiraba "attempt to call a nil
-- value" al abrir la mochila. Verificado el patrón `C_Container.X or X`
-- contra 6 addons reales instalados (SharpiesGearJudge —Interface.lua
-- recorre bag=0,4 con la misma estructura que ScanBags acá—, BigWigs,
-- DBM-Core, Details, Gathering, Gargul): todos usan exactamente este
-- fallback, ninguno asume que solo un lado existe.
local GetContainerNumSlots = C_Container and C_Container.GetContainerNumSlots or GetContainerNumSlots
local GetContainerItemLink = C_Container and C_Container.GetContainerItemLink or GetContainerItemLink

-- {[itemString] = {itemLink=, result={eligible=, reason=, score=}}}
-- Vive solo mientras la ventana de loot actual está abierta.
local lootResults = {}

-- {[rollID] = {itemLink=, result={eligible=, reason=, score=}}}
-- ponytail: nunca se limpia (no escuchamos CANCEL_LOOT_ROLL); no es un
-- problema real de memoria para una sesión de juego — cada entrada es
-- diminuta y una noche de raid no genera miles de tiradas. Añadir limpieza
-- si algún día se vuelve un problema real.
local rollResults = {}

-- {["tipo:índice"] = {itemLink=, result=}} -- recompensas de misión
-- (elegibles y garantizadas) mostradas en la pantalla de aceptar
-- (QUEST_DETAIL) o entregar (QUEST_COMPLETE) una misión. ponytail: nunca se
-- limpia explícitamente; la clave es acotada (unos pocos "choice:N"/
-- "reward:N") y el hook de UI (Fase 6) solo la consulta para los índices
-- que la ventana de Blizzard realmente dibuja para la misión ACTUAL — una
-- entrada vieja de una misión anterior bajo el mismo índice queda huérfana
-- sin causar daño, porque nada la vuelve a leer.
local questResults = {}

-- {[itemString] = {itemLink=, result=}} -- ítems ya en la mochila (no solo
-- loot recién llegado). ponytail: nunca se limpia -- a diferencia de
-- lootResults (que sí se vacía porque una ventana de loot es efímera por
-- diseño), un ítem puede quedarse en la mochila sesiones enteras, así que
-- "limpiar y reanalizar" no ahorraría nada real; la dedupe por itemString
-- ya evita reanalizar lo mismo en cada BAG_UPDATE_DELAYED. Una entrada de
-- un ítem vendido/destruido queda huérfana sin causar daño (nada la vuelve
-- a consultar, igual que con questResults).
local bagResults = {}

-- {["tipo:índice"] = {itemLink=, result=}} -- recompensas de la misión
-- ACTUALMENTE SELECCIONADA en el diario de misiones, sin estar frente al
-- NPC (Fase 9, ampliación tras investigar el gap documentado). Tabla
-- separada de questResults a propósito, no comparten claves: el diario y
-- la pantalla de aceptar/entregar pueden referirse a misiones distintas
-- al mismo tiempo, y mezclarlas arriesgaría mostrar el resultado de una
-- misión en el tooltip de otra.
local questLogResults = {}

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

--- Recorre las recompensas visibles de la misión actual (elegibles vía
--- GetNumQuestChoices/"choice" + garantizadas vía GetNumQuestRewards/
--- "reward") y analiza cada una. Se llama en QUEST_DETAIL (vista previa al
--- aceptar) y QUEST_COMPLETE (al entregar, donde el jugador realmente
--- elige) — ambas pantallas comparten esta misma API de recompensas.
--- Sobrescribe la entrada de un índice solo si el ítem cambió respecto a
--- la última vez (evita reencolar RequestItemStats si el evento se
--- repite para la misma misión, y detecta correctamente cuando el índice
--- pasa a corresponder a otra misión).
local function ScanQuestKind(kind, count)
	for i = 1, count do
		local itemLink = GetQuestItemLink(kind, i)
		if itemLink then
			local key = kind .. ":" .. i
			local existing = questResults[key]
			if not existing or existing.itemLink ~= itemLink then
				AnalyzeAndStore(itemLink, function(result)
					questResults[key] = { itemLink = itemLink, result = result }
				end)
			end
		end
	end
end

local function ScanQuestRewards()
	ScanQuestKind("choice", GetNumQuestChoices())
	ScanQuestKind("reward", GetNumQuestRewards())
end

--- Recorre todos los bolsillos (mochila 0 + bolsas 1..NUM_BAG_SLOTS) y
--- analiza cada ítem nuevo, mismo criterio de dedupe que ScanLootWindow.
--- Se llama en BAG_UPDATE_DELAYED, no en BAG_UPDATE: ese último dispara
--- una vez POR CADA slot que cambia, así que lootear/vender/mover un
--- stack entero dispararía muchos BAG_UPDATE seguidos para la misma
--- acción del jugador — BAG_UPDATE_DELAYED se dispara UNA vez después de
--- que el lote completo se asienta.
local function ScanBags()
	for bag = 0, NUM_BAG_SLOTS do
		for slot = 1, GetContainerNumSlots(bag) do
			local itemLink = GetContainerItemLink(bag, slot)
			if itemLink then
				local itemString = ns.GetItemString(itemLink)
				if itemString and not bagResults[itemString] then
					AnalyzeAndStore(itemLink, function(result)
						bagResults[itemString] = { itemLink = itemLink, result = result }
					end)
				end
			end
		end
	end
end

--[[
Investigación de la limitación de la Fase 9 (recompensas de misión desde
el diario, sin estar frente al NPC): verificado que GetQuestLogItemLink y
GameTooltip:SetQuestLogItem SÍ existen y funcionan igual que
GetQuestItemLink/SetQuestItem — confirmado contra SharpiesGearJudge
(TooltipManager.lua, addon real e instalado en esta máquina), que engancha
exactamente ese par junto al que ya usábamos, con la misma forma
(tipo, índice).

Lo que NO se pudo verificar: el equivalente a GetNumQuestChoices/
GetNumQuestRewards para el diario. Ninguno de los addons reales
instalados (SharpiesGearJudge, LibExtraTip, Auctionator, Scrap, Questie)
llama a una función tipo "GetNumQuestLogChoices/Rewards" sin questID —
Questie es el único que cuenta recompensas de misión, y lo hace con un
questID explícito (GetNumQuestLogRewards(questId)), que resuelve una
misión por ID, no "la seleccionada ahora en el diario" que es lo que acá
hace falta. Portar ese nombre a un conteo implícito sería exactamente el
mismo error que el bug de nombre de stat sin verificar de la Fase 3 (ver
CLAUDE.md) — así que en vez de adivinar el nombre, se itera con un tope
defensivo y se corta en el primer índice sin ítem. GetQuestLogItemLink SÍ
está confirmado, y se asume el mismo comportamiento "nil = no hay más"
que ya tiene su contraparte GetQuestItemLink (mismo autor, mismo patrón,
en SharpiesGearJudge).
]]
local MAX_QUEST_LOG_REWARDS = 10 -- tope defensivo, ninguna misión de TBC se acerca a esto

local function ScanQuestLogKind(kind)
	for i = 1, MAX_QUEST_LOG_REWARDS do
		local itemLink = GetQuestLogItemLink(kind, i)
		if not itemLink then
			break
		end

		local key = kind .. ":" .. i
		local existing = questLogResults[key]
		if not existing or existing.itemLink ~= itemLink then
			AnalyzeAndStore(itemLink, function(result)
				questLogResults[key] = { itemLink = itemLink, result = result }
			end)
		end
	end
end

local function ScanQuestLogRewards()
	ScanQuestLogKind("choice")
	ScanQuestLogKind("reward")
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("LOOT_OPENED")
frame:RegisterEvent("LOOT_CLOSED")
frame:RegisterEvent("START_LOOT_ROLL")
frame:RegisterEvent("CONFIRM_LOOT_ROLL")
frame:RegisterEvent("QUEST_DETAIL")
frame:RegisterEvent("QUEST_COMPLETE")
frame:RegisterEvent("BAG_UPDATE_DELAYED")
frame:RegisterEvent("QUEST_LOG_UPDATE")
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
	elseif event == "QUEST_DETAIL" or event == "QUEST_COMPLETE" then
		ScanQuestRewards()
	elseif event == "BAG_UPDATE_DELAYED" then
		ScanBags()
	elseif event == "QUEST_LOG_UPDATE" then
		ScanQuestLogRewards()
	end
end)

-- Almacenamiento temporal que consume UIIntegration.lua. Se exponen las
-- tablas directamente (se mutan in-place, nunca se reasignan, así que la
-- referencia siempre queda vigente) más helpers de consulta para no tener
-- que conocer el detalle de itemString/clave por fuera.
ns.currentLootResults = lootResults
ns.currentRollResults = rollResults
ns.currentQuestResults = questResults
ns.currentBagResults = bagResults
ns.currentQuestLogResults = questLogResults

function ns.GetLootResult(itemLink)
	local itemString = ns.GetItemString(itemLink)
	return itemString and lootResults[itemString]
end

function ns.GetRollResult(rollID)
	return rollResults[rollID]
end

function ns.GetQuestRewardResult(questItemType, index)
	return questResults[questItemType .. ":" .. index]
end

function ns.GetBagItemResult(itemLink)
	local itemString = ns.GetItemString(itemLink)
	return itemString and bagResults[itemString]
end

function ns.GetQuestLogRewardResult(questItemType, index)
	return questLogResults[questItemType .. ":" .. index]
end
