# LidaPrint

Sistema de impresion automatica de facturas Odoo para Windows. Imprime cada PDF con Ghostscript (o ESC/POS crudo) y elimina el archivo. Tres modos: **Local** (vigila Descargas y filtra por patron de nombre), **Red local** (Odoo envia los PDF a esta PC por HTTP) y **Nube** (LidaPrint consulta a Odoo por HTTPS; sirve con Odoo en un VPS).

Este es el **documento principal del proyecto**: cubre **uso**, **configuracion** y **funcionamiento interno** de LidaPrint. El lado de Odoo del modo Nube (modulo `l10n_ve_lidoo_integration_api` 18.0.2.4.0 o superior; se recomienda 18.0.2.4.1) esta documentado en [`docs/odoo-modo-nube.md`](docs/odoo-modo-nube.md).

## Estructura del proyecto

```
lida-print/
├── README.md                ← Este archivo (documentacion principal)
├── docs/
│   └── odoo-modo-nube.md    ← Modo Nube en el modulo de Odoo (contrato, cola, seguridad fiscal)
├── get.ps1                  ← Script de instalacion/actualizacion web (curl / irm)
├── build/
│   └── Update-DriverHashes.ps1  ← Recalcula hashes SHA-256 de drivers en drivers.json
├── drivers/
│   ├── drivers.json         ← Catalogo de drivers incluidos
│   ├── epson-tm-u220pd/     ← Driver APD para EPSON TM-U220PD
│   ├── epson-m188d/         ← Driver APD para EPSON M188D
│   ├── canon-lbp6030/       ← Instalador para Canon LBP6030/6030B/6030w
│   └── ...
├── tests/                   ← Pruebas Pester (`Invoke-Pester ./tests`)
├── LidaPrint.ps1            ← Monitor + servidor HTTP + cliente del modo Nube
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
8. [Modo Nube (Odoo en VPS)](#modo-nube-odoo-en-vps)
9. [API HTTP](#api-http)
10. [Patrones de nombre](#patrones-de-nombre)
11. [Motor de impresion (Ghostscript)](#motor-de-impresion-ghostscript)
12. [Logs](#logs)
13. [Drivers de impresora](#drivers-de-impresora)
14. [Como funciona internamente](#como-funciona-internamente)
15. [Solucion de problemas](#solucion-de-problemas)
16. [Desinstalar](#desinstalar)

---

## Que hace

Una vez instalado, LidaPrint corre en segundo plano (Task Scheduler) y:

1. Recibe los PDF segun el modo: monitorea la carpeta de Descargas cada 1 segundo
   (Local y Red local) o consulta a Odoo por HTTPS si hay trabajos pendientes (Nube).
2. Decide que imprimir (patron de nombre, cola de la API o cola de trabajos de Odoo).
3. Los imprime con Ghostscript (o ESC/POS crudo) usando la configuracion guardada.
4. Elimina el archivo tras imprimirlo (en Nube, ademas, confirma el resultado a Odoo).

Todo sin intervencion del usuario.

---

## Requisitos

- Windows 10 / 11
- PowerShell 5.1 o superior
- Ghostscript (el instalador lo instala automaticamente)
- Impresora configurada en Windows
- **No requiere Administrador** (Ghostscript puede pedir UAC una vez, si no esta instalado)

> **Ghostscript:** si no esta instalado, el instalador de LidaPrint descarga GPL Ghostscript
> (licencia AGPL) desde el repositorio oficial de Artifex, verifica su firma y **avanza su
> asistente automaticamente**: desde la version 10.01.0 Artifex no permite la instalacion
> silenciosa (`/S`). Windows pide confirmacion de administrador una sola vez (el aviso de UAC
> aparece como "Windows PowerShell"). Si la instalacion no termina en 5 minutos, se cancela y
> se informa el error.

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

### Modo Nube (Odoo en VPS)

1. El usuario pulsa **Forma Libre** en Odoo: Odoo crea los trabajos de impresion en su cola.
2. LidaPrint, que consulta a Odoo cada pocos segundos, los toma, descarga cada PDF y lo imprime.
3. LidaPrint confirma a Odoo si se imprimio o fallo. Ver [Modo Nube](#modo-nube-odoo-en-vps).

---

## Configuracion (Configurator)

Se abre desde `LidaPrint.bat` o ejecutando `Configurator.ps1`. GUI con tema oscuro organizada en
**5 pestanas por tarea**. En pantalla queda a lo sumo una linea de ayuda por seccion: la
explicacion de cada campo esta en su **tooltip** (pasar el mouse por encima).

| Pestana | Para que | Antes estaba en |
|---------|----------|-----------------|
| **Conexion** | Como llegan los PDF: modo Local, Red local o Nube | Monitoreo, Sistema (ejemplos) |
| **Impresora** | Impresora, copias, orientacion, DPI, papel, margenes, escala | Impresion, Papel |
| **Forma continua / Ticketera** | Papel tractor y ticketeras ESC/POS con su calibracion | Forma Continua, Calibracion |
| **Avanzado** | Motor Ghostscript, conversor DPI/pixeles, auto-inicio y logs | Calidad, Sistema |
| **Drivers y formatos** | Instalar drivers y descargar formatos de factura | Drivers, Formatos |

### Pestana 1: Conexion

Arriba, el selector de **modo de operacion** (ver [Modos de operacion](#modos-de-operacion)).
Debajo se muestra **solo** el panel del modo elegido:

| Modo | Se muestra |
|------|------------|
| Local (por nombre de archivo) | Carpeta de descargas + filtro por nombre |
| Red local (Odoo envia a esta PC) | Carpeta de descargas + puerto, API Key y URL para Odoo |
| Nube (Odoo en VPS) | URL de Odoo, token, intervalo de consulta y **Probar conexion** |

| Campo | Descripcion | Default |
|-------|-------------|---------|
| Carpeta | Carpeta de descargas (boton **...** para elegirla, **Abrir** la abre en el Explorador). La usan Local y Red local | `...\Downloads` |
| Patron de nombre | Regex de validacion | `^(F\|ND\|NC)-\d{8}\.pdf$` |
| Usar patron | Filtro por regex. Solo en modo Local: en Red local y Nube se desactiva y desmarca, y al volver a Local recupera el valor que tenia | activado |
| Puerto | Puerto HTTP del modo Red local. Debajo se muestra la URL a usar **en Odoo** (con la IP de esta PC) | 8080 |
| API Key | Clave de autenticacion (boton **Mostrar/Ocultar**). **Obligatoria** en modo Red local | (vacio) |
| URL de Odoo | Direccion **base** de Odoo, ej. `https://cliente.example.com`: esquema, dominio y, si hace falta, puerto, **sin `/odoo` ni `/web`**. Si se pega con una ruta (copiada del navegador), **Probar conexion** y **Guardar** la quitan y avisan. Debe ser `https://`; `http://` solo se admite hacia la red local (`localhost`, nombres `.local`, IP privadas, link-local o CGNAT, IPv6 `::1`, `fc00::/7` o `fe80::/10`), con advertencia | (vacio) |
| Token | Token del equipo, generado en Odoo por un **administrador**: **Ajustes > API de integracion > LidaPrint > Equipos LidaPrint** (el boton se ve con cualquier destino) o **Facturacion > Configuracion > Equipos LidaPrint**; abrir el equipo y pulsar **Generar token**. Se muestra una sola vez y tiene 43 caracteres: si no, al probar o guardar se avisa (sin bloquear) por si se copio a medias. Enmascarado (boton **Mostrar/Ocultar**) | (vacio) |
| Consultar cada (s) | Intervalo inicial entre consultas (1-300). Odoo puede indicar otro con `next_poll` y ese manda | 3 |
| Probar conexion | Llama a `GET /ping` con la URL y el token escritos (sin guardar). Muestra el equipo y la compania, o el error: 401 (equipo archivado o token revocado, o token mal copiado), 404/400 (URL incorrecta o base de datos no resuelta, ver [Solucion de problemas (Nube)](#solucion-de-problemas-nube)), sin conexion | — |

### Pestana 2: Impresora

| Campo | Descripcion | Default |
|-------|-------------|---------|
| Impresora | Impresora fisica de Windows (**Refrescar** relee la lista) | Primera disponible |
| Copias | Copias por documento (1-10). Con Odoo en Red local o Nube, usar 1 | 2 |
| Orientacion | `portrait` / `landscape` | portrait |
| DPI | Resolucion de impresion: presets (203 matriciales, 300 laser, etc.) **o valor escrito a mano** (72-1200) | 300 |
| DPI del driver | Al lado del DPI se muestra el que reporta el driver de la impresora seleccionada; **Usar este DPI** lo aplica de un clic | auto |
| Tamano | A4, Letter, Legal, Tabloid, A5, Continuo, Custom | A4 |
| Tamano personalizado | Habilita ancho/alto manual; al marcarlo el tamano pasa a `Custom` automaticamente (y viceversa) | desactivado |
| Ancho / Alto (mm) | En mm (50-2000) | 210 / 297 |
| Margenes | Superior/Inferior/Izquierdo/Derecho en mm — aplicados por **Ghostscript** | 0 |
| Escala (%) | Porcentaje del tamano original (10-200) | 100 |

> **Nota sobre margenes:** cada margen **empuja** el contenido en su direccion, sin
> escalarlo: izquierdo lo mueve a la derecha, derecho a la izquierda, superior hacia
> abajo, inferior hacia arriba. Margenes opuestos se restan (izq 20 + der 5 = corrimiento
> neto de 15mm a la derecha). Si el contenido queda fuera del papel, se recorta — para
> achicarlo usa **Escala (%)**. El desplazamiento superior de forma continua empuja hacia abajo.

### Pestana 3: Forma continua / Ticketera

**Forma continua** — para impresoras matriciales con papel tractor:

| Campo | Descripcion | Default |
|-------|-------------|---------|
| Activar modo forma continua | Usa dimensiones de forma continua | desactivado |
| Largo (mm) | Alto del formulario en mm (50-5000) | 279 |
| Desplaz. sup. (mm) | Desplazamiento superior (offset) en mm | 0 |

#### Ticketera ESC/POS y calibracion

Para ticketeras **9-agujas o termicas** cuyo driver **no acepta impresion grafica GDI**
por el puerto disponible (caso tipico: EPSON TM-U220 conectada por un adaptador
**USB-a-paralelo** CH340). En esos equipos Ghostscript falla con `StartDoc` y no sale
papel. Con el modo ESC/POS activo, LidaPrint **rasteriza el PDF a una imagen** y la envia
como comandos de imagen (`ESC *`) en **bytes crudos (RAW)**, la unica via que la impresora
acepta por ese adaptador.

| Campo | Descripcion | Default |
|-------|-------------|---------|
| Imprimir por ESC/POS crudo | Activa la via RAW en vez de la impresion GDI/Ghostscript | desactivado |
| Ancho imprimible (mm) | Ancho fisico maximo del cabezal (la barra que llena el papel) | 64 |
| DPI horizontal | Densidad de puntos horizontal (`puntos / mm x 25.4`) | 158.75 |
| DPI vertical | Densidad vertical de la banda de 8 puntos (ajusta la proporcion) | 72 |
| Densidad | Modo `ESC *`: `0` simple (8 puntos), `1` doble (24 puntos) | 1 |
| Interlineado (n) | Avance de papel entre bandas via `ESC 3 n` (unidad 1/144" en TM-U220); ajustado para que las bandas queden contiguas sin franjas blancas ni solape | 16 |
| Umbral negro | Corte de luminancia (0-255) para binarizar la imagen antes de mandarla | 170 |
| Separacion extra (mm) | Avance extra de papel al final de cada ticket ESC/POS (`linePitch`). 0 = sin separacion extra | 4.23 |
| Antialiasing | Suavizado al rasterizar con Ghostscript (`-dTextAlphaBits=4`): texto mas legible | activado |

**Boton "Imprimir barras de calibracion":** imprime dos barras negras de ancho conocido
(200 y 400 puntos). Se miden en mm para deducir los valores:

- **Ancho imprimible** = ancho en mm de la barra que llena todo el papel. En la TM-U220
  medida: **400 puntos = 64mm** (maximo del cabezal).
- **DPI horizontal** = `puntos / (mm / 25.4)`. Ejemplo real: 400 puntos que miden 64mm ->
  `400 / (64/25.4)` = **158.75**. (Este valor MEDIDO manda sobre el 120dpi teorico del
  spec del modo `ESC *`.)
- **DPI vertical**: por defecto **72** para 9-agujas; subir/bajar si la altura sale
  estirada o aplastada.
- **Interlineado (`ESC 3 n`)**: la unidad de avance en la TM-U220 es **1/144 de pulgada**
  (no 1/216). Para una banda de imagen de 8/24 puntos contigua, el valor correcto es
  **n = 16**. Se verifica imprimiendo bloques solidos: con n mas alto aparecen franjas
  blancas entre bandas; con n mas bajo las bandas se montan.

> **Importante — el tamano del texto NO se arregla en LidaPrint.** Si la barra de 400
> puntos mide 64mm, LidaPrint imprime 1:1 y es fiel. Si la factura sale "chica", la causa
> esta en el PDF: **wkhtmltopdf aplica *smart-shrinking*** y auto-encoge el contenido para
> que entre en el ancho de pagina. Si el contenido del reporte es ~3x mas ancho que la
> pagina, un `font-size: 23pt` termina renderizando a ~3.4pt. La solucion es del lado del
> **reporte de Odoo**: disenarlo al ancho real del papel (paperformat 72mm, margenes <=2mm)
> y neutralizar el encogido por CSS. Ver el documento de referencia
> `REPORTE ODOO 18 CORRECTO` para el formato completo corregido.

> Con ESC/POS, el reporte de Odoo debe estar disenado al tamano del papel (no A4): el
> paperformat de Odoo, el papel de la pestana **Impresora** de LidaPrint y el papel fisico
> deben coincidir para que la salida sea 1:1 sin deformacion. El ancho del contenido no
> puede superar el **Ancho imprimible** del cabezal.

### Pestana 4: Avanzado

| Campo | Descripcion | Default |
|-------|-------------|---------|
| Ghostscript | Ruta al ejecutable (`gswin64c.exe`), con **...** y **Detectar** automatico | auto-detectado |
| Suavizado maximo | Renderiza texto y graficos como imagen con antialiasing | desactivado |
| Conversor DPI/pixeles | mm + DPI -> pixeles, y pixeles + DPI -> mm (bidireccional, en vivo) | 210mm @ 203dpi |
| Auto-iniciar con Windows | Crea/elimina la tarea programada | activado |
| Generar logs | Escribe en `logs/PrintLog_yyyy-MM.txt` | activado |
| Ver Log | Abre el log mas reciente en el Bloc de notas | — |

**Cuando usar Ghostscript:** si el PDF se ve perfecto en pantalla pero **imprime feo**
(letras deformadas, fuentes sustituidas, texto serruchado), el problema suele ser como el
driver interpreta las fuentes del PDF. Ghostscript lo evita: **rasteriza la pagina al DPI
exacto configurado** (pestana Impresora) y la envia ya renderizada como mapa de bits via el
driver de Windows (device `mswinpr2`). El driver ya no interpreta nada: solo pinta puntos.

**El conversor DPI/pixeles:** las impresoras de forma continua trabajan en pixeles a una
densidad fija (203 DPI = 8 puntos/mm es el estandar en matriciales y termicas). El conversor
resuelve la cuenta en ambos sentidos:

- `pixeles = mm / 25.4 * DPI`  (ej: 210mm a 203dpi = 1678 px)
- `mm = pixeles / DPI * 25.4`  (ej: 1678 px a 203dpi = 210mm)

Util para calcular el `Largo` de forma continua (pestana Forma continua / Ticketera) cuando
el fabricante especifica el area imprimible en pixeles.

### Pestana 5: Drivers y formatos

Dos listas lado a lado que se cargan del catalogo de LidaPrint al entrar a la pestana:
**Drivers de impresora** (boton **Instalar driver seleccionado**, ver
[Drivers de impresora](#drivers-de-impresora)) y **Formatos de factura** (boton
**Descargar...**, guarda la plantilla XML para importarla en Odoo).

### Botones inferiores

A la izquierda las pruebas, a la derecha Cancelar / Guardar:

- **Probar impresion**: envia un PDF de prueba con Ghostscript a la impresora elegida.
- **Probar monitor**: en Local deja una factura de prueba en la carpeta vigilada (el monitor
  deberia imprimirla y borrarla). En Red local y Nube solo verifica que el monitor este
  corriendo y explica como probar de punta a punta: imprimir una factura desde Odoo (en Red
  local tambien **Probar conexion** de Odoo, o `curl.exe -X POST http://localhost:PUERTO/print/file`).
- **Cancelar** cierra sin guardar; **Guardar** valida y persiste.

Al **Guardar**, el Configurator valida: impresora seleccionada, carpeta de descargas existente
(salvo en modo Nube), ruta de Ghostscript valida, patron regex correcto, API Key presente en
modo Red local (y advierte si el puerto es < 1024), y en modo Nube una URL `https://` (o
`http://` a localhost/red local, con advertencia) y un token no vacio.

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
    "mode":            "local",
    "webEnabled":      false,
    "webPort":         8080,
    "webApiKey":       "",
    "cloudUrl":        "",
    "cloudToken":      "",
    "cloudPollSeconds": 3,
    "escposEnabled":     false,
    "escposWidthMm":     64,
    "escposHdpi":        158.75,
    "escposVdpi":        72,
    "escposDensity":     1,
    "escposLineSpacing": 16,
    "escposThreshold":   170,
    "escposAntialias":   true
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
| `linePitch` | decimal | Separacion extra en mm al final de cada ticket ESC/POS (pestana Forma continua / Ticketera). La via Ghostscript no la usa |
| `gsPath` | string | Ruta a Ghostscript (`gswin64c.exe`). Si esta vacia o quedo obsoleta, **se re-resuelve sola** en runtime |
| `renderAsImage` | bool | Suavizado maximo de texto/graficos al rasterizar |
| `downloadFolder` | string | Carpeta monitoreada (modos Local y Red local; no se usa en Nube). Vacia = Descargas del usuario actual |
| `installPath` | string | Informativo. En runtime los scripts se auto-ubican con su propia ruta |
| `autoStart` | bool | Si debe existir la tarea programada |
| `enableLogging` | bool | Habilita el log |
| `usePattern` | bool | Filtra por regex (solo modo Local) |
| `invoicePattern` | string | Regex de validacion de nombres |
| `mode` | string | Modo de operacion: `local`, `api` (Red local) o `cloud` (Nube). Si falta o es invalido, se deriva de `webEnabled` |
| `webEnabled` | bool | Habilita el servidor HTTP. Se sigue escribiendo, coherente con `mode` (`true` solo si `mode = api`), para lectores viejos |
| `webPort` | int | Puerto HTTP |
| `webApiKey` | string | Clave de autenticacion. **Obligatoria** en modo `api` (sin ella el listener no arranca) |
| `cloudUrl` | string | URL base de Odoo para el modo Nube (`https://...`): solo esquema, dominio y puerto, sin `/odoo` ni `/web` (el Configurator y el monitor quitan cualquier ruta) |
| `cloudToken` | string | Token del equipo generado en Odoo. **Obligatorio** en modo Nube: sin URL o sin token el monitor no arranca. `config.json` queda con acceso restringido al usuario |
| `cloudPollSeconds` | int | Intervalo inicial de consulta en segundos (1-300). Odoo lo ajusta con `next_poll` |
| `escposEnabled` | bool | Imprime por la via RAW ESC/POS (rasteriza el PDF y manda `ESC *`) en vez de GDI/Ghostscript. Para ticketeras cuyo driver no acepta grafica GDI por el puerto disponible |
| `escposWidthMm` | decimal | Ancho imprimible del cabezal en mm (barra de calibracion que llena el papel) |
| `escposHdpi` | decimal | DPI horizontal medido: `puntos / (mm / 25.4)` |
| `escposVdpi` | decimal | DPI vertical de la banda de 8/24 puntos |
| `escposDensity` | int | Modo `ESC *`: `0` simple (8 puntos), `1` doble (24 puntos) |
| `escposLineSpacing` | int | Avance `ESC 3 n` entre bandas. Unidad 1/144" en TM-U220 -> `16` deja bandas contiguas |
| `escposThreshold` | int | Umbral de binarizacion 0-255 (mas bajo = mas negro) |
| `escposAntialias` | bool | Suavizado del texto al rasterizar (`-dTextAlphaBits=4`) |

Los valores `escpos*` se calibran por modelo. Cuando instalas el driver desde el
Configurator, se aplican solos desde el bloque `calibration` de `drivers.json` (ver
[Drivers de impresora](#drivers-de-impresora)).

---

## Modos de operacion

El modo se guarda en `mode` (`"local"`, `"api"` o `"cloud"`) y se elige en la pestana **Conexion** del Configurator.

### Modo Local (`mode = "local"`)

Autonomo. Depende de `usePattern`:

- **`usePattern = true`**: solo imprime archivos cuyo nombre coincide con `invoicePattern`.
- **`usePattern = false`**: imprime cualquier PDF que aparezca.

### Modo Red local / API (`mode = "api"`)

LidaPrint deja de imprimir automaticamente y espera instrucciones de Odoo (el servidor de Odoo
debe poder llegar a esta PC por la red):

- Solo imprime archivos que esten en la `printQueue`.
- Odoo agrega archivos via `POST /print` y los excluye via `POST /skip`.
- El patron de nombres **no se usa** (la UI desactiva el checkbox automaticamente).

### Modo Nube (`mode = "cloud"`)

LidaPrint consulta a Odoo por HTTPS (conexion saliente) y descarga los trabajos pendientes de
su equipo. No usa la carpeta de descargas, ni el patron, ni el listener HTTP. Sirve con Odoo
en un VPS. Detalle en [Modo Nube](#modo-nube-odoo-en-vps).

### Compatibilidad `mode` / `webEnabled`

Las configuraciones anteriores no tienen `mode`: se deriva de `webEnabled` (`true` -> `api`,
`false` -> `local`). Si `mode` trae un valor desconocido tambien se deriva asi. Al guardar, el
Configurator escribe ambas claves, con `webEnabled = (mode == "api")`, para que versiones
viejas de LidaPrint sigan leyendo el archivo correctamente.

---

## Modo Nube (Odoo en VPS)

### Por que existe

El modo Red local necesita que el **servidor** de Odoo llegue a la PC de Windows por la
red. Con Odoo en un VPS eso no pasa: la PC esta detras del router (NAT) y el VPS no puede
abrirle conexiones. En modo Nube se invierte el sentido, como en una IoT Box: **LidaPrint
sale a Odoo por HTTPS** y le pregunta si hay trabajos; Odoo guarda una cola de trabajos de
impresion por equipo. No hay que abrir puertos, ni reglas de firewall, ni `urlacl`.

```
Navegador (usuario)      Odoo (VPS)                         LidaPrint (PC de la caja)
     |                       |                                      |
     |-- clic Forma Libre -->| crea 2 trabajos (pending):           |
     |<-- "Enviado a Caja 1" |   original + copia SIN DERECHO...    |
     |                       |<------------- POST /poll ------------|  cada ~3 s
     |                       |  reclama hasta 10 (pending->printing)|
     |                       |--- 200 {"jobs":[{"id":51,...},    -->|
     |                       |    {"id":52,...}],"next_poll":3}     |
     |                       |<------------- GET /job/51/pdf -------|
     |                       |--------------- PDF ----------------->|  imprime, borra
     |                       |<------ POST /job/51/ack {"done"} ----|  (printing->done)
     |                       |          (igual con el 52)           |
```

### Quien consulta a Odoo (y quien no)

- **Solo el agente LidaPrint consulta**, y solo cuando su `config.json` tiene
  `mode = "cloud"` con `cloudUrl` y `cloudToken` definidos.
- Las PC **sin LidaPrint**, las PC con LidaPrint en modo **Local** o **Red local**, y
  **todos los navegadores / clientes web de Odoo** generan **cero** trafico de consultas.
- El modulo de Odoo **no agrega consultas del lado del navegador** (ni temporizadores JS,
  ni bus/longpolling): el boton **Forma Libre** solo crea los trabajos en el servidor.
- La carga del servidor escala con el **numero de equipos Nube registrados y activos**, no
  con el numero de usuarios ni de PC.

### Puesta en marcha

Guia paso a paso para tecnicos (VPS, cada caja y errores comunes): [`docs/instalacion-modo-nube.md`](docs/instalacion-modo-nube.md).

1. En Odoo (modulo `l10n_ve_lidoo_integration_api` 18.0.2.4.0 o posterior, ver
   [`docs/odoo-modo-nube.md`](docs/odoo-modo-nube.md)), un **administrador** abre
   **Ajustes > API de integracion > LidaPrint > Equipos LidaPrint** (o **Facturacion >
   Configuracion > Equipos LidaPrint**), crea el equipo (ej. "Caja 1") y pulsa **Generar
   token**. El token se muestra **una sola vez**. El boton se ve con cualquier destino de
   impresion: conviene crear los equipos y copiar los tokens **antes** de pasar Odoo a Nube.
2. En el Configurator, pestana **Conexion**: elegir **Nube (Odoo en VPS)**, pegar la URL base
   de Odoo (`https://...`, sin `/odoo` ni `/web`) y el token, pulsar **Probar conexion** (debe
   mostrar el equipo y la compania) y **Guardar**. El monitor se reinicia y empieza a consultar.
3. En la pestana **Impresora** dejar **Copias = 1**: Odoo ya envia original y copia como
   trabajos separados.
4. En Odoo, **Ajustes > API de integracion > LidaPrint**: **Destino de impresion = Nube** y el
   equipo por defecto de la compania (cada usuario puede elegir otro en sus preferencias,
   **Imprimir en**).

### Contrato HTTP

Base: `{cloudUrl}/lidaprint/v1`. Toda peticion lleva `Authorization: Bearer <cloudToken>` y
`User-Agent: LidaPrint/<version>`. Los cuerpos van en JSON (`application/json; charset=utf-8`).

| Metodo | Ruta | Cuerpo | Respuesta |
|--------|------|--------|-----------|
| GET | `/ping` | — | 200 `{"ok":true,"device":"Caja 1","company":"ACME","next_poll":3}`; **401** si el token es invalido o fue revocado. **No reclama trabajos** (lo usa **Probar conexion**) |
| POST | `/poll` | `{"hostname":"<COMPUTERNAME>","version":"<ver>","printer":"<config.printer>"}` | **Siempre 200** `{"jobs":[{"id":51,"filename":"F-00001234.pdf","size":12345}],"next_poll":3}` (`jobs` puede venir vacio). Del lado del servidor reclama atomicamente hasta 10 trabajos pendientes del equipo (pending -> printing) |
| GET | `/job/<id>/pdf` | — | 200 `application/pdf` binario; 404 si el trabajo no es de este equipo o ya no esta en `printing` (pendiente, impreso o con error). LidaPrint toma el 404 como definitivo y confirma `error` |
| POST | `/job/<id>/ack` | `{"status":"done"}` o `{"status":"error","message":"..."}` | 200 `{"ok":true}`. Idempotente: un ack tardio o repetido tambien es 200. 404 solo si el trabajo no es del equipo; 400 si el `status` no es valido |

Errores: el **401** responde `{"ok":false,"error":"unauthorized"}` en las cuatro rutas (token
invalido o revocado, o equipo archivado), sin efectos en Odoo; el 404 y el 400 del modulo,
`{"status":"error","message":"..."}`. Si el servidor tiene varias bases y no puede elegir una
sin sesion (sin `dbfilter`), Odoo responde un **HTML 404** a cualquier `/lidaprint/v1/*`.

### Comportamiento del agente

- En modo Nube el monitor **no** inicia el listener HTTP ni vigila la carpeta de descargas.
- Al arrancar normaliza `cloudUrl` con la misma funcion que el Configurator (`Get-CloudUrlCheck`):
  solo esquema, dominio y puerto; si trae una ruta (`/odoo`, `/web`...) la quita y deja un WARN
  en el log. Con `http://` hacia un host publico el ciclo Nube **no arranca** (ERROR en el log):
  el token viajaria en claro por internet. `http://` hacia la red local funciona, con un WARN.
- Habilita **TLS 1.2** si el sistema no negocia por su cuenta (con `SystemDefault` no toca nada,
  asi sigue disponible TLS 1.3), mantiene **keep-alive** y desactiva `Expect: 100-continue`. Timeouts:
  15 s para ping/poll/ack, 60 s para descargar el PDF.
- Por cada trabajo: descarga el PDF a `temp\job-<id>-<nombre>` (nombre saneado con
  `[IO.Path]::GetFileName`), rechaza > 50 MB o sin los magic bytes `%PDF-` (mismas reglas que
  `/print/file`), lo imprime por la **misma via** que los otros modos (Ghostscript o
  ESC/POS), lo borra y confirma `done`. Si la impresion falla, confirma `error` con el mensaje.
- **Nunca imprime dos veces el mismo id** en una sesion. Por eso una reimpresion en Odoo crea
  siempre un trabajo nuevo.
- Si un ack falla por red queda pendiente (guardado en `temp\cloud-pending-acks.json`, asi
  sobrevive a un reinicio del monitor) y se reintenta antes del poll como mucho cada 30 s, **sin bloquearlo
  nunca**; se descarta con un WARN a los 60 minutos. Si la descarga falla por red
  se reintenta hasta 5 veces (es seguro: aun no se imprimio); despues confirma `error`. Cada
  reintento de descarga deja un WARN en el log y no cuenta como perdida de conexion.
- **Caducidad:** un trabajo que espero en la cola local **10 minutos** o mas sin poder
  imprimirse (Odoo caido o sin red) **ya no se imprime**: se confirma `error` ("Trabajo
  caducado..."). Mientras tanto Odoo pudo marcarlo como error y el operador reimprimirlo;
  imprimirlo tarde duplicaria la factura fiscal. Se comprueba antes de descargar el PDF y otra
  vez justo antes de imprimirlo. La espera se mide con un reloj monotono (`Stopwatch`) y con la
  hora de Windows, y manda la mayor: atrasar la hora no alarga la ventana, y una suspension de
  la PC tampoco. La cola local vive solo en memoria: si el monitor se reinicia, esos trabajos
  quedan en "Imprimiendo" en Odoo, el poll ya no los devuelve y el cron de Odoo los pasa a error.
- **Lotes largos:** un poll trae hasta 10 trabajos y el lote se atiende entero antes del
  siguiente poll. Como Odoo da por desconectado un equipo sin contacto en 60 s, entre dos
  trabajos del lote, si pasaron mas de 30 s desde el ultimo contacto, LidaPrint hace un
  `GET /ping` (no reclama nada y actualiza la ultima conexion). Si falla, sigue con el lote.
- Intervalo: el `next_poll` que manda Odoo, acotado a [1, 300] s; si no viene, `cloudPollSeconds`.
- Sin red, timeout o error del servidor: backoff exponencial 2, 4, 8... hasta 60 s.
- **404 o 400 en el poll** (URL incorrecta o base de datos no resuelta, ver
  [Solucion de problemas (Nube)](#solucion-de-problemas-nube)): un ERROR en el log al cambiar de
  estado, una sola vez, y el mismo backoff hasta 60 s.
- **401** (equipo archivado o token revocado en Odoo, o token mal copiado): espera **60 s**; tras
  **3 rechazos seguidos** alarga la espera a **300 s**, asi un equipo dado de baja no martilla
  al servidor (como mucho ~288 peticiones/dia). El contador vuelve a cero con la primera
  respuesta correcta.
- Log: no registra cada consulta. Registra los trabajos (recibido, impreso, fallido) y solo
  los **cambios** de estado de la conexion:

```
[2026-09-14 08:00:03] [OK] Conectado a Odoo (https://cliente.example.com/lidaprint/v1)
[2026-09-14 10:15:30] [INFO] Nube: trabajo #51 recibido (F-00001234.pdf, 48211 bytes)
[2026-09-14 10:15:33] [OK] Nube #51: Impreso (Ghostscript 300dpi, 210x297mm): job-51-F-00001234.pdf -> Canon LBP6030
[2026-09-14 12:40:10] [WARN] Conexion con Odoo perdida: The operation has timed out
[2026-09-14 12:41:02] [OK] Conexion con Odoo restablecida
```

- Con `mode = "cloud"` pero sin `cloudUrl` o sin `cloudToken`, o con `http://` hacia un host
  publico, el monitor registra un ERROR y **no arranca** (el Configurator no deja guardar esos
  casos).

### Costo del polling

Una consulta sin trabajos, con keep-alive, ocupa unos **0,5-1 KB** (cabeceras con el token +
JSON corto). Con ~0,8 KB por consulta y **por PC en modo Nube**:

| Intervalo | Consultas/dia | Trafico/dia |
|-----------|---------------|-------------|
| 1 s | 86 400 | ~69 MB |
| 3 s (default) | 28 800 | **~23 MB** |
| 5 s | 17 280 | ~14 MB |

Los PDF se suman aparte (decenas de KB por factura). Odoo puede alargar el intervalo fuera
de horario con `next_poll` (ej. 30 s), lo que baja el total a la mitad o menos. Estimaciones
de carga del servidor en [`docs/odoo-modo-nube.md`](docs/odoo-modo-nube.md) (seccion Rendimiento).

### Solucion de problemas (Nube)

| Sintoma | Causa probable | Solucion |
|---------|----------------|----------|
| **Probar conexion** o el log dicen **401** | Equipo archivado o token revocado en Odoo, o token mal copiado (el Configurator avisa si no tiene 43 caracteres) | Generar un token nuevo en Odoo, pegarlo en la pestana Conexion y Guardar. Mientras tanto el monitor reintenta cada 60 s y luego cada 300 s |
| "Sin conexion con Odoo" / **timeout** | Sin internet, URL mal escrita, DNS, o un proxy/antivirus que bloquea la salida | Abrir la URL de Odoo en el navegador de esa PC. `curl.exe -m 15 https://cliente.example.com/lidaprint/v1/ping -H "Authorization: Bearer TOKEN"` debe devolver `{"ok":true,...}` |
| Error de **TLS / SSL** ("canal seguro", "trust relationship") | Certificado vencido o no valido en el servidor, fecha/hora del PC incorrecta, o inspeccion HTTPS del antivirus | LidaPrint ya habilita TLS 1.2. Corregir la hora de Windows, renovar el certificado (Let's Encrypt) o excluir el dominio de la inspeccion HTTPS |
| **404 o 400** en Probar conexion, o en el log "URL incorrecta o base de datos no resuelta" | La peticion no llega al modulo: (1) la URL no es la del dominio de Odoo o traia una ruta (`/odoo`, `/web`; LidaPrint ya la quita); (2) el servidor tiene **varias bases** y sin `dbfilter` no sabe cual usar: Odoo responde un HTML 404 a `/lidaprint/v1/*`; (3) el modulo de Odoo no esta actualizado a 18.0.2.4.0 | URL base, sin `/odoo` ni `/web`. En el servidor, una sola base por instancia o `dbfilter` por dominio (`dbfilter = ^%d$` o `^%h$`; ver el README del modulo). Prueba: `curl.exe -H "Authorization: Bearer x" https://cliente.example.com/lidaprint/v1/ping` debe responder **401 JSON**; un HTML 404 es que la base no se resolvio |
| **404/400** ("URL incorrecta o base de datos no resuelta") con la URL correcta | El servidor de Odoo tiene **varias bases** y el `dbfilter` no elige una para `/lidaprint/v1/*` | `dbfilter` por dominio (`dbfilter = ^%d$`), o en nginx `location /lidaprint/ { proxy_set_header X-Odoo-dbfilter "^<db>$"; ... }` (requiere el modulo server-wide `dbfilter_from_header` y `proxy_mode = True`). Detalle en [docs/odoo-modo-nube.md](docs/odoo-modo-nube.md), seccion 6.3 |
| "Odoo respondio algo que no es JSON" | La URL apunta a otro sitio o a una pagina de login/redireccion | Usar la URL base de Odoo con `https://` (sin `/odoo` ni `/web`) |
| El monitor sale al arrancar: "Modo Nube sin URL de Odoo o sin token" | `config.json` editado a mano | Completar URL y token en el Configurator y Guardar |
| El monitor sale al arrancar: "La URL debe empezar con https://" | `cloudUrl` con `http://` hacia un host publico (`config.json` viejo o editado a mano): el token viajaria en claro | Usar `https://`. `http://` solo se admite hacia la red local |
| En Odoo un trabajo queda en **Imprimiendo** | La PC se apago o LidaPrint se reinicio a mitad de un lote, o no pudo confirmar el resultado | El cron de Odoo lo pasa a error a los **15 min** sin confirmacion (configurable, nunca menos de 12) y **nunca** lo devuelve a la cola: pudo haberse impreso. Revisar el papel y, si no salio, reimprimir desde la factura con el boton **Forma Libre**, que sale como **COPIA**. El boton **Reenviar el original** del trabajo solo existe cuando LidaPrint informo un error (no imprimio), y es para usuarios de facturacion, con confirmacion |

---

## API HTTP

Se activa con el modo Red local (`mode = "api"`, que escribe `webEnabled = true`). El listener registra el prefijo **raiz** (`http://+:PUERTO/`) y enruta todas las rutas en codigo.

### Autenticacion

La **API Key es obligatoria** en modo Red local (`mode = "api"`). Si la API esta activada pero
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
El Configurator muestra la URL con la IP de la PC (`En Odoo: http://IP:PUERTO`);
`localhost` es valida solo dentro del propio Windows. Si Odoo corre en un VPS
(fuera de la red de la PC), usar el [Modo Nube](#modo-nube-odoo-en-vps).

### Integracion con Odoo (modulo l10n_ve_lidoo_integration_api)

El modulo de la localizacion venezolana trae la integracion lista en
**Ajustes > API de integracion > LidaPrint**. El selector **Destino de impresion** decide
adonde va la Forma Libre (original y copia **SIN DERECHO A CREDITO FISCAL**) y los reportes
marcados:

| Destino | Que hace |
|---------|----------|
| Navegador (descargar PDF) | Descarga el PDF como siempre, sin LidaPrint |
| Red local (API) | Odoo envia los PDF a esta PC por `POST /print/file` (esta seccion) |
| Nube | Odoo deja los PDF en la cola del equipo y LidaPrint los recoge por HTTPS (ver [Modo Nube](#modo-nube-odoo-en-vps)) |

El interruptor anterior **Imprimir Forma Libre con LidaPrint** ya no esta en la pantalla: en
una instalacion que lo tenia encendido el destino pasa a **Red local**, y con el interruptor
apagado a **Navegador**, sin migracion.

Con **Red local** se completan:

| Campo | Valor |
|-------|-------|
| URL | IP del Windows donde corre LidaPrint (ver advertencia de `localhost` arriba). Ej: `http://192.168.122.32:8081` |
| API Key | La misma `webApiKey` del `config.json` (pestana Conexion del Configurator, modo Red local) |
| Probar conexion | Hace `GET /print/status` y notifica si LidaPrint responde |

Reglas de comportamiento del modulo:

- Solo aplica a facturas, notas de credito y notas de debito de cliente
  publicadas con numero de control.
- En Red local, sin conexion con LidaPrint la impresion se **bloquea** con
  un error explicito (no imprime a medias en silencio). En Nube no se bloquea:
  los documentos quedan en cola y se imprimen cuando el equipo se conecta.
- En el `config.json` de LidaPrint dejar **`copies: 1`**: Odoo ya envia
  original y copia como documentos separados; con `copies: 2` saldria 2x2.
- Los PDF viajan por `POST /print/file` (subida directa), asi que **no** hace
  falta carpeta compartida ni que el navegador descargue nada.

### Acceso desde otra maquina (Odoo en Linux, LidaPrint en VM/PC Windows)

Checklist completo para que la API responda desde fuera del Windows. Los tres
pasos de PowerShell van **como Administrador** y usan el puerto configurado en
la pestana Conexion (modo Red local; ejemplos con 8081):

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
| `-rN` | DPI de rasterizado (pestana Impresora: 203, 300, etc.) |
| `-dNumCopies=N` | Copias |
| `-c "<< /BeginPage ... >>"` | Margenes (desplazamiento puro por lado), topOffset y escala del usuario |
| `-dTextAlphaBits=4 -dGraphicsAlphaBits=4` | Suavizado maximo (checkbox en la pestana Avanzado) |

> **Nota fisica:** el tamano configurado define el area que ocupa el CONTENIDO. La hoja
> fisica es la que este cargada en la impresora: un contenido de 50x100mm sobre una hoja
> media carta imprime en una region de 50x100mm de esa hoja (alineable con los margenes).

Todas las funcionalidades de configuracion (margenes, orientacion, paper size, escala,
DPI, forma continua, desplazamiento superior) estan soportadas por este motor. La unica
excepcion es `linePitch`, que solo usa la via ESC/POS (separacion extra entre tickets).

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
pestana **Drivers y formatos** del Configurator — no hace falta buscarlos en la web del fabricante.

### Drivers incluidos

| Modelo | Tipo | Formato |
|--------|------|---------|
| EPSON TM-U220PD | Matricial / ticket | APD (zip) |
| EPSON M188D | Termica / ticket | APD (zip) |
| Canon LBP6030 / 6030B / 6030w | Laser | Instalador exe |

### Instalar un driver desde el Configurator

1. Abrir el Configurator (`LidaPrint.exe`).
2. Ir a la pestana **Drivers y formatos**.
3. Seleccionar el modelo de la lista.
4. Hacer clic en **Instalar** y seguir las instrucciones del instalador.

Al terminar la instalacion, LidaPrint deja la impresora **utilizable de inmediato**:
segun el bloque `postInstall` del driver (ver abajo) reasigna el puerto, apaga el
bidireccional y limpia el estado "sin conexion"; y segun el bloque `calibration`
escribe en `config.json` el **DPI, ancho imprimible e interlineado ESC/POS medidos
para ese modelo** — sin calibrar a mano en la pestana Forma continua / Ticketera. Instalar el driver en una PC
nueva deja todo listo para imprimir 1:1.

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

### Calibracion automatica al instalar (`calibration`)

Cada modelo de ticketera tiene un DPI, ancho imprimible e interlineado propios que hay
que medir una sola vez sobre el hardware (ver **Ticketera ESC/POS y calibracion** en la seccion del Configurator). Para
que no haya que repetir esa medicion en cada PC, esos valores se guardan en el bloque
opcional `calibration` del driver en `drivers.json`. Al instalar el driver, el
Configurator los escribe en `config.json` y los refleja en la pestana Forma continua / Ticketera.

| Clave | Descripcion | TM-U220 |
|-------|-------------|---------|
| `escposEnabled` | Activa la via RAW ESC/POS para este modelo | `true` |
| `escposWidthMm` | Ancho imprimible del cabezal en mm | `64` |
| `escposHdpi` | DPI horizontal medido (`puntos / mm x 25.4`) | `158.75` |
| `escposVdpi` | DPI vertical de la banda | `72` |
| `escposDensity` | Modo `ESC *`: `0` simple, `1` doble | `1` |
| `escposLineSpacing` | Avance `ESC 3 n` entre bandas (unidad 1/144") | `16` |
| `escposThreshold` | Umbral de binarizacion 0-255 | `170` |
| `escposAntialias` | Suavizado al rasterizar | `true` |

Solo se tocan las claves presentes en el bloque; el resto de `config.json` queda intacto.
Es idempotente (reinstalar reaplica los mismos valores) y no bloquea: si algo falla se
registra en el log y la instalacion continua. **Resultado: en toda PC nueva, instalar el
driver deja la impresion ESC/POS calibrada de una vez, sin ajustes manuales.**

### Agregar un driver nuevo al repositorio

1. Colocar el archivo del driver (zip, exe, etc.) en `drivers/<id>/`.
2. Agregar la entrada correspondiente en `drivers/drivers.json` con los campos `id`,
   `name`, `version`, `file`, y `sha256` (dejar `sha256` en blanco por ahora). Si la
   impresora necesita reparacion post-instalacion, agregar el bloque `postInstall`
   descrito arriba. Si es una ticketera ESC/POS ya calibrada, agregar el bloque
   `calibration` con sus valores medidos para que se apliquen solos al instalar.
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
    +-- [Runspace HTTP]  Start-WebListener  (solo modo api + API Key)
    |       GET  /             → dashboard HTML
    |       GET  /print/status → estado JSON
    |       POST /print        → printQueue.Add
    |       POST /skip         → skipList.Add
    |       POST /clear        → vacia ambas colas
    |       POST /print/file   → guarda PDF (max 50MB, nombre saneado) + encola
    |
    +-- [Modo Nube]  Invoke-CloudLoop  (solo mode=cloud + URL + token; sin listener ni carpeta)
    |       POST /poll          → trabajos reclamados + next_poll
    |       en cola local > 10 min → caducado: ack error, NO se imprime
    |       GET  /job/<id>/pdf  → temp\job-<id>-<nombre>  (max 50MB, magic %PDF-)
    |       Invoke-Print        → Ghostscript / ESC/POS  →  borra el temporal
    |       POST /job/<id>/ack  → done / error  (acks fallidos: se reintentan antes del poll)
    |       espera next_poll [1-300]s | red caida: backoff hasta 60s | 401: 60s, 300s tras 3
    |
    +-- [Loop principal]  Polling cada 1s  (modos local y api)
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
| `Get-LidaPrintMode` | Modo efectivo (`local`/`api`/`cloud`); si falta `mode` lo deriva de `webEnabled`. Copia identica en `Configurator.ps1` (en el exe el monitor y la GUI corren en ramas distintas) |
| `Invoke-Print` | Elige la via de impresion: ESC/POS crudo o Ghostscript |
| `Invoke-CloudLoop` | Ciclo del modo Nube: acks pendientes, poll, trabajos, espera/backoff y log de cambios de estado |
| `Invoke-CloudBatch` / `Invoke-CloudKeepAlive` | Atiende en orden los trabajos de un poll; entre dos trabajos, `GET /ping` si pasaron mas de 30 s sin contacto con Odoo |
| `Invoke-CloudJob` | Descarga, valida, imprime (via `Invoke-Print`) y confirma un trabajo; nunca reimprime un id |
| `Complete-ExpiredCloudJob` | Caducidad local (10 min, reloj monotono y de pared) antes de descargar y antes de imprimir |
| `Get-CloudUrlCheck` / `Test-CloudLocalHost` | Normalizan la URL de Odoo y deciden si se admite `http://` (solo red local). Copia identica en `Configurator.ps1`, verificada por `tests/Cloud.Tests.ps1` |
| `Invoke-CloudRequest` | Peticion HTTPS a Odoo con `Authorization: Bearer` y `User-Agent`; adjunta el codigo HTTP al error |

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
| **Imprime feo** (el PDF se ve bien en pantalla) | El driver interpreta mal las fuentes del PDF | Pestana **Impresora** -> DPI de la impresora (203 en matriciales). Si persiste, pestana **Avanzado** -> "Suavizado maximo" |
| Ghostscript no instalado o movido | winget/descarga fallo, UAC cancelado o ejecutable eliminado | Se auto-resuelve en runtime; si no, instalar desde ghostscript.com y usar **Detectar** en la pestana Avanzado |
| El PDF no se elimina | Archivo bloqueado por otro proceso | LidaPrint reintenta 5 veces; si falla, se reintenta al reiniciar |
| No detecta facturas (modo local) | Patron incorrecto u otro modo elegido | Revisar el regex, o elegir **Local** en la pestana Conexion |
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
| Modo Nube: Odoo no imprime, 401, 404, timeouts o errores TLS | Equipo archivado o token revocado, URL con ruta o base de datos no resuelta, sin salida a internet, certificado | Ver [Solucion de problemas (Nube)](#solucion-de-problemas-nube) |

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
