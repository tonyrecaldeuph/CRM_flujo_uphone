# Evolución de Cartera — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Agregar un widget "Evolución de Cartera" con acordeón de 3 paneles (Análisis de Cartera, Clientes No Cobro, Cartera Refinanciada) entre MetricsOverview y AdvancedMetricsCharts en el panel de métricas del supervisor.

**Architecture:** 3 queries nuevas en `queries.js` leen metadata JSON de `contactos` (`DIAS IMPAGO`, `REFINANCIADO`, `VALOR EN MORA`). Cada query acepta `opts = {}` con filtros opcionales. El componente `EvolucionCartera.jsx` usa carga lazy por panel (solo carga cuando está abierto). SupervisorPanel lo monta entre los dos bloques existentes.

**Tech Stack:** better-sqlite3 (sync queries), React 18 (hooks), Electron IPC (ipcMain.handle / window.api.invoke)

---

## Estructura de archivos

| Archivo | Acción |
|---|---|
| `src/main/database/queries.js` | Modificar — agregar 3 funciones + exportarlas |
| `src/main/ipcHandlers.js` | Modificar — agregar 3 handlers IPC |
| `src/renderer/supervisor/EvolucionCartera.jsx` | Crear — nuevo componente |
| `src/renderer/supervisor/SupervisorPanel.jsx` | Modificar — import + render |
| `tests/unit/queries-evolucion-cartera.test.js` | Crear — tests unitarios |

---

## Task 1: Queries backend + tests

**Files:**
- Modify: `src/main/database/queries.js` (al final, antes de `module.exports`)
- Create: `tests/unit/queries-evolucion-cartera.test.js`

### Contexto del codebase

`queries.js` usa `getDb()` para obtener la instancia DB. Cada función sigue el patrón:
```js
function miFunc(opts = {}) {
  const db = getDb();
  // ... preparar params
  return db.prepare(`SELECT ...`).all(...params);
}
```

`fecha_asignacion` y `ya_pago` no están en `schema.sql` base — fueron agregadas por migraciones. Los tests deben usar `ALTER TABLE` para agregarlas.

Los tests usan `better-sqlite3` directamente con DB en memoria — igual que `tests/unit/queries-validacion.test.js`.

---

- [ ] **Step 1: Escribir el test con DB en memoria**

Crear `tests/unit/queries-evolucion-cartera.test.js` con este contenido:

