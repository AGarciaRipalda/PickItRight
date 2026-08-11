local ADDON_NAME, ns = ...

ns.context = ns.context or {}

--[[
Mapeo [claseToken][índice de árbol de talentos] -> rol.
Los índices de árbol (1, 2, 3) son fijos por clase y no dependen del idioma
del cliente, así que la clave es el classToken (2do valor de retorno de
UnitClass), nunca el nombre localizado.

Roles: "Tank", "Healer", "Melee", "Caster".
- "Melee" agrupa todo el dps basado en Attack Power, incluido Hunter (va a
  distancia, pero su prioridad de stats es AP como un melee real, no Spell
  Power) — la Fase 3 (pesos de stats) necesita esa distinción, no la de
  "pega cuerpo a cuerpo vs. a distancia".
- "Caster" agrupa el dps basado en Spell Power.

CÓMO EXPANDIR ESTA TABLA:
1. Casos híbridos que un solo árbol no puede resolver (ej. Feral Druid:
   mismo árbol sirve para oso/Tank y gato/Melee). Este detector NO
   distingue eso con puntos de talento solamente — no fuerces un 5º valor
   en la fila, añade un paso de desempate aparte en DeriveRole() (p. ej.
   leer GetShapeshiftForm(), o exponer un override manual del usuario) y
   solo cae al valor de la tabla cuando ese desempate no aplica.
2. Clase o árbol nuevo: añade la fila `CLASE = { rolÁrbol1, rolÁrbol2,
   rolÁrbol3 }` respetando el orden real de pestañas de esa clase en el
   cliente (verificarlo en juego, no asumirlo).
3. Si una prioridad de stats no encaja en estas 4 categorías (ej. un build
   que en cierta fase de contenido se comporta distinto), no agregues una
   5ª categoría aquí: este mapeo es un filtro grueso para la Fase 4, el
   ajuste fino de prioridades vive en el perfil de pesos de la Fase 3.
]]
local SPEC_ROLES = {
	WARRIOR = { "Melee",  "Melee",  "Tank" },   -- Armas, Furia, Protección
	PALADIN = { "Healer", "Tank",   "Melee" },  -- Sagrado, Protección, Retribución
	HUNTER  = { "Melee",  "Melee",  "Melee" },  -- Bestias, Puntería, Supervivencia
	ROGUE   = { "Melee",  "Melee",  "Melee" },  -- Asesinato, Combate, Sutileza
	PRIEST  = { "Healer", "Healer", "Caster" }, -- Disciplina, Sagrado, Sombras
	SHAMAN  = { "Caster", "Melee",  "Healer" }, -- Elemental, Mejora, Restauración
	MAGE    = { "Caster", "Caster", "Caster" }, -- Arcano, Fuego, Escarcha
	WARLOCK = { "Caster", "Caster", "Caster" }, -- Aflicción, Demonología, Destrucción
	DRUID   = { "Caster", "Melee",  "Healer" }, -- Equilibrio, Feral (ver punto 1), Restauración
}

-- Recorre las 3 pestañas de talentos y devuelve el índice con más puntos
-- invertidos, junto con la tabla completa de puntos por pestaña.
local function ScanDominantTalentTree()
	local dominantTab, dominantPoints = nil, -1
	local pointsByTab = {}

	-- Bug real encontrado en juego: este cliente ("TBC Anniversary") sí tiene
	-- spec dual (a diferencia del TBC original/2021, que nunca lo tuvo) --
	-- confirmado porque Cell trae un .toc específico para TBC (Cell_TBC.toc)
	-- que carga Core_Vanilla.lua, y ESE archivo llama a GetActiveTalentGroup()
	-- sin condicional (además usa GetNumTalentGroups() == 2 para detectar si
	-- el dual spec está activo). Sin pasar el 4º argumento (talentGroup) a
	-- GetTalentTabInfo, el cliente devolvía 0 puntos en las 3 pestañas para
	-- un personaje real con 10/44 puntos repartidos, porque el grupo activo
	-- del jugador era el "secundario" (2) y GetTalentTabInfo sin ese
	-- argumento no lo lee. `type(...) == "function"` en vez de asumir que
	-- existe: TBC Classic "normal" (sin spec dual) puede no tener esta API.
	local activeGroup = (type(GetActiveTalentGroup) == "function") and GetActiveTalentGroup() or nil

	for tabIndex = 1, (GetNumTalentTabs() or 0) do
		local _, _, pointsSpent = GetTalentTabInfo(tabIndex, nil, nil, activeGroup)
		-- tonumber(), no "or 0": en el cliente TBC Anniversary, GetTalentTabInfo
		-- puede devolver "" (string vacío) en vez de un número para una pestaña
		-- que el cliente todavía no calculó al momento de PLAYER_ENTERING_WORLD
		-- (bug real encontrado en juego, no en los tests). "" es verdadero en
		-- Lua, así que "pointsSpent or 0" lo dejaba pasar tal cual, y la
		-- comparación de más abajo (número vs string) tiraba un error duro que
		-- abortaba ANTES de escribir nada en ns.context — rompía todo el addon.
		pointsSpent = tonumber(pointsSpent) or 0
		pointsByTab[tabIndex] = pointsSpent
		if pointsSpent > dominantPoints then
			dominantTab, dominantPoints = tabIndex, pointsSpent
		end
	end

	return dominantTab, pointsByTab, activeGroup
end

-- nil si la clase o el árbol dominante no están en SPEC_ROLES (clase nueva
-- todavía no mapeada, o sin puntos gastados en ningún árbol).
local function DeriveRole(classToken, dominantTab)
	local roles = SPEC_ROLES[classToken]
	return roles and dominantTab and roles[dominantTab] or nil
end

-- Única función que escribe ns.context.role — el resto del addon debe
-- leerlo desde ahí (Fase 4 lo usará como filtro), no recalcularlo.
local function RefreshCharacterState()
	local _, classToken = UnitClass("player")
	local _, raceToken = UnitRace("player")
	local dominantTab, pointsByTab, activeGroup = ScanDominantTalentTree()

	ns.context.class = classToken
	ns.context.race = raceToken
	ns.context.dominantTab = dominantTab
	ns.context.pointsByTab = pointsByTab
	ns.context.activeTalentGroup = activeGroup
	ns.context.role = DeriveRole(classToken, dominantTab)
end

ns.RefreshCharacterState = RefreshCharacterState

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("CHARACTER_POINTS_CHANGED")
-- Solo dispara en clientes con spec dual (ver el comentario en
-- ScanDominantTalentTree) -- RegisterEvent con un nombre de evento
-- inexistente en un cliente más viejo es un error duro en WoW, así que
-- primero hay que confirmar que el cliente lo reconoce.
if type(GetNumTalentGroups) == "function" and GetNumTalentGroups() == 2 then
	frame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
end
frame:SetScript("OnEvent", RefreshCharacterState)
