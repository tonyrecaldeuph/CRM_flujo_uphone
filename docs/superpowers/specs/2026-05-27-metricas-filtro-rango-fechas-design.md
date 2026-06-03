# Diseño: Filtro por Rango de Fechas en Métricas del Supervisor

**Fecha:** 2026-05-27  
**Estado:** Aprobado  
**Autor:** Claudiodev  

---

## Contexto

Las cards de Métricas del supervisor solo permiten filtrar por un único día (`metricasFiltroFecha`). El supervisor necesita analizar períodos completos (ej. 20–26 mayo 2026) para detectar tendencias, comparar semanas o preparar reportes de gestión.

---

## Decisiones de diseño

| Pregunta | Decisión |
|---|---|
| Control UI | Dos inputs separados: **Desde** / **Hasta** |
| Charts horarios en rango | Agregar todas las horas del período (misma vista, datos acumulados) |
| Card Proyecciones en rango histórico | Mostrar totales reales acumulados sin proyección |
| Métricas de stock (Mora Base, Asesores) | Usar `fechaFin` como punto de referencia |

---

## Enfoque de implementación

**Opción B — `opts.fechaFin` opcional en funciones existentes.**

- Cuando `fechaFin` no se pasa: `fechaFin = fechaInicio` → `BETWEEN x AND x` ≡ `= x`
- Sin código condicional, sin breaking changes, sin duplicación de funciones
- Un solo código path para día único y rango

---

## Sección 1: Backend — `queries.js`

### Nuevo helper `_dateRangeMatch(col)`

```js
function _dateRangeMatch(col) {
  return `(substr(${col},1,10) BETWEEN ? AND ?
    OR date(${col},'localtime') BETWEEN ? AND ?
    OR date(${col}) BETWEEN ? AND ?)`;
}
// Necesita 6 params: [fechaInicio, fechaFin, fechaInicio, fechaFin, fechaInicio, fechaFin]
```

Variante de `_dateLocalMatch` que usa `BETWEEN`. Cuando `fechaInicio === fechaFin`, semánticamente equivalente a `= fecha`.

### Funciones modificadas

#### `getMetricasDia(usuarioId, fecha, opts)`

```js
const fechaInicio = fecha || _todayLocalISO();
const fechaFin    = opts.fechaFin || fechaInicio;
```

- **Queries de flujo** (CDRs, eventos, compromisos): `${cdrDateExpr} BETWEEN ? AND ?` con params `[fechaInicio, fechaFin]`
- **Queries de stock** (cartera, mora base): usa `fechaFin` como snapshot de referencia (reemplaza `fechaExplicita = fecha`)
- `campFilterCdr` sin cambios (ya agrega al array de params)

#### `getMetricasEquipo(fecha, opts)`

Forwarding transparente: `opts.fechaFin` viaja a `getMetricasDia` sin cambio en la firma.

#### `getDetalleContactabilidad(fecha, asesorId, campanaId, fechaFin)`

```js
function getDetalleContactabilidad(fecha = null, asesorId = null, campanaId = null, fechaFin = null) {
  const fi = fecha || _todayLocalISO();
  const ff = fechaFin || fi;
  // WHERE date(horaInicio) BETWEEN ? AND ?  → params: [fi, ff]
```

#### `getPagosVerificadosPorAsesor(fecha, campanaId, fechaFin)`

```js
function getPagosVerificadosPorAsesor(fecha = null, campanaId = null, fechaFin = null) {
  const fi = fecha || _todayLocalISO();
  const ff = fechaFin || fi;
```

#### `getCompromisosEquipo(fecha, asesorId, opts)`

Reemplaza `_dateLocalMatch` por `_dateRangeMatch`:
```js
const fi = fecha || _todayLocalISO();
const ff = opts.fechaFin || fi;
// params para _dateRangeMatch: [fi, ff, fi, ff, fi, ff]
```

#### `getRotacionCarteraPeriodo(opts)`

Ya tiene `opts.fechaInicio / opts.fechaFin`. Solo se conecta al nuevo filtro desde el frontend.

---

## Sección 2: IPC Handlers + API Server

### `ipcHandlers.js`

| Handler | Cambio |
|---|---|
| `db:getMetricasEquipo` | `opts.fechaFin` ya viaja dentro del objeto `opts` |
| `db:getDetalleContactabilidad` | Acepta 4to arg `fechaFin` |
| `db:getPagosVerificadosPorAsesor` | Acepta 3er arg `fechaFin` |
| `db:getCompromisosEquipo` | `opts.fechaFin` ya viaja dentro del objeto `opts` |

### `apiServer.js` (modo multi-PC)

Los 3 endpoints afectados aceptan `?fecha_fin=` en query string:

```
GET /api/metricas-equipo?fecha=2026-05-20&fecha_fin=2026-05-26&campana_id=1
GET /api/detalle-contactabilidad?fecha=2026-05-20&fecha_fin=2026-05-26&asesor_id=3
GET /api/pagos-verificados?fecha=2026-05-20&fecha_fin=2026-05-26
```

---

## Sección 3: Frontend

### `SupervisorPanel.jsx`

**Estado nuevo:**
```js
const [metricasFiltroDesde, setMetricasFiltroDesde] = useState('');
const [metricasFiltroHasta, setMetricasFiltroHasta] = useState('');
const metricasFiltroDesdeRef = useRef('');
const metricasFiltroHastaRef = useRef('');
```

Se elimina `metricasFiltroFecha` y su ref.

**Validación automática:** si `hasta < desde` al escribir → auto-swap.