```js
const Database = require('better-sqlite3');
const path = require('path');
const fs = require('fs');

let db;

function buildDb() {
  const d = new Database(':memory:');
  d.pragma('journal_mode = WAL');
  d.pragma('foreign_keys = ON');
  const schema = fs.readFileSync(
    path.resolve(__dirname, '../../src/main/database/schema.sql'), 'utf-8'
  );
  d.exec(schema);
  // Columnas agregadas por migraciones
  d.exec("ALTER TABLE contactos ADD COLUMN fecha_asignacion TEXT");
  d.exec("ALTER TABLE contactos ADD COLUMN ya_pago INTEGER DEFAULT 0");

  const hash = '$2a$10$dummyHashForTestingPurposesOnly1234567890abcdef';
  d.prepare("INSERT INTO usuarios (nombre,email,password_hash,rol) VALUES (?,?,?,'supervisor')").run('Super','sup@t.com',hash);
  d.prepare("INSERT INTO campanas (nombre,supervisor_id,estado,fecha_inicio) VALUES ('C1',1,'activa','2026-01-01')").run();

  // Contacto 1: 20 días impago, sin CDR, sin pago, fecha 2026-05-10
  d.prepare("INSERT INTO contactos (campana_id,telefono,nombre_deudor,cedula,estado_marcacion,intentos_realizados,metadata,fecha_asignacion,ya_pago) VALUES (1,'001','Juan','001','PENDIENTE',0,?,?,0)").run(
    JSON.stringify({ 'DIAS IMPAGO': '20', 'VALOR EN MORA': '100.00', 'REFINANCIADO': '' }), '2026-05-10'
  );
  // Contacto 2: 20 días impago, CON CDR, CON pago, fecha 2026-05-10
  d.prepare("INSERT INTO contactos (campana_id,telefono,nombre_deudor,cedula,estado_marcacion,intentos_realizados,metadata,fecha_asignacion,ya_pago) VALUES (1,'002','Pedro','002','GESTIONADO',1,?,?,1)").run(
    JSON.stringify({ 'DIAS IMPAGO': '20', 'VALOR EN MORA': '200.00', 'REFINANCIADO': '' }), '2026-05-10'
  );
  // Contacto 3: 40 días impago, sin CDR, fecha 2026-05-15
  d.prepare("INSERT INTO contactos (campana_id,telefono,nombre_deudor,cedula,estado_marcacion,intentos_realizados,metadata,fecha_asignacion,ya_pago) VALUES (1,'003','Maria','003','PENDIENTE',0,?,?,0)").run(
    JSON.stringify({ 'DIAS IMPAGO': '40', 'VALOR EN MORA': '300.00', 'REFINANCIADO': '' }), '2026-05-15'
  );
  // Contacto 4: refinanciado, 10 días impago, fecha 2026-05-10
  d.prepare("INSERT INTO contactos (campana_id,telefono,nombre_deudor,cedula,estado_marcacion,intentos_realizados,metadata,fecha_asignacion,ya_pago) VALUES (1,'004','Ana','004','PENDIENTE',0,?,?,0)").run(
    JSON.stringify({ 'DIAS IMPAGO': '10', 'VALOR EN MORA': '50.00', 'REFINANCIADO': 'SI' }), '2026-05-10'
  );
  // Contacto 5: refinanciado, 5 días impago, fecha 2026-05-20
  d.prepare("INSERT INTO contactos (campana_id,telefono,nombre_deudor,cedula,estado_marcacion,intentos_realizados,metadata,fecha_asignacion,ya_pago) VALUES (1,'005','Luis','005','PENDIENTE',0,?,?,0)").run(
    JSON.stringify({ 'DIAS IMPAGO': '5', 'VALOR EN MORA': '80.00', 'REFINANCIADO': 'SI' }), '2026-05-20'
  );

  // CDR para contacto 2 (Pedro)
  d.prepare("INSERT INTO cdrs (contacto_id,usuario_id,timestamp_inicio) VALUES (2,1,'2026-05-10T10:00:00')").run();

  return d;
}

// Funciones bajo test (copiadas/adaptadas de queries.js para test unitario)
function getCarteraAnalisis(d, opts = {}) {
  const { fechaAsig = null, desdeD = 0, hastaD = 30 } = opts;
  const fechaWhere = fechaAsig ? "AND date(ct.fecha_asignacion) = ?" : "";
  const params = [desdeD, hastaD, ...(fechaAsig ? [fechaAsig] : [])];
  return d.prepare(`
    SELECT
      CASE WHEN EXISTS (SELECT 1 FROM cdrs c WHERE c.contacto_id = ct.id)
           THEN 'REALIZADA' ELSE 'NO REALIZADA' END AS gestion,
      COUNT(ct.id) AS num_clientes,
      COALESCE(SUM(CAST(NULLIF(TRIM(json_extract(ct.metadata, '$."VALOR EN MORA"')), '') AS REAL)), 0) AS valor_cobrar,
      COALESCE(SUM(CASE WHEN ct.ya_pago = 1 THEN CAST(NULLIF(TRIM(json_extract(ct.metadata, '$."VALOR EN MORA"')), '') AS REAL) ELSE 0 END), 0) AS suma_pago
    FROM contactos ct
    WHERE CAST(NULLIF(TRIM(json_extract(ct.metadata, '$."DIAS IMPAGO"')), '') AS INTEGER) BETWEEN ? AND ?
    ${fechaWhere}
    GROUP BY gestion ORDER BY gestion
  `).all(...params);
}

function getClientesNoCobro(d, opts = {}) {
  const { fechaAsig = null, minDias = 30 } = opts;
  const fechaWhere = fechaAsig ? "AND date(ct.fecha_asignacion) = ?" : "";
  const params = [minDias, ...(fechaAsig ? [fechaAsig] : [])];
  return d.prepare(`
    SELECT
      CASE WHEN EXISTS (SELECT 1 FROM cdrs c WHERE c.contacto_id = ct.id)
           THEN 'REALIZADA' ELSE 'NO REALIZADA' END AS gestion,
      COUNT(ct.id) AS num_clientes,
      COALESCE(SUM(CAST(NULLIF(TRIM(json_extract(ct.metadata, '$."VALOR EN MORA"')), '') AS REAL)), 0) AS valor_cobrar
    FROM contactos ct
    WHERE CAST(NULLIF(TRIM(json_extract(ct.metadata, '$."DIAS IMPAGO"')), '') AS INTEGER) >= ?
    ${fechaWhere}
    GROUP BY gestion ORDER BY gestion
  `).all(...params);
}

function getCarteraRefinanciada(d, opts = {}) {
  const { fechaAsig = null } = opts;
  const fechaWhere = fechaAsig ? "AND date(ct.fecha_asignacion) = ?" : "";
  const params = [...(fechaAsig ? [fechaAsig] : [])];
  return d.prepare(`
    SELECT
      date(ct.fecha_asignacion) AS fecha_apertura,
      COUNT(ct.id) AS num_clientes,
      COALESCE(SUM(CAST(NULLIF(TRIM(json_extract(ct.metadata, '$."VALOR EN MORA"')), '') AS REAL)), 0) AS valor_cobrar
    FROM contactos ct
    WHERE TRIM(COALESCE(json_extract(ct.metadata, '$."REFINANCIADO"'), '')) != ''
    ${fechaWhere}
    GROUP BY date(ct.fecha_asignacion)
    ORDER BY fecha_apertura DESC
  `).all(...params);
}

beforeEach(() => { db = buildDb(); });

describe('getCarteraAnalisis', () => {
  it('sin filtros devuelve contactos con DIAS IMPAGO 0-30 agrupados por gestión', () => {
    const rows = getCarteraAnalisis(db);
    // Contactos 1,2,4 tienen 20,20,10 días (rango 0-30). Contacto 3 tiene 40 días → excluido.
    // Contacto 2 tiene CDR → REALIZADA. Contactos 1,4 no → NO REALIZADA.
    expect(rows.length).toBe(2);
    const realizada = rows.find(r => r.gestion === 'REALIZADA');
    const noRealizada = rows.find(r => r.gestion === 'NO REALIZADA');
    expect(realizada.num_clientes).toBe(1);
    expect(noRealizada.num_clientes).toBe(2);
  });

  it('con rango 16-30 excluye contacto de 10 días', () => {
    const rows = getCarteraAnalisis(db, { desdeD: 16, hastaD: 30 });
    // Solo contactos 1 y 2 (20 días). Contacto 4 tiene 10 días → excluido.
    const total = rows.reduce((s, r) => s + r.num_clientes, 0);
    expect(total).toBe(2);
  });

  it('suma_pago suma solo contactos con ya_pago=1', () => {
    const rows = getCarteraAnalisis(db);
    const realizada = rows.find(r => r.gestion === 'REALIZADA');
    expect(realizada.suma_pago).toBe(200);
  });

  it('filtro fechaAsig restringe por fecha_asignacion', () => {
    const rows = getCarteraAnalisis(db, { fechaAsig: '2026-05-10' });
    // Solo contactos de 2026-05-10: 1,2,4 (todos en rango 0-30)
    const total = rows.reduce((s, r) => s + r.num_clientes, 0);
    expect(total).toBe(3);
  });
});

describe('getClientesNoCobro', () => {
  it('sin filtros devuelve contactos con DIAS IMPAGO >= 30', () => {
    const rows = getClientesNoCobro(db);
    // Solo contacto 3 (40 días)
    const total = rows.reduce((s, r) => s + r.num_clientes, 0);
    expect(total).toBe(1);
  });

  it('minDias=5 incluye más contactos', () => {
    const rows = getClientesNoCobro(db, { minDias: 5 });
    // Contactos 1(20),2(20),3(40),4(10),5(5) — todos >= 5
    const total = rows.reduce((s, r) => s + r.num_clientes, 0);
    expect(total).toBe(5);
  });
});

describe('getCarteraRefinanciada', () => {
  it('sin filtros agrupa refinanciados por fecha_asignacion', () => {
    const rows = getCarteraRefinanciada(db);
    // Contactos 4 (2026-05-10) y 5 (2026-05-20)
    expect(rows.length).toBe(2);
  });

  it('con fechaAsig filtra a una sola fecha', () => {
    const rows = getCarteraRefinanciada(db, { fechaAsig: '2026-05-10' });
    expect(rows.length).toBe(1);
    expect(rows[0].num_clientes).toBe(1);
    expect(rows[0].valor_cobrar).toBe(50);
  });

  it('contactos sin REFINANCIADO (vacío) no aparecen', () => {
    const rows = getCarteraRefinanciada(db);
    const total = rows.reduce((s, r) => s + r.num_clientes, 0);
    expect(total).toBe(2); // solo Ana y Luis, no Juan/Pedro/Maria
  });
});
```

