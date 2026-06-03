# Migración Backend PostgreSQL — Terminal de Cobranza
## Spec de Diseño — Fase 1 (Sin ERP) · Revisión 2

**Fecha:** 2026-05-31 (Rev 2 — incorpora VM real + Admin Dashboard dual-mode)
**Objetivo:** Escalar la terminal de cobranza de uso local a múltiples sucursales con base de datos centralizada PostgreSQL en la VM Azure existente.
**Alcance:** Backend REST + PostgreSQL + modo dual Electron + Dashboard Admin con selector de fuente de datos. Sin integración ERP en esta fase.

---

## Diferencias clave respecto a Revisión 1

| Ítem | Rev 1 (especulativa) | Rev 2 (real) |
|------|---------------------|--------------|
| SO de la VM | Ubuntu 22.04 LTS | **Windows Server 2022 Datacenter Azure Edition** |
| Tamaño | Standard B2s (2 vCPU / 4 GB) | **4 vCPU / 32 GB RAM** (ya provisionado) |
| IP pública | Por contratar | **Sin IP pública** — acceso vía Bastion + NAT Gateway saliente |
| Proxy / SSL | nginx + Let's Encrypt | **Cloudflare Tunnel** (`cloudflared`) — sin puerto expuesto |
| Disco de datos | OS disk | **F: DATA — 1 TB** (1024 GiB, ya montado) |
| Admin Dashboard | N/A | **Implementado** — dual-mode Local SQLite / VM PostgreSQL |
| Rol admin | No existía | **`admin`** (M-036 migrado en SQLite; en Prisma desde el inicio) |

---

## Infraestructura Azure — VM Real

| Elemento | Valor |
|---|---|
| Ambiente | PROD |
| Región | East US |
| Resource Group | `rg-uphone-data-gw-prod` |
| VM | `vm-uphone-data-gw-01` |
| Bastion | `bas-uphone-prod-01` (Standard) — RDP seguro sin IP pública |
| Red | `vnet-uphone-data-prod / snet-data-01` |
| IP privada | `10.20.1.4` (estática) |
| IP pública | **Sin IP pública** — solo salida via NAT Gateway |
| SO | Windows Server 2022 Datacenter Azure Edition |
| CPU / RAM | 4 vCPU / 32 GB RAM |
| Disco OS | Disco de arranque (C:) |
| Disco datos | 1 TB montado como **F: DATA** |
| Acceso admin | Azure Bastion (RDP sin puertos públicos) |
| Salida a internet | NAT Gateway `pip-nat-uphone-data-prod` (IP fija de salida) |
| Uso actual | Instalación de software + Power BI Gateway (si corresponde) |

### Conectividad de asesores → VM (sin IP pública)

La VM no tiene IP pública por diseño de seguridad. Para que los asesores externos se conecten, se usa **Cloudflare Tunnel** (`cloudflared`):

```
Asesor (casa/oficina)
  └── Electron → HTTPS/WSS → cobranza.empresa.com
                               └── Cloudflare Edge (PoP cercano)
                                     └── Cloudflare Tunnel (conexión saliente)
                                           └── VM 10.20.1.4:3001
                                                 └── Node.js + WebSocket
```

**Ventajas de Cloudflare Tunnel:**
- La VM inicia la conexión saliente (NAT Gateway lo permite); no necesita IP pública
- Cloudflare gestiona HTTPS/WSS automáticamente
- DDoS protection y WAF incluidos en Free tier
- Costo adicional: **$0** (vs $3.65/mes por IP pública)
- WebSocket completamente soportado (HTTP/2 upgrade)

---

## Arquitectura General

### Topología: Estrella con hub en Azure

```
Sucursal A (asesor) ──┐
Sucursal B (asesor) ──┤
Sucursal C (sup)    ──┼──→ Cloudflare Edge ──→ Tunnel ──→ VM:3001
Admin (dashboard)   ──┤                                     │
Sucursal N          ──┘                              Node.js + PM2
                                                           │
                                                     PostgreSQL 16
                                                     (F:\postgresql)
```

### Stack completo en la VM

```
VM Windows Server 2022 — 4 vCPU / 32 GB / F: 1TB
├── cloudflared (Windows Service) — tunnel cobranza.empresa.com → :3001
├── PM2 (Windows Service vía pm2-windows-service)
│   └── 2 instancias de src/main/apiServer.js + wsServer.js
│       PORT=3001 · NODE_ENV=production
│       DATABASE_URL=postgresql://cobranza:PWD@localhost:5432/cobranza_db
│       JWT_SECRET=<32 chars aleatorios>
└── PostgreSQL 16 for Windows
    └── Datos en F:\postgresql\data
        └── DB: cobranza_db
            └── Usuario: cobranza (password en .env)
```

