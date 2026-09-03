local ADDON_NAME, ns = ...

-- Declarada en el .toc como `## SavedVariables: PickItRightDB`. El cliente
-- puebla este global (con los datos guardados, o {} la primera vez) ANTES
-- de ejecutar los archivos del addon — ADDON_LOADED es solo la señal, no
-- el momento en que la tabla empieza a existir — así que este patrón al
-- nivel superior del archivo es seguro y no necesita esperar ese evento.
PickItRightDB = PickItRightDB or {}

local DEFAULT_PHASE = 1

--- Fase de contenido activa (1 = Kara/Gruul/Mag, 2 = SSC/TK, ...). No hay
--- forma de detectar esto automáticamente (ver CLAUDE.md, Fase 8) — lo fija
--- el usuario a mano y persiste entre sesiones vía SavedVariables.
local function GetContentPhase()
	return PickItRightDB.contentPhase or DEFAULT_PHASE
end

local function SetContentPhase(phase)
	PickItRightDB.contentPhase = phase
end

ns.GetContentPhase = GetContentPhase
ns.SetContentPhase = SetContentPhase

--[[
CAPS NO LINEALES
================
Algunos stats no valen nada (o valen menos) una vez que el personaje ya
alcanzó cierto umbral — el Golpe de Hechizos por encima del 16% no evita
ningún fallo adicional, es puro desperdicio. Modelarlos como un peso lineal
constante sobrevaloraría un item que solo aporta golpe a alguien que ya está
capeado.

Para añadir un cap nuevo (Defensa, Expertise en fases futuras, límite de
Resistencia por encantamiento, etc.) solo hace falta una fila más en
CAP_RULES con esta forma — EvaluateCappedValue ya sabe aplicar cualquier
regla que la tenga, no hay que tocar la lógica de scoring.

  statKey = {
    cap = <valor del stat en el que deja de aportar>,
    pastCapMultiplier = <0 = no vale nada por encima del cap;
                          0 < x < 1 = "cap blando", sigue aportando algo>,
  }
]]
local CAP_RULES = {
	-- TBC: 202 de Golpe de Hechizos ≈ 16% contra un jefe de nivel 73.
	-- Verificado cruzando con SharpiesGearJudge (addon de gear-scoring TBC
	-- real, instalado localmente): su tabla SAFETY_CAPS usa el mismo
	-- ITEM_MOD_HIT_SPELL_RATING_SHORT base=202 para las 5 clases con
	-- hechizos. No es una segunda fuente independiente de theorycrafting,
	-- pero reemplaza la cifra de memoria sin verificar por una que otro
	-- addon de producción ya usa contra este mismo cliente.
	ITEM_MOD_HIT_SPELL_RATING_SHORT = { cap = 202, pastCapMultiplier = 0 },

	-- TODO(Fase 4/tank): Defensa (490 = inmune a golpes aplastantes, 535 =
	-- inmune a críticos). El valor 490 aparece igual en el SAFETY_CAPS de
	-- SharpiesGearJudge (DEFENSE_FLOOR base=490) — corroborado de paso,
	-- aunque no lo buscábamos. 535 (inmune a críticos) sigue sin verificar.
	-- No inventar la conversión rating->skill sin una fuente real; añadir
	-- cuando exista un perfil de Tank que la use.
}

--- Cuánto de `itemValue` (lo que APORTA el item de ese stat) cuenta de
--- verdad, dado que el personaje ya tiene `currentValue` de ese stat sin
--- contar el item evaluado. Sin regla de cap conocida, vale su valor
--- completo (comportamiento lineal de siempre).
local function EvaluateCappedValue(statKey, itemValue, currentValue)
	local rule = CAP_RULES[statKey]
	if not rule then
		return itemValue
	end

	currentValue = currentValue or 0
	if currentValue >= rule.cap then
		return itemValue * rule.pastCapMultiplier
	end

	local roomBeforeCap = rule.cap - currentValue
	if itemValue <= roomBeforeCap then
		return itemValue
	end

	local overCap = itemValue - roomBeforeCap
	return roomBeforeCap + (overCap * rule.pastCapMultiplier)
end

ns.EvaluateCappedValue = EvaluateCappedValue

