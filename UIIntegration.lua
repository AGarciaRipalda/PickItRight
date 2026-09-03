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

-- Mismo shim que LootIntegration.lua (ver el comentario ahí): en el
-- cliente TBC Anniversary el global clásico GetContainerItemLink no
-- existe, solo C_Container.GetContainerItemLink.
local GetContainerItemLink = C_Container and C_Container.GetContainerItemLink or GetContainerItemLink

--- Línea de veredicto para un ítem elegible. isUpgrade puede ser true,
--- false, o nil (sin datos de comparación, ver ComputeUpgradeInfo en
--- ItemFilter.lua) — cada caso tiene su propio color y redacción. A pedido
--- explícito: nunca se muestra el número de score, solo el veredicto —
--- `result.score`/`result.equippedScore` siguen calculándose igual (los
--- sigue necesitando ComputeUpgradeInfo para decidir isUpgrade), solo no
--- se imprimen acá.
local function FormatScoreLine(result)
	if result.isUpgrade == true then
		return ("%sEquípatelo%s"):format(COLOR_GREEN, COLOR_RESET)
	elseif result.isUpgrade == false then
		return ("%sNo es mejora%s"):format(COLOR_GRAY, COLOR_RESET)
	else
		return ("%sElegible%s"):format(COLOR_GRAY, COLOR_RESET)
	end
end

ns.FormatScoreLine = FormatScoreLine

--- Color identitario de clase de WoW (hex, sin "|c"/alfa). RAID_CLASS_COLORS
--- es un global real del cliente, indexado por classToken en inglés
--- (r/g/b 0-1) — confirmado en uso de producción contra SharpiesGearJudge
--- (Interface.lua:256, MSC.GetClassColor, mismo fallback dorado para
--- classToken desconocido). No se mantiene una tabla de colores propia:
--- ya existe en el cliente, no hay que reinventarla.
local function GetClassColorHex(classToken)
	local c = (classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]) or { r = 1, g = 0.82, b = 0 }
	return ("%02x%02x%02x"):format(math.floor(c.r * 255), math.floor(c.g * 255), math.floor(c.b * 255))
end

--- Línea "Clase Especialización" (color de clase), agregada ARRIBA del
--- veredicto de mejora — pedido explícito del usuario. Muestra contra qué
--- build se evaluó el ítem, sin depender de que el jugador interprete el
--- panel de talentos o corra /pickitright context a mano: el mismo tipo de
--- desajuste ya causó un bug real documentado (SpecDetector.lua resolvió
--- Arcano en vez de Frost para un Mago, ver AddonSettings.lua/CLAUDE.md) —
--- esta línea lo hace visible en el momento, no solo con un diagnóstico
--- manual. nil si el contexto de personaje (Fase 1) todavía no resolvió.
local function FormatClassSpecLine()
	local context = ns.context
	local class = context and context.class
	local dominantTab = context and context.dominantTab
	local specNames = class and ns.L and ns.L.SPEC_NAMES and ns.L.SPEC_NAMES[class]
	local specName = specNames and specNames[dominantTab]
	if not class or not specName then
		return nil
	end
	local className = (ns.L.CLASS_NAMES and ns.L.CLASS_NAMES[class]) or class
	return ("|cff%s%s %s%s"):format(GetClassColorHex(class), className, specName, COLOR_RESET)
end

ns.FormatClassSpecLine = FormatClassSpecLine

