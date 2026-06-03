ANTIGRAVITY_PROMPT_TerminalCobranza.md# ANTIGRAVITY — MASTER BUILD PROMPT
## Terminal de Cobranza · Plataforma Asesor / Supervisor
**Versión:** 1.0 | **Fecha:** Marzo 2026 | **Clasificación:** Interno

---

## ROL Y CONTEXTO

Eres el agente de desarrollo de ANTIGRAVITY. Tu misión es construir una aplicación de escritorio instalable llamada **Terminal de Cobranza**, que reemplaza funciones de ISSABEL sin necesidad de ISO ni servidor dedicado. La app corre completamente en red local y se distribuye como instalador `.exe` / `.msi`.

---

## STACK TECNOLÓGICO OBLIGATORIO

```
Framework:        Electron.js (última versión estable) + React 18
Backend local:    Node.js + Express (puerto 3000, configurable)
Base de datos:    SQLite con better-sqlite3 (sin servidor externo)
Monitoreo móvil:  scrcpy v3.1 (open source, incluido en /resources)
Comunicación ADB: Android Debug Bridge (ADB) — bundleado en /resources/adb
Audio:            FFmpeg (captura local) + WebRTC para transmisión LAN
Reportes:         ExcelJS (xlsx) + PDFKit (pdf) + csv nativo
Empaquetado:      Electron Builder → genera .exe/.msi firmado
Tiempo real:      WebSocket (ws) entre instancias Asesor ↔ Supervisor
Estilos:          CSS Modules + variables CSS (NO Tailwind, NO frameworks UI externos)
```

---

## ARQUITECTURA DEL SISTEMA

```
┌─────────────────────────────────────────────────────┐
│                  ELECTRON MAIN PROCESS               │
│  - Gestiona ventanas (Asesor / Supervisor)           │
│  - Lanza procesos hijos: scrcpy, ADB, FFmpeg         │
│  - Servidor Express localhost:3000                   │
│  - Servidor WebSocket localhost:3001                 │
│  - Base de datos SQLite en AppData/antigravity/      │
└────────────┬────────────────────────┬────────────────┘
             │ IPC (ipcMain/ipcRenderer)│
    ┌────────▼────────┐      ┌─────────▼────────┐
    │  PANEL ASESOR   │      │ PANEL SUPERVISOR  │
    │  (Renderer)     │      │  (Renderer)       │
    │  React UI       │◄────►│  React UI         │
    └────────┬────────┘ WS  └──────────────────┘
             │
    ┌────────▼────────┐
    │  DISPOSITIVO    │
    │  Android (ADB)  │
    │  scrcpy mirror  │
    │  Audio captura  │
    └─────────────────┘
```

---

## MÓDULO 1 — PANEL DE ASESOR

### Archivo: `src/renderer/asesor/AsesorPanel.jsx`

#### 1.1 Componente: Estado de Conexión
```
Nombre del componente: <ConnectionStatus />
Comportamiento:
  - Consulta cada 2 segundos: ejecutar "adb devices" vía IPC
  - Estados posibles:
    · CONECTADO_USB   → indicador verde  + ícono USB
    · CONECTADO_WIFI  → indicador verde  + ícono WiFi
    · DESCONECTADO    → indicador rojo   + ícono alerta
    · CONECTANDO      → indicador amarillo parpadeante
  - Muestra: modelo del dispositivo, IP si es WiFi, versión Android
  - Detecta automáticamente dispositivos INFINIX (ver Sección INFINIX)
```

#### 1.2 Componente: Botones de Conexión Rápida
```
Nombre del componente: <QuickConnect />

Botón USB:
  - Ejecuta vía IPC → main process → spawn .bat:
    · Ruta configurable: resources/scripts/connect_usb.bat
    · Contenido del .bat:
        @echo off
        adb kill-server
        adb start-server
        adb devices
        scrcpy --window-title "Terminal Cobranza - Asesor" --max-fps 30
  - Feedback visual: spinner durante conexión, éxito/error en toast

Botón WiFi:
  - Abre modal para ingresar IP del dispositivo
  - Ejecuta vía IPC → main process → spawn .bat:
    · Ruta: resources/scripts/connect_wifi.bat [IP]
    · Contenido del .bat:
        @echo off
        adb tcpip 5555
        timeout /t 2
        adb connect %1:5555
        scrcpy --window-title "Terminal Cobranza - WiFi" --max-fps 30
  - Guarda la última IP usada en SQLite (tabla: config)
```

