# Changelog

Formato basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.0.0/).

## [0.1.0] - 2026-08-24

### Agregado

- Detección automática de clase, raza y especialización activa (vía árbol de talentos dominante — TBC no expone una API oficial de "spec activa"), incluyendo soporte para clientes con spec dual (TBC Anniversary).
- Extracción de stats reales de cada ítem con la API del juego, nunca por item level — incluye los bonos que solo aparecen en líneas "Equip: Improves/Increases X by Y" del tooltip, que `GetItemStats()` no expone por sí sola.
- Tablas de pesos de stats por clase y especialización (9 clases × 3 specs), sourced de gear-scoring real de TBC y cruzadas contra guías públicas de theorycrafting, con caps no lineales para stats con techo (Golpe de Hechizos, etc.).
- Filtro estricto de elegibilidad antes de puntuar: tipo de armadura según nivel de entrenamiento real (no el máximo teórico de nivel 70), arma entrenada para la clase, y stats itemizados para otro rol.
- Veredicto directo en el tooltip de la ventana de loot, tiradas Need/Greed de grupo, recompensas de misión (al aceptar, al entregar, y desde el diario sin estar frente al NPC), y objetos en la mochila — sin mostrar nunca el puntaje numérico, solo "Equípatelo" / "No es mejora" / motivo de rechazo, y una segunda línea indicando qué stat concreto explica una mejora.
- Comparación contra lo que ya está equipado en el mismo slot, no solo el score absoluto del ítem.
- Comandos `/pickitright phase|weight|module|inspect|context|talents` para fijar la fase de contenido activa, ajustar pesos manualmente, activar/desactivar módulos, y diagnosticar el estado detectado del personaje.
- Persistencia de configuración vía SavedVariables.
