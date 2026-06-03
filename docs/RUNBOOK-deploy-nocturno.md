# 🌙 Runbook — Deploy nocturno v3.0 (C1/C2 + C4 + A1 + Índices + Bug 3 + Bug 4)

> **Contexto:** app YA en producción con equipo operando. Este deploy reinicia el proceso → corta conexiones y (si quick tunnel) rota la URL. **Solo en ventana sin operación.**

## ⚠️ DOS destinos
- **VM (backend):** corre `apiServer` (build `out/`). Aplica al hacer rebuild + restart PM2.
- **PCs cliente (7):** Electron instalado (NSIS). Los cambios de renderer aplican al **reinstalar la app**.
- El aislamiento **REST** de Bug 4 funciona solo con la VM. El aislamiento **WS en tiempo real**, la **UI de asignar equipos** y **C1/C2** requieren clientes actualizados (hasta entonces, el WS falla-abierto).

## Cambios a desplegar

### Backend → VM
| Archivo | Tipo | Fix |
|---------|------|-----|
| `src/main/security/rateLimitKeys.js` | **NUEVO** | C4 (rate limit por email) |
| `src/main/wsGroupFilter.js` | **NUEVO** | Bug 4 (broadcast WS por grupo) |
| `src/main/apiServer.js` | mod | C4 + A1 (.env abs) + Bug 3/4 (filtros por token) |
| `src/main/database/db.js` | mod | M-037 (índices) + **M-038 (`supervisor_id`)** — corren al arrancar |
| `src/main/database/queries.js` | mod | Bug 3 (admin oculto) + Bug 4 (aislamiento equipo) |
| `src/main/wsServer.js` | mod | Bug 4 (filtro broadcast por grupo) |
| `src/main/ipcHandlers.js` | mod | Bug 3/4 (admin:getUsers, updateUser supervisor_id) |

### Cliente → 7 PCs (reinstalar app)
| Archivo | Tipo | Fix |
|---------|------|-----|
| `src/renderer/shared/apiClient.js` | **NUEVO** | C1/C2 |
| `src/renderer/asesor/AsesorPanel.jsx` | mod | C1/C2 |
| `src/renderer/supervisor/SupervisorPanel.jsx` | mod | C2 + Bug 4 (IDENTIFICAR con supervisor_id/es_admin) |
| `src/renderer/admin/AdminPanel.jsx` | mod | Bug 4 (selector de supervisor) |

> ⚠️ Faltan archivos NUEVOS (`rateLimitKeys.js`, `wsGroupFilter.js`, `apiClient.js`) → el build/arranque **falla**. Confirmar que todos los `??` del `git status` estén presentes antes de buildear (Paso 4).
> ⚠️ M-037 + M-038 corren automáticamente al arrancar sobre la BD de prod (~120k filas): `ALTER ADD COLUMN` es instantáneo, `CREATE INDEX` toma segundos. Una sola vez.

---

## PASO 0 — Pre-flight (se puede hacer de día, read-only)

```powershell
# ¿Cómo corre el server? Anota el "script path" y "exec cwd".
pm2 list
pm2 describe <id-del-server>
```
**RAMA CRÍTICA según el script path:**
- Si apunta a **`out\main\...`** → la VM corre el BUILD. Hay que `npm run build` tras copiar `src/` (Paso 5b).
- Si apunta a **`src\main\...`** → corre fuente directa. Copiar `src/` basta (sin build).

```powershell
# Línea base a comparar luego
pm2 env <id> | Select-String "JWT_SECRET|NODE_ENV"      # A1
Get-CimInstance Win32_Process -Filter "name='cloudflared.exe'" | Select CommandLine   # C3
(Invoke-WebRequest http://localhost:3001/api/health -UseBasicParsing).Content
```

---

## PASO 1 — Abrir ventana (equipo offline)

```powershell
# Confirmar que NO hay asesores conectados antes de tocar nada
pm2 logs --lines 20 | Select-String "WS|IDENTIFICAR|conect"
# (Idealmente avisar al equipo y confirmar 0 sesiones activas)
```

---

## PASO 2 — Backup BD (OBLIGATORIO, irreversible si se omite)