### Electron — Modo dual

El Electron detecta la fuente de datos en dos capas:

**Capa 1 — ipcHandlers.js** (legacy, para asesores/supervisores sin Admin):
```
BACKEND_URL en .env → HTTP/HTTPS al servidor VM
Sin BACKEND_URL     → SQLite local (comportamiento actual)
```

**Capa 2 — Admin Dashboard** (nuevo):
```
admin_db_mode = 'local' → IPC → better-sqlite3
admin_db_mode = 'vm'    → fetch → ${admin_vm_url}/api/* (JWT en header)
```

El Admin puede cambiar de modo en tiempo real desde "Conexión BD" en el panel.

---

## Prisma Schema — Completo (espejo del schema SQLite actual)

```prisma
generator client {
  provider = "prisma-client-js"
}

datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}

// ── Usuarios ─────────────────────────────────────────────────────
model Usuario {
  id            Int      @id @default(autoincrement())
  nombre        String
  email         String   @unique
  password_hash String
  rol           String   @default("asesor")
  // Valores: "admin" | "supervisor" | "asesor"
  estado        String   @default("activo")
  // Valores: "activo" | "inactivo"
  creado_en     DateTime @default(now())

  contactos     Contacto[]    @relation("ContactoAsesor")
  campanas_sup  Campana[]     @relation("CampanaSupervisor")
  cdrs          Cdr[]
  eventos       Evento[]
  sesiones      Sesion[]
  agendamientos Agendamiento[]
  sub_gestiones SubGestion[]
  metas         MetaAsesor[]
}

// ── Campañas ─────────────────────────────────────────────────────
model Campana {
  id            Int      @id @default(autoincrement())
  nombre        String
  descripcion   String?
  fecha_inicio  String?
  fecha_fin     String?
  supervisor_id Int?
  estado        String   @default("activa")
  // Valores: "activa" | "pausada" | "finalizada"

  supervisor    Usuario?   @relation("CampanaSupervisor", fields: [supervisor_id], references: [id])
  contactos     Contacto[]
}

// ── Contactos ─────────────────────────────────────────────────────
model Contacto {
  id                  Int      @id @default(autoincrement())
  campana_id          Int
  cedula              String?
  nombre_deudor       String?
  telefono            String
  monto_deuda         Float?
  producto            String?
  estado_marcacion    String   @default("PENDIENTE")
  // Valores: PENDIENTE | EN_INTENTOS | AGENDADO | GESTIONADO | YA_PAGO
  intentos_realizados Int      @default(0)
  asignado_a          Int?
  metadata            Json?
  valor_promocional   Float?   @default(0)
  ya_pago             Boolean  @default(false)
  validado_pago       Boolean  @default(false)
  orden_marcacion     Int?
  fecha_asignacion    String?

  campana    Campana    @relation(fields: [campana_id], references: [id], onDelete: Cascade)
  asesor     Usuario?   @relation("ContactoAsesor", fields: [asignado_a], references: [id])
  cdrs       Cdr[]
  agendamientos Agendamiento[]
}

// ── Tipificaciones ────────────────────────────────────────────────
model Tipificacion {
  id               Int     @id @default(autoincrement())
  codigo           String  @unique
  descripcion      String
  requiere_agd     Boolean @default(false)
  categoria        String  @default("NO_CONTACTADO")
  finaliza_gestion Boolean @default(true)
  solo_sistema     Boolean @default(false)

  cdrs Cdr[]
}

// ── CDRs ──────────────────────────────────────────────────────────
model Cdr {
  id                Int       @id @default(autoincrement())
  contacto_id       Int?      // Nullable — contacto puede borrarse, CDR persiste
  usuario_id        Int
  tipificacion_id   Int?
  timestamp_inicio  String?
  timestamp_ringing String?
  timestamp_answered String?
  timestamp_fin     String?
  duracion_seg      Int?
  latencia_ms       Int?      @default(0)
  operadora         String?
  resultado         String?
  notas             String?
  url_grabacion     String?
  monto_acordado    Float?
  comprobante       String?
  forma_pago        String?
  monto_pagado      Float?
  // Snapshots para trazabilidad cuando se elimina la cartera
  snapshot_nombre   String?
  snapshot_cedula   String?
  snapshot_telefono String?
  snapshot_empresa  String?
  creado_en         DateTime  @default(now())

  contacto     Contacto?    @relation(fields: [contacto_id], references: [id], onDelete: SetNull)
  usuario      Usuario      @relation(fields: [usuario_id], references: [id])
  tipificacion Tipificacion? @relation(fields: [tipificacion_id], references: [id])
  sub_gestiones SubGestion[]
}

// ── Sub-gestiones (llamadas a referencias) ─────────────────────────
model SubGestion {
  id          Int      @id @default(autoincrement())
  contacto_id Int
  asesor_id   Int
  cdr_id      Int?
  telefono    String
  notas       String?
  nombre_ref  String?
  parentesco  String?
  creado_en   DateTime @default(now())

  contacto Contacto @relation(fields: [contacto_id], references: [id], onDelete: Cascade)
  asesor   Usuario  @relation(fields: [asesor_id], references: [id])
  cdr      Cdr?     @relation(fields: [cdr_id], references: [id], onDelete: SetNull)
}

// ── Agendamientos ─────────────────────────────────────────────────
model Agendamiento {
  id          Int      @id @default(autoincrement())
  contacto_id Int
  asesor_id   Int
  tipo        String
  // Valores: "PMP" | "VOL_CALL" | "REAGENDADO"
  fecha_hora  String
  notas       String?
  estado      String   @default("pendiente")
  // Valores: "pendiente" | "ejecutado" | "cancelado" | "incumplido"
  creado_en   DateTime @default(now())

  contacto Contacto @relation(fields: [contacto_id], references: [id])
  asesor   Usuario  @relation(fields: [asesor_id], references: [id])
}

// ── Sesiones de trabajo ───────────────────────────────────────────
model Sesion {
  id             Int      @id @default(autoincrement())
  usuario_id     Int
  inicio         DateTime @default(now())
  fin            DateTime?
  tipo_conexion  String?
  // Valores: "USB" | "WIFI" | "LOCAL"

  usuario Usuario @relation(fields: [usuario_id], references: [id])
  eventos Evento[]
}

// ── Eventos de actividad ──────────────────────────────────────────
model Evento {
  id           Int      @id @default(autoincrement())
  usuario_id   Int
  sesion_id    Int?
  tipo         String
  // Valores: "ESTADO" | "LLAMADA" | "CONEXION" | "DESCONEXION" | "ACCION_RAPIDA"
  estado_id    Int?
  duracion_seg Int?
  timestamp    DateTime @default(now())
  metadata     Json?

  usuario Usuario  @relation(fields: [usuario_id], references: [id])
  sesion  Sesion?  @relation(fields: [sesion_id], references: [id])
}

// ── Validación de pagos ───────────────────────────────────────────
model SesionValidacion {
  id               Int      @id @default(autoincrement())
  total_registros  Int      @default(0)
  monto_total      Float    @default(0)
  creado_en        DateTime @default(now())

  validaciones ValidacionPago[]
}

model ValidacionPago {
  id           Int      @id @default(autoincrement())
  contacto_id  Int
  asesor_id    Int?
  monto_pagado Float
  fecha_pago   String?
  banco        String?
  referencia   String?
  validado_en  DateTime @default(now())
  sesion_id    Int?

  sesion SesionValidacion? @relation(fields: [sesion_id], references: [id])
}

// ── Metas de asesores ─────────────────────────────────────────────
model MetaAsesor {
  id              Int    @id @default(autoincrement())
  asesor_id       Int
  periodo         String
  valor_recaudado Float  @default(0)
  meta_propuesta  Float  @default(0)
  meta_diaria     Float  @default(0)
  meta_semanal    Float  @default(0)
  meta_mensual    Float  @default(0)

  asesor Usuario @relation(fields: [asesor_id], references: [id])
  @@unique([asesor_id, periodo])
}

// ── Configuración ─────────────────────────────────────────────────
model Configuracion {
  clave String @id
  valor String
}
```