--[[
BASE DE DATOS DE PESOS
=======================
[claseToken][nombreSpec][fase] -> {ITEM_MOD_X = peso}.

Un peso ausente para un stat significa "ignorar ese stat", no "vale 0 y
resta" — el descarte activo de stats irrelevantes al rol (ej. Espíritu en
un dps físico) es trabajo de la Fase 4 (filtro estricto), no de este
scorer.

FUENTE: SharpiesGearJudge (gear-scoring TBC real, instalado localmente),
archivo `Classes/TBC/<Clase>.lua` por clase, tabla `Weights` keyed por
spec. Mismo diseño que el nuestro (tabla explícita ITEM_MOD_X -> peso,
estilo Pawn), así que la traducción es directa. Reglas de curación
aplicadas a TODAS las filas de abajo, no copiadas en bloque:
  1. Se descarta `MSC_WEAPON_SPEED` (cálculo propio de ese addon, no una
     clave de GetItemStats) pero su valor de `MSC_WEAPON_DPS` SÍ se porta
     — apuntado a `ITEM_MOD_DAMAGE_PER_SECOND_SHORT`, la clave real que
     GetItemStats() expone para el DPS del arma (confirmada con
     `/pickitright inspect` contra un ítem real). Bug real reportado por
     un Paladín tanque: sin esta clave, el DPS del arma puntuaba 0 pase lo
     que pase, así que un arma con menos daño por segundo (pero algún
     stat secundario mayor) podía salir "Equípatelo" ignorando por
     completo que pegaba más flojo. El VALOR de peso de `MSC_WEAPON_DPS`
     se reusa tal cual para la clave real: aunque el cálculo de origen de
     ese número sea propio de SharpiesGearJudge, representa la misma
     idea ("cuánto vale 1 punto de DPS de arma para esta spec"), y aplica
     igual de bien al DPS real del arma. Perfiles donde el peso de
     MSC_WEAPON_DPS era 0.0 en la fuente (Sacerdote, Brujo, Druida) se
     dejaron sin la clave — agregar un peso 0.0 no cambia nada, es ruido.
  2. **Supuesto revertido, confirmado equivocado:** se excluía
     `ITEM_MOD_EXPERTISE_RATING_SHORT` de todas las filas asumiendo que
     Pericia era un stat de WotLK sin existencia real en TBC. Refutado con
     evidencia real, no solo de una guía externa: `Helpers.lua` de
     SharpiesGearJudge lee el rating EN VIVO vía `GetCombatRating(24)`
     (una llamada real a la API del personaje, no un valor teórico), y
     varias filas de este mismo archivo fuente traen el comentario
     explícito `-- Added TBC Stat` junto al peso de Expertise — es decir,
     el propio autor de la fuente que ya usamos para todo lo demás
     documentó que SÍ es un stat real de TBC, y el peso simplemente se
     venía descartando acá por error, sin volver a verificar el supuesto.
     Restaurado en las 8 filas donde la fuente lo pesa (`ITEM_MOD_ARMOR_SHORT`
     de Paladín Protección es la excepción notable: esa fila específica NO
     tiene Expertise en la fuente, no se agregó ahí).
  3. Se descarta lo agrupado bajo sus comentarios "TRACE VALUES" /
     "POISON PROTECTION" / "ZERO VALUES" — son parches del motor de ESE
     addon para neutralizar un efecto secundario propio de su scoring
     (evitar que unificar todos los stats en una sola pasada penalice un
     ítem por tener un stat sin peso). Nuestro ScoreStats ya ignora
     cualquier stat ausente del perfil sin necesidad de esto.
  4. Corregido en el perfil de Mago Fuego (el único que ya existía antes
     de esta fuente): `ITEM_MOD_CRIT_SPELL_RATING_SHORT`/
     `ITEM_MOD_HASTE_SPELL_RATING_SHORT` NO son los nombres reales del
     stat — son `ITEM_MOD_SPELL_CRIT_RATING_SHORT`/
     `ITEM_MOD_SPELL_HASTE_RATING_SHORT` (orden de palabras invertido).
     Confirmado contra 6 archivos de clase distintos que coinciden en el
     mismo orden — no es casualidad de uno solo. Con el nombre viejo,
     esos dos pesos nunca hicieron nada: GetItemStats jamás iba a
     devolver una clave que no existe.
  5. Cuando la clase tiene `EndgameTabMap` en su fuente (Guerrero,
     Paladín, Druida, Chamán), se usó exactamente esa variante por
     pestaña de talentos — es la propia elección del autor entre varios
     sub-perfiles de una misma spec (ej. Furia dual-wield vs Furia a dos
     manos). Sin `EndgameTabMap` (Sacerdote, Pícaro, Cazador, Brujo,
     Mago), se infirió la variante PvE/raid más estándar; queda anotado
     por fila cuál se eligió y por qué.
  6. Ninguna fila está diferenciada por fase de contenido en la fuente
     (SharpiesGearJudge no versiona por fase) — todo se cargó bajo la
     fase 1 por ahora. Fases 2+ seguirían necesitando su propia fuente.

Para añadir una clase/spec nueva o revisar una de estas:
1. Agregar/corregir la fila de pesos aquí, con una fuente real (no un
   número al azar).
2. Agregar la entrada correspondiente en SPEC_NAMES más abajo, con el
   mismo índice de árbol de talentos que usa SpecDetector.lua.
]]
--[[
ÚNICA EXCEPCIÓN A "todo cargado bajo la Fase 1" (punto 6 arriba):
Icy Veins (rogue-dps-pve-stat-priority) es la única guía de las 27
combinaciones clase/spec revisadas que da una tabla numérica real de
pesos POR FASE de contenido ("EP Weights by Tier": Pre-Raid/T4/T5/T6/
Sunwell) -- todas las demás solo dan orden cualitativo sin números, o
remiten a Wowsims (simulador interactivo, no una página con datos para
portar). Investigado a pedido del usuario ("y no lo podrias deducir
viendo los stats de la tier list de tbca bis...?" -- se descartó esa vía:
Atlas solo tiene item IDs sin stats, y el ranking ya mezcla procs/bonos
de set con stats crudos, así que "deducir" pesos del orden terminaría
inventando un número con apariencia de dato real).

La tabla de Icy Veins NO distingue Asesinato/Combate/Sutileza -- es
"Rogue DPS" genérico, cita textual: "These EP weights are a general
sense of how each stat scales. These are assuming you are at an average
gear level in each tier." Por eso, a diferencia de la Fase 1 (donde cada
spec tiene su propia fila sourced de SharpiesGearJudge), las 3 specs
comparten estas mismas tablas para Fases 2-5 -- es exactamente lo que la
fuente real ofrece, no una simplificación nuestra.

Mapeo fase de contenido -> columna de la fuente (ver GetContentPhase en
este mismo archivo: 1=Kara/Gruul/Mag, 2=SSC/TK, 3=BT/Hyjal, 4=ZA,
5=Sunwell): T4->Fase 1 (ya cubierta con datos propios de SharpiesGearJudge,
no se pisa), T5->Fase 2, T6->Fase 3 Y Fase 4 (Zul'Aman no agrega una
itemización de tier nueva en la fuente, comparte T6), Sunwell->Fase 5.
"Pre-Raid" no mapea a ninguna fase nuestra (todas parten de raideo), se
descarta.

No incluye ITEM_MOD_DAMAGE_PER_SECOND_SHORT (peso de DPS de arma): la
fuente no lo cubre, y agregar un número inventado sería exactamente lo
que se evitó al descartar la inferencia desde Atlas -- un stat ausente
del perfil simplemente se ignora al puntuar (ver el comentario grande de
BASE DE DATOS DE PESOS más abajo), no rompe nada.
]]
local ROGUE_GENERIC_T5 = { -- Fase 2 (SSC/TK)
	ITEM_MOD_EXPERTISE_RATING_SHORT = 2.65,
	ITEM_MOD_HIT_RATING_SHORT = 2.42,
	ITEM_MOD_AGILITY_SHORT = 2.19,
	ITEM_MOD_CRIT_RATING_SHORT = 1.72,
	ITEM_MOD_HASTE_RATING_SHORT = 2.13,
	ITEM_MOD_STRENGTH_SHORT = 1.1,
	ITEM_MOD_ATTACK_POWER_SHORT = 1.0,
	ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT = 0.30,
}
local ROGUE_GENERIC_T6 = { -- Fases 3 y 4 (BT/Hyjal, ZA)
	ITEM_MOD_EXPERTISE_RATING_SHORT = 2.66,
	ITEM_MOD_HIT_RATING_SHORT = 2.44,
	ITEM_MOD_AGILITY_SHORT = 2.21,
	ITEM_MOD_CRIT_RATING_SHORT = 1.76,
	ITEM_MOD_HASTE_RATING_SHORT = 2.29,
	ITEM_MOD_STRENGTH_SHORT = 1.1,
	ITEM_MOD_ATTACK_POWER_SHORT = 1.0,
	ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT = 0.34,
}
local ROGUE_GENERIC_SUNWELL = { -- Fase 5 (Sunwell Plateau)
	ITEM_MOD_EXPERTISE_RATING_SHORT = 2.93,
	ITEM_MOD_HIT_RATING_SHORT = 2.71,
	ITEM_MOD_AGILITY_SHORT = 2.31,
	ITEM_MOD_CRIT_RATING_SHORT = 1.92,
	ITEM_MOD_HASTE_RATING_SHORT = 2.24,
	ITEM_MOD_STRENGTH_SHORT = 1.1,
	ITEM_MOD_ATTACK_POWER_SHORT = 1.0,
	ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT = 0.38,
}

