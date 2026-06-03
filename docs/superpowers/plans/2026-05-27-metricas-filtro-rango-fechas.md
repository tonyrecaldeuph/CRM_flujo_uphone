# Filtro por Rango de Fechas en Métricas del Supervisor — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Agregar filtro Desde/Hasta a todas las cards del tab Métricas del supervisor, permitiendo analizar períodos como "20–26 mayo 2026".

**Architecture:** Enfoque B — `opts.fechaFin` opcional en funciones existentes. Cuando no se pasa: `fechaFin = fechaInicio` → `BETWEEN x AND x` ≡ `= x`. Sin breaking changes. Un solo código path para día único y rango.

**Tech Stack:** better-sqlite3 (BETWEEN nativo), React 18 (useState/useRef), Electron IPC, Express REST (multi-PC).

---

## Mapa de archivos

| Archivo | Qué cambia |
|---|---|
| `src/main/database/queries.js` | Nuevo helper `_dateRangeMatch` + 5 funciones con soporte BETWEEN |
| `src/main/ipcHandlers.js` | 2 handlers con arg `fechaFin` |
| `src/main/apiServer.js` | 3 endpoints con `fecha_fin` query param |
| `src/renderer/supervisor/SupervisorPanel.jsx` | Estado Desde/Hasta + filter bar + polling |
| `src/renderer/supervisor/AdvancedMetricsCharts.jsx` | Props + lógica rango + Proyecciones |
| `src/renderer/supervisor/ContactabilidadModal.jsx` | Props `fechaDesde/fechaHasta` |
| `src/renderer/supervisor/VolumenModal.jsx` | Props `fechaDesde/fechaHasta` |
| `src/renderer/supervisor/ContactabilidadDrillDown.jsx` | Prop `fechaFin` |

---

## Task 1: queries.js — helper `_dateRangeMatch` + `getMetricasDia`

**Files:**
- Modify: `src/main/database/queries.js`

- [ ] **Step 1.1: Agregar helper `_dateRangeMatch` después de `_dateLocalMatch` (línea 373)**

Abrir `src/main/database/queries.js`. Después de la línea 373 (cierre de `_dateLocalMatch`), insertar:

```js
// Variante BETWEEN de _dateLocalMatch. Necesita 6 params: [fi, ff, fi, ff, fi, ff]
function _dateRangeMatch(col) {
  return `(substr(${col}, 1, 10) BETWEEN ? AND ?
    OR date(${col}, 'localtime') BETWEEN ? AND ?
    OR date(${col}) BETWEEN ? AND ?)`;
}
```

- [ ] **Step 1.2: Actualizar `getMetricasDia` — encabezado de variables (líneas 1351-1381)**

Reemplazar el bloque de variables iniciales de `getMetricasDia`:

```js
// ANTES (líneas 1356-1381):
const hoy = fecha || _todayLocalISO();
const fechaExplicita = fecha || null;
const campanaId = opts.campanaId || null;
// ...
if (fechaExplicita) {
  carteraFilters.push('date(fecha_asignacion) = ?');
  carteraParams.push(fechaExplicita);
}
```

```js
// DESPUÉS:
const fechaInicio = fecha || _todayLocalISO();
const fechaFin    = opts.fechaFin || fechaInicio;
const campanaId   = opts.campanaId || null;

const campFilterCdr = campanaId
  ? ' AND c.contacto_id IN (SELECT id FROM contactos WHERE campana_id = ?)'
  : '';
const campParam = campanaId ? [campanaId] : [];

const carteraFilters = [];
const carteraParams  = [];
if (campanaId) {
  carteraFilters.push('campana_id = ?');
  carteraParams.push(campanaId);
}
// Stock: usa fechaFin como snapshot de referencia cuando hay filtro explícito.
// BETWEEN x AND x ≡ = x para día único.
if (fecha !== null) {
  carteraFilters.push('date(fecha_asignacion) BETWEEN ? AND ?');
  carteraParams.push(fechaInicio, fechaFin);
}
const carteraExtraSql = carteraFilters.length ? ' AND ' + carteraFilters.join(' AND ') : '';

const cdrDateExpr    = _dateLocalExpr('c.timestamp_inicio');
const evDateExpr     = _dateLocalExpr('e.timestamp');
const evDateExprAlias = _dateLocalExpr('timestamp');
```

- [ ] **Step 1.3: Actualizar queries de flujo en `getMetricasDia` — reemplazar `= ?` con `BETWEEN ? AND ?`**

Buscar y reemplazar CADA ocurrencia del patrón `.get(usuarioId, hoy, ...)` dentro de `getMetricasDia`. El patrón es: cualquier query con `${cdrDateExpr} = ?` o `${evDateExpr} = ?` o `${evDateExprAlias} = ?`.

**Marcaciones CDRs** (línea ~1390):
```js
// ANTES:
`... WHERE c.usuario_id = ? AND ${cdrDateExpr} = ?${campFilterCdr}`
).get(usuarioId, hoy, ...campParam);
// DESPUÉS:
`... WHERE c.usuario_id = ? AND ${cdrDateExpr} BETWEEN ? AND ?${campFilterCdr}`
).get(usuarioId, fechaInicio, fechaFin, ...campParam);
```

**Marcaciones externas con campaña** (línea ~1402):
```js
// ANTES:
`... AND ${evDateExpr} = ?
     AND json_extract(e.metadata, '$.subtipo') = 'DIAL_EXTERNO'
     AND CAST(json_extract(e.metadata, '$.contacto_id') AS INTEGER)
         IN (SELECT id FROM contactos WHERE campana_id = ?)
`).get(usuarioId, hoy, campanaId);
// DESPUÉS:
`... AND ${evDateExpr} BETWEEN ? AND ?
     AND json_extract(e.metadata, '$.subtipo') = 'DIAL_EXTERNO'
     AND CAST(json_extract(e.metadata, '$.contacto_id') AS INTEGER)
         IN (SELECT id FROM contactos WHERE campana_id = ?)
`).get(usuarioId, fechaInicio, fechaFin, campanaId);
```

**Marcaciones externas sin campaña** (línea ~1412):
```js
// ANTES:
`... AND tipo = 'LLAMADA' AND ${evDateExprAlias} = ?
     AND json_extract(metadata, '$.subtipo') = 'DIAL_EXTERNO'
