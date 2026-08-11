-- Prueba de humo standalone (no requiere el cliente de WoW). Ejecutar desde
-- la raíz del repo con cualquier intérprete Lua 5.1:
--   lua5.1 tests/test_SpecDetector.lua

local mockClass, mockPoints, mockActiveGroup, mockPointsByGroup

_G.GetNumTalentTabs = function() return 3 end
-- GetNumTalentPoints es el camino PRIMARIO real (ver SpecDetector.lua) --
-- mockeado por defecto para que todos los check() de abajo lo ejerciten.
_G.GetNumTalentPoints = function(i) return mockPoints[i] end
_G.GetTalentTabInfo = function(i, _, _, group)
	if mockPointsByGroup then
		return "tab", "icon", mockPointsByGroup[group or mockActiveGroup][i]
	end
	return "tab", "icon", mockPoints[i]
end
_G.UnitClass = function() return "mock", mockClass end
_G.UnitRace = function() return "mock", "Human" end
_G.CreateFrame = function() return { RegisterEvent = function() end, SetScript = function() end } end

local ns = {}
assert(loadfile("SpecDetector.lua"))("PickItRight", ns)

local function check(class, points, expectedRole, label)
	mockClass, mockPoints, mockPointsByGroup = class, points, nil
	ns.RefreshCharacterState()
	assert(ns.context.role == expectedRole,
		("%s: esperado %s, obtenido %s"):format(label, expectedRole, tostring(ns.context.role)))
end

check("WARRIOR", { 5, 10, 40 }, "Tank",   "guerrero con protección dominante")
check("WARRIOR", { 40, 10, 5 }, "Melee",  "guerrero con armas dominante")
check("PRIEST",  { 40, 5, 10 }, "Healer", "sacerdote con disciplina dominante")
check("PRIEST",  { 5, 5, 40 },  "Caster", "sacerdote con sombras dominante")
check("MAGE",    { 40, 0, 0 },  "Caster", "mago con arcano dominante")
check("PALADIN", { 40, 0, 0 },  "Healer", "paladín con sagrado dominante")

-- --- Builds híbridas (Fase 9: casos de prueba explícitos) ----------------
-- Feral Druid es la limitación conocida y documentada del plan: un mismo
-- árbol cubre oso (Tank) y gato (Melee), y no hay forma de distinguirlos
-- solo con puntos de talento. Lo que hay que garantizar acá no es "acierta
-- el rol real", sino "resuelve a un valor determinístico sin romper".
check("DRUID", { 40, 5, 3 },  "Caster", "druida con equilibrio dominante")
check("DRUID", { 5, 40, 3 },  "Melee",  "druida feral (oso o gato) resuelve al default documentado")
check("DRUID", { 3, 5, 40 },  "Healer", "druida con restauración dominante")

-- Empate exacto entre dos árboles: ScanDominantTalentTree usa `>` estricto,
-- así que el PRIMER árbol en alcanzar el máximo gana el empate — no es
-- ambiguo ni azaroso, y no debe arrojar error.
check("WARRIOR", { 20, 20, 0 }, "Melee", "empate exacto entre armas y furia: gana el primero (índice más bajo)")

-- Personaje recién creado, sin puntos de talento gastados todavía: no debe
-- devolver nil ni arrojar error, aunque el resultado sea poco significativo.
check("MAGE", { 0, 0, 0 }, "Caster", "sin puntos de talento gastados, resuelve al primer árbol sin error")

-- Bug real encontrado en juego (cliente TBC Anniversary, no simulable con
-- suposiciones): GetTalentTabInfo puede devolver "" (string vacío) en vez
-- de un número para una pestaña que el cliente todavía no calculó al
-- momento de PLAYER_ENTERING_WORLD. "" es verdadero en Lua, así que un
-- simple "or 0" no lo atrapa, y comparar string contra número tira un
-- error duro. tonumber(pointsSpent) or 0 sí lo cubre.
check("MAGE", { "", 40, 5 }, "Caster", "pestaña sin calcular todavía (string vacío) no debe romper ni ganar el empate")

-- Bug real reportado por el jugador (nivel 63, 10 puntos en Arcano, 44 en
-- Escarcha) pero /pickitright context mostraba 0/0/0, incluso después de
-- pasar el grupo activo como 4º argumento a GetTalentTabInfo (ese fix SÍ
-- detectaba bien el grupo activo, pero GetTalentTabInfo seguía devolviendo
-- 0 puntos). Este es el camino de FALLBACK (sin GetNumTalentPoints
-- disponible) -- fuerza a que ns.context.activeTalentGroup exista y se use
-- correctamente como 4º argumento cuando el camino primario no está.
_G.GetNumTalentPoints = nil
mockPointsByGroup = {
	[1] = { 0, 0, 0 },   -- grupo primario: nunca usado, sin puntos
	[2] = { 10, 0, 44 }, -- grupo secundario (activo): Arcano 10, Escarcha 44
}
_G.GetActiveTalentGroup = function() return 2 end
mockClass = "MAGE"
ns.RefreshCharacterState()
assert(ns.context.dominantTab == 3,
	("spec dual (fallback): esperaba pestaña 3 (Escarcha) dominante, obtuvo %s"):format(tostring(ns.context.dominantTab)))
assert(ns.context.pointsByTab[1] == 10 and ns.context.pointsByTab[3] == 44,
	"spec dual (fallback): lee los puntos del grupo activo (2), no del grupo primario vacío")
assert(ns.context.activeTalentGroup == 2,
	"spec dual (fallback): ns.context expone el grupo activo detectado, para diagnóstico (/pickitright context)")
mockPointsByGroup = nil

-- Sin GetActiveTalentGroup en el cliente (TBC Classic "normal", sin spec
-- dual) y también sin GetNumTalentPoints: no debe romper, simplemente pasa
-- nil como talentGroup al camino de fallback.
_G.GetActiveTalentGroup = nil
check("MAGE", { 5, 0, 40 }, "Caster", "cliente sin spec dual ni GetNumTalentPoints sigue funcionando")

-- Bug real de seguimiento: pasar el grupo activo a GetTalentTabInfo detectaba
-- bien el grupo pero seguía leyendo 0 puntos en el cliente real del usuario.
-- GetNumTalentPoints(tabIndex) -- confirmada real y en uso sin argumento de
-- grupo en SharpiesGearJudge -- es el camino PRIMARIO cuando existe, y debe
-- preferirse sobre GetTalentTabInfo aunque ambas estén disponibles.
_G.GetNumTalentPoints = function(i) return mockPoints[i] end
_G.GetTalentTabInfo = function() return "tab", "icon", 0 end -- a propósito "roto": si esto se usara, el test fallaría
check("MAGE", { 10, 0, 44 }, "Caster", "con GetNumTalentPoints disponible, se prefiere sobre GetTalentTabInfo")
assert(ns.context.pointsByTab[3] == 44,
	"GetNumTalentPoints es el camino primario: no debe caer a GetTalentTabInfo (que acá devuelve 0 a propósito)")

print("OK: SpecDetector.lua supera la prueba de humo")
