# Empaqueta el addon para Interface/AddOns/. Lee la lista de archivos y el
# nombre del addon directamente del .toc presente en la carpeta (nunca los
# duplica a mano acá: un .toc con nombre distinto, o un módulo nuevo
# agregado a su lista, se recogen solos, sin tocar este script).
#
# Uso:  powershell -File package.ps1
# Salida: dist/<NombreDelAddon>/       (carpeta lista para copiar)
#         dist/<NombreDelAddon>.zip    (lista para subir o descomprimir en AddOns/)

$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$distRoot = Join-Path $root "dist"

$tocFile = Get-ChildItem -Path $root -Filter "*.toc" | Select-Object -First 1
if (-not $tocFile) {
    throw "No se encontro ningun .toc en $root"
}
$tocPath = $tocFile.FullName
$addonName = [System.IO.Path]::GetFileNameWithoutExtension($tocFile.Name)
$addonDist = Join-Path $distRoot $addonName

# Lineas del .toc que no son metadatos (## ...) ni vacias == archivos a incluir.
$luaFiles = Get-Content $tocPath | Where-Object {
    $_.Trim() -ne "" -and -not $_.TrimStart().StartsWith("##")
} | ForEach-Object { $_.Trim() }

if ($luaFiles.Count -eq 0) {
    throw "$($tocFile.Name) no lista ningun archivo .lua -- revisar antes de empaquetar."
}

foreach ($file in $luaFiles) {
    $fullPath = Join-Path $root $file
    if (-not (Test-Path $fullPath)) {
        throw "El .toc referencia '$file' pero el archivo no existe. Corregir antes de empaquetar."
    }
}

if (Test-Path $distRoot) {
    Remove-Item $distRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $addonDist -Force | Out-Null

Copy-Item $tocPath -Destination $addonDist
foreach ($file in $luaFiles) {
    Copy-Item (Join-Path $root $file) -Destination $addonDist
}

$zipPath = Join-Path $distRoot "$addonName.zip"
Compress-Archive -Path $addonDist -DestinationPath $zipPath -Force

Write-Host "Empaquetado en $zipPath"
Write-Host "Contenido: $($tocFile.Name) + $($luaFiles.Count) archivo(s) .lua"
Write-Host ($luaFiles -join "`n")
Write-Host ""
Write-Host "Instalar: descomprimir dentro de Interface/AddOns/ -- debe quedar"
Write-Host "Interface/AddOns/$addonName/$($tocFile.Name) (el nombre de carpeta debe"
Write-Host "coincidir exactamente con el nombre del .toc)."