`).get(usuarioId, hoy);
// DESPUÉS:
`... AND tipo = 'LLAMADA' AND ${evDateExprAlias} BETWEEN ? AND ?
     AND json_extract(metadata, '$.subtipo') = 'DIAL_EXTERNO'
`).get(usuarioId, fechaInicio, fechaFin);
```

**Tiempo al aire** (línea ~1421):
```js
// ANTES:
`... WHERE c.usuario_id = ? AND ${cdrDateExpr} = ? AND c.timestamp_fin IS NOT NULL${campFilterCdr}`
).get(usuarioId, hoy, ...campParam);
// DESPUÉS:
`... WHERE c.usuario_id = ? AND ${cdrDateExpr} BETWEEN ? AND ? AND c.timestamp_fin IS NOT NULL${campFilterCdr}`
).get(usuarioId, fechaInicio, fechaFin, ...campParam);
```

**Tiempo muerto** (línea ~1426):
```js
// ANTES:
`... AND ${evDateExprAlias} = ?`
).get(usuarioId, hoy);
// DESPUÉS:
`... AND ${evDateExprAlias} BETWEEN ? AND ?`
).get(usuarioId, fechaInicio, fechaFin);
```

**Promesas de pago** (línea ~1431):
```js
// ANTES:
`... WHERE c.usuario_id = ? AND ${cdrDateExpr} = ? AND t.codigo = 'PMP' ...${campFilterCdr}`
).get(usuarioId, hoy, ...campParam);
// DESPUÉS:
`... WHERE c.usuario_id = ? AND ${cdrDateExpr} BETWEEN ? AND ? AND t.codigo = 'PMP' ...${campFilterCdr}`
).get(usuarioId, fechaInicio, fechaFin, ...campParam);
```

**Pagos recaudados** (línea ~1436):
```js
// ANTES:
`... WHERE c.usuario_id = ? AND ${cdrDateExpr} = ? AND t.codigo IN ('PAGO_REAL', ...) ...${campFilterCdr}`
).get(usuarioId, hoy, ...campParam);
// DESPUÉS:
`... WHERE c.usuario_id = ? AND ${cdrDateExpr} BETWEEN ? AND ? AND t.codigo IN ('PAGO_REAL', ...) ...${campFilterCdr}`
).get(usuarioId, fechaInicio, fechaFin, ...campParam);
```

- [ ] **Step 1.4: Actualizar queries de compromisos en `getMetricasDia` (líneas ~1445-1456)**

El `_compExistsAg` usa `= ?` para agendamientos. Cambiar a BETWEEN:

```js
// ANTES:
const _compExistsAg = `EXISTS (SELECT 1 FROM agendamientos ag WHERE ag.contacto_id = c.contacto_id AND ag.asesor_id = c.usuario_id AND (substr(ag.fecha_hora,1,10) = ? OR date(ag.fecha_hora) = ?) AND ag.estado != 'cancelado')`;
const compCumplidos = db.prepare(
  `... AND (${cdrDateExpr} = ? OR ${_compExistsAg})${campFilterCdr}`
).get(usuarioId, hoy, hoy, hoy, ...campParam);

// DESPUÉS:
const _compExistsAg = `EXISTS (SELECT 1 FROM agendamientos ag WHERE ag.contacto_id = c.contacto_id AND ag.asesor_id = c.usuario_id AND (substr(ag.fecha_hora,1,10) BETWEEN ? AND ? OR date(ag.fecha_hora) BETWEEN ? AND ?) AND ag.estado != 'cancelado')`;
const compCumplidos = db.prepare(
  `... AND (${cdrDateExpr} BETWEEN ? AND ? OR ${_compExistsAg})${campFilterCdr}`
).get(usuarioId, fechaInicio, fechaFin, fechaInicio, fechaFin, fechaInicio, fechaFin, ...campParam);
// Params: userId | fi,ff (cdrDateExpr) | fi,ff,fi,ff (_compExistsAg) | ...campParam

const compIncumplidos = db.prepare(
  `... AND (${cdrDateExpr} BETWEEN ? AND ? OR ${_compExistsAg})${campFilterCdr}`
).get(usuarioId, fechaInicio, fechaFin, fechaInicio, fechaFin, fechaInicio, fechaFin, ...campParam);

const compReagendados = db.prepare(
  `... AND (${cdrDateExpr} BETWEEN ? AND ? OR ${_compExistsAg})${campFilterCdr}`
).get(usuarioId, fechaInicio, fechaFin, fechaInicio, fechaFin, fechaInicio, fechaFin, ...campParam);
```

- [ ] **Step 1.5: Actualizar queries de contactabilidad por categoría en `getMetricasDia` (líneas ~1474-1505)**

Mismo patrón `= ?` → `BETWEEN ? AND ?` para: `contactosEfectivos`, `cdrsTotal`, `cdrsNeutros`, `cdrsNoContactados`, `cdrsSinTipificar`:

```js
// Patrón para cada uno (reemplazar hoy por fechaInicio, fechaFin):
// ANTES: `... AND ${cdrDateExpr} = ?${campFilterCdr}`).get(usuarioId, hoy, ...campParam);
// DESPUÉS: `... AND ${cdrDateExpr} BETWEEN ? AND ?${campFilterCdr}`).get(usuarioId, fechaInicio, fechaFin, ...campParam);
```

- [ ] **Step 1.6: Actualizar queries de monto y acciones rápidas en `getMetricasDia` (líneas ~1508-1565)**

**montoPrometido** (línea ~1512):
```js
// ANTES: AND ${cdrDateExpr} = ? ... ).get(usuarioId, hoy, ...campParam);
// DESPUÉS: AND ${cdrDateExpr} BETWEEN ? AND ? ... ).get(usuarioId, fechaInicio, fechaFin, ...campParam);
```

**montoRecaudado** (línea ~1523): mismo patrón.

**acciones rápidas** `accCount` (línea ~1558):
```js
// ANTES:
`... AND ${evDateExprAlias} = ?
   AND json_extract(metadata, '$.canal') = ?${extraWhere}
`).get(usuarioId, hoy, canal, ...extraParams)
// DESPUÉS:
`... AND ${evDateExprAlias} BETWEEN ? AND ?
   AND json_extract(metadata, '$.canal') = ?${extraWhere}
`).get(usuarioId, fechaInicio, fechaFin, canal, ...extraParams)
```

- [ ] **Step 1.7: Verificar manualmente**

