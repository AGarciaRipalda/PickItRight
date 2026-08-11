local ADDON_NAME, ns = ...

--[[
RENDIMIENTO: este archivo NO calcula nada pesado. Todo el trabajo caro
(extracción de stats, scoring, filtro) ya corrió en la Fase 5 cuando se
abrió la ventana de loot o apareció la tirada — aquí solo se lee una
tabla ya resuelta (ns.GetLootResult/ns.GetRollResult, un lookup O(1)) y se
agregan un par de líneas de texto. Pasar el cursor por 20 items en una
ventana de loot de raid no dispara ni una sola llamada a la API de stats:
por diseño, no por una optimización añadida acá.
]]

local COLOR_GREEN = "|cff33ff33"
local COLOR_RED = "|cffff4444"
local COLOR_GRAY = "|cff999999"
local COLOR_RESET = "|r"

--- Línea de score para un ítem elegible. isUpgrade puede ser true, false,
--- o nil (sin datos de comparación, ver ComputeUpgradeInfo en
--- ItemFilter.lua) — cada caso tiene su propio color y redacción.
local function FormatScoreLine(result)
	if result.isUpgrade == true then
		return ("%sMejora: +%.1f%s"):format(COLOR_GREEN, result.score, COLOR_RESET)
	elseif result.isUpgrade == false then
		return ("%sNo es mejora (%.1f vs %.1f equipado)%s"):format(
			COLOR_GRAY, result.score, result.equippedScore, COLOR_RESET)
	else
		return ("%sPuntaje: %.1f%s"):format(COLOR_GRAY, result.score, COLOR_RESET)
	end
end

ns.FormatScoreLine = FormatScoreLine

--- Agrega al tooltip la línea de análisis para `entry` (lo que devuelven
--- ns.GetLootResult/ns.GetRollResult). `entry` puede ser nil si el hover
--- ocurre antes de que la Fase 5 termine de resolver el ítem (hueco async
--- raro, no un error) — se muestra un placeholder liviano en vez de
--- recalcular nada aquí; si el jugador vuelve a pasar el cursor una vez
--- resuelto, ya sale el resultado real.
local function AppendAnalysis(tooltip, entry)
	if not entry then
		tooltip:AddLine(("%sPickItRight: analizando...%s"):format(COLOR_GRAY, COLOR_RESET))
		return
	end

	local result = entry.result
	if not result.eligible then
		tooltip:AddLine(("%s%s%s"):format(COLOR_RED, result.reason, COLOR_RESET))
		return
	end

	tooltip:AddLine(FormatScoreLine(result))
end

ns.AppendAnalysis = AppendAnalysis

-- hooksecurefunc: corre DESPUÉS de que Blizzard ya llenó el tooltip con lo
-- suyo, sin tocar el método original ni arriesgar taint — la forma segura
-- estándar de anexar contenido a un tooltip que no es propio del addon.
-- Fase 8: /pickitright module UIIntegration off apaga la anotación del tooltip
-- sin poder des-hookear SetLootItem/SetLootRollItem en caliente — el
-- chequeo va al principio de cada callback, igual que en LootIntegration.lua.
hooksecurefunc(GameTooltip, "SetLootItem", function(tooltip, slot)
	if not ns.IsModuleEnabled("UIIntegration") then
		return
	end
	local itemLink = GetLootSlotLink(slot)
	if not itemLink then
		return
	end
	AppendAnalysis(tooltip, ns.GetLootResult(itemLink))
	tooltip:Show()
end)

hooksecurefunc(GameTooltip, "SetLootRollItem", function(tooltip, rollID)
	if not ns.IsModuleEnabled("UIIntegration") then
		return
	end
	AppendAnalysis(tooltip, ns.GetRollResult(rollID))
	tooltip:Show()
end)

-- Recompensas de misión: SetQuestItem es el método real que usa el frame
-- de recompensas de Blizzard tanto al aceptar (QUEST_DETAIL) como al
-- entregar (QUEST_COMPLETE) una misión — cada botón de recompensa llama
-- GameTooltip:SetQuestItem(tipo, índice) al mostrar su tooltip.
hooksecurefunc(GameTooltip, "SetQuestItem", function(tooltip, questItemType, index)
	if not ns.IsModuleEnabled("UIIntegration") then
		return
	end
	AppendAnalysis(tooltip, ns.GetQuestRewardResult(questItemType, index))
	tooltip:Show()
end)

-- Ítems de la mochila: SetBagItem es el método real que usa el tooltip de
-- cualquier botón de bolsa. Acá sí hay que resolver el itemLink dentro del
-- hook (a diferencia de SetLootItem, que también lo resuelve, esto es
-- consistente) porque el callback solo recibe bolsa+slot, no el link.
hooksecurefunc(GameTooltip, "SetBagItem", function(tooltip, bag, slot)
	if not ns.IsModuleEnabled("UIIntegration") then
		return
	end
	local itemLink = GetContainerItemLink(bag, slot)
	if not itemLink then
		return
	end
	AppendAnalysis(tooltip, ns.GetBagItemResult(itemLink))
	tooltip:Show()
end)

-- Recompensas de misión desde el DIARIO, sin estar frente al NPC (Fase 9,
-- ampliación tras investigar el gap que quedaba documentado acá).
-- GetQuestLogItemLink/SetQuestLogItem confirmados contra SharpiesGearJudge
-- (TooltipManager.lua, addon real instalado): engancha exactamente este
-- par junto a SetQuestItem/GetQuestItemLink, con la misma forma.
-- `if GameTooltip.SetQuestLogItem then` es el mismo guard defensivo que
-- usa esa fuente — a diferencia de los otros hooks de este archivo (que no
-- lo tienen), hooksecurefunc sobre un método inexistente rompería la carga
-- del resto de este archivo, y no hay garantía local de que este método en
-- particular exista en toda variante de cliente TBC.
if GameTooltip.SetQuestLogItem then
	hooksecurefunc(GameTooltip, "SetQuestLogItem", function(tooltip, questItemType, index)
		if not ns.IsModuleEnabled("UIIntegration") then
			return
		end
		AppendAnalysis(tooltip, ns.GetQuestLogRewardResult(questItemType, index))
		tooltip:Show()
	end)
end
