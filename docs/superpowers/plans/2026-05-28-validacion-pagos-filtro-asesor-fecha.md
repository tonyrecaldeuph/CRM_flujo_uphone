# Validación de Pagos — Filtro Asesor + Fecha (Correlación) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Acotar la correlación de pagos a un asesor específico y una fecha de asignación, eliminando coincidencias erróneas por contratos presentes en múltiples carteras.

**Architecture:** Se añade `opts = { asesorId, fecha }` como segundo parámetro opcional a `correlacionarPagos` en `queries.js`, que extiende dinámicamente el WHERE con `AND ct.asignado_a = ?` y/o `AND date(ct.fecha_asignacion) = ?`. El IPC handler reenvía el segundo argumento. El frontend agrega selector de asesor + input de fecha inline encima del botón Correlacionar, y bloquea la acción hasta que ambos estén completos.

**Tech Stack:** better-sqlite3 (queries.js), Electron IPC (ipcHandlers.js), React 18 (ValidacionPagos.jsx)

---

## Archivos afectados

| Archivo | Tipo |
|---|---|
| `src/main/database/queries.js` | Modificar función `correlacionarPagos` (línea 2080) |
| `src/main/ipcHandlers.js` | Modificar handler `validacion:correlacionar` (línea 471) |
| `src/renderer/supervisor/ValidacionPagos.jsx` | Modificar estado, carga de asesores y sección del botón |
| `tests/unit/queries-validacion.test.js` | Crear nuevo archivo de tests |

---

## Contexto clave antes de empezar

- `fecha_asignacion` NO está en `schema.sql` base — fue agregada por migración. La columna **existe** en la BD en producción. En tests con `:memory:` y el schema base, esa columna **no existe**, por lo que los tests deben agregarla manualmente con `ALTER TABLE contactos ADD COLUMN fecha_asignacion TEXT`.
- `getDb()` es un singleton del proceso Electron. Los tests NO pueden importar `correlacionarPagos` directamente — deben replicar la lógica SQL sobre un `testDb` in-memory.
- Hay un bug preexistente de `NODE_MODULE_VERSION` en el runner de tests (mejor-sqlite3 compilado para Node 121, runner usa 127). Los tests nuevos pueden fallar por esto, no es regresión de este feature.
- `getAsesores()` devuelve `[{ id, nombre, email, rol, estado }]` — usar `a.id` y `a.nombre` en el select.
- La columna `fecha_asignacion` en `contactos` se filtra con `date(ct.fecha_asignacion) = ?` (la fecha ya es ISO `YYYY-MM-DD` pero `date()` garantiza compatibilidad).

---

### Task 1: Backend — `correlacionarPagos` acepta `opts = { asesorId, fecha }`

**Files:**
- Modify: `src/main/database/queries.js:2080`
- Create: `tests/unit/queries-validacion.test.js`

- [ ] **Step 1: Crear test que falla — sin filtro devuelve todos los matches**

