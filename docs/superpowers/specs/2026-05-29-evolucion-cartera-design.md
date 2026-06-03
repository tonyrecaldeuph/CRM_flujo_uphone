# Diseño: Evolución de Cartera — Widget en Panel de Métricas

**Fecha:** 2026-05-29
**Estado:** Aprobado
**Autor:** Claudiodev

---

## Contexto

En la página de Métricas del panel supervisor existe una grilla de cards KPI (`MetricsOverview`) seguida de gráficos (`AdvancedMetricsCharts`). Se necesita un nuevo widget de análisis de cartera que muestre la evolución de mora de los clientes, insertado entre esos dos bloques. Nada del código existente se elimina.

---

## Decisiones de diseño

| Pregunta | Decisión |
|---|---|
| ¿Reemplaza o agrega? | Agrega — nada existente se elimina |
| Layout interior | Acordeón de 3 paneles, cada uno colapsable independientemente |
| Panel expandido por defecto | Panel 1 (Análisis de Cartera) |
| Títulos de paneles | Siempre fijos, no dinámicos |
| Filtro FECHA APERTURA | Mapeado a `date(ct.fecha_asignacion)` — verificar existencia de columna con `PRAGMA table_info` igual que el resto del codebase |
| Fuente de DIAS IMPAGO | `json_extract(ct.metadata, '$."DIAS IMPAGO"')` — metadata del Excel |
| Fuente de REFINANCIADO | `json_extract(ct.metadata, '$."REFINANCIADO"')` — metadata del Excel |
| "GESTIÓN REALIZADA" | Contacto con al menos 1 CDR (`EXISTS (SELECT 1 FROM cdrs WHERE contacto_id = ct.id)`) |
| "Suma PAGO" | Suma de `monto_deuda` (o `VALOR EN MORA` de metadata) de contactos con `ya_pago = 1` |

---

## Sección 1: Backend — `queries.js`

### `getCarteraAnalisis(opts = {})`

```js
function getCarteraAnalisis(opts = {}) {
  const { fechaAsig = null, desdeD = 0, hastaD = 30 } = opts;
  const db = getDb();

  const fechaWhere = fechaAsig ? "AND date(ct.fecha_asignacion) = ?" : "";
  const params = [desdeD, hastaD, ...(fechaAsig ? [fechaAsig] : [])];

  const rows = db.prepare(`
    SELECT
      CASE WHEN EXISTS (SELECT 1 FROM cdrs c WHERE c.contacto_id = ct.id)
           THEN 'REALIZADA' ELSE 'NO REALIZADA' END AS gestion,
      COUNT(ct.id) AS num_clientes,
      COALESCE(SUM(
        CAST(NULLIF(TRIM(json_extract(ct.metadata, '$."VALOR EN MORA"')), '') AS REAL)
      ), 0) AS valor_cobrar,
      COALESCE(SUM(CASE WHEN ct.ya_pago = 1 THEN
        CAST(NULLIF(TRIM(json_extract(ct.metadata, '$."VALOR EN MORA"')), '') AS REAL)
      ELSE 0 END), 0) AS suma_pago
    FROM contactos ct
    WHERE CAST(NULLIF(TRIM(json_extract(ct.metadata, '$."DIAS IMPAGO"')), '') AS INTEGER)
          BETWEEN ? AND ?
    ${fechaWhere}
    GROUP BY gestion
    ORDER BY gestion
  `).all(...params);

  return rows;
}
```

### `getClientesNoCobro(opts = {})`

