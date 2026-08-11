# PickItRight

Asistente de decisiones de equipo en tiempo real para **World of Warcraft: Burning Crusade Classic** (Anniversary). Detecta tu clase, raza y especialización activa, y te dice si un ítem que acabás de lootear es una mejora real — directo en el tooltip de la ventana de saqueo, sin tener que alt-tabear a una calculadora.

## Qué hace

- Detecta automáticamente tu clase/raza/spec (vía el árbol de talentos con más puntos invertidos — TBC no expone un flag oficial de "spec activa").
- Extrae las estadísticas reales del ítem con la API de WoW, nunca por item level ni parseando el texto del tooltip.
- Filtra por proficiencia de armadura/arma de tu clase y por stats irrelevantes a tu rol antes de puntuar nada.
- Puntúa cada ítem contra un perfil de pesos por clase y especialización (Fase 1 de contenido: Kara/Gruul/Magtheridon), fuente real de theorycrafting, no números inventados.
- Compara contra lo que ya tenés equipado en ese slot — no solo el puntaje absoluto del ítem.
- Muestra el veredicto directo en la ventana de loot, en las tiradas Need/Greed de grupo, en la pantalla de recompensas de misión (al aceptar, al entregar, o mirándolas desde el diario sin estar frente al NPC), y también al pasar el cursor sobre cualquier ítem que ya tengas en la mochila:
  - 🟢 **Mejora** — supera lo que tenés puesto.
  - ⚪ **No es mejora** / sin datos suficientes para comparar.
  - 🔴 **Rechazado**, con el motivo exacto (tipo de armadura incorrecto, arma no entrenada, stats incompatibles con tu rol, etc.).

## Instalación

1. Descargar este repo, o correr `powershell -File package.ps1` para generar un paquete listo en `dist/PickItRight/`.
2. Copiar esa carpeta a `Interface/AddOns/PickItRight/` de tu instalación de WoW — debe quedar `Interface/AddOns/PickItRight/PickItRight.toc` (el nombre de carpeta tiene que coincidir exactamente con el del `.toc`).
3. En la pantalla de selección de personaje, botón **AddOns**, activar **PickItRight**.

## Uso

Pasá el cursor sobre cualquier ítem en la ventana de saqueo, en una tirada de grupo, en la pantalla de recompensas de misión, o en tu mochila — no hace falta hacer nada más.

| Comando | Qué hace |
|---|---|
| `/pickitright` | Resumen de uso |
| `/pickitright phase` | Ver la fase de contenido activa |
| `/pickitright phase <1-5>` | Fijar la fase de contenido (1 = Kara/Gruul/Mag, 2 = SSC/TK, ...) |
| `/pickitright weight <ITEM_MOD_X> <valor>` | Override manual del peso de un stat para tu build |
| `/pickitright weight <ITEM_MOD_X> clear` | Quitar ese override |
| `/pickitright module <LootIntegration\|UIIntegration> <on\|off>` | Activar/desactivar un módulo |

## Estado actual

- Cobertura de pesos: las 9 clases × 3 especializaciones, pero **solo Fase 1 de contenido** — fases posteriores todavía no tienen datos y se degradan con gracia (motivo "Sin datos de build") en vez de dar una recomendación inventada.
- Requiere un cliente TBC Classic; el `.toc` fija `## Interface: 20506` — si tu cliente marca el addon como "fuera de fecha", verificalo con `/dump select(4, GetBuildInfo())` in-game.

## Desarrollo

`CLAUDE.md` tiene el detalle completo de arquitectura, decisiones de diseño fase por fase, y qué está verificado contra fuentes reales vs. qué sigue siendo un supuesto documentado.

Tests (standalone, sin necesitar el cliente de WoW):

```
lua5.1 tests/test_*.lua
```