Abrir la app con `npm run dev`. Ir a tab Métricas. Sin cambiar filtros — datos deben verse igual que antes (ambas fechas iguales → BETWEEN x AND x ≡ = x).

- [ ] **Step 1.8: Commit**

```bash
git add src/main/database/queries.js
git commit -m "feat(queries): soporte BETWEEN en getMetricasDia para rango de fechas"
```

---

## Task 2: queries.js — `getDetalleContactabilidad`, `getPagosVerificadosPorAsesor`, `getCompromisosEquipo`

**Files:**
- Modify: `src/main/database/queries.js`

- [ ] **Step 2.1: Actualizar `getDetalleContactabilidad` — agregar param `fechaFin` (línea 1830)**

```js
// ANTES:
function getDetalleContactabilidad(fecha = null, asesorId = null, campanaId = null) {
  // ...
  if (fecha) { where += ` AND date(${horaInicio}) = ?`; params.push(fecha); }

// DESPUÉS:
function getDetalleContactabilidad(fecha = null, asesorId = null, campanaId = null, fechaFin = null) {
  // ...
  const fi = fecha;
  const ff = fechaFin || fi;
  if (fi) {
    where += ` AND date(${horaInicio}) BETWEEN ? AND ?`;
    params.push(fi, ff);
  }
```

- [ ] **Step 2.2: Actualizar `getPagosVerificadosPorAsesor` — agregar param `fechaFin` (línea 1740)**

```js
// ANTES:
function getPagosVerificadosPorAsesor(fecha = null, campanaId = null) {
  const db = getDb();
  const f = fecha || _todayLocalISO();
  // ...
  const dateExpr = _dateLocalMatch(dateCol);
  const params = [f, f, f];

// DESPUÉS:
function getPagosVerificadosPorAsesor(fecha = null, campanaId = null, fechaFin = null) {
  const db = getDb();
  const fi = fecha || _todayLocalISO();
  const ff = fechaFin || fi;
  // ...
  const dateExpr = _dateRangeMatch(dateCol);
  const params = [fi, ff, fi, ff, fi, ff];  // 6 params para _dateRangeMatch
```

También actualizar el campFilter params más abajo:
```js
// La línea que hace params.push(campanaId) permanece igual — solo cambian los 3 iniciales.
```

- [ ] **Step 2.3: Actualizar `getCompromisosEquipo` — usar `_dateRangeMatch` y rango en agendamientos (línea 1611)**

```js
// ANTES:
function getCompromisosEquipo(fecha = null, asesorId = null, opts = {}) {
  const db = getDb();
  const f = fecha || _todayLocalISO();
  // ...
  const params = [f, f, f, f, f, f, f, ...codigos];
  let where = `(${_dateLocalMatch(horaCol)} OR EXISTS (
    SELECT 1 FROM agendamientos ag
    WHERE ag.contacto_id = c.contacto_id
      AND ag.asesor_id   = c.usuario_id
      AND (substr(ag.fecha_hora, 1, 10) = ? OR date(ag.fecha_hora) = ?)
      AND ag.estado != 'cancelado'
  ) OR (c.resultado = 'INCUMP' AND EXISTS (
    SELECT 1 FROM agendamientos ag
    WHERE ag.contacto_id = c.contacto_id
      AND ag.asesor_id   = c.usuario_id
      AND (substr(ag.fecha_hora, 1, 10) = ? OR date(ag.fecha_hora) = ?)
  )))`;

// DESPUÉS:
function getCompromisosEquipo(fecha = null, asesorId = null, opts = {}) {
  const db = getDb();
  const fi = fecha || _todayLocalISO();
  const ff = opts.fechaFin || fi;
  // ...
  // _dateRangeMatch = 6 params; cada EXISTS con BETWEEN = 4 params. Total: 6+4+4 = 14
  const params = [fi, ff, fi, ff, fi, ff,  // _dateRangeMatch
                  fi, ff, fi, ff,           // primer EXISTS
                  fi, ff, fi, ff,           // segundo EXISTS
                  ...codigos];
  let where = `(${_dateRangeMatch(horaCol)} OR EXISTS (
    SELECT 1 FROM agendamientos ag
    WHERE ag.contacto_id = c.contacto_id
      AND ag.asesor_id   = c.usuario_id
      AND (substr(ag.fecha_hora, 1, 10) BETWEEN ? AND ? OR date(ag.fecha_hora) BETWEEN ? AND ?)
      AND ag.estado != 'cancelado'
  ) OR (c.resultado = 'INCUMP' AND EXISTS (
    SELECT 1 FROM agendamientos ag
    WHERE ag.contacto_id = c.contacto_id
      AND ag.asesor_id   = c.usuario_id
      AND (substr(ag.fecha_hora, 1, 10) BETWEEN ? AND ? OR date(ag.fecha_hora) BETWEEN ? AND ?)
  )))`;
```

- [ ] **Step 2.4: Verificar en consola de Node que las funciones compilan sin error**

```bash
cd C:\Users\HP\Desktop\DESARROLLOS_UPHONE\terminal-cobranza
node -e "const q = require('./src/main/database/queries.js'); console.log('OK');"
```
Resultado esperado: `OK` (sin stack trace).

- [ ] **Step 2.5: Commit**

```bash
git add src/main/database/queries.js
git commit -m "feat(queries): fechaFin en getDetalleContactabilidad, getPagosVerificados, getCompromisosEquipo"
```

---

## Task 3: ipcHandlers.js + apiServer.js

**Files:**
- Modify: `src/main/ipcHandlers.js`
- Modify: `src/main/apiServer.js`

- [ ] **Step 3.1: Actualizar handler `db:getDetalleContactabilidad` (línea 463)**

```js
// ANTES:
ipcMain.handle('db:getDetalleContactabilidad', async (event, fecha, asesorId, campanaId) =>
  getDetalleContactabilidad(fecha || null, asesorId || null, campanaId || null)
);

// DESPUÉS:
ipcMain.handle('db:getDetalleContactabilidad', async (event, fecha, asesorId, campanaId, fechaFin) =>
  getDetalleContactabilidad(fecha || null, asesorId || null, campanaId || null, fechaFin || null)
);
```

- [ ] **Step 3.2: Actualizar handler `db:getPagosVerificadosPorAsesor` (línea 466)**