---

## Endpoints REST — Completos

Todos los endpoints (excepto `/api/health` y `/api/auth/login`) requieren `Authorization: Bearer {jwt}`.

### Health
| Método | Ruta | Auth | Respuesta |
|--------|------|------|-----------|
| GET | `/api/health` | No | `{ ok: true, timestamp, engine: "prisma/postgresql" }` |

### Auth
| Método | Ruta | Body | Respuesta |
|--------|------|------|-----------|
| POST | `/api/auth/login` | `{ email, password }` | `{ token, usuario: { id, nombre, rol } }` |

### Admin — `requireAdmin` (rol = "admin")
| Método | Ruta | Descripción |
|--------|------|-------------|
| GET | `/api/admin/users` | Todos los usuarios (todas las roles) |
| POST | `/api/admin/users` | Crear usuario con hash bcrypt |
| PUT | `/api/admin/users/:id` | Editar nombre/email/rol/estado |
| POST | `/api/admin/users/:id/toggle` | Toggle activo/inactivo |
| POST | `/api/admin/users/:id/password` | Cambiar contraseña |
| GET | `/api/admin/sysinfo` | CPU/RAM/disco del servidor VM *(pendiente)* |
| GET | `/api/admin/connected` | Clientes WS conectados en la VM *(pendiente)* |

