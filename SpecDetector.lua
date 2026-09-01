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
   distingue eso con puntos de talento totales solamente — no fuerces un
   5º valor en la fila, añade un paso de desempate aparte en DeriveRole()
   y solo cae al valor de la tabla cuando ese desempate no aplica. Ver
   FERAL_TANK_TALENT_NAME más abajo para el caso ya resuelto (Druida
   Feral, desempate por rank del talento "Thick Hide").
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

--[[
DESEMPATE OSO/GATO (Druida Feral) — resuelve el punto 1 de arriba.
====================================================================
Mismo árbol de talentos (Feral) cubre Oso (Tank) y Gato (Melee); SPEC_ROLES
no puede distinguirlos con puntos totales solamente. Mecanismo real,
verificado contra SharpiesGearJudge (Classes/TBC/Druid.lua, función
`Druid:GetSpec`): NO usa GetShapeshiftForm() (dependería de que el jugador
esté shapeshifteado en el momento exacto de mirar el loot) — usa el rank
del talento "Thick Hide" (supervivencia/mitigación, solo vale invertir en
él si se está especceando para tanquear): 3+ puntos = Oso, menos = Gato.
Confirmado con datos reales de la comunidad (AtlasLootClassic_TBCA_BIS
mantiene listas de BiS separadas "DruidBear"/"DruidCat" — la distinción
importa de verdad, no es un detalle menor).

Nombre en inglés únicamente (mismo límite que AddEquipEffectStats en
ItemStatsAnalyzer.lua — cliente en inglés): en otro idioma este desempate
simplemente no encuentra el talento y el rol queda en "Melee" (el default
de SPEC_ROLES), degradando con gracia en vez de romper.
]]
local FERAL_TANK_TALENT_NAME = "Thick Hide"
local FERAL_TANK_TALENT_RANK_THRESHOLD = 3

-- Recorre las 3 pestañas de talentos y devuelve el índice con más puntos
-- invertidos, junto con la tabla completa de puntos por pestaña.
local function ScanDominantTalentTree()
	local dominantTab, dominantPoints = nil, -1
	local pointsByTab = {}
	local feralTankTalentRank = 0

	-- Bug real encontrado en juego: este cliente ("TBC Anniversary") sí tiene
	-- spec dual (a diferencia del TBC original/2021, que nunca lo tuvo) --
	-- confirmado porque Cell trae un .toc específico para TBC (Cell_TBC.toc)
	-- que carga Core_Vanilla.lua, y ESE archivo llama a GetActiveTalentGroup()
	-- sin condicional (además usa GetNumTalentGroups() == 2 para detectar si
	-- el dual spec está activo). `type(...) == "function"` en vez de asumir
	-- que existe: TBC Classic "normal" (sin spec dual) puede no tener esta
	-- API. Se sigue guardando en ns.context solo para diagnóstico
	-- (/pickitright context/talents) -- ya NO hace falta para leer puntos,
	-- ver el comentario de más abajo.
	local activeGroup = (type(GetActiveTalentGroup) == "function") and GetActiveTalentGroup() or nil

	-- Dos intentos de fix previos, cada uno refutado por el cliente real del
	-- jugador (nivel 63, 10 Arcano / 44 Escarcha reales):
	--   1. GetTalentTabInfo(tab, nil, nil, activeGroup): detectaba bien el
	--      grupo activo pero devolvía 0 puntos en las 3 pestañas.
	--   2. GetNumTalentPoints(tabIndex): dejó de dar 0, pero devolvía el
	--      MISMO total (54 = 10+44) repetido en las 3 pestañas -- ignoraba
	--      el índice de pestaña en este cliente, pese a que
	--      SharpiesGearJudge (Paladin.lua) lo usa asumiendo valores
	--      distintos por pestaña.
	-- Confirmado con /pickitright talents (diagnóstico agregado
	-- específicamente para esto) contra el personaje real: sumar el rank de
	-- cada talento individual vía GetTalentInfo(tab, i) SÍ dio 10/0/44,
	-- exacto. Mismo mecanismo que SharpiesGearJudge usa de verdad para
	-- GetTalentRank (BuildTalentCache en Dynamic_Engine.lua) -- no hace
	-- falta ningún argumento de grupo: GetTalentInfo ya refleja el build
	-- activo por su cuenta.
	for tabIndex = 1, (GetNumTalentTabs() or 0) do
		local pointsSpent = 0
		local numTalents = GetNumTalents(tabIndex) or 0
		for talentIndex = 1, numTalents do
			local name, _, _, _, rank = GetTalentInfo(tabIndex, talentIndex)
			-- tonumber(), no "or 0": la misma clase de dato-no-listo-todavía
			-- que ya se vio con GetTalentTabInfo ("" en vez de número) podría
			-- darse acá también -- mejor no asumir que rank siempre es numérico.
			rank = tonumber(rank) or 0
			pointsSpent = pointsSpent + rank
			if name == FERAL_TANK_TALENT_NAME then
				feralTankTalentRank = rank
			end
		end
		pointsByTab[tabIndex] = pointsSpent
		if pointsSpent > dominantPoints then
			dominantTab, dominantPoints = tabIndex, pointsSpent
		end
	end

	return dominantTab, pointsByTab, activeGroup, feralTankTalentRank