```powershell
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
# Checkpoint del WAL para que el .db quede consistente
# (o detener el server un momento antes de copiar — ver Paso 4)
Copy-Item F:\cobranza\data\terminal.db      "F:\cobranza\backups\terminal-$stamp.db"
Copy-Item F:\cobranza\data\terminal.db-wal  "F:\cobranza\backups\terminal-$stamp.db-wal" -ErrorAction SilentlyContinue
Copy-Item F:\cobranza\data\terminal.db-shm  "F:\cobranza\backups\terminal-$stamp.db-shm" -ErrorAction SilentlyContinue
Test-Path "F:\cobranza\backups\terminal-$stamp.db"   # debe ser True
```
> **Snapshot de la VM en Azure Portal** antes de continuar (recuperación total ante cualquier fallo).

---

## PASO 3 — Respaldar versión actual del código (para rollback)

```powershell
# Opción git (si la VM trackea el repo):
cd F:\ruta\al\app
git stash list ; git rev-parse HEAD        # anota el commit actual
# Opción copia (si no hay git en la VM):
Copy-Item src\main\apiServer.js        "F:\cobranza\rollback\apiServer.js.bak"
Copy-Item src\main\database\db.js      "F:\cobranza\rollback\db.js.bak"
```

---

## PASO 4 — Detener el server y copiar archivos

```powershell
pm2 stop <id-del-server>        # corta el proceso (ventana ya abierta)

# Copiar los 3 archivos (desde el repo de dev o git pull):
#   Backend (ver tabla "Cambios → VM"): los 7 archivos src/main/*
#   Crear carpeta src\main\security\ si no existe (archivo nuevo rateLimitKeys.js)
```
**Verificación previa al arranque (evita outage) — los 3 archivos NUEVOS:**
```powershell
Test-Path src\main\security\rateLimitKeys.js ; Test-Path src\main\wsGroupFilter.js ; Test-Path src\main\shared 2>$null
node -e "require('./src/main/security/rateLimitKeys'); require('./src/main/wsGroupFilter'); console.log('require OK')"
```

---

## PASO 5 — Aplicar y arrancar

**5a. Sin dependencias nuevas** (express-rate-limit ya estaba) → no `npm install`.

**5b. SOLO si la VM corre `out/` (ver Paso 0):**
```powershell
npm run build        # regenera out/ con los cambios de src/
```

**5c. ¿ABI de better-sqlite3?** (si en logs aparece `NODE_MODULE_VERSION`):
```powershell
npm rebuild better-sqlite3
```

**5d. Arrancar:**
```powershell
pm2 start <id-del-server>   # o pm2 restart <id>
pm2 logs --lines 40         # vigilar arranque
```
> Las migraciones **M-037** (índices) y **M-038** (`supervisor_id`) corren automáticamente al arrancar `initDatabase()`. ALTER instantáneo + CREATE INDEX segundos. Una sola vez.

---

## PASO 6 — Verificación post-deploy

```powershell
# Salud
(Invoke-WebRequest http://localhost:3001/api/health -UseBasicParsing).Content     # ok:true

# A1 — JWT_SECRET cargado y NO el fallback dev
pm2 logs --lines 40 | Select-String "SEGURIDAD|secret|JWT"     # sin throw de seguridad
# Login real devuelve token:
$body = '{"email":"asesor@uphone.local","password":"asesor123"}'
Invoke-WebRequest http://localhost:3001/api/auth/login -Method POST -Body $body -ContentType "application/json" -UseBasicParsing

# Índices (M-037) presentes:
# (con sqlite3.exe o un script node que liste sqlite_master)
node -e "process.env.DB_PATH='F:/cobranza/data/terminal.db'; const {initDatabase,getDb,closeDb}=require('./src/main/database/db'); initDatabase(); console.log(getDb().prepare(\"SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_ct_%'\").all()); closeDb();"
```
**Criterio de éxito:** health ok · login devuelve `token` · sin errores en `pm2 logs` · índices listados.