local WEIGHT_PROFILES = {
	MAGE = {
		Arcane = {
			[1] = { -- ARCANE_RAID: mana battery/burst. Sin cap explícito propio.
				ITEM_MOD_INTELLECT_SHORT = 1.2,
				ITEM_MOD_SPELL_POWER_SHORT = 1.0,
				ITEM_MOD_ARCANE_DAMAGE_SHORT = 1.0,
				ITEM_MOD_HIT_SPELL_RATING_SHORT = 1.3,
				ITEM_MOD_SPELL_CRIT_RATING_SHORT = 0.7,
				ITEM_MOD_SPELL_HASTE_RATING_SHORT = 0.9,
				ITEM_MOD_SPIRIT_SHORT = 0.6, -- Arcane Meditation
				ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 0.02,
			},
		},
		Fire = {
			[1] = { -- FIRE_RAID. Corregido: faltaba Fire Damage y Spirit; crítico/celeridad
				-- tenían el nombre de stat al revés (ver punto 4 arriba) y el valor viejo.
				ITEM_MOD_SPELL_POWER_SHORT = 1.0,
				ITEM_MOD_HIT_SPELL_RATING_SHORT = 1.3, -- alto valor hasta el cap, ver CAP_RULES
				ITEM_MOD_FIRE_DAMAGE_SHORT = 1.0,
				-- Celeridad reordenada por encima de Crítico contra Icy Veins
				-- (fire-mage-dps-pve-stat-priority: Golpe > Daño > Celeridad >
				-- Crítico).
				ITEM_MOD_SPELL_HASTE_RATING_SHORT = 1.0,
				ITEM_MOD_SPELL_CRIT_RATING_SHORT = 0.95, -- Ignite
				ITEM_MOD_INTELLECT_SHORT = 0.4,
				ITEM_MOD_SPIRIT_SHORT = 0.1,
				ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 0.02,
			},
		},
		Frost = {
			[1] = { -- FROST_PVE ("safe dps"), no FROST_AOE ni FROST_PVP.
				ITEM_MOD_HIT_SPELL_RATING_SHORT = 1.3,
				ITEM_MOD_FROST_DAMAGE_SHORT = 1.0,
				ITEM_MOD_SPELL_POWER_SHORT = 1.0,
				ITEM_MOD_SPELL_CRIT_RATING_SHORT = 0.6,
				ITEM_MOD_SPELL_HASTE_RATING_SHORT = 0.8,
				ITEM_MOD_INTELLECT_SHORT = 0.5,
				ITEM_MOD_SPIRIT_SHORT = 0.1,
				ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 0.02,
			},
		},
	},
	WARRIOR = {
		Arms = {
			[1] = { -- EndgameTabMap: ARMS_PVE. Golpe reordenado por encima de
				-- Fuerza contra Icy Veins (arms-warrior-dps-pve-stat-priority:
				-- Golpe > Expertise > Crítico > Penetración > Fuerza/Ataque).
				-- Expertise restaurada (ver el punto 2 de la cabecera de
				-- WEIGHT_PROFILES) con el valor real de la fuente.
				ITEM_MOD_HIT_RATING_SHORT = 2.4,
				ITEM_MOD_EXPERTISE_RATING_SHORT = 2.0,
				ITEM_MOD_STRENGTH_SHORT = 2.3,
				ITEM_MOD_CRIT_RATING_SHORT = 1.5,
				ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT = 0.4,
				ITEM_MOD_ATTACK_POWER_SHORT = 1.0,
				ITEM_MOD_HASTE_RATING_SHORT = 1.1,
				ITEM_MOD_AGILITY_SHORT = 1.4,
				ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 5.0,
			},
		},
		Fury = {
			[1] = { -- EndgameTabMap: FURY_DW (dual-wield). También existe FURY_2H en
				-- la fuente. Golpe reordenado por encima de Fuerza, y Crítico por
				-- encima de Agilidad, contra Icy Veins (fury-warrior-dps-pve-stat-
				-- priority: Golpe > Expertise > Crítico > Penetración >
				-- Fuerza/Ataque > Agilidad > Celeridad). Expertise restaurada
				-- (ver punto 2 de la cabecera de WEIGHT_PROFILES) con el valor
				-- real de la fuente.
				ITEM_MOD_HIT_RATING_SHORT = 2.3,
				ITEM_MOD_EXPERTISE_RATING_SHORT = 2.2,
				ITEM_MOD_STRENGTH_SHORT = 2.2,
				ITEM_MOD_ATTACK_POWER_SHORT = 1.0,
				ITEM_MOD_CRIT_RATING_SHORT = 1.6,
				ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT = 0.35,
				ITEM_MOD_HASTE_RATING_SHORT = 1.3,
				ITEM_MOD_AGILITY_SHORT = 1.5,
				ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 6.0,
			},
		},
		Protection = {
			[1] = { -- EndgameTabMap: DEEP_PROT. Expertise restaurada (ver punto 2
				-- de la cabecera de WEIGHT_PROFILES) con el valor real de la
				-- fuente. Reordenado contra Icy Veins (protection-warrior-tank-
				-- pve-stat-priority: Aguante > Armadura > Defensa > Resiliencia >
				-- Agilidad > Esquiva > Parada > Valor de Bloqueo) -- la fuente NO
				-- pesa Armadura en esta fila (solo en bloques de leveling, que no
				-- se mezclan acá); se reusa el valor de Paladín Protección (0.12,
				-- misma fuente, mismo concepto "tanque de placas") por analogía,
				-- no como número inventado desde cero. Aguante y Agilidad subidos
				-- para respetar el orden de la guía.
				ITEM_MOD_STAMINA_SHORT = 2.5,
				ITEM_MOD_ARMOR_SHORT = 0.12,
				ITEM_MOD_DEFENSE_SKILL_RATING_SHORT = 2.4,
				ITEM_MOD_BLOCK_VALUE_SHORT = 0.7,
				ITEM_MOD_DODGE_RATING_SHORT = 1.0,
				ITEM_MOD_PARRY_RATING_SHORT = 1.0,
				ITEM_MOD_BLOCK_RATING_SHORT = 0.9,
				ITEM_MOD_HIT_RATING_SHORT = 0.6,
				ITEM_MOD_EXPERTISE_RATING_SHORT = 1.0,
				ITEM_MOD_RESILIENCE_RATING_SHORT = 0.8,
				ITEM_MOD_STRENGTH_SHORT = 0.6,
				ITEM_MOD_AGILITY_SHORT = 1.05,
				ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 1.5,
			},
		},
	},
	PALADIN = {
		Holy = {
			[1] = { -- EndgameTabMap: HOLY_RAID. Reordenado contra Icy Veins
				-- (holy-paladin-healer-pve-stat-priority: Poder de Curación >
				-- Mp5 > Crítico > Intelecto > Celeridad) -- la fuente (comentario
				-- propio "INTELLECT, The Stat King in 2.5.5") está tuneada para
				-- el meta tardío de Sunwell, donde Intelecto supera a Curación;
				-- para Fase 1 se prioriza la curación directa primero, siguiendo
				-- la guía general en vez de ese meta específico.
				ITEM_MOD_INTELLECT_SHORT = 1.5,
				ITEM_MOD_SPELL_HEALING_DONE_SHORT = 2.2,
				ITEM_MOD_SPELL_POWER_SHORT = 2.1,
				ITEM_MOD_SPELL_HASTE_RATING_SHORT = 1.1,
				ITEM_MOD_SPELL_CRIT_RATING_SHORT = 1.8,
				ITEM_MOD_MANA_REGENERATION_SHORT = 2.0,
				ITEM_MOD_STAMINA_SHORT = 0.2,
				ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 0.02,
			},
		},
		Protection = {
			[1] = { -- EndgameTabMap: PROT_DEEP. Orden de Bloqueo/Esquiva/Parada y
				-- Poder con Hechizos/Golpe ajustado contra Icy Veins (guía TBC
				-- Classic, revisada para TBC Anniversary) -- ver el comentario de
				-- cabecera de WEIGHT_PROFILES.
				ITEM_MOD_DEFENSE_SKILL_RATING_SHORT = 2.4,
				ITEM_MOD_BLOCK_RATING_SHORT = 2.1,
				ITEM_MOD_DODGE_RATING_SHORT = 2.0,
				ITEM_MOD_PARRY_RATING_SHORT = 1.9,
				ITEM_MOD_STAMINA_SHORT = 1.6,
				ITEM_MOD_ARMOR_SHORT = 0.12,
				ITEM_MOD_RESILIENCE_RATING_SHORT = 0.8,
				ITEM_MOD_SPELL_POWER_SHORT = 0.8,
				ITEM_MOD_HIT_SPELL_RATING_SHORT = 0.75,
				ITEM_MOD_HIT_RATING_SHORT = 0.6,
				ITEM_MOD_BLOCK_VALUE_SHORT = 0.35,
				ITEM_MOD_STRENGTH_SHORT = 0.1,
				ITEM_MOD_AGILITY_SHORT = 0.6,
				ITEM_MOD_INTELLECT_SHORT = 0.1,
				ITEM_MOD_MANA_REGENERATION_SHORT = 0.2,
				ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 0.2,
			},
		},
		Retribution = {
			[1] = { -- EndgameTabMap: RET_STANDARD. Golpe reordenado por encima de
				-- Fuerza, y Crítico bajado por debajo de Celeridad, contra Icy
				-- Veins (retribution-paladin-dps-pve-stat-priority: Golpe >
				-- Expertise > Fuerza > Ataque > Celeridad > Penetración >
				-- Agilidad/Crítico, este último al final). Expertise restaurada
				-- (ver punto 2 de la cabecera de WEIGHT_PROFILES) con el valor
				-- real de la fuente.
				ITEM_MOD_HIT_RATING_SHORT = 2.5,
				ITEM_MOD_EXPERTISE_RATING_SHORT = 2.2,
				ITEM_MOD_STRENGTH_SHORT = 2.4,
				ITEM_MOD_CRIT_RATING_SHORT = 1.3,
				ITEM_MOD_STAMINA_SHORT = 1.5,
				ITEM_MOD_AGILITY_SHORT = 1.4,
				ITEM_MOD_HASTE_RATING_SHORT = 1.5,
				ITEM_MOD_ATTACK_POWER_SHORT = 1.0,
				ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT = 0.4,
				ITEM_MOD_INTELLECT_SHORT = 0.05,
				ITEM_MOD_SPELL_POWER_SHORT = 0.1,
				ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 7.5,
			},
		},
	},
	HUNTER = {
		BeastMastery = {
			[1] = { -- Sin EndgameTabMap en la fuente; inferido: RAID_BM (variante
				-- PvE estándar). Reordenado contra Icy Veins
				-- (beast-mastery-hunter-dps-pve-stat-priority: Golpe >
				-- Penetración > Agilidad > Ataque > Crítico) -- la fuente tenía
				-- Penetración como el peso más bajo, muy por debajo de
				-- Agilidad/Golpe/Crítico, al revés de la guía. Ataque también
				-- subido por encima de Crítico.
				ITEM_MOD_HIT_RATING_SHORT = 2.0,
				ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT = 1.95,
				ITEM_MOD_AGILITY_SHORT = 1.9,
				ITEM_MOD_ATTACK_POWER_SHORT = 1.35,
				ITEM_MOD_RANGED_ATTACK_POWER_SHORT = 1.35,
				ITEM_MOD_CRIT_RATING_SHORT = 1.3,
				ITEM_MOD_HASTE_RATING_SHORT = 1.2,
				ITEM_MOD_INTELLECT_SHORT = 0.4,
				ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 12.0,
			},
		},
		Marksmanship = {
			[1] = { -- Inferido: RAID_MM. Mismo reordenamiento que BM contra Icy
				-- Veins (marksmanship-hunter-dps-pve-stat-priority: Golpe >
				-- Penetración > Agilidad > Ataque > Crítico) -- Agilidad estaba
				-- por encima de Golpe, al revés de la guía.
				ITEM_MOD_HIT_RATING_SHORT = 2.3,
				ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT = 2.25,
				ITEM_MOD_AGILITY_SHORT = 2.2,
				ITEM_MOD_ATTACK_POWER_SHORT = 1.35,
				ITEM_MOD_RANGED_ATTACK_POWER_SHORT = 1.35,
				ITEM_MOD_CRIT_RATING_SHORT = 1.3,
				ITEM_MOD_INTELLECT_SHORT = 0.5,
				ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 13.0,
			},
		},
		Survival = {
			[1] = { -- Inferido: RAID_SURV. Reordenado contra Icy Veins
				-- (survival-hunter-dps-pve-stat-priority: Agilidad > Crítico >
				-- Golpe (tope muy bajo, 2%, por Pies Firmes) > Penetración >
				-- Ataque) -- Golpe estaba por encima de Crítico (correcto para
				-- BM/MM, pero no para Superviviente, cuyo tope de Golpe es
				-- trivial) y Penetración por debajo de Ataque, ambos al revés.
				ITEM_MOD_AGILITY_SHORT = 3.0, -- Expose Weakness
				ITEM_MOD_CRIT_RATING_SHORT = 2.0,
				ITEM_MOD_HIT_RATING_SHORT = 1.5,
				ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT = 0.7,
				ITEM_MOD_ATTACK_POWER_SHORT = 0.6,
				ITEM_MOD_RANGED_ATTACK_POWER_SHORT = 0.6,
				ITEM_MOD_INTELLECT_SHORT = 0.6, -- Thrill of the Hunt
				ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 10.0,
			},
		},
	},
	ROGUE = {
		Assassination = {
			[1] = { -- Inferido: RAID_MUTILATE. Expertise restaurada (ver punto 2
				-- de la cabecera de WEIGHT_PROFILES) con el valor real de la
				-- fuente.
				ITEM_MOD_CRIT_RATING_SHORT = 1.6, -- Seal Fate
				ITEM_MOD_AGILITY_SHORT = 2.1,
				ITEM_MOD_HIT_RATING_SHORT = 1.7,
				ITEM_MOD_EXPERTISE_RATING_SHORT = 1.8,
				ITEM_MOD_ATTACK_POWER_SHORT = 1.0,
				ITEM_MOD_HASTE_RATING_SHORT = 1.2,
				ITEM_MOD_STRENGTH_SHORT = 1.0,
				ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 5.0,
			},
			[2] = ROGUE_GENERIC_T5, [3] = ROGUE_GENERIC_T6, [4] = ROGUE_GENERIC_T6, [5] = ROGUE_GENERIC_SUNWELL,
		},
		Combat = {
			[1] = { -- Inferido: RAID_COMBAT. Expertise restaurada (ver punto 2 de
				-- la cabecera de WEIGHT_PROFILES) con el valor real de la fuente.
				ITEM_MOD_HIT_RATING_SHORT = 1.9, -- cap amarillo, prioridad #1
				ITEM_MOD_AGILITY_SHORT = 2.2,
				ITEM_MOD_EXPERTISE_RATING_SHORT = 2.1,
				ITEM_MOD_ATTACK_POWER_SHORT = 1.0,
				ITEM_MOD_CRIT_RATING_SHORT = 1.3,
				ITEM_MOD_HASTE_RATING_SHORT = 1.4,
				ITEM_MOD_STRENGTH_SHORT = 1.1,
				ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 6.5,
			},
			[2] = ROGUE_GENERIC_T5, [3] = ROGUE_GENERIC_T6, [4] = ROGUE_GENERIC_T6, [5] = ROGUE_GENERIC_SUNWELL,
		},
		Subtlety = {
			[1] = { -- OJO: la fuente no tiene variante PvE/raid para Subtlety, solo
				-- PVP_SUBTLETY. Se usa igual (mejor que nada), pero prioriza
				-- Resiliencia (stat de PvP) — no es un perfil de raid real.
				ITEM_MOD_RESILIENCE_RATING_SHORT = 1.8,
				ITEM_MOD_STAMINA_SHORT = 1.5,
				ITEM_MOD_AGILITY_SHORT = 2.4,
				ITEM_MOD_ATTACK_POWER_SHORT = 1.0,
				ITEM_MOD_HIT_RATING_SHORT = 0.5,
				ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT = 0.3,
				ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 3.0,
			},
			[2] = ROGUE_GENERIC_T5, [3] = ROGUE_GENERIC_T6, [4] = ROGUE_GENERIC_T6, [5] = ROGUE_GENERIC_SUNWELL,
		},
	},
	PRIEST = {
		Discipline = {
			[1] = { -- Sin EndgameTabMap; inferido: DISC_SUPPORT
				ITEM_MOD_INTELLECT_SHORT = 1.5, -- Rapture
				ITEM_MOD_SPELL_HEALING_DONE_SHORT = 1.0,
				ITEM_MOD_SPELL_POWER_SHORT = 1.0,
				ITEM_MOD_MANA_REGENERATION_SHORT = 2.0,
				ITEM_MOD_SPIRIT_SHORT = 0.6,
				ITEM_MOD_SPELL_CRIT_RATING_SHORT = 0.5,
			},
		},
		Holy = {
			[1] = { -- Inferido: HOLY_DEEP. Reordenado contra Icy Veins
				-- (holy-priest-healer-pve-stat-priority: Celeridad > Poder de
				-- Curación > Crítico > Espíritu > Intelecto > Mp5 > Aguante) --
				-- la fuente tenía Mp5 como el peso más alto y Celeridad casi el
				-- más bajo, al revés de la prioridad general de la guía.
				ITEM_MOD_SPELL_HEALING_DONE_SHORT = 2.2,
				ITEM_MOD_SPELL_POWER_SHORT = 2.2,
				ITEM_MOD_SPIRIT_SHORT = 1.1, -- Spiritual Guidance
				ITEM_MOD_MANA_REGENERATION_SHORT = 0.5,
				ITEM_MOD_INTELLECT_SHORT = 0.8,
				ITEM_MOD_SPELL_HASTE_RATING_SHORT = 2.4,
				ITEM_MOD_SPELL_CRIT_RATING_SHORT = 1.6,
			},
		},
		Shadow = {
			[1] = { -- Inferido: SHADOW_PVE, no SHADOW_PVP ni SMITE_DPS. Espíritu
				-- reordenado por encima de Mp5 contra Icy Veins
				-- (shadow-priest-dps-pve-stat-priority: ...Espíritu > Mp5 >
				-- Aguante).
				ITEM_MOD_HIT_SPELL_RATING_SHORT = 1.4, -- cap es prioridad #1
				ITEM_MOD_SHADOW_DAMAGE_SHORT = 1.2,
				ITEM_MOD_SPELL_POWER_SHORT = 1.0,
				ITEM_MOD_SPELL_HASTE_RATING_SHORT = 0.8,
				ITEM_MOD_SPELL_CRIT_RATING_SHORT = 0.4,
				ITEM_MOD_INTELLECT_SHORT = 0.3,
				ITEM_MOD_SPIRIT_SHORT = 0.55,
				ITEM_MOD_MANA_REGENERATION_SHORT = 0.45,
			},
		},
	},
	SHAMAN = {
		Elemental = {
			[1] = { -- EndgameTabMap: ELE_PVE. Celeridad reordenada por encima de
				-- Daño de Hechizos contra Icy Veins (Golpe > Celeridad > Daño de
				-- Hechizos > Crítico), que antes tenía el orden invertido.
				ITEM_MOD_HIT_SPELL_RATING_SHORT = 1.3,
				ITEM_MOD_SPELL_HASTE_RATING_SHORT = 1.25,
				ITEM_MOD_NATURE_DAMAGE_SHORT = 1.2,
				ITEM_MOD_SPELL_POWER_SHORT = 1.0,
				ITEM_MOD_SPELL_CRIT_RATING_SHORT = 0.8,
				ITEM_MOD_INTELLECT_SHORT = 0.4,
				ITEM_MOD_MANA_REGENERATION_SHORT = 0.5,
				ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 0.02,
			},
		},
		Enhancement = {
			[1] = { -- EndgameTabMap: ENH_PVE. Expertise restaurada (ver punto 2 de
				-- la cabecera de WEIGHT_PROFILES) con el valor real de la fuente.
				ITEM_MOD_HIT_RATING_SHORT = 1.9,
				ITEM_MOD_EXPERTISE_RATING_SHORT = 2.1,
				ITEM_MOD_STRENGTH_SHORT = 2.1,
				ITEM_MOD_AGILITY_SHORT = 1.6,
				ITEM_MOD_ATTACK_POWER_SHORT = 1.0,
				ITEM_MOD_INTELLECT_SHORT = 1.1, -- maná para Shocks/totems
				ITEM_MOD_CRIT_RATING_SHORT = 1.3,
				ITEM_MOD_HASTE_RATING_SHORT = 1.2,
				ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT = 0.4,
				ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 4.5,
			},
		},
		Restoration = {
			[1] = { -- EndgameTabMap: RESTO_PVE. Celeridad e Intelecto ajustados a
				-- los valores EXACTOS que da Icy Veins
				-- (restoration-shaman-healer-pve-stat-priority, formato Pawn:
				-- Intelecto=0.5, Mp5=2, Curación=1, CríticoHechizos=0.6,
				-- CeleridadHechizos=1.5, Aguante=0.2) -- Curación, Crítico y
				-- Mp5 ya coincidían casi exactos con la fuente anterior.
				ITEM_MOD_SPELL_HEALING_DONE_SHORT = 1.0,
				ITEM_MOD_MANA_REGENERATION_SHORT = 2.0,
				ITEM_MOD_INTELLECT_SHORT = 0.5,
				ITEM_MOD_SPELL_HASTE_RATING_SHORT = 1.5,
				ITEM_MOD_SPELL_CRIT_RATING_SHORT = 0.6,
				ITEM_MOD_DAMAGE_PER_SECOND_SHORT = 0.02,
			},
		},
	},
	WARLOCK = {
		Affliction = {
			[1] = { -- Sin EndgameTabMap; inferido: RAID_AFFLICTION. Celeridad
				-- subida y Aguante bajado contra Icy Veins
				-- (affliction-warlock-dps-pve-stat-priority), que da valores de
				-- equivalencia numéricos reales relativos a Poder con Hechizos:
				-- Celeridad ≈1.36x, Aguante ≈0x (0 DPS de Aguante para un Brujo).
				ITEM_MOD_SHADOW_DAMAGE_SHORT = 1.2,
				ITEM_MOD_SPELL_POWER_SHORT = 1.3,
				ITEM_MOD_HIT_SPELL_RATING_SHORT = 1.4,
				ITEM_MOD_SPELL_HASTE_RATING_SHORT = 1.75,
				ITEM_MOD_SPELL_CRIT_RATING_SHORT = 0.5,
				ITEM_MOD_INTELLECT_SHORT = 0.5,
				ITEM_MOD_STAMINA_SHORT = 0.05,
				ITEM_MOD_SPIRIT_SHORT = 0.3,
				ITEM_MOD_MANA_REGENERATION_SHORT = 0.1,
			},
		},
		Demonology = {
			[1] = { -- Inferido: DEMO_PVE. Mismo ajuste de Celeridad/Aguante que
				-- Afflicción, contra Icy Veins (demonology-warlock-dps-pve-stat-
				-- priority, EV numérico: Celeridad ≈1.36x, Aguante ≈0.06x).
				ITEM_MOD_SPELL_POWER_SHORT = 1.0,
				ITEM_MOD_SHADOW_DAMAGE_SHORT = 0.95,
				ITEM_MOD_HIT_SPELL_RATING_SHORT = 1.3,
				ITEM_MOD_SPELL_CRIT_RATING_SHORT = 0.8,
				ITEM_MOD_STAMINA_SHORT = 0.06,
				ITEM_MOD_INTELLECT_SHORT = 0.6,
				ITEM_MOD_SPELL_HASTE_RATING_SHORT = 1.36,
				ITEM_MOD_SPIRIT_SHORT = 0.2,
				ITEM_MOD_MANA_REGENERATION_SHORT = 0.1,
			},
		},
		Destruction = {
			[1] = { -- Inferido: DESTRUCT_SHADOW (Shadow Bolt como nuke principal
				-- en TBC incluso para Destro). La fuente también tiene
				-- DESTRUCT_FIRE, casi idéntico salvo Fire Damage en vez de Shadow.
				-- Mismo ajuste de Celeridad/Aguante que las otras dos specs,
				-- contra Icy Veins (destruction-warlock-dps-pve-stat-priority,
				-- EV numérico: Celeridad ≈1.39x, Aguante ≈0x).
				ITEM_MOD_HIT_SPELL_RATING_SHORT = 1.3,
				ITEM_MOD_SHADOW_DAMAGE_SHORT = 1.2,
				ITEM_MOD_SPELL_POWER_SHORT = 1.3,
				ITEM_MOD_SPELL_CRIT_RATING_SHORT = 0.9,
				ITEM_MOD_SPELL_HASTE_RATING_SHORT = 1.8,
				ITEM_MOD_INTELLECT_SHORT = 0.4,
				ITEM_MOD_STAMINA_SHORT = 0.05,
				ITEM_MOD_SPIRIT_SHORT = 0.2,
				ITEM_MOD_MANA_REGENERATION_SHORT = 0.05,
			},
		},
	},
	DRUID = {
		Balance = {
			[1] = { -- EndgameTabMap: BALANCE_PVE. Celeridad subida por encima de
				-- Crítico, y Espíritu por encima de Mp5, contra Icy Veins
				-- (balance-druid-dps-pve-stat-priority: ...Celeridad > Crítico >
				-- Intelecto > Espíritu > Mp5 > Aguante).
				ITEM_MOD_HIT_SPELL_RATING_SHORT = 1.4,
				ITEM_MOD_SPELL_POWER_SHORT = 1.0,
				ITEM_MOD_ARCANE_DAMAGE_SHORT = 1.0,
				ITEM_MOD_NATURE_DAMAGE_SHORT = 1.0,
				ITEM_MOD_SPELL_HASTE_RATING_SHORT = 1.05,
				ITEM_MOD_SPELL_CRIT_RATING_SHORT = 1.0,
				ITEM_MOD_INTELLECT_SHORT = 0.7,
				ITEM_MOD_SPIRIT_SHORT = 0.45,
				ITEM_MOD_MANA_REGENERATION_SHORT = 0.35,
				ITEM_MOD_STAMINA_SHORT = 0.1,
			},
		},
		Feral = {
			[1] = { -- EndgameTabMap: FERAL_CAT (dps). La fuente también tiene
				-- FERAL_BEAR (tank) por separado — mismo dilema Tank/Melee que
				-- ya documentamos en SpecDetector.lua; SharpiesGearJudge por
				-- defecto también elige la interpretación dps para esta pestaña.
				-- Golpe reordenado por encima de Fuerza contra Icy Veins
				-- (feral-druid-dps-pve-stat-priority: Agilidad > Golpe >
				-- Expertise > Fuerza). Expertise restaurada (ver punto 2 de la
				-- cabecera de WEIGHT_PROFILES) con el valor real de la fuente.
				ITEM_MOD_HIT_RATING_SHORT = 2.2,
				ITEM_MOD_EXPERTISE_RATING_SHORT = 1.9,
				ITEM_MOD_STRENGTH_SHORT = 2.1,
				ITEM_MOD_AGILITY_SHORT = 2.3,
				ITEM_MOD_ATTACK_POWER_SHORT = 1.0,
				ITEM_MOD_FERAL_ATTACK_POWER_SHORT = 1.0,
				ITEM_MOD_CRIT_RATING_SHORT = 1.6,
				ITEM_MOD_ARMOR_PENETRATION_RATING_SHORT = 0.8,
				ITEM_MOD_HASTE_RATING_SHORT = 1.2,
				ITEM_MOD_STAMINA_SHORT = 0.1,
			},
		},
		Restoration = {
			[1] = { -- EndgameTabMap: RESTO_TREE. Reordenado contra Icy Veins
				-- (restoration-druid-healer-pve-stat-priority: Poder de
				-- Curación > Celeridad > Espíritu > Mp5 > Intelecto > Crítico >
				-- Aguante) -- la fuente tenía Mp5 como el peso más alto y
				-- Celeridad casi el más bajo, al revés de la prioridad de la
				-- guía (los HoT de Druida no tickean más rápido con Celeridad,
				-- pero igual pesa más que Mp5 según Icy Veins).
				ITEM_MOD_SPELL_HEALING_DONE_SHORT = 2.4,
				ITEM_MOD_SPELL_HASTE_RATING_SHORT = 2.2,
				ITEM_MOD_SPIRIT_SHORT = 1.35,
				ITEM_MOD_MANA_REGENERATION_SHORT = 1.0,
				ITEM_MOD_INTELLECT_SHORT = 0.7,
				ITEM_MOD_SPELL_CRIT_RATING_SHORT = 0.3,
				ITEM_MOD_STAMINA_SHORT = 0.2,
			},
		},
	},
}

