# Instalación del modo Nube de LidaPrint (Odoo 18 en un VPS)

Guía paso a paso para el técnico que instala LidaPrint en **modo Nube** para un
cliente cuyo Odoo 18 corre en un VPS: primero el servidor (VPS y Odoo), después
cada PC Windows de caja. Al final hay una tabla de errores con el texto exacto que
se ve en el Configurador, en el log o en Odoo.

- Referencia técnica (contrato HTTP, seguridad fiscal, rendimiento):
  [`odoo-modo-nube.md`](odoo-modo-nube.md).
- Documento principal de LidaPrint: [`../README.md`](../README.md).

Convenciones de esta guía:

- `cliente.example.com` es el dominio de Odoo del cliente; `<token>` es el token
  del equipo; `<db>` es el nombre de la base de datos. Reemplácelos.
- Los textos de la ventana de LidaPrint (Configurador) se citan **tal cual**
  aparecen en pantalla, sin tildes: **Probar conexion**, **Guardar**.
- Los textos de Odoo se citan como aparecen en Odoo en español: **Generar token**,
  **Equipos LidaPrint**.

> **El orden importa.** Primero se crean los equipos en Odoo y se deja cada PC
> consultando; **después** se cambia el destino de impresión de Odoo a Nube
> (paso [B6](#b6-activar-el-destino-nube-en-odoo)). Si se cambia antes, imprimir
> falla por falta de equipo o los trabajos se acumulan en la cola de un equipo que
> todavía no consulta, y se imprimirán cuando esa PC se conecte.

---

## Contenido

1. [Resumen: cómo funciona](#1-resumen-cómo-funciona)
2. [Requisitos](#2-requisitos)
3. [Parte A — VPS y Odoo](#3-parte-a--vps-y-odoo)
4. [Parte B — PC Windows (caja)](#4-parte-b--pc-windows-caja)
5. [Parte C — Varias cajas en la misma empresa](#5-parte-c--varias-cajas-en-la-misma-empresa)
6. [Verificación final](#6-verificación-final)
7. [Errores posibles y soluciones](#7-errores-posibles-y-soluciones)
8. [Mantenimiento](#8-mantenimiento)

---

## 1. Resumen: cómo funciona

Con Odoo en un VPS, el servidor no puede llegar a la PC de la caja (está detrás del
router). En modo Nube se invierte el sentido: **LidaPrint sale a Odoo por HTTPS**
cada pocos segundos y pregunta si hay algo que imprimir. Odoo guarda una cola de
trabajos por equipo.

```
 Usuario (navegador)        Odoo 18 (VPS)                     LidaPrint (PC de la caja)
        |                         |                                     |
        |--- clic Forma Libre --->| crea 2 trabajos (Pendiente):        |
        |<-- "Enviado a Caja 1" --|   original + copia SIN DERECHO...   |
        |                         |<------- POST /lidaprint/v1/poll ----|  cada 3 s en horario,
        |                         |-- trabajos (pasan a Imprimiendo) -->|  30 s fuera de horario
        |                         |<--- GET /lidaprint/v1/job/<id>/pdf -|
        |                         |------------------ PDF ------------->|  imprime (Ghostscript
        |                         |<--- POST /lidaprint/v1/job/<id>/ack |  o ESC/POS) y borra
        |                         |  (Impreso o Error)                  |  el temporal
```

Lo esencial:

- La PC **siempre** abre la conexión (HTTPS saliente, puerto 443). No se abren
  puertos en la PC ni en el router del cliente.
- Cada PC es un **equipo** en Odoo («Caja 1», «Caja 2»…) con **su propio token**.
- Solo consultan a Odoo las PC con LidaPrint en modo Nube. Los navegadores y las PC
  sin LidaPrint no generan tráfico de consultas.
- La Forma Libre crea **dos trabajos** por documento: el original y la copia
  **SIN DERECHO A CRÉDITO FISCAL**. Por eso LidaPrint debe tener **Copias = 1**.
- Toda reimpresión es un trabajo **nuevo**. Un trabajo que pudo haberse impreso
  nunca vuelve solo a la cola (evita un segundo original fiscal).

---

## 2. Requisitos

### Servidor (VPS y Odoo)

- Odoo 18 con el módulo `l10n_ve_lidoo_integration_api` **18.0.2.4.1 o
  posterior**, instalado y actualizado en la base del cliente (el modo Nube
  existe desde 18.0.2.4.0; la 18.0.2.4.1 corrige el aviso de las reimpresiones).
- Un dominio público que apunte al VPS y un **certificado HTTPS válido** (Let's
  Encrypt u otra CA pública).
- nginx (u otro proxy inverso) delante de Odoo, con `proxy_mode = True` en Odoo.
- **wkhtmltopdf** instalado en el servidor (Odoo lo usa para generar el PDF).
- La base de datos debe resolverse **sin sesión**: una sola base en la instancia,
  `dbfilter` por dominio o `dbfilter_from_header` (ver [A3](#a3-https-y-nginx)).
- Un usuario **administrador** de Odoo (grupo de Ajustes, `base.group_system`):
  los equipos y los tokens solo los ve un administrador.

### PC Windows (caja)

- Windows 10 u 11 y PowerShell 5.1 o superior. **No requiere administrador**
  (Ghostscript puede pedir UAC una vez).
- Salida a internet por **HTTPS (puerto 443)** hacia el dominio de Odoo.
- La impresora instalada en Windows e imprimiendo.
- **Fecha, hora y zona horaria correctas** (si no, falla el TLS).
- Si el certificado del servidor es autofirmado o de una CA interna: importar esa
  CA en Windows (ver [errores de TLS](#71-conexión-configurador-y-log)).

---

## 3. Parte A — VPS y Odoo

### A1. Versión del módulo

- [ ] En el servidor, el manifiesto del módulo dice `18.0.2.4.1` o mayor:

  ```bash
  grep '"version"' /ruta/a/addons/l10n-ve-lidoo/l10n_ve_lidoo_integration_api/__manifest__.py
  ```

- [ ] El módulo está **actualizado en la base** del cliente
  (`-u l10n_ve_lidoo_integration_api` con el procedimiento habitual del servidor).
- [ ] Comprobación en Odoo: en **Ajustes > API de integración** aparece el bloque
  **LidaPrint** con el selector **Destino de impresión** (Navegador / Red local /
  Nube), y existe el menú **Facturación > Configuración > Equipos LidaPrint**
  (solo lo ve un administrador).

### A2. wkhtmltopdf

Odoo genera el PDF de la Forma Libre con wkhtmltopdf. Sin él, al pulsar
**Forma Libre** Odoo muestra:

> No se ha podido encontrar Wkhtmltopdf en el sistema. El PDF no se puede crear.

y no se encola nada.

- [ ] Instalar wkhtmltopdf en el servidor, en la versión que recomienda la
  documentación de Odoo 18.
- [ ] Verificar **con el mismo usuario y entorno con que corre el servicio de
  Odoo**:

  ```bash
  wkhtmltopdf --version
  ```

- [ ] Odoo lo busca en el `PATH` del proceso de Odoo y, además, en la opción
  `bin_path` de `odoo.conf`. Si el binario está en otra carpeta, agregar esa
  carpeta al `PATH` del servicio o a `bin_path`, y reiniciar Odoo.

### A3. HTTPS y nginx

El token viaja en cada petición: desde internet **solo HTTPS**. LidaPrint rechaza
`http://` hacia un host público (solo lo admite hacia la red local, con
advertencia).

#### A3.1 Una base o varias

Pruebe con un token inventado (desde cualquier máquina):

```bash
curl -i -H "Authorization: Bearer x" https://cliente.example.com/lidaprint/v1/ping
```

| Respuesta | Significado |
|---|---|
| `401` con `{"ok": false, "error": "unauthorized"}` | Correcto: la base se resuelve y el módulo responde. Siga en A3.3 |
| `404` en **HTML** (página de Odoo) | Odoo no sabe qué base usar (varias bases sin filtro) o el módulo no está instalado/actualizado en esa base. Aplique A3.2 |
| Error de conexión o de certificado | Falta HTTPS o el certificado no es válido. Aplique A3.3 |

#### A3.2 Varias bases en el servidor

Con más de una base en el servidor y un `dbfilter` genérico, **todas** las rutas
`/lidaprint/v1/*` responden un 404 en HTML y LidaPrint informa «URL incorrecta o
base de datos no resuelta». `?db=` en la URL **no sirve**. Hay dos soluciones:

**Opción 1 — `dbfilter` por dominio** (`odoo.conf`):

```ini
[options]
dbfilter = ^%d$
```

`%d` es el primer subdominio: con `cliente.example.com` la base debe llamarse
`cliente`. `^%h$` usa el host completo (la base debe llamarse
`cliente.example.com`). Afecta a toda la instancia.

**Opción 2 — cabecera `X-Odoo-dbfilter` desde nginx** (módulo OCA
`dbfilter_from_header`, de `server-tools` 18.0). Solo filtra lo que pasa por
`location /lidaprint/`, sin tocar el acceso web al resto de las bases:

1. Poner la carpeta de `server-tools` (la que contiene `dbfilter_from_header`) en
   el `addons_path`. No hace falta instalarlo en la base: se carga como módulo
   *server-wide*.
2. En `odoo.conf`:

   ```ini
   [options]
   proxy_mode = True
   server_wide_modules = base,web,dbfilter_from_header
   ```

   Si el servidor ya carga otros módulos *server-wide*, mantenerlos en la lista.
   El `dbfilter` normal se sigue aplicando **antes** que la cabecera: no debe
   excluir la base del cliente.
3. En nginx, dentro de `location /lidaprint/`:
   `proxy_set_header X-Odoo-dbfilter "^<db>$";` (ver el bloque completo en A3.3).
   En **todas las demás** `location` poner `proxy_set_header X-Odoo-dbfilter "";`:
   el módulo filtra con la cabecera que llegue, y sin esa línea un cliente podría
   enviar la suya y elegir otra base del servidor.
4. Reiniciar Odoo y recargar nginx.

#### A3.3 Bloque de nginx (HTTPS)

Ejemplo mínimo completo. Rutas del certificado de Let's Encrypt como ejemplo;
ajuste el dominio, las rutas, el puerto de Odoo y `<db>`.

```nginx
# /etc/nginx/sites-available/odoo-cliente.conf

upstream odoo {
    server 127.0.0.1:8069;
}

# Estándar de Odoo con workers > 0 (chat y notificaciones del navegador).
# LidaPrint no lo usa; si el servidor no tiene gevent en 8072, quítelo.
upstream odoochat {
    server 127.0.0.1:8072;
}

map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

# http:// -> https:// (el token no debe viajar en claro)
server {
    listen 80;
    server_name cliente.example.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name cliente.example.com;

    ssl_certificate     /etc/letsencrypt/live/cliente.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/cliente.example.com/privkey.pem;

    location / {
        # Descarta un X-Odoo-dbfilter enviado por el cliente (con valor vacío
        # nginx no envía la cabecera): nadie elige la base desde fuera.
        proxy_set_header X-Odoo-dbfilter   "";
        proxy_set_header Host              $host;
        proxy_set_header X-Forwarded-Host  $host;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_redirect off;
        proxy_pass http://odoo;
    }

    location /websocket {
        proxy_set_header X-Odoo-dbfilter   "";
        proxy_set_header Upgrade           $http_upgrade;
        proxy_set_header Connection        $connection_upgrade;
        proxy_set_header Host              $host;
        proxy_set_header X-Forwarded-Host  $host;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_pass http://odoochat;
    }

    # LidaPrint (modo Nube). La línea X-Odoo-dbfilter solo hace falta con
    # varias bases y dbfilter_from_header (A3.2, opción 2); si no, bórrela.
    location /lidaprint/ {
        proxy_set_header X-Odoo-dbfilter   "^<db>$";
        proxy_set_header Host              $host;
        proxy_set_header X-Forwarded-Host  $host;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_redirect off;
        proxy_pass http://odoo;
    }
}
```

Notas:

- nginx **no hereda** los `proxy_set_header` de un nivel superior si el
  `location` define alguno propio: por eso cada `location` repite todas las
  cabeceras.
- Odoo solo aplica las cabeceras `X-Forwarded-*` con `proxy_mode = True` **y**
  si llega `X-Forwarded-Host`.
- Use `fullchain.pem` (certificado + intermedios), no solo `cert.pem`: con la
  cadena incompleta Windows puede rechazar el certificado.
- `keepalive_timeout` de nginx debe ser mayor que el intervalo de consulta fuera
  de horario (30 s por defecto). El valor por defecto de nginx (75 s) sirve.

Aplicar:

```bash
sudo nginx -t && sudo systemctl reload nginx
sudo systemctl restart <servicio-de-odoo>     # si cambió odoo.conf
```

- [ ] `curl -i -H "Authorization: Bearer x" https://cliente.example.com/lidaprint/v1/ping`
  responde **401 JSON** (no HTML 404).
- [ ] `http://cliente.example.com` redirige a `https://`.

### A4. Crear el equipo (caja) y copiar el token

1. Entrar a Odoo como **administrador**.
2. Abrir **Facturación > Configuración > Equipos LidaPrint**.
   Otro camino a la misma lista: **Ajustes > API de integración >** bloque
   **LidaPrint >** botón **Equipos LidaPrint** (visible con cualquier destino).
3. **Nuevo**. Completar:
   - **Nombre**: por ejemplo `Caja 1` (un equipo por PC).
   - **Compañía**: la de los documentos que imprimirá esa caja (solo aparece con
     varias compañías).
   - **Zona horaria**: por defecto `America/Caracas`; es la zona en la que se
     evalúa el horario laboral.
4. Guardar el registro.
5. Pulsar **Generar token** (arriba). Se abre la ventana **Token de Caja 1** con
   el aviso «Copie este token en el Configurador de LidaPrint (pestaña
   Conexión > Nube). No se volverá a mostrar.».
6. Copiar el campo **Token** (botón de copiar a la derecha). Tiene
   **43 caracteres**.
7. Pulsar **Listo, ya lo copié**.

- [ ] Token copiado y guardado en un lugar seguro hasta pegarlo en la PC. Quien
  tenga el token puede descargar los PDF de ese equipo.
- El token **se muestra una sola vez**: en la base solo queda su huella
  (SHA-256). Si se pierde, se genera otro (ver [Mantenimiento](#8-mantenimiento)).
- Si el equipo ya tenía token, **Generar token** pide confirmación: «El token
  anterior dejará de funcionar de inmediato: LidaPrint recibirá 401 hasta que
  copie el nuevo en el Configurador. ¿Continuar?».
- **Un token por PC.** Si dos PC usan el mismo token, los trabajos se reparten
  entre ambas (se imprimen en la PC equivocada) y Odoo muestra el campo
  **Equipo anterior** en el equipo.

### A5. Probar el token con curl

Desde cualquier máquina con `curl` (en Windows, escribir `curl.exe`: en PowerShell
5.1 `curl` es otro comando):

```bash
curl -i -H "Authorization: Bearer <token>" https://cliente.example.com/lidaprint/v1/ping
```

Respuesta esperada (`200`):

```json
{"ok": true, "device": "Caja 1", "company": "Mi Empresa", "next_poll": 3}
```

| Respuesta | Qué hacer |
|---|---|
| `200` con `"ok": true` | Correcto. `device` es el equipo, `company` la compañía y `next_poll` los segundos entre consultas |
| `401` `{"ok": false, "error": "unauthorized"}` | Token mal copiado, revocado o equipo archivado. Generar otro (A4) |
| `404` en HTML | Base no resuelta o módulo no actualizado (A1, A3.2) |

El ping **no toma trabajos** de la cola, pero sí actualiza la **Última conexión**
del equipo: durante un minuto después del curl el equipo puede aparecer
**En línea** aunque ninguna PC esté consultando todavía.

### A6. Revisar los ajustes de LidaPrint (sin activar Nube todavía)

**Ajustes > API de integración >** bloque **LidaPrint**:

| Campo | Valor | Notas |
|---|---|---|
| **Destino de impresión** | Dejar el actual por ahora | Opciones: «Navegador (descargar PDF)», «Red local (API)», «Nube». Se pasa a Nube en [B6](#b6-activar-el-destino-nube-en-odoo) |
| **Equipo por defecto** | (se elige en B6) | Solo aparece con el destino Nube seleccionado |
| **Consulta en horario (s)** | `3` | Segundos entre consultas dentro del horario laboral (1–300) |
| **Consulta fuera de horario (s)** | `30` | Fuera del horario (1–300) |
| **Horario laboral** | `07:00-19:00` | Formato `HH:MM-HH:MM`, en la zona horaria del equipo. Puede cruzar la medianoche (`22:00-06:00`) |
| **Sin confirmación (min)** | `15` | Minutos para pasar a error un trabajo tomado por LidaPrint sin confirmación. Nunca menos de 12 |

Estos cuatro últimos campos solo se ven con el destino Nube seleccionado. Al
guardar, Odoo rechaza intervalos fuera de 1–300 s, un horario mal escrito y un
umbral menor de 12 minutos. Los valores de fábrica son los recomendados.

El umbral de **En línea** es de 60 s con los valores de fábrica; si se alarga un
intervalo, pasa a ser el doble del intervalo más largo.

---

## 4. Parte B — PC Windows (caja)

Repetir esta parte en cada PC. Iniciar sesión en Windows con **el usuario que usa
la caja todos los días**: LidaPrint se instala en su perfil
(`%LOCALAPPDATA%\LidaPrint`) y la tarea programada arranca al iniciar sesión
**ese** usuario.

### B1. Instalar LidaPrint

1. Abrir **PowerShell** (normal, sin administrador) y pegar:

   ```powershell
   irm https://raw.githubusercontent.com/LIDALabs/lida-print/main/get.ps1 | iex
   ```

   O desde `cmd`:

   ```cmd
   curl -L -o "%TEMP%\get.ps1" https://raw.githubusercontent.com/LIDALabs/lida-print/main/get.ps1 && powershell -ExecutionPolicy Bypass -File "%TEMP%\get.ps1"
   ```

2. El instalador:
   - descarga `LidaPrint.exe` de la última versión publicada en GitHub y verifica
     su SHA-256;
   - lo instala en `%LOCALAPPDATA%\LidaPrint` (por ejemplo
     `C:\Users\<usuario>\AppData\Local\LidaPrint`);
   - verifica o instala Ghostscript (paso B2);
   - registra la tarea programada **LidaPrint** (al iniciar sesión, sin
     administrador) y la arranca;
   - crea el acceso **LidaPrint** en el menú Inicio y agrega la carpeta al `PATH`
     del usuario;
   - en la primera instalación **abre el Configurador**.
3. Al final debe decir `LidaPrint <versión> instalado en C:\Users\<usuario>\AppData\Local\LidaPrint`.

- [ ] En el Configurador, pestaña **Conexion**, grupo **Modo de operacion**,
  existe la opción **Nube (Odoo en VPS)**. Si no aparece, la versión publicada no
  incluye el modo Nube: no seguir hasta tener una versión que lo incluya.
- Si el Configurador no se abrió (por ejemplo, en una reinstalación): menú
  Inicio > **LidaPrint**, o `Win+R` > `lidaprint`.

### B2. Ghostscript

LidaPrint imprime con GPL Ghostscript (licencia AGPL). Si no está instalado, el
instalador de LidaPrint descarga el instalador oficial de Artifex, comprueba su
firma y lo ejecuta **avanzando su asistente solo**: desde la versión 10.01.0
Artifex no permite la instalación silenciosa (`/S`), así que el asistente se ve
en pantalla pasando de página sin que nadie pulse nada.

- Windows pide permiso de administrador **una vez**: el aviso de UAC aparece como
  **Windows PowerShell** (es el proceso que avanza el asistente). Responder **Sí**.
- La consola muestra `Instalando GPL Ghostscript (licencia AGPL, ghostscript.com).
  Su asistente avanza solo, no lo cierres...`. **No cerrar** el asistente ni la
  consola; tarda menos de un minuto.
- Si no termina en **5 minutos**, se cancela solo y la consola muestra
  `El instalador de Ghostscript no termino en 5 minutos y fue cancelado.`
  (o `...termino con codigo N`). Si después aparece `ERROR: Ghostscript es el
  motor de impresion y no pudo instalarse...`: instalar Ghostscript a mano desde
  ghostscript.com (valores por defecto) y volver a ejecutar el comando de B1.

- [ ] En el Configurador, pestaña **Avanzado**, grupo **Motor de impresion:
  Ghostscript**: el campo muestra la ruta de `gswin64c.exe`. Si está vacío, pulsar
  **Detectar**.

### B3. Impresora de Windows

- [ ] La impresora está instalada en Windows e imprime una página de prueba de
  Windows. Para los modelos incluidos (EPSON TM-U220PD, EPSON M188D, Canon
  LBP6030), el driver se instala desde la pestaña **Drivers y formatos** del
  Configurador: elegir el modelo y pulsar **Instalar driver seleccionado**.
- [ ] Pestaña **Impresora**: en **Impresora:** elegir la de la caja (**Refrescar**
  relee la lista) y ajustar papel, DPI y márgenes según el formato de factura.
- [ ] **Copias:** `1`. **Importante:** la configuración inicial trae `2`; con 2,
  cada Forma Libre saldría 2×2 = 4 hojas (Odoo ya envía original y copia por
  separado).
- [ ] Botón **Probar impresion** (abajo): sale la página de prueba.

### B4. Configurar el modo Nube en el Configurador

1. Pestaña **Conexion** > grupo **Modo de operacion** > **Nube (Odoo en VPS)**.
   Queda visible solo el grupo **Nube (Odoo en un VPS o en internet)**.
2. **URL de Odoo:** `https://cliente.example.com`
   - Solo esquema, dominio y, si hace falta, puerto. **Sin** `/odoo` ni `/web`.
   - Si se pega con una ruta copiada del navegador, **Probar conexion** y
     **Guardar** la quitan y avisan: `La URL traia la ruta '/odoo', que sobra:
     LidaPrint usa solo la direccion base de Odoo, sin /odoo ni /web. Se usa
     https://cliente.example.com.`
3. **Token:** pegar el token de A4. **Mostrar** permite verlo. Si no tiene
   43 caracteres, al probar o guardar aparece (sin bloquear): `El token no tiene
   el formato que genera Odoo (43 caracteres: letras, numeros, - y _; este tiene
   N). Se copio completo?`
4. **Consultar cada (s):** dejar `3`. Odoo indica su propio intervalo y ese manda.
5. Pulsar **Probar conexion**. Debe mostrar `Conexion correcta.` con
   `Equipo: Caja 1` y `Compania: ...`, y al lado del botón `OK: Caja 1 (...)`.
   Si muestra otra cosa, ver [7.1](#71-conexión-configurador-y-log).
6. Pestaña **Impresora**: confirmar **Impresora:** y **Copias:** `1` (B3).
7. Pestaña **Avanzado** > grupo **Sistema**:
   - [ ] **Auto-iniciar con Windows (Task Scheduler)** marcado. **Siempre** en las
     PC del cliente: sin él, el monitor corre solo en esta sesión y no arranca
     después de reiniciar.
   - [ ] **Generar logs de impresion** marcado.
8. Pulsar **Guardar** (abajo a la derecha).
   - Correcto: `Configuracion guardada. Monitor reiniciado con la nueva
     configuracion.`
   - Si el mensaje añade `(Sin auto-inicio: corre solo en esta sesion; no
     arrancara solo al iniciar Windows.)`: volver al paso 7, marcar
     **Auto-iniciar con Windows (Task Scheduler)** y **Guardar** otra vez.
   - Si dice `Configuracion guardada, pero el monitor NO esta corriendo.`: abrir
     el log (B5).

Validaciones de **Guardar** en modo Nube:

| Mensaje | Qué significa |
|---|---|
| `Modo Nube: La URL debe empezar con https://: con http:// el token viajaria en claro por internet. http:// solo se admite para localhost o un equipo de la red local.` | Bloquea. Usar `https://` |
| `Modo Nube: falta el token. ...` | Bloquea. Pegar el token |
| `La URL usa http:// (sin cifrado): el token viaja en claro. Solo es aceptable dentro de la red local.` y `Continuar?` | Advertencia (solo con `http://` hacia `localhost`, nombres `.local` o IP privadas). Con Odoo en un VPS nunca debería aparecer |

### B5. Verificar el log y «En línea»

1. Pestaña **Avanzado** > **Ver Log**. Abre en el Bloc de notas el log del mes:
   `%LOCALAPPDATA%\LidaPrint\logs\PrintLog_yyyy-MM.txt` (por ejemplo
   `PrintLog_2026-09.txt`).
2. Deben aparecer, tras el último `LidaPrint - INICIO`:

   ```
   [2026-09-14 08:00:01] [INFO] LidaPrint - INICIO
   [2026-09-14 08:00:01] [INFO] Nube:         https://cliente.example.com/lidaprint/v1 (cada 3s salvo que Odoo indique otro intervalo)
   [2026-09-14 08:00:01] [OK] Monitor activo en modo Nube. Esperando trabajos de Odoo...
   [2026-09-14 08:00:02] [OK] Conectado a Odoo (https://cliente.example.com/lidaprint/v1)
   ```

   El log **no** registra cada consulta: solo los trabajos y los **cambios** de
   estado de la conexión (`Conectado a Odoo`, `Conexion con Odoo perdida: ...`,
   `Conexion con Odoo restablecida`).
3. En Odoo, **Equipos LidaPrint**: el equipo tiene marcado **En línea**. En su
   formulario, el grupo **Informado por LidaPrint** muestra **En línea**,
   **Última conexión**, **Equipo** (nombre de la PC), **Versión de LidaPrint** e
   **Impresora** (la elegida en el Configurador).

- [ ] Log con `Conectado a Odoo`.
- [ ] Equipo **En línea** en Odoo, con el nombre de la PC y la impresora correctos.

**En línea** significa contacto en los últimos 60 s (valores de fábrica): solo se
ve mientras el agente consulta. Con la PC apagada o el monitor detenido pasa a
desconectado en un minuto.

### B6. Activar el destino Nube en Odoo

Solo cuando **todas** las cajas del cliente aparecen **En línea** (B5).

1. **Ajustes > API de integración >** bloque **LidaPrint**.
2. **Destino de impresión** = **Nube**.
3. **Equipo por defecto** = el equipo que recibe las impresiones de los usuarios
   sin preferencia propia (por ejemplo `Caja 1`). Debe ser de la misma compañía.
4. Revisar los tiempos (A6). Opcional: **Reportes** que también deben salir por
   LidaPrint (uno por impresión, además de la Forma Libre).
5. **Guardar**.
6. Pulsar **Probar conexión** (en Odoo). En Nube informa el estado de los equipos,
   por ejemplo `Caja 1: en línea (hace 4 s) · LidaPrint <versión> · <impresora>`.
   Sale en rojo si no hay equipos, si falta el equipo por defecto o si está
   desconectado.

**Imprimir en** (preferencia por usuario, opcional): cada usuario puede elegir su
caja en el menú de usuario (arriba a la derecha) > **Preferencias** > pestaña
**Preferencias** > **Imprimir en**. Un administrador lo cambia en **Ajustes >
Usuarios y compañías > Usuarios** > el usuario > pestaña **Preferencias** >
**Imprimir en**. Vacío = equipo por defecto de la compañía.

A qué equipo va cada impresión, en este orden:

1. **Imprimir en** del usuario, si el equipo está activo y es de la compañía del
   documento.
2. **Equipo por defecto** de la compañía.
3. Ninguno: Odoo muestra «No hay un equipo LidaPrint asignado para <compañía>.
   Elija uno en Mis preferencias > Imprimir en, o configure el equipo por defecto
   en Ajustes > API de integración > LidaPrint.» y no toca el contador de copias.

### B7. Primera impresión de prueba

Cada Forma Libre suma al contador de copias de la factura. Para la prueba conviene
una factura cuyo original **ya se imprimió**: saldrán dos **COPIA**.

1. Abrir una factura (o nota de crédito) de cliente **publicada** y con **número de
   control**.
2. Pulsar **Forma Libre** (primer botón de la cabecera).
3. Aviso de Odoo:
   - equipo en línea: título **Enviado a Caja 1** y el texto
     `1 documento(s) en cola de impresión: original y copia.` (primera impresión)
     o `1 documento(s) en cola de impresión: 2 copias.` (reimpresión);
   - equipo desconectado: título **Caja 1 no está conectado** y el texto «Los
     documentos quedaron en cola y se imprimirán cuando LidaPrint se conecte.
     Última conexión: …». Los trabajos quedan en cola igual.
4. En unos segundos la caja imprime **dos hojas**: original y copia **SIN
   DERECHO A CRÉDITO FISCAL**, o dos **COPIA** en una reimpresión.
5. En el log de la PC:

   ```
   [INFO] Nube: trabajo #51 recibido (F-00001234-forma-libre.pdf, 48211 bytes)
   [OK] Nube #51: Impreso (...): job-51-F-00001234-forma-libre.pdf -> <impresora>
   ```

   (el nombre es el de la factura con `/` cambiado por `-`, y `-copia-forma-libre.pdf`
   para la segunda pasada).
6. En la factura, el botón inteligente **Trabajos LidaPrint** muestra los dos
   trabajos en **Impreso**.

Prueba opcional de desconexión: en PowerShell `Stop-ScheduledTask -TaskName
"LidaPrint"`, imprimir una Forma Libre (debe avisar «no está conectado» y los
trabajos quedan en **Pendiente**), y luego `Start-ScheduledTask -TaskName
"LidaPrint"`: la cola se imprime sola.

---

## 5. Parte C — Varias cajas en la misma empresa

- **Un equipo y un token por PC.** Repetir [A4](#a4-crear-el-equipo-caja-y-copiar-el-token)
  y la [Parte B](#4-parte-b--pc-windows-caja) en cada PC: «Caja 1», «Caja 2»…
  Nunca copiar el mismo token en dos PC.
- **Cada cajero con su usuario de Odoo** y su **Imprimir en** apuntando a su caja.
  La preferencia es **por usuario**, no por PC: si varias cajas comparten el mismo
  usuario de Odoo, todas sus impresiones van al mismo equipo.
- **Equipo por defecto** de la compañía: para los usuarios sin preferencia (por
  ejemplo, administración).
- **Varias compañías:** cada equipo pertenece a una compañía. La preferencia de un
  usuario solo se usa si el equipo es de la compañía del documento; si no, se usa
  el equipo por defecto de esa compañía.
- Carga: cada PC en Nube consulta por su cuenta (unos 0,5–1 KB por consulta; con
  3 s en horario y 30 s fuera, unos 13 MB al día por PC). La carga del servidor
  crece con el número de equipos Nube, no con el número de usuarios.

---

## 6. Verificación final

Servidor y Odoo:

- [ ] Módulo `l10n_ve_lidoo_integration_api` 18.0.2.4.1 o posterior, actualizado en la base.
- [ ] `wkhtmltopdf --version` responde en el servidor.
- [ ] `https://cliente.example.com` con certificado válido; `http://` redirige a `https://`.
- [ ] `curl -i -H "Authorization: Bearer x" https://cliente.example.com/lidaprint/v1/ping` → **401 JSON**.
- [ ] Un equipo por PC, cada uno con token generado.
- [ ] **Destino de impresión** = **Nube** y **Equipo por defecto** elegido.
- [ ] **Imprimir en** configurado en los usuarios que lo necesiten.

Cada PC:

- [ ] Modo **Nube (Odoo en VPS)**, URL `https://` sin `/odoo` ni `/web`.
- [ ] **Probar conexion** muestra el equipo y la compañía correctos.
- [ ] **Copias:** `1`.
- [ ] **Auto-iniciar con Windows (Task Scheduler)** marcado.
- [ ] Log con `Conectado a Odoo`; equipo **En línea** en Odoo.
- [ ] Forma Libre de prueba impresa; trabajos en **Impreso**.
- [ ] Tras **reiniciar la PC** e iniciar sesión, el equipo vuelve a **En línea**
  sin tocar nada.

---

## 7. Errores posibles y soluciones

El log está en `%LOCALAPPDATA%\LidaPrint\logs\PrintLog_yyyy-MM.txt`
(**Avanzado > Ver Log**). Los trabajos se ven en Odoo en **Facturación >
Configuración > Trabajos LidaPrint** (administradores; filtro «Por atender» por
defecto) o en el botón **Trabajos LidaPrint** de cada factura.

Los mensajes de error de red de Windows (tiempos de espera, TLS) salen en el idioma
de Windows; abajo se citan de forma aproximada.

### 7.1 Conexión (Configurador y log)

| Síntoma | Causa | Solución |
|---|---|---|
| **Probar conexion**: `Token rechazado (401)` / `Odoo rechazo el token (HTTP 401): equipo archivado o token revocado, o el token se copio mal.` Log: `Odoo rechazo el token (HTTP 401): ...` | Token mal copiado (incompleto o con espacios), token revocado o regenerado, o equipo archivado | Generar un token nuevo en Odoo (A4), pegarlo en **Token:**, **Probar conexion** y **Guardar**. Si el equipo está archivado, desarchivarlo (filtro «Archivados») o crear otro. Mientras tanto el monitor reintenta cada 60 s y, tras 3 rechazos, cada 300 s |
| **Probar conexion**: `URL o base de datos (HTTP 404)` (o 400). Log: `Odoo respondio HTTP 404 a https://.../lidaprint/v1/poll. URL incorrecta o base de datos no resuelta: ...` | La petición no llega al módulo: el servidor tiene **varias bases** y no puede elegir una, el módulo no está instalado o actualizado en esa base, o la URL es de otro sitio | `curl -i -H "Authorization: Bearer x" https://cliente.example.com/lidaprint/v1/ping` debe dar **401 JSON**. Si da HTML 404: [A3.2](#a32-varias-bases-en-el-servidor) (dbfilter por dominio o `X-Odoo-dbfilter`) o actualizar el módulo (A1) |
| **Probar conexion**: `Respuesta no valida` / `La URL respondio, pero no parece Odoo con el modo Nube de LidaPrint.` Log: `Odoo respondio algo que no es JSON ...` | La URL apunta a otro sitio, a una página de inicio de sesión o a una redirección | URL base de Odoo con `https://`, sin `/odoo` ni `/web` |
| **Probar conexion**: `Sin conexion` con un error de TLS («no se puede establecer una relación de confianza para el canal seguro SSL/TLS», «no se pudo crear un canal seguro»). Log: `Sin conexion con Odoo: ...` o `Conexion con Odoo perdida: ...` | Windows no confía en el certificado: autofirmado o de una CA interna, cadena incompleta en nginx, certificado vencido, **hora de Windows incorrecta**, o antivirus con inspección HTTPS | LidaPrint usa el TLS del sistema: un certificado de una CA pública (Let's Encrypt) funciona tal cual. Con CA interna o autofirmado, importar la CA en «Entidades de certificación raíz de confianza»: `Import-Certificate -FilePath C:\ruta\ca.crt -CertStoreLocation Cert:\CurrentUser\Root` (usuario de la caja; pide confirmación) o `Cert:\LocalMachine\Root` (PowerShell como administrador, para todos los usuarios). En nginx usar `fullchain.pem`. Corregir la fecha y hora. Excluir el dominio de la inspección HTTPS del antivirus |
| **Guardar**: `Modo Nube: La URL debe empezar con https://: con http:// el token viajaria en claro por internet...` Log al arrancar: `Modo Nube: La URL debe empezar con https://: ... - abortando` | `http://` hacia un host público | Usar `https://` (A3). `http://` solo se admite hacia la red local |
| Log: `Conexion con Odoo perdida: HTTP 502` (o 503), luego `Conexion con Odoo restablecida` | Odoo se reinició o nginx no alcanza a Odoo por un momento | Nada: el agente reintenta (2, 4, 8… hasta 60 s). Si una confirmación no llegó (`Nube: no se pudo confirmar el trabajo #51 a Odoo (HTTP 502); se reintentara`), queda pendiente y se entrega después (`Nube: confirmacion pendiente del trabajo #51 entregada (done)`) **sin reimprimir**. Si dura, revisar el servicio de Odoo |
| **Probar conexion**: `Sin conexion` / `No se pudo conectar con Odoo: ...` con un tiempo de espera agotado. Log: `Conexion con Odoo perdida: The operation has timed out` (o su versión en español) | Sin internet, DNS, **firewall o proxy corporativo** que bloquea la salida por 443, o antivirus | Abrir `https://cliente.example.com` en el navegador de esa PC. En PowerShell: `Test-NetConnection cliente.example.com -Port 443` y `curl.exe -m 15 -H "Authorization: Bearer <token>" https://cliente.example.com/lidaprint/v1/ping`. LidaPrint no tiene configuración de proxy propia: pedir al responsable de la red que permita la salida HTTPS directa al dominio de Odoo |
| Log: `Nube: trabajo #51: fallo la descarga del PDF (...), intento 2/5; se reintenta` | Corte de red durante la descarga | Nada: se reintenta (es seguro, todavía no se imprimió). Tras 5 intentos: `no se pudo descargar el PDF tras 5 intentos` y el trabajo queda en error en Odoo |
| Log: `Nube: trabajo #51: Odoo nego la descarga del PDF (HTTP 404)` | El trabajo ya no está en **Imprimiendo** en Odoo (lo pasó a error el cron o se canceló) | No se imprime. Revisar el trabajo en Odoo y, si hace falta, reimprimir desde la factura (COPIA) |
| Log al arrancar: `Modo Nube sin URL de Odoo o sin token: ... - abortando` | `config.json` editado a mano | Completar **URL de Odoo:** y **Token:** en el Configurador y **Guardar** |

### 7.2 Equipo y trabajos (Odoo)

| Síntoma | Causa | Solución |
|---|---|---|
| El equipo no aparece **En línea**. En Odoo, **Probar conexión**: `Caja 1: nunca se ha conectado` o `sin conexión desde ...` | El monitor no corre (PC apagada o suspendida, sin auto-inicio, error al arrancar), o la PC usa el token de otro equipo, o está en otro modo | En la PC: **Ver Log** (buscar `Conectado a Odoo` o el error). El botón **Probar monitor** dice si el monitor corre (`El monitor NO esta corriendo...`). Comprobar modo **Nube (Odoo en VPS)**, **Auto-iniciar con Windows (Task Scheduler)** y **Guardar**. En Odoo, revisar **Equipo** (nombre de la PC) en el formulario del equipo |
| Trabajos que se quedan en **Pendiente** | El equipo de destino no consulta (apagado o desconectado), o los trabajos fueron a **otro equipo** | En **Trabajos LidaPrint**, mirar la columna **Equipo**. Corregir **Imprimir en** del usuario o el **Equipo por defecto**. Los pendientes **no caducan**: se imprimirán cuando ese equipo se conecte. Si no deben imprimirse, **Cancelar** (solo trabajos pendientes; usuarios de facturación) y reimprimir desde la factura en el equipo correcto (sale COPIA) |
| Salió en la caja equivocada | **Imprimir en** del usuario o **Equipo por defecto** apuntan a otra caja, o dos PC comparten token (aparece **Equipo anterior** en el equipo) | Corregir la preferencia o el equipo por defecto. Si comparten token: generar un token para cada PC (A4) |
| Al pulsar **Forma Libre**: «No hay un equipo LidaPrint asignado para <compañía>...» | El usuario no tiene **Imprimir en** válido y la compañía no tiene **Equipo por defecto** (o está archivado) | [B6](#b6-activar-el-destino-nube-en-odoo). No se consumió ningún número de copia |
| Log: `Nube: trabajo #51 (...) caducado: recibido hace 12 min sin poder imprimirse; NO se imprime`. En Odoo: **Error**, origen **Informado por LidaPrint**, «Trabajo caducado: ...; verifique en Odoo antes de reimprimir» | El trabajo esperó **10 minutos o más** en la PC sin poder imprimirse (Odoo caído, red cortada) | LidaPrint **no** lo imprimió a propósito, para no duplicar un documento fiscal. Verificar el papel y el estado en Odoo. Si no salió: **Reenviar el original** en el trabajo (existe porque LidaPrint informó el error; pide confirmación) o **Forma Libre** en la factura (sale COPIA) |
| En Odoo: **Error**, origen **Sin confirmación (cron)**, «LidaPrint no confirmó la impresión a tiempo. Verifique el papel antes de reimprimir: pudo haberse impreso.» | El trabajo quedó en **Imprimiendo** más de 15 min sin confirmación (la PC se apagó, LidaPrint se reinició a mitad de un lote, sin red). El cron corre cada 5 min | **Verificar el papel.** Si no salió, reimprimir desde la factura con **Forma Libre** (sale **COPIA**). En estos trabajos no se ofrece **Reenviar el original**. Una confirmación tardía no cambia el estado (queda una nota en la factura) |
| Al pulsar **Forma Libre**: «No se ha podido encontrar Wkhtmltopdf en el sistema. El PDF no se puede crear.» | Falta wkhtmltopdf en el servidor o no está en el `PATH` del servicio de Odoo | [A2](#a2-wkhtmltopdf). No se encoló nada |
| Al pulsar **Forma Libre**: «El PDF supera el límite de 50 MB aceptado por LidaPrint (...)» o «El documento generado no es un PDF válido.» | Documento demasiado grande, o el reporte no genera PDF | Reducir el documento (imágenes). No se encoló nada |
| Log: `Nube: trabajo #51 rechazado: El archivo recibido no es un PDF (...)` o `... PDF demasiado grande (> 50 MB) ...` | Lo que llegó a la PC no es el PDF: típico de un proxy, portal cautivo o antivirus que devuelve una página HTML | Revisar el proxy o firewall de la red (7.1). El trabajo queda en error informado por LidaPrint: si el papel no salió, **Reenviar el original** |
| Log: `Nube: el trabajo #51 ya fue atendido en esta sesion; NO se reimprime` | Protección contra doble impresión | Nada. Una reimpresión desde Odoo siempre crea un trabajo nuevo |

### 7.3 Instalación, arranque y hoja impresa

| Síntoma | Causa | Solución |
|---|---|---|
| Durante la instalación la consola espera y no aparece el asistente de Ghostscript | El aviso de UAC («Windows PowerShell») quedó detrás de otra ventana | Buscarlo en la barra de tareas y responder **Sí**. El asistente avanza solo; no cerrarlo |
| `El instalador de Ghostscript no termino en 5 minutos y fue cancelado.` o `...termino con codigo N` | UAC rechazado, antivirus que bloquea el instalador o descarga dañada | Volver a ejecutar B1 aceptando el UAC. Si se repite: instalar Ghostscript a mano desde ghostscript.com (valores por defecto) y, en el Configurador, **Avanzado > Detectar** |
| Después de reiniciar la PC no imprime; el equipo no aparece **En línea** | **Auto-iniciar con Windows (Task Scheduler)** desmarcado (al guardar se vio `corre solo en esta sesion`), o se inició sesión con otro usuario de Windows | Marcar **Auto-iniciar con Windows (Task Scheduler)** y **Guardar**. Comprobar la tarea: `Get-ScheduledTask -TaskName "LidaPrint"`. La tarea arranca al iniciar sesión el usuario que instaló LidaPrint: instalar con el usuario de la caja |
| Salen 4 hojas (2×2) | **Copias:** `2` en LidaPrint (valor inicial) | Pestaña **Impresora** > **Copias:** `1` > **Guardar** |
| Una reimpresión sale como COPIA | Correcto: el original fiscal existe una sola vez. El aviso de Odoo lo dice (`2 copias`) | Nada |
| Se perdió el token (no se copió o se cerró la ventana) | Odoo solo guarda la huella del token: no se puede recuperar | **Generar token** otra vez en el equipo (el anterior deja de funcionar al instante) y pegarlo en la PC |
| Errores de TLS en una PC y en otras no | Fecha u hora de Windows incorrectas, o una PC sin la CA interna importada | Corregir fecha, hora y zona horaria (sincronizar la hora de Windows). Importar la CA (7.1) |

---

## 8. Mantenimiento

**Rotar el token de un equipo** (por ejemplo, si se filtró):

1. Odoo: abrir el equipo > **Generar token** > confirmar. El token anterior deja de
   funcionar **de inmediato** (LidaPrint recibe 401).
2. Copiar el token nuevo > **Listo, ya lo copié**.
3. PC: pestaña **Conexion** > **Token:** > pegar > **Probar conexion** > **Guardar**.

**Revocar el token**: equipo > **Revocar token** > confirmar («LidaPrint recibirá
401 en su próxima consulta y dejará de imprimir en este equipo.»). El agente sigue
intentando cada 60 s y luego cada 300 s hasta que se cambie su configuración.

**Archivar un equipo** (PC retirada):

1. **Cancelar** sus trabajos **Pendiente** (si no, se imprimirían si esa PC vuelve a
   conectarse).
2. Cambiar el **Equipo por defecto** y el **Imprimir en** de los usuarios que
   apuntaban a él.
3. En el formulario del equipo: **Acciones** (engranaje) > **Archivar**. El equipo
   recibe 401 igual que con el token revocado. Para verlo después: filtro
   «Archivados».
4. En esa PC, cambiar el modo en el Configurador (**Local** o **Red local**) o
   desinstalar: `LidaPrint.exe -Uninstall`. Mientras siga en Nube, consulta cada
   5 minutos y recibe 401.

**Actualizar LidaPrint** en una PC: volver a ejecutar el comando de B1. Descarga la
última versión y conserva `config.json` (URL, token, impresora, copias). Después,
**Ver Log** debe mostrar `Conectado a Odoo`, y en Odoo el campo **Versión de
LidaPrint** del equipo muestra la versión nueva.

**Cambiar el dominio de Odoo**: actualizar **URL de Odoo:** en cada PC y
**Guardar**. Los tokens siguen valiendo.

**Volver al destino Navegador o Red local**: antes, **Cancelar** los trabajos
**Pendiente** en **Trabajos LidaPrint**; después, cambiar el modo de LidaPrint en
cada PC.

**Logs**: un archivo por mes en `%LOCALAPPDATA%\LidaPrint\logs\`
(`PrintLog_yyyy-MM.txt`). Los PDF de los trabajos se conservan en Odoo como traza.