> Los primeros 5 endpoints están **implementados** en `apiServer.js`. Los marcados *(pendiente)* habilitan el monitoring de VM en el Admin Dashboard cuando se implemente.

### Usuarios
| Método | Ruta | Equivale a |
|--------|------|-----------|
| GET | `/api/usuarios` | `db:getAsesores` (solo activos) |
| GET | `/api/usuarios/todos` | `db:getAllUsuarios` |
| POST | `/api/usuarios` | `db:insertAsesor` |
| PUT | `/api/usuarios/:id` | `db:updateAsesor` |
| DELETE | `/api/usuarios/:id` | `db:deleteAsesor` |
| POST | `/api/usuarios/:id/anonymize` | `db:anonymizeAsesor` |

### Campañas
| Método | Ruta | Equivale a |
|--------|------|-----------|
| GET | `/api/campanas` | `db:getCampanas` |
| GET | `/api/campanas/:id` | `db:getCampana` |
| POST | `/api/campanas` | `db:insertCampana` |
| DELETE | `/api/campanas/:id` | `db:deleteCampana` |
| POST | `/api/campanas/:id/contactos` | `db:insertContactos` |
| GET | `/api/campanas/:id/siguiente` | `db:getSiguienteContacto` |
| GET | `/api/campanas/:id/progreso` | `db:getProgresoCampana` |
| GET | `/api/campanas/dashboard` | `db:getCampanasDashboard` |

### Contactos
| Método | Ruta | Equivale a |
|--------|------|-----------|
| GET | `/api/contactos/:id` | `db:getContactoById` |
| POST | `/api/contactos/:id/gestionado` | `db:marcarContactoGestionado` |
| PATCH | `/api/contactos/:id/intentos` | `db:incrementarIntentoContacto` |
| POST | `/api/contactos/:id/intentos/reset` | `db:resetearIntentosContacto` |
| GET | `/api/contactos/buscar/:cedula` | `db:buscarContactoPorCedula` |

### CDRs
| Método | Ruta | Equivale a |
|--------|------|-----------|
| POST | `/api/cdrs` | `db:insertCdr` |
| PATCH | `/api/cdrs/:id` | `db:updateCdr` |
| POST | `/api/cdrs/:id/tipificar` | `cdrs:tipificar` |
| GET | `/api/cdrs` | `db:getCdrs` |
| GET | `/api/contactos/:id/cdrs` | `db:getCdrsByContacto` |
| POST | `/api/cdrs/:id/subgestiones` | `db:insertSubGestion` |
| GET | `/api/cdrs/:id/subgestiones` | `db:getSubGestionesByContacto` |
| GET | `/api/bitacora` | `db:getBitacoraAsesor` |
| POST | `/api/confirmar-pago-compromiso` | `db:confirmarPagoCompromiso` |
| POST | `/api/reagendar-compromiso` | `db:reagendarCompromiso` |
| POST | `/api/marcar-compromiso-incumplido` | `db:marcarCompromisoIncumplido` |

### Tipificaciones
| Método | Ruta | Equivale a |
|--------|------|-----------|
| GET | `/api/tipificaciones` | `db:getTipificaciones` |

### Agendamientos
| Método | Ruta | Equivale a |
|--------|------|-----------|
| POST | `/api/agendamientos` | `db:insertAgendamiento` |

### Eventos
| Método | Ruta | Equivale a |
|--------|------|-----------|
| POST | `/api/eventos` | `db:insertEvento` |

### Métricas (supervisor + admin)
| Método | Ruta | Equivale a |
|--------|------|-----------|
| GET | `/api/metricas/:usuario_id` | `db:getMetricasDia` |
| GET | `/api/metricas-equipo` | `db:getMetricasEquipo` |
| GET | `/api/compromisos-equipo` | `db:getCompromisosEquipo` |
| GET | `/api/contactabilidad-detalle` | `db:getDetalleContactabilidad` |
| GET | `/api/pagos-verificados` | `db:getPagosVerificadosPorAsesor` |
| GET | `/api/mis-compromisos` | `db:getCompromisosEquipo` (filtrado al asesor) |
| GET | `/api/cartera` | `db:getCarteraAsesor` |
| GET | `/api/cartera-equipo` | `db:getCarteraEquipo` |
| POST | `/api/cartera/reordenar` | `cartera:setOrdenMarcacionBatch` |