#### 1.3 Componente: Selector de Estado del Asesor
```
Nombre del componente: <EstadoSelector />

Estados disponibles (hardcoded + editables por supervisor):
  ID | NOMBRE              | COLOR HEX | TIPO
  1  | En Gestión          | #22C55E   | PRODUCTIVO
  2  | Ingreso de Datos    | #3B82F6   | IMPRODUCTIVO
  3  | Baño / Pausa        | #EAB308   | IMPRODUCTIVO
  4  | Capacitación        | #F97316   | IMPRODUCTIVO
  5  | Reunión             | #8B5CF6   | IMPRODUCTIVO
  6  | Desconectado        | #EF4444   | NO_APLICA

Comportamiento:
  - Al cambiar estado: INSERT en tabla eventos con timestamp UTC
  - El estado se emite por WebSocket al Panel Supervisor en tiempo real
  - Muestra temporizador del tiempo en estado actual (HH:MM:SS)
  - El estado "En Gestión" se activa automáticamente al detectar llamada activa
    (detección por audio: si FFmpeg detecta audio del dispositivo → estado=1)
```

#### 1.4 Componente: Transmisión de Audio
```
Nombre del componente: <AudioTransmitter />

Comportamiento:
  - Captura audio del dispositivo Android vía:
      ffmpeg -f dshow -i audio="CABLE Output" -codec:a pcm_s16le -ar 44100 pipe:1
    (Usar VB-Cable como virtual audio device o audio interno de scrcpy)
  - Reproduce en PC del asesor con volumen ajustable (slider 0-100)
  - Indicador visual de nivel de audio (VU Meter animado)
  - Toggle ON/OFF sin interrumpir la conexión scrcpy
  - Si el dispositivo no soporta captura de audio:
      · Mostrar aviso: "Dispositivo no compatible con audio — modo visual activo"
      · NO romper la conexión ni lanzar error crítico
  - Fallback flag scrcpy: --no-audio si FFmpeg falla al iniciar
```

---

## MÓDULO 2 — PANEL DE SUPERVISOR

### Archivo: `src/renderer/supervisor/SupervisorPanel.jsx`

#### 2.1 Componente: Vista de Asesores
```
Nombre del componente: <AsesoresGrid />

Comportamiento:
  - Renderiza tarjeta por cada asesor conectado al WebSocket
  - Actualización en tiempo real (cada 2 segundos vía WS ping)
  - Tarjeta de asesor muestra:
      · Nombre del asesor
      · Estado actual (color + label)
      · Temporizador en estado actual
      · Total de marcaciones del día
      · Tiempo al aire acumulado (HH:MM:SS)
      · Tiempo muerto acumulado (HH:MM:SS)
      · Botón: [Escuchar Llamada]
      · Botón: [Ver Pantalla]
  - Filtros superiores: Todos | Solo Activos | Solo Inactivos | Por Estado
  - Alerta visual (borde rojo parpadeante) si asesor lleva >10 min en Pausa
```

#### 2.2 Componente: Escucha de Llamadas
```
Nombre del componente: <CallMonitor />

Comportamiento:
  - Al hacer clic en [Escuchar Llamada] en la tarjeta del asesor:
      1. IPC → main process solicita stream de audio del asesor seleccionado
      2. El audio se transmite por WebSocket (formato: audio/pcm, chunks de 4096 bytes)
      3. Se reproduce en los parlantes del supervisor
  - Solo un asesor puede ser escuchado a la vez
  - Indicador en la tarjeta del asesor monitoreado: ícono de auricular animado
  - El asesor NO es notificado de que está siendo escuchado (modo silencioso)
  - Botón [Detener escucha] para liberar el stream
```

