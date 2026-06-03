# Issues Conocidos y Backlog Técnico

> Estado al momento de la entrega (handoff). Mantener actualizado. Versión 3.0 · 2026-06.

## Críticos / Seguridad
| ID | Tema | Estado | Notas |
|----|------|--------|-------|
| C3 | URL del túnel inestable | Abierto | cloudflared *quick tunnel* rota la URL en cada reinicio. Recomendado: IP pública estática Azure (~$3-4/mes) o named tunnel. |
| SEC-1 | SQLite sin cifrado en reposo | Abierto (ADR pendiente) | El cifrado a nivel app (SQLCipher) solo protege exfiltración de archivo/backup; contra acceso a la VM, lo que protege es control de acceso + clave en Key Vault. |
| SEC-2 | Rotación de `JWT_SECRET` | Recomendado | `.env` nunca estuvo en historial; rotar periódicamente igualmente. |

## Escalabilidad
| ID | Tema | Estado | Notas |
|----|------|--------|-------|
| C5 | API sin autoescalado | Abierto | Proceso único + SQLite local → solo escala **vertical**. Autoescalado horizontal requiere PostgreSQL (T-003) + backend stateless + estado WS compartido. |
| PERF-1 | Carga masiva de campañas | Mitigable | `express.json` limit 2mb; cargas grandes pueden requerir chunking. |

## Correcciones v3.0 (implementadas, pendientes de deploy)
| ID | Tema | Estado |
|----|------|--------|
| C1 | Fallback silencioso a SQLite local en canal de datos no mapeado | ✅ corregido |
| C2 | Sin manejo global de 401 (sesión zombi) | ✅ corregido |
| C4 | Rate-limit de login por IP (bloqueo colectivo) | ✅ corregido (por email) |
| A1 | `.env` cargado por CWD (JWT_SECRET no cargaba bajo PM2) | ✅ corregido (ruta absoluta) |
| Índices | Full scan en cards de cartera/métricas | ✅ M-037 |
| Bug 3 | Cuenta admin visible a supervisores + apartado de personal en supervisor | ✅ (backend + UI) |
| Bug 4 | Sin aislamiento de equipos por supervisor | ✅ (`supervisor_id` + REST + WS + UI admin) |

## Verificación pendiente (requiere VM)
- Confirmar en la VM: tipo de túnel (C3), IP compartida en rate-limit (C4), `JWT_SECRET`/`NODE_ENV` cargados (A1), specs de la VM.
- Causa raíz del error "Login fallido: Respuesta inválida del servidor" en `admin:vmLogin` (respuesta no-JSON del POST de login) — diagnosticar con curl directo.

## Deuda menor
- Código muerto: `renderPersonalConfig` en `SupervisorPanel.jsx` (apartado removido, función sin uso).
- Dir `backend/` (Prisma) divergente del backend real (`src/main/apiServer.js`).