### Validación de pagos (supervisor + admin)
| Método | Ruta | Equivale a |
|--------|------|-----------|
| GET | `/api/validacion/sesiones` | `validacion:getSesiones` |
| POST | `/api/validacion/correlacionar` | `validacion:correlacionar` |
| POST | `/api/validacion/confirmar` | `validacion:confirmarPagos` |
| GET | `/api/validacion/metricas` | `validacion:getMetricas` |
| GET | `/api/validacion/historial` | `validacion:getHistorial` |
| POST | `/api/validacion/revertir` | `validacion:revertir` |

### Config
| Método | Ruta | Equivale a |
|--------|------|-----------|
| GET | `/api/config` | `db:getAllConfig` |
| GET | `/api/config/:clave` | `db:getConfig` |
| POST | `/api/config` | `db:setConfig` |

---

## Admin Dashboard — Integración con VM

El nuevo Dashboard Admin (ya implementado en Electron) se integra con la VM de la siguiente manera:

### Selector de modo (página "Conexión BD")

```
Admin Panel → "Conexión BD"
  ├── [◉] Local LAN — SQLite
  │         Datos: better-sqlite3 vía IPC
  │         Requiere: nada (offline-capable)
  │
  └── [○] VM / Azure — PostgreSQL + Prisma
            URL: https://cobranza.empresa.com
            Token: JWT del admin en la VM
            PG String: postgresql://cobranza:PWD@localhost:5432/cobranza_db
            [Test Conexión] → GET /api/health → latencia ms
            [Login VM]      → POST /api/auth/login → guarda JWT
```

### Config persistida en SQLite local

| Clave config | Descripción |
|---|---|
| `admin_db_mode` | `'local'` \| `'vm'` |
| `admin_vm_url` | `https://cobranza.empresa.com` |
| `admin_vm_token` | JWT del admin en la VM (expira cada 8h) |
| `admin_pg_string` | Connection string (referencia, no usada en Electron) |

### Routing de datos según modo

| Operación | Modo Local | Modo VM |
|---|---|---|
| Métricas equipo | IPC `admin:getGlobalMetrics` | `GET /api/metricas-equipo` |
| Lista usuarios | IPC `admin:getUsers` | `GET /api/admin/users` |
| Crear usuario | IPC `admin:createUser` | `POST /api/admin/users` |
| Editar usuario | IPC `admin:updateUser` | `PUT /api/admin/users/:id` |
| Toggle estado | IPC `admin:toggleUser` | `POST /api/admin/users/:id/toggle` |
| Cambiar contraseña | IPC `admin:changePassword` | `POST /api/admin/users/:id/password` |
| CPU/RAM/Disco | IPC `admin:getSystemInfo` | `GET /api/admin/sysinfo` *(pendiente)* |
| WS conectados | IPC `admin:getConnectedUsers` | `GET /api/admin/connected` *(pendiente)* |

---

## Despliegue en Windows Server 2022

### Herramientas requeridas

Instalar vía Bastion (RDP a `10.20.1.4`) → todas las instalaciones son via winget o MSI:

```powershell
# 1. Node.js 20 LTS
winget install OpenJS.NodeJS.LTS
# Verificar: node --version  →  v20.x.x

# 2. PostgreSQL 16 para Windows
# Descargar installer de https://www.enterprisedb.com/downloads/postgres-postgresql-installers
# Durante la instalación: Data Directory → F:\postgresql\data
# Puerto: 5432 (default). Password de postgres: guardar en KeePass/vault.

# 3. PM2 + adaptador para Windows Service
npm install -g pm2 pm2-windows-service
pm2-service-install -n "CobranzaAPI"

# 4. Cloudflare Tunnel
winget install Cloudflare.cloudflared
```

### Preparar disco F: DATA

```powershell
# Crear estructura de directorios en F:
New-Item -ItemType Directory -Path "F:\cobranza\app"
New-Item -ItemType Directory -Path "F:\cobranza\logs"
New-Item -ItemType Directory -Path "F:\cobranza\backups"
# F:\postgresql\data ya creado por el installer de PostgreSQL
```

### Configurar PostgreSQL

```powershell
# Via psql como postgres
psql -U postgres
```
```sql
CREATE USER cobranza WITH PASSWORD 'CAMBIAR_POR_PASSWORD_SEGURO';
CREATE DATABASE cobranza_db OWNER cobranza ENCODING 'UTF8';
GRANT ALL PRIVILEGES ON DATABASE cobranza_db TO cobranza;
\q
```

### Clonar y configurar la app

