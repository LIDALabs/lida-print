# LidaPrint

Sistema de impresion automatica de facturas Odoo para Windows. Vigila una carpeta, imprime cada PDF con SumatraPDF y elimina el archivo. Puede operar de forma autonoma (por patron de nombre) o controlado por Odoo via HTTP.

Este es el **unico documento del proyecto**: cubre **uso**, **configuracion** y **funcionamiento interno**.

## Estructura del proyecto

```
lida-print/
├── DOCUMENTACION.md         ← Este archivo
├── Instalador.bat           ← Doble clic para instalar (se auto-eleva a admin)
├── Install.ps1              ← Logica de instalacion (lo corre Instalador.bat)
├── LidaPrint.ps1            ← Monitor + servidor HTTP
├── Configurator.ps1         ← GUI de configuracion
├── LidaPrint.bat            ← Lanzador del Configurator
├── LidaPrint.vbs            ← Lanzador silencioso
├── config.json              ← Configuracion persistente
├── logo.png                 ← Icono de la GUI
└── logs/                    ← Registro de impresiones (se crea al ejecutar)
```

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
10. [Opciones de SumatraPDF](#opciones-de-sumatrapdf)
11. [Logs](#logs)
12. [Como funciona internamente](#como-funciona-internamente)
13. [Solucion de problemas](#solucion-de-problemas)
14. [Desinstalar](#desinstalar)

---

## Que hace

Una vez instalado, LidaPrint corre en segundo plano (Task Scheduler) y:

1. Monitorea la carpeta de Descargas cada 1 segundo.
2. Detecta PDFs nuevos (por patron de nombre o por cola de impresion de la API).
3. Los imprime con SumatraPDF usando la configuracion guardada.
4. Elimina el archivo tras imprimirlo.

Todo sin intervencion del usuario.

---

## Requisitos

- Windows 10 / 11
- PowerShell 5.1 o superior
- SumatraPDF (el instalador lo instala automaticamente)
- Impresora configurada en Windows

---

## Instalacion

### Opcion 1: Instalacion completa (recomendado)

1. Copiar la carpeta **`lida-print`** a `C:\` (o cualquier ruta).
2. **Doble clic en `Instalador.bat`.** Se eleva a Administrador solo (acepta el aviso de UAC) y ejecuta todo el proceso.
3. Seguir las instrucciones en pantalla. Al terminar, el Configurator se abre solo.

`Instalador.bat` es un lanzador que pide permisos de Administrador y corre `Install.ps1`.
Si preferis hacerlo a mano, abri PowerShell **como Administrador** y ejecuta:
```powershell
powershell -ExecutionPolicy Bypass -File "C:\lida-print\Install.ps1"
```

`Install.ps1` automaticamente:
- Verifica/instala SumatraPDF (via `winget` o descarga directa).
- **Actualiza** `config.json` con las rutas detectadas (sumatraPath, downloadFolder, installPath).
- Crea la tarea programada **LidaPrint** (triggers: al iniciar sesion + al iniciar Windows), con `RunLevel Highest`.
- Agrega la ruta al `PATH` del usuario (opcional para acceso directo desde cmd/PowerShell).

### Opcion 2: Solo abrir el Configurator

1. Doble clic en `LidaPrint.bat` (o `LidaPrint.vbs` para arranque sin ventana de consola).
2. Configurar y hacer clic en **Guardar**. La tarea programada se crea al guardar si "Auto-iniciar" esta activo.

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

Se abre desde `LidaPrint.bat` o ejecutando `Configurator.ps1`. GUI con tema oscuro, 5 pestanas.

### Pestana 1: Impresion

| Campo | Descripcion | Default |
|-------|-------------|---------|
| Impresora | Impresora fisica de Windows | Primera disponible |
| Copias | Copias por documento (1-10) | 2 |
| Orientacion | `portrait` / `landscape` | portrait |
| Escala (%) | Porcentaje del tamano original (10-200) | 100 |
| DPI | Resolucion de impresion | 300 |

### Pestana 2: Papel

| Campo | Descripcion | Default |
|-------|-------------|---------|
| Paper Size | A4, Letter, Legal, Tabloid, A5, Continuo, Custom | A4 |
| Tamano personalizado | Habilita ancho/alto manual | desactivado |
| Ancho / Alto | En mm (50-2000) | 210 / 297 |
| Margenes | Superior/Inferior/Izq/Der en mm — **referencia visual** (ver nota) | 0 |

> **Nota sobre margenes:** SumatraPDF no aplica margenes por linea de comandos. Los campos quedan como referencia; los margenes reales se controlan desde la configuracion de la impresora en Windows.

### Pestana 3: Forma Continua

Para impresoras matriciales con papel tractor.

| Campo | Descripcion | Default |
|-------|-------------|---------|
| Activar modo | Usa dimensiones de forma continua | desactivado |
| Largo del formulario | Alto en mm (50-5000) | 279 |
| Desplazamiento superior | Offset en mm | 0 |
| Interlineado | mm entre lineas (4.23 = 6 LPI) | 4.23 |

### Pestana 4: Monitoreo

| Campo | Descripcion | Default |
|-------|-------------|---------|
| Descargas | Carpeta a vigilar (boton **Abrir** la abre en el Explorador) | `...\Downloads` |
| Patron factura | Regex de validacion | `^(F\|ND\|NC)-\d{8}\.pdf$` |
| Usar patron | Filtro por regex (se **desactiva** al activar la API) | activado |
| SumatraPDF | Ruta al ejecutable | auto-detectado |
| Activar API web | Modo controlado por Odoo | desactivado |
| Puerto | Puerto HTTP (muestra la URL al activar) | 8080 |
| API Key | Clave de autenticacion (boton **Mostrar/Ocultar**). Obligatoria si la API esta activa | (vacio) |

### Pestana 5: Sistema

| Campo | Descripcion | Default |
|-------|-------------|---------|
| Auto-iniciar con Windows | Crea/elimina la tarea programada | activado |
| Generar logs | Escribe en `logs/PrintLog_yyyy-MM.txt` | activado |
| Ver Log | Abre el log mas reciente en el Bloc de notas | — |

Botones inferiores: **Probar Impresion** (envia un PDF de prueba), **Guardar** (valida y persiste), **Cancelar**.

Al **Guardar**, el Configurator valida: impresora seleccionada, carpeta de descargas existente, ruta de SumatraPDF valida, patron regex correcto y advierte si el puerto es < 1024.

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
    "sumatraPath":     "C:\\Users\\...\\SumatraPDF.exe",
    "downloadFolder":  "C:\\Users\\...\\Downloads",
    "installPath":     "C:\\AutoPrintFacturas",
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
| `marginTop/Bottom/Left/Right` | int | Referencia visual (no aplicados por CLI) |
| `continuousForm` | bool | Modo papel continuo |
| `formLength` | int | Largo del formulario en mm |
| `topOffset` | int | Desplazamiento superior en mm |
| `linePitch` | decimal | Interlineado en mm |
| `sumatraPath` | string | Ruta al ejecutable de SumatraPDF |
| `downloadFolder` | string | Carpeta monitoreada |
| `installPath` | string | Ruta de instalacion de los scripts |
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

### Firewall (acceso desde otra maquina)

```powershell
New-NetFirewallRule -DisplayName "LidaPrint HTTP" -Direction Inbound -LocalPort 8080 -Protocol TCP -Action Allow
```

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

## Opciones de SumatraPDF

Comando generado por `Invoke-Print`:
```
SumatraPDF.exe -silent -print-to "Impresora" -print-settings "2x,portrait,paper=A4" "archivo.pdf"
```

| Opcion | Descripcion |
|--------|-------------|
| `-silent` | Sin ventanas ni dialogs |
| `-print-to "name"` | Impresora destino |
| `Nx` | N copias |
| `portrait` / `landscape` | Orientacion |
| `paper=A4` | Tamano por nombre |
| `paper=595x842` | Tamano personalizado en puntos (1 mm = 2.835 pt) |
| `scale=N` | Escala en % |

**Codigos de salida:**

| Codigo | Significado |
|--------|-------------|
| 0 | Exito |
| 2 | No se pudo abrir el archivo |
| 3 | El documento no permite impresion |
| 4 | Impresora no encontrada |
| 5 | Error del driver |
| 6 | Impresion deshabilitada |

---

## Logs

Con `enableLogging = true`, LidaPrint escribe en `logs/PrintLog_yyyy-MM.txt` (rotacion mensual, evita crecimiento indefinido).

```
[2026-07-22 10:15:30] [OK] Impreso: F-12345678.pdf -> Canon LBP6030 [2x,portrait,paper=A4]
[2026-07-22 10:15:31] [OK] Eliminado: F-12345678.pdf
[2026-07-22 10:15:45] [WARN] Archivo bloqueado: NC-00005678.pdf
```

Niveles: `INFO`, `WARN`, `ERROR`, `OK`.

---

## Como funciona internamente

### Componentes

| Archivo | Rol |
|---------|-----|
| `LidaPrint.ps1` | Monitor principal: loop de polling + servidor HTTP |
| `Configurator.ps1` | GUI de configuracion (Windows Forms, 5 pestanas) |
| `Install.ps1` | Instalador: SumatraPDF, copia de scripts, tarea programada |
| `LidaPrint.bat` | Lanza el Configurator con `-ExecutionPolicy Bypass` |
| `LidaPrint.vbs` | Ejecuta el `.bat` sin ventana de consola |
| `config.json` | Configuracion persistente |
| `logo.png` | Icono de la ventana |
| `logs/` | Registro de operaciones |

### Flujo general

```
LidaPrint.bat / .vbs
    |
    v
Configurator.ps1  ──>  config.json
    |
    v (Task Scheduler — al iniciar sesion / al iniciar Windows, RunLevel Highest)
LidaPrint.ps1
    |
    +-- [Runspace HTTP]  Start-WebListener  (solo si webEnabled)
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
      SumatraPDF imprime  →  elimina archivo
```

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
| `Test-FileReady` | Verifica que el archivo no este bloqueado por otro proceso |
| `Invoke-Print` | Construye los `-print-settings` y ejecuta SumatraPDF; mapea el exit code |
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
| "SumatraPDF no encontrado" | Ejecutable movido/eliminado | Re-ejecutar `Install.ps1` o corregir la ruta en el Configurator |
| El PDF no se elimina | Archivo bloqueado por otro proceso | LidaPrint reintenta 5 veces; si falla, se reintenta al reiniciar |
| No detecta facturas (modo local) | Patron incorrecto o API activada | Revisar el regex o desactivar la API |
| API no responde | Puerto en uso o firewall | `netstat -an \| findstr 8080` y abrir el puerto |
| 401 Unauthorized | API Key incorrecta | Verificar el header `X-Api-Key` |
| El listener no arranca (ejecucion manual) | Falta reserva urlacl (sin admin) | `netsh http add urlacl url=http://+:8080/ user=%USERNAME%` o correr elevado |
| Monitor se cierra al iniciar | Error en `config.json` | Revisar el log; suele ser impresora o ruta invalida |
| La consola parpadea al arrancar | Se ejecuto el `.bat` directo | Usar `LidaPrint.vbs` para arranque silencioso |

---

## Desinstalar

```powershell
Unregister-ScheduledTask -TaskName "LidaPrint" -Confirm:$false
Remove-Item -Recurse -Force "C:\AutoPrintFacturas"
```

---

## Licencia

MIT