```js
// ANTES:
ipcMain.handle('db:getPagosVerificadosPorAsesor', async (event, fecha, campanaId) =>
  getPagosVerificadosPorAsesor(fecha || null, campanaId || null)
);

// DESPUÉS:
ipcMain.handle('db:getPagosVerificadosPorAsesor', async (event, fecha, campanaId, fechaFin) =>
  getPagosVerificadosPorAsesor(fecha || null, campanaId || null, fechaFin || null)
);
```

- [ ] **Step 3.3: Actualizar endpoint `GET /api/pagos-verificados` (línea ~337)**

```js
// ANTES:
app.get('/api/pagos-verificados', requireAuth, requireSupervisor, (req, res) => {
  try {
    const fecha     = req.query.fecha      || null;
    const campanaId = req.query.campana_id ? parseInt(req.query.campana_id) : null;
    res.json(getPagosVerificadosPorAsesor(fecha, campanaId));

// DESPUÉS:
app.get('/api/pagos-verificados', requireAuth, requireSupervisor, (req, res) => {
  try {
    const fecha     = req.query.fecha      || null;
    const campanaId = req.query.campana_id ? parseInt(req.query.campana_id) : null;
    const fechaFin  = req.query.fecha_fin  || null;
    res.json(getPagosVerificadosPorAsesor(fecha, campanaId, fechaFin));
```

- [ ] **Step 3.4: Actualizar endpoint `GET /api/metricas-equipo` (línea ~495)**

```js
// ANTES:
app.get('/api/metricas-equipo', requireAuth, requireSupervisor, (req, res) => {
  try {
    res.json(getMetricasEquipo());

// DESPUÉS:
app.get('/api/metricas-equipo', requireAuth, requireSupervisor, (req, res) => {
  try {
    const fecha     = req.query.fecha      || null;
    const campanaId = req.query.campana_id ? parseInt(req.query.campana_id) : null;
    const fechaFin  = req.query.fecha_fin  || null;
    const opts = {};
    if (campanaId) opts.campanaId = campanaId;
    if (fechaFin)  opts.fechaFin  = fechaFin;
    res.json(getMetricasEquipo(fecha, opts));
```

- [ ] **Step 3.5: Actualizar endpoint `GET /api/compromisos-equipo` (línea ~503)**

```js
// ANTES:
app.get('/api/compromisos-equipo', requireAuth, requireSupervisor, (req, res) => {
  try {
    const fecha    = req.query.fecha     || null;
    const asesorId = req.query.asesor_id ? parseInt(req.query.asesor_id) : null;
    res.json(getCompromisosEquipo(fecha, asesorId));

// DESPUÉS:
app.get('/api/compromisos-equipo', requireAuth, requireSupervisor, (req, res) => {
  try {
    const fecha    = req.query.fecha     || null;
    const asesorId = req.query.asesor_id ? parseInt(req.query.asesor_id) : null;
    const fechaFin = req.query.fecha_fin || null;
    const opts = fechaFin ? { fechaFin } : {};
    res.json(getCompromisosEquipo(fecha, asesorId, opts));
```

- [ ] **Step 3.6: Agregar import de `getDetalleContactabilidad` a apiServer.js si falta**

Verificar que la línea de imports incluye `getDetalleContactabilidad`. Si no, agregar. Buscar:
```js
grep -n "getDetalleContactabilidad" src/main/apiServer.js
```
Si no aparece, no hay endpoint REST para ese — no es necesario agregarlo (se usa solo por IPC en modo Electron).

- [ ] **Step 3.7: Commit**

```bash
git add src/main/ipcHandlers.js src/main/apiServer.js
git commit -m "feat(ipc,api): handlers y endpoints aceptan fechaFin para rango de fechas"
```

---

## Task 4: SupervisorPanel.jsx — estado, barra de filtros, polling

**Files:**
- Modify: `src/renderer/supervisor/SupervisorPanel.jsx`

- [ ] **Step 4.1: Reemplazar estado `metricasFiltroFecha` con `metricasFiltroDesde` + `metricasFiltroHasta` (líneas 49-57)**

```js
// ANTES (líneas 49-57):
const [metricasFiltroFecha, setMetricasFiltroFecha] = useState('');
const [metricasFiltroCampana, setMetricasFiltroCampana] = useState('');
const [metricasEquipoFiltradas, setMetricasEquipoFiltradas] = useState(null);
const metricasFiltroFechaRef   = useRef('');
const metricasFiltroCampanaRef = useRef('');
// ...
useEffect(() => { metricasFiltroFechaRef.current   = metricasFiltroFecha;   }, [metricasFiltroFecha]);
useEffect(() => { metricasFiltroCampanaRef.current = metricasFiltroCampana; }, [metricasFiltroCampana]);

// DESPUÉS:
const [metricasFiltroDesde,    setMetricasFiltroDesde]    = useState('');
const [metricasFiltroHasta,    setMetricasFiltroHasta]    = useState('');
const [metricasFiltroCampana,  setMetricasFiltroCampana]  = useState('');
const [metricasEquipoFiltradas, setMetricasEquipoFiltradas] = useState(null);
const metricasFiltroDesdeRef   = useRef('');
const metricasFiltroHastaRef   = useRef('');
const metricasFiltroCampanaRef = useRef('');
// ...
useEffect(() => { metricasFiltroDesdeRef.current   = metricasFiltroDesde;   }, [metricasFiltroDesde]);
useEffect(() => { metricasFiltroHastaRef.current   = metricasFiltroHasta;   }, [metricasFiltroHasta]);
useEffect(() => { metricasFiltroCampanaRef.current = metricasFiltroCampana; }, [metricasFiltroCampana]);
```

- [ ] **Step 4.2: Actualizar `cargarMetricasEquipoFiltradas` (líneas 140-151)**

```js
// ANTES:
const cargarMetricasEquipoFiltradas = useCallback(async (fecha, campanaId) => {
  const hayFiltro = fecha || campanaId;
  if (!hayFiltro) { setMetricasEquipoFiltradas(null); return; }
  try {
    const opts = campanaId ? { campanaId: Number(campanaId) } : {};
    const r = await window.api.invoke('db:getMetricasEquipo', fecha || null, opts);
    setMetricasEquipoFiltradas(r);
  } catch (err) {
    console.error('[METRICAS_FILTRO]', err);
    setMetricasEquipoFiltradas(null);
  }
}, []);

// DESPUÉS:
const cargarMetricasEquipoFiltradas = useCallback(async (desde, hasta, campanaId) => {
  const hayFiltro = desde || campanaId;
  if (!hayFiltro) { setMetricasEquipoFiltradas(null); return; }
  try {
    const opts = {};
    if (campanaId) opts.campanaId = Number(campanaId);
    if (hasta && hasta !== desde) opts.fechaFin = hasta;
    const r = await window.api.invoke('db:getMetricasEquipo', desde || null, opts);
    setMetricasEquipoFiltradas(r);
  } catch (err) {
    console.error('[METRICAS_FILTRO]', err);
    setMetricasEquipoFiltradas(null);
  }
}, []);
```