```powershell
cd F:\cobranza\app
git clone <repo_url> .

# Instalar dependencias del backend (reutiliza el mismo package.json raíz)
npm install

# Crear .env de producción
@"
NODE_ENV=production
PORT=3001
DATABASE_URL=postgresql://cobranza:CAMBIAR_POR_PASSWORD_SEGURO@localhost:5432/cobranza_db
JWT_SECRET=GENERAR_32_CHARS_ALEATORIOS
JWT_EXPIRES_IN=8h
DB_PATH=F:\cobranza\data\terminal.db
"@ | Out-File -Encoding utf8 .env

# Aplicar migraciones Prisma
npx prisma migrate deploy

# Seed inicial (tipificaciones + usuario admin)
node scripts/seed-prod.js
```

### PM2 — ecosystem.config.js

```js
// F:\cobranza\app\ecosystem.config.js
module.exports = {
  apps: [{
    name: 'cobranza-api',
    script: 'src/main/apiServer.js',
    cwd: 'F:\\cobranza\\app',
    instances: 2,
    exec_mode: 'cluster',
    autorestart: true,
    max_memory_restart: '2G',
    log_file: 'F:\\cobranza\\logs\\combined.log',
    error_file: 'F:\\cobranza\\logs\\error.log',
    env: {
      NODE_ENV: 'production',
      PORT: 3001,
      // DATABASE_URL, JWT_SECRET leídos desde .env via dotenv
    }
  }]
};
```

```powershell
# Arrancar y guardar para reinicio automático
pm2 start ecosystem.config.js
pm2 save
# PM2 ya está instalado como Windows Service via pm2-windows-service
```

### Cloudflare Tunnel — conectividad sin IP pública

```powershell
# 1. Autenticar cloudflared con la cuenta Cloudflare
cloudflared tunnel login

# 2. Crear el tunnel
cloudflared tunnel create cobranza-prod

# 3. Crear config en C:\Users\Administrator\.cloudflared\config.yml
@"
tunnel: <TUNNEL_ID>
credentials-file: C:\Users\Administrator\.cloudflared\<TUNNEL_ID>.json

ingress:
  - hostname: cobranza.empresa.com
    service: http://localhost:3001
    originRequest:
      noTLSVerify: false
  - service: http_status:404
"@ | Out-File -Encoding utf8 "C:\Users\Administrator\.cloudflared\config.yml"

# 4. Crear registro DNS en Cloudflare (automático)
cloudflared tunnel route dns cobranza-prod cobranza.empresa.com

# 5. Instalar como Windows Service
cloudflared service install

# 6. Iniciar
Start-Service cloudflared
```

**Resultado:** Los asesores se conectan a `https://cobranza.empresa.com` (HTTPS automático vía Cloudflare). El WebSocket también funciona: `wss://cobranza.empresa.com` (Cloudflare hace el upgrade automáticamente).

### NSG — reglas mínimas

Con Cloudflare Tunnel no se necesitan reglas de entrada al puerto 3001. El NSG solo necesita:

| Dirección | Puerto | Protocolo | Origen | Propósito |
|-----------|--------|-----------|--------|-----------|
| Salida | 443 | TCP | Any | cloudflared → Cloudflare |
| Salida | 7844 | TCP/UDP | Any | cloudflared protocolo QUIC (opcional) |
| Entrada | 3389 | TCP | Azure Bastion CIDR | RDP via Bastion |
| Entrada | 5432 | ❌ Bloqueado | Any | PostgreSQL solo local |

---

## Orden de despliegue — Paso a paso

```
Paso 1  — Conectar a VM vía Azure Bastion (RDP)                        ~5 min
Paso 2  — winget install Node.js 20 LTS                                ~5 min
Paso 3  — Instalar PostgreSQL 16 for Windows (data en F:\postgresql)   ~10 min
Paso 4  — Crear DB + usuario cobranza en psql                          ~3 min
Paso 5  — Clonar repo en F:\cobranza\app + npm install                 ~10 min
Paso 6  — Crear .env de producción con DATABASE_URL y JWT_SECRET        ~3 min
Paso 7  — npx prisma migrate deploy (crea todas las tablas en PG)       ~2 min
Paso 8  — node scripts/seed-prod.js (tipificaciones + admin user)       ~1 min
Paso 9  — pm2 start + pm2 save                                         ~2 min
Paso 10 — winget install Cloudflare.cloudflared                        ~3 min
Paso 11 — cloudflared tunnel create + route dns + service install       ~5 min
Paso 12 — Verificar: GET https://cobranza.empresa.com/api/health        ~1 min
Paso 13 — Configurar Admin Dashboard: URL + login + Test Conexión       ~3 min
Paso 14 — Distribuir Electron con BACKEND_URL a asesores               ~variable
─────────────────────────────────────────────────────────────────────────
Total estimado: ~55 min de configuración en VM
```