Crear `tests/unit/queries-validacion.test.js`:

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
  // fecha_asignacion no está en schema base — agregarla
  d.exec("ALTER TABLE contactos ADD COLUMN fecha_asignacion TEXT");

  const hash = '$2a$10$dummyHashForTestingPurposesOnly1234567890abcdef';
  d.prepare("INSERT INTO usuarios (nombre, email, password_hash, rol) VALUES (?,?,?,'supervisor')").run('Super','sup@t.com',hash);
  d.prepare("INSERT INTO usuarios (nombre, email, password_hash, rol) VALUES (?,?,?,'asesor')").run('Asesor A','a@t.com',hash);
  d.prepare("INSERT INTO usuarios (nombre, email, password_hash, rol) VALUES (?,?,?,'asesor')").run('Asesor B','b@t.com',hash);
  d.prepare("INSERT INTO campanas (nombre, supervisor_id, estado, fecha_inicio) VALUES ('C1',1,'activa','2026-01-01')").run();

  // Contacto 1: Asesor A, asignado 2026-05-20, contrato 1001
  d.prepare("INSERT INTO contactos (campana_id,telefono,nombre_deudor,cedula,asignado_a,estado_marcacion,intentos_realizados,metadata,fecha_asignacion) VALUES (1,'0991','Juan','111',2,'PENDIENTE',0,?,?)").run(
    JSON.stringify({ 'Nº CONTRATO': '1001', EMPRESA: 'SCC' }), '2026-05-20'
  );
  // Contacto 2: Asesor B, asignado 2026-05-20, mismo contrato 1001
  d.prepare("INSERT INTO contactos (campana_id,telefono,nombre_deudor,cedula,asignado_a,estado_marcacion,intentos_realizados,metadata,fecha_asignacion) VALUES (1,'0992','Pedro','222',3,'PENDIENTE',0,?,?)").run(
    JSON.stringify({ 'Nº CONTRATO': '1001', EMPRESA: 'SCC' }), '2026-05-20'
  );
  // Contacto 3: Asesor A, asignado 2026-05-21, contrato diferente 1002
  d.prepare("INSERT INTO contactos (campana_id,telefono,nombre_deudor,cedula,asignado_a,estado_marcacion,intentos_realizados,metadata,fecha_asignacion) VALUES (1,'0993','Maria','333',2,'PENDIENTE',0,?,?)").run(
    JSON.stringify({ 'Nº CONTRATO': '1002', EMPRESA: 'SCC' }), '2026-05-21'
  );

  return d;
}

// Simula el núcleo de correlacionarPagos con opts
function correlacionarSQL(db, contratos, opts = {}) {
  const { asesorId = null, fecha = null } = opts;
  const ph = contratos.map(() => '?').join(',');
  const extraWhere = [
    asesorId ? 'AND ct.asignado_a = ?' : '',
    fecha    ? "AND date(ct.fecha_asignacion) = ?" : '',
  ].join(' ');

  return db.prepare(`
    SELECT ct.id, ct.nombre_deudor, ct.asignado_a, ct.metadata
    FROM contactos ct
    JOIN campanas c ON ct.campana_id = c.id
    LEFT JOIN usuarios u ON ct.asignado_a = u.id
    WHERE CAST(json_extract(ct.metadata, '$."Nº CONTRATO"') AS TEXT) IN (${ph})
    ${extraWhere}
  `).all(...contratos, ...(asesorId ? [asesorId] : []), ...(fecha ? [fecha] : []));
}

beforeEach(() => { db = buildDb(); });