```js
function getClientesNoCobro(opts = {}) {
  const { fechaAsig = null, minDias = 30 } = opts;
  const db = getDb();

  const fechaWhere = fechaAsig ? "AND date(ct.fecha_asignacion) = ?" : "";
  const params = [minDias, ...(fechaAsig ? [fechaAsig] : [])];

  const rows = db.prepare(`
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

  return rows;
}
```

### `getCarteraRefinanciada(opts = {})`

```js
function getCarteraRefinanciada(opts = {}) {
  const { fechaAsig = null } = opts;
  const db = getDb();

  const fechaWhere = fechaAsig ? "AND date(ct.fecha_asignacion) = ?" : "";
  const params = [...(fechaAsig ? [fechaAsig] : [])];

  const rows = db.prepare(`
    SELECT
      date(ct.fecha_asignacion) AS fecha_apertura,
      COUNT(ct.id)              AS num_clientes,
      COALESCE(SUM(
        CAST(NULLIF(TRIM(json_extract(ct.metadata, '$."VALOR EN MORA"')), '') AS REAL)
      ), 0) AS valor_cobrar
    FROM contactos ct
    WHERE TRIM(COALESCE(json_extract(ct.metadata, '$."REFINANCIADO"'), '')) != ''
    ${fechaWhere}
    GROUP BY date(ct.fecha_asignacion)
    ORDER BY fecha_apertura DESC
  `).all(...params);

  return rows;
}
```

---

## Sección 2: IPC — `ipcHandlers.js`

```js
ipcMain.handle('db:getCarteraAnalisis',    async (_, opts) => getCarteraAnalisis(opts || {}));
ipcMain.handle('db:getClientesNoCobro',    async (_, opts) => getClientesNoCobro(opts || {}));
ipcMain.handle('db:getCarteraRefinanciada',async (_, opts) => getCarteraRefinanciada(opts || {}));
```

---

## Sección 3: Frontend — `EvolucionCartera.jsx`

### Estado

```js
// Panel abierto/cerrado (independientes)
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
```

### Carga lazy por panel

Cada panel carga sus datos únicamente cuando se expande por primera vez o cuando cambian sus filtros. No se cargan los 3 en el mount.

```js
// Ejemplo para panel 1:
useEffect(() => {
  if (!openPanels.analisis) return;
  setP1Load(true);
  window.api.invoke('db:getCarteraAnalisis', { fechaAsig: p1Fecha || null, desdeD: p1Desde, hastaD: p1Hasta })
    .then(d => setP1Data(d || []))
    .catch(() => setP1Data([]))
    .finally(() => setP1Load(false));
}, [openPanels.analisis, p1Fecha, p1Desde, p1Hasta]);
```

(Mismo patrón para paneles 2 y 3.)

### Acordeón UI

```jsx
<div className="widget-card" style={{ marginBottom: 16 }}>
  <div className="widget-header">
    <span className="material-symbols-outlined" style={{ color: 'var(--color-primary)' }}>trending_up</span>
    <h3 className="widget-title">Evolución de Cartera</h3>
  </div>

  {/* Panel 1 */}
  <AccordionPanel
    title="Análisis de Cartera"
    open={openPanels.analisis}
    onToggle={() => setOpenPanels(p => ({ ...p, analisis: !p.analisis }))}
  >
    {/* filtros: fecha, desde, hasta */}
    {/* tabla: GESTIÓN · No. CLIENTES · VALOR A COBRAR · Suma PAGO */}
    {/* totales al pie */}
  </AccordionPanel>

  {/* Panel 2 */}
  <AccordionPanel
    title="Clientes No Cobro"
    open={openPanels.noCobro}
    onToggle={() => setOpenPanels(p => ({ ...p, noCobro: !p.noCobro }))}
  >
    {/* filtros: fecha, minDias */}
    {/* tabla: GESTIÓN · No. CLIENTES · VALOR A COBRAR */}
  </AccordionPanel>

  {/* Panel 3 */}
  <AccordionPanel
    title="Cartera Refinanciada"
    open={openPanels.refinanciada}
    onToggle={() => setOpenPanels(p => ({ ...p, refinanciada: !p.refinanciada }))}
  >
    {/* filtro: fecha (opcional) */}
    {/* tabla: FECHA APERTURA · No. CLIENTES · VALOR A COBRAR */}
    {/* totales al pie */}
  </AccordionPanel>
</div>
```

`AccordionPanel` es un sub-componente local (no nuevo archivo) con header clicable + chevron animado + contenido colapsable.

### Formato de valores

- `valor_cobrar` y `suma_pago`: `$N,NNN.NN` (mismo `fmt$` que MetricsOverview)
- `num_clientes`: entero con `.toLocaleString()`

---

## Sección 4: SupervisorPanel — integración

```jsx
// Importar
import EvolucionCartera from './EvolucionCartera';

// En la función que renderiza la página Métricas, entre MetricsOverview y AdvancedMetricsCharts:
<MetricsOverview ... />

<EvolucionCartera />

<AdvancedMetricsCharts ... />
```

No se pasan props adicionales — el componente maneja su propio estado e IPC.

---

## Archivos afectados

| Archivo | Tipo de cambio |
|---|---|
| `src/main/database/queries.js` | +3 funciones: `getCarteraAnalisis`, `getClientesNoCobro`, `getCarteraRefinanciada` |
| `src/main/ipcHandlers.js` | +3 handlers IPC |
| `src/renderer/supervisor/EvolucionCartera.jsx` | Nuevo componente |
| `src/renderer/supervisor/SupervisorPanel.jsx` | Import + render del nuevo componente |

**Total: 4 archivos**

---

## Criterios de aceptación

1. Tres paneles de acordeón expandibles de forma independiente
2. Panel 1 expandido por defecto al montar
3. Carga lazy: datos solo se piden cuando el panel está abierto
4. Al cambiar cualquier filtro, los datos se recargan automáticamente
5. Panel 1 filtra por `DIAS IMPAGO` BETWEEN desdeD AND hastaD
6. Panel 2 filtra por `DIAS IMPAGO` >= minDias (default 30)
7. Panel 3 filtra por `REFINANCIADO` not null/empty, agrupado por fecha_asignacion
8. FECHA APERTURA opcional en los 3 paneles; sin valor = sin filtro de fecha
9. Filas de total al pie en paneles 1 y 3
10. Nada del código existente se modifica salvo los 2 archivos de backend y SupervisorPanel
