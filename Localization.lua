local ADDON_NAME, ns = ...

-- Tabla de locale simple, sin dependencia de AceLocale. Clave por defecto en
-- español; añadir bloques `if locale == "..." then` para otros idiomas
-- cuando el addon los necesite, no antes.
local L = {}
ns.L = L

L["ADDON_LOADED"] = "cargado. Rol detectado vía especialización dominante de talentos."

-- Nombres de clase/especialización en español, para la línea de tooltip
-- "Clase Especialización" de UIIntegration.lua (qué build se usó para
-- evaluar el ítem). Mismas traducciones que ya usan los comentarios de
-- SPEC_ROLES en SpecDetector.lua, solo que acá quedan expuestas como
-- datos en vez de comentario, para poder mostrarlas en el tooltip.
L.CLASS_NAMES = {
	WARRIOR = "Guerrero",
	PALADIN = "Paladín",
	HUNTER = "Cazador",
	ROGUE = "Pícaro",
	PRIEST = "Sacerdote",
	SHAMAN = "Chamán",
	MAGE = "Mago",
	WARLOCK = "Brujo",
	DRUID = "Druida",
}

-- [claseToken][índice de árbol de talentos] -> nombre de spec, mismo
-- orden que ns.context.dominantTab (SpecDetector.lua).
L.SPEC_NAMES = {
	WARRIOR = { "Armas", "Furia", "Protección" },
	PALADIN = { "Sagrado", "Protección", "Retribución" },
	HUNTER = { "Bestias", "Puntería", "Supervivencia" },
	ROGUE = { "Asesinato", "Combate", "Sutileza" },
	PRIEST = { "Disciplina", "Sagrado", "Sombras" },
	SHAMAN = { "Elemental", "Mejora", "Restauración" },
	MAGE = { "Arcano", "Fuego", "Escarcha" },
	WARLOCK = { "Aflicción", "Demonología", "Destrucción" },
	DRUID = { "Equilibrio", "Feral", "Restauración" },
}