- [ ] **Step 2: Verificar que los tests fallan**

```bash
npx jest tests/unit/queries-evolucion-cartera.test.js --no-coverage 2>&1 | head -30
```

Esperado: error de módulo o FAIL porque las funciones no existen en queries.js aún.

- [ ] **Step 3: Agregar las 3 funciones en `queries.js`**

Abrir `src/main/database/queries.js`. Localizar la línea `module.exports = {` (línea ~2405). Insertar **antes** de esa línea:

```js
// ═══════════════════════════════════════════════════════════════
// EVOLUCIÓN DE CARTERA
// ═══════════════════════════════════════════════════════════════

function getCarteraAnalisis(opts = {}) {
  const db = getDb();
  const cols = db.prepare("PRAGMA table_info(contactos)").all().map(c => c.name);
  const hasFechaAsig = cols.includes('fecha_asignacion');
  const hasYaPago = cols.includes('ya_pago');

  const { fechaAsig = null, desdeD = 0, hastaD = 30 } = opts;
  const fechaWhere = (hasFechaAsig && fechaAsig) ? "AND date(ct.fecha_asignacion) = ?" : "";
  const params = [desdeD, hastaD, ...(hasFechaAsig && fechaAsig ? [fechaAsig] : [])];

  return db.prepare(`
    SELECT
      CASE WHEN EXISTS (SELECT 1 FROM cdrs c WHERE c.contacto_id = ct.id)
           THEN 'REALIZADA' ELSE 'NO REALIZADA' END AS gestion,
      COUNT(ct.id) AS num_clientes,
      COALESCE(SUM(
        CAST(NULLIF(TRIM(json_extract(ct.metadata, '$."VALOR EN MORA"')), '') AS REAL)
      ), 0) AS valor_cobrar,
      COALESCE(SUM(CASE WHEN ${hasYaPago ? 'ct.ya_pago' : '0'} = 1 THEN
        CAST(NULLIF(TRIM(json_extract(ct.metadata, '$."VALOR EN MORA"')), '') AS REAL)
      ELSE 0 END), 0) AS suma_pago
    FROM contactos ct
    WHERE CAST(NULLIF(TRIM(json_extract(ct.metadata, '$."DIAS IMPAGO"')), '') AS INTEGER)
          BETWEEN ? AND ?
    ${fechaWhere}
    GROUP BY gestion
    ORDER BY gestion
  `).all(...params);
}

function getClientesNoCobro(opts = {}) {
  const db = getDb();
  const cols = db.prepare("PRAGMA table_info(contactos)").all().map(c => c.name);
  const hasFechaAsig = cols.includes('fecha_asignacion');

  const { fechaAsig = null, minDias = 30 } = opts;
  const fechaWhere = (hasFechaAsig && fechaAsig) ? "AND date(ct.fecha_asignacion) = ?" : "";
  const params = [minDias, ...(hasFechaAsig && fechaAsig ? [fechaAsig] : [])];

  return db.prepare(`
    SELECT
      CASE WHEN EXISTS (SELECT 1 FROM cdrs c WHERE c.contacto_id = ct.id)
           THEN 'REALIZADA' ELSE 'NO REALIZADA' END AS gestion,
      COUNT(ct.id) AS num_clientes,
      COALESCE(SUM(
        CAST(NULLIF(TRIM(json_extract(ct.metadata, '$."VALOR EN MORA"')), '') AS REAL)
      ), 0) AS valor_cobrar
    FROM contactos ct
    WHERE CAST(NULLIF(TRIM(json_extract(ct.metadata, '$."DIAS IMPAGO"')), '') AS INTEGER) >= ?
    ${fechaWhere}
    GROUP BY gestion
    ORDER BY gestion
  `).all(...params);
}

function getCarteraRefinanciada(opts = {}) {
  const db = getDb();
  const cols = db.prepare("PRAGMA table_info(contactos)").all().map(c => c.name);
  const hasFechaAsig = cols.includes('fecha_asignacion');

  const { fechaAsig = null } = opts;
  const fechaWhere = (hasFechaAsig && fechaAsig) ? "AND date(ct.fecha_asignacion) = ?" : "";
  const params = [...(hasFechaAsig && fechaAsig ? [fechaAsig] : [])];

  return db.prepare(`
    SELECT
      ${hasFechaAsig ? "date(ct.fecha_asignacion)" : "NULL"} AS fecha_apertura,
      COUNT(ct.id) AS num_clientes,
      COALESCE(SUM(
        CAST(NULLIF(TRIM(json_extract(ct.metadata, '$."VALOR EN MORA"')), '') AS REAL)
      ), 0) AS valor_cobrar
    FROM contactos ct
    WHERE TRIM(COALESCE(json_extract(ct.metadata, '$."REFINANCIADO"'), '')) != ''
    ${fechaWhere}
    GROUP BY ${hasFechaAsig ? "date(ct.fecha_asignacion)" : "1"}
    ORDER BY fecha_apertura DESC
  `).all(...params);
}
```