ns.WeightProfiles = WEIGHT_PROFILES

-- Nombre de spec en inglés por [claseToken][índice de árbol], mismo orden
-- de pestañas que SPEC_ROLES en SpecDetector.lua. Confirmado contra
-- `<Clase>.Specs` de SharpiesGearJudge para las 9 clases — coincide
-- exactamente con el orden que ya teníamos.
local SPEC_NAMES = {
	WARRIOR = { "Arms", "Fury", "Protection" },
	PALADIN = { "Holy", "Protection", "Retribution" },
	HUNTER = { "BeastMastery", "Marksmanship", "Survival" },
	ROGUE = { "Assassination", "Combat", "Subtlety" },
	PRIEST = { "Discipline", "Holy", "Shadow" },
	SHAMAN = { "Elemental", "Enhancement", "Restoration" },
	MAGE = { "Arcane", "Fire", "Frost" },
	WARLOCK = { "Affliction", "Demonology", "Destruction" },
	DRUID = { "Balance", "Feral", "Restoration" },
}

-- Compartido con ItemFilter.lua (GetItemTargetBuild): necesita recorrer
-- [claseToken][índice de árbol] -> nombre de spec en inglés para poder
-- indexar WEIGHT_PROFILES de CUALQUIER clase, no solo la del jugador
-- actual (a diferencia de GetActiveWeightProfile, que solo resuelve
-- ns.context).
ns.SpecNames = SPEC_NAMES

