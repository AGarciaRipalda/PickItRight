local ADDON_NAME, ns = ...

--[[
INICIALIZACIÓN SEGURA
======================
El cliente puebla el global PickItRightDB (con los datos guardados, o {} la
primera vez) ANTES de ejecutar los archivos del addon — ver la misma nota
en StatScorer.lua. `or` en cada campo cubre tanto "primera vez" (tabla
vacía) como "SavedVariables de una versión anterior sin este campo
todavía" (ej. si se actualiza el addon), sin arrojar ningún error de Lua
en ninguno de los dos casos.
]]
PickItRightDB = PickItRightDB or {}
PickItRightDB.contentPhase = PickItRightDB.contentPhase or 1
PickItRightDB.enabledModules = PickItRightDB.enabledModules or {}
PickItRightDB.statWeightOverrides = PickItRightDB.statWeightOverrides or {}

-- Módulos que de verdad tiene sentido apagar: los dos que gatillan
-- comportamiento visible (analizar loot, anotar tooltips). Los módulos de
-- plomería interna (SpecDetector, ItemStatsAnalyzer, StatScorer,
-- ItemFilter) no tienen switch propio — apagarlos aislados no tendría
-- ningún efecto observable sin apagar también todo lo que depende de ellos.
local KNOWN_MODULES = {
	LootIntegration = true,
	UIIntegration = true,
}

--- Sin entrada guardada todavía, el módulo está activo por defecto — así
--- una SavedVariables vieja (o recién creada) no apaga nada por omisión.
local function IsModuleEnabled(moduleName)
	local enabled = PickItRightDB.enabledModules[moduleName]
	if enabled == nil then
		return true
	end
	return enabled
end

local function SetModuleEnabled(moduleName, enabled)
	PickItRightDB.enabledModules[moduleName] = enabled
end

ns.IsModuleEnabled = IsModuleEnabled
ns.SetModuleEnabled = SetModuleEnabled

-- Contador que sube en cada cambio de overrides. StatScorer.lua no lo lee
-- directamente; lo consume ItemFilter.lua (Fase 7) como parte de la key
-- del cache de resultados, para que un override tenga efecto inmediato en
-- vez de quedar pegado al valor viejo hasta el próximo cambio de spec/fase.
local overridesVersion = 0

local function GetStatWeightOverrides()
	return PickItRightDB.statWeightOverrides
end

local function SetStatWeightOverride(statKey, weight)
	PickItRightDB.statWeightOverrides[statKey] = weight
	overridesVersion = overridesVersion + 1
end

local function ClearStatWeightOverride(statKey)
	PickItRightDB.statWeightOverrides[statKey] = nil
	overridesVersion = overridesVersion + 1
end

local function GetOverridesVersion()
	return overridesVersion
end

ns.GetStatWeightOverrides = GetStatWeightOverrides
ns.SetStatWeightOverride = SetStatWeightOverride
ns.ClearStatWeightOverride = ClearStatWeightOverride
ns.GetOverridesVersion = GetOverridesVersion

--[[
COMANDOS DE BARRA: /pickitright
=============================
  /pickitright phase [1-5]                     -- ver o fijar la fase de contenido
  /pickitright weight <ITEM_MOD_X> <valor|clear> -- override manual de un peso
  /pickitright module <LootIntegration|UIIntegration> <on|off>

Sin panel gráfico a propósito: el pedido de esta fase acepta "interfaz de
configuración O comandos de barra", y un panel de Interface Options es
trabajo de UI adicional sin requisito funcional nuevo detrás — los
comandos ya cubren leer y escribir todo lo que hay que persistir.
]]
local MIN_PHASE, MAX_PHASE = 1, 5

local function Print(msg)
	print(("|cff33ff99PickItRight|r: %s"):format(msg))
end

local function HandlePhaseCommand(arg)
	if not arg then
		Print(("Fase de contenido activa: %d"):format(ns.GetContentPhase()))
		return
	end

	local phase = tonumber(arg)
	if not phase or phase ~= math.floor(phase) or phase < MIN_PHASE or phase > MAX_PHASE then
		Print(("Uso: /pickitright phase <%d-%d>"):format(MIN_PHASE, MAX_PHASE))
		return
	end

	ns.SetContentPhase(phase)
	Print(("Fase de contenido fijada a %d."):format(phase))
end

local function HandleWeightCommand(statKey, valueArg)
	if not statKey or not valueArg then
		Print("Uso: /pickitright weight <ITEM_MOD_X> <valor|clear>")
		return
	end

	if valueArg == "clear" then
		ns.ClearStatWeightOverride(statKey)
		Print(("Override de %s eliminado."):format(statKey))
		return
	end

	local weight = tonumber(valueArg)
	if not weight then
		Print("El valor debe ser un número, o 'clear' para quitar el override.")
		return
	end

	ns.SetStatWeightOverride(statKey, weight)
	Print(("%s fijado a %.2f para tu build."):format(statKey, weight))