- [ ] **Step 4: Exportar las 3 funciones en `module.exports`**

En `src/main/database/queries.js`, localizar la línea que contiene `getRotacionCarteraPeriodo,` al final del `module.exports`. Cambiarla a:

```js
  getRotacionCarteraPeriodo,
  // Evolución de Cartera
  getCarteraAnalisis, getClientesNoCobro, getCarteraRefinanciada,
};
```

- [ ] **Step 5: Ejecutar tests y verificar que pasan**

```bash
npx jest tests/unit/queries-evolucion-cartera.test.js --no-coverage
```

Esperado:
```
PASS tests/unit/queries-evolucion-cartera.test.js
  getCarteraAnalisis
    ✓ sin filtros devuelve contactos con DIAS IMPAGO 0-30 agrupados por gestión
    ✓ con rango 16-30 excluye contacto de 10 días
    ✓ suma_pago suma solo contactos con ya_pago=1
    ✓ filtro fechaAsig restringe por fecha_asignacion
  getClientesNoCobro
    ✓ sin filtros devuelve contactos con DIAS IMPAGO >= 30
    ✓ minDias=5 incluye más contactos
  getCarteraRefinanciada
    ✓ sin filtros agrupa refinanciados por fecha_asignacion
    ✓ con fechaAsig filtra a una sola fecha
    ✓ contactos sin REFINANCIADO (vacío) no aparecen

Tests: 9 passed
```

> **Nota sobre NODE_MODULE_VERSION:** Si la versión del node sistema difiere del node de Electron, los tests de better-sqlite3 pueden fallar con `ERR_DLOPEN_FAILED`. En ese caso ejecutar:
> `npx electron tests/unit/queries-evolucion-cartera.test.js` — o ignorar el error de native module y verificar la lógica SQL directamente.

- [ ] **Step 6: Commit**