---

## Script seed-prod.js

```js
// scripts/seed-prod.js — seed de producción
// Corre: node scripts/seed-prod.js
require('dotenv').config();
const bcrypt = require('bcryptjs');
const { PrismaClient } = require('@prisma/client');

const prisma = new PrismaClient();

async function main() {
  // Tipificaciones estándar
  const tipificaciones = [
    { codigo: 'PMP',        descripcion: 'Compromiso de pago',         categoria: 'CONTACTO EXITOSO' },
    { codigo: 'AB_PARC',    descripcion: 'Abono parcial',               categoria: 'CONTACTO EXITOSO' },
    { codigo: 'VOL_CALL',   descripcion: 'Volver a llamar',             categoria: 'CONTACTO EXITOSO' },
    { codigo: 'PAGO_REAL',  descripcion: 'Pago realizado',              categoria: 'CONTACTO EXITOSO' },
    { codigo: 'PEND_COMP',  descripcion: 'Pendiente registro',          categoria: 'CONTACTO EXITOSO' },
    { codigo: 'NEG_PAG',    descripcion: 'Negativa de Pago',            categoria: 'CONTACTO NEUTRO'  },
    { codigo: 'TER_CON',    descripcion: 'Tercero conocido',            categoria: 'CONTACTO NEUTRO'  },
    { codigo: 'NC',         descripcion: 'No contesta',                 categoria: 'CONTACTO NEUTRO'  },
    { codigo: 'BUZON',      descripcion: 'Buzon',                       categoria: 'CONTACTO NEUTRO'  },
    { codigo: 'NUM_EQ',     descripcion: 'Numero equivocado',           categoria: 'NO CONTACTADO'    },
    { codigo: 'TIT_FAL',    descripcion: 'Titular fallecido',           categoria: 'NO CONTACTADO'    },
    { codigo: 'FUERA_SERV', descripcion: 'Fuera de servicio',           categoria: 'NO CONTACTADO'    },
    { codigo: 'INCUMP',     descripcion: 'Compromiso Incumplido',       categoria: 'CONTACTO NEUTRO',  solo_sistema: true },
    { codigo: 'COMP_CUM',   descripcion: 'Compromiso Cumplido',         categoria: 'CONTACTO EXITOSO', solo_sistema: true },
    { codigo: 'REAG',       descripcion: 'Reagendamiento',              categoria: 'CONTACTO EXITOSO', solo_sistema: true, finaliza_gestion: false },
  ];

  for (const t of tipificaciones) {
    await prisma.tipificacion.upsert({
      where: { codigo: t.codigo },
      update: t,
      create: t,
    });
  }
  console.log('[SEED] Tipificaciones OK');

  // Usuario admin
  const adminHash = await bcrypt.hash('Admin2026!', 10);
  await prisma.usuario.upsert({
    where: { email: 'admin@sistema.local' },
    update: { password_hash: adminHash, rol: 'admin', estado: 'activo' },
    create: {
      nombre: 'Administrador Sistema',
      email: 'admin@sistema.local',
      password_hash: adminHash,
      rol: 'admin',
      estado: 'activo',
    },
  });
  console.log('[SEED] Admin user: admin@sistema.local / Admin2026!');

  // Config defaults
  const defaults = [
    { clave: 'modo_marcacion', valor: 'MANUAL' },
    { clave: 'intentos_marcacion', valor: '3' },
    { clave: 'alerta_pausa_min', valor: '10' },
    { clave: 'codigo_pais', valor: '593' },
  ];
  for (const d of defaults) {
    await prisma.configuracion.upsert({
      where: { clave: d.clave },
      update: {},
      create: d,
    });
  }
  console.log('[SEED] Config defaults OK');
}

main()
  .catch(console.error)
  .finally(() => prisma.$disconnect());
```

---

## Electron — Patrón `ipcHandlers.js` dual-mode

```js
// src/main/ipcHandlers.js — patrón para handlers dual-mode
const MODE = process.env.BACKEND_URL ? 'cloud' : 'local';
let _token = null;

async function apiCall(path, method = 'GET', body = null) {
  const res = await fetch(`${process.env.BACKEND_URL}${path}`, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(_token ? { Authorization: `Bearer ${_token}` } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  if (!res.ok) throw new Error(`API ${res.status}`);
  return res.json();
}

// Auth — guarda el JWT para todas las llamadas siguientes
ipcMain.handle('auth:login', async (_, { email, password }) => {
  if (MODE === 'cloud') {
    const data = await apiCall('/api/auth/login', 'POST', { email, password });
    _token = data.token;
    return data;
  }
  return loginLocal({ email, password }); // SQLite local
});

// Campañas — ejemplo de handler dual
ipcMain.handle('db:getCampanas', async () =>
  MODE === 'cloud' ? apiCall('/api/campanas') : getCampanas()
);
```

