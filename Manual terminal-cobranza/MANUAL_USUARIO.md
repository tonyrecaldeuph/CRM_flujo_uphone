# Manual de Usuario — Terminal de Cobranza

**Versión:** 2.0.0
**Plataforma:** Windows 10 / 11 (Desktop Electron)
**Roles:** Supervisor · Asesor

---

## Tabla de contenidos

1. [Introducción](#1-introducción)
2. [Requisitos](#2-requisitos)
3. [Instalación](#3-instalación)
4. [Inicio de sesión](#4-inicio-de-sesión)
5. [Rol Supervisor](#5-rol-supervisor)
   - 5.1 Monitoreo en vivo
   - 5.2 Gestión de asesores
   - 5.3 Campañas e importación de clientes
   - 5.4 Plantillas de mensajes
   - 5.5 Métricas avanzadas y reportes
   - 5.6 Historial de gestiones
6. [Rol Asesor](#6-rol-asesor)
   - 6.1 Estados de trabajo
   - 6.2 Selección de campaña
   - 6.3 Modos de marcación
   - 6.4 Gestión de la llamada
   - 6.5 Tipificación
   - 6.6 Agendamiento (PMP y Volver a Llamar)
   - 6.7 Acciones rápidas (WhatsApp, SMS, Correo)
   - 6.8 Historial y métricas personales
7. [Configuración de dispositivos Android (ADB)](#7-configuración-de-dispositivos-android-adb)
8. [Configuración Multi-PC en red LAN](#8-configuración-multi-pc-en-red-lan)
9. [Solución de problemas frecuentes](#9-solución-de-problemas-frecuentes)
10. [Glosario de tipificaciones](#10-glosario-de-tipificaciones)

---

## 1. Introducción

**Terminal de Cobranza** es una plataforma de escritorio diseñada para equipos de cobranza que trabajan con un celular Android controlado desde la PC. Integra gestión de campañas, asignación de clientes, marcación automática o manual, tipificación de resultados, agendamientos, reportería y supervisión en tiempo real.

La arquitectura permite operar en dos modalidades:

- **Modo local:** Un solo computador ejecuta supervisor y asesor simultáneamente.
- **Modo Multi-PC en LAN:** Un computador ejerce de Supervisor (servidor central) y hasta **11 asesores** se conectan desde computadores adicionales en la misma red local.

---

## 2. Requisitos

### Hardware mínimo
- Procesador de 2 núcleos o superior.
- 4 GB de RAM (8 GB recomendado si opera como Supervisor con 10+ asesores).
- 500 MB de espacio en disco.
- Puerto USB libre para el celular (solo en PC del Asesor).

### Software
- Windows 10 versión 1903 o superior / Windows 11.
- Conexión a red local (para modo Multi-PC).

### Celular
- Android 7.0 o superior.
- Depuración USB habilitada.
- SIM con plan de voz activo.

---

## 3. Instalación

1. Ejecutar el instalador `Terminal de Cobranza Setup 2.0.0.exe`.
2. Aceptar la creación del acceso directo en el escritorio.
3. Al primer arranque, Windows puede solicitar permitir el acceso a la red privada. **Aceptar** esta solicitud (necesaria para el modo Multi-PC).
4. Si el antivirus bloquea `scrcpy.exe` o `adb.exe`, agregar la carpeta de instalación a la lista de excepciones.

---

## 4. Inicio de sesión

Al abrir la aplicación aparece la pantalla de login.

### Login local (un solo PC)
1. Dejar el campo **IP del Servidor** en `127.0.0.1` (valor por defecto).
2. Ingresar correo y contraseña entregados por el administrador.
3. Clic en **Iniciar sesión**.

### Login remoto (asesor conectado a un supervisor en LAN)
1. Clic en **Opciones avanzadas** para mostrar el campo de IP.
2. Ingresar la IP del PC del Supervisor (ejemplo: `192.168.1.50`).
3. Ingresar credenciales.
4. Clic en **Iniciar sesión**.

> Si el login remoto falla con mensaje de conexión, confirmar que:
> - El PC del Supervisor tiene la aplicación abierta.
> - Ambos computadores están en la misma red Wi-Fi o cableada.
> - El firewall del Supervisor permite conexiones entrantes al puerto **3001**.

---

## 5. Rol Supervisor

Tras iniciar sesión con un usuario supervisor, se despliega el dashboard central con un menú lateral que contiene las secciones principales.

### 5.1 Monitoreo en vivo

Pantalla por defecto. Muestra en tiempo real:

- **Lista de asesores:** estado actual (Productivo, Baño, Almuerzo, etc.), tiempo acumulado por estado, contacto en gestión, y si está en llamada activa.
- **Métricas del equipo:** totales agregados de gestiones, compromisos, productividad, tiempo efectivo.
- **Panel de actividad:** flujo cronológico de eventos (logins, llamadas, tipificaciones).

Acciones disponibles por asesor:
- **Enviar mensaje:** Envía un texto directo al panel del asesor (aparece como notificación).

### 5.2 Gestión de asesores

Sección **Configuración → Usuarios**.

Permite:
- Crear nuevos usuarios (rol **asesor** o **supervisor**).
- Asignar o cambiar contraseñas.
- **Anonimizar** usuarios retirados sin romper el histórico de gestiones.

> Únicamente un usuario con rol `supervisor` puede crear o modificar otros usuarios.

### 5.3 Campañas e importación de clientes

Sección **Campañas**.

#### Crear una campaña
1. Clic en **Nueva campaña**.
2. Asignar nombre descriptivo (ejemplo: `OCT-2026 Cartera Vencida`).
3. Guardar.

#### Importar clientes
1. Seleccionar la campaña destino.
2. Clic en **Importar XLSX**.
3. Elegir el archivo Excel.
4. Seleccionar el asesor al que se asignarán los contactos.
5. Confirmar la importación.

Campos reconocidos en el XLSX (se conservan todos los adicionales como metadata):
- `CEDULA` *(obligatorio)*
- `NOMBRE DEUDOR` *(obligatorio)*
- `TELEFONO 1` *(obligatorio)*
- `VALOR EN MORA` — usado en la interpolación de plantillas de mensaje.
- `CORREO CLIENTE` — autocompleta el destino en Acciones Rápidas.
- Cualquier otra columna se almacena como campo extra y aparece en el panel del asesor.

#### Configuración de marcación por campaña
En la misma sección se define:
- **Modo de marcación:** `MANUAL` o `AUTOMÁTICA`.
- **Intentos máximos por contacto:** número de reintentos si el asesor tipifica `NC` o `BUZON`.

### 5.4 Plantillas de mensajes

Sección **Configuración → Mensajes**.

Permite definir plantillas reutilizables para:
- **WhatsApp**
- **SMS**
- **Correo electrónico** (asunto y cuerpo)

Tokens disponibles (se reemplazan automáticamente al enviar):

| Token | Reemplazo |
|-------|-----------|
| `{nombres_apellidos}` | Nombre completo del deudor |
| `{cedula}` | Cédula del contacto |
| `{valor_mora}` | Valor en mora formateado |
| `{valor_promocional}` | Valor con descuento si aplica |
| `{asesor_nombre}` | Nombre del asesor que ejecuta |

Al guardar los cambios, se propagan automáticamente a todos los asesores conectados sin necesidad de reiniciar la aplicación.

### 5.5 Métricas avanzadas y reportes

Sección **Métricas**.

Incluye gráficos de:
- Productividad individual y comparativa.
- Contactabilidad diaria (efectivos vs. no contactados).
- Tasa de compromiso por asesor.
- Tiempo productivo vs. improductivo.

Sección **Reportes**.

Permite generar:
- **Reporte de Actividad** (XLSX): tiempos por estado, marcaciones, productividad.
- **Reporte de Gestiones** (XLSX): detalle de cada tipificación registrada.

Filtros:
- Asesor (o todos).
- Rango de fechas.
- Formato: XLSX o PDF.

### 5.6 Historial de gestiones

Sección **Historial**. Muestra todas las gestiones registradas por cualquier asesor, con filtros por fecha, asesor, tipificación y búsqueda libre por cédula o nombre.

---

## 6. Rol Asesor

### 6.1 Estados de trabajo

Al ingresar, el asesor debe seleccionar su estado:

| Estado | Categoría | Descripción |
|--------|-----------|-------------|
| **Productivo** | Productivo | En marcación activa |
| **Baño** | Improductivo | Pausa breve |
| **Almuerzo** | Improductivo | Hora de comida |
| **Capacitación** | Improductivo | Reuniones/formación |
| **Tiempo personal** | Improductivo | Otras pausas |
| **Contactable** | Productivo | Disponible post-llamada |

El tiempo acumulado en cada estado se reporta al supervisor en vivo.

### 6.2 Selección de campaña

En el panel central, elegir la campaña asignada del desplegable **Campaña activa**. El sistema cargará automáticamente el siguiente contacto pendiente.

### 6.3 Modos de marcación

El modo lo configura el supervisor a nivel de campaña.

**Manual:** El asesor revisa el contacto, evalúa, y pulsa **Llamar** cuando esté listo. Al finalizar, tipifica.

**Automática:** Al terminar una llamada y tipificarla, el sistema avanza automáticamente al siguiente contacto. Si el asesor tipifica `NC` o `BUZON`, se reintenta al mismo contacto hasta agotar el número de intentos configurado.

### 6.4 Gestión de la llamada

1. El contacto actual aparece en el panel principal con todos sus datos.
2. Clic en **Llamar** — el celular conectado por USB inicia la llamada.
3. Durante la llamada:
   - Panel de tipificación se despliega en la columna lateral.
   - Botones de acciones rápidas disponibles (WSP, SMS, Correo).
4. Al colgar, la tipificación queda obligatoria antes de avanzar.

### 6.5 Tipificación

En el panel de **Tipificar Gestión**:

1. Seleccionar el **resultado** haciendo clic en uno de los botones agrupados por categoría.
2. Si la tipificación requiere agendamiento (PMP o Volver a Llamar), se desplegará el selector de **fecha y hora**.
3. Completar **Notas / Observaciones** (opcional pero recomendado).
4. Clic en **Guardar Gestión**.

La tipificación cierra el ciclo del contacto (o lo deja agendado) y habilita al asesor para pasar al siguiente cliente.

### 6.6 Agendamiento (PMP y Volver a Llamar)

Tipificaciones con **agendamiento obligatorio:**
- **PMP** — Promesa de Pago.
- **VOL_CALL** — Volver a llamar.

Al seleccionar alguna de estas:
1. El sistema sugiere la fecha/hora actual, ajustable por el asesor.
2. A la hora programada, el asesor recibe automáticamente:
   - **5 minutos antes:** Notificación de aviso (toast amarillo).
   - **Hora exacta:** Notificación para ejecutar (toast verde) con botón para cargar al cliente directamente.
3. También se puede **re-gestionar desde el historial** haciendo clic en el botón **Gestionar** en la fila correspondiente.

### 6.7 Acciones rápidas (WhatsApp, SMS, Correo)

Visibles en el panel de tipificación.

| Acción | Comportamiento |
|--------|----------------|
| **WSP** | Abre WhatsApp Web con el mensaje prellenado. Requiere teléfono en el contacto. |
| **SMS** | Envía la orden al celular para abrir la app de mensajes con el SMS listo. Requiere celular conectado por USB. |
| **CORREO** | Abre Gmail con asunto y cuerpo prellenados. El correo se autocompleta desde la columna `CORREO CLIENTE` del XLSX si existe. |

Los tres mensajes se construyen con las plantillas definidas por el supervisor, reemplazando tokens con datos reales del contacto.

### 6.8 Historial y métricas personales

En la columna lateral del panel del asesor:

- **Métricas del día:** marcaciones, productividad, contactabilidad, compromisos, tiempos.
- **Historial de gestiones:** tabla con cada tipificación realizada, con botón **Gestionar** si tiene agendamiento activo.

---

## 7. Configuración de dispositivos Android (ADB)

### Habilitar depuración USB en el celular
1. Ir a **Ajustes → Acerca del teléfono**.
2. Tocar **Número de compilación** 7 veces hasta ver el mensaje "Ya eres desarrollador".
3. Regresar y entrar en **Opciones de desarrollador**.
4. Activar **Depuración USB**.

### Conectar por USB
1. Conectar el celular al PC del asesor mediante cable USB.
2. En el celular, autorizar la conexión (diálogo "¿Permitir depuración USB?") y marcar **Siempre permitir desde este equipo**.
3. En la aplicación, el estado del dispositivo debe pasar a **Conectado** en la barra superior.

### Conectar por Wi-Fi (opcional)
1. Conectar primero por USB.
2. En la aplicación, abrir el panel de conexión y clic en **Habilitar WiFi**.
3. Ingresar la IP del celular (visible en **Ajustes → Wi-Fi → red actual**).
4. Confirmar.
5. Desconectar el USB — la conexión persiste por Wi-Fi.

---

## 8. Configuración Multi-PC en red LAN

### En el PC del Supervisor
1. Abrir la aplicación e iniciar sesión con un usuario de rol `supervisor`.
2. Identificar la IP local del PC:
   - Presionar `Windows + R`, escribir `cmd`, Enter.
   - Escribir `ipconfig` y buscar **Dirección IPv4** (ejemplo: `192.168.1.50`).
3. Asegurar que el **firewall de Windows permita conexiones entrantes al puerto 3001**. En la primera ejecución, Windows pregunta si permitir — aceptar.

### En cada PC del Asesor
1. Abrir la aplicación.
2. En el login, clic en **Opciones avanzadas**.
3. Ingresar la IP del Supervisor obtenida en el paso anterior.
4. Iniciar sesión con las credenciales del asesor.
5. Conectar el celular por USB y verificar el estado de ADB.

> Todos los cambios del supervisor (plantillas de mensajes, configuración de campañas, modo de marcación) se propagan automáticamente a los asesores conectados sin necesidad de reiniciar.

---

## 9. Solución de problemas frecuentes

### El celular no aparece como conectado
1. Desconectar y reconectar el cable USB.
2. Confirmar que **Depuración USB** está activa.
3. En el celular, revocar autorizaciones USB y volver a autorizar.
4. Reiniciar la aplicación.

### El botón de SMS no responde
- Verificar que el contacto tenga un número telefónico válido en el XLSX original (columna `TELEFONO 1` o el campo `telefono`).
- Si el botón se ve atenuado, el contacto no tiene teléfono asignado.
- Revisar que el celular esté conectado y visible en la barra superior.

### WhatsApp Web no abre
- El sistema abre la URL en el navegador predeterminado. Verificar que haya uno configurado.
- Si se bloquea por ventanas emergentes, permitir pop-ups para la aplicación.

### El asesor remoto no puede conectarse
1. Desde el PC asesor, abrir `cmd` y ejecutar `ping <IP_DEL_SUPERVISOR>`. Debe haber respuesta.
2. Confirmar que el supervisor tiene la aplicación abierta.
3. En el supervisor, desactivar temporalmente el firewall para descartar que sea la causa. Si funciona así, crear una regla de entrada para el puerto 3001.

### No se genera el reporte XLSX
- Revisar que exista al menos un asesor con gestiones en el rango de fechas seleccionado.
- Si el supervisor está en modo Multi-PC, el reporte se descarga como archivo al directorio de descargas del navegador/sistema.

### Los agendamientos no notifican
- Verificar que el asesor tenga la aplicación abierta a la hora programada.
- Revisar el historial: si aparece el agendamiento pero sin notificación, reportar al soporte.

### Pierde conexión con el Supervisor durante el trabajo
- La app intentará reconectar automáticamente.
- Las métricas del asesor se recuperan desde la base de datos al reconectar (no se pierden).
- Si persiste, verificar estabilidad de la red Wi-Fi o cambiar a red cableada.

---

## 10. Glosario de tipificaciones

### Contacto Efectivo (cierran la gestión del día)
- **PMP** — Promesa de Pago → **Requiere agendamiento**.
- **AB_PARC** — Abono Parcial.
- **PAGO_REAL** — Pago Realizado.
- **PEND_COMP** — Pendiente de Registro de Comprobante.
- **VOL_CALL** — Volver a Llamar → **Requiere agendamiento**.
- **NEG_PAG** — Negativa de Pago.
- **TER_CON** — Tercero Contactado.

### No Contactado — decisivos (cierran la gestión)
- **NUM_EQ** — Número Equivocado.
- **TIT_FAL** — Titular Fallecido.
- **FUERA_SERV** — Fuera de Servicio.

### No Contactado — se reintenta hasta el máximo de intentos
- **NC** — No Contesta.
- **BUZON** — Llamada al buzón de voz.

> **Regla de reintentos:** únicamente **NC** y **BUZON** vuelven a marcarse automáticamente al mismo contacto en modo automático. Cualquier otra tipificación cierra el ciclo y avanza al siguiente cliente.

---

**Soporte técnico:** contactar al administrador del sistema o al equipo de desarrollo.