```bash
git add src/main/database/queries.js tests/unit/queries-evolucion-cartera.test.js
git commit -m "feat(cartera): agregar queries getCarteraAnalisis, getClientesNoCobro, getCarteraRefinanciada"
```

---

## Task 2: Handlers IPC

**Files:**
- Modify: `src/main/ipcHandlers.js`

### Contexto

`ipcHandlers.js` importa funciones de `queries.js` al inicio. Cerca de la línea 15-70 hay un bloque de `require`. Al final del archivo (antes del cierre de la función `registerIpcHandlers` o equivalente) se agregan los nuevos handlers.

- [ ] **Step 1: Agregar imports de las 3 funciones**

En `src/main/ipcHandlers.js`, localizar el bloque de destructuring de queries.js. Buscar la línea que contiene `getRotacionCarteraPeriodo` en el require/destructuring y agregar las 3 nuevas funciones.

Buscar:
```js
  getRotacionCarteraPeriodo,
} = require('./database/queries');
```

Reemplazar con:
```js
  getRotacionCarteraPeriodo,
  getCarteraAnalisis, getClientesNoCobro, getCarteraRefinanciada,
} = require('./database/queries');
```

- [ ] **Step 2: Agregar los 3 handlers IPC**

En `src/main/ipcHandlers.js`, localizar el handler de `validacion:correlacionar` o cualquier handler de la sección de validación. Inmediatamente después del bloque de validación, agregar:

```js
  // ── Evolución de Cartera ─────────────────────────────────
  ipcMain.handle('db:getCarteraAnalisis',     async (_, opts) => getCarteraAnalisis(opts || {}));
  ipcMain.handle('db:getClientesNoCobro',     async (_, opts) => getClientesNoCobro(opts || {}));
  ipcMain.handle('db:getCarteraRefinanciada', async (_, opts) => getCarteraRefinanciada(opts || {}));
```

- [ ] **Step 3: Verificar que la app compila sin errores**

```bash
npx electron . --no-sandbox 2>&1 | head -20
```

Esperado: la app arranca sin `ReferenceError` ni `Cannot find` en los nuevos handlers.

- [ ] **Step 4: Commit**

```bash
git add src/main/ipcHandlers.js
git commit -m "feat(cartera): registrar handlers IPC db:getCarteraAnalisis, db:getClientesNoCobro, db:getCarteraRefinanciada"
```

---

## Task 3: Componente EvolucionCartera.jsx

**Files:**
- Create: `src/renderer/supervisor/EvolucionCartera.jsx`

### Contexto de estilos

La UI usa variables CSS: `var(--color-primary)` (verde). Las cards usan clase `widget-card`. Las tablas siguen el patrón de `Compromisos.jsx`: `fontSize: 11`, `padding: '8px 10px'`, `borderTop: '1px solid rgba(255,255,255,0.04)'`. Inline styles en todos los elementos (no CSS modules).

- [ ] **Step 1: Crear el componente completo**

Crear `src/renderer/supervisor/EvolucionCartera.jsx`:

