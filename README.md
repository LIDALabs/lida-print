# LidaPrint

Sistema de impresion automatica de facturas Odoo para Windows. Vigila una carpeta, imprime cada PDF con Ghostscript y elimina el archivo. Puede operar de forma autonoma (por patron de nombre) o controlado por Odoo via HTTP.

Este es el **unico documento del proyecto**: cubre **uso**, **configuracion** y **funcionamiento interno**.

## Estructura del proyecto

```
lida-print/
├── README.md                ← Este archivo (documentacion completa)
├── get.ps1                  ← Script de instalacion/actualizacion web (curl / irm)
├── build/
│   └── Update-DriverHashes.ps1  ← Recalcula hashes SHA-256 de drivers en drivers.json
├── drivers/
│   ├── drivers.json         ← Catalogo de drivers incluidos
│   ├── epson-tm-u220pd/     ← Driver APD para EPSON TM-U220PD
│   ├── epson-m188d/         ← Driver APD para EPSON M188D
│   ├── canon-lbp6030/       ← Instalador para Canon LBP6030/6030B/6030w
│   └── ...
├── LidaPrint.ps1            ← Monitor + servidor HTTP
├── Configurator.ps1         ← GUI de configuracion
├── LidaPrint.bat            ← Abre el Configurator sin dejar consola abierta
├── LidaPrint.vbs            ← Igual, con cero parpadeo (para doble clic)
├── config.json              ← Plantilla de configuracion
├── logo.png                 ← Icono de la GUI
├── logs/                    ← Registro de impresiones (se crea al ejecutar)
└── temp/                    ← PDFs intermedios de la pasada 1 (se crea al ejecutar)
```

> **Donde vive la instalacion:** LidaPrint se instala en `%LOCALAPPDATA%\LidaPrint` como
> un unico ejecutable (`LidaPrint.exe`). El instalador descarga solo ese archivo desde
> GitHub Releases — no se copia codigo fuente ni scripts.

---

## Tabla de contenidos