end

local function HandleModuleCommand(moduleName, stateArg)
	if not moduleName or not KNOWN_MODULES[moduleName] or (stateArg ~= "on" and stateArg ~= "off") then
		Print("Uso: /pickitright module <LootIntegration|UIIntegration> <on|off>")
		return
	end

	ns.SetModuleEnabled(moduleName, stateArg == "on")
	Print(("%s %s."):format(moduleName, stateArg == "on" and "activado" or "desactivado"))
end

--[[
COMANDO DE DIAGNÓSTICO: /pickitright inspect <shift-click de un ítem>
=======================================================================
Agregado para depurar un reporte real: un ítem con línea "Equip:" seguía
sin puntuar el bono correspondiente incluso después de dos fixes
distintos en ItemStatsAnalyzer.lua (AddEquipEffectStats), sin forma de
confirmar desde acá si el scanner de tooltip encuentra algo o no en ESE
cliente para ESE ítem puntual. En vez de seguir adivinando causas sin
poder probarlas contra el cliente real, este comando imprime en el chat
los stats crudos de GetItemStats() por un lado, y lo que agrega
AddEquipEffectStats por el otro (vía ns.RequestItemStats, el mismo
camino real que usa el resto del addon) — así se ve a simple vista si el
scanner está detectando algo, y qué score final resulta.
]]
local function HandleInspectCommand(rawMsg)
	local itemLink = rawMsg:match("(item:[%-%d:]+)")
	if not itemLink then
		Print("Uso: /pickitright inspect <shift-click de un ítem sobre esta ventana de chat>")
		return
	end

	local itemName, _, _, _, _, _, _, _, itemEquipLoc, _, _, classID, subclassID = GetItemInfo(itemLink)
	Print(("Inspeccionando: %s"):format(itemName or itemLink))
	-- Agregado tras un reporte real (anillos/collares/trinkets rechazados
	-- con "Tipo de armadura incorrecto", algo que ARMOR_MATERIAL_SLOTS en
	-- ItemFilter.lua no debería producir para esos equipLoc según lectura
	-- estática del código) -- expone los valores CRUDOS de GetItemInfo y el
	-- veredicto real de IsEligible para el ítem puntual, en vez de seguir
	-- adivinando sobre el código sin dato real del cliente.
	Print(("  equipLoc=%s classID=%s subclassID=%s"):format(
		tostring(itemEquipLoc), tostring(classID), tostring(subclassID)))
	if ns.IsEligible then
		local eligible, reason = ns.IsEligible(itemLink, GetItemStats(itemLink) or {})
		Print(("  IsEligible: %s%s"):format(tostring(eligible), reason and (" -- " .. reason) or ""))
	end

	local rawStats = GetItemStats(itemLink) or {}
	local rawKeys = {}
	for statKey in pairs(rawStats) do
		table.insert(rawKeys, statKey)
	end
	table.sort(rawKeys)
	if #rawKeys == 0 then
		Print("  GetItemStats() crudo: (sin stats)")
	else
		for _, statKey in ipairs(rawKeys) do
			Print(("  GetItemStats() crudo: %s = %s"):format(statKey, rawStats[statKey]))
		end
	end

	ns.RequestItemStats(itemLink, function(mergedStats)
		local mergedKeys = {}
		for statKey in pairs(mergedStats) do
			table.insert(mergedKeys, statKey)
		end
		table.sort(mergedKeys)

		local foundEquipBonus = false
		for _, statKey in ipairs(mergedKeys) do
			if rawStats[statKey] ~= mergedStats[statKey] then
				foundEquipBonus = true
				Print(("  + bono de Equip: detectado: %s = %s (crudo tenía %s)"):format(
					statKey, mergedStats[statKey], tostring(rawStats[statKey])))
			end
		end
		if not foundEquipBonus then
			Print("  Ningún bono de Equip: detectado por el scanner de tooltip para este ítem.")
		end

		local weightProfile = ns.GetActiveWeightProfile and ns.GetActiveWeightProfile()
		if not weightProfile then
			Print("  Sin perfil de pesos activo (clase/spec/fase sin datos) -- no se puede calcular score.")
			return
		end

		local currentStats = ns.GetEquippedSnapshot and ns.GetEquippedSnapshot()
		local score = ns.ScoreStats(mergedStats, weightProfile, currentStats)
		Print(("  Score final contra tu perfil activo: %.1f"):format(score))
	end)
end