```jsx
import React, { useState, useEffect } from 'react';

const fmt$ = (n) => {
  if (!n && n !== 0) return '—';
  const v = Number(n);
  if (isNaN(v)) return '—';
  return `$${v.toLocaleString('es-EC', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
};

const inputStyle = {
  padding: '5px 8px', fontSize: 11, colorScheme: 'dark',
  background: 'rgba(0,0,0,0.25)', border: '1px solid rgba(255,255,255,0.08)',
  borderRadius: 6, color: 'inherit', outline: 'none',
};

const th = { padding: '8px 10px', fontSize: 10, fontWeight: 700, opacity: 0.6, textTransform: 'uppercase', letterSpacing: 0.4 };
const td = { padding: '8px 10px', verticalAlign: 'middle', fontSize: 11 };

function AccordionPanel({ title, icon, open, onToggle, children }) {
  return (
    <div style={{ borderTop: '1px solid rgba(255,255,255,0.06)', marginTop: 4 }}>
      <button
        onClick={onToggle}
        style={{
          width: '100%', display: 'flex', alignItems: 'center', gap: 8,
          padding: '10px 14px', background: 'none', border: 'none', color: 'inherit',
          cursor: 'pointer', textAlign: 'left',
        }}
      >
        <span className="material-symbols-outlined" style={{ fontSize: 16, color: 'var(--color-primary)', opacity: 0.8 }}>
          {icon}
        </span>
        <span style={{ fontSize: 12, fontWeight: 700, flex: 1 }}>{title}</span>
        <span
          className="material-symbols-outlined"
          style={{ fontSize: 16, opacity: 0.4, transition: 'transform 0.2s', transform: open ? 'rotate(90deg)' : 'none' }}
        >
          chevron_right
        </span>
      </button>
      {open && (
        <div style={{ padding: '0 14px 14px' }}>
          {children}
        </div>
      )}
    </div>
  );
}

function GestionTable({ data, loading, showPago = false }) {
  if (loading) {
    return (
      <div style={{ padding: '20px 0', textAlign: 'center', opacity: 0.5 }}>
        <span className="material-symbols-outlined" style={{ fontSize: 24 }}>sync</span>
      </div>
    );
  }
  if (!data || data.length === 0) {
    return (
      <div style={{ padding: '20px 0', textAlign: 'center', opacity: 0.4, fontSize: 12 }}>
        Sin datos para los filtros aplicados
      </div>
    );
  }
  const totalClientes = data.reduce((s, r) => s + (r.num_clientes || 0), 0);
  const totalCobrar   = data.reduce((s, r) => s + (r.valor_cobrar || 0), 0);
  const totalPago     = showPago ? data.reduce((s, r) => s + (r.suma_pago || 0), 0) : null;

  return (
    <div style={{ borderRadius: 8, border: '1px solid rgba(255,255,255,0.07)', overflow: 'hidden', marginTop: 10 }}>
      <table style={{ width: '100%', borderCollapse: 'collapse' }}>
        <thead>
          <tr style={{ background: 'rgba(255,255,255,0.04)', textAlign: 'left' }}>
            <th style={th}>Gestión</th>
            <th style={{ ...th, textAlign: 'right' }}>No. Clientes</th>
            <th style={{ ...th, textAlign: 'right' }}>Valor a Cobrar</th>
            {showPago && <th style={{ ...th, textAlign: 'right' }}>Suma Pago</th>}
          </tr>
        </thead>
        <tbody>
          {data.map((r, i) => (
            <tr key={i} style={{ borderTop: '1px solid rgba(255,255,255,0.04)' }}>
              <td style={td}>
                <span style={{
                  fontSize: 9, fontWeight: 700, padding: '2px 6px', borderRadius: 99,
                  background: r.gestion === 'REALIZADA' ? 'rgba(0,230,118,0.15)' : 'rgba(255,152,0,0.15)',
                  color: r.gestion === 'REALIZADA' ? 'var(--color-primary)' : '#ffcc02',
                }}>
                  {r.gestion}
                </span>
              </td>
              <td style={{ ...td, textAlign: 'right', fontWeight: 700 }}>
                {(r.num_clientes || 0).toLocaleString()}
              </td>
              <td style={{ ...td, textAlign: 'right', color: 'var(--color-primary)', fontWeight: 700 }}>
                {fmt$(r.valor_cobrar)}
              </td>
              {showPago && (
                <td style={{ ...td, textAlign: 'right', color: '#64b5f6', fontWeight: 700 }}>
                  {fmt$(r.suma_pago)}
                </td>
              )}
            </tr>
          ))}
        </tbody>
        <tfoot>
          <tr style={{ borderTop: '1px solid rgba(255,255,255,0.1)', background: 'rgba(255,255,255,0.03)' }}>
            <td style={{ ...td, fontWeight: 800, fontSize: 10, opacity: 0.7 }}>TOTAL</td>
            <td style={{ ...td, textAlign: 'right', fontWeight: 800 }}>{totalClientes.toLocaleString()}</td>
            <td style={{ ...td, textAlign: 'right', fontWeight: 800, color: 'var(--color-primary)' }}>{fmt$(totalCobrar)}</td>
            {showPago && <td style={{ ...td, textAlign: 'right', fontWeight: 800, color: '#64b5f6' }}>{fmt$(totalPago)}</td>}
          </tr>
        </tfoot>
      </table>
    </div>
  );
}

function RefinanciadaTable({ data, loading }) {
  if (loading) {
    return (
      <div style={{ padding: '20px 0', textAlign: 'center', opacity: 0.5 }}>
        <span className="material-symbols-outlined" style={{ fontSize: 24 }}>sync</span>
      </div>
    );
  }
  if (!data || data.length === 0) {
    return (
      <div style={{ padding: '20px 0', textAlign: 'center', opacity: 0.4, fontSize: 12 }}>
        Sin datos para los filtros aplicados
      </div>
    );
  }
  const totalClientes = data.reduce((s, r) => s + (r.num_clientes || 0), 0);
  const totalCobrar   = data.reduce((s, r) => s + (r.valor_cobrar || 0), 0);

  return (
    <div style={{ borderRadius: 8, border: '1px solid rgba(255,255,255,0.07)', overflow: 'hidden', marginTop: 10 }}>
      <table style={{ width: '100%', borderCollapse: 'collapse' }}>
        <thead>
          <tr style={{ background: 'rgba(255,255,255,0.04)', textAlign: 'left' }}>
            <th style={th}>Fecha Apertura</th>
            <th style={{ ...th, textAlign: 'right' }}>No. Clientes</th>
            <th style={{ ...th, textAlign: 'right' }}>Valor a Cobrar</th>
          </tr>
        </thead>
        <tbody>
          {data.map((r, i) => (
            <tr key={i} style={{ borderTop: '1px solid rgba(255,255,255,0.04)' }}>
              <td style={{ ...td, fontWeight: 600 }}>{r.fecha_apertura || '—'}</td>
              <td style={{ ...td, textAlign: 'right', fontWeight: 700 }}>
                {(r.num_clientes || 0).toLocaleString()}
              </td>
              <td style={{ ...td, textAlign: 'right', color: 'var(--color-primary)', fontWeight: 700 }}>
                {fmt$(r.valor_cobrar)}
              </td>
            </tr>
          ))}
        </tbody>
        <tfoot>
          <tr style={{ borderTop: '1px solid rgba(255,255,255,0.1)', background: 'rgba(255,255,255,0.03)' }}>
            <td style={{ ...td, fontWeight: 800, fontSize: 10, opacity: 0.7 }}>TOTAL</td>
            <td style={{ ...td, textAlign: 'right', fontWeight: 800 }}>{totalClientes.toLocaleString()}</td>
            <td style={{ ...td, textAlign: 'right', fontWeight: 800, color: 'var(--color-primary)' }}>{fmt$(totalCobrar)}</td>
          </tr>
        </tfoot>
      </table>
    </div>
  );
}

export default function EvolucionCartera() {
  const [openPanels, setOpenPanels] = useState({ analisis: true, noCobro: false, refinanciada: false });

  // Panel 1 — Análisis de Cartera
  const [p1Fecha,  setP1Fecha]  = useState('');
  const [p1Desde,  setP1Desde]  = useState(0);
  const [p1Hasta,  setP1Hasta]  = useState(30);
  const [p1Data,   setP1Data]   = useState([]);
  const [p1Load,   setP1Load]   = useState(false);

  // Panel 2 — Clientes No Cobro
  const [p2Fecha,  setP2Fecha]  = useState('');
  const [p2MinD,   setP2MinD]   = useState(30);
  const [p2Data,   setP2Data]   = useState([]);
  const [p2Load,   setP2Load]   = useState(false);

  // Panel 3 — Cartera Refinanciada
  const [p3Fecha,  setP3Fecha]  = useState('');
  const [p3Data,   setP3Data]   = useState([]);
  const [p3Load,   setP3Load]   = useState(false);

  useEffect(() => {
    if (!openPanels.analisis) return;
    setP1Load(true);
    window.api.invoke('db:getCarteraAnalisis', { fechaAsig: p1Fecha || null, desdeD: Number(p1Desde), hastaD: Number(p1Hasta) })
      .then(d => setP1Data(d || []))
      .catch(() => setP1Data([]))
      .finally(() => setP1Load(false));
  }, [openPanels.analisis, p1Fecha, p1Desde, p1Hasta]);

  useEffect(() => {
    if (!openPanels.noCobro) return;
    setP2Load(true);
    window.api.invoke('db:getClientesNoCobro', { fechaAsig: p2Fecha || null, minDias: Number(p2MinD) })
      .then(d => setP2Data(d || []))
      .catch(() => setP2Data([]))
      .finally(() => setP2Load(false));
  }, [openPanels.noCobro, p2Fecha, p2MinD]);

  useEffect(() => {
    if (!openPanels.refinanciada) return;
    setP3Load(true);
    window.api.invoke('db:getCarteraRefinanciada', { fechaAsig: p3Fecha || null })
      .then(d => setP3Data(d || []))
      .catch(() => setP3Data([]))
      .finally(() => setP3Load(false));
  }, [openPanels.refinanciada, p3Fecha]);

  const toggle = (key) => setOpenPanels(p => ({ ...p, [key]: !p[key] }));

  const filterRow = (children) => (
    <div style={{
      display: 'flex', gap: 10, flexWrap: 'wrap', alignItems: 'center',
      padding: '8px 0', marginBottom: 2,
    }}>
      {children}
    </div>
  );

  const filterLabel = (text) => (
    <span style={{ fontSize: 10, opacity: 0.5 }}>{text}</span>
  );

  return (
    <div className="widget-card" style={{ marginBottom: 16 }}>
      <div className="widget-header" style={{ marginBottom: 4 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <span className="material-symbols-outlined" style={{ fontSize: 20, color: 'var(--color-primary)' }}>trending_up</span>
          <div>
            <span className="text-label" style={{ opacity: 0.5 }}>SUPERVISOR · ANÁLISIS</span>
            <h3 className="widget-title" style={{ marginTop: 2 }}>Evolución de Cartera</h3>
          </div>
        </div>
      </div>

      {/* ── Panel 1: Análisis de Cartera ── */}
      <AccordionPanel
        title="Análisis de Cartera"
        icon="analytics"
        open={openPanels.analisis}
        onToggle={() => toggle('analisis')}
      >
        {filterRow(<>
          {filterLabel('Fecha apertura')}
          <input type="date" value={p1Fecha} onChange={e => setP1Fecha(e.target.value)} style={inputStyle} />
          {filterLabel('Días impago desde')}
          <input type="number" min="0" value={p1Desde} onChange={e => setP1Desde(e.target.value)} style={{ ...inputStyle, width: 70 }} />
          {filterLabel('hasta')}
          <input type="number" min="0" value={p1Hasta} onChange={e => setP1Hasta(e.target.value)} style={{ ...inputStyle, width: 70 }} />
        </>)}
        <GestionTable data={p1Data} loading={p1Load} showPago />
      </AccordionPanel>

      {/* ── Panel 2: Clientes No Cobro ── */}
      <AccordionPanel
        title="Clientes No Cobro"
        icon="phone_missed"
        open={openPanels.noCobro}
        onToggle={() => toggle('noCobro')}
      >
        {filterRow(<>
          {filterLabel('Fecha apertura')}
          <input type="date" value={p2Fecha} onChange={e => setP2Fecha(e.target.value)} style={inputStyle} />
          {filterLabel('Mínimo días impago')}
          <input type="number" min="0" value={p2MinD} onChange={e => setP2MinD(e.target.value)} style={{ ...inputStyle, width: 70 }} />
        </>)}
        <GestionTable data={p2Data} loading={p2Load} showPago={false} />
      </AccordionPanel>

      {/* ── Panel 3: Cartera Refinanciada ── */}
      <AccordionPanel
        title="Cartera Refinanciada"
        icon="autorenew"
        open={openPanels.refinanciada}
        onToggle={() => toggle('refinanciada')}
      >
        {filterRow(<>
          {filterLabel('Fecha apertura')}
          <input type="date" value={p3Fecha} onChange={e => setP3Fecha(e.target.value)} style={inputStyle} />
        </>)}
        <RefinanciadaTable data={p3Data} loading={p3Load} />
      </AccordionPanel>
    </div>
  );
}
```

- [ ] **Step 2: Verificar que el archivo no tiene errores de sintaxis**

```bash
node --input-type=module < src/renderer/supervisor/EvolucionCartera.jsx 2>&1 | head -5
```

Si hay error de JSX (esperado porque node no parsea JSX), verificar manualmente que no hay llaves sin cerrar ni imports rotos.

- [ ] **Step 3: Commit**

```bash
git add src/renderer/supervisor/EvolucionCartera.jsx
git commit -m "feat(cartera): componente EvolucionCartera con acordeón 3 paneles"
```

---

## Task 4: Integrar en SupervisorPanel

**Files:**
- Modify: `src/renderer/supervisor/SupervisorPanel.jsx` (líneas ~13-19 para import, ~929-935 para render)

- [ ] **Step 1: Agregar el import**

En `src/renderer/supervisor/SupervisorPanel.jsx`, localizar el bloque de imports (líneas 1-22). Agregar después de la línea `import AdvancedMetricsCharts from './AdvancedMetricsCharts';`:

```js
import EvolucionCartera from './EvolucionCartera';
```

- [ ] **Step 2: Renderizar entre MetricsOverview y AdvancedMetricsCharts**

En `SupervisorPanel.jsx`, localizar el bloque (líneas ~929-945):

```jsx
        <MetricsOverview
          metricas={metricasParaMostrar}
          validacion={metricasValidacion}
          onCardClick={(key) => setDetalleModal(key)}
          onNavigate={setActivePage}
        />

        <AdvancedMetricsCharts
```

Reemplazar con:

```jsx
        <MetricsOverview
          metricas={metricasParaMostrar}
          validacion={metricasValidacion}
          onCardClick={(key) => setDetalleModal(key)}
          onNavigate={setActivePage}
        />

        <EvolucionCartera />

        <AdvancedMetricsCharts
```

- [ ] **Step 3: Verificar en la app (Vite dev)**

```bash
npm run dev
```

Navegar al panel Métricas. Verificar:
1. Widget "Evolución de Cartera" aparece entre las cards KPI y los gráficos
2. Panel 1 "Análisis de Cartera" está expandido por defecto
3. Los otros 2 paneles están colapsados
4. Al cambiar filtros de Panel 1, los datos se recargan
5. Al expandir Panel 2 y 3, cargan sus datos
6. Los totales aparecen en el pie de cada tabla
7. Sin datos → mensaje "Sin datos para los filtros aplicados"

- [ ] **Step 4: Commit final**

```bash
git add src/renderer/supervisor/SupervisorPanel.jsx
git commit -m "feat(cartera): integrar EvolucionCartera en página de métricas del supervisor"
```

---

## Self-Review

**Spec coverage:**
- ✅ Panel 1 filtra por DIAS IMPAGO BETWEEN desdeD AND hastaD
- ✅ Panel 2 filtra por DIAS IMPAGO >= minDias (default 30)
- ✅ Panel 3 filtra por REFINANCIADO not null/empty, agrupado por fecha_asignacion
- ✅ FECHA APERTURA opcional en los 3 paneles
- ✅ Carga lazy (useEffect depende de `openPanels.X`)
- ✅ Panel 1 expandido por defecto (`analisis: true`)
- ✅ Filas de total al pie en los 3 paneles
- ✅ Nada existente eliminado
- ✅ fecha_asignacion con PRAGMA guard

**Placeholder scan:** Ninguno encontrado.

**Type consistency:** `opts` con claves `fechaAsig`, `desdeD`, `hastaD`, `minDias` — consistente entre queries, handlers y JSX.