--- Perfil de pesos activo para el personaje actual, según ns.context
--- (clase + árbol dominante, Fase 1) y la fase de contenido configurada.
--- nil si no hay perfil cargado para esa combinación todavía.
---
--- Si el usuario guardó overrides manuales (Fase 8, ns.GetStatWeightOverrides
--- de AddonSettings.lua), se mezclan aquí en una tabla NUEVA — nunca se
--- escribe sobre WEIGHT_PROFILES directamente, esa tabla es literal
--- compartida en memoria y mutarla corrompería el perfil base para el
--- resto de la sesión (y para cualquier otro personaje de la misma clase).
local function GetActiveWeightProfile()
	local context = ns.context
	local class = context and context.class
	local dominantTab = context and context.dominantTab
	if not class or not dominantTab then
		return nil
	end

	local specName = SPEC_NAMES[class] and SPEC_NAMES[class][dominantTab]
	local classProfiles = specName and WEIGHT_PROFILES[class]
	local specProfiles = classProfiles and classProfiles[specName]
	local baseProfile = specProfiles and specProfiles[GetContentPhase()]
	if not baseProfile then
		return nil
	end

	local overrides = ns.GetStatWeightOverrides and ns.GetStatWeightOverrides()
	if not overrides or not next(overrides) then
		return baseProfile
	end

	local merged = {}
	for statKey, weight in pairs(baseProfile) do
		merged[statKey] = weight
	end
	for statKey, weight in pairs(overrides) do
		merged[statKey] = weight
	end
	return merged