#### 2.3 Métricas en Tiempo Real
```
Nombre del componente: <MetricsDashboard />

Métricas por asesor (calculadas en main process desde SQLite):
  - total_marcaciones:    COUNT de eventos tipo LLAMADA del día
  - tiempo_al_aire:       SUM de duraciones de estado ID=1 del día (segundos)
  - tiempo_muerto:        SUM de duraciones de estados ID=2,3,4,5 del día (segundos)
  - ratio_productividad:  (tiempo_al_aire / (tiempo_al_aire + tiempo_muerto)) * 100
  - ultima_llamada:       timestamp de la última marcación

Panel superior resumen (todo el equipo):
  - Total asesores conectados / Total asesores registrados
  - Marcaciones totales del equipo hoy
  - Promedio de productividad del equipo (%)
  - Asesor más productivo del día
```

---

## MÓDULO 3 — BASE DE DATOS SQLite

### Archivo: `src/main/database/schema.sql`

```sql
-- Ejecutar al inicializar la app si no existe la BD

CREATE TABLE IF NOT EXISTS asesores (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  nombre      TEXT NOT NULL,
  extension   TEXT,
  dispositivo TEXT,
  activo      INTEGER DEFAULT 1,
  creado_en   TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS sesiones (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  asesor_id   INTEGER REFERENCES asesores(id),
  inicio      TEXT NOT NULL,
  fin         TEXT,
  tipo_conexion TEXT CHECK(tipo_conexion IN ('USB','WIFI'))
);

CREATE TABLE IF NOT EXISTS eventos (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  asesor_id   INTEGER REFERENCES asesores(id),
  sesion_id   INTEGER REFERENCES sesiones(id),
  tipo        TEXT CHECK(tipo IN ('ESTADO','LLAMADA','CONEXION','DESCONEXION')),
  estado_id   INTEGER,
  duracion_seg INTEGER,
  timestamp   TEXT DEFAULT (datetime('now')),
  metadata    TEXT  -- JSON libre para datos adicionales
);

CREATE TABLE IF NOT EXISTS config (
  clave TEXT PRIMARY KEY,
  valor TEXT
);

-- Valores por defecto de configuración
INSERT OR IGNORE INTO config VALUES ('ultima_ip_wifi', '');
INSERT OR IGNORE INTO config VALUES ('puerto_websocket', '3001');
INSERT OR IGNORE INTO config VALUES ('puerto_api', '3000');
INSERT OR IGNORE INTO config VALUES ('alerta_pausa_min', '10');
INSERT OR IGNORE INTO config VALUES ('max_fps_scrcpy', '30');
```

---

## MÓDULO 4 — REPORTES

### Archivo: `src/main/reports/ReportGenerator.js`

```
Reportes disponibles:
  1. REPORTE DIARIO POR ASESOR
     - Filtros: asesor, fecha
     - Contenido: marcaciones, tiempo al aire, tiempo muerto, ratio, historial de estados
     - Formatos: PDF (PDFKit), XLSX (ExcelJS), CSV

  2. REPORTE CONSOLIDADO DE EQUIPO
     - Filtros: rango de fechas, todos los asesores o selección
     - Contenido: métricas agregadas por asesor, ranking de productividad
     - Formatos: PDF, XLSX

  3. REPORTE DE ESTADOS
     - Detalle minuto a minuto de cambios de estado por asesor
     - Útil para auditoría

Ruta de exportación: configurable por el usuario (default: Documentos/ANTIGRAVITY/Reportes/)
Nombre de archivo: {tipo}_{asesor}_{fecha_YYYYMMDD}.{ext}
```

---

## MÓDULO 5 — COMPATIBILIDAD INFINIX

### Archivo: `src/main/device/InfinixCompat.js`