### `.env` por tipo de instalación

```env
# Instalación en sucursal (modo cloud)
BACKEND_URL=https://cobranza.empresa.com

# Instalación local LAN (sin esta línea → SQLite, comportamiento actual)
# No escribir BACKEND_URL

# Admin Dashboard (se configura desde la UI, no desde .env)
# admin_db_mode / admin_vm_url / admin_vm_token → tabla config en SQLite
```

---

## Recursos de la VM — Capacidad estimada

Con 4 vCPU / 32 GB RAM / 1 TB disco:

| Recurso | Requerimiento app | Disponible | Margen |
|---|---|---|---|
| CPU | ~0.5 vCPU (Node.js × 2 PM2) | 4 vCPU | **×8** |
| RAM | ~512 MB (Node) + ~512 MB (PG) | 32 GB | **×32** |
| Disco app | ~500 MB (node_modules + código) | 1 TB (F:) | **×2000** |
| Disco PG data | ~10 GB (100k contactos + CDRs) | ~990 GB libre | **×99** |
| Conexiones PG | ~50 (2 inst × 25 pool) | max_connections=200 | OK |
| Conexiones WS | 100 asesores × 1 WS = 100 | Node.js soporta 10k+ | OK |

La VM está sobre-provisionada para las necesidades actuales. Puede alojar también el Power BI Gateway sin competencia de recursos.

---

## Deuda Técnica — Fase 2

| ID | Descripción | Prioridad |
|----|-------------|-----------|
| DT-B01 | Endpoints `/api/admin/sysinfo` y `/api/admin/connected` (habilitan monitoring completo en Admin Dashboard modo VM) | ALTA |
| DT-B02 | Refresh tokens + revocación JWT (actualmente token fijo 8h; admin re-login cada 8h) | ALTA |
| DT-B03 | Módulos diferidos en Prisma: validación pagos, cartera análisis, metas, referencias | MEDIA |
| DT-B04 | Redis Pub/Sub para WebSocket multi-instancia PM2 (actualmente broadcast en memoria, no funciona en cluster) | MEDIA |
| DT-B05 | Azure Monitor + Application Insights — observabilidad del servidor | MEDIA |
| DT-B06 | Suite de tests de integración contra PostgreSQL | MEDIA |
| DT-B07 | Auto-renovación del JWT del Admin Dashboard (hoy expira a las 8h sin aviso) | BAJA |
| DT-B08 | Migrar a Azure Database for PostgreSQL Flexible Server (backups automáticos, PITR) | BAJA |

> **DT-B04 es crítico para PM2 cluster:** Con 2 instancias en cluster, un broadcast WebSocket solo llega a los clientes conectados a ESA instancia. Solución: `Socket.io + @socket.io/redis-adapter` o bajar a `instances: 1` temporalmente.

---

## Criterios de Aceptación — Fase 1

### Backend VM
- [ ] `GET https://cobranza.empresa.com/api/health` responde `{ ok: true }`
- [ ] `POST /api/auth/login` con `admin@sistema.local / Admin2026!` retorna JWT válido
- [ ] `GET /api/admin/users` con JWT admin retorna lista de usuarios
- [ ] `GET /api/metricas-equipo` retorna datos del día con JWT supervisor
- [ ] Un asesor puede tipificar una llamada y el CDR queda en PostgreSQL
- [ ] HTTPS activo — ningún dato viaja en texto plano
- [ ] PM2 reinicia automáticamente si el proceso cae
- [ ] cloudflared Windows Service arranca con la VM

### Admin Dashboard — Modo VM
- [ ] Admin abre "Conexión BD" → selecciona "VM / Azure"
- [ ] Ingresa URL `https://cobranza.empresa.com` → "Test Conexión" muestra latencia OK
- [ ] "Login VM" con credenciales admin → token guardado automáticamente
- [ ] Dashboard muestra métricas provenientes de la VM (no del SQLite local)
- [ ] Gestión Usuarios opera sobre usuarios de la VM (crear/editar via `/api/admin/users`)
- [ ] Al volver a "Local SQLite", los datos locales se muestran nuevamente

### Electron asesores
- [ ] Electron con `BACKEND_URL` configurado inicia sesión y carga campañas del servidor
- [ ] Electron sin `BACKEND_URL` funciona igual que hoy (SQLite local)
- [ ] 2 instalaciones Electron en sucursales distintas ven la misma data compartida
- [ ] WebSocket (`wss://cobranza.empresa.com`) conecta y recibe eventos en tiempo real