end

-- nil si la clase o el árbol dominante no están en SPEC_ROLES (clase nueva
-- todavía no mapeada, o sin puntos gastados en ningún árbol).
local function DeriveRole(classToken, dominantTab, feralTankTalentRank)
	local roles = SPEC_ROLES[classToken]
	local role = roles and dominantTab and roles[dominantTab] or nil

	-- Desempate Oso/Gato (ver el comentario grande arriba) -- solo aplica
	-- cuando el árbol dominante ya resolvió a "Melee" para un Druida, que
	-- es exactamente (y únicamente) lo que SPEC_ROLES.DRUID[2] (Feral)
	-- devuelve.
	if classToken == "DRUID" and role == "Melee" and (feralTankTalentRank or 0) >= FERAL_TANK_TALENT_RANK_THRESHOLD then
		return "Tank"
	end

	return role
end

-- Única función que escribe ns.context.role — el resto del addon debe
-- leerlo desde ahí (Fase 4 lo usará como filtro), no recalcularlo.
local function RefreshCharacterState()
	local _, classToken = UnitClass("player")
	local _, raceToken = UnitRace("player")
	local dominantTab, pointsByTab, activeGroup, feralTankTalentRank = ScanDominantTalentTree()

	ns.context.class = classToken
	ns.context.race = raceToken
	ns.context.dominantTab = dominantTab
	ns.context.pointsByTab = pointsByTab
	ns.context.activeTalentGroup = activeGroup
	ns.context.role = DeriveRole(classToken, dominantTab, feralTankTalentRank)
end

ns.RefreshCharacterState = RefreshCharacterState

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("CHARACTER_POINTS_CHANGED")
-- Confirmado real (sin guard, registrado siempre) en SharpiesGearJudge
-- (Dynamic_Engine.lua) para el mismo propósito: la data de talentos puede
-- no estar sincronizada todavía en PLAYER_ENTERING_WORLD (mismo problema de
-- fondo que el bug de pointsSpent = "" de arriba), y este evento es la señal
-- real de que ya terminó de llegar del servidor.
frame:RegisterEvent("PLAYER_TALENT_UPDATE")
-- Solo dispara en clientes con spec dual (ver el comentario en
-- ScanDominantTalentTree) -- RegisterEvent con un nombre de evento
-- inexistente en un cliente más viejo es un error duro en WoW, así que
-- primero hay que confirmar que el cliente lo reconoce.
if type(GetNumTalentGroups) == "function" and GetNumTalentGroups() == 2 then
	frame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
end
frame:SetScript("OnEvent", RefreshCharacterState)