- [ ] **Step 4.3: Actualizar el bloque de polling (líneas ~298-306)**

```js
// ANTES:
const fFecha = metricasFiltroFechaRef.current   || null;
const fCamp  = metricasFiltroCampanaRef.current || null;
cargarMetricasValidacion(fFecha, fCamp);
if (fFecha || fCamp) {
  cargarMetricasEquipoFiltradas(fFecha, fCamp);
}

// DESPUÉS:
const fDesde = metricasFiltroDesdeRef.current   || null;
const fHasta = metricasFiltroHastaRef.current   || null;
const fCamp  = metricasFiltroCampanaRef.current || null;
cargarMetricasValidacion(fDesde, fCamp);
if (fDesde || fCamp) {
  cargarMetricasEquipoFiltradas(fDesde, fHasta, fCamp);
}
```

- [ ] **Step 4.4: Actualizar `useEffect` de cambio de filtros (líneas 329-332)**

```js
// ANTES:
useEffect(() => {
  if (activePage !== 'metricas') return;
  cargarMetricasEquipoFiltradas(metricasFiltroFecha || null, metricasFiltroCampana || null);
}, [activePage, metricasFiltroFecha, metricasFiltroCampana, cargarMetricasEquipoFiltradas]);

// DESPUÉS:
useEffect(() => {
  if (activePage !== 'metricas') return;
  cargarMetricasEquipoFiltradas(metricasFiltroDesde || null, metricasFiltroHasta || null, metricasFiltroCampana || null);
}, [activePage, metricasFiltroDesde, metricasFiltroHasta, metricasFiltroCampana, cargarMetricasEquipoFiltradas]);
```

- [ ] **Step 4.5: Actualizar `useEffect` de activePage (línea ~321)**

```js
// ANTES:
cargarMetricasValidacion(metricasFiltroFecha || null, metricasFiltroCampana || null);

// DESPUÉS:
cargarMetricasValidacion(metricasFiltroDesde || null, metricasFiltroCampana || null);
```

- [ ] **Step 4.6: Actualizar `hayFiltroMet` y helper de handler de "Limpiar" en `renderTabMetricas` (línea ~817)**

```js
// ANTES:
const hayFiltroMet = !!(metricasFiltroFecha || metricasFiltroCampana);

// DESPUÉS:
const hayFiltroMet = !!(metricasFiltroDesde || metricasFiltroCampana);
```

- [ ] **Step 4.7: Reemplazar la barra de filtros en `renderTabMetricas` (líneas ~837-895)**

Reemplazar el bloque completo del input "Día" + botón HOY:

```jsx
{/* Barra de filtros */}
<div style={{
  display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap',
  padding: '10px 14px', marginBottom: 12, borderRadius: 8,
  background: 'rgba(255,255,255,0.03)', border: '1px solid rgba(255,255,255,0.06)',
}}>
  <span style={{ fontSize: 10, fontWeight: 700, opacity: 0.6, textTransform: 'uppercase', letterSpacing: 0.5 }}>
    <span className="material-symbols-outlined" style={{ fontSize: 13, verticalAlign: 'middle', marginRight: 4 }}>filter_alt</span>
    Filtrar Métricas
  </span>
  {/* Desde */}
  <div style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
    <span style={{ fontSize: 10, opacity: 0.5 }}>Desde</span>
    <input
      type="date"
      value={metricasFiltroDesde}
      onChange={(e) => {
        const val = e.target.value;
        setMetricasFiltroDesde(val);
        // Si Hasta está vacío o es anterior al nuevo Desde, igualarlo
        if (!metricasFiltroHasta || metricasFiltroHasta < val) {
          setMetricasFiltroHasta(val);
        }
      }}
      style={{
        padding: '5px 8px', fontSize: 11, colorScheme: 'dark',
        background: 'rgba(0,0,0,0.25)', border: '1px solid rgba(255,255,255,0.08)',
        borderRadius: 6, color: 'inherit', outline: 'none',
      }}
    />
  </div>
  {/* Hasta */}
  <div style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
    <span style={{ fontSize: 10, opacity: 0.5 }}>Hasta</span>
    <input
      type="date"
      value={metricasFiltroHasta}
      min={metricasFiltroDesde || undefined}
      onChange={(e) => setMetricasFiltroHasta(e.target.value)}
      style={{
        padding: '5px 8px', fontSize: 11, colorScheme: 'dark',
        background: 'rgba(0,0,0,0.25)', border: '1px solid rgba(255,255,255,0.08)',
        borderRadius: 6, color: 'inherit', outline: 'none',
      }}
    />
  </div>
  <button
    onClick={() => { setMetricasFiltroDesde(todayLocalISO()); setMetricasFiltroHasta(todayLocalISO()); }}
    style={{
      padding: '4px 8px', fontSize: 9, fontWeight: 700,
      background: 'rgba(0,230,118,0.1)', border: '1px solid rgba(0,230,118,0.3)',
      color: 'var(--color-primary)', borderRadius: 6, cursor: 'pointer',
    }}
  >HOY</button>
  {/* Campaña */}
  <div style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
    <span style={{ fontSize: 10, opacity: 0.5 }}>Campaña</span>
    <select
      value={metricasFiltroCampana}
      onChange={(e) => setMetricasFiltroCampana(e.target.value)}
      style={{
        padding: '5px 8px', fontSize: 11,
        background: 'rgba(0,0,0,0.25)', border: '1px solid rgba(255,255,255,0.08)',
        borderRadius: 6, color: 'inherit', outline: 'none', minWidth: 140,
      }}
    >
      <option value="">Todas</option>
      {campanasDisponibles.map(c => (
        <option key={c.id} value={c.id}>{c.nombre}</option>
      ))}
    </select>
  </div>
  {hayFiltroMet && (
    <button
      onClick={() => { setMetricasFiltroDesde(''); setMetricasFiltroHasta(''); setMetricasFiltroCampana(''); }}
      style={{
        padding: '5px 10px', fontSize: 10, background: 'rgba(255,80,80,0.1)',
        border: '1px solid rgba(255,80,80,0.25)', color: '#ff8080',
        borderRadius: 6, cursor: 'pointer', display: 'flex', alignItems: 'center', gap: 3,
      }}
    >
      <span className="material-symbols-outlined" style={{ fontSize: 13 }}>filter_alt_off</span>
      Limpiar
    </button>
  )}
  {hayFiltroMet && (
    <div style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 8 }}>
      <span style={{ fontSize: 9, opacity: 0.55, fontStyle: 'italic' }}>
        {metricasFiltroDesde && metricasFiltroHasta && metricasFiltroDesde !== metricasFiltroHasta
          ? `Filtrando: ${metricasFiltroDesde} → ${metricasFiltroHasta}`
          : metricasFiltroDesde
            ? `Filtrando: ${metricasFiltroDesde}`
            : ''
        }
        {metricasFiltroCampana && ` · campaña #${metricasFiltroCampana}`}
      </span>
    </div>
  )}
