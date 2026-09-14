# Modo Nube de LidaPrint — implementación en Odoo 18

Referencia del **modo Nube** de LidaPrint en el módulo
`l10n_ve_lidoo_integration_api` (repo de addons de Lazylidoo,
`addons/l10n-ve-lidoo`): el agente de Windows consulta a Odoo por HTTPS y Odoo
mantiene la cola de trabajos de impresión.

> **Estado:** implementado en `l10n_ve_lidoo_integration_api` **18.0.2.4.0**,
> rama `feat/lidaprint-nube` del repo de addons (cambios aún sin commit al
> escribir esta guía). Probado con 253 tests de integración en verde más el
> carril puro (§11). Esta guía ya **no** es una propuesta: los bloques de
> código son extractos recortados del código real o se sustituyeron por una
> referencia al archivo. Si algo de aquí no coincide con el módulo, **manda el
> código del módulo**.

Todas las rutas de archivo de esta guía son relativas a
`addons/l10n-ve-lidoo/l10n_ve_lidoo_integration_api/` salvo que se indique
otra cosa.

## Contenido

1. [El problema y el modelo pull](#1-el-problema-y-el-modelo-pull)
2. [Contrato HTTP](#2-contrato-http)
3. [Punto de partida: el módulo antes de 18.0.2.4.0](#3-punto-de-partida-el-módulo-antes-de-180240)
4. [Modelos](#4-modelos)
5. [Enrutamiento: a qué equipo va cada impresión](#5-enrutamiento-a-qué-equipo-va-cada-impresión)
6. [Controladores](#6-controladores)
7. [Despacho: destino de impresión](#7-despacho-destino-de-impresión)
8. [Seguridad fiscal](#8-seguridad-fiscal)
9. [Seguridad](#9-seguridad)
10. [Rendimiento](#10-rendimiento)
11. [Pruebas](#11-pruebas)
12. [Versión y migración](#12-versión-y-migración)
13. [Checklist de despliegue](#13-checklist-de-despliegue)
14. [Decisiones](#14-decisiones)

---

## 1. El problema y el modelo pull

Antes de 18.0.2.4.0 el módulo solo sabía empujar el PDF al equipo de
impresión: `tools/lidaprint.py` hace `GET {url}/print/status` y
`POST {url}/print/file` contra el HttpListener de LidaPrint (destino **Red
local**). Eso exige que el servidor Odoo **alcance** la PC por la red. Con Odoo
en un VPS la PC está detrás de un NAT (router de la tienda, IP dinámica, CGNAT
del ISP): el VPS no puede abrir una conexión hacia ella sin VPN, reenvío de
puertos o IP pública, y ninguna de esas opciones es razonable para el cliente
final.

El modo Nube invierte el sentido, igual que las cajas IoT de Odoo: **la PC
abre siempre la conexión** (HTTPS saliente, que cualquier NAT permite) y Odoo
solo responde. Odoo guarda cada impresión como un *trabajo* en una cola por
equipo; LidaPrint consulta la cola cada pocos segundos, descarga los PDF,
los imprime y confirma el resultado.

```
 Usuario (navegador)        Odoo (VPS)                     LidaPrint (PC de la caja)
        |                       |                                    |
        |  Imprimir Forma Libre |                                    |
        |---------------------->|                                    |
        |                       | contador +1, render original       |
        |                       | contador +1, render copia          |
        |                       | crea job 51 y 52 (pending)         |
        |  "Enviado a Caja 1"   |                                    |
        |<----------------------|                                    |
        |                       |      POST /lidaprint/v1/poll       |
        |                       |<-----------------------------------|  (cada next_poll s)
        |                       | UPDATE ... FOR UPDATE SKIP LOCKED  |
        |                       | 51, 52: pending -> printing        |
        |                       |  200 {"jobs":[{"id":51,            |
        |                       |   "filename":"F-00001234.pdf",     |
        |                       |   "size":48211},{"id":52,...}],    |
        |                       |   "next_poll":3}                   |
        |                       |----------------------------------->|
        |                       |      GET /lidaprint/v1/job/51/pdf  |
        |                       |<-----------------------------------|
        |                       |  200 application/pdf               |
        |                       |----------------------------------->|  imprime (Ghostscript / ESC-POS)
        |                       |  POST /lidaprint/v1/job/51/ack     |
        |                       |<-----------------------------------|  {"status":"done"}
        |                       | 51: printing -> done               |
        |                       |  200 {"ok":true}                   |
        |                       |----------------------------------->|
        |                       |   (igual para 52: pdf, imprime, ack)
        |                       |                                    |
        |                       |      POST /lidaprint/v1/poll       |
        |                       |<-----------------------------------|
        |                       |  200 {"jobs":[],"next_poll":3}     |
        |                       |----------------------------------->|
```

Consecuencias de diseño que respeta la implementación:

- **Imprimir no bloquea al usuario.** En Red local `lidaprint.ensure_ready()`
  hace un `GET /print/status` síncrono y lanza `UserError` si la PC no
  responde. En Nube el trabajo queda en cola; si el equipo está desconectado
  se avisa (notificación `warning` persistente), pero no se bloquea.
- **La creación del trabajo es el acto fiscal.** El contador
  `l10n_ve_lidoo_free_form_copy_number` se incrementa al encolar, en la misma
  transacción que crea los trabajos. Si algo falla antes del commit, no queda
  ni contador ni trabajo (a diferencia de Red local, que debe compensar
  subidas parciales).
- **Un trabajo nunca se reencola solo.** Un trabajo que quedó en `printing`
  sin confirmación pudo haberse impreso: reimprimirlo automáticamente podría
  sacar un segundo original fiscal (§8).

---

## 2. Contrato HTTP

Este contrato es el mismo que implementa LidaPrint (`LidaPrint.ps1`, modo
`cloud`) y el que documenta el docstring de `controllers/lidaprint_cloud.py`.
Cualquier cambio debe hacerse en los dos lados a la vez.

**Base:** `{cloudUrl}/lidaprint/v1`, donde `cloudUrl` es solo
`esquema://host[:puerto]` de Odoo, **sin** `/odoo`, `/web` ni otra ruta (por
ejemplo `https://cliente.example.com`). LidaPrint normaliza la URL a esa forma
(§2.1).

**Cabeceras en todas las peticiones:**

```
Authorization: Bearer <cloudToken>
User-Agent: LidaPrint/<versión>
```

**Rechazo por token.** Con un token inválido, revocado o de un equipo
archivado, **todos** los endpoints responden, sin ningún efecto en la base:

```
401 {"ok":false,"error":"unauthorized"}
```

**Otros errores** del contrato usan el envoltorio de `ApiHelpers._error()`
(`controllers/common.py`):

```
404 {"status":"error","message":"job not found"}
400 {"status":"error","message":"<motivo>"}
```

Distinto de ellos: si Odoo **no resuelve la base de datos** (varias bases sin
`dbfilter`, §6.3), cualquier ruta `/lidaprint/v1/*` responde un **404 en HTML**
del propio Odoo, no JSON.

### `GET /ping`

Prueba de conexión del botón «Probar conexión» del Configurador, y *keep-alive*
del agente entre trabajos de un lote (§2.1). **No reclama trabajos.** Actualiza
`last_seen` (con throttle) y la versión del agente (del `User-Agent`).

```
200 {"ok":true,"device":"Caja 1","company":"ACME","next_poll":3}
401 {"ok":false,"error":"unauthorized"}
```

### `POST /poll`

```
Cuerpo:  {"hostname":"<COMPUTERNAME>","version":"<ver>","printer":"<config.printer>"}
200      {"jobs":[{"id":51,"filename":"F-00001234.pdf","size":12345}],"next_poll":3}
```

Con token válido responde **siempre** `200`; `jobs` puede venir vacío y un
cuerpo vacío o inválido cuenta como `{}`. En el servidor reclama de forma
atómica hasta **10** trabajos pendientes del equipo (`pending` -> `printing`),
en orden de id. Si llenó el cupo, `next_poll` vale `1`. Una excepción
inesperada sale como `500` (LidaPrint aplica su backoff).

### `GET /job/<id>/pdf`

```
200 application/pdf (binario, con Content-Length y Content-Disposition)
404 {"status":"error","message":"job not found"}
```

Solo se sirve un trabajo **reclamado** (`printing`) del propio equipo, y cada
descarga suma 1 a `attempts`. Un trabajo ajeno, inexistente o propio en
`pending`, `done` o `error` responde **404** (siempre 404: Odoo nunca responde
410). LidaPrint trata el 404 como definitivo: no imprime y confirma con un ack
de error, que Odoo ignora si el trabajo ya no está en `printing` (§8.3).

### `POST /job/<id>/ack`

```
Cuerpo:  {"status":"done"}
    o    {"status":"error","message":"..."}
200      {"ok":true}
404      {"status":"error","message":"job not found"}      (trabajo de otro equipo o inexistente)
400      {"status":"error","message":"<motivo>"}           (cuerpo sin status válido)
```

Idempotente: repetir un ack, o enviarlo tarde, devuelve `200 {"ok":true}` sin
cambiar el resultado ya registrado (§8.3). El mensaje se recorta a 2000
caracteres (LidaPrint ya lo recorta a 500).

### 2.1 Comportamiento del cliente que el servidor debe esperar

Lo que hace LidaPrint en modo Nube, para que el servidor no tenga que
adivinarlo:

| Aspecto | Comportamiento de LidaPrint |
|---|---|
| URL | El Configurador y el monitor normalizan `cloudUrl` a `esquema://host[:puerto]` con la misma función (`Get-CloudUrlCheck`): quitan ruta, query y fragmento y avisan (el Configurador con un mensaje y reescribiendo el campo; el monitor con un WARN en el log). Con `https://odoo…/odoo` Odoo 18 respondería al ping un 303 a `/web/login` y al poll un 400 por CSRF. |
| Esquema | `https://` siempre. `http://` solo hacia hosts de red local (`Test-CloudLocalHost`): `localhost`, nombres `.local`, 127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 169.254.0.0/16, 100.64.0.0/10, `::1`, fc00::/7 y fe80::/10, con aviso de que el token viaja en claro. Con `http://` hacia un host público el Configurador no deja guardar y el monitor **no arranca** el ciclo Nube: registra un ERROR y sale, igual que sin token. |
| Intervalo | Duerme `next_poll` segundos, acotado a **[1, 300]**. Si la respuesta no trae `next_poll`, usa `cloudPollSeconds` del `config.json` (por defecto **3**). |
| Timeouts | **15 s** para ping, poll y ack; **60 s** para la descarga del PDF; **10 s** para el ping de *keep-alive*. |
| Lote y *keep-alive* | Procesa el lote entero (hasta 10 trabajos) antes del siguiente poll. Entre dos trabajos del mismo lote, si pasaron más de **30 s** desde el último contacto (poll o ping exitoso, o el último intento de *keep-alive*), hace `GET /ping`: no reclama nada y actualiza `last_seen`, así el equipo no aparece desconectado (umbral de 60 s, §6.4) durante un lote largo. Un fallo de ese ping no interrumpe el lote: deja un WARN y se reintenta 30 s después. |
| Ids | Solo acepta `id` enteros (ignora los trabajos cuyo `id` no casa con `^\d+$`). Los ids de Odoo ya lo son. |
| Validación del PDF | Rechaza PDF de más de **50 MB** (según el `size` del poll o el archivo descargado) o que no empiecen con `%PDF-`: las mismas reglas que `/print/file` y que `pdf_problem()` (`MAX_PDF_BYTES` y `PDF_MAGIC` en `tools/lidaprint_cloud.py`). Un PDF rechazado no se imprime y se confirma con `ack` de error. |
| Caducidad local | Anota cuándo entró cada trabajo en su cola local con un reloj **monótono** (`Stopwatch.GetTimestamp`), combinado con el reloj de Windows tomando el mayor de los dos tiempos transcurridos: atrasar la hora no alarga la ventana, y un contador monótono detenido durante una suspensión tampoco. Si el trabajo lleva **10 minutos** o más en la cola, **no lo imprime** y envía `ack` de error «Trabajo caducado: recibido hace X min sin poder imprimirse; verifique en Odoo antes de reimprimir». Lo comprueba antes de descargar y **otra vez justo antes de imprimir** (después de la descarga). Un trabajo sin marca de recepción conocida cuenta como caducado. |
| Cola en memoria | La cola local y sus marcas viven solo en memoria. Si el monitor se reinicia, los trabajos que había reclamado sin terminar quedan en `printing` en Odoo; el poll no los devuelve (solo reclama `pending`) y el cron los pasa a error (§8.1). |
| Descarga fallida | Un fallo transitorio (sin respuesta, 401, 408, 429 o 5xx) deja el trabajo primero en la cola local y lo reintenta en el ciclo siguiente: **un intento por ciclo** y solo mientras los polls tienen éxito. Tras **5 intentos fallidos** envía `ack` de error; la caducidad de 10 minutos acota además el total. Es seguro porque todavía no imprimió nada. Un **404** (u otro 4xx) en la descarga es definitivo: `ack` de error y sigue con el siguiente. |
| Nombre de archivo | Lo sanea con `[IO.Path]::GetFileName` y lo guarda como `job-<id>-<filename>` en su carpeta temporal. |
| Duplicados | Nunca imprime dos veces el mismo `id` en una misma sesión (lleva un conjunto de ids ya tratados). Por eso **una reimpresión siempre es un trabajo nuevo** (id nuevo), nunca un trabajo existente devuelto a `pending` (§8.2). |
| Acks pendientes | Un ack fallido se guarda, se persiste en `temp/cloud-pending-acks.json` (sobrevive a un reinicio del monitor) y se reintenta antes del poll, **como mucho cada 30 s** por ack. **Nunca bloquea el poll.** Cada ack se descarta con un WARN a los **60 minutos** (hay además un tope de 150 intentos como red de seguridad, inalcanzable antes de los 60 minutos a ese ritmo); un ack respondido con un 4xx distinto de 401, 408 o 429 se descarta sin reintentar. Por eso un ack puede llegar tarde o no llegar nunca: el endpoint es idempotente e ignora los tardíos (§8.3), y el cron cubre los que no llegan (§8.1). |
| Errores de red o 5xx | Backoff exponencial 2 → 4 → 8 … hasta **60 s**. Registra solo el cambio de estado («Conexión con Odoo perdida» / «restablecida»). |
| 404 o 400 en ping o poll | Mensaje propio: «URL incorrecta o base de datos no resuelta: revise la URL (sin /odoo ni /web) y, si el servidor tiene varias bases, configure dbfilter por dominio» (§6.3). En el monitor se registra una sola vez, como cambio de estado, y se mantiene el mismo backoff hasta 60 s. |
| 401 | «Equipo archivado o token revocado» (o token mal copiado). Espera **60 s**; tras **3 respuestas 401 seguidas** alarga la espera a **300 s**. El contador se reinicia con la primera respuesta exitosa. Registra solo el cambio de estado. Un equipo revocado o archivado cuesta como mucho ~1 petición cada 5 min (~288/día). |
| Formato del token | El Configurador avisa, sin bloquear, si el token no casa con `^[A-Za-z0-9_-]{43}$` («¿se copió completo?»): Odoo genera `secrets.token_urlsafe(32)`, 43 caracteres. |
| Peticiones | Cuerpos JSON con `Content-Type: application/json; charset=utf-8`, sin `Expect: 100-continue`. Decodifica las respuestas JSON como UTF-8 aunque no traigan `charset`, así que el `application/json` de `request.make_json_response` sirve tal cual. |
| TLS y keep-alive | Keep-alive activo (predeterminado de .NET). Solo añade TLS 1.2 (OR) a `ServicePointManager.SecurityProtocol` cuando el valor actual **no** es `SystemDefault` (0); con `SystemDefault` deja que Windows negocie, así que TLS 1.3 sigue disponible donde el sistema lo soporta. |

Consecuencias para el servidor (todas implementadas):

- Si la PC se apaga o LidaPrint se reinicia a mitad de un lote, los trabajos
  reclamados quedan en `printing` sin ack y el agente no los vuelve a pedir.
  De esos trabajos se ocupa el cron de §8.1.
- Un trabajo puede pasar bastante tiempo en `printing`: un lote de 10 se
  imprime en serie y las descargas fallidas solo se reintentan mientras los
  polls funcionan. La cota real la pone la caducidad local de LidaPrint: a los
  10 minutos de recibirlo, el agente o ya lo imprimió o renunció a él. Por eso
  el umbral del cron de trabajos atascados es **mayor** que esos 10 minutos:
  15 por defecto, nunca menos de 12 (`MIN_STUCK_MINUTES`, §8.1).
- Un ack puede llegar tarde (se reintenta antes de cada poll y sobrevive a
  reinicios) o no llegar nunca (se descarta a los 60 minutos). Un ack tardío
  sobre un trabajo ya `done` o `error` se ignora (§8.3) y los que nunca llegan
  los resuelve el cron.
- El servidor responde **401 tanto a tokens revocados como a equipos
  archivados** (`active = False`), y un 401 no tiene efectos secundarios: ni
  `last_seen`, ni `hostname`/`version`/`printer`, ni reclamo de trabajos
  (§6.1).

### 2.2 Quién consulta a Odoo (y quién no)

**Solo consulta el agente LidaPrint**, y solo cuando su `config.json` tiene
`mode = "cloud"` con `cloudUrl` y `cloudToken` definidos. No generan ningún
tráfico de consultas:

- las PC sin LidaPrint instalado;
- las PC cuyo LidaPrint está en modo `local` o `api` (Red local);
- **ningún navegador ni cliente web de Odoo**, sea cual sea el número de
  usuarios conectados.

El módulo **no añade ninguna consulta del lado del navegador**: ni
temporizadores JS, ni suscripciones al bus, ni longpolling.
`static/src/lidaprint_report_handler.js` sigue haciendo una sola llamada por
clic. El botón «Imprimir Forma Libre» (y el despacho de reportes marcados)
solo crea los trabajos en el servidor y devuelve una notificación; el estado
posterior se consulta abriendo el trabajo o la factura, no en vivo.

La carga del servidor escala con el **número de equipos Nube registrados y
activos**, no con el número de usuarios ni de PC de la empresa (§10).

---

## 3. Punto de partida: el módulo antes de 18.0.2.4.0

Estado **histórico** (18.0.2.3.2), del que partió la implementación:

| Pieza | Archivo | Qué hacía |
|---|---|---|
| Cliente push | `tools/lidaprint.py` | Parámetros `ENABLE_PARAM`, `URL_PARAM`, `API_KEY_PARAM`; `get_config()`, `is_available()` (`GET /print/status`, 5 s), `upload_pdf()` (`POST /print/file`, 30 s, límite de 50 MB), `ensure_ready()` (`UserError`), `LidaPrintError`. |
| Forma Libre | `models/account_move.py` | `action_l10n_ve_lidoo_print_factura()` con el interruptor encendido hacía dos pasadas por documento (contador + 1 -> `_render_qweb_pdf` -> `upload_pdf`); la segunda sale con la leyenda COPIA porque `l10n_ve_lidoo_is_print_copy` vale `copy_number > 1`. Compensaba fallos parciales con una notificación `danger` sticky. |
| Otros reportes | `models/ir_actions_report.py` | Campo `l10n_ve_lidoo_lidaprint_print`; `l10n_ve_lidoo_lidaprint_dispatch()` (llamado por el JS) renderizaba una copia y la subía; excluye la Forma Libre. |
| Ajustes | `models/res_config_settings.py`, `views/res_config_settings_views.xml` | Interruptor «Imprimir Forma Libre con LidaPrint», URL, API Key, reportes y «Probar conexión». |
| Handler JS | `static/src/lidaprint_report_handler.js` | Notificación con `type: "success"` fijo. |
| Guardia de rutas | `decorators/__init__.py`, `tests/test_route_coverage.py` | Solo `require_api_key()`; el test exigía 5 controladores y 5 rutas `POST`/`auth='public'`. |

La rama Red local de `action_l10n_ve_lidoo_print_factura` se saltaba la
validación de lote de `l10n_ve_lidoo_invoice_report` (una compañía y una
variante de formato); 18.0.2.4.0 la corrige (`[FIX]` en `RELEASE_NOTES.md`):
las tres ramas que imprimen llaman a `_l10n_ve_lidoo_validate_factura_print()`.

### Nombres

El brief original hablaba de `lidaprint.device`, `lidaprint.job` y
`lidaprint_device_id`. El módulo sigue la convención del repo (prefijo
`l10n_ve_lidoo.` en los modelos y `l10n_ve_lidoo_` en los campos añadidos a
modelos ajenos):

| Brief | Implementado |
|---|---|
| `lidaprint.device` | `l10n_ve_lidoo.lidaprint.device` (tabla `l10n_ve_lidoo_lidaprint_device`) |
| `lidaprint.job` | `l10n_ve_lidoo.lidaprint.job` (tabla `l10n_ve_lidoo_lidaprint_job`) |
| wizard del token | `l10n_ve_lidoo.lidaprint.token.wizard` (`models/lidaprint_token_wizard.py`) |
| `res.users.lidaprint_device_id` | `res.users.l10n_ve_lidoo_lidaprint_device_id` |
| dispositivo por defecto de la compañía | `res.company.l10n_ve_lidoo_lidaprint_default_device_id` |

Los campos propios de los modelos nuevos van sin prefijo (`state`,
`attempts`, …), como en `l10n_ve_lidoo.webhook.event`.

---

## 4. Modelos

Archivos: `models/lidaprint_device.py`, `models/lidaprint_job.py`,
`models/lidaprint_token_wizard.py`, `models/res_company.py`,
`models/res_users.py`, más `tools/lidaprint_cloud.py` para la lógica pura.

### 4.1 Lógica pura — `tools/lidaprint_cloud.py`

Sin `import odoo`: se prueba en `tests_pure/test_lidaprint_cloud.py` con
`load_pure`, sin arrancar Odoo. Sus límites son parte del contrato con
LidaPrint.

| Constante | Valor | Uso |
|---|---|---|
| `MIN_POLL` / `MAX_POLL` | 1 / 300 | Límites de `next_poll` (los mismos que aplica LidaPrint) |
| `DEFAULT_POLL_BUSY` / `DEFAULT_POLL_IDLE` | 3 / 30 | Segundos en horario laboral / fuera de él |
| `DEFAULT_HOURS` | `"07:00-19:00"` | Horario laboral de fábrica |
| `CLAIM_LIMIT` | 10 | Trabajos por poll |
| `MAX_PDF_BYTES`, `PDF_MAGIC` | 50 MB, `b"%PDF-"` | Reglas del PDF (también las usa `tools/lidaprint.upload_pdf`) |
| `ACK_STATUSES`, `MAX_ACK_MESSAGE` | `("done", "error")`, 2000 | Validación del ack |
| `MAX_REPORTED_VALUE` | 128 | Largo máximo de `hostname`, `version`, `printer` |
| `ONLINE_SECONDS` | 60 | Umbral «en línea» mínimo |
| `LAST_SEEN_WRITE_SECONDS` | 15 | Throttle de `last_seen` |
| `AGENT_EXPIRY_MINUTES` | 10 | Caducidad local del agente (referencia) |
| `DEFAULT_STUCK_MINUTES` / `MIN_STUCK_MINUTES` | 15 / 12 | Umbral del cron de trabajos atascados |

| Función | Qué hace |
|---|---|
| `hash_token(token)` | SHA-256 hex; en la base solo se guarda esto |
| `bearer_token(authorization)` | Token de `Authorization: Bearer <token>` (esquema sin distinguir mayúsculas); `""` con otro esquema o sin cabecera |
| `clamp_poll(seconds, default)` | Acota a [1, 300]; valor inválido -> `default` |
| `is_valid_hours(value)` / `parse_hours(value, default)` | `HH:MM-HH:MM`; `parse_hours` devuelve `(time, time)` y, con un valor inválido, el horario de fábrica. Un inicio posterior al fin (`22:00-06:00`) es un horario que **cruza la medianoche** |
| `in_business_hours(local_time, hours)` | Dentro del horario, también con rangos que cruzan la medianoche |
| `next_poll(local_now, busy, idle, hours, has_more)` | `1` si el poll llenó el cupo; si no, `busy` o `idle` según el horario |
| `online_seconds(busy, idle)` | `max(60, 2 × intervalo más largo)` |
| `stuck_minutes(value)` | Minutos del cron, nunca menos de 12; inválido -> 15 |
| `parse_ack(data)` | `(status, message)` o `ValueError`; `status` debe ser el texto `done` o `error` |
| `pdf_problem(content)` | `None`, `"too_large"` o `"not_pdf"` |
| `reported_value(value)` | Texto del agente recortado; `""` si no es un escalar |
| `version_from_user_agent(ua)` | `"LidaPrint/1.8.0"` -> `"1.8.0"` |
| `is_quiet_access_line(message)` | Regex de la línea de acceso de un poll con 200 (§9.4) |

Los parámetros de `ir.config_parameter` viven en `tools/lidaprint.py`
(`DESTINATION_PARAM`, `CLOUD_POLL_BUSY_PARAM`, `CLOUD_POLL_IDLE_PARAM`,
`CLOUD_HOURS_PARAM`, `CLOUD_STUCK_MINUTES_PARAM`, junto a los de Red local);
ver §6.4 y §7.1.

### 4.2 `l10n_ve_lidoo.lidaprint.device`

Un registro por PC con LidaPrint (`models/lidaprint_device.py`). El token en
claro **nunca** se guarda: solo su SHA-256, y se muestra una sola vez al
generarlo.

| Campo | Notas |
|---|---|
| `name`, `company_id`, `active`, `tz` | `tz` por defecto `America/Caracas`: zona en la que se evalúa el horario laboral |
| `token_hash` | `groups="base.group_system"`, `copy=False`; restricción `unique(token_hash)` (admite varios NULL) |
| `has_token` | **Guardado**, no computado: `token_hash` está restringido a administradores y la vista necesita saber qué botón mostrar. Lo mantienen los dos botones del token |
| `last_seen`, `hostname`, `previous_hostname`, `version`, `printer` | Solo lectura, los informa el agente |
| `online` | Computado: `last_seen` dentro de `online_seconds(busy, idle)` según Ajustes |
| `job_ids` | Trabajos del equipo |

Métodos:

- `action_generate_token()` y `action_revoke_token()` llaman a
  `self.check_access("write")` **antes** del `sudo()`. Los usuarios internos
  pueden **leer** equipos (para elegir «Imprimir en»); sin esa verificación
  cualquiera podría rotar el token por RPC y quedarse con uno válido. Generar
  escribe `token_hash` y `has_token = True` y abre el wizard; revocar vacía
  los dos.
- `_l10n_ve_lidoo_touch(hostname, version, printer)`: escribe `last_seen` como
  mucho cada 15 s y solo lo que cambió. Si cambia el `hostname`, guarda el
  anterior en `previous_hostname` y deja un **WARNING** en el log (¿dos PC con
  el mismo token?).
- `_l10n_ve_lidoo_next_poll(has_more)`: `next_poll()` con la hora local del
  equipo.
- `_l10n_ve_lidoo_status_line()` y `_l10n_ve_lidoo_notification_params()`:
  textos de «Probar conexión» (§7.5) y de las notificaciones al encolar.

Wizard (`models/lidaprint_token_wizard.py`, vista
`views/lidaprint_token_wizard_views.xml`): muestra el token con
`widget="CopyClipboardChar"` y el aviso «Copie este token en el Configurador de
LidaPrint (pestaña Conexión > Nube). No se volverá a mostrar.».
`action_done` («Listo, ya lo copié») borra el token en claro antes de cerrar;
si el usuario cierra con la X, queda en la tabla transitoria hasta el
autovacuum (1 h), legible solo por administradores (ACL del wizard).

### 4.3 `l10n_ve_lidoo.lidaprint.job`

Un registro por PDF a imprimir (`models/lidaprint_job.py`). La Forma Libre
genera dos (original y copia). Todos los campos son de solo lectura en la
interfaz: los crea el servidor y los mueven el agente y el cron.

| Campo | Notas |
|---|---|
| `device_id` (`ondelete="restrict"`), `company_id` | La compañía se toma del equipo |
| `move_id` (`ondelete="set null"`), `reference` | Documento de origen; `reference` guarda p. ej. `account.move,7` o `res.partner,7` |
| `pdf` (`attachment=True`), `filename`, `file_size` | |
| `state` | `pending`, `printing` («Imprimiendo»), `done`, `error` |
| `error_source` | `agent` (informado por LidaPrint), `timeout` (cron), `cancel` |
| `claimed_at`, `printed_at`, `attempts`, `error_message` | `attempts` = descargas del PDF |
| `requested_by`, `reprint_of_id` | Quién imprimió; trabajo de origen de una reimpresión |

```
pending --poll--> printing --ack done---> done
   |                 |------ack error--> error (agent)
   |                 '------cron-------> error (timeout)
   '---cancelar------------------------> error (cancel)
```

Índices parciales, creados en `init()` con `odoo.tools.sql.create_index`:

- `l10n_ve_lidoo_lidaprint_job_pending_idx` sobre `(device_id, id)`
  `WHERE state = 'pending'`: el reclamo del poll;
- `l10n_ve_lidoo_lidaprint_job_printing_idx` sobre `(claimed_at)`
  `WHERE state = 'printing'`: el cron de trabajos atascados.

Operaciones:

- `_l10n_ve_lidoo_enqueue(device, filename, pdf_content, move, reference,
  reprint_of)`: aplica `pdf_problem()` (mismo criterio que LidaPrint, para
  rechazar con el usuario delante y no como ack de error minutos después) y
  crea el trabajo en `sudo()`.
- `_l10n_ve_lidoo_claim(device, limit=10)`: reclamo atómico. El SQL se arma
  con `odoo.tools.SQL`, la hora es `fields.Datetime.now()` de Python y el
  UPDATE escribe también `write_uid`:

  ```python
  now = fields.Datetime.now()
  self.env.cr.execute(SQL(
      """
      UPDATE %(table)s AS job
         SET state = 'printing', claimed_at = %(now)s,
             write_date = %(now)s, write_uid = %(uid)s
       WHERE job.id IN (SELECT id FROM %(table)s
                         WHERE device_id = %(device)s AND state = 'pending'
                         ORDER BY id LIMIT %(limit)s
                           FOR UPDATE SKIP LOCKED)
   RETURNING job.id, job.filename, job.file_size
      """,
      table=SQL.identifier(self._table), now=now, uid=self.env.uid,
      device=device.id, limit=limit,
  ))
  ```

  `FOR UPDATE SKIP LOCKED`: dos polls concurrentes (dos workers, o dos agentes
  con el mismo token por error) nunca reclaman la misma fila y ninguno espera
  al otro. Las filas se ordenan en Python (`RETURNING` no garantiza orden).
- `_l10n_ve_lidoo_apply_ack(status, message)`: §8.3.
- `_cron_l10n_ve_lidoo_expire_stuck_jobs()`: §8.1.
- `action_l10n_ve_lidoo_reprint()` y `action_l10n_ve_lidoo_cancel()`: §8.2.

Retención: los PDF se conservan como traza, sin purga (§14).

### 4.4 Vistas y menús

Equipos (`views/lidaprint_device_views.xml`, acción `action_lidaprint_device`),
**solo para administradores** (`base.group_system`), por dos caminos:

- **Ajustes > API de integración > LidaPrint**, botón **«Equipos LidaPrint»**.
  Se ve con **cualquier** destino de impresión, para poder crear los equipos y
  copiar su token en LidaPrint antes de pasar el destino a Nube.
- Menú **Facturación > Configuración > Equipos LidaPrint** (padre
  `account.menu_finance_configuration`).

Formulario del equipo: en la cabecera, **Generar token** (con `confirm` si ya
hay token: «El token anterior dejará de funcionar de inmediato…») y **Revocar
token**, ambos con `groups="base.group_system"`; cinta «Archivado»; grupos
«Configuración» (compañía, zona horaria, token generado) e «Informado por
LidaPrint» (en línea, última conexión, equipo, equipo anterior si lo hay,
versión, impresora); pestaña con sus trabajos.

Trabajos (`views/lidaprint_job_views.xml`, acción `action_lidaprint_job`, con
el filtro «Por atender» por defecto): botón «Trabajos LidaPrint» del mismo
bloque de Ajustes (visible con cualquier destino) y menú **Facturación >
Configuración > Trabajos LidaPrint**, ambos para administradores. Los usuarios
de facturación los ven desde el smart button «Trabajos LidaPrint» de la factura
(`views/account_move_views.xml`). Lista y formulario muestran **Cancelar**
(solo `pending`) y **Reenviar el original** (solo `error` con
`error_source = 'agent'`), con `groups="account.group_account_invoice"` y
`confirm` (§8.2).

Preferencia «Imprimir en»: `views/res_users_views.xml`, en Mis preferencias y
en el formulario de usuario.

---

## 5. Enrutamiento: a qué equipo va cada impresión

`res.users._l10n_ve_lidoo_lidaprint_device(company)`, en este orden:

1. Preferencia del usuario **«Imprimir en»**
   (`res.users.l10n_ve_lidoo_lidaprint_device_id`), si está activa y pertenece
   a la compañía del documento.
2. Equipo por defecto de la compañía
   (`res.company.l10n_ve_lidoo_lidaprint_default_device_id`).
3. Ninguno -> `UserError` explícito **antes** de tocar contadores o renderizar.

Detalles de la implementación:

- `res.users` añade el campo a `SELF_READABLE_FIELDS` y
  `SELF_WRITEABLE_FIELDS`: cada usuario lo cambia desde Mis preferencias sin ser
  administrador.
- `res.company` restringe el equipo por defecto a su propia compañía: dominio
  `[('company_id', '=', id)]` y una restricción `@api.constrains` que lanza
  `ValidationError` si el equipo es de otra compañía. En Ajustes el campo es un
  `related` editable con el mismo dominio.

POS: el cajero que imprime es `env.user`, así que la preferencia por usuario
funciona si cada caja tiene su usuario. Si varios equipos comparten usuario
hará falta un mapeo `pos.config` -> equipo en `l10n_ve_lidoo_pos` (abierto,
§14).

---

## 6. Controladores

`controllers/lidaprint_cloud.py` (clase `LidaPrintCloudController`) y el
decorador `require_device_token()` de `decorators/__init__.py`.

### 6.1 Guardia por token de equipo

Mismo patrón que `require_api_key()`: el decorador va **encima** de `route` y
deja la marca `DEVICE_TOKEN_GUARD_ATTR`, que `tests/test_route_coverage.py`
exige en cada ruta del modo Nube.

```python
token = bearer_token(request.httprequest.headers.get("Authorization"))
devices = request.env["l10n_ve_lidoo.lidaprint.device"].sudo()
device = (
    devices.search([("token_hash", "=", hash_token(token))], limit=1, order="id")
    if token else devices
)
if not device:
    _logger.warning("LidaPrint nube: token rechazado en %s", func.__name__)
    return request.make_json_response({"ok": False, "error": "unauthorized"}, status=401)
request.update_env(user=SUPERUSER_ID)
kwargs["device"] = device.with_env(request.env)   # pisa cualquier ?device=
```

- Equipos archivados: `search()` aplica el filtro implícito `active = True`,
  así que un equipo archivado recibe 401 igual que un token revocado. No se usa
  `active_test=False`.
- La búsqueda por hash no necesita `hmac.compare_digest`: el cliente no
  controla el hash y el tiempo de una búsqueda por índice no revela nada útil.
- Un 401 no tiene efectos secundarios. Como LidaPrint espacia los reintentos
  (60 s, luego 300 s), el WARNING sale como mucho una vez cada cinco minutos
  por agente mal configurado.
- Con el token válido la petición pasa a OdooBot (`SUPERUSER_ID`): con
  `auth='none'` el entorno llega sin usuario y `message_post` fallaría sin
  autor.

### 6.2 El controlador

```python
BASE = "/lidaprint/v1"
_ROUTE = {
    "type": "http",
    "auth": "none",
    "csrf": False,
    "save_session": False,
    "readonly": False,
}
```

- **`readonly=False`**: en Odoo 18 una ruta `auth='none'` se declara de solo
  lectura por defecto (`odoo/http.py`). Con una réplica configurada
  (`db_replica_host`) correría en el cursor de la réplica y la primera
  escritura obligaría a repetir la petición entera en el primario; las cuatro
  rutas escriben (`last_seen`, reclamo, `attempts`, ack).
  `tests/test_route_coverage.py` lo exige.
- Todo corre como OdooBot (§6.1): el ORM del controlador no aplica reglas de
  acceso, la separación entre equipos la da el filtro explícito por
  `device_id` (`_device_job()` y el reclamo) y la compañía se toma siempre del
  equipo, nunca de `request.env.company`. `create_uid`/`write_uid` y el autor de
  las notas del agente son OdooBot.
- **Poll sin `_handle`**: con token válido responde siempre 200. Una excepción
  inesperada sale como 500 y LidaPrint aplica su backoff; los conflictos de
  serialización los reintenta Odoo (`odoo.service.model.retrying`).
- **Ack sin `_handle`**: solo los errores del cliente se traducen a 4xx (404 si
  el trabajo no es del equipo; 400 si `parse_ack` o `_parse_body` rechazan el
  cuerpo). Un conflicto de serialización con el cron (el ack bloquea la fila)
  llega a `retrying` y Odoo lo reintenta; `_handle` lo habría convertido en un
  500 sin reintento.
- **PDF**: `404 job not found` si el trabajo no es del equipo o no está en
  `printing`. Es la segunda barrera contra la doble impresión: un trabajo que
  el cron ya pasó a error no se puede descargar.
- `_optional_body()`: el poll nunca falla por el cuerpo.

El mismo archivo instala el filtro del log de acceso (§9.4).

### 6.3 Resolución de la base de datos con `auth='none'`

LidaPrint no guarda cookies (`save_session=False` y cada petición es
independiente), así que Odoo elige la base en
`Request._get_session_and_dbname()` (`odoo/http.py`): sin sesión, toma
`db_list(force=True, host=host)` filtrada por `dbfilter` y **solo** si queda
exactamente una base (monodb). Si no se resuelve ninguna, la petición cae en
`_serve_nodb()`, que solo conoce rutas de los módulos *server-wide*: la ruta
responde **HTML 404** aunque el módulo esté instalado (el mismo síntoma que el
README del módulo documenta para `/api/*`). En LidaPrint aparece como «URL
incorrecta o base de datos no resuelta» (§2.1).

Opciones, de la preferida a la menos:

1. **Una sola base por instancia** (lo habitual en un VPS por cliente). No
   hay nada que hacer.
2. **`dbfilter` por dominio**: `dbfilter = ^%d$` (primer subdominio) o
   `^%h$` (host completo). El `cloudUrl` de LidaPrint usa ese dominio.
   Recomendada para instancias con varias bases.
3. **`dbfilter_from_header`** (módulo OCA documentado en el README del módulo:
   `proxy_mode = True`, `server_wide_modules = web,dbfilter_from_header`): el
   proxy inyecta `X-Odoo-dbfilter` por vhost o en `location /lidaprint/`.
   LidaPrint no envía esa cabecera (no está en el contrato), así que la debe
   poner nginx.
4. **`?db=` en la URL: no sirve.** En Odoo 18 solo `web/controllers/utils.py`
   (`ensure_db`) lee ese parámetro, y únicamente para `/web`. Además LidaPrint
   quita cualquier query de `cloudUrl`.

Prueba: `curl -H "Authorization: Bearer x" https://dominio/lidaprint/v1/ping`
debe responder **401 JSON**; un HTML 404 es que la base no se resolvió.

### 6.4 `next_poll` controlado por el servidor

El servidor decide el ritmo con tres parámetros de `ir.config_parameter`
(constantes en `tools/lidaprint.py`), editables en Ajustes (§7.4):

| Parámetro | Defecto | Uso |
|---|---|---|
| `lida_integration_api.lidaprint_cloud_poll_busy` | `3` | Segundos en horario laboral |
| `lida_integration_api.lidaprint_cloud_poll_idle` | `30` | Segundos fuera de horario |
| `lida_integration_api.lidaprint_cloud_hours` | `07:00-19:00` | Horario laboral, en la zona horaria del equipo (`tz`); admite rangos que cruzan la medianoche (`22:00-06:00`) |

Si un poll llenó el cupo de 10 trabajos se responde `next_poll: 1` para vaciar
la cola rápido. Un valor inválido guardado a mano cae en los de fábrica
(`clamp_poll`, `parse_hours`). LidaPrint acota cualquier valor a [1, 300].

Umbral de «en línea»: `online_seconds(busy, idle) = max(60, 2 × intervalo más
largo)`. Con los valores de fábrica son 60 s, por encima del intervalo fuera de
horario más el throttle de `last_seen` (30 + 15); si se alarga un intervalo, el
umbral sube solo y el equipo no parpadea entre en línea y desconectado. El
*keep-alive* del agente entre trabajos de un lote (§2.1) mantiene `last_seen`
al día durante lotes largos.

---

## 7. Despacho: destino de impresión

### 7.1 Destino en `tools/lidaprint.py`

Un selector sustituye al interruptor booleano, con compatibilidad hacia atrás
igual que en LidaPrint (`mode` frente a `webEnabled`):

| Destino | Valor | Comportamiento |
|---|---|---|
| Navegador | `browser` | Descarga del PDF (flujo estándar) |
| Red local (API) | `lan` | Push a `POST /print/file` |
| Nube | `cloud` | Cola de trabajos (esta guía) |

- `get_config(env)`: `DESTINATION_PARAM` gana si existe; si no, se deriva de
  `ENABLE_PARAM` (encendido = `lan`, apagado = `browser`). Conserva
  `enabled` (destino distinto del navegador) para el código y los tests que ya
  lo leían.
- `set_destination(env, destination)`: escribe el destino y, por
  compatibilidad, `ENABLE_PARAM` (`"True"` con cualquier destino distinto del
  navegador; se borra con el navegador). Los dos parámetros nunca se
  contradicen.

### 7.2 Forma Libre: `models/account_move.py`

`action_l10n_ve_lidoo_print_factura()` elige la rama por destino: `browser`
delega en `super()`, `cloud` llama a `_l10n_ve_lidoo_lidaprint_print_cloud()`
y `lan` sigue con el push (ahora con la validación de lote).

`_l10n_ve_lidoo_lidaprint_print_cloud()`:

1. `_l10n_ve_lidoo_validate_factura_print()`: imprimible, una compañía y una
   variante de formato por lote.
2. Resuelve el equipo (§5): `UserError` antes de tocar ningún contador.
3. Por documento, dos pasadas: contador + 1 -> `_render_qweb_pdf` ->
   `_l10n_ve_lidoo_enqueue(...)`. El nombre sale de
   `_l10n_ve_lidoo_lidaprint_filename()` (`<nombre>-forma-libre.pdf` /
   `<nombre>-copia-forma-libre.pdf`); la leyenda COPIA la sigue decidiendo el
   contador, sin tocar el QWeb.
4. Cualquier excepción aborta el lote completo: no hay «error parcial» como en
   Red local, o se encola todo o nada.
5. Notificación de `_l10n_ve_lidoo_lidaprint_cloud_notification()`: `success`
   con el equipo en línea; `warning` persistente con la última conexión si
   está desconectado. Los trabajos quedan en cola igual.

### 7.3 Otros reportes: `models/ir_actions_report.py`

`l10n_ve_lidoo_lidaprint_dispatch()`: con `browser` devuelve
`{"handled": False}`; en `cloud` no llama a `ensure_ready()`, resuelve el
equipo **antes** del render (`self.env.user._l10n_ve_lidoo_lidaprint_device(
self.env.company)`) y crea **un** trabajo con
`_l10n_ve_lidoo_lidaprint_enqueue_report()` (enlazado a la factura si el
reporte es de un solo `account.move`; `reference` guarda el origen). Devuelve
`handled`, `title`, `message`, `type` y `sticky`.

`static/src/lidaprint_report_handler.js` usa `type` y `sticky` de la respuesta
(`type: result.type || "success"`). Sigue siendo una sola llamada por clic.

### 7.4 Ajustes

`models/res_config_settings.py` y el bloque `l10n_ve_lidoo_lidaprint` de
`views/res_config_settings_views.xml`:

- `l10n_ve_lidoo_lidaprint_destination` (`Selection` «Navegador (descargar
  PDF)» / «Red local (API)» / «Nube», radio «Destino de impresión»), **sin**
  `config_parameter`: se lee con `get_config()` en `get_values()` y se escribe
  con `set_destination()` después de `super().set_values()`.
- `l10n_ve_lidoo_lidaprint_enable` se conserva en Python por compatibilidad
  pero ya no está en la vista.
- Con destino Red local: URL y API Key.
- Con destino Nube: equipo por defecto (`related` a la compañía), consulta en
  horario y fuera de horario (s), horario laboral y **trabajos sin
  confirmación (min)** (`lidaprint_cloud_stuck_minutes`).
- Con **cualquier** destino: botones «Equipos LidaPrint» y «Trabajos
  LidaPrint».
- Con destino distinto del navegador: reportes marcados y «Probar conexión».
- Al guardar, `_l10n_ve_lidoo_lidaprint_check_cloud_values()` rechaza con
  `UserError` intervalos fuera de 1–300 s, un horario que no sea
  `HH:MM-HH:MM` y un umbral de trabajos sin confirmación por debajo de 12
  minutos.

### 7.5 «Probar conexión» en modo Nube

`action_l10n_ve_lidoo_lidaprint_test_connection()` lee el destino del
formulario (no el guardado). En `lan` hace `GET /print/status`. En `cloud`
(`_l10n_ve_lidoo_lidaprint_cloud_status()`) no hay nada a qué conectarse desde
el servidor: informa el estado de los equipos de la compañía a partir de
`last_seen` («Caja 1: en línea (hace 4 s) · LidaPrint 1.8.0 · EPSON LX-350»,
«Caja 2: sin conexión desde 2026-09-14 10:32»). `success` si el equipo por
defecto está en línea; `danger` persistente si no hay equipos, si falta el
equipo por defecto o si está desconectado.

La prueba de extremo a extremo es «Probar conexión» del Configurador de
LidaPrint, que llama a `GET /ping`.

---

## 8. Seguridad fiscal

### 8.1 Trabajos atascados: cron, nunca reencolar

Cron `ir_cron_lidaprint_expire_stuck_jobs` («LIDALabs: LidaPrint, trabajos sin
confirmación a error», cada 5 minutos, `data/ir_cron_data.xml`) ->
`_cron_l10n_ve_lidoo_expire_stuck_jobs()`. Un trabajo en `printing` sin ack
durante más de N minutos (`lida_integration_api.lidaprint_cloud_stuck_minutes`,
**15** por defecto, nunca menos de **12** por `stuck_minutes()`) pasa a `error`
con `error_source = 'timeout'` y el mensaje «LidaPrint no confirmó la impresión
a tiempo. Verifique el papel antes de reimprimir: pudo haberse impreso.».
**Nunca vuelve a `pending`**: si la impresora llegó a imprimir antes de que la
PC se colgara, reencolarlo sacaría un segundo original.

El UPDATE usa `odoo.tools.SQL`, escribe `write_date` y `write_uid`, y el umbral
se calcula en Python: `fields.Datetime.now() - timedelta(minutes=N)`, igual que
`claimed_at` (los dos en UTC, desde el mismo reloj). El índice parcial
`printing_idx` evita recorrer la tabla completa.

Por qué N debe superar la caducidad local de LidaPrint (10 minutos, §2.1):
cuando el cron marca el error, el operador puede reimprimir desde la factura.
Si el cron se adelantara a la caducidad, el trabajo viejo podría seguir en la
cola local del agente y salir en papel **después** de la reimpresión: doble
impresión fiscal. Con N > 10, cuando Odoo marca el error el agente ya lo
imprimió (y su ack tardío se ignora, §8.3) o ya renunció a él. Del lado del
agente la caducidad usa un reloj monótono y se vuelve a comprobar justo antes
de imprimir, así que un cambio de hora de Windows o una descarga lenta no la
alargan. Hay una segunda barrera: `GET /job/<id>/pdf` solo sirve trabajos en
`printing` (§6.2).

### 8.2 Reimprimir y cancelar

Regla general: **toda reimpresión crea un trabajo nuevo** (id nuevo, estado
`pending`, `reprint_of_id` al de origen). Nunca se devuelve a `pending` un
trabajo existente: LidaPrint no volvería a imprimir un id que ya trató en la
sesión y se perdería el historial.

- **Desde la factura**: «Imprimir Forma Libre» es la reimpresión segura: el
  contador sube y los dos PDF salen como **COPIA**. El smart button «Trabajos
  LidaPrint» muestra qué pasó con cada impresión.
- **«Reenviar el original»** (`action_l10n_ve_lidoo_reprint`): solo con
  `state = 'error'` y `error_source = 'agent'` (LidaPrint informó que no pudo
  imprimir). Con `timeout` se desconoce si salió en papel y con `cancel` fue
  una decisión del operador: se rechaza en Python, no solo en la vista, y la vía
  es reimprimir desde la factura (COPIA). Rechaza también un equipo
  **archivado** (el trabajo nunca se imprimiría). Crea el trabajo nuevo con los
  mismos bytes, deja nota en el chatter de la factura con el usuario como autor
  y recarga la vista.
- **Cancelar** (`action_l10n_ve_lidoo_cancel`): trabajos `pending` -> `error`
  con `error_source = 'cancel'`, para un equipo que quedó desconectado y se
  decidió imprimir por otra vía (los pendientes no caducan). **Por lotes, todo o
  nada**: si alguno no está en `pending` se rechaza el lote, y el UPDATE
  condicionado a `pending` revierte el lote entero si un poll concurrente
  reclamó alguno. Deja nota en la factura de cada trabajo.

Quién: usuarios de facturación (`account.group_account_invoice`), con
`confirm` en los botones. Como esos usuarios solo **leen** trabajos
(`ir.model.access.csv`) y la escritura va en `sudo()`,
`_l10n_ve_lidoo_check_operator()` verifica en Python el grupo, el acceso de
lectura (ACL y reglas multicompañía) y que la compañía del trabajo esté entre
las activas del usuario (`AccessError` si no).

### 8.3 Idempotencia del ack

Reglas de `_l10n_ve_lidoo_apply_ack()`:

| Estado actual | Ack `done` | Ack `error` |
|---|---|---|
| `printing` | -> `done`, `printed_at` | -> `error`, `error_source = agent`, mensaje (o «Error sin detalle») |
| `error` por `timeout` (ack tardío) | sin cambios; log y nota en la factura (autor OdooBot) | sin cambios; igual |
| `done` | sin cambios (log) | sin cambios (log) |
| `error` por `agent` o `cancel` | sin cambios (log) | sin cambios (log) |
| `pending` (no reclamado) | sin cambios (se registra en el log) | sin cambios (se registra en el log) |

Solo un trabajo en `printing` cambia de estado. El resultado ya registrado
nunca se sobrescribe: un «done» tardío sobre un trabajo que el cron pasó a
error, y que el operador quizá ya reimprimió, no lo convierte en impreso a
escondidas.

En todos los casos la respuesta es `200 {"ok":true}`. Solo hay 404 si el
trabajo no es del equipo (LidaPrint descarta ese ack sin reintentarlo) y 400 si
el cuerpo no trae un `status` válido. Un `SELECT … FOR UPDATE` sobre la fila
(armado con `SQL`) serializa el ack contra el cron y contra acks repetidos.

---

## 9. Seguridad

### 9.1 Accesos y reglas multicompañía

`security/ir.model.access.csv`:

```csv
access_l10n_ve_lidoo_lidaprint_device_system,l10n_ve_lidoo.lidaprint.device system,model_l10n_ve_lidoo_lidaprint_device,base.group_system,1,1,1,1
access_l10n_ve_lidoo_lidaprint_device_user,l10n_ve_lidoo.lidaprint.device read,model_l10n_ve_lidoo_lidaprint_device,base.group_user,1,0,0,0
access_l10n_ve_lidoo_lidaprint_job_system,l10n_ve_lidoo.lidaprint.job system,model_l10n_ve_lidoo_lidaprint_job,base.group_system,1,1,0,1
access_l10n_ve_lidoo_lidaprint_job_invoice,l10n_ve_lidoo.lidaprint.job read,model_l10n_ve_lidoo_lidaprint_job,account.group_account_invoice,1,0,0,0
access_l10n_ve_lidoo_lidaprint_token_wizard_system,l10n_ve_lidoo.lidaprint.token.wizard system,model_l10n_ve_lidoo_lidaprint_token_wizard,base.group_system,1,1,1,1
```

- Los usuarios internos leen equipos (para elegir «Imprimir en»); el campo
  `token_hash` lleva `groups="base.group_system"` y los botones del token
  verifican `check_access('write')` (§4.2).
- Nadie crea trabajos por la interfaz: se crean en `sudo()` desde
  `_l10n_ve_lidoo_enqueue()`. Reimprimir y cancelar se verifican en Python
  (§8.2).

`security/lidaprint_security.xml`: reglas globales
`[('company_id', 'in', company_ids)]` sobre equipos y trabajos. Los endpoints
del agente corren como OdooBot, así que ahí la separación entre equipos la
garantiza el filtro explícito por `device_id`, no estas reglas.

### 9.2 Tokens

- 32 bytes de `secrets.token_urlsafe` (43 caracteres de `[A-Za-z0-9_-]`); se
  guarda solo el SHA-256 hex. El Configurador de LidaPrint avisa, sin
  bloquear, si el token pegado no tiene ese formato.
- **Revocar:** botón que vacía `token_hash` (y `has_token`), o archivar el
  equipo. El siguiente poll recibe 401 y LidaPrint registra el cambio de
  estado una sola vez; luego reintenta cada 60 s y, tras 3 respuestas 401
  seguidas, cada 300 s (~288 peticiones/día, sin efectos en la base). Para que
  deje de consultar del todo hay que cambiar el modo de LidaPrint en esa PC a
  `local` o `api` (o desinstalarlo).
- **Rotar:** «Generar token» otra vez; el anterior deja de funcionar al
  instante (con aviso de confirmación).
- Un token por PC. Compartirlo entre dos PC no rompe nada (`SKIP LOCKED`
  reparte los trabajos) pero imprime en la PC equivocada; el cambio de
  `hostname` queda en `previous_hostname` y como WARNING en el log (§4.2).

### 9.3 Solo HTTPS

- El token viaja en cada petición: exigir HTTPS en el proxy (redirigir o
  rechazar `http://` en `location /lidaprint/`). El módulo no valida el
  esquema; si se quisiera hacerlo en Odoo (`request.httprequest.scheme`),
  detrás de nginx solo es fiable con `proxy_mode = True` y
  `X-Forwarded-Proto` controlado por el proxy.
- LidaPrint (Configurador y monitor, misma regla, §2.1) solo acepta `http://`
  hacia hosts de red local, con aviso; con `http://` hacia un host público el
  Configurador no guarda y el monitor no arranca el ciclo Nube.

### 9.4 Silenciar el poll en el log de acceso

Con 50 equipos Nube cada 3 s serían 1,44 millones de líneas diarias. El log de
acceso sale por el logger `werkzeug`, al que Odoo 18 ya le cuelga su
`PerfFilter` (`odoo/netsvc.py`). Al final de `controllers/lidaprint_cloud.py`,
`_LidaPrintPollLogFilter` descarta solo los poll **exitosos** con
`is_quiet_access_line()`, una regex sobre la línea de acceso:

```python
_QUIET_ACCESS_LINE = re.compile(r'"POST /lidaprint/v1/poll(?:\?\S*)? HTTP/[\d.]+" 200 ')
```

Los 401 y los 500 del poll, y el resto de rutas, se siguen registrando. El
filtro se instala una sola vez por proceso (afecta a todas las bases de ese
Odoo), algo aceptable para una ruta propia del módulo. Alternativa sin código:
`location = /lidaprint/v1/poll { access_log off; ... }` en nginx.

---

## 10. Rendimiento

**Quién genera carga:** solo los agentes LidaPrint en modo `cloud` con
`cloudUrl` y `cloudToken` definidos (§2.2). Los navegadores, los usuarios de
Odoo y las PC sin LidaPrint o con LidaPrint en modo `local`/`api` no consultan
nada. Todas las cifras de esta sección son **por equipo Nube activo**; un
equipo revocado o archivado que siga configurado baja a ~1 petición cada
5 min (~288/día, unos 0,2 MB/día) y no escribe en la base.

### 10.1 Costo por equipo Nube

Una consulta sin trabajos, con keep-alive (sin renegociar TLS), ocupa unos
**0,5–1 KB** entre petición (cabeceras con el token, cuerpo de ~80 B) y
respuesta. Con ~0,8 KB por consulta:

| Intervalo | Consultas/día | Tráfico/día | Tráfico/mes (30 d) |
|---|---|---|---|
| 1 s | 86 400 | 43–86 MB (~69 MB) | ~2,1 GB |
| 3 s | 28 800 | 14–29 MB (~23 MB) | ~0,7 GB |
| 5 s | 17 280 | 9–17 MB (~14 MB) | ~0,4 GB |
| 3 s en horario (12 h) + 30 s fuera (12 h) | 15 840 | ~13 MB | ~0,4 GB |

Los PDF se suman aparte (una Forma Libre suele pesar decenas de KB por
copia). El ping de *keep-alive* solo aparece durante lotes de más de 30 s.

Keep-alive: .NET mantiene la conexión en su pool unos 100 s sin uso
(`ServicePointManager.MaxServicePointIdleTime`), y nginx la cierra según
`keepalive_timeout` (75 s por defecto). Con `next_poll` por encima de esos
valores cada consulta paga un handshake TLS (unos 4–6 KB más). Con 3 s y 30 s
no ocurre.

### 10.2 Carga en el servidor

**Estimación a medir**, suponiendo ~10 ms de worker por consulta sin trabajos
(autenticación por índice, `last_seen` con throttle, reclamo vacío). Columna
«worker»: fracción de un worker de Odoo ocupada solo por las consultas
(1,0 = un worker al 100 %).

| Equipos Nube activos | 1 s | 3 s | 5 s |
|---|---|---|---|
| 10 | 10 req/s · 0,10 worker | 3,3 req/s · 0,03 worker | 2 req/s · 0,02 worker |
| 50 | 50 req/s · 0,50 worker | 16,7 req/s · 0,17 worker | 10 req/s · 0,10 worker |
| 200 | 200 req/s · 2,0 workers | 66,7 req/s · 0,67 worker | 40 req/s · 0,40 worker |

Escrituras en la base: sin throttle, cada consulta haría un `UPDATE` de
`last_seen`; con el throttle de 15 s son N/15 por segundo (10 PC: 0,7/s;
50: 3,3/s; 200: 13,3/s). El reclamo sin pendientes es un sondeo del índice
parcial que no toca filas ni genera WAL.

Cómo medir los 10 ms: Odoo 18 ya añade al final de cada línea del log de
acceso el número de consultas SQL, el tiempo en SQL y el resto (el
`PerfFilter` de `odoo/netsvc.py`). Medir en staging con el filtro de §9.4
desactivado, o con `$request_time` de nginx.

La carga no depende del número de usuarios ni de navegadores abiertos: 200
usuarios con 10 equipos Nube cuestan lo mismo que 10 usuarios con 10 equipos.

Recomendación: 3 s en horario y 30 s fuera (los valores de fábrica). Con 200
equipos a 1 s harían falta dos workers solo para consultas.

### 10.3 Índices parciales

```sql
CREATE INDEX l10n_ve_lidoo_lidaprint_job_pending_idx
    ON l10n_ve_lidoo_lidaprint_job (device_id, id)
 WHERE state = 'pending';

CREATE INDEX l10n_ve_lidoo_lidaprint_job_printing_idx
    ON l10n_ve_lidoo_lidaprint_job (claimed_at)
 WHERE state = 'printing';
```

Los crea `init()` del modelo con `odoo.tools.sql.create_index` (§4.3). El
primero cubre el `WHERE device_id = … AND state = 'pending' ORDER BY id LIMIT
10` del reclamo; el segundo, el `WHERE state = 'printing' AND claimed_at < …`
del cron. Los dos son diminutos (solo filas pendientes o reclamadas) aunque la
tabla crezca dos filas por factura.

---

## 11. Pruebas

Convenciones del repo: `@tagged("post_install", "-at_install",
"l10n_ve_lidoo", "l10n_ve_lidoo_integration_api")`; `TransactionCase` para
modelos, `AccountTestInvoicingCommon` cuando hace falta contabilidad,
`HttpCase` para endpoints con el patrón de `tests/common.py`; render parcheado
devolviendo `b"%PDF-fake"`; lógica sin Odoo en `tests_pure/` con
`load_pure(...)`.

**Resultado: 253 tests de integración del módulo en verde**, más el carril
puro.

| Archivo | Qué cubre |
|---|---|
| `tests_pure/test_lidaprint_cloud.py` (13 tests) | Hash y `bearer_token`, `clamp_poll`, `parse_hours` y `next_poll` (incluido un horario que cruza la medianoche), `online_seconds`, `stuck_minutes` (nunca por debajo de la caducidad del agente), `parse_ack`, `pdf_problem`, `reported_value`, `version_from_user_agent` y la regex del log de acceso |
| `tests/test_lidaprint_cloud_api.py` (`HttpCase`) | Ping, throttle de `last_seen`, 401 sin efectos en los cuatro endpoints (sin cabecera, otro esquema, token incorrecto, revocado, equipo archivado), poll siempre 200, reclamo de 10 en orden y solo propios, datos del agente, descarga y 404 del PDF, acks idempotentes, 400 y 404 del ack, ack tardío tras el cron y sobre un pendiente, nota en la factura con autor OdooBot |
| `tests/test_lidaprint_cloud_jobs.py` | Encolado con las reglas de LidaPrint, índice parcial, cron sin reencolar y con el mínimo de 12, reimprimir (solo error del agente, rechaza equipo archivado, exige el grupo de facturación), cancelar (pendiente sí, reclamado no), reglas multicompañía, token (una sola vez, solo hash, rotar, revocar, usuario interno sin acceso), preferencia propia, equipo por defecto de la compañía, derivación del destino, validaciones de Ajustes, «Probar conexión» en Nube y el filtro del log |
| `tests/test_lidaprint_cloud_dispatch.py` | Forma Libre en Nube (original y copia, reimpresión como copias, varios documentos en orden, sin equipo bloquea antes de los contadores, equipo por defecto archivado, desconectado avisa pero encola, preferencia frente a equipo por defecto, preferencia de otra compañía, fallo de render sin trabajos, validación de lote, destino navegador), nota al reenviar el original y reportes genéricos |
| `tests/test_route_coverage.py` | 6 controladores y 9 rutas: 5 con `GUARD_ATTR` (`POST`, `csrf=False`, `save_session=False`, `auth='public'`, nunca bajo `/lidaprint/`) y 4 con `DEVICE_TOKEN_GUARD_ATTR` (`auth='none'`, `csrf=False`, `save_session=False`, **`readonly=False`**, `GET` o `POST`, bajo `/lidaprint/v1/`); ninguna ruta sin guardia |

Requisitos del entorno de pruebas:

- Si el servidor de tests ve varias bases, los `HttpCase` necesitan
  `--db-filter ^<base>$`: sin base resuelta, todas las rutas dan HTML 404
  (§6.3).
- Los tests que emiten facturas fijan
  `l10n_ve_lidoo_control_number_source = "company"` en su compañía: con el
  valor de fábrica (`box`) no se puede emitir sin caja.

Comando: `uv run dev -d lidoo_test -u l10n_ve_lidoo_integration_api
--test-enable --test-tags /l10n_ve_lidoo_integration_api --stop-after-init`
(añadiendo el `--db-filter` si hace falta), el carril puro (`tests_pure`) y,
antes de producción, `uv run verify-prod` sobre un dump (siempre con los
comandos `lidoo`, nunca `psql`/`odoo-bin` a mano).

Queda pendiente la prueba de punta a punta del agente Windows contra un Odoo
real por HTTPS (hasta ahora se probó contra un Odoo simulado).

---

## 12. Versión y migración

- `__manifest__.py`: **`18.0.2.4.0`** (funcionalidad nueva con modelos
  nuevos). `data` incluye, en este orden, `security/ir.model.access.csv`,
  `security/lidaprint_security.xml`, `data/ir_cron_data.xml`, las vistas de
  equipos, trabajos y wizard **antes** de Ajustes (que enlaza sus acciones con
  `%(...)d`), preferencias de usuario, la factura y Ajustes.
- `RELEASE_NOTES.md`: sección `## 18.0.2.4.0` con los `[IMP]` del modo Nube y
  el `[FIX]` de la validación de lote en Red local.
- **Sin script de migración.** Las tablas las crea el ORM, los índices
  parciales `init()`, y el destino se deriva en lectura de `ENABLE_PARAM`
  (§7.1): una instalación con LidaPrint encendido sigue en `lan` y una apagada
  en `browser`, sin inventar valores. Al guardar Ajustes se escriben los dos
  parámetros.

---

## 13. Checklist de despliegue

El orden importa: los equipos se crean y su token se copia en cada PC
**antes** de pasar el destino a Nube. Si se cambia el destino primero, las
impresiones fallan por falta de equipo o se acumulan en la cola de un equipo
que todavía no consulta.

**1. Servidor (VPS)**

- [ ] HTTPS válido en el dominio de Odoo; `http://` redirigido o rechazado en
      `/lidaprint/`.
- [ ] La base se resuelve sin sesión (monodb, `dbfilter` por dominio o
      `dbfilter_from_header` con cabecera del proxy): probar con
      `curl -H "Authorization: Bearer x" https://dominio/lidaprint/v1/ping`,
      que debe dar **401 JSON**, no HTML 404.
- [ ] `keepalive_timeout` de nginx por encima del `next_poll` fuera de horario.
- [ ] Log de acceso del poll silenciado (filtro §9.4, ya incluido, o
      `access_log off`).
- [ ] Módulo actualizado a 18.0.2.4.0 en staging, tests en verde, luego
      producción.

**2. Odoo: equipos (como administrador, con el destino todavía en Navegador o
Red local)**

- [ ] *Ajustes > API de integración > LidaPrint*, botón **Equipos LidaPrint**
      (visible con cualquier destino), o *Facturación > Configuración >
      Equipos LidaPrint*: crear un equipo por PC («Caja 1») con la compañía
      correcta, pulsar **Generar token** y copiarlo (se muestra una sola vez).
- [ ] Equipo por defecto de la compañía (Ajustes, con el destino Nube
      seleccionado se muestra el campo) y, si aplica, «Imprimir en» por
      usuario.
- [ ] Revisar horario y segundos de consulta (3 s / 30 s) y el umbral de
      trabajos sin confirmación (15 min; nunca menos de 12, siempre por encima
      de la caducidad local de 10 min de LidaPrint).

**3. PC de la caja**

- [ ] LidaPrint con modo Nube (versión que incluya `cloudUrl`, `cloudToken`,
      `cloudPollSeconds`).
- [ ] Configurador > Conexión > Nube: URL `https://dominio` (sin `/odoo` ni
      `/web`; si se pega con ruta, el Configurador la quita y avisa) y token;
      **Probar conexión** muestra equipo y compañía. Un 404/400 indica URL con
      ruta o base no resuelta; un 401, token mal copiado, revocado o equipo
      archivado.
- [ ] `copies = 1` en LidaPrint: Odoo ya envía original y copia por separado
      (igual que en el modo Red local).
- [ ] Guardar; el monitor queda consultando y el equipo aparece «En línea» en
      Odoo.

**4. Corte: destino Nube**

- [ ] Solo con los equipos creados y las PC consultando: *Ajustes > API de
      integración > LidaPrint*, destino **Nube**, y Guardar.
- [ ] Imprimir una factura de prueba: sale el original y la copia con la
      leyenda; ambos trabajos en `done`.
- [ ] Probar desconexión: parar LidaPrint, imprimir (debe avisar «no está
      conectado» y dejar la cola), arrancarlo (debe imprimir la cola).
- [ ] Vigilar la primera jornada: trabajos en `error`, equipos sin conexión,
      carga de workers. La carga debe corresponder al número de equipos Nube
      activos; si crece con los usuarios, algo consulta desde el navegador y
      eso no debe existir (§2.2).
- [ ] Probar la revocación: archivar el equipo (o revocar su token) debe dar
      401 sin tocar `last_seen`; el log de LidaPrint muestra el cambio de
      estado una sola vez y el agente pasa a reintentar cada 300 s.

**5. Vuelta atrás**

- [ ] Antes de cambiar el destino a «Red local» o «Navegador», **cancelar** los
      trabajos `pending` (§8.2) para que no se impriman al reconectar.
- [ ] En cada PC, pasar LidaPrint a modo `local` o `api`: a partir de ahí no
      consulta a Odoo. Si solo se archivan los equipos en Odoo, los agentes
      que sigan en modo `cloud` quedan en ~1 petición cada 5 min (401, sin
      efectos en la base) hasta que se reconfiguren.

---

## 14. Decisiones

### Decididas (implementadas en 18.0.2.4.0)

1. **Nombres de modelos.** `l10n_ve_lidoo.lidaprint.device` y
   `l10n_ve_lidoo.lidaprint.job` (y `l10n_ve_lidoo.lidaprint.token.wizard`),
   por la convención del repo, en lugar de `lidaprint.device` /
   `lidaprint.job` del brief (§3).
2. **Reenviar el PDF original desde el trabajo.** Solo cuando LidaPrint
   informó el error (`state = 'error'`, `error_source = 'agent'`), para
   usuarios de facturación (`account.group_account_invoice`), con
   confirmación, verificación en Python de grupo y compañía, y rechazo de
   equipos archivados. Crea un trabajo nuevo y deja nota en la factura. Los
   trabajos sin confirmación (`timeout`) o cancelados se reimprimen desde la
   factura con «Imprimir Forma Libre», como COPIA (§8.2).
3. **Estado «cancelado».** Se mantienen los cuatro estados; cancelar es
   `error` con `error_source = 'cancel'` (filtro «Cancelados» en la búsqueda).
4. **Caducidad de pendientes.** Los `pending` **no caducan**: con el equipo
   apagado se imprimen al reconectar, salvo que alguien los cancele.
5. **Wizard del token.** Se mantiene el `TransientModel`: «Listo, ya lo copié»
   (`action_done`) borra el token en claro; si el usuario cierra con la X,
   queda hasta el autovacuum (1 h), legible solo por administradores (ACL del
   wizard).
6. **Retención de PDF.** Los PDF se conservan como traza fiscal, sin purga.

### Abiertas

7. **POS con usuarios compartidos:** mapeo `pos.config` -> equipo en
   `l10n_ve_lidoo_pos`. Hoy la preferencia es por usuario (§5).
8. **Horario laboral por días de la semana** (sábados, domingos) además del
   rango horario. Hoy es un solo rango diario, que puede cruzar la medianoche.