--[[
COMANDO DE DIAGNÓSTICO: /pickitright context
==============================================
Agregado en la misma investigación que /pickitright inspect: los scores
de `inspect` para dos ítems reales no coincidían con la cuenta a mano
usando el perfil de Mago Frost, pero SÍ coincidían exactos usando el
perfil de Mago Arcano — es decir, `ns.context.dominantTab` no era el que
el jugador esperaba. Este comando expone `ns.context` tal cual (clase,
raza, árbol dominante, puntos por árbol, rol) para poder confirmar esto
sin que el jugador tenga que interpretar manualmente cuál pestaña del
panel de talentos es "1", "2" o "3".
]]
local function HandleContextCommand()
	local context = ns.context
	if not context or not context.class then
		Print("Contexto no disponible todavía (¿recién iniciaste sesión? esperá a PLAYER_ENTERING_WORLD).")
		return
	end

	Print(("Clase: %s | Raza: %s | Rol: %s"):format(
		context.class, context.race or "?", context.role or "sin datos"))
	Print(("Árbol de talentos dominante: pestaña %s"):format(tostring(context.dominantTab)))
	Print(("Grupo de spec activo (dual spec): %s"):format(tostring(context.activeTalentGroup)))

	if context.pointsByTab then
		local parts = {}
		for tabIndex, points in pairs(context.pointsByTab) do
			table.insert(parts, ("pestaña %d = %d puntos"):format(tabIndex, points))
		end
		table.sort(parts)
		Print(("Puntos por pestaña: %s"):format(table.concat(parts, ", ")))
	end
end

--[[
COMANDO DE DIAGNÓSTICO: /pickitright talents
==============================================
Agregado tras DOS intentos de fix fallidos para el mismo reporte real
(0/0/0 puntos, después 54/54/54 -- el total real repetido en las 3
pestañas, no dividido) -- en vez de arriesgar un tercer intento a ciegas,
este comando imprime en el chat, pestaña por pestaña, el resultado de
CADA candidato de API que se probó o se consideró:
  - GetTalentTabInfo sin grupo
  - GetTalentTabInfo con el grupo activo como 4º argumento
  - GetNumTalentPoints(tabIndex) (resultó no ser fiable: en el cliente
    real del usuario devolvió el total repetido en las 3 pestañas)
  - la suma de GetTalentInfo(tab, i) por talento individual (el mecanismo
    que SharpiesGearJudge usa de verdad para GetTalentRank, no el que se
    usó por error para esta fase)
Con estos 4 valores lado a lado para un personaje real con distribución
conocida, se puede identificar con certeza cuál API funciona en vez de
seguir adivinando y pedir otro ciclo de reload+captura.
]]
local function HandleTalentsCommand()
	local activeGroup = (type(GetActiveTalentGroup) == "function") and GetActiveTalentGroup() or nil
	Print(("Grupo activo detectado: %s"):format(tostring(activeGroup)))

	for tabIndex = 1, (GetNumTalentTabs() or 0) do
		local _, tabName = GetTalentTabInfo(tabIndex)
		local rawNoGroup = select(3, GetTalentTabInfo(tabIndex))
		local rawWithGroup = select(3, GetTalentTabInfo(tabIndex, nil, nil, activeGroup))
		local numTalentPoints = (type(GetNumTalentPoints) == "function") and GetNumTalentPoints(tabIndex) or "N/A"

		local summed = 0
		local numTalents = (type(GetNumTalents) == "function") and (GetNumTalents(tabIndex) or 0) or 0
		for i = 1, numTalents do
			local _, _, _, _, rank = GetTalentInfo(tabIndex, i)
			summed = summed + (tonumber(rank) or 0)
		end

		Print(("Pestaña %d (%s): sinGrupo=%s conGrupo=%s GetNumTalentPoints=%s sumaTalentos=%d"):format(
			tabIndex, tostring(tabName), tostring(rawNoGroup), tostring(rawWithGroup),
			tostring(numTalentPoints), summed))
	end
end

local function PrintUsage()
	Print("/pickitright phase [1-5] | weight <ITEM_MOD_X> <valor|clear> | module <nombre> <on|off> | inspect <shift-click de un ítem> | context | talents")
end

SLASH_PICKITRIGHT1 = "/pickitright"
SlashCmdList["PICKITRIGHT"] = function(msg)
	local args = {}
	for word in msg:gmatch("%S+") do
		table.insert(args, word)
	end

	local command = args[1]
	if command == "phase" then
		HandlePhaseCommand(args[2])
	elseif command == "weight" then
		HandleWeightCommand(args[2], args[3])
	elseif command == "module" then
		HandleModuleCommand(args[2], args[3])
	elseif command == "inspect" then
		-- Necesita el mensaje SIN partir por palabras: un link de ítem
		-- pegado con shift-click trae espacios adentro de los corchetes
		-- ([Nombre del Objeto]), partirlo por %S+ lo rompería.
		HandleInspectCommand(msg)
	elseif command == "context" then
		HandleContextCommand()
	elseif command == "talents" then
		HandleTalentsCommand()
	else
		PrintUsage()
	end
end