</div>
```

- [ ] **Step 4.8: Actualizar props de `AdvancedMetricsCharts` (línea ~904-912)**

```jsx
// ANTES:
<AdvancedMetricsCharts
  metricas={metricas}
  metricasEquipo={metricasParaMostrar}
  asesores={asesores}
  filtroFecha={metricasFiltroFecha || null}
  filtroCampana={metricasFiltroCampana || null}
  onOpenContactabilidad={() => setShowContactModal(true)}
  onOpenVolumen={() => setShowVolumenModal(true)}
/>

// DESPUÉS:
<AdvancedMetricsCharts
  metricas={metricas}
  metricasEquipo={metricasParaMostrar}
  asesores={asesores}
  filtroFechaDesde={metricasFiltroDesde || null}
  filtroFechaHasta={metricasFiltroHasta || null}
  filtroCampana={metricasFiltroCampana || null}
  onOpenContactabilidad={() => setShowContactModal(true)}
  onOpenVolumen={() => setShowVolumenModal(true)}
/>
```

- [ ] **Step 4.9: Actualizar props de ContactabilidadModal (línea ~1384-1395)**

```jsx
// ANTES:
<ContactabilidadModal
  fecha={metricasFiltroFecha || null}
  campanaId={metricasFiltroCampana ? Number(metricasFiltroCampana) : null}
  asesores={asesores}
  campanas={campanasDisponibles}
  onFiltersChange={(fecha, campanaId) => {
    setMetricasFiltroFecha(fecha || '');
    setMetricasFiltroCampana(campanaId ? String(campanaId) : '');
  }}
  onClose={() => setShowContactModal(false)}
/>

// DESPUÉS:
<ContactabilidadModal
  fechaDesde={metricasFiltroDesde || null}
  fechaHasta={metricasFiltroHasta || null}
  campanaId={metricasFiltroCampana ? Number(metricasFiltroCampana) : null}
  asesores={asesores}
  campanas={campanasDisponibles}
  onFiltersChange={(desde, hasta, campanaId) => {
    setMetricasFiltroDesde(desde || '');
    setMetricasFiltroHasta(hasta || desde || '');
    setMetricasFiltroCampana(campanaId ? String(campanaId) : '');
  }}
  onClose={() => setShowContactModal(false)}
/>
```

- [ ] **Step 4.10: Actualizar props de VolumenModal (línea ~1399-1411)**

```jsx
// ANTES:
<VolumenModal
  fecha={metricasFiltroFecha || null}
  campanaId={metricasFiltroCampana ? Number(metricasFiltroCampana) : null}
  asesores={asesores}
  campanas={campanasDisponibles}
  onFiltersChange={(fecha, campanaId) => {
    setMetricasFiltroFecha(fecha || '');
    setMetricasFiltroCampana(campanaId ? String(campanaId) : '');
  }}
  onClose={() => setShowVolumenModal(false)}
/>

// DESPUÉS:
<VolumenModal
  fechaDesde={metricasFiltroDesde || null}
  fechaHasta={metricasFiltroHasta || null}
  campanaId={metricasFiltroCampana ? Number(metricasFiltroCampana) : null}
  asesores={asesores}
  campanas={campanasDisponibles}
  onFiltersChange={(desde, hasta, campanaId) => {
    setMetricasFiltroDesde(desde || '');
    setMetricasFiltroHasta(hasta || desde || '');
    setMetricasFiltroCampana(campanaId ? String(campanaId) : '');
  }}
  onClose={() => setShowVolumenModal(false)}
/>
```

- [ ] **Step 4.11: Actualizar DetalleMetricaModal (línea ~1375-1380)**

```jsx
// ANTES:
<DetalleMetricaModal
  tipo={detalleModal}
  fecha={metricasFiltroFecha || null}
  campanaId={metricasFiltroCampana ? Number(metricasFiltroCampana) : null}
  onClose={() => setDetalleModal(null)}
/>

// DESPUÉS:
<DetalleMetricaModal
  tipo={detalleModal}
  fecha={metricasFiltroDesde || null}
  fechaFin={metricasFiltroHasta || null}
  campanaId={metricasFiltroCampana ? Number(metricasFiltroCampana) : null}
  onClose={() => setDetalleModal(null)}