end

ns.GetActiveWeightProfile = GetActiveWeightProfile

--- Puntúa las stats de un item contra un perfil de pesos.
--- itemStats: tabla {ITEM_MOD_X = valor}, tal cual la devuelve
---            ItemStatsAnalyzer (Fase 2) — se puede pasar directo.
--- weightProfile: tabla {ITEM_MOD_X = peso}, ej. la que devuelve
---                GetActiveWeightProfile().
--- currentStats: tabla {ITEM_MOD_X = valor} con lo que el personaje YA
---               tiene equipado (ej. totalStats de GetEquippedSnapshot),
---               solo para evaluar caps no lineales. Opcional — si se
---               omite, los caps se evalúan como si el personaje partiera
---               de 0 en cada stat (menos preciso, pero sigue funcionando).
--- Devuelve un número: la puntuación total del item para ese perfil.
local function ScoreStats(itemStats, weightProfile, currentStats)
	if not weightProfile then
		return 0
	end
	currentStats = currentStats or {}

	local total = 0
	for statKey, itemValue in pairs(itemStats) do
		local weight = weightProfile[statKey]
		if weight then
			local effectiveValue = EvaluateCappedValue(statKey, itemValue, currentStats[statKey])
			total = total + (effectiveValue * weight)
		end
	end

	return total
end

ns.ScoreStats = ScoreStats