```javascript
// VIDs conocidos de chipsets MediaTek usados en INFINIX
const INFINIX_VENDOR_IDS = ['0x0e8d', '0x1bbb', '0x2970'];

// Flags ADB específicos para INFINIX
const INFINIX_ADB_FLAGS = [
  '--no-audio',           // fallback si el modelo no soporta captura
  '--window-borderless',
  '--stay-awake'
];

// Lógica de detección:
// 1. Ejecutar: adb devices -l
// 2. Parsear "model:" del output
// 3. Si model contiene "INFINIX" o "X6" o "X5":
//    a. Aplicar INFINIX_ADB_FLAGS al comando scrcpy
//    b. Mostrar guía de activación de modo desarrollador en modal
//    c. Intentar instalar driver vía: pnputil /add-driver resources/drivers/infinix_mtk.inf /install

// Guía modo desarrollador por modelo (mostrar en modal):
const DEV_MODE_GUIDE = {
  default: "Ajustes → Acerca del teléfono → tocar 'Número de compilación' 7 veces → volver a Ajustes → Opciones de desarrollador → activar Depuración USB",
  INFINIX_HOT: "Ajustes → Sistema → Acerca del teléfono → Número de compilación (7 toques)",
  INFINIX_NOTE: "Ajustes → Sobre el teléfono → Versión de compilación (7 toques)"
};
```

---

## MÓDULO 6 — CONFIGURACIÓN DEL INSTALADOR

### Archivo: `electron-builder.yml`

```yaml
appId: com.antigravity.terminal-cobranza
productName: Terminal de Cobranza
copyright: Copyright © 2026 ANTIGRAVITY

directories:
  output: dist
  buildResources: build

files:
  - "src/**/*"
  - "resources/**/*"
  - "node_modules/**/*"

extraResources:
  - from: resources/adb/
    to: adb/
  - from: resources/scrcpy/
    to: scrcpy/
  - from: resources/ffmpeg/
    to: ffmpeg/
  - from: resources/drivers/
    to: drivers/
  - from: resources/scripts/
    to: scripts/

win:
  target:
    - target: nsis
      arch: [x64]
  icon: build/icon.ico

nsis:
  oneClick: false
  allowToChangeInstallationDirectory: true
  installerLanguages: [Spanish]
  language: 3082
  runAfterFinish: true
  createDesktopShortcut: true
  shortcutName: Terminal de Cobranza

publish: null
```

---

## ESTRUCTURA DE CARPETAS DEL PROYECTO

```
terminal-cobranza/
├── src/
│   ├── main/
│   │   ├── index.js              ← Entry point Electron
│   │   ├── windowManager.js      ← Gestión de ventanas
│   │   ├── ipcHandlers.js        ← Todos los handlers IPC
│   │   ├── adbManager.js         ← Control de ADB y scrcpy
│   │   ├── audioManager.js       ← Captura y transmisión de audio
│   │   ├── wsServer.js           ← Servidor WebSocket
│   │   ├── apiServer.js          ← Express API localhost
│   │   ├── database/
│   │   │   ├── db.js             ← Inicialización SQLite
│   │   │   ├── schema.sql
│   │   │   └── queries.js        ← Todas las queries SQL
│   │   ├── reports/
│   │   │   └── ReportGenerator.js
│   │   └── device/
│   │       └── InfinixCompat.js
│   └── renderer/
│       ├── asesor/
│       │   ├── AsesorPanel.jsx
│       │   ├── ConnectionStatus.jsx
│       │   ├── QuickConnect.jsx
│       │   ├── EstadoSelector.jsx
│       │   └── AudioTransmitter.jsx
│       ├── supervisor/
│       │   ├── SupervisorPanel.jsx
│       │   ├── AsesoresGrid.jsx
│       │   ├── AsesorCard.jsx
│       │   ├── CallMonitor.jsx
│       │   └── MetricsDashboard.jsx
│       └── shared/
│           ├── Toast.jsx
│           ├── Modal.jsx
│           └── theme.css         ← Variables CSS globales
├── resources/
│   ├── adb/                      ← ADB bundleado (win32)
│   ├── scrcpy/                   ← scrcpy v3.1 binarios
│   ├── ffmpeg/                   ← FFmpeg bundleado
│   ├── drivers/
│   │   └── infinix_mtk.inf       ← Driver MediaTek para INFINIX
│   └── scripts/
│       ├── connect_usb.bat
│       └── connect_wifi.bat
├── build/
│   └── icon.ico
├── electron-builder.yml
├── package.json
└── README.md
```

---

## DESIGN SYSTEM — UI

