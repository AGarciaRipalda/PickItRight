local ADDON_NAME, ns = ...
local L = ns.L

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(_, _, arg1)
	if arg1 == ADDON_NAME then
		print(("|cff33ff99%s|r %s"):format(ADDON_NAME, L["ADDON_LOADED"]))
	end
end)