**Bug 3 + Bug 4 (aislamiento) — verificación funcional:**
```powershell
# Bug 4: columna supervisor_id existe
node -e "process.env.DB_PATH='F:/cobranza/data/terminal.db'; const {initDatabase,getDb,closeDb}=require('./src/main/database/db'); initDatabase(); console.log(getDb().prepare(\"PRAGMA table_info(usuarios)\").all().map(c=>c.name).includes('supervisor_id')?'supervisor_id OK':'FALTA'); closeDb();"
# Bug 3: token de un supervisor → GET /api/admin/users NO debe traer rol 'admin'
# Bug 4: ese mismo token → GET /api/asesores solo trae asesores con su supervisor_id
#   (probar con curl/Invoke-WebRequest usando un token de supervisor real)
```
**Criterio:** supervisor NO ve cuenta admin ni asesores de otros equipos; admin ve todo.

---

## PASO 7 — URL del túnel (si sigue quick tunnel — C3 sin resolver)

```powershell
Get-Content F:\cobranza\logs\tunnel-url.txt    # URL NUEVA tras el reinicio
```
> Distribuir la URL nueva a los clientes (campo "Configurar IP del Servidor" → `uphone_ws_ip`). **Este paso desaparece cuando se resuelva C3** (IP pública Azure / named tunnel).

---

## PASO 8 — Prueba de carga (equipo aún offline)

```powershell
$env:BASE_URL="http://127.0.0.1:3001"; $env:EMAIL="asesor@uphone.local"; $env:PASSWORD="asesor123"
k6 run scripts/load/k6-asesores.js                          # capacidad
$env:SCENARIO="login_storm"; k6 run scripts/load/k6-asesores.js   # C4: ahora 429 debe bajar
Remove-Item Env:\SCENARIO
```
> Tras tocar login, espera ~15 min o reinicia el contador antes de reabrir.

---

## PASO 9 — Actualizar PCs cliente (renderer: C1/C2 + Bug 4 UI/WS)
> Sin esto, los fixes de renderer NO toman efecto: la UI de asignar equipos del admin, el aislamiento WS en tiempo real y C1/C2 quedan inactivos (el backend ya aísla por REST).

```powershell
# En el equipo de build (no en la VM):
npm run build        # electron-vite build + electron-builder → instalador NSIS en dist/
```
- Distribuir el instalador nuevo a las **7 PCs** y reinstalar (o vía auto-update si está configurado).
- Orden sugerido: primero la PC del **admin** (para asignar los equipos), luego cada supervisor/asesores.
- Tras reinstalar, el admin asigna `supervisor_id` a los asesores legacy (selector en Gestión de Usuarios).

---

## PASO 10 — Cerrar ventana
- Confirmar health + un login real manual (supervisor: que NO vea otros equipos ni al admin).
- Avisar al equipo / reabrir operación.
- Anotar resultados de la prueba de carga.

---

## 🔙 ROLLBACK (si algo falla en Paso 5–6)

```powershell
pm2 stop <id>
# Restaurar código:
git checkout -- src/main/apiServer.js src/main/database/db.js   # (o copiar los .bak del Paso 3)
Remove-Item src\main\security\rateLimitKeys.js                  # archivo nuevo
# Si la BD quedó tocada (no debería: M-037 es solo índices, no datos):
#   Copy-Item "F:\cobranza\backups\terminal-<stamp>.db" F:\cobranza\data\terminal.db
pm2 start <id>
(Invoke-WebRequest http://localhost:3001/api/health -UseBasicParsing).Content
```
> Los índices (M-037) no borran datos; el rollback de código no requiere tocar la BD salvo corrupción. El backup del Paso 2 es la red de seguridad final junto al snapshot.

---

## Resumen de riesgos
| Riesgo | Mitigación |
|--------|-----------|
| `rateLimitKeys.js` ausente → server no arranca | Paso 4 verifica `require OK` antes de start |
| VM corre `out/` y no se rebuildea | Paso 0 detecta el script path |
| ABI better-sqlite3 | Paso 5c `npm rebuild` |
| URL de túnel rota | Paso 7 redistribuir (o resolver C3) |
| Corrupción BD | Backup Paso 2 + snapshot VM |
