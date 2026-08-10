local ADDON_NAME, ns = ...

-- Tabla de locale simple, sin dependencia de AceLocale. Clave por defecto en
-- español; añadir bloques `if locale == "..." then` para otros idiomas
-- cuando el addon los necesite, no antes.
local L = {}
ns.L = L

L["ADDON_LOADED"] = "cargado. Rol detectado vía especialización dominante de talentos."