describe('correlacionarPagos — filtros opts', () => {
  it('sin opts devuelve ambos contactos con contrato 1001', () => {
    const rows = correlacionarSQL(db, ['1001']);
    expect(rows).toHaveLength(2);
  });

  it('con asesorId=2 devuelve solo el contacto del Asesor A', () => {
    const rows = correlacionarSQL(db, ['1001'], { asesorId: 2 });
    expect(rows).toHaveLength(1);
    expect(rows[0].asignado_a).toBe(2);
  });

  it('con asesorId=2 y fecha=2026-05-20 devuelve solo contrato 1001 del Asesor A', () => {
    const rows = correlacionarSQL(db, ['1001', '1002'], { asesorId: 2, fecha: '2026-05-20' });
    expect(rows).toHaveLength(1);
    const meta = JSON.parse(rows[0].metadata);
    expect(meta['Nº CONTRATO']).toBe('1001');
  });

  it('con asesorId=2 y fecha=2026-05-21 devuelve solo contrato 1002', () => {
    const rows = correlacionarSQL(db, ['1001', '1002'], { asesorId: 2, fecha: '2026-05-21' });
    expect(rows).toHaveLength(1);
    const meta = JSON.parse(rows[0].metadata);
    expect(meta['Nº CONTRATO']).toBe('1002');
  });

  it('con asesorId inexistente devuelve vacío', () => {
    const rows = correlacionarSQL(db, ['1001'], { asesorId: 999 });
    expect(rows).toHaveLength(0);
  });
});
```

- [ ] **Step 2: Ejecutar tests para verificar que fallan (o que corren)**

```powershell
npx jest tests/unit/queries-validacion.test.js --no-coverage 2>&1 | head -40
```

Resultado esperado: Si el runner tiene el problema de NODE_MODULE_VERSION, verás `Error: The module was compiled against a different Node.js version` — esto es preexistente y no bloquea el avance. Si el runner funciona correctamente, los tests deben **FALLAR** porque `correlacionarSQL` aún no está implementada en `queries.js` (estamos probando la lógica SQL directamente en el test, no el módulo).

- [ ] **Step 3: Implementar `correlacionarPagos(pagosData, opts = {})` en `queries.js`**

En `src/main/database/queries.js`, localizar la función en la línea ~2080:

```js
// ANTES:
function correlacionarPagos(pagosData) {

// DESPUÉS:
function correlacionarPagos(pagosData, opts = {}) {
  const { asesorId = null, fecha = null } = opts;
```

Luego, dentro del bucle `for (let i = 0; i < contratos.length; i += BATCH)`, reemplazar la sentencia `db.prepare(...)` completa:

```js
// ANTES (líneas ~2108-2117):
const rows = db.prepare(`
  SELECT ct.id, ct.nombre_deudor, ct.cedula, ct.ya_pago,
         ct.campana_id, ct.asignado_a, ct.metadata, ct.monto_deuda,
         c.nombre AS campana_nombre,
         u.nombre AS asesor_nombre
  FROM contactos ct
  JOIN campanas c ON ct.campana_id = c.id
  LEFT JOIN usuarios u ON ct.asignado_a = u.id
  WHERE CAST(json_extract(ct.metadata, '$."Nº CONTRATO"') AS TEXT) IN (${ph})
`).all(...batch);

// DESPUÉS:
const extraWhere = [
  asesorId ? 'AND ct.asignado_a = ?' : '',
  fecha    ? "AND date(ct.fecha_asignacion) = ?" : '',
].join(' ');
const rows = db.prepare(`
  SELECT ct.id, ct.nombre_deudor, ct.cedula, ct.ya_pago,
         ct.campana_id, ct.asignado_a, ct.metadata, ct.monto_deuda,
         c.nombre AS campana_nombre,
         u.nombre AS asesor_nombre
  FROM contactos ct
  JOIN campanas c ON ct.campana_id = c.id
  LEFT JOIN usuarios u ON ct.asignado_a = u.id
  WHERE CAST(json_extract(ct.metadata, '$."Nº CONTRATO"') AS TEXT) IN (${ph})
  ${extraWhere}
`).all(...batch, ...(asesorId ? [asesorId] : []), ...(fecha ? [fecha] : []));
```

No cambiar nada más en la función — el resto del procesamiento (agrupación, `estadoPago`, etc.) permanece idéntico.

- [ ] **Step 4: Verificar que los tests pasan (si el runner funciona)**

```powershell
npx jest tests/unit/queries-validacion.test.js --no-coverage 2>&1 | head -40
```

Resultado esperado: `5 passed, 5 total` (o el error preexistente de NODE_MODULE_VERSION si el runner está roto — no bloquea).

- [ ] **Step 5: Commit**

```powershell
git add src/main/database/queries.js tests/unit/queries-validacion.test.js
git commit -m "feat(validacion): correlacionarPagos acepta opts asesorId+fecha para filtrar contactos"
```

---

### Task 2: IPC — handler `validacion:correlacionar` reenvía `opts`

**Files:**
- Modify: `src/main/ipcHandlers.js:471-475`

- [ ] **Step 1: Localizar el handler actual**

En `src/main/ipcHandlers.js` líneas 471-475:
```js
ipcMain.handle('validacion:correlacionar', async (event, pagosData) => {
  if (!Array.isArray(pagosData) || pagosData.length === 0)
    return { matches: [], totalContratos: 0, totalMatches: 0 };
  return correlacionarPagos(pagosData);
});
```

- [ ] **Step 2: Actualizar handler para pasar `opts`**

Reemplazar el bloque completo:

```js
ipcMain.handle('validacion:correlacionar', async (event, pagosData, opts) => {
  if (!Array.isArray(pagosData) || pagosData.length === 0)
    return { matches: [], totalContratos: 0, totalMatches: 0 };
  return correlacionarPagos(pagosData, opts || {});
});
```

El único cambio es: agregar `opts` como tercer parámetro del callback IPC y pasarlo a `correlacionarPagos`. Sin otras modificaciones.

- [ ] **Step 3: Verificar que el handler compila sin errores**

```powershell
node -e "require('./src/main/ipcHandlers.js'); console.log('OK')" 2>&1
```

Resultado esperado: Este comando fallará con un error sobre `electron` (no disponible fuera de Electron) — eso es normal. Lo importante es que NO falle con `SyntaxError`. Si ves `SyntaxError`, hay un error de tipeo — revisar el archivo.

Resultado correcto (esperado): `Error: Cannot find module 'electron'` → sintaxis OK.

- [ ] **Step 4: Commit**

```powershell
git add src/main/ipcHandlers.js
git commit -m "feat(ipc): validacion:correlacionar recibe opts { asesorId, fecha } y los reenvía"
```

---

### Task 3: Frontend — ValidacionPagos.jsx: estado + carga de asesores + barra de filtros

**Files:**
- Modify: `src/renderer/supervisor/ValidacionPagos.jsx`

#### Contexto de la UI actual

La sección relevante está alrededor de la línea 391-403:
```jsx
{/* Correlate button */}
{anySlot && (
  <div style={{ display: 'flex', justifyContent: 'flex-end', marginBottom: 14 }}>
    <button
      className="btn btn-primary"
      style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13, padding: '10px 20px' }}
      onClick={handleCorrelacionar}
      disabled={procesando}
    >
      <span className="material-symbols-outlined" style={{ fontSize: 18 }}>sync</span>
      {procesando ? 'Correlacionando…' : 'Correlacionar con Campañas'}
    </button>
  </div>
)}
```

El estado actual del componente (líneas ~93-106) tiene: `slots`, `procesando`, `resultado`, `seleccionados`, `confirmando`, `filtroEstado`, `filtroEmpresa`, `historial`, `histFiltro`, `sesiones`, `sesionAbierta`.

- [ ] **Step 1: Agregar estado nuevo al componente**

Inmediatamente después de la última línea `const [sesionAbierta, setSesionAbierta] = useState(null);` (línea ~106), agregar:

```js
const [corrAsesorId, setCorrAsesorId] = useState('');
const [corrFecha,    setCorrFecha]    = useState('');
const [asesores,     setAsesores]     = useState([]);
```

- [ ] **Step 2: Cargar asesores en el mount**

Inmediatamente después del `useEffect` que llama a `cargarHistorial()` (línea ~121):

```js
useEffect(() => { cargarHistorial(); }, [cargarHistorial]);
```

Agregar el siguiente useEffect:

```js
useEffect(() => {
  window.api.invoke('db:getAsesores')
    .then(data => setAsesores(data || []))
    .catch(() => {});
}, []);
```

- [ ] **Step 3: Agregar useEffect para limpiar resultado al cambiar filtros**

Después del useEffect de asesores del step anterior, agregar:

```js
useEffect(() => {
  setResultado(null);
  setSeleccionados(new Set());
}, [corrAsesorId, corrFecha]);
```

- [ ] **Step 4: Agregar la constante `canCorrelate`**

Buscar la línea donde se define `anySlot`:
```js
const anySlot = slots.SCC || slots.TEC_SAS;
```

Inmediatamente después, agregar:

```js
const canCorrelate = !!(anySlot && corrAsesorId && corrFecha);
```

- [ ] **Step 5: Actualizar `handleCorrelacionar` para pasar opts**

Localizar dentro de `handleCorrelacionar` (línea ~224):
```js
const res = await window.api.invoke('validacion:correlacionar', todosPagos);
```

Reemplazar por:
```js
const res = await window.api.invoke('validacion:correlacionar', todosPagos, {
  asesorId: Number(corrAsesorId),
  fecha:    corrFecha,
});
```

Nota: `corrAsesorId` viene del `value` del `<select>`, que retorna string — convertir a `Number` para que SQLite lo compare correctamente con el entero `asignado_a`.

- [ ] **Step 6: Reemplazar la sección `{/* Correlate button */}` con la barra de filtros**

Localizar el bloque completo (líneas ~390-403):
```jsx
      {/* Correlate button */}
      {anySlot && (
        <div style={{ display: 'flex', justifyContent: 'flex-end', marginBottom: 14 }}>
          <button
            className="btn btn-primary"
            style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13, padding: '10px 20px' }}
            onClick={handleCorrelacionar}
            disabled={procesando}
          >
            <span className="material-symbols-outlined" style={{ fontSize: 18 }}>sync</span>
            {procesando ? 'Correlacionando…' : 'Correlacionar con Campañas'}
          </button>
        </div>
      )}
