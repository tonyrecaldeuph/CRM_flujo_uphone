# Diseño: Filtro Asesor + Fecha en Correlación de Validación de Pagos

**Fecha:** 2026-05-28  
**Estado:** Aprobado  
**Autor:** Claudiodev  

---

## Contexto

Al subir un reporte de cuotas (Excel), la correlación corre contra **todas** las asignaciones de la base de datos que coincidan por número de contrato. Si un contrato aparece en múltiples carteras o asesores, se generan coincidencias erróneas. El supervisor necesita poder acotar la correlación a **un asesor específico** y a **la fecha de asignación** del contacto.

---

## Decisiones de diseño

| Pregunta | Decisión |
|---|---|
| Tipo de filtro fecha | `date(ct.fecha_asignacion) = ?` (fecha de asignación del contacto) |
| Obligatoriedad | Ambos filtros (asesor + fecha) requeridos antes de habilitar Correlacionar |
| Layout UI | Filtros inline en la misma barra del botón Correlacionar (Opción B) |
| Retrocompatibilidad | `opts = {}` → sin filtros (comportamiento actual para posibles usos futuros) |

---

## Sección 1: Backend — `queries.js`

### `correlacionarPagos(pagosData, opts = {})`

**Firma nueva:**
```js
function correlacionarPagos(pagosData, opts = {}) {
  const { asesorId = null, fecha = null } = opts;
  // ...resto igual hasta la query...
}
```

**Cláusula WHERE extendida:**
```js
const extraWhere = [
  asesorId ? 'AND ct.asignado_a = ?' : '',
  fecha    ? 'AND date(ct.fecha_asignacion) = ?' : '',
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

Sin cambios en el resto de la función (agrupación por contrato, cálculo de estadoPago, etc.).

---

## Sección 2: IPC — `ipcHandlers.js`

```js
// Antes:
ipcMain.handle('validacion:correlacionar', async (event, pagosData) =>
  correlacionarPagos(pagosData)
);

// Después:
ipcMain.handle('validacion:correlacionar', async (event, pagosData, opts) =>
  correlacionarPagos(pagosData, opts || {})
);
```

Sin otros cambios en el archivo.

---

## Sección 3: Frontend — `ValidacionPagos.jsx`

### Estado nuevo

```js
const [corrAsesorId, setCorrAsesorId] = useState('');
const [corrFecha,    setCorrFecha]    = useState('');
const [asesores,     setAsesores]     = useState([]);
```

### Carga de asesores (mount)

```js
useEffect(() => {
  window.api.invoke('db:getAsesores')
    .then(data => setAsesores(data || []))
    .catch(() => {});
}, []);
```

### Reset de resultado al cambiar filtros

```js
useEffect(() => {
  if (resultado) {
    setResultado(null);
    setSeleccionados(new Set());
  }
}, [corrAsesorId, corrFecha]);
```

### Derivado `canCorrelate`

```js
const canCorrelate = !!(anySlot && corrAsesorId && corrFecha);
```

### `handleCorrelacionar` — propagación de opts

```js
const res = await window.api.invoke(
  'validacion:correlacionar',
  todosPagos,
  { asesorId: corrAsesorId, fecha: corrFecha }
);
```

### UI — barra de correlación

Reemplaza el `div` actual que contiene solo el botón:

```jsx
{anySlot && (
  <div style={{ display: 'flex', justifyContent: 'flex-end', alignItems: 'center', gap: 10, marginBottom: 14 }}>
    {/* Selector asesor */}
    <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
      <span className="material-symbols-outlined" style={{ fontSize: 18, color: 'var(--color-primary)', opacity: 0.7 }}>person_search</span>
      <select
        value={corrAsesorId}
        onChange={e => setCorrAsesorId(e.target.value)}
        style={{ /* estilo inline consistente con la UI actual */ }}
      >
        <option value="">Asesor…</option>
        {asesores.map(a => (
          <option key={a.id} value={a.id}>{a.nombre}</option>
        ))}
      </select>
    </div>

    {/* Fecha asignación */}
    <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
      <span className="material-symbols-outlined" style={{ fontSize: 18, color: 'var(--color-primary)', opacity: 0.7 }}>calendar_today</span>
      <input
        type="date"
        value={corrFecha}
        onChange={e => setCorrFecha(e.target.value)}
        style={{ /* estilo inline consistente con la UI actual */ }}
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

**Tooltip en botón deshabilitado:** `title="Seleccioná asesor y fecha para correlacionar"` — visible al hover.

---

## Archivos afectados

| Archivo | Tipo de cambio |
|---|---|
| `src/main/database/queries.js` | `correlacionarPagos` acepta `opts = { asesorId, fecha }` |
| `src/main/ipcHandlers.js` | Handler `validacion:correlacionar` pasa `opts` al segundo arg |
| `src/renderer/supervisor/ValidacionPagos.jsx` | Estado + carga asesores + barra de filtros inline |

**Total: 3 archivos**

---

## Criterios de aceptación

1. Sin filtros aplicados (asesorId = null, fecha = null) → comportamiento idéntico al actual (retrocompat)
2. Con asesor + fecha → solo muestra contratos del asesor asignados en esa fecha
3. Botón Correlacionar deshabilitado hasta que ambos filtros estén completos
4. Al cambiar asesor o fecha después de correlacionar → resultado se limpia automáticamente
5. Tooltip en botón deshabilitado explica qué falta
6. Lista de asesores cargada al montar el componente vía `db:getAsesores`
