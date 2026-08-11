-- Prueba de humo standalone (no requiere el cliente de WoW). Ejecutar desde
-- la raíz del repo con cualquier intérprete Lua 5.1:
--   lua5.1 tests/test_ContainerAPIShim.lua
--
-- Regresión dedicada a un bug real encontrado en juego (Fase 9): en el
-- cliente TBC Anniversary, los globals clásicos GetContainerNumSlots/
-- GetContainerItemLink NO existen -- solo C_Container.GetContainerNumSlots/
-- C_Container.GetContainerItemLink. Los otros tests (test_LootIntegration.lua,
-- test_UIIntegration.lua) definen esos globals directamente como stub, así
-- que NUNCA hubieran detectado este bug -- por diseño no simulan un cliente
-- donde el global no existe. Este archivo sí: deliberadamente NO define
-- _G.GetContainerNumSlots ni _G.GetContainerItemLink, solo _G.C_Container.

local registeredHandler
_G.CreateFrame = function()
	return {
		RegisterEvent = function() end,
		SetScript = function(_, _, handler) registeredHandler = handler end,
	}
end

_G.NUM_BAG_SLOTS = 4
_G.C_Container = {
	GetContainerNumSlots = function(bag) return bag == 0 and 2 or 0 end,
	GetContainerItemLink = function(bag, slot)
		if bag == 0 and slot == 1 then
			return "item:desde-c-container"
		end
		return nil
	end,
}
-- A propósito: sin _G.GetContainerNumSlots ni _G.GetContainerItemLink. Si
-- LootIntegration.lua o UIIntegration.lua intentan usar el global viejo en
-- vez del shim, esto reproduce el crash real ("attempt to call a nil value").

local ns = {}
ns.GetItemString = function(link) return link end
ns.GetCachedResult = function() return nil end
ns.RequestItemStats = function(link, callback) callback({ ITEM_MOD_SPELL_POWER_SHORT = 10 }) end
ns.GetEquippedSnapshot = function() return {} end
ns.IsModuleEnabled = function() return true end
ns.EvaluateItem = function() return { eligible = true, score = 55 } end

assert(loadfile("LootIntegration.lua"))("PickItRight", ns)

local function assertEqual(actual, expected, label)
	assert(actual == expected, ("%s: esperado %s, obtenido %s"):format(label, tostring(expected), tostring(actual)))
end

-- Caso 1: ScanBags (disparado por BAG_UPDATE_DELAYED) usa C_Container.*
-- sin arrojar error, y resuelve el ítem que solo esa API conoce.
registeredHandler(nil, "BAG_UPDATE_DELAYED")
assertEqual(ns.GetBagItemResult("item:desde-c-container").result.score, 55,
	"caso 1: ScanBags usó C_Container.GetContainerNumSlots/GetContainerItemLink sin el global clásico")

-- Caso 2: UIIntegration.lua también resuelve el link vía el mismo shim, no
-- solo LootIntegration.lua (cada archivo lo definió por su cuenta).
_G.hooksecurefunc = function(tbl, name, hookFn)
	local original = tbl[name]
	tbl[name] = function(self, ...)
		if original then
			original(self, ...)
		end
		hookFn(self, ...)
	end
end
local GameTooltip = {
	lines = {},
	SetLootItem = function() end,
	SetLootRollItem = function() end,
	SetQuestItem = function() end,
	SetBagItem = function() end,
	SetQuestLogItem = function() end,
	AddLine = function(self, text) table.insert(self.lines, text) end,
	Show = function() end,
}
_G.GameTooltip = GameTooltip
ns.GetLootResult = function() return nil end
ns.GetRollResult = function() return nil end
ns.GetQuestRewardResult = function() return nil end
ns.GetQuestLogRewardResult = function() return nil end

assert(loadfile("UIIntegration.lua"))("PickItRight", ns)

GameTooltip:SetBagItem(0, 1)
local lastLine = GameTooltip.lines[#GameTooltip.lines]
assert(lastLine and lastLine:find("55"),
	"caso 2: SetBagItem resolvió el link vía C_Container y mostró el score real, no un placeholder ni un error")

print("OK: test_ContainerAPIShim.lua supera la prueba de humo")