```

Reemplazar por:
```jsx
      {/* Correlate bar */}
      {anySlot && (
        <div style={{ display: 'flex', justifyContent: 'flex-end', alignItems: 'center', gap: 10, marginBottom: 14, flexWrap: 'wrap' }}>
          {/* Selector asesor */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
            <span className="material-symbols-outlined" style={{ fontSize: 17, color: 'var(--color-primary)', opacity: 0.7 }}>person_search</span>
            <select
              value={corrAsesorId}
              onChange={e => setCorrAsesorId(e.target.value)}
              style={{
                background: '#151515', border: '1px solid rgba(255,255,255,0.15)',
                borderRadius: 8, color: 'var(--color-on-surface)',
                fontSize: 12, padding: '7px 10px', cursor: 'pointer',
              }}
            >
              <option value="">Asesor…</option>
              {asesores.map(a => (
                <option key={a.id} value={a.id}>{a.nombre}</option>
              ))}
            </select>
          </div>

          {/* Fecha asignación */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
            <span className="material-symbols-outlined" style={{ fontSize: 17, color: 'var(--color-primary)', opacity: 0.7 }}>calendar_today</span>
            <input
              type="date"
              value={corrFecha}
              onChange={e => setCorrFecha(e.target.value)}
              style={{
                background: '#151515', border: '1px solid rgba(255,255,255,0.15)',
                borderRadius: 8, color: 'var(--color-on-surface)',
                fontSize: 12, padding: '7px 10px',
              }}
            />
          </div>

          {/* Botón */}
          <button
            className="btn btn-primary"
            style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13, padding: '10px 20px' }}
            onClick={handleCorrelacionar}
            disabled={procesando || !canCorrelate}
            title={!canCorrelate ? 'Seleccioná asesor y fecha para correlacionar' : ''}
          >
            <span className="material-symbols-outlined" style={{ fontSize: 18 }}>sync</span>
            {procesando ? 'Correlacionando…' : 'Correlacionar con Campañas'}
          </button>
        </div>
      )}
