# Changelog

Formato basado en [Keep a Changelog](https://keepachangelog.com/). Fechas en YYYY-MM-DD.

## [3.0] — 2026-06 (en preparación de despliegue)
### Seguridad
- Rate-limit de login **por cuenta (email)** en lugar de por IP (evita bloqueo colectivo tras túnel). *(C4)*
- Carga de `.env` por ruta absoluta — `JWT_SECRET` se carga independientemente del CWD del proceso. *(A1)*
### Añadido
- **Aislamiento de equipos por supervisor** (`usuarios.supervisor_id`): listas, métricas, compromisos y monitoreo WS filtrados por equipo; admin ve todo. *(Bug 4)*
- Selector de supervisor en el panel Admin al crear/editar asesores.
- Índices de cartera/métricas (`idx_ct_dias_impago`, etc.). *(M-037)*
- Harness de pruebas contra BD real (`tests/helpers/realDb.js`); scripts de carga k6.
- Documentación técnica en `docs/` (arquitectura, reglas de negocio, API, modelo de datos, runbook, issues).
### Cambiado
- Gestión de usuarios movida exclusivamente al panel Admin; el panel del Supervisor ya no la muestra. *(Bug 3)*
- Manejo global de 401 → cierre de sesión en vez de sesión zombi. *(C2)*
- Canal de datos no mapeado en modo remoto ya no cae a SQLite local. *(C1)*
### Corregido
- Cuenta admin del sistema ya no visible para supervisores. *(Bug 3)*
- "Pagos Realizados" mostraba data; reportería emite Excel. *(Bugs 1, 2)*
- Botón "Desconectar" removido del listado de asesores del supervisor.
- Test de cartera-evolución corregido (conteo NO REALIZADA).

## [2.0] — 2026-04
- Migración dual-mode (local/VM), validación de pagos, compromisos, métricas de equipo, seguridad de dependencias (Dependabot + CI).

## [1.0] — 2026-03
- Versión inicial: monitoreo Asesor/Supervisor en LAN, ADB/scrcpy, tipificaciones, reportes.