--- Nombre corto en español + en qué situación importa, para el stat que más
--- explica un veredicto "Equípatelo" (ns.result.topStat, calculado en
--- ItemFilter.lua/GetTopContributingStat). No pretende cubrir cada
--- ITEM_MOD_X del juego, solo los que aparecen en algún WEIGHT_PROFILES
--- real (StatScorer.lua) — agregar una fila acá sin peso en ningún perfil
--- no serviría para nada, nunca se elegiría como top stat.
local STAT_CONTEXT = {
	ITEM_MOD_SPELL_CRIT_RATING_SHORT = { "Crítico de Hechizos", "ráfagas de daño más altas" },
	ITEM_MOD_CRIT_RATING_SHORT = { "Crítico", "ráfagas de daño más altas" },
	ITEM_MOD_SPELL_HASTE_RATING_SHORT = { "Celeridad de Hechizos", "más casteos por minuto" },
	ITEM_MOD_HASTE_RATING_SHORT = { "Celeridad", "más golpes por minuto" },
	ITEM_MOD_HIT_SPELL_RATING_SHORT = { "Golpe de Hechizos", "menos fallos contra jefes" },
	ITEM_MOD_HIT_RATING_SHORT = { "Golpe", "menos fallos contra jefes" },
	ITEM_MOD_SPELL_POWER_SHORT = { "Poder con Hechizos", "más daño/curación directo" },
	ITEM_MOD_ATTACK_POWER_SHORT = { "Poder de Ataque", "más daño físico directo" },
	ITEM_MOD_RANGED_ATTACK_POWER_SHORT = { "Poder de Ataque a Distancia", "más daño a distancia" },
	ITEM_MOD_FERAL_ATTACK_POWER_SHORT = { "Poder de Ataque Feral", "más daño en formas feral" },
	ITEM_MOD_SPELL_HEALING_DONE_SHORT = { "Curación", "más sanación directa" },
	ITEM_MOD_MANA_REGENERATION_SHORT = { "Regen. de Maná (Mp5)", "mejor en peleas largas" },
	ITEM_MOD_SPIRIT_SHORT = { "Espíritu", "mejor regeneración fuera de combate" },
	ITEM_MOD_INTELLECT_SHORT = { "Intelecto", "más reserva de maná" },
	ITEM_MOD_STAMINA_SHORT = { "Aguante", "más vida" },
	ITEM_MOD_STRENGTH_SHORT = { "Fuerza", "más daño físico base" },
	ITEM_MOD_AGILITY_SHORT = { "Agilidad", "más daño físico y esquiva" },
	ITEM_MOD_DEFENSE_SKILL_RATING_SHORT = { "Defensa", "más supervivencia como tanque" },
	ITEM_MOD_DODGE_RATING_SHORT = { "Esquiva", "más supervivencia como tanque" },
	ITEM_MOD_PARRY_RATING_SHORT = { "Parada", "más supervivencia como tanque" },
	ITEM_MOD_BLOCK_RATING_SHORT = { "Bloqueo", "más supervivencia como tanque" },
	ITEM_MOD_BLOCK_VALUE_SHORT = { "Valor de Bloqueo", "más supervivencia como tanque" },
	ITEM_MOD_RESILIENCE_RATING_SHORT = { "Resiliencia", "mejor en PvP" },
	ITEM_MOD_ARMOR_SHORT = { "Armadura", "más mitigación física" },
	ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT = { "Penetración de Armadura", "más daño contra objetivos acorazados" },
	ITEM_MOD_FIRE_DAMAGE_SHORT = { "Daño de Fuego", "más daño en esa escuela de hechizos" },
	ITEM_MOD_FROST_DAMAGE_SHORT = { "Daño de Escarcha", "más daño en esa escuela de hechizos" },
	ITEM_MOD_ARCANE_DAMAGE_SHORT = { "Daño Arcano", "más daño en esa escuela de hechizos" },
	ITEM_MOD_NATURE_DAMAGE_SHORT = { "Daño de Naturaleza", "más daño en esa escuela de hechizos" },
	ITEM_MOD_SHADOW_DAMAGE_SHORT = { "Daño de Sombra", "más daño en esa escuela de hechizos" },
}

--- Línea secundaria, solo para "Equípatelo": qué stat explica la mejora y
--- para qué sirve, sin volver a mostrar el número de score (pedido
--- explícito de una fase anterior). nil si no hay topStat o no está
--- mapeado en STAT_CONTEXT -- en ese caso no se agrega segunda línea.
local function FormatContextLine(result)
	if result.isUpgrade ~= true or not result.topStat then
		return nil
	end
	local info = STAT_CONTEXT[result.topStat]
	if not info then
		return nil
	end
	return ("  %sPor: +%s (%s)%s"):format(COLOR_GRAY, info[1], info[2], COLOR_RESET)
end

ns.FormatContextLine = FormatContextLine

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

	local classSpecLine = FormatClassSpecLine()
	if classSpecLine then
		tooltip:AddLine(classSpecLine)
	end

	local result = entry.result
	if not result.eligible then
		tooltip:AddLine(("%s%s%s"):format(COLOR_RED, result.reason, COLOR_RESET))
		return
	end

	tooltip:AddLine(FormatScoreLine(result))

	local contextLine = FormatContextLine(result)
	if contextLine then
		tooltip:AddLine(contextLine)
	end
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