/>
```

- [ ] **Step 4.12: Verificar que la app compila sin errores de React**

Correr `npm run dev`. Abrir el supervisor. La barra de filtros debe mostrar dos inputs "Desde" / "Hasta" + botón "HOY". Sin filtro → datos igual que antes.

- [ ] **Step 4.13: Commit**

```bash
git add src/renderer/supervisor/SupervisorPanel.jsx
git commit -m "feat(supervisor): filtro Desde/Hasta en barra de Métricas"
```

---

## Task 5: AdvancedMetricsCharts.jsx — props + lógica rango

**Files:**
- Modify: `src/renderer/supervisor/AdvancedMetricsCharts.jsx`

- [ ] **Step 5.1: Actualizar firma del componente y agregar helpers de rango (línea 27)**

```js
// ANTES:
function AdvancedMetricsCharts({ metricas, metricasEquipo, asesores, estadosWS, onOpenContactabilidad, onOpenVolumen, filtroFecha, filtroCampana }) {

// DESPUÉS:
function AdvancedMetricsCharts({ metricas, metricasEquipo, asesores, estadosWS, onOpenContactabilidad, onOpenVolumen, filtroFechaDesde, filtroFechaHasta, filtroCampana }) {
  // Alias para compatibilidad interna
  const filtroDesde = filtroFechaDesde || null;
  const filtroHasta = filtroFechaHasta || filtroFechaDesde || null;
  const esRango = !!(filtroDesde && filtroHasta && filtroDesde !== filtroHasta);
  // Label contextual reutilizable en subtítulos de cards
  const labelFecha = esRango
    ? `del ${filtroDesde} al ${filtroHasta}`
    : filtroDesde ? `el ${filtroDesde}` : 'hoy';
```

- [ ] **Step 5.2: Actualizar `proyEsHoy` para rangos (línea 116)**

```js
// ANTES:
const proyEsHoy = !filtroFecha || filtroFecha === proyHoyStr;

// DESPUÉS:
// Si hay rango de varios días → siempre "histórico" (sin proyección)
// Si hay un solo día → proyectar solo si ese día es hoy
const proyEsHoy = !esRango && (!filtroDesde || filtroDesde === proyHoyStr);
```

- [ ] **Step 5.3: Actualizar el useEffect de `getDetalleContactabilidad` (líneas 159-164)**

```js
// ANTES:
useEffect(() => {
  const camp = filtroCampana ? Number(filtroCampana) : null;
  window.api.invoke('db:getDetalleContactabilidad', filtroFecha || null, null, camp)
    .then(d => setDetalleContact(Array.isArray(d) ? d : []))
    .catch(err => { console.error('[CONTACT_HORA]', err); setDetalleContact([]); });
}, [filtroFecha, filtroCampana]);

// DESPUÉS:
useEffect(() => {
  const camp = filtroCampana ? Number(filtroCampana) : null;
  window.api.invoke('db:getDetalleContactabilidad', filtroDesde || null, null, camp, filtroHasta || null)
    .then(d => setDetalleContact(Array.isArray(d) ? d : []))
    .catch(err => { console.error('[CONTACT_HORA]', err); setDetalleContact([]); });
}, [filtroDesde, filtroHasta, filtroCampana]);
```

- [ ] **Step 5.4: Actualizar el useEffect de Rotación de Cartera para respetar rango global (líneas 46-58)**

Cuando hay rango global (`esRango`) y no hay filtro local de rotación, usar el rango global:

```js
// DESPUÉS del bloque actual de useEffect de rotación, agregar:
// Si el supervisor aplicó un rango global y no hay filtro local de rotación,
// sincronizar con el rango global para que la card Rotación también lo respete.
useEffect(() => {
  const hayFiltroLocal = rotFechaInicio || rotFechaFin || rotCampana;
  if (hayFiltroLocal) return; // filtro local tiene precedencia
  if (!filtroDesde) { setRotDetalle(null); return; } // sin filtro global → datos de prop
  const opts = {};
  if (filtroDesde) opts.fechaInicio = filtroDesde;
  if (filtroHasta) opts.fechaFin    = filtroHasta;
  window.api.invoke('db:getRotacionCarteraPeriodo', opts)
    .then(d => setRotDetalle(Array.isArray(d) ? d : null))
    .catch(() => setRotDetalle(null));
}, [filtroDesde, filtroHasta, rotFechaInicio, rotFechaFin, rotCampana]);
```

- [ ] **Step 5.5: Actualizar card Proyecciones — mostrar totales reales cuando hay rango**

Buscar el JSX de la card Proyecciones (alrededor de línea 987 o cerca del subtítulo de proyecciones). Cambiar el subtítulo:

```jsx
// Buscar donde aparece el texto "Proyección al cierre de jornada" o similar
// y el subtítulo de la card.

// Patrón: reemplazar el subtítulo dinámico que ya detecta "día cerrado":
// El proyEsHoy ya es false cuando esRango=true → proyFactor=1 automáticamente.
// Solo ajustar el texto del subtítulo para el caso rango:

// Agregar antes del subtítulo existente:
const subtituloProy = esRango
  ? `Período ${filtroDesde} → ${filtroHasta} · totales reales acumulados`
  : proyEsHoy
    ? `Proyección al cierre de jornada (${new Date().toLocaleTimeString('es-EC',{hour:'2-digit',minute:'2-digit'})})`
    : `Día cerrado · valores reales finales (sin proyección)`;
```

Luego usar `{subtituloProy}` donde antes estaba el subtítulo dinámico de proyecciones.

- [ ] **Step 5.6: Actualizar labels en cards con `filtroFecha` hardcodeado**

Buscar en el archivo todas las referencias a `filtroFecha` y reemplazar:

```bash
# En terminal, verificar cuántas quedan:
grep -n "filtroFecha" src/renderer/supervisor/AdvancedMetricsCharts.jsx
```

Para cada una que sea un label de texto tipo `filtroFecha ? \`el ${filtroFecha}\` : 'hoy'`, reemplazar por `labelFecha`:

```js
// ANTES: filtroFecha ? `el ${filtroFecha}` : 'hoy'
// DESPUÉS: labelFecha
```

- [ ] **Step 5.7: Verificar visualmente**

Con `npm run dev`:
1. Sin filtro → cards muestran datos actuales, sin cambio
2. Seleccionar Hoy en ambos campos → igual que antes
3. Seleccionar 20/05 → 26/05 → cards muestran totales del período
4. Card Proyecciones con rango → subtítulo dice "Período ... totales reales acumulados", sin barras dashed

- [ ] **Step 5.8: Commit**

```bash
git add src/renderer/supervisor/AdvancedMetricsCharts.jsx
git commit -m "feat(charts): soporte rango fechas en todas las cards de Métricas"
```

---

## Task 6: Modales — ContactabilidadModal, VolumenModal, ContactabilidadDrillDown

**Files:**
- Modify: `src/renderer/supervisor/ContactabilidadModal.jsx`
- Modify: `src/renderer/supervisor/VolumenModal.jsx`
- Modify: `src/renderer/supervisor/ContactabilidadDrillDown.jsx`

- [ ] **Step 6.1: Actualizar `ContactabilidadModal` — firma y fetch (líneas 31-56)**

```js
// ANTES:
export default function ContactabilidadModal({ fecha, campanaId, asesores = [], campanas = [], onFiltersChange, onClose }) {
  // ...
  const [filtroFecha, setFiltroFecha] = useState(fecha || '');
  // ...
  window.api.invoke('db:getDetalleContactabilidad', filtroFecha || null, null, camp)
  // ...
  onFiltersChange(filtroFecha || null, filtroCampana ? Number(filtroCampana) : null);

// DESPUÉS:
export default function ContactabilidadModal({ fechaDesde, fechaHasta, campanaId, asesores = [], campanas = [], onFiltersChange, onClose }) {
  // ...
  const [filtroFecha,    setFiltroFecha]    = useState(fechaDesde || '');
  const [filtroFechaFin, setFiltroFechaFin] = useState(fechaHasta || fechaDesde || '');
  // ...
  window.api.invoke('db:getDetalleContactabilidad', filtroFecha || null, null, camp, filtroFechaFin || null)
  // ...
  onFiltersChange(filtroFecha || null, filtroFechaFin || filtroFecha || null, filtroCampana ? Number(filtroCampana) : null);
```

También agregar en la barra de filtros interna del modal un segundo input "Hasta" junto al "Desde" existente:

```jsx
{/* Agregar junto al input de fecha existente del modal: */}
<input
  type="date"
  value={filtroFechaFin}
  min={filtroFecha || undefined}
  onChange={e => setFiltroFechaFin(e.target.value)}
  style={{ padding: '5px 8px', fontSize: 11, colorScheme: 'dark',
    background: 'rgba(0,0,0,0.25)', border: '1px solid rgba(255,255,255,0.08)',
    borderRadius: 6, color: 'inherit', outline: 'none' }}
/>
```

- [ ] **Step 6.2: Actualizar `VolumenModal` — mismo patrón que ContactabilidadModal**

```js
// ANTES:
export default function VolumenModal({ fecha, campanaId, asesores = [], campanas = [], onFiltersChange, onClose }) {
  const [filtroFecha, setFiltroFecha] = useState(fecha || '');
  // ...
  window.api.invoke('db:getDetalleContactabilidad', filtroFecha || null, null, camp)
  onFiltersChange(filtroFecha || null, filtroCampana ? Number(filtroCampana) : null);

// DESPUÉS:
export default function VolumenModal({ fechaDesde, fechaHasta, campanaId, asesores = [], campanas = [], onFiltersChange, onClose }) {
  const [filtroFecha,    setFiltroFecha]    = useState(fechaDesde || '');
  const [filtroFechaFin, setFiltroFechaFin] = useState(fechaHasta || fechaDesde || '');
  // ...
  window.api.invoke('db:getDetalleContactabilidad', filtroFecha || null, null, camp, filtroFechaFin || null)
  onFiltersChange(filtroFecha || null, filtroFechaFin || filtroFecha || null, filtroCampana ? Number(filtroCampana) : null);
```

Agregar segundo input "Hasta" en la barra de filtros del modal (mismo JSX que en ContactabilidadModal Step 6.1).

- [ ] **Step 6.3: Actualizar `ContactabilidadDrillDown` — agregar prop `fechaFin` (línea 41)**

```js
// ANTES:
export default function ContactabilidadDrillDown({ open, onClose, asesorId, asesorNombre, categoria, fecha, campanaId }) {
  // ...
  window.api.invoke('db:getDetalleContactabilidad', fecha || null, asesorId, campanaId || null)

// DESPUÉS:
export default function ContactabilidadDrillDown({ open, onClose, asesorId, asesorNombre, categoria, fecha, fechaFin, campanaId }) {
  // ...
  window.api.invoke('db:getDetalleContactabilidad', fecha || null, asesorId, campanaId || null, fechaFin || null)
```

También actualizar el `useEffect` deps:
```js
// ANTES:
}, [open, asesorId, categoria, fecha, campanaId]);
// DESPUÉS:
}, [open, asesorId, categoria, fecha, fechaFin, campanaId]);
```

- [ ] **Step 6.4: Pasar `fechaFin` al drill-down desde `AdvancedMetricsCharts`**

En `AdvancedMetricsCharts.jsx`, buscar donde se renderiza `ContactabilidadDrillDown` (línea ~1245):

```jsx
// ANTES:
<ContactabilidadDrillDown
  open={!!drillContact}
  onClose={() => setDrillContact(null)}
  asesorId={drillContact?.asesorId}
  asesorNombre={drillContact?.asesorNombre}
  categoria={drillContact?.categoria}
  fecha={filtroFecha}
  campanaId={filtroCampana}
/>

// DESPUÉS:
<ContactabilidadDrillDown
  open={!!drillContact}
  onClose={() => setDrillContact(null)}
  asesorId={drillContact?.asesorId}
  asesorNombre={drillContact?.asesorNombre}
  categoria={drillContact?.categoria}
  fecha={filtroDesde}
  fechaFin={filtroHasta}
  campanaId={filtroCampana}
/>
```

- [ ] **Step 6.5: Verificar modales con rango**

Con `npm run dev`:
1. Poner filtro Desde 20/05 → Hasta 26/05
2. Hacer click en card Contactabilidad por Hora → modal abre → datos del período acumulado
3. Hacer click en card Volumen → modal abre → datos del período
4. Hacer click en celda de Contactabilidad Cruda → drill-down abre → CDRs del período

- [ ] **Step 6.6: Commit final**

```bash
git add src/renderer/supervisor/ContactabilidadModal.jsx src/renderer/supervisor/VolumenModal.jsx src/renderer/supervisor/ContactabilidadDrillDown.jsx src/renderer/supervisor/AdvancedMetricsCharts.jsx
git commit -m "feat(modales): ContactabilidadModal, VolumenModal y DrillDown soportan rango fechas"
```

---

## Criterios de aceptación finales

1. Sin filtro → comportamiento idéntico al anterior (regresión cero)
2. HOY → ambas fechas en hoy → idéntico al "filtro día único" anterior
3. Rango 20–26 mayo → todas las cards muestran totales acumulados del período
4. Card Proyecciones con rango → muestra totales reales sin barras proyectadas
5. Contactabilidad por Hora / Volumen con rango → acumula todas las horas de los 7 días
6. Mora Base y Asesores Activos → usan fechaFin como referencia
7. Hasta < Desde imposible (input con `min`)
8. Limpiar → vuelve sin filtro
9. Modales (Contactabilidad, Volumen, DrillDown) respetan el rango heredado del panel
