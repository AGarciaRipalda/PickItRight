-- Prueba de humo standalone (no requiere el cliente de WoW). Ejecutar desde
-- la raíz del repo con cualquier intérprete Lua 5.1:
--   lua5.1 tests/test_ItemStatsAnalyzer.lua

local loadedItems = {} -- [itemString] = true si "el cliente" ya lo tiene cacheado
local statsByLink = {} -- [itemLink] = stats simuladas devueltas por GetItemStats
local registeredHandler

_G.GetItemInfo = function(link)
	local itemString = link:match("(item:[%-%d:]+)")
	return loadedItems[itemString] and "MockItemName" or nil
end
_G.GetItemStats = function(link) return statsByLink[link] end
_G.CreateFrame = function()
	return {
		RegisterEvent = function() end,
		SetScript = function(_, _, handler) registeredHandler = handler end,
	}
end

local ns = {}
assert(loadfile("ItemStatsAnalyzer.lua"))("PickItRight", ns)

local function assertEqual(actual, expected, label)
	assert(actual == expected, ("%s: esperado %s, obtenido %s"):format(label, tostring(expected), tostring(actual)))
end

-- Caso 1: item ya cacheado por el cliente -> resuelve de inmediato.
local linkA = "item:12345:0:0:0:0:0:100:0:70:0:0"
loadedItems[linkA] = true
statsByLink[linkA] = { ITEM_MOD_CRIT_RATING_SHORT = 10 }

local resultA
ns.RequestItemStats(linkA, function(stats) resultA = stats end)
assert(resultA, "caso 1: el callback no se llamó de inmediato")
assertEqual(resultA.ITEM_MOD_CRIT_RATING_SHORT, 10, "caso 1: stat esperado")

-- Caso 2: mismo itemID (12345), sufijo distinto -> cache separado, no se pisan.
local linkB = "item:12345:0:0:0:0:0:200:0:70:0:0"
loadedItems[linkB] = true
statsByLink[linkB] = { ITEM_MOD_CRIT_RATING_SHORT = 25 }

local resultB
ns.RequestItemStats(linkB, function(stats) resultB = stats end)
assertEqual(resultB.ITEM_MOD_CRIT_RATING_SHORT, 25, "caso 2: sufijo distinto no debe compartir cache")
assertEqual(resultA.ITEM_MOD_CRIT_RATING_SHORT, 10, "caso 2: el link original no debe haber cambiado")

-- Caso 3: item aún no descargado por el cliente -> espera a GET_ITEM_INFO_RECEIVED.
local linkC = "item:99999:0:0:0:0:0:0:0:70:0:0"
statsByLink[linkC] = { ITEM_MOD_STAMINA_SHORT = 15 }

local resultC, calledImmediately = nil, false
ns.RequestItemStats(linkC, function(stats)
	resultC = stats
	calledImmediately = true
end)
assert(not calledImmediately, "caso 3: no debía resolver antes de que el item esté cacheado")

loadedItems[linkC] = true -- "el cliente" ya terminó de descargar los datos
registeredHandler(nil, "GET_ITEM_INFO_RECEIVED", 99999, true)
assert(resultC, "caso 3: el reintento tras GET_ITEM_INFO_RECEIVED debía resolver el callback")
assertEqual(resultC.ITEM_MOD_STAMINA_SHORT, 15, "caso 3: stat esperado tras reintento")

-- Caso 4: un link "decorado" (color + nombre) comparte cache con el mismo
-- item string plano, porque la key de cache es el item string, no el texto.
local plain = "item:55555:0:0:0:0:0:0:0:70:0:0"
local decorated = "|cff1eff00|Hitem:55555:0:0:0:0:0:0:0:70:0:0|h[Objeto Mock]|h|r"
loadedItems[plain] = true
statsByLink[plain] = { ITEM_MOD_AGILITY_SHORT = 8 }

local resultPlain
ns.RequestItemStats(plain, function(stats) resultPlain = stats end)

local resultDecorated
ns.RequestItemStats(decorated, function(stats) resultDecorated = stats end)
assertEqual(resultDecorated, resultPlain, "caso 4: link decorado debe compartir cache con su item string plano")

-- Caso 5: snapshot de equipo suma stats de varios slots y conserva el
-- desglose por slot.
local equipped = {
	HeadSlot = "item:1:0:0:0:0:0:0:0:70:0:0",
	ChestSlot = "item:2:0:0:0:0:0:0:0:70:0:0",
}
loadedItems[equipped.HeadSlot] = true
loadedItems[equipped.ChestSlot] = true
statsByLink[equipped.HeadSlot] = { ITEM_MOD_STAMINA_SHORT = 20, ITEM_MOD_CRIT_RATING_SHORT = 5 }
statsByLink[equipped.ChestSlot] = { ITEM_MOD_STAMINA_SHORT = 30 }

_G.GetInventorySlotInfo = function(name) return name end
_G.GetInventoryItemLink = function(_, slotID) return equipped[slotID] end

local totalStats, bySlot = ns.GetEquippedSnapshot()
assertEqual(totalStats.ITEM_MOD_STAMINA_SHORT, 50, "caso 5: suma de aguante entre slots")
assertEqual(totalStats.ITEM_MOD_CRIT_RATING_SHORT, 5, "caso 5: crítico solo viene del casco")
assertEqual(bySlot.HeadSlot.link, equipped.HeadSlot, "caso 5: el desglose por slot conserva el link")

print("OK: ItemStatsAnalyzer.lua supera la prueba de humo")