```css
/* src/renderer/shared/theme.css */
:root {
  --color-bg-primary:    #0D1117;
  --color-bg-secondary:  #161B22;
  --color-bg-card:       #1C2128;
  --color-accent:        #58A6FF;
  --color-success:       #22C55E;
  --color-warning:       #EAB308;
  --color-danger:        #EF4444;
  --color-info:          #3B82F6;
  --color-text-primary:  #F0F6FC;
  --color-text-secondary:#8B949E;
  --color-border:        #30363D;
  --font-main:           'Inter', 'Segoe UI', sans-serif;
  --radius-card:         12px;
  --radius-btn:          8px;
  --shadow-card:         0 4px 24px rgba(0,0,0,0.4);
  --transition:          0.18s ease;
}
```

---

## REGLAS DE DESARROLLO

```
1. NUNCA hardcodear rutas de ADB/scrcpy — siempre usar:
   path.join(process.resourcesPath, 'adb', 'adb.exe')

2. SIEMPRE manejar errores de ADB con try/catch y mostrar toast al usuario
   No dejar errores silenciosos.

3. SIEMPRE usar IPC para comunicación renderer ↔ main.
   Nunca llamar Node.js APIs directamente desde el renderer.

4. Los procesos hijos (scrcpy, adb, ffmpeg) deben ser registrados y
   destruidos en el evento 'will-quit' de la app.

5. La base de datos SQLite solo se accede desde el main process.
   El renderer pide datos vía IPC.

6. WebSocket: cada cliente se identifica con { tipo: 'ASESOR'|'SUPERVISOR', asesor_id }
   El servidor rutea mensajes según el tipo.

7. Audio: chunk size = 4096 bytes, sample rate = 44100 Hz, mono, PCM 16-bit.

8. Compatibilidad mínima: Windows 10 64-bit, Node 18+, Android 8.0+.

9. Todos los timestamps se almacenan en UTC en SQLite.
   La UI los convierte a hora local del PC para mostrar.

10. El instalador debe funcionar SIN conexión a Internet.
    Todos los binarios (ADB, scrcpy, FFmpeg) van bundleados en /resources.
```

---

## ORDEN DE CONSTRUCCIÓN (BUILD ORDER)

```
FASE 1 — Setup base
  [ ] Init proyecto Electron + React
  [ ] Configurar IPC bidireccional
  [ ] Configurar Express API en main process
  [ ] Configurar WebSocket server
  [ ] Inicializar SQLite con schema

FASE 2 — ADB + scrcpy + INFINIX
  [ ] adbManager.js: detect, connect USB, connect WiFi
  [ ] InfinixCompat.js: detección por VID, flags, guía modal
  [ ] Scripts .bat generados dinámicamente
  [ ] Test con dispositivos físicos

FASE 3 — Panel Asesor
  [ ] ConnectionStatus con polling
  [ ] QuickConnect botones + modales
  [ ] EstadoSelector con timer y persistencia
  [ ] AudioTransmitter con fallback

FASE 4 — Panel Supervisor
  [ ] AsesoresGrid con WS suscripción
  [ ] AsesorCard con métricas en tiempo real
  [ ] CallMonitor con stream de audio
  [ ] MetricsDashboard con queries SQLite

FASE 5 — Reportes
  [ ] ReportGenerator.js (PDF + XLSX + CSV)
  [ ] UI de selección de filtros y exportación

FASE 6 — Empaquetado
  [ ] electron-builder.yml configurado
  [ ] Bundlear ADB + scrcpy + FFmpeg + drivers
  [ ] Generar instalador .exe
  [ ] Test de instalación limpia en VM Windows 10
```

---

## ENTREGABLES ESPERADOS POR FASE

| Fase | Entregable verificable |
|------|------------------------|
| 1 | App Electron abre ventana, IPC funciona, SQLite inicializado |
| 2 | `adb devices` ejecutado desde app, scrcpy abre mirror, INFINIX detectado |
| 3 | Panel Asesor completo: conexión, estado, audio |
| 4 | Panel Supervisor: grid de asesores, escucha, métricas |
| 5 | Reporte PDF y XLSX generados con datos reales de sesión |
| 6 | Instalador .exe funciona en PC limpia sin Node instalado |

---

*ANTIGRAVITY — Terminal de Cobranza · Master Build Prompt v1.0*
*Uso exclusivo interno del equipo de desarrollo.*