```

- [ ] **Step 7: Verificar que el renderer compila sin errores**

```powershell
npx vite build --mode development 2>&1 | tail -20
```

Resultado esperado: `built in X.XXs` sin errores de TypeScript ni de React. Si hay error, revisar que todos los nuevos identificadores (`corrAsesorId`, `corrFecha`, `asesores`, `canCorrelate`) estén definidos antes de su uso en el JSX.

- [ ] **Step 8: Probar manualmente en la aplicación**

1. Arrancar la app: `npm run electron` (o el comando habitual del proyecto)
2. Abrir panel Supervisor → pestaña Validación de Pagos
3. Cargar un archivo Excel en cualquiera de los slots
4. Verificar que el botón "Correlacionar con Campañas" aparece **deshabilitado**
5. Verificar que el select de Asesor muestra los asesores activos
6. Seleccionar un asesor — el botón sigue deshabilitado
7. Seleccionar una fecha — el botón se habilita
8. Hacer clic en Correlacionar — verificar que la correlación solo retorna contratos del asesor seleccionado asignados en esa fecha
9. Cambiar el asesor — verificar que el resultado se limpia automáticamente

- [ ] **Step 9: Commit**

```powershell
git add src/renderer/supervisor/ValidacionPagos.jsx
git commit -m "feat(ui): filtro asesor+fecha requerido antes de correlacionar pagos"
```
