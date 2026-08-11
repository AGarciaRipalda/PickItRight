-- Prueba de humo standalone (no requiere el cliente de WoW). Ejecutar desde
-- la raíz del repo con cualquier intérprete Lua 5.1:
--   lua5.1 tests/test_SpecDetector.lua

local mockClass, mockPoints

_G.GetNumTalentTabs = function() return 3 end
-- GetTalentInfo(tab, talentIndex) por talento individual es el camino
-- PRIMARIO real (ver SpecDetector.lua) -- se modela cada pestaña como un
-- solo "talento" cuyo rank es el total de puntos de esa pestaña, para poder
-- seguir expresando los casos de prueba como { pestaña1, pestaña2, pestaña3 }.
_G.GetNumTalents = function() return 1 end
_G.GetTalentInfo = function(tabIndex, talentIndex)
	return "Talent", "icon", 1, 1, mockPoints[tabIndex]
end
-- GetTalentTabInfo y GetNumTalentPoints quedaron confirmadas NO fiables en
-- el cliente real del jugador (ver el comentario en SpecDetector.lua) --
-- mockeadas acá devolviendo basura a propósito: si el código volviera a
-- depender de cualquiera de las dos, estos tests lo detectarían.
_G.GetTalentTabInfo = function() return "tab", "icon", 999 end
_G.GetNumTalentPoints = function() return 999 end
_G.UnitClass = function() return "mock", mockClass end
_G.UnitRace = function() return "mock", "Human" end
_G.CreateFrame = function() return { RegisterEvent = function() end, SetScript = function() end } end

local ns = {}
assert(loadfile("SpecDetector.lua"))("PickItRight", ns)

local function check(class, points, expectedRole, label)
	mockClass, mockPoints = class, points
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
-- suposiciones): el rank de un talento puede llegar como "" (string vacío)
-- en vez de un número para una pestaña que el cliente todavía no calculó al
-- momento de PLAYER_ENTERING_WORLD. "" es verdadero en Lua, así que un
-- simple "or 0" no lo atrapa, y comparar string contra número tira un
-- error duro. tonumber(rank) or 0 sí lo cubre.
check("MAGE", { "", 40, 5 }, "Caster", "pestaña sin calcular todavía (string vacío) no debe romper ni ganar el empate")

-- Bug real reportado por el jugador (nivel 63, 10 Arcano / 0 Fuego / 44
-- Escarcha reales): dos fixes previos fallaron -- GetTalentTabInfo con el
-- grupo activo como 4º argumento devolvía 0/0/0, y GetNumTalentPoints(tab)
-- devolvía el mismo total repetido en las 3 pestañas, ignorando el índice.
-- Confirmado con /pickitright talents contra el personaje real: sumar el
-- rank de cada talento individual vía GetTalentInfo SÍ dio 10/0/44 exacto.
-- Este caso reproduce esa distribución real; GetTalentTabInfo/
-- GetNumTalentPoints siguen mockeados devolviendo 999 arriba, así que si el
-- código volviera a usarlos el resultado no daría 10/0/44.
check("MAGE", { 10, 0, 44 }, "Caster", "distribución real reportada: no debe leer de GetTalentTabInfo/GetNumTalentPoints (mockeados en 999)")
assert(ns.context.pointsByTab[1] == 10 and ns.context.pointsByTab[2] == 0 and ns.context.pointsByTab[3] == 44,
	"lee los puntos reales sumando GetTalentInfo por talento, no GetTalentTabInfo/GetNumTalentPoints")
assert(ns.context.dominantTab == 3, "con 44 en Escarcha, la pestaña dominante es la 3")

-- ns.context.activeTalentGroup sigue expuesto para diagnóstico
-- (/pickitright context) aunque ya no se necesite para leer puntos --
-- GetActiveTalentGroup ausente (TBC Classic "normal", sin spec dual) no
-- debe romper nada.
_G.GetActiveTalentGroup = function() return 2 end
ns.RefreshCharacterState()
assert(ns.context.activeTalentGroup == 2, "expone el grupo de spec dual activo para diagnóstico")

_G.GetActiveTalentGroup = nil
check("MAGE", { 10, 0, 44 }, "Caster", "cliente sin spec dual (GetActiveTalentGroup ausente) sigue funcionando")
assert(ns.context.activeTalentGroup == nil, "sin GetActiveTalentGroup, activeTalentGroup queda nil, no rompe")

print("OK: SpecDetector.lua supera la prueba de humo")