**`hayFiltroMet`:**
```js
const hayFiltroMet = !!(metricasFiltroDesde || metricasFiltroCampana);
```

**Barra de filtros — layout:**
```
[filter_alt] FILTRAR MÉTRICAS
  Desde: [____-__-__]  Hasta: [____-__-__]  [HOY]  |  Campaña: [▼ Todas]  |  [Limpiar]
```
- `Hasta` tiene `min={metricasFiltroDesde}` para bloquear fechas anteriores al inicio
- "HOY" setea ambos a `todayLocalISO()`
- Label activo (un solo día): `"Filtrando: 20/05/2026"`
- Label activo (rango): `"Filtrando: 20/05/2026 → 26/05/2026"`
- Con campaña: agrega `· campaña #X`

**Propagación a consumers:**
```jsx
<AdvancedMetricsCharts
  filtroFechaDesde={metricasFiltroDesde || null}
  filtroFechaHasta={metricasFiltroHasta || null}
  ...
/>
<ContactabilidadModal
  fechaDesde={metricasFiltroDesde || null}
  fechaHasta={metricasFiltroHasta || null}
  ...
/>
<VolumenModal
  fechaDesde={metricasFiltroDesde || null}
  fechaHasta={metricasFiltroHasta || null}
  ...
/>
```

**Polling** — `cargarMetricasEquipoFiltradas` recibe ambas fechas:
```js
callApi('db:getMetricasEquipo', desde, { campanaId, fechaFin: hasta })
```

---

### `AdvancedMetricsCharts.jsx`

**Props:** `filtroFecha` → `filtroFechaDesde` + `filtroFechaHasta`

**Helper local:**
```js
const filtroDesde = filtroFechaDesde;
const filtroHasta = filtroFechaHasta || filtroFechaDesde;
const esRango = filtroDesde && filtroHasta && filtroDesde !== filtroHasta;
```

**Card Proyecciones — cuando `esRango`:**
- Oculta barras de delta proyectado (dashed)
- Subtítulo: `"Período ${desde} → ${hasta} · valores reales acumulados"`
- `proyFactor = 1` (sin extrapolación)

**Textos contextuales en cards:**
```js
const labelFecha = esRango
  ? `del ${filtroDesde} al ${filtroHasta}`
  : filtroDesde ? `el ${filtroDesde}` : 'hoy';
```

**Llamada a `getDetalleContactabilidad`:**
```js
window.api.invoke('db:getDetalleContactabilidad',
  filtroDesde || null, null, camp, filtroHasta || null)
```

**Llamada a `getPagosVerificadosPorAsesor`:**
```js
window.api.invoke('db:getPagosVerificadosPorAsesor',
  filtroDesde || null, camp, filtroHasta || null)
```

**Rotación de Cartera — cuando hay rango:**
```js
// Si esRango → llamar db:getRotacionCarteraPeriodo({ fechaInicio: filtroDesde, fechaFin: filtroHasta, campanaId })
//              y usar el resultado como rotDetalle (reemplaza detalleAsesores del prop metricasEquipo)
// Si no hay rango → comportamiento actual con detalleAsesores de metricasEquipo
// El useEffect que ya maneja rotPeriodo/rotCampana/rotDetalle en AdvancedMetricsCharts
// se extiende para dispararse también cuando cambian filtroDesde/filtroHasta
```

---

### `ContactabilidadModal.jsx`

Props nuevas: `fechaDesde` + `fechaHasta` (reemplaza `fecha`).  
Pasa ambas a `db:getDetalleContactabilidad` como 1er y 4to arg.  
Label de filtro interno actualizado para mostrar rango.

### `VolumenModal.jsx`

Mismo patrón que `ContactabilidadModal.jsx`.

### `ContactabilidadDrillDown.jsx`

Recibe nueva prop `fechaFin`. La pasa como 4to arg a `db:getDetalleContactabilidad`. El filtro por categoría en cliente sigue igual — solo cambia el rango de fechas del fetch.

---

## Archivos afectados

| Archivo | Tipo de cambio |
|---|---|
| `src/main/database/queries.js` | Nuevo helper + 5 funciones modificadas |
| `src/main/ipcHandlers.js` | 4 handlers actualizados |
| `src/main/apiServer.js` | 3 endpoints con `fecha_fin` query param |
| `src/renderer/supervisor/SupervisorPanel.jsx` | Estado + filter bar + propagación |
| `src/renderer/supervisor/AdvancedMetricsCharts.jsx` | Props + lógica de rango |
| `src/renderer/supervisor/ContactabilidadModal.jsx` | Props fechaDesde/fechaHasta |
| `src/renderer/supervisor/VolumenModal.jsx` | Props fechaDesde/fechaHasta |
| `src/renderer/supervisor/ContactabilidadDrillDown.jsx` | Prop `fechaFin` → 4to arg a getDetalleContactabilidad |

**Total: 8 archivos**

---

## Criterios de aceptación

1. Filtro día único (Desde = Hasta) → comportamiento idéntico al actual
2. Rango 20–26 mayo → todas las cards muestran datos acumulados del período
3. Contactabilidad por Hora y Volumen → agregan horas de todos los días del rango
4. Proyecciones → muestra totales reales sin barra proyectada cuando hay rango
5. Mora Base y Asesores Activos → usan `fechaFin` como referencia
6. Limpiar → vuelve a comportamiento sin filtro
7. `Hasta < Desde` → auto-swap sin romper la UI
8. Modo multi-PC → `fecha_fin` en query string funciona igual que IPC