1. [Que hace](#que-hace)
2. [Requisitos](#requisitos)
3. [Instalacion](#instalacion)
4. [Uso diario](#uso-diario)
5. [Configuracion (Configurator)](#configuracion-configurator)
6. [Referencia de config.json](#referencia-de-configjson)
7. [Modos de operacion](#modos-de-operacion)
8. [API HTTP](#api-http)
9. [Patrones de nombre](#patrones-de-nombre)
10. [Motor de impresion (Ghostscript)](#motor-de-impresion-ghostscript)
11. [Logs](#logs)
12. [Drivers de impresora](#drivers-de-impresora)
13. [Como funciona internamente](#como-funciona-internamente)
14. [Solucion de problemas](#solucion-de-problemas)
15. [Desinstalar](#desinstalar)

---

## Que hace

Una vez instalado, LidaPrint corre en segundo plano (Task Scheduler) y:

1. Monitorea la carpeta de Descargas cada 1 segundo.
2. Detecta PDFs nuevos (por patron de nombre o por cola de impresion de la API).
3. Los imprime con Ghostscript usando la configuracion guardada.
4. Elimina el archivo tras imprimirlo.

Todo sin intervencion del usuario.

---

## Requisitos

- Windows 10 / 11
- PowerShell 5.1 o superior
- Ghostscript (el instalador lo instala automaticamente)
- Impresora configurada en Windows
- **No requiere Administrador** (Ghostscript puede pedir UAC una vez, si no esta instalado)

---

## Instalacion

### Instalacion en un comando (recomendado)

Abrir PowerShell (normal, sin admin) y pegar:

```powershell
irm https://raw.githubusercontent.com/LIDALabs/lida-print/main/get.ps1 | iex
```

O desde cmd con `curl`:

```cmd
curl -L -o "%TEMP%\get.ps1" https://raw.githubusercontent.com/LIDALabs/lida-print/main/get.ps1 && powershell -ExecutionPolicy Bypass -File "%TEMP%\get.ps1"
```

El instalador descarga **unicamente `LidaPrint.exe`** desde GitHub Releases (no se instala
codigo fuente), lo copia a `%LOCALAPPDATA%\LidaPrint`, instala Ghostscript si es necesario,
crea la tarea programada y **abre el Configurator automaticamente** al terminar.

**El mismo comando sirve para actualizar:** volver a ejecutarlo descarga la version mas
reciente de `LidaPrint.exe` y reemplaza la anterior. La configuracion (`config.json`) se
conserva intacta.

### Despues de instalar

No hay nada que "correr" a mano: el monitor ya quedo corriendo y se re-lanza solo en cada
inicio de sesion. Para uso tecnico por consola (abrir una consola **nueva** tras instalar):

```powershell
Start-ScheduledTask -TaskName "LidaPrint"    # arrancar el monitor a mano
Stop-ScheduledTask  -TaskName "LidaPrint"    # detenerlo
Get-ScheduledTask   -TaskName "LidaPrint"    # ver estado
```

---

## Uso diario

### Modo Local (sin API)

1. Odoo descarga la factura a la carpeta de Descargas.
2. El nombre coincide con el patron (ej: `F-12345678.pdf`).
3. LidaPrint la detecta, la imprime y la borra.

### Modo API (controlado por Odoo)

1. Odoo descarga la factura a Descargas.
2. Odoo envia `POST /print {"filename": "F-12345678.pdf"}`.
3. LidaPrint la detecta en la cola, la imprime y la borra.
4. Odoo puede enviar `POST /skip` para archivos que NO deben imprimirse.

---

## Configuracion (Configurator)

Se abre desde `LidaPrint.bat` o ejecutando `Configurator.ps1`. GUI con tema oscuro, 6 pestanas.

### Pestana 1: Impresion

| Campo | Descripcion | Default |
|-------|-------------|---------|
| Impresora | Impresora fisica de Windows | Primera disponible |
| Copias | Copias por documento (1-10) | 2 |
| Orientacion | `portrait` / `landscape` | portrait |
| Escala (%) | Porcentaje del tamano original (10-200) | 100 |
| DPI | Resolucion de impresion: presets (203 matriciales, 300 laser, etc.) **o valor escrito a mano** (72-1200) | 300 |
| DPI del driver | Muestra el DPI por defecto que reporta el driver de la impresora seleccionada (Epson, Bixolon, Canon, etc.); boton **Usar este DPI** lo aplica de un clic | auto |

### Pestana 2: Papel

| Campo | Descripcion | Default |
|-------|-------------|---------|
| Paper Size | A4, Letter, Legal, Tabloid, A5, Continuo, Custom | A4 |
| Tamano personalizado | Habilita ancho/alto manual; al marcarlo el Paper Size pasa a `Custom` automaticamente (y viceversa) | desactivado |
| Ancho / Alto | En mm (50-2000) | 210 / 297 |
| Margenes | Superior/Inferior/Izq/Der en mm — aplicados por **Ghostscript** | 0 |

> **Nota sobre margenes:** cada margen **empuja** el contenido en su direccion, sin
> escalarlo: izquierdo lo mueve a la derecha, derecho a la izquierda, superior hacia
> abajo, inferior hacia arriba. Margenes opuestos se restan (izq 20 + der 5 = corrimiento
> neto de 15mm a la derecha). Si el contenido queda fuera del papel, se recorta — para
> achicarlo usa **Escala (%)**. El desplazamiento superior de forma continua empuja hacia abajo.

### Pestana 3: Forma Continua

Para impresoras matriciales con papel tractor.

| Campo | Descripcion | Default |
|-------|-------------|---------|
| Activar modo | Usa dimensiones de forma continua | desactivado |
| Largo del formulario | Alto en mm (50-5000) | 279 |
| Desplazamiento superior | Offset en mm | 0 |
| Interlineado | mm entre lineas (4.23 = 6 LPI) | 4.23 |

### Pestana 4: Calidad

El apartado que controla **como se renderiza** el PDF antes de llegar a la impresora.

| Campo | Descripcion | Default |
|-------|-------------|---------|
| Suavizado maximo | Renderiza texto y graficos como imagen con antialiasing | desactivado |
| Ghostscript | Ruta al ejecutable (`gswin64c.exe`), con **Detectar** automatico | auto-detectado |
| Conversor DPI/pixeles | mm + DPI -> pixeles, y pixeles + DPI -> mm (bidireccional, en vivo) | 210mm @ 203dpi |

**Cuando usar Ghostscript:** si el PDF se ve perfecto en pantalla pero **imprime feo**
(letras deformadas, fuentes sustituidas, texto serruchado), el problema suele ser como el
driver interpreta las fuentes del PDF. Ghostscript lo evita: **rasteriza la pagina al DPI
exacto configurado** (pestana Impresion) y la envia ya renderizada como mapa de bits via el
driver de Windows (device `mswinpr2`). El driver ya no interpreta nada: solo pinta puntos.

**El conversor DPI/pixeles:** las impresoras de forma continua trabajan en pixeles a una
densidad fija (203 DPI = 8 puntos/mm es el estandar en matriciales y termicas). El conversor
resuelve la cuenta en ambos sentidos:

- `pixeles = mm / 25.4 * DPI`  (ej: 210mm a 203dpi = 1678 px)
- `mm = pixeles / DPI * 25.4`  (ej: 1678 px a 203dpi = 210mm)

Util para calcular el `Largo del formulario` (pestana Forma Continua) cuando el fabricante
especifica el area imprimible en pixeles.

### Pestana 5: Monitoreo

| Campo | Descripcion | Default |
|-------|-------------|---------|
| Descargas | Carpeta a vigilar (boton **Abrir** la abre en el Explorador) | `...\Downloads` |
| Patron factura | Regex de validacion | `^(F\|ND\|NC)-\d{8}\.pdf$` |
| Usar patron | Filtro por regex (se **desactiva** al activar la API) | activado |
| Activar API web | Modo controlado por Odoo | desactivado |
| Puerto | Puerto HTTP (muestra la URL al activar) | 8080 |
| API Key | Clave de autenticacion (boton **Mostrar/Ocultar**). Obligatoria si la API esta activa | (vacio) |

### Pestana 6: Sistema

| Campo | Descripcion | Default |
|-------|-------------|---------|
| Auto-iniciar con Windows | Crea/elimina la tarea programada | activado |
| Generar logs | Escribe en `logs/PrintLog_yyyy-MM.txt` | activado |
| Ver Log | Abre el log mas reciente en el Bloc de notas | — |

Botones inferiores: **Probar Impresion** (envia un PDF de prueba), **Guardar** (valida y persiste), **Cancelar**.

Al **Guardar**, el Configurator valida: impresora seleccionada, carpeta de descargas existente,
ruta de Ghostscript valida, patron regex correcto,
API Key presente si la API esta activa, y advierte si el puerto es < 1024.

Ademas, al guardar **repara la tarea programada** si apunta a una ruta vieja: la re-registra
apuntando a la ubicacion actual de los scripts. Esto resuelve el caso "movi/borre la carpeta
y dejo de imprimir".

---

## Referencia de config.json

```json
{
    "printer":         "Canon LBP6030/6040/6018L",
    "copies":          2,
    "orientation":     "portrait",
    "paperSize":       "A4",
    "paperWidth":      210,
    "paperHeight":     297,
    "useCustomPaper":  false,
    "scale":           100,
    "dpi":             300,
    "marginTop":       0,
    "marginBottom":    0,
    "marginLeft":      0,
    "marginRight":     0,
    "continuousForm":  false,
    "formLength":      279,
    "topOffset":       0,
    "linePitch":       4.23,
    "gsPath":          "",
    "renderAsImage":   false,
    "downloadFolder":  "",
    "installPath":     "",
    "autoStart":       true,
    "enableLogging":   true,
    "usePattern":      true,
    "invoicePattern":  "^(F|ND|NC)-\\d{8}\\.pdf$",
    "webEnabled":      false,
    "webPort":         8080,
    "webApiKey":       ""
}
```

| Campo | Tipo | Descripcion |
|-------|------|-------------|
| `printer` | string | Nombre exacto de la impresora en Windows |
| `copies` | int | Copias por documento |
| `orientation` | string | `portrait` o `landscape` |
| `paperSize` | string | Preset de papel |
| `paperWidth` / `paperHeight` | int | Dimensiones en mm (papel personalizado) |
| `useCustomPaper` | bool | Usa dimensiones manuales |
| `scale` | int | Escala en % |
| `dpi` | int | Resolucion |
| `marginTop/Bottom/Left/Right` | int | Desplazamiento del contenido en mm (cada margen empuja en su direccion) |
| `continuousForm` | bool | Modo papel continuo |
| `formLength` | int | Largo del formulario en mm |
| `topOffset` | int | Desplazamiento superior en mm (forma continua, motor Ghostscript) |
| `linePitch` | decimal | Informativo — no aplicable a PDFs (es un concepto de impresoras de linea) |
| `gsPath` | string | Ruta a Ghostscript (`gswin64c.exe`). Si esta vacia o quedo obsoleta, **se re-resuelve sola** en runtime |
| `renderAsImage` | bool | Suavizado maximo de texto/graficos al rasterizar |
| `downloadFolder` | string | Carpeta monitoreada. Vacia = Descargas del usuario actual |
| `installPath` | string | Informativo. En runtime los scripts se auto-ubican con su propia ruta |
| `autoStart` | bool | Si debe existir la tarea programada |
| `enableLogging` | bool | Habilita el log |
| `usePattern` | bool | Filtra por regex (solo modo Local) |
| `invoicePattern` | string | Regex de validacion de nombres |
| `webEnabled` | bool | Habilita el servidor HTTP |
| `webPort` | int | Puerto HTTP |
| `webApiKey` | string | Clave de autenticacion. **Obligatoria** si `webEnabled = true` (sin ella el listener no arranca) |

---

## Modos de operacion

### Modo Local (`webEnabled = false`)

Autonomo. Depende de `usePattern`:

- **`usePattern = true`**: solo imprime archivos cuyo nombre coincide con `invoicePattern`.
- **`usePattern = false`**: imprime cualquier PDF que aparezca.

### Modo API (`webEnabled = true`)

LidaPrint deja de imprimir automaticamente y espera instrucciones de Odoo:

- Solo imprime archivos que esten en la `printQueue`.
- Odoo agrega archivos via `POST /print` y los excluye via `POST /skip`.
- El patron de nombres **no se usa** (la UI desactiva el checkbox automaticamente).

---

## API HTTP

Se activa con `webEnabled = true`. El listener registra el prefijo **raiz** (`http://+:PUERTO/`) y enruta todas las rutas en codigo.

### Autenticacion

La **API Key es obligatoria** cuando `webEnabled = true`. Si la API esta activada pero
`webApiKey` esta vacia, el listener **no se inicia** (se registra un error en el log) — asi se
evita exponer un endpoint de subida+impresion sin autenticacion. El Configurator tambien
bloquea el guardado en ese caso.

Toda peticion POST debe incluir el header `X-Api-Key: <clave>`. Si no coincide: **401**.
`GET` no requiere auth.

> **Exposicion de red:** el listener escucha en todas las interfaces (`http://+:PUERTO/`) para
> permitir el acceso desde otra maquina (ver Firewall). Si Odoo corre en la **misma** maquina,
> considera restringir el binding a loopback (`http://127.0.0.1:PUERTO/`) para reducir la
> superficie de ataque.

### Endpoints

| Metodo | Ruta | Descripcion |
|--------|------|-------------|
| GET | `/` | Dashboard HTML con estado en vivo (auto-refresco 5s) |
| GET | `/print/status` | Estado JSON: printQueue y skipList |
| POST | `/print` | Agrega archivo(s) a la cola de impresion |
| POST | `/skip` | Marca archivo(s) para NO imprimir |
| POST | `/clear` | Vacia ambas colas |
| POST | `/print/file` | Sube un PDF binario (max 50 MB) y lo encola |

#### GET `/print/status`
```bash
curl http://localhost:8080/print/status
```
```json
{ "status": "ok", "printQueue": ["F-12345678.pdf"], "skipList": ["ND-00001234.pdf"] }
```

#### POST `/print`
```bash
curl -X POST http://localhost:8080/print -H "Content-Type: application/json" \
  -d '{"filename": "F-12345678.pdf"}'
# o varios:
curl -X POST http://localhost:8080/print -H "Content-Type: application/json" \
  -d '{"filenames": ["F-12345678.pdf", "NC-00005678.pdf"]}'
```
```json
{ "ok": true, "added": ["F-12345678.pdf"], "printQueue": ["F-12345678.pdf"] }
```

#### POST `/skip`
```bash
curl -X POST http://localhost:8080/skip -H "Content-Type: application/json" \
  -d '{"filename": "ND-00001234.pdf"}'
```

#### POST `/clear`
```bash
curl -X POST http://localhost:8080/clear
```

#### POST `/print/file`
```bash
curl -X POST http://localhost:8080/print/file \
  -H "X-Filename: F-12345678.pdf" --data-binary @factura.pdf
```
El nombre se sanea (solo el nombre de archivo, sin rutas), se rechazan archivos > 50 MB (**413**)
y se valida que el contenido empiece con los magic bytes `%PDF-`; si no, **400**.

### Codigos HTTP

| Codigo | Significado |
|--------|-------------|
| 200 | Exito |
| 400 | Body invalido |
| 401 | API Key incorrecta |
| 404 | Ruta no encontrada |
| 405 | Metodo no permitido |
| 413 | Archivo demasiado grande |

### Integracion con Odoo (Python)

```python
import requests

BASE = "http://localhost:8080"
HEADERS = {"Content-Type": "application/json", "X-Api-Key": "mi_clave"}

requests.post(f"{BASE}/print", json={"filename": "F-12345678.pdf"}, headers=HEADERS)
requests.post(f"{BASE}/skip",  json={"filename": "ND-00001234.pdf"}, headers=HEADERS)
print(requests.get(f"{BASE}/print/status", headers=HEADERS).json())
requests.post(f"{BASE}/clear", headers=HEADERS)
```

**IMPORTANTE — la URL se resuelve donde corre Odoo, no donde corre LidaPrint.**
La peticion HTTP la hace el **servidor** de Odoo (Python), no el navegador del
usuario. `http://localhost:PUERTO` solo funciona si Odoo y LidaPrint corren en
la **misma** maquina. Si Odoo corre en Linux y LidaPrint en un Windows aparte
(fisico o VM), la URL configurada en Odoo debe ser la IP de esa maquina Windows
vista desde el servidor de Odoo, por ejemplo `http://192.168.122.32:8081`.
La URL que muestra el Configurator (`http://localhost:...`) es valida solo
dentro del propio Windows.

### Integracion con Odoo (modulo l10n_ve_lidoo_integration_api)

El modulo de la localizacion venezolana trae la integracion lista en
**Ajustes > API de integracion > LidaPrint**:

| Campo | Valor |
|-------|-------|
| Imprimir Forma Libre con LidaPrint | Interruptor. Encendido, el boton **Forma Libre** envia a LidaPrint dos PDF por documento: el original y la copia **SIN DERECHO A CREDITO FISCAL**. Apagado, descarga el PDF en el navegador como siempre |
| URL de LidaPrint | IP del Windows donde corre LidaPrint (ver advertencia de `localhost` arriba). Ej: `http://192.168.122.32:8081` |
| API Key de LidaPrint | La misma `webApiKey` del `config.json` (pestana Monitoreo del Configurator) |
| Probar conexion | Hace `GET /print/status` y notifica si LidaPrint responde |

Reglas de comportamiento del modulo:

- Solo aplica a facturas, notas de credito y notas de debito de cliente
  publicadas con numero de control.
- Con el interruptor encendido y sin conexion, la impresion se **bloquea** con
  un error explicito (no imprime a medias en silencio).
- En el `config.json` de LidaPrint dejar **`copies: 1`**: Odoo ya envia
  original y copia como documentos separados; con `copies: 2` saldria 2x2.
- Los PDF viajan por `POST /print/file` (subida directa), asi que **no** hace
  falta carpeta compartida ni que el navegador descargue nada.

### Acceso desde otra maquina (Odoo en Linux, LidaPrint en VM/PC Windows)

Checklist completo para que la API responda desde fuera del Windows. Los tres
pasos de PowerShell van **como Administrador** y usan el puerto configurado en
la pestana Monitoreo (ejemplos con 8081):

```powershell
# 1. Perfil de red Privado (el perfil Publico descarta todo el trafico entrante)
Set-NetConnectionProfile -NetworkCategory Private

# 2. Regla de firewall para el puerto de LidaPrint
New-NetFirewallRule -DisplayName "LidaPrint HTTP" -Direction Inbound -LocalPort 8081 -Protocol TCP -Action Allow

# 3. Reserva urlacl: sin esto el listener NO ARRANCA cuando LidaPrint corre sin admin
netsh http add urlacl url=http://+:8081/ user=$env:USERNAME
```

Despues de los tres pasos, **reiniciar LidaPrint** (Guardar en el Configurator
y relanzar el monitor): el listener solo relee la configuracion al arrancar.

Verificacion, en orden — cada paso descarta una capa:

```powershell
# Dentro del Windows: el listener esta vivo?
netstat -ano | findstr :8081        # debe mostrar 0.0.0.0:8081 LISTENING
curl.exe -m 3 http://localhost:8081/print/status   # debe devolver {"status":"ok",...}
```

```bash
# Desde la maquina de Odoo (Linux):
curl -m 5 http://IP_DEL_WINDOWS:8081/print/status  # debe devolver {"status":"ok",...}
```

Como leer los fallos del curl remoto:

- **Timeout** -> el firewall de Windows esta descartando los paquetes
  (perfil de red Publico o falta la regla del paso 2).
- **Connection refused** -> el puerto esta abierto pero no hay listener
  (LidaPrint apagado, o el listener no arranco por falta de urlacl del paso 3;
  el log de LidaPrint registra el motivo).

En una VM libvirt/KVM, la IP del guest se obtiene desde el host con:

```bash
virsh -c qemu:///system net-dhcp-leases default
```

El ping al Windows puede fallar aunque todo este bien (ICMP viene bloqueado
por defecto); probar siempre con `curl` al puerto, no con ping.

---

## Patrones de nombre

Solo en Modo Local con `usePattern = true`. Patron por defecto: `^(F|ND|NC)-\d{8}\.pdf$`

| Ejemplo | Valido |
|---------|--------|
| `F-12345678.pdf` | Si |
| `ND-00001234.pdf` | Si |
| `NC-00005678.pdf` | Si |
| `F-123.pdf` | No (menos de 8 digitos) |
| `factura.pdf` | No (prefijo incorrecto) |
| `F_12345678.pdf` | No (guion bajo) |

---

## Motor de impresion (Ghostscript)

LidaPrint imprime exclusivamente con **Ghostscript**: rasteriza cada pagina al DPI exacto
configurado y la envia ya renderizada via el driver de Windows (device `mswinpr2`). El
driver no interpreta fuentes ni geometria — solo pinta puntos. Eso garantiza que lo que se
ve en pantalla es lo que sale en papel, tambien en matriciales y forma continua.

La impresion son **dos pasadas** de Ghostscript:

**Pasada 1 — tamano de papel (`pdfwrite`):** el device de impresion de Windows (`mswinpr2`)
toma el tamano de pagina del DEVMODE del driver e **ignora** los parametros de medio de la
linea de comandos. Por eso el tamano configurado se aplica primero re-formateando el PDF:

```
gswin64c.exe -dBATCH -dNOPAUSE -dQUIET -sDEVICE=pdfwrite -dDEVICEWIDTHPOINTS=142 -dDEVICEHEIGHTPOINTS=283 -dFIXEDMEDIA -dFitPage "-sOutputFile=%TEMP%\lidaprint_fit_X.pdf" -f "archivo.pdf"
```

**Pasada 2 — impresion (`mswinpr2`):** el PDF ya redimensionado se rasteriza al DPI
configurado y se envia al driver, con margenes y escala del usuario:

```
gswin64c.exe -dBATCH -dNOPAUSE -dQUIET -dNoCancel -sDEVICE=mswinpr2 -r300 -dNumCopies=2 "-sOutputFile=%printer%Impresora" -c "<< /BeginPage { pop 28 -28 translate 0.9 0.9 scale } >> setpagedevice" -f "%TEMP%\lidaprint_fit_X.pdf"
```

| Opcion | Descripcion |
|--------|-------------|
| `pdfwrite` + `-dDEVICEWIDTH/HEIGHTPOINTS -dFIXEDMEDIA -dFitPage` | Re-formatea el PDF al tamano configurado (landscape intercambia ancho/alto) |
| `-sDEVICE=mswinpr2` | Imprime via el driver de Windows con la pagina YA rasterizada |
| `-rN` | DPI de rasterizado (pestana Impresion: 203, 300, etc.) |
| `-dNumCopies=N` | Copias |
| `-c "<< /BeginPage ... >>"` | Margenes (desplazamiento puro por lado), topOffset y escala del usuario |
| `-dTextAlphaBits=4 -dGraphicsAlphaBits=4` | Suavizado maximo (checkbox en la pestana Calidad) |

> **Nota fisica:** el tamano configurado define el area que ocupa el CONTENIDO. La hoja
> fisica es la que este cargada en la impresora: un contenido de 50x100mm sobre una hoja
> media carta imprime en una region de 50x100mm de esa hoja (alineable con los margenes).

Todas las funcionalidades de configuracion (margenes, orientacion, paper size, escala,
DPI, forma continua, desplazamiento superior) estan soportadas por este motor. La unica
excepcion es `linePitch` (interlineado), que no aplica a PDFs.

---

## Logs

Con `enableLogging = true`, LidaPrint escribe en `logs/PrintLog_yyyy-MM.txt` (rotacion mensual, evita crecimiento indefinido).

```
[2026-07-22 10:15:30] [OK] Impreso (Ghostscript 300dpi): F-12345678.pdf -> Canon LBP6030
[2026-07-22 10:15:31] [OK] Eliminado: F-12345678.pdf
[2026-07-22 10:15:45] [WARN] Archivo bloqueado: NC-00005678.pdf
```

Niveles: `INFO`, `WARN`, `ERROR`, `OK`.

---

## Drivers de impresora

LidaPrint incluye drivers preempaquetados para modelos comunes. Se instalan desde la
pestana **Drivers** del Configurator — no hace falta buscarlos en la web del fabricante.

### Drivers incluidos

| Modelo | Tipo | Formato |
|--------|------|---------|
| EPSON TM-U220PD | Matricial / ticket | APD (zip) |
| EPSON M188D | Termica / ticket | APD (zip) |
| Canon LBP6030 / 6030B / 6030w | Laser | Instalador exe |

### Instalar un driver desde el Configurator

1. Abrir el Configurator (`LidaPrint.exe`).
2. Ir a la pestana **Drivers**.
3. Seleccionar el modelo de la lista.
4. Hacer clic en **Instalar** y seguir las instrucciones del instalador.

Al terminar la instalacion, LidaPrint deja la impresora **utilizable de inmediato**
segun el bloque `postInstall` del driver (ver abajo): reasigna el puerto, apaga el
bidireccional y limpia el estado "sin conexion" sin intervencion.

### Reparacion automatica post-instalacion (`postInstall`)

Algunas ticketeras EPSON (driver APD) conectadas por un **adaptador USB-a-paralelo**
(p. ej. CH340) quedan, tras el asistente del driver, atadas al puerto propio de EPSON
(`ESDPRTxxx`). Ese puerto usa deteccion USB **nativa EPSON** y nunca encuentra al
adaptador generico: el trabajo entra al spooler pero **no sale papel**, y el polling
bidireccional que el adaptador no responde deja la impresora en estado **"Sin conexion"**.

El Configurator corrige esto automaticamente al instalar, segun el bloque opcional
`postInstall` de cada driver en `drivers.json`:

| Campo | Efecto |
|-------|--------|
| `printerNameMatch` | Regex del nombre de la impresora instalada a reparar. |
| `rebindToUsb` | Reasigna la impresora del puerto `ESDPRTxxx` al puerto `USBxxx` del adaptador. |
| `usbPortMatch` | Regex de la descripcion del puerto USB fisico a elegir (su ID 1284). |
| `disableBidi` | Apaga el soporte bidireccional (`EnableBIDI=false`) que causa el "Sin conexion". |
| `clearOffline` | Quita el flag "usar impresora sin conexion". |

La rutina es idempotente y no bloquea: cualquier fallo se registra en el log y la
instalacion continua. Nota: el asistente del APD todavia pide **una vez** seleccionar
el modelo y el puerto USB; a partir de ahi, todo lo demas es automatico.

### Agregar un driver nuevo al repositorio

1. Colocar el archivo del driver (zip, exe, etc.) en `drivers/<id>/`.
2. Agregar la entrada correspondiente en `drivers/drivers.json` con los campos `id`,
   `name`, `version`, `file`, y `sha256` (dejar `sha256` en blanco por ahora). Si la
   impresora necesita reparacion post-instalacion, agregar el bloque `postInstall`
   descrito arriba.
3. Ejecutar `build/Update-DriverHashes.ps1` para calcular y escribir los hashes SHA-256:

```powershell
.\build\Update-DriverHashes.ps1
```

4. Commitear `drivers/<id>/`, `drivers/drivers.json` y el hash actualizado.

El Configurator verifica el hash antes de instalar para garantizar la integridad del archivo.

---

## Como funciona internamente

### Componentes

| Archivo | Rol |
|---------|-----|
| `get.ps1` | Descarga `LidaPrint.exe` desde GitHub Releases y lo instala en `%LOCALAPPDATA%\LidaPrint` |
| `LidaPrint.exe` | Ejecutable unico: incluye el monitor, el Configurator y la logica de instalacion/desinstalacion |
| `config.json` | Configuracion persistente |
| `drivers/drivers.json` | Catalogo de drivers incluidos con hashes SHA-256 |
| `drivers/<id>/` | Archivos de driver por modelo |
| `logs/` | Registro de operaciones |

### Flujo general

```
get.ps1 (curl/irm)
    |
    v
LidaPrint.exe  ──>  %LOCALAPPDATA%\LidaPrint\  (instalacion ESTABLE)
    |
    v
LidaPrint.exe --configurator  ──>  config.json
    |
    v (Task Scheduler — al iniciar sesion, nivel usuario, sin admin)
LidaPrint.exe (monitor)
    |
    +-- [Resolucion de rutas]  Re-resuelve Ghostscript en runtime
    |
    +-- [Runspace HTTP]  Start-WebListener  (solo si webEnabled + API Key)
    |       GET  /             → dashboard HTML
    |       GET  /print/status → estado JSON
    |       POST /print        → printQueue.Add
    |       POST /skip         → skipList.Add
    |       POST /clear        → vacia ambas colas
    |       POST /print/file   → guarda PDF (max 50MB, nombre saneado) + encola
    |
    +-- [Loop principal]  Polling cada 1s
            |
            +-- Modo API:   solo procesa archivos en printQueue
            +-- Modo Local: usePattern=true → filtra por regex
            |               usePattern=false → imprime todo PDF
            v
      Ghostscript imprime  →  elimina archivo

LidaPrint.exe -Uninstall  →  elimina tarea, proceso e instalacion
```

### Resolucion de rutas (self-locating)

El bug clasico de "movi la carpeta y dejo de imprimir" se elimina en tres capas:

1. **Instalacion estable:** todo vive en `%LOCALAPPDATA%\LidaPrint`, una ruta que no
   depende de donde descargaste el proyecto.
2. **Auto-ubicacion:** los scripts derivan su propia carpeta (`$scriptDir`) en runtime;
   `config.json`, `logs/` y los ejecutables se buscan relativos a ella. Ninguna funcion
   confia en el `installPath` guardado.
3. **Auto-reparacion de la tarea:** al Guardar, el Configurator compara la ruta que ejecuta
   la tarea programada con la ubicacion real del script. Si difieren (instalacion vieja,
   carpeta movida), la re-registra y avisa.

La ruta de Ghostscript guardada en `config.json` es solo un cache: si el valor guardado
no existe, `Resolve-ToolPath` prueba las ubicaciones conocidas (`bin\` local,
`Program Files`, `%LOCALAPPDATA%\Programs`) y usa la primera que encuentre.

### Concurrencia

`printQueue` y `skipList` son **ArrayList sincronizados**
(`[System.Collections.ArrayList]::Synchronized(...)`), seguros para acceso concurrente
entre el hilo principal (polling) y el runspace del listener HTTP. El script del listener
recibe listener, carpeta de descargas, API key y ambas colas via `AddArgument` y corre con
`BeginInvoke` en su propio runspace.

### Funciones clave en LidaPrint.ps1

| Funcion | Rol |
|---------|-----|
| `Write-Log` | Escribe en consola y en el log mensual con timestamp y nivel |
| `Resolve-ToolPath` | Re-resuelve rutas de ejecutables en runtime (guardada -> conocidas) |
| `Test-FileReady` | Verifica que el archivo no este bloqueado por otro proceso |
| `Get-PaperPoints` | Dimensiones del papel en puntos segun la configuracion |
| `Invoke-PrintGhostscript` | Rasteriza al DPI configurado, aplica margenes/escala y envia via `mswinpr2` |
| `Remove-Invoice` | Elimina el archivo con hasta 5 reintentos |
| `Process-InvoiceFile` | Espera que el tamano se estabilice, imprime y elimina |
| `Start-WebListener` / `Stop-WebListener` | Ciclo de vida del servidor HTTP |

### Deteccion de archivos estables

Antes de imprimir, `Process-InvoiceFile` espera a que el tamano del archivo se mantenga
constante durante 3 lecturas consecutivas (hasta 20 intentos de 500 ms) y a que el archivo
no este bloqueado. Esto evita imprimir PDFs a medio descargar.

### Rastreo de archivos vistos (`$seenFiles`)

El loop mantiene un hashtable `$seenFiles` para no reprocesar el mismo archivo:

- En **modo Local**, todo archivo escaneado se marca como visto.
- En **modo API**, un archivo que aun no esta en `printQueue` **no** se marca, de modo que
  si Odoo lo encola despues (via `POST /print`), el siguiente poll lo detecta e imprime.

Los archivos que dejan de existir en disco se limpian del hashtable en cada ciclo.

---

## Solucion de problemas

| Problema | Causa probable | Solucion |
|----------|----------------|----------|
| No imprime ninguna factura | Impresora apagada o en pausa | Verificar estado en Panel de control |
| No imprime tras mover/borrar la carpeta descargada | Instalacion vieja apuntando a ruta muerta (ej: `C:\AutoPrintFacturas`) | Re-ejecutar el instalador (`irm .../get.ps1 \| iex`): migra la tarea a `%LOCALAPPDATA%\LidaPrint`. O abrir el Configurator y Guardar: repara la tarea |
| **Imprime feo** (el PDF se ve bien en pantalla) | El driver interpreta mal las fuentes del PDF | Pestana **Calidad** -> motor **Ghostscript** + DPI de la impresora (203 en matriciales). Si persiste, activar "Suavizado maximo" |
| Ghostscript no instalado o movido | winget/descarga fallo, UAC cancelado o ejecutable eliminado | Se auto-resuelve en runtime; si no, instalar desde ghostscript.com y usar **Detectar** en la pestana Calidad |
| El PDF no se elimina | Archivo bloqueado por otro proceso | LidaPrint reintenta 5 veces; si falla, se reintenta al reiniciar |
| No detecta facturas (modo local) | Patron incorrecto o API activada | Revisar el regex o desactivar la API |
| API no responde | Puerto en uso o firewall | `netstat -an \| findstr 8080` y abrir el puerto |
| Odoo dice "LidaPrint no respondio" con **timeout** | Firewall de Windows descartando trafico (perfil de red Publico o falta la regla), o la URL en Odoo apunta a `localhost` en vez de a la IP del Windows | Seguir el checklist de **Acceso desde otra maquina**; en Odoo usar `http://IP_DEL_WINDOWS:PUERTO` |
| Odoo no conecta pero `curl.exe localhost` funciona dentro del Windows | El listener esta vivo pero el firewall bloquea el acceso externo | Perfil de red Privado + regla de firewall del puerto (pasos 1 y 2 del checklist) |
| `netstat` no muestra el puerto y `curl.exe localhost` falla dentro del Windows | El listener nunca arranco: falta la reserva urlacl o no se reinicio tras Guardar | Paso 3 del checklist (`netsh http add urlacl ...`) y reiniciar LidaPrint |
| 401 Unauthorized | API Key incorrecta | Verificar el header `X-Api-Key` |
| El listener no arranca | Falta reserva urlacl (tarea de usuario, sin admin) | Una vez, como Administrador: `netsh http add urlacl url=http://+:8080/ user=%USERNAME%` (ajustar el puerto al configurado) y **reiniciar LidaPrint** |
| Ticketera EPSON: el trabajo entra a la cola pero **no sale papel** e imprime como "Sin conexion" | Conectada por adaptador USB-a-paralelo (CH340): quedo en el puerto `ESDPRTxxx` de EPSON (que no ve al adaptador) y con bidireccional activo | Se corrige solo al instalar el driver desde el Configurator (bloque `postInstall`). Manual: reasignar la impresora al puerto `USBxxx` del adaptador, apagar el bidireccional (Propiedades → Puertos → desmarcar "Habilitar compatibilidad bidireccional") y reiniciar el spooler |
| La tarea corre pero el log esta vacio (ni la linea de arranque) | Windows 11: `-WindowStyle Hidden` cuelga la creacion de la consola y el script nunca ejecuta | Reinstalar, o abrir el Configurator y **Guardar**: migra la tarea a `conhost --headless` (sin ventana) |
| Aparece una ventana de consola al imprimir y cerrarla mata el monitor | Tarea vieja lanzada con `-WindowStyle Minimized` (la ventana existia, solo minimizada) | Reinstalar o **Guardar**: la tarea migra a `conhost --headless`, el monitor corre sin ventana alguna |
| Monitor se cierra al iniciar | Error en `config.json` | Revisar el log: toda salida temprana escribe su motivo (impresora, motores, carpeta) |
| La consola parpadea al arrancar | Se ejecuto el `.bat` directo | Usar `LidaPrint.vbs` para arranque silencioso |

---

## Desinstalar

Desde cualquier terminal, sin admin:

```powershell
LidaPrint.exe -Uninstall
```

Elimina **todo**: la tarea programada, los procesos del monitor y la instalacion en
`%LOCALAPPDATA%\LidaPrint`. Es idempotente: se puede correr aunque algo ya no exista.

Para **reinstalar de cero**: correr la desinstalacion y despues el comando de instalacion.

Ghostscript no se elimina (una reinstalacion lo reutiliza). Para quitarlo:

```powershell
winget uninstall ArtifexSoftware.GhostScript
```

Si tenias SumatraPDF de versiones anteriores de LidaPrint y ya no lo usas:

```powershell
winget uninstall SumatraPDF.SumatraPDF
```

---

## Licencia

MIT
