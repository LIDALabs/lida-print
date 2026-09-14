<#
.SYNOPSIS
    LidaPrint - Monitor de impresion automatica de facturas Odoo.
.DESCRIPTION
    Vigila carpeta local y/o recibe archivos via HTTP.
    Imprime con Ghostscript y elimina el archivo.
    La API permite a Odoo controlar que archivos se imprimen.
.NOTES
    Se ejecuta via Task Scheduler al iniciar sesion.
#>

$ErrorActionPreference = "Stop"

# ===================== CARGAR CONFIGURACION =====================
$scriptDir = if ($Global:LidaPrintExeDir) { $Global:LidaPrintExeDir } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$configPath = Join-Path $scriptDir "config.json"

# Traza de arranque INCONDICIONAL, antes de validar nada. El monitor corre con
# ventana oculta: si muere antes del banner, sin esta linea no queda rastro.
function Write-BootLog {
    param([string]$message, [string]$level = "INFO")
    try {
        $bootDir = Join-Path $scriptDir "logs"
        if (-not (Test-Path $bootDir)) { New-Item -ItemType Directory -Path $bootDir -Force | Out-Null }
        $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$level] $message"
        Add-Content -Path (Join-Path $bootDir "PrintLog_$(Get-Date -Format 'yyyy-MM').txt") -Value $line -Encoding UTF8
        Write-Host $line
    } catch { }
}
Write-BootLog "Proceso monitor lanzado (PID $PID, usuario $env:USERNAME)"

# Instancia unica: dos monitores en paralelo compiten por los mismos archivos
# (doble impresion o errores espurios cuando uno borra lo que el otro procesa).
# El mutex vive lo que vive el proceso; el SO lo libera al salir.
# Intentar mutex Global para cubrir sesiones distintas (TS/RDS). Si el usuario
# no tiene permiso para crear objetos globales, caer a Local sin error.
$script:instanceMutex = $null
try {
    $script:instanceMutex = New-Object System.Threading.Mutex($false, "Global\LidaPrintMonitor")
} catch [System.UnauthorizedAccessException] {
    $script:instanceMutex = New-Object System.Threading.Mutex($false, "Local\LidaPrintMonitor")
} catch {
    $script:instanceMutex = New-Object System.Threading.Mutex($false, "Local\LidaPrintMonitor")
}
if (-not $script:instanceMutex.WaitOne(0)) {
    Write-BootLog "Ya hay otro monitor corriendo en esta sesion - esta instancia sale (PID $PID)" "WARN"
    exit 0
}

# Ocultar la propia ventana de consola. La tarea lanza con -WindowStyle Minimized
# porque Hidden puede colgar el arranque en Windows 11; una vez corriendo, el
# monitor esconde su consola por completo (invisible e incerrable por el usuario).
# NOTA: se usa GetConsoleWindow() y NO Process.MainWindowHandle, que devuelve
# cero para ventanas minimizadas y dejaba la consola visible.
try {
    $sig = '[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);'
    $win32 = Add-Type -MemberDefinition $sig -Name "Win32Console" -Namespace "Native" -PassThru
    $hwnd = $win32::GetConsoleWindow()
    if ($hwnd -ne [IntPtr]::Zero) { [void]$win32::ShowWindow($hwnd, 0) }
} catch { }

if (-not (Test-Path $configPath)) {
    Write-BootLog "config.json no encontrado en $scriptDir - abortando" "ERROR"
    Start-Sleep 10; exit 1
}

try {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
} catch {
    Write-BootLog "config.json invalido o ilegible: $_ - abortando" "ERROR"
    Start-Sleep 10; exit 1
}

# ---------- Resolucion de rutas (self-locating) ----------
# Las rutas guardadas en config.json pueden quedar obsoletas si la carpeta
# se movio o el ejecutable cambio de lugar. Cada ruta se re-resuelve en
# runtime probando: (1) el valor guardado, (2) ubicaciones conocidas.
function Resolve-ToolPath {
    param([string]$saved, [string[]]$candidates)
    if ($saved -and (Test-Path $saved)) { return $saved }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return $null
}

# Modo de operacion: "local" (patron de nombre), "api" (Odoo empuja por HTTP a
# esta PC) o "cloud" (esta PC consulta a Odoo por HTTPS). Configs viejas no
# traen "mode": se deriva de webEnabled. Copia identica en Configurator.ps1:
# en el exe unico el monitor corre dentro de la rama -Service y la GUI fuera,
# asi que no comparten funciones.
function Get-LidaPrintMode {
    param($cfg)
    $m = ""
    if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'mode') -and $cfg.mode) { $m = ([string]$cfg.mode).Trim().ToLower() }
    if ($m -eq "local" -or $m -eq "api" -or $m -eq "cloud") { return $m }
    if ($cfg -and $cfg.webEnabled) { return "api" }
    return "local"
}
$script:runMode = Get-LidaPrintMode $config

# ===================== MODO NUBE: FUNCIONES COMPARTIDAS =====================
# Copia identica en Configurator.ps1, por el mismo motivo que Get-LidaPrintMode.
# tests/Cloud.Tests.ps1 falla si las dos copias dejan de coincidir.
function Test-CloudLocalHost {
    # True si el host es esta PC o un equipo de la red local: localhost, nombres
    # .local (mDNS), loopback (127.0.0.0/8, ::1), redes privadas (10/8,
    # 172.16/12, 192.168/16), link-local (169.254/16, fe80::/10), CGNAT
    # (100.64/10) y ULA IPv6 (fc00::/7). Solo hacia ellos se admite http://.
    param([string]$hostName)
    $h = (([string]$hostName).Trim() -replace '^\[(.*)\]$', '$1').TrimEnd('.').ToLowerInvariant()
    if (-not $h) { return $false }
    if ($h -eq "localhost" -or $h.EndsWith(".local")) { return $true }
    $ip = $null
    if (-not [System.Net.IPAddress]::TryParse($h, [ref]$ip)) { return $false }
    if ($ip.IsIPv4MappedToIPv6) { $ip = $ip.MapToIPv4() }
    $b = $ip.GetAddressBytes()
    if ($ip.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        return ($b[0] -eq 127 -or $b[0] -eq 10 -or
            ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or
            ($b[0] -eq 192 -and $b[1] -eq 168) -or
            ($b[0] -eq 169 -and $b[1] -eq 254) -or
            ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127))
    }
    return ([System.Net.IPAddress]::IPv6Loopback.Equals($ip) -or
        (($b[0] -band 0xFE) -eq 0xFC) -or
        ($b[0] -eq 0xFE -and ($b[1] -band 0xC0) -eq 0x80))
}

function Get-CloudUrlCheck {
    # Normaliza la URL de Odoo a esquema://host[:puerto] y valida el esquema:
    # https siempre; http solo hacia la red local (Test-CloudLocalHost), con
    # advertencia. Quita ruta, query y fragmento: con https://host/odoo, Odoo 18
    # responde al ping con un 303 a /web/login y al poll con un 400 (CSRF).
    # Devuelve Url (normalizada), Error (no se puede usar), Warning (http sin
    # cifrado) y Notice (se quito una ruta: hay que avisar al usuario).
    param([string]$url)
    $raw = ([string]$url).Trim()
    $res = @{ Url = $raw.TrimEnd('/'); Error = ""; Warning = ""; Notice = "" }
    if (-not $raw) { $res.Error = "Falta la URL de Odoo (ej: https://cliente.example.com)."; return $res }
    if ($raw -notmatch '^[A-Za-z][A-Za-z0-9+.-]*://') {
        $res.Error = "La URL de Odoo debe empezar con https:// (ej: https://cliente.example.com)."; return $res
    }
    $u = $null
    if (-not [Uri]::TryCreate($raw, [UriKind]::Absolute, [ref]$u) -or -not $u.Host) {
        $res.Error = "La URL de Odoo no es valida: $raw"; return $res
    }
    $scheme = $u.Scheme.ToLowerInvariant()
    if ($scheme -ne "https" -and $scheme -ne "http") {
        $res.Error = "La URL de Odoo debe empezar con https:// (ej: https://cliente.example.com)."; return $res
    }
    # Solo esquema, host y puerto (el puerto solo si no es el de fabrica). Un
    # literal IPv6 se toma del texto escrito (compacto, en minusculas): [uri] de
    # .NET Framework 4.x lo expande siempre ([::1] -> [0000:...:0001]).
    $hostText = $u.Host.ToLowerInvariant()
    if ($raw -match '^[A-Za-z][A-Za-z0-9+.-]*://(?:[^/?#@]*@)?(\[[^\]/?#]+\])') { $hostText = $Matches[1].ToLowerInvariant() }
    $base = "${scheme}://$hostText"
    if (-not $u.IsDefaultPort) { $base += ":$($u.Port)" }
    $res.Url = $base
    $rest = [string]$u.PathAndQuery + [string]$u.Fragment
    if ($rest -ne "/" -and $rest -ne "") {
        if ($rest.Length -gt 60) { $rest = $rest.Substring(0, 57) + "..." }
        $res.Notice = "La URL traia la ruta '$rest', que sobra: LidaPrint usa solo la direccion base de Odoo, sin /odoo ni /web. Se usa $base."
    }
    if ($scheme -eq "https") { return $res }
    if (Test-CloudLocalHost $hostText) {
        $res.Warning = "La URL usa http:// (sin cifrado): el token viaja en claro. Solo es aceptable dentro de la red local."
        return $res
    }
    $res.Error = "La URL debe empezar con https://: con http:// el token viajaria en claro por internet. http:// solo se admite para localhost o un equipo de la red local."
    return $res
}

function Get-CloudFailureKind {
    # Clasifica el codigo HTTP de un ping o de un poll fallido (0 = sin respuesta):
    #   "unauthorized": 401, equipo archivado o token revocado en Odoo.
    #   "config": 404 o 400. La peticion no llega a /lidaprint/v1 del modulo:
    #     la URL trae una ruta, el modulo no esta actualizado o, con varias
    #     bases y sin dbfilter, Odoo no sabe cual usar y responde HTML 404.
    #     Reintentar no lo arregla: hay que corregir la configuracion.
    #   "transient": sin respuesta, 408, 429 o 5xx.
    #   "other": cualquier otro codigo.
    param([int]$code)
    if ($code -eq 401) { return "unauthorized" }
    if ($code -eq 404 -or $code -eq 400) { return "config" }
    if ($code -eq 0 -or $code -eq 408 -or $code -eq 429 -or $code -ge 500) { return "transient" }
    return "other"
}

function Get-CloudConfigHint {
    # Texto del Configurador y del log para un 404/400 del ping o del poll.
    return "URL incorrecta o base de datos no resuelta: revise la URL (sin /odoo ni /web) y, si el servidor tiene varias bases, configure dbfilter por dominio"
}

# Ghostscript: consola de 64 bits (gswin64c) o 32 (gswin32c)
$gsCandidates = @()
$gsCandidates += (Join-Path $scriptDir "bin\gswin64c.exe")
foreach ($base in @("$env:ProgramFiles\gs", "${env:ProgramFiles(x86)}\gs", "$env:LOCALAPPDATA\Programs\gs")) {
    if (Test-Path $base) {
        $found = Get-ChildItem -Path $base -Recurse -Filter "gswin*c.exe" -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
        if ($found) { $gsCandidates += $found.FullName }
    }
}
$gsResolved = Resolve-ToolPath $config.gsPath $gsCandidates

if (-not $config.printer) {
    Write-BootLog "No hay impresora configurada - abortando. Abre el Configurator, elige impresora y Guardar." "ERROR"
    Start-Sleep 10; exit 1
}
if ($config.printer -match '"') {
    Write-BootLog "El nombre de impresora no puede contener comillas dobles: '$($config.printer)' - abortando. Corrige el nombre en el Configurator." "ERROR"
    Start-Sleep 10; exit 1
}
if (-not $gsResolved) {
    Write-BootLog "Ghostscript no encontrado - abortando. Re-ejecuta el instalador." "ERROR"
    Start-Sleep 10; exit 1
}
if (-not $config.downloadFolder) {
    # Default: la carpeta de Descargas del usuario actual (donde Odoo baja las facturas)
    $config.downloadFolder = Join-Path $env:USERPROFILE "Downloads"
}
# En modo Nube no se vigila ninguna carpeta: no abortar por ella.
if ($script:runMode -ne "cloud" -and -not (Test-Path $config.downloadFolder)) {
    Write-BootLog "Carpeta de descargas no encontrada: $($config.downloadFolder) - abortando" "ERROR"
    Start-Sleep 10; exit 1
}
# Modo Nube sin URL o sin token: igual que la API sin API Key, no se arranca.
# Aqui ademas se sale, porque el modo Nube no tiene otro trabajo que hacer y
# un monitor ocioso haria creer a "Probar monitor" que todo esta bien.
if ($script:runMode -eq "cloud" -and (-not ([string]$config.cloudUrl).Trim() -or -not ([string]$config.cloudToken).Trim())) {
    Write-BootLog "Modo Nube sin URL de Odoo o sin token: no se consulta a Odoo. Configuralos en la pestana Conexion del Configurator. - abortando" "ERROR"
    Start-Sleep 10; exit 1
}
# Misma regla de URL que el Configurator (Get-CloudUrlCheck). Un config.json
# viejo o editado a mano puede traer http:// hacia un host publico: el token
# viajaria en claro por internet, asi que el ciclo Nube no arranca.
$script:cloudUrlCheck = Get-CloudUrlCheck ([string]$config.cloudUrl)
if ($script:runMode -eq "cloud" -and $script:cloudUrlCheck.Error) {
    Write-BootLog "Modo Nube: $($script:cloudUrlCheck.Error) Corrigela en la pestana Conexion del Configurator. - abortando" "ERROR"
    Start-Sleep 10; exit 1
}

# Directorio temporal PROPIO para los PDF intermedios de la pasada 1.
# NO usar $env:TEMP: el Task Scheduler lo entrega en formato corto 8.3
# (C:\Users\JOSEG~1\...) y ese alias puede no existir en el volumen,
# rompiendo la impresion antes de empezar.
$script:tempDir = Join-Path $scriptDir "temp"
if (-not (Test-Path $script:tempDir)) { New-Item -ItemType Directory -Path $script:tempDir -Force | Out-Null }
# Limpiar residuos de corridas anteriores
Get-ChildItem -Path $script:tempDir -Filter "lidaprint_fit_*" -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue
# PDFs de trabajos de la nube que quedaron a medias (corte de luz, cierre)
Get-ChildItem -Path $script:tempDir -Filter "job-*" -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

# ===================== FUNCIONES =====================
function Write-Log {
    param([string]$message, [string]$level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$level] $message"
    if ($config.enableLogging) {
        $logDir = Join-Path $scriptDir "logs"
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        # Rotacion mensual: un archivo por mes evita crecimiento indefinido
        $logFile = Join-Path $logDir "PrintLog_$(Get-Date -Format 'yyyy-MM').txt"
        Add-Content -Path $logFile -Value $line -Encoding UTF8
    }
    # La salida a consola es opcional: en consola headless o rota, Write-Host
    # puede lanzar (error 0xE9). El log a archivo ya se escribio arriba.
    try {
        switch ($level) {
            "ERROR" { Write-Host $line -ForegroundColor Red }
            "WARN"  { Write-Host $line -ForegroundColor Yellow }
            "OK"    { Write-Host $line -ForegroundColor Green }
            default { Write-Host $line -ForegroundColor Gray }
        }
    } catch { }
}

function Test-FileReady {
    param([string]$filePath)
    for ($i = 0; $i -lt 15; $i++) {
        try {
            $s = [System.IO.File]::Open($filePath, 'Open', 'Read', 'None')
            $s.Close(); $s.Dispose(); return $true
        } catch { Start-Sleep -Milliseconds 500 }
    }
    return $false
}

function Invoke-ProcessCapture {
    param([string]$exe, [string]$arguments)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = $arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.WaitForExit()
    $code = $proc.ExitCode
    $proc.Dispose()
    return $code
}

function Get-PaperPoints {
    # Dimensiones del papel en puntos PostScript (1 mm = 2.835 pt)
    if ($config.useCustomPaper) {
        return @([math]::Round($config.paperWidth * 2.835), [math]::Round($config.paperHeight * 2.835))
    }
    if ($config.continuousForm) {
        return @([math]::Round(210 * 2.835), [math]::Round($config.formLength * 2.835))
    }
    switch ($config.paperSize) {
        "A4"      { return @(595, 842) }
        "Letter"  { return @(612, 792) }
        "Legal"   { return @(612, 1008) }
        "Tabloid" { return @(792, 1224) }
        "A5"      { return @(420, 595) }
        default   { return @(595, 842) }
    }
}

function Invoke-PrintGhostscript {
    # Rasteriza el PDF al DPI configurado y lo envia via el driver de Windows
    # (device mswinpr2). Esto arregla los casos donde el PDF se ve bien en
    # pantalla pero imprime mal: la pagina llega a la impresora ya renderizada
    # a la resolucion exacta, sin depender de como el driver interprete fuentes.
    param([string]$filePath)
    $fileName = Split-Path $filePath -Leaf
    $dpi = if ($config.dpi) { [int]$config.dpi } else { 300 }

    # PASADA 1 - Tamano de papel: mswinpr2 toma el tamano de pagina del DEVMODE
    # del driver de Windows e IGNORA los parametros de medio de la linea de
    # comandos. pdfwrite si los respeta: se re-formatea el PDF al tamano
    # configurado (contenido escalado adentro con FitPage) y ESE es el que se
    # imprime en la pasada 2.
    # Cultura invariante: los flotantes que van a Ghostscript (-dDEVICE*POINTS,
    # -c BeginPage) deben usar punto decimal, no la coma del locale es-VE.
    $ic = [System.Globalization.CultureInfo]::InvariantCulture
    $paper = Get-PaperPoints
    $wPts = $paper[0]; $hPts = $paper[1]
    if ($config.orientation -eq "landscape") { $tmp = $wPts; $wPts = $hPts; $hPts = $tmp }

    $resized = Join-Path $script:tempDir ("lidaprint_fit_" + [System.IO.Path]::GetFileName($filePath))
    $fitArgs = "-dBATCH -dNOPAUSE -dQUIET -sDEVICE=pdfwrite -dDEVICEWIDTHPOINTS=$(([double]$wPts).ToString($ic)) -dDEVICEHEIGHTPOINTS=$(([double]$hPts).ToString($ic)) -dFIXEDMEDIA -dFitPage `"-sOutputFile=$resized`" -f `"$filePath`""
    $fitCode = Invoke-ProcessCapture $gsResolved $fitArgs
    $printSource = $filePath
    if ($fitCode -eq 0 -and (Test-Path $resized)) {
        $printSource = $resized
    } else {
        Write-Log "Ajuste de tamano de papel fallo (gs $fitCode); se imprime el PDF original" "WARN"
    }

    # PASADA 2 - Impresion via driver de Windows (mswinpr2)
    $gsArgs = @(
        "-dBATCH", "-dNOPAUSE", "-dQUIET", "-dNoCancel",
        "-sDEVICE=mswinpr2",
        "-r$dpi",
        "-dNumCopies=$($config.copies)"
    )

    # Suavizado de texto/graficos al rasterizar (maxima fidelidad)
    if ($config.renderAsImage) {
        $gsArgs += @("-dTextAlphaBits=4", "-dGraphicsAlphaBits=4")
    }

    # Margenes = DESPLAZAMIENTO puro por lado, sin escalar. Cada margen empuja
    # el contenido en su direccion: izquierdo -> derecha, derecho -> izquierda,
    # superior -> abajo, inferior -> arriba (eje Y de PostScript apunta arriba).
    # Si el contenido queda fuera del papel se recorta; para achicarlo esta
    # Escala (%). topOffset (forma continua) empuja hacia abajo.
    $mL = [double]$config.marginLeft   * 2.835
    $mR = [double]$config.marginRight  * 2.835
    $mT = [double]$config.marginTop    * 2.835
    $mB = [double]$config.marginBottom * 2.835
    $offX = [math]::Round($mL - $mR, 2)
    $offY = [math]::Round($mB - $mT, 2)
    if ($config.continuousForm -and $config.topOffset) {
        $offY = [math]::Round($offY - ([double]$config.topOffset * 2.835), 2)
    }
    $userScale = 1.0
    if ($config.scale -and $config.scale -ne 100) { $userScale = [math]::Round([double]$config.scale / 100.0, 4) }

    $pageCmd = $null
    if ($offX -ne 0 -or $offY -ne 0 -or $userScale -ne 1.0) {
        # translate primero, scale despues: la escala queda anclada en el punto
        # ya desplazado, asi los margenes no se re-escalan.
        $sOffX = ([double]$offX).ToString($ic); $sOffY = ([double]$offY).ToString($ic)
        $sScale = ([double]$userScale).ToString($ic)
        $pageCmd = "<< /BeginPage { pop $sOffX $sOffY translate $sScale $sScale scale } >> setpagedevice"
    }

    $gsArgs += "-sOutputFile=%printer%$($config.printer)"
    if ($pageCmd) { $gsArgs += "-c"; $gsArgs += $pageCmd }
    $gsArgs += "-f"
    $gsArgs += $printSource
    # Quotear todo argumento con espacios (bloque -c, OutputFile, ruta del PDF)
    $argStr = ($gsArgs | ForEach-Object { if ($_ -match '\s' -or $_ -match '^-sOutputFile=') { "`"$_`"" } else { $_ } }) -join " "

    $exitCode = Invoke-ProcessCapture $gsResolved $argStr

    # Limpiar el PDF temporal de la pasada 1
    if ($printSource -ne $filePath) { Remove-Item -LiteralPath $printSource -Force -ErrorAction SilentlyContinue }

    if ($exitCode -eq 0) {
        return @{ Success = $true; Message = "Impreso (Ghostscript ${dpi}dpi, $([math]::Round($wPts/2.835))x$([math]::Round($hPts/2.835))mm): $fileName -> $($config.printer)" }
    } else {
        return @{ Success = $false; Message = "Error Ghostscript ($exitCode) imprimiendo $fileName" }
    }
}

# Helper de impresion CRUDA (RAW datatype) via WritePrinter. Necesario para la
# via ESC/POS: manda bytes directos al puerto, sin pasar por el render GDI del
# driver. Imprescindible en ticketeras EPSON conectadas por adaptador
# USB-a-paralelo (CH340), donde el driver EPSON no acepta trabajos GDI.
if (-not ("LidaRaw" -as [type])) {
Add-Type -Language CSharp -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public class LidaRaw {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Ansi)]
  public struct DI { [MarshalAs(UnmanagedType.LPStr)] public string n;
    [MarshalAs(UnmanagedType.LPStr)] public string o; [MarshalAs(UnmanagedType.LPStr)] public string t; }
  [DllImport("winspool.drv",CharSet=CharSet.Ansi,SetLastError=true)] public static extern bool OpenPrinter(string s,out IntPtr h,IntPtr d);
  [DllImport("winspool.drv",SetLastError=true)] public static extern bool StartDocPrinter(IntPtr h,int l,ref DI di);
  [DllImport("winspool.drv",SetLastError=true)] public static extern bool StartPagePrinter(IntPtr h);
  [DllImport("winspool.drv",SetLastError=true)] public static extern bool WritePrinter(IntPtr h,byte[] b,int c,out int w);
  [DllImport("winspool.drv",SetLastError=true)] public static extern bool EndPagePrinter(IntPtr h);
  [DllImport("winspool.drv",SetLastError=true)] public static extern bool EndDocPrinter(IntPtr h);
  [DllImport("winspool.drv",SetLastError=true)] public static extern bool ClosePrinter(IntPtr h);
  public static string Send(string p, byte[] d){ IntPtr h;
    if(!OpenPrinter(p,out h,IntPtr.Zero)) return "OpenPrinter FAIL "+Marshal.GetLastWin32Error();
    var di=new DI(); di.n="LidaPrint ESCPOS"; di.t="RAW";
    if(!StartDocPrinter(h,1,ref di)){ClosePrinter(h);return "StartDoc FAIL "+Marshal.GetLastWin32Error();}
    StartPagePrinter(h); int w; bool ok=WritePrinter(h,d,d.Length,out w);
    EndPagePrinter(h); EndDocPrinter(h); ClosePrinter(h);
    if(!ok) return "WritePrinter FAIL "+Marshal.GetLastWin32Error();
    return "OK"; } }
"@
}

function Read-PbmToken {
    # Lee un token del header PBM/PGM saltando espacios y comentarios (#...).
    param([byte[]]$b, [ref]$i)
    while ($true) {
        $c = $b[$i.Value]
        if ($c -eq 32 -or $c -eq 10 -or $c -eq 13 -or $c -eq 9) { $i.Value++; continue }
        if ($c -eq 35) { while ($b[$i.Value] -ne 10) { $i.Value++ }; continue }
        break
    }
    $s = ""
    while ($b[$i.Value] -notin 32, 10, 13, 9) { $s += [char]$b[$i.Value]; $i.Value++ }
    return $s
}

function Invoke-PrintEscPos {
    # Via ESC/POS raster: rasteriza el PDF a un bitmap del ancho imprimible y lo
    # manda como comandos de imagen (ESC *) en bytes crudos. Para ticketeras
    # 9-agujas / termicas cuyo driver no acepta impresion GDI por el puerto
    # disponible (p. ej. EPSON TM-U220 por adaptador USB-a-paralelo CH340).
    #
    # Estrategia (maximiza tamano y nitidez en papel angosto):
    #   1. Recorta al CONTENIDO real del PDF (device bbox) -> descarta margenes
    #      y el blanco, para que la factura llene el papel.
    #   2. Escala ese contenido para llenar el ancho imprimible completo.
    #   3. Renderiza en gris con antialiasing y umbraliza -> trazos mas firmes,
    #      texto chico mas legible en impacto.
    #   4. Codifica en bandas ESC * de 8 puntos con el interlineado calibrado.
    #
    # Valores calibrados por impresora (pestana Calibracion del Configurator):
    #   escposWidthMm     : ancho imprimible real (la barra que llena el papel).
    #   escposHdpi        : densidad horizontal (puntos / mm * 25.4).
    #   escposVdpi        : densidad vertical de la banda de 8 puntos.
    #   escposLineSpacing : ESC 3 n para que las bandas queden JUSTO pegadas
    #                       (mide un bloque solido; corrige la raya blanca).
    #   escposThreshold   : umbral de negro (0-255); mas alto = trazo mas grueso.
    param([string]$filePath)
    $fileName = Split-Path $filePath -Leaf
    $widthMm  = if ($config.escposWidthMm) { [double]$config.escposWidthMm } else { 64 }
    $hdpi     = if ($config.escposHdpi)    { [double]$config.escposHdpi }    else { 158.75 }
    $vdpi     = if ($config.escposVdpi)    { [double]$config.escposVdpi }    else { 72 }
    $m        = if ($null -ne $config.escposDensity) { [int]$config.escposDensity } else { 1 }
    $lineSpacing = if ($config.escposLineSpacing) { [int]$config.escposLineSpacing } else { 16 }
    $threshold   = if ($null -ne $config.escposThreshold) { [int]$config.escposThreshold } else { 170 }
    $antialias   = if ($null -ne $config.escposAntialias) { [bool]$config.escposAntialias } else { $true }

    try {
        if (-not ("System.Drawing.Bitmap" -as [type])) { Add-Type -AssemblyName System.Drawing }
        # Cultura invariante: los flotantes que van a Ghostscript (-r, -c) deben
        # usar punto decimal, no la coma del locale es-VE (rompe el parseo de gs).
        $ic = [System.Globalization.CultureInfo]::InvariantCulture

        # 1) bbox del contenido (puntos). Descarta margenes/blanco del PDF.
        #    El device bbox escribe a STDERR: redirigir a archivo (capturar con
        #    2>&1 lo envuelve como ErrorRecord y no matchea el texto).
        $bboxTxt = Join-Path $script:tempDir ("escpos_bbox_" + [System.IO.Path]::GetFileNameWithoutExtension($filePath) + ".txt")
        Remove-Item -LiteralPath $bboxTxt -Force -ErrorAction SilentlyContinue
        Start-Process $gsResolved -ArgumentList "-dBATCH -dNOPAUSE -dQUIET -sDEVICE=bbox -dLastPage=1 -f `"$filePath`"" -Wait -NoNewWindow -RedirectStandardError $bboxTxt
        $bw = 0; $bh = 0; $llx = 0; $lly = 0
        if (Test-Path $bboxTxt) {
            $bline = Get-Content $bboxTxt | Select-String "HiResBoundingBox" | Select-Object -First 1
            if ($bline) {
                $nums = [regex]::Matches($bline.ToString(), "[-0-9.]+") | ForEach-Object { [double]$_.Value }
                if ($nums.Count -ge 4) { $llx = $nums[0]; $lly = $nums[1]; $bw = $nums[2] - $llx; $bh = $nums[3] - $lly }
            }
            Remove-Item -LiteralPath $bboxTxt -Force -ErrorAction SilentlyContinue
        }

        # 2) Geometria destino: llenar el ancho imprimible, alto por aspecto fisico.
        $widthDots = [int][math]::Round($widthMm / 25.4 * $hdpi)
        if ($bw -le 1 -or $bh -le 1) {
            # PDF sin bbox util (raro): usar pagina completa como respaldo.
            $probe = Join-Path $script:tempDir ("escpos_probe_" + [System.IO.Path]::GetFileNameWithoutExtension($filePath) + ".pbm")
            Invoke-ProcessCapture $gsResolved "-dBATCH -dNOPAUSE -dQUIET -dFirstPage=1 -dLastPage=1 -sDEVICE=pbmraw -r24 `"-sOutputFile=$probe`" -f `"$filePath`"" | Out-Null
            $pb = [System.IO.File]::ReadAllBytes($probe); $pi = 2
            $pw = [int](Read-PbmToken $pb ([ref]$pi)); $ph = [int](Read-PbmToken $pb ([ref]$pi))
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            $bw = $pw * 3.0; $bh = $ph * 3.0; $llx = 0; $lly = 0
        }
        $rows = [int][math]::Round(($widthDots / $hdpi) * ($bh / $bw) * $vdpi)
        if ($rows -lt 1) { $rows = 1 }
        $rHdpi = ($widthDots * 72.0 / $bw).ToString($ic)
        $rVdpi = ($rows * 72.0 / $bh).ToString($ic)
        $tx = ([math]::Round(-1 * $llx, 3)).ToString($ic)
        $ty = ([math]::Round(-1 * $lly, 3)).ToString($ic)
        $inst = "<</Install{ $tx $ty translate }>> setpagedevice"

        # 3) Render gris (antialias) o mono, recortado+escalado al destino.
        #    -dFirstPage/-dLastPage: el bbox se midio en la pagina 1; renderizar
        #    solo esa pagina para no meter paginas extra en la geometria fija.
        $png = Join-Path $script:tempDir ("escpos_" + [System.IO.Path]::GetFileNameWithoutExtension($filePath) + ".png")
        Remove-Item -LiteralPath $png -Force -ErrorAction SilentlyContinue
        $aa = if ($antialias) { "-dTextAlphaBits=4 -dGraphicsAlphaBits=4" } else { "" }
        $rArgs = "-dBATCH -dNOPAUSE -dQUIET -dFirstPage=1 -dLastPage=1 -sDEVICE=pnggray $aa -g${widthDots}x${rows} " +
                 "-r${rHdpi}x${rVdpi} -dFIXEDMEDIA `"-sOutputFile=$png`" -c `"$inst`" -f `"$filePath`""
        $rc = Invoke-ProcessCapture $gsResolved $rArgs
        if (-not (Test-Path $png)) { return @{ Success = $false; Message = "ESC/POS: fallo el rasterizado (gs $rc): $fileName" } }

        # 4) Leer los grises via LockBits (rapido) y umbralizar. try/finally para
        #    liberar SIEMPRE el bitmap/lockbits (fuga de handles GDI+ si excepta).
        $w = 0; $h = 0; $stride = 0; $buf = $null
        $bmp = New-Object System.Drawing.Bitmap($png)
        try {
            $w = $bmp.Width; $h = $bmp.Height
            $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
            $bd = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
            try {
                $stride = $bd.Stride
                $buf = New-Object byte[] ($stride * $h)
                [System.Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $buf, 0, $buf.Length)
            } finally {
                $bmp.UnlockBits($bd)
            }
        } finally {
            $bmp.Dispose()
        }
        Remove-Item -LiteralPath $png -Force -ErrorAction SilentlyContinue

        # 5) Codificar en bandas ESC * de 8 puntos. Negro si gris < umbral.
        $out = New-Object System.Collections.Generic.List[byte]
        $ESC = 0x1B; $LF = 0x0A
        $out.Add($ESC); $out.Add(0x40)                               # ESC @ init
        $out.Add($ESC); $out.Add(0x33); $out.Add([byte]$lineSpacing) # ESC 3 n calibrado
        $nL = $w -band 0xFF; $nH = ($w -shr 8) -band 0xFF
        $bands = [int][math]::Ceiling($h / 8.0)
        for ($band = 0; $band -lt $bands; $band++) {
            $out.Add($ESC); $out.Add(0x2A); $out.Add([byte]$m); $out.Add([byte]$nL); $out.Add([byte]$nH)
            for ($x = 0; $x -lt $w; $x++) {
                $bv = 0
                $xoff = $x * 3
                for ($k = 0; $k -lt 8; $k++) {
                    $r = $band * 8 + $k
                    if ($r -lt $h -and $buf[$r * $stride + $xoff] -lt $threshold) {
                        $bv = $bv -bor (1 -shl (7 - $k))
                    }
                }
                $out.Add([byte]$bv)
            }
            $out.Add($LF)
        }
        1..6 | ForEach-Object { $out.Add($LF) }                      # avanzar para cortar

        # Separacion extra entre tickets: linePitch (mm) de la pestana Forma
        # Continua, aplicada siempre (con o sin forma continua). Cada LF avanza
        # una banda de 8 puntos al vdpi calibrado, asi los mm se traducen a
        # saltos reales de esta impresora.
        $extraMm = if ($config.linePitch) { [double]$config.linePitch } else { 0 }
        if ($extraMm -gt 0) {
            $mmPerLf = 8.0 * 25.4 / $vdpi
            $extraLf = [int][math]::Round($extraMm / $mmPerLf)
            if ($extraLf -gt 0) { 1..$extraLf | ForEach-Object { $out.Add($LF) } }
        }

        $res = [LidaRaw]::Send($config.printer, $out.ToArray())
        if ($res -eq "OK") {
            return @{ Success = $true; Message = "Impreso (ESC/POS ${w}x${h} puntos, ${widthMm}mm): $fileName -> $($config.printer)" }
        }
        return @{ Success = $false; Message = "ESC/POS: $res imprimiendo $fileName" }
    } catch {
        return @{ Success = $false; Message = "ESC/POS: excepcion imprimiendo ${fileName}: $($_.Exception.Message)" }
    }
}

function Invoke-Print {
    param([string]$filePath)
    if ($config.escposEnabled) {
        return Invoke-PrintEscPos $filePath
    }
    return Invoke-PrintGhostscript $filePath
}

function Remove-Invoice {
    param([string]$filePath)
    $lastError = $null
    for ($i = 0; $i -lt 8; $i++) {
        try {
            Remove-Item -LiteralPath $filePath -Force -ErrorAction Stop
            return $true
        } catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Milliseconds 700
        }
    }
    # Dejar el MOTIVO en el log: "no se pudo eliminar" sin causa es indepurable
    Write-Log "Eliminacion fallida tras 8 intentos: $filePath - $lastError" "ERROR"
    return $false
}

function Process-InvoiceFile {
    param([string]$fp)
    $fileName = Split-Path $fp -Leaf

    # Esperar tamano estable. Chequeos rapidos (200ms) para minimizar la latencia
    # de impresion: ~600ms tipico para un archivo ya descargado, hasta 5s para
    # descargas lentas.
    $sz = -1; $lastSize = -1; $stable = 0; $ready = $false
    for ($i = 0; $i -lt 25; $i++) {
        Start-Sleep -Milliseconds 200
        try { $sz = (Get-Item -LiteralPath $fp).Length } catch { break }
        if ($sz -eq $lastSize -and $sz -gt 0) { $stable++; if ($stable -ge 2) { $ready = $true; break } }
        else { $stable = 0 }
        $lastSize = $sz
    }
    if (-not $ready) { Write-Log "Archivo no estabilizado: $fileName" "WARN"; return }
    if (-not (Test-FileReady $fp)) { Write-Log "Archivo bloqueado: $fileName" "WARN"; return }

    Write-Log "Procesando: $fileName ($sz bytes)"
    $result = Invoke-Print $fp
    if ($result.Success) {
        Write-Log $result.Message "OK"
        if (Remove-Invoice $fp) { Write-Log "Eliminado: $fileName" "OK" }
        else { Write-Log "No se pudo eliminar: $fileName" "WARN" }
    } else {
        Write-Log $result.Message "ERROR"
    }
}

# ===================== COLAS DE LA API =====================
# ArrayList sincronizado: seguro para acceso concurrente entre el hilo
# principal (polling) y el runspace del listener HTTP.
$script:printQueue = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
$script:skipList   = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())

# ===================== LISTENER WEB (HTTP) =====================
$script:httpListener = $null
$script:httpRunning = $false

function Start-WebListener {
    if ($script:runMode -ne "api") { return }
    # Seguridad: no exponer un endpoint de subida+impresion sin autenticacion.
    # Si la API esta activada pero no hay API Key, el listener NO se inicia.
    if (-not $config.webApiKey) {
        Write-Log "API web activada SIN API Key. Por seguridad el listener no se inicia. Configura una API Key en el Configurator." "ERROR"
        return
    }
    try {
        $script:httpListener = New-Object System.Net.HttpListener
        # Prefijo raiz: enruta TODAS las rutas en codigo. El prefijo anterior
        # ("/print/") dejaba /skip y /clear fuera de alcance (nunca llegaban).
        $script:httpListener.Prefixes.Add("http://+:$($config.webPort)/")
        $script:httpListener.Start()
        $script:httpRunning = $true
        Write-Log "Listener HTTP activo en puerto $($config.webPort)" "OK"

        # El script del listener corre en su propio runspace via BeginInvoke.
        # Todos los datos que necesita se pasan por AddArgument (ver mas abajo).
        [powershell]::Create().AddScript({
            param($listener, $dlFolder, $apiKey, $pq, $sl, $logFile)

            # Escritura de log desde el runspace: Add-Content es thread-safe por
            # defecto en .NET (usa FileShare.ReadWrite + append), suficiente aqui.
            function Write-ListenerLog {
                param([string]$msg, [string]$lvl = "INFO")
                $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$lvl] [HTTP] $msg"
                try { Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 } catch { }
            }

            # Limite de tamano para cuerpos JSON de /print y /skip (1 MB)
            $maxJsonBytes = 1MB
            # Limite para /print/file (50 MB)
            $maxUploadBytes = 50MB

            while ($listener.IsListening) {
                $ctx  = $null
                $req  = $null
                $resp = $null
                try {
                    $ctx  = $listener.GetContext()
                    $req  = $ctx.Request
                    $resp = $ctx.Response
                } catch [System.Net.HttpListenerException] {
                    # El listener fue detenido (shutdown normal): salir sin ruido.
                    break
                } catch [System.ObjectDisposedException] {
                    break
                } catch {
                    Write-ListenerLog "Error obteniendo contexto: $_" "ERROR"
                    Start-Sleep -Milliseconds 200
                    continue
                }

                try {
                    # GET / - Dashboard web
                    if ($req.HttpMethod -eq "GET" -and $req.Url.AbsolutePath -eq "/") {
                        $pqRows = if ($pq.Count) { ($pq.ToArray() | ForEach-Object { "<div class='ok'>$_</div>" }) -join "" } else { "<div class='empty'>(vacia)</div>" }
                        $slRows = if ($sl.Count) { ($sl.ToArray() | ForEach-Object { "<div class='skip'>$_</div>" }) -join "" } else { "<div class='empty'>(vacia)</div>" }
                        $html = @"
<!DOCTYPE html>
<html lang="es"><head><meta charset="UTF-8"><meta http-equiv="refresh" content="5">
<title>LidaPrint</title>
<style>
body{font-family:'Segoe UI',sans-serif;background:#1e1e2e;color:#cdd6f4;padding:24px;max-width:720px;margin:auto}
h1{color:#89b4fa;font-size:20px}h3{color:#a6adc8;margin-top:24px;font-size:14px}
.box{background:#313244;padding:12px;border-radius:8px;font-family:Consolas,monospace;font-size:13px}
.ok{color:#a6e3a1}.skip{color:#f38ba8}.empty{color:#6c7086;font-style:italic}
.foot{color:#6c7086;font-size:11px;margin-top:24px}
</style></head><body>
<h1>LidaPrint &mdash; Estado</h1>
<h3>Cola de impresion ($($pq.Count))</h3><div class='box'>$pqRows</div>
<h3>Omitidos ($($sl.Count))</h3><div class='box'>$slRows</div>
<div class='foot'>Auto-refresco cada 5s</div>
</body></html>
"@
                        $body = [System.Text.Encoding]::UTF8.GetBytes($html)
                        $resp.ContentType = "text/html; charset=utf-8"
                        $resp.ContentLength64 = $body.Length
                        $resp.OutputStream.Write($body, 0, $body.Length)
                        continue
                    }

                    # GET /print/status
                    if ($req.HttpMethod -eq "GET" -and $req.Url.AbsolutePath -eq "/print/status") {
                        $statusObj = [PSCustomObject]@{
                            status = "ok"
                            printQueue = @($pq.ToArray())
                            skipList = @($sl.ToArray())
                        }
                        $body = [System.Text.Encoding]::UTF8.GetBytes(($statusObj | ConvertTo-Json -Compress))
                        $resp.ContentType = "application/json"
                        $resp.ContentLength64 = $body.Length
                        $resp.OutputStream.Write($body, 0, $body.Length)
                        continue
                    }

                    if ($req.HttpMethod -ne "POST") {
                        $resp.StatusCode = 405; continue
                    }

                    if ($apiKey -and $req.Headers["X-Api-Key"] -ne $apiKey) {
                        $body = [System.Text.Encoding]::UTF8.GetBytes('{"error":"unauthorized"}')
                        $resp.StatusCode = 401; $resp.ContentType = "application/json"
                        $resp.ContentLength64 = $body.Length; $resp.OutputStream.Write($body, 0, $body.Length)
                        continue
                    }

                    # POST /print - Agregar archivo(s) a la cola de impresion
                    if ($req.Url.AbsolutePath -eq "/print") {
                        # Rechazar cuerpos demasiado grandes antes de leer
                        if ($req.ContentLength64 -lt 0 -or $req.ContentLength64 -gt $maxJsonBytes) {
                            $code = if ($req.ContentLength64 -lt 0) { 411 } else { 413 }
                            $errMsg = if ($req.ContentLength64 -lt 0) { '{"error":"length required"}' } else { '{"error":"body too large"}' }
                            $body = [System.Text.Encoding]::UTF8.GetBytes($errMsg)
                            $resp.StatusCode = $code; $resp.ContentType = "application/json"
                            $resp.ContentLength64 = $body.Length; $resp.OutputStream.Write($body, 0, $body.Length)
                            continue
                        }
                        $reader = New-Object System.IO.StreamReader($req.InputStream)
                        $rawBody = $reader.ReadToEnd(); $reader.Close()

                        $json = $null
                        try { $json = $rawBody | ConvertFrom-Json } catch {
                            $body = [System.Text.Encoding]::UTF8.GetBytes('{"error":"invalid JSON"}')
                            $resp.StatusCode = 400; $resp.ContentType = "application/json"
                            $resp.ContentLength64 = $body.Length; $resp.OutputStream.Write($body, 0, $body.Length)
                            continue
                        }

                        $added = @()
                        $files = @()
                        if ($json.filename)  { $files = @($json.filename) }
                        elseif ($json.filenames) { $files = @($json.filenames) }

                        foreach ($fn in $files) {
                            # Validar que el item sea un string no vacio
                            if (-not ($fn -is [string]) -or $fn.Trim() -eq "") { continue }
                            if (-not $fn.EndsWith(".pdf")) { $fn += ".pdf" }
                            if ($fn -notin $pq.ToArray()) {
                                [void]$pq.Add($fn)
                                $added += $fn
                                if ($fn -in $sl.ToArray()) { $sl.Remove($fn) }
                            }
                        }

                        $result = [PSCustomObject]@{
                            ok = $true
                            added = $added
                            printQueue = @($pq.ToArray())
                        }
                        $body = [System.Text.Encoding]::UTF8.GetBytes(($result | ConvertTo-Json -Compress))
                        $resp.ContentType = "application/json"; $resp.ContentLength64 = $body.Length
                        $resp.OutputStream.Write($body, 0, $body.Length)
                        continue
                    }

                    # POST /skip - Marcar archivo(s) para NO imprimir
                    if ($req.Url.AbsolutePath -eq "/skip") {
                        if ($req.ContentLength64 -lt 0 -or $req.ContentLength64 -gt $maxJsonBytes) {
                            $code = if ($req.ContentLength64 -lt 0) { 411 } else { 413 }
                            $errMsg = if ($req.ContentLength64 -lt 0) { '{"error":"length required"}' } else { '{"error":"body too large"}' }
                            $body = [System.Text.Encoding]::UTF8.GetBytes($errMsg)
                            $resp.StatusCode = $code; $resp.ContentType = "application/json"
                            $resp.ContentLength64 = $body.Length; $resp.OutputStream.Write($body, 0, $body.Length)
                            continue
                        }
                        $reader = New-Object System.IO.StreamReader($req.InputStream)
                        $rawBody = $reader.ReadToEnd(); $reader.Close()

                        $json = $null
                        try { $json = $rawBody | ConvertFrom-Json } catch {
                            $body = [System.Text.Encoding]::UTF8.GetBytes('{"error":"invalid JSON"}')
                            $resp.StatusCode = 400; $resp.ContentType = "application/json"
                            $resp.ContentLength64 = $body.Length; $resp.OutputStream.Write($body, 0, $body.Length)
                            continue
                        }

                        $added = @()
                        $files = @()
                        if ($json.filename)  { $files = @($json.filename) }
                        elseif ($json.filenames) { $files = @($json.filenames) }

                        foreach ($fn in $files) {
                            if (-not ($fn -is [string]) -or $fn.Trim() -eq "") { continue }
                            if (-not $fn.EndsWith(".pdf")) { $fn += ".pdf" }
                            if ($fn -notin $sl.ToArray()) {
                                [void]$sl.Add($fn)
                                $added += $fn
                                if ($fn -in $pq.ToArray()) { $pq.Remove($fn) }
                            }
                        }

                        $result = [PSCustomObject]@{
                            ok = $true
                            added = $added
                            skipList = @($sl.ToArray())
                        }
                        $body = [System.Text.Encoding]::UTF8.GetBytes(($result | ConvertTo-Json -Compress))
                        $resp.ContentType = "application/json"; $resp.ContentLength64 = $body.Length
                        $resp.OutputStream.Write($body, 0, $body.Length)
                        continue
                    }

                    # POST /clear - Limpiar colas
                    if ($req.Url.AbsolutePath -eq "/clear") {
                        $pq.Clear()
                        $sl.Clear()
                        $body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true,"printQueue":[],"skipList":[]}')
                        $resp.ContentType = "application/json"; $resp.ContentLength64 = $body.Length
                        $resp.OutputStream.Write($body, 0, $body.Length)
                        continue
                    }

                    # POST /print/file - Subir PDF directamente
                    if ($req.Url.AbsolutePath -eq "/print/file") {
                        # Validar ContentLength64 antes de leer: rechazar negativo o excesivo
                        if ($req.ContentLength64 -lt 0) {
                            $body = [System.Text.Encoding]::UTF8.GetBytes('{"error":"Content-Length required"}')
                            $resp.StatusCode = 411; $resp.ContentType = "application/json"
                            $resp.ContentLength64 = $body.Length; $resp.OutputStream.Write($body, 0, $body.Length)
                            continue
                        }
                        if ($req.ContentLength64 -gt $maxUploadBytes) {
                            $body = [System.Text.Encoding]::UTF8.GetBytes('{"error":"file too large"}')
                            $resp.StatusCode = 413; $resp.ContentType = "application/json"
                            $resp.ContentLength64 = $body.Length; $resp.OutputStream.Write($body, 0, $body.Length)
                            continue
                        }

                        $fileName = $req.Headers["X-Filename"]
                        if (-not $fileName) { $fileName = "web_upload_$(Get-Date -Format 'yyyyMMddHHmmss').pdf" }
                        $fileName = [System.IO.Path]::GetFileName($fileName)
                        if (-not $fileName.EndsWith(".pdf")) { $fileName += ".pdf" }
                        $destPath = Join-Path $dlFolder $fileName
                        $binReader = New-Object System.IO.BinaryReader($req.InputStream)
                        $bytes = $binReader.ReadBytes([int]$req.ContentLength64)
                        $binReader.Close()

                        # Validar magic bytes: debe empezar con "%PDF-" (0x25 50 44 46 2D)
                        if ($bytes.Length -lt 5 -or $bytes[0] -ne 0x25 -or $bytes[1] -ne 0x50 -or `
                            $bytes[2] -ne 0x44 -or $bytes[3] -ne 0x46 -or $bytes[4] -ne 0x2D) {
                            $body = [System.Text.Encoding]::UTF8.GetBytes('{"error":"not a PDF"}')
                            $resp.StatusCode = 400; $resp.ContentType = "application/json"
                            $resp.ContentLength64 = $body.Length; $resp.OutputStream.Write($body, 0, $body.Length)
                            continue
                        }

                        # Cada subida es un trabajo de impresion propio. Si ya hay un
                        # archivo con ese nombre en disco o en la cola (Odoo manda
                        # "original" y "copia" con el mismo nombre al reimprimir),
                        # NO sobreescribir ni deduplicar: renombrar con sufijo -N
                        # para que salgan las dos impresiones.
                        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
                        $n = 1
                        while ((Test-Path -LiteralPath $destPath) -or ($fileName -in $pq.ToArray())) {
                            $n++
                            $fileName = "$baseName-$n.pdf"
                            $destPath = Join-Path $dlFolder $fileName
                        }

                        [System.IO.File]::WriteAllBytes($destPath, $bytes)
                        [void]$pq.Add($fileName)

                        $body = [System.Text.Encoding]::UTF8.GetBytes("{`"ok`":true,`"file`":`"$fileName`"}")
                        $resp.ContentType = "application/json"; $resp.ContentLength64 = $body.Length
                        $resp.OutputStream.Write($body, 0, $body.Length)
                        continue
                    }

                    $resp.StatusCode = 404
                } catch {
                    Write-ListenerLog "Error procesando solicitud: $_" "ERROR"
                } finally {
                    # Garantizar que la respuesta siempre se cierra
                    if ($resp) { try { $resp.Close() } catch { } }
                }
            }
        }).AddArgument($script:httpListener).AddArgument($config.downloadFolder).AddArgument($config.webApiKey).AddArgument($script:printQueue).AddArgument($script:skipList).AddArgument((Join-Path $scriptDir "logs\PrintLog_$(Get-Date -Format 'yyyy-MM').txt")).BeginInvoke() | Out-Null

    } catch {
        Write-Log "Error iniciando listener HTTP: $_" "WARN"
        Write-Log "Prueba con: netsh http add urlacl url=http://+:$($config.webPort)/ user=$env:USERNAME" "WARN"
    }
}

function Stop-WebListener {
    if ($script:httpListener -and $script:httpListener.IsListening) {
        $script:httpListener.Stop()
        $script:httpListener.Dispose()
    }
}

# ===================== MODO NUBE (pull HTTPS a Odoo) =====================
# Odoo en un VPS no puede abrir conexiones hacia esta PC (esta detras de NAT).
# En modo Nube es LidaPrint quien sale a Odoo por HTTPS: pregunta si hay
# trabajos (poll), descarga cada PDF, lo imprime por la via normal
# (Invoke-Print) y confirma el resultado (ack). Solo este agente consulta, y
# solo con mode=cloud: los navegadores y las PCs en modo local/api no generan
# trafico de polling. Contrato completo en docs/odoo-modo-nube.md.
# URL ya normalizada a esquema://host[:puerto] por Get-CloudUrlCheck (arriba).
$script:cloudBase    = $script:cloudUrlCheck.Url + "/lidaprint/v1"
$script:cloudToken   = ([string]$config.cloudToken).Trim()
$script:cloudVersion = if ($Global:LidaPrintVersion) { [string]$Global:LidaPrintVersion } else { "dev" }
$script:cloudDefaultPoll = 3
if ($config.cloudPollSeconds) { try { $script:cloudDefaultPoll = [int]$config.cloudPollSeconds } catch { } }
if ($script:cloudDefaultPoll -lt 1)   { $script:cloudDefaultPoll = 1 }
if ($script:cloudDefaultPoll -gt 300) { $script:cloudDefaultPoll = 300 }
$script:cloudMaxPdfBytes = 50MB
$script:cloudHandled     = @{}   # id -> resultado. Un id atendido NUNCA se reimprime en esta sesion
$script:cloudAttempts    = @{}   # id -> descargas fallidas (reintento seguro: aun no se imprimio)
$script:cloudQueue       = New-Object System.Collections.ArrayList   # trabajos recibidos por atender
$script:cloudQueuedAt    = @{}   # id -> marca de Get-CloudClock al entrar a la cola local (caducidad)
$script:cloudPendingAcks = New-Object System.Collections.ArrayList   # acks que fallaron por red
# Persistidos para sobrevivir a un reinicio del monitor. El nombre no casa con
# la limpieza de arranque (lidaprint_fit_*, job-*): no se borra al arrancar.
$script:cloudAcksFile    = Join-Path $script:tempDir "cloud-pending-acks.json"
$script:cloudJobExpireMinutes = 10   # trabajo en cola local mas que esto: NO se imprime
$script:cloudAckRetrySeconds  = 30   # ack pendiente: se reintenta como mucho cada 30 s
$script:cloudAckMaxMinutes    = 60   # limite real: se descarta tras 60 minutos...
$script:cloudAckMaxAttempts   = 150  # ...red de seguridad: a 30 s no se alcanza antes de 60 min
$script:cloudClockFrequency   = [System.Diagnostics.Stopwatch]::Frequency   # marcas por segundo del reloj monotono
$script:cloudKeepAliveSeconds = 30   # lote largo: GET /ping si pasaron mas de 30 s sin contacto con Odoo
$script:cloudLastContact      = $null   # marca del ultimo poll/ping con exito o del ultimo intento de ping entre trabajos

function Get-HttpStatusCode {
    # Codigo HTTP de un error de Invoke-WebRequest, o 0 si no hubo respuesta
    # (red caida, DNS, timeout, TLS). Cierra la respuesta de error: sin eso la
    # conexion no vuelve al pool y las siguientes peticiones se cuelgan.
    param($err)
    $ex = $err.Exception
    while ($ex -and -not ($ex -is [System.Net.WebException])) { $ex = $ex.InnerException }
    if (-not $ex -or -not $ex.Response) { return 0 }
    $code = 0
    try { $code = [int]$ex.Response.StatusCode } catch { }
    try { $ex.Response.Close() } catch { }
    return $code
}

function Get-CloudErrorCode {
    # Codigo HTTP que Invoke-CloudRequest adjunta a su excepcion; 0 = sin respuesta.
    param($err)
    $ex = $err.Exception
    while ($ex) {
        if ($ex.Data -and $ex.Data.Contains("HttpStatus")) { return [int]$ex.Data["HttpStatus"] }
        $ex = $ex.InnerException
    }
    return 0
}

function Test-CloudRetryable {
    # Fallos transitorios: sin respuesta, 401 (token corregible), 408, 429 y 5xx.
    param([int]$code)
    return ($code -eq 0 -or $code -eq 401 -or $code -eq 408 -or $code -eq 429 -or $code -ge 500)
}

function Get-CloudClock {
    # Marca de tiempo para medir esperas del modo Nube. Mono: reloj monotono
    # (Stopwatch.GetTimestamp), al que no le afectan los cambios de hora de
    # Windows; con Get-Date, atrasar la hora alargaba la ventana de caducidad.
    # Wall: hora UTC, que sigue contando si el contador monotono se detiene con
    # la PC suspendida. Solo valen dentro de este proceso: no se guardan en disco.
    return @{ Mono = [System.Diagnostics.Stopwatch]::GetTimestamp(); Wall = [DateTime]::UtcNow.Ticks }
}

function Get-CloudAgeSeconds {
    # Segundos entre dos marcas de Get-CloudClock: la MAYOR de las dos medidas
    # (monotona y de pared). Asi un reloj atrasado no alarga la espera y una
    # suspension tampoco: ante la duda, un trabajo caduca antes, nunca despues.
    # Sin marca de partida (desconocida) la edad es infinita.
    param($since, $now, [long]$frequency)
    if ($null -eq $since -or $null -eq $now) { return [double]::PositiveInfinity }
    $mono = [double]0
    if ($frequency -gt 0 -and [long]$now.Mono -gt [long]$since.Mono) {
        $mono = [double]([long]$now.Mono - [long]$since.Mono) / [double]$frequency
    }
    $wall = [double]0
    if ([long]$now.Wall -gt [long]$since.Wall) {
        $wall = [double]([long]$now.Wall - [long]$since.Wall) / [double][TimeSpan]::TicksPerSecond
    }
    return [math]::Max($mono, $wall)
}

function Test-CloudJobExpired {
    # Caducidad local: True si el trabajo lleva $expireMinutes o mas en la cola.
    param($queuedAt, $now, [long]$frequency, [int]$expireMinutes)
    return ((Get-CloudAgeSeconds $queuedAt $now $frequency) -ge ($expireMinutes * 60))
}

function Test-CloudKeepAliveDue {
    # True si pasaron MAS de $seconds desde el ultimo contacto con Odoo.
    param($lastContact, $now, [long]$frequency, [int]$seconds)
    return ((Get-CloudAgeSeconds $lastContact $now $frequency) -gt $seconds)
}

function Invoke-CloudRequest {
    # Peticion a {cloudUrl}/lidaprint/v1{Path}. Devuelve el JSON ya parseado
    # ($null con -OutFile). Ante cualquier fallo lanza una excepcion con el
    # codigo HTTP en Data["HttpStatus"] (0 = sin respuesta), que se conserva
    # aunque el error se relance.
    param(
        [string]$Method,
        [string]$Path,
        $Body = $null,
        [int]$TimeoutSec = 15,
        [string]$OutFile = ""
    )
    $req = @{
        Uri             = $script:cloudBase + $Path
        Method          = $Method
        Headers         = @{ Authorization = "Bearer $($script:cloudToken)" }
        UserAgent       = "LidaPrint/$($script:cloudVersion)"
        UseBasicParsing = $true
        TimeoutSec      = $TimeoutSec
        ErrorAction     = "Stop"
    }
    if ($null -ne $Body) {
        # Bytes UTF-8 explicitos: PS 5.1 codificaria un string como ISO-8859-1.
        $req.Body = [System.Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Compress))
        $req.ContentType = "application/json; charset=utf-8"
    }
    if ($OutFile) { $req.OutFile = $OutFile }
    $resp = $null
    try {
        $resp = Invoke-WebRequest @req
    } catch {
        $code = Get-HttpStatusCode $_
        $msg = if ($code) { "HTTP $code" } else { $_.Exception.Message }
        $ex = New-Object System.Exception($msg)
        $ex.Data["HttpStatus"] = $code
        throw $ex
    }
    if ($OutFile) { return $null }
    # Decodificar a mano como UTF-8: sin charset en el Content-Type, PS 5.1
    # asume ISO-8859-1 y rompe los acentos (p. ej. el nombre del equipo).
    $text = [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
    if (-not $text.Trim()) { return $null }
    try {
        return ($text | ConvertFrom-Json)
    } catch {
        $ex = New-Object System.Exception("Odoo respondio algo que no es JSON (revisa la URL y que el modulo este instalado)")
        $ex.Data["HttpStatus"] = 0
        throw $ex
    }
}

function New-CloudAckBody {
    param([string]$status, [string]$message)
    $b = @{ status = $status }
    if ($status -eq "error") {
        if ($message.Length -gt 500) { $message = $message.Substring(0, 500) }
        $b.message = $message
    }
    return $b
}

function Save-PendingCloudAcks {
    # Persiste los acks pendientes en temp\cloud-pending-acks.json: un reinicio
    # del monitor (Guardar en el Configurator lo reinicia) no pierde el
    # resultado de trabajos que SI se imprimieron.
    try {
        if ($script:cloudPendingAcks.Count -eq 0) {
            Remove-Item -LiteralPath $script:cloudAcksFile -Force -ErrorAction SilentlyContinue
            return
        }
        ConvertTo-Json -InputObject @($script:cloudPendingAcks.ToArray()) -Depth 3 |
            Set-Content -LiteralPath $script:cloudAcksFile -Encoding UTF8
    } catch {
        Write-Log "Nube: no se pudieron guardar las confirmaciones pendientes: $($_.Exception.Message)" "WARN"
    }
}

function Import-PendingCloudAcks {
    # Recupera los acks pendientes de la sesion anterior. Sus trabajos cuentan
    # como atendidos: si Odoo los reenviara, no se reimprimen.
    if (-not (Test-Path -LiteralPath $script:cloudAcksFile)) { return }
    try {
        $items = Get-Content -LiteralPath $script:cloudAcksFile -Raw | ConvertFrom-Json
        foreach ($it in @($items)) {
            if (-not $it) { continue }
            $id = [string]$it.id
            $st = [string]$it.status
            if ($id -notmatch '^\d+$' -or ($st -ne "done" -and $st -ne "error")) { continue }
            $ticks = [long]0
            try { $ticks = [long]$it.firstTicks } catch { }
            if ($ticks -le 0) { $ticks = (Get-Date).ToUniversalTime().Ticks }
            $att = 0
            try { $att = [int]$it.attempts } catch { }
            # lastTicks falta en archivos viejos: 0 = se puede reintentar ya.
            $last = [long]0
            try { $last = [long]$it.lastTicks } catch { }
            [void]$script:cloudPendingAcks.Add(@{ id = $id; status = $st; message = [string]$it.message; attempts = $att; firstTicks = $ticks; lastTicks = $last })
            $script:cloudHandled[$id] = @{ status = $st; message = [string]$it.message }
        }
        if ($script:cloudPendingAcks.Count -gt 0) {
            Write-Log "Nube: $($script:cloudPendingAcks.Count) confirmacion(es) pendiente(s) recuperada(s) de la sesion anterior" "INFO"
        }
    } catch {
        Write-Log "Nube: no se pudieron leer las confirmaciones pendientes de $($script:cloudAcksFile): $($_.Exception.Message)" "WARN"
    }
}

function Remove-PendingCloudAck {
    # Quita el ack pendiente de ese trabajo. Devuelve $true si habia uno.
    param([string]$id)
    $removed = $false
    foreach ($old in @($script:cloudPendingAcks.ToArray())) {
        if ($old.id -eq $id) { $script:cloudPendingAcks.Remove($old); $removed = $true }
    }
    return $removed
}

function Add-PendingCloudAck {
    # Un solo ack pendiente por trabajo: el ultimo resultado manda.
    param([string]$id, [string]$status, [string]$message)
    [void](Remove-PendingCloudAck $id)
    $now = (Get-Date).ToUniversalTime().Ticks
    [void]$script:cloudPendingAcks.Add(@{ id = $id; status = $status; message = $message; attempts = 1; firstTicks = $now; lastTicks = $now })
    Save-PendingCloudAcks
}

function Send-CloudAck {
    # Confirma a Odoo el resultado de un trabajo. El ack es idempotente del lado
    # del servidor: reenviarlo es seguro. Si falla de forma transitoria queda
    # pendiente y se reintenta antes del proximo poll.
    param([string]$id, [string]$status, [string]$message = "")
    try {
        [void](Invoke-CloudRequest -Method "POST" -Path "/job/$id/ack" -Body (New-CloudAckBody $status $message))
        if (Remove-PendingCloudAck $id) { Save-PendingCloudAcks }
        return $true
    } catch {
        $code = Get-CloudErrorCode $_
        if (Test-CloudRetryable $code) {
            Add-PendingCloudAck $id $status $message
            Write-Log "Nube: no se pudo confirmar el trabajo #$id a Odoo ($($_.Exception.Message)); se reintentara" "WARN"
        } else {
            Write-Log "Nube: Odoo rechazo la confirmacion del trabajo #$id (HTTP $code); se descarta" "WARN"
        }
        return $false
    }
}

function Send-PendingCloudAcks {
    # Reintenta los acks pendientes SIN bloquear nunca el poll: no lanza. Cada
    # ack se reintenta como mucho cada 30 s (el poll puede correr cada 1-3 s)
    # y se descarta a los 60 minutos; el tope de intentos es solo una red de
    # seguridad. Ante el primer fallo transitorio deja el resto para el
    # proximo ciclo (si la red esta caida, el poll fallara igual).
    $changed = $false
    $skipRest = $false
    $nowTicks = (Get-Date).ToUniversalTime().Ticks
    $retryTicks = [long]$script:cloudAckRetrySeconds * [TimeSpan]::TicksPerSecond
    foreach ($ack in @($script:cloudPendingAcks.ToArray())) {
        $ageMin = [int][math]::Floor([double]($nowTicks - [long]$ack.firstTicks) / [double][TimeSpan]::TicksPerMinute)
        if ([int]$ack.attempts -ge $script:cloudAckMaxAttempts -or $ageMin -ge $script:cloudAckMaxMinutes) {
            $script:cloudPendingAcks.Remove($ack); $changed = $true
            Write-Log "Nube: se descarta la confirmacion ($($ack.status)) del trabajo #$($ack.id) tras $($ack.attempts) intentos / $ageMin min sin respuesta de Odoo; revise ese trabajo en Odoo" "WARN"
            continue
        }
        if ($skipRest) { continue }
        # Con la hora de Windows atrasada, ahora < lastTicks: reintentar ya en
        # vez de esperar a que el reloj alcance la marca vieja.
        if ($nowTicks -ge [long]$ack.lastTicks -and ($nowTicks - [long]$ack.lastTicks) -lt $retryTicks) { continue }
        $ack.lastTicks = $nowTicks; $changed = $true
        try {
            [void](Invoke-CloudRequest -Method "POST" -Path "/job/$($ack.id)/ack" -Body (New-CloudAckBody $ack.status $ack.message))
            $script:cloudPendingAcks.Remove($ack); $changed = $true
            Write-Log "Nube: confirmacion pendiente del trabajo #$($ack.id) entregada ($($ack.status))" "INFO"
        } catch {
            $code = Get-CloudErrorCode $_
            if (Test-CloudRetryable $code) {
                $ack.attempts = [int]$ack.attempts + 1; $changed = $true
                $skipRest = $true
            } else {
                $script:cloudPendingAcks.Remove($ack); $changed = $true
                Write-Log "Nube: Odoo rechazo la confirmacion pendiente del trabajo #$($ack.id) (HTTP $code); se descarta" "WARN"
            }
        }
    }
    if ($changed) { Save-PendingCloudAcks }
}

function Complete-CloudJob {
    # Registra el resultado final del trabajo y lo confirma a Odoo.
    param([string]$id, [string]$status, [string]$message = "")
    $script:cloudHandled[$id] = @{ status = $status; message = $message }
    $script:cloudAttempts.Remove($id)
    $script:cloudQueuedAt.Remove($id)
    [void](Send-CloudAck $id $status $message)
}

function Complete-ExpiredCloudJob {
    # Caducidad (seguridad fiscal): un trabajo que espero en la cola local 10
    # minutos o mas (Odoo caido o sin red) ya NO se imprime. Mientras tanto el
    # cron de Odoo (15 min, nunca menos de 12) pudo pasarlo a error y el
    # operador reimprimirlo: imprimirlo ahora duplicaria la factura. Se
    # comprueba antes de descargar y otra vez justo antes de imprimir.
    # Devuelve $true si caduco (ya confirmado a Odoo como error).
    #
    # La cola local y sus marcas viven solo en memoria. Tras reiniciar el
    # monitor no queda nada que caducar: esos trabajos siguen en "printing" en
    # Odoo, el poll ya no los devuelve (solo reclama pendientes) y el cron los
    # pasa a error. Una marca de Get-CloudClock no vale en otro proceso: si la
    # cola llegara a persistirse, un trabajo sin marca conocida cuenta como
    # caducado (lo conservador es no imprimir algo que pudo quedar viejo).
    param([string]$id, [string]$name)
    $now = Get-CloudClock
    $queuedAt = $null
    if ($script:cloudQueuedAt.ContainsKey($id)) { $queuedAt = $script:cloudQueuedAt[$id] }
    if (-not (Test-CloudJobExpired $queuedAt $now $script:cloudClockFrequency $script:cloudJobExpireMinutes)) { return $false }
    if ($null -eq $queuedAt) {
        $why = "sin hora de recepcion conocida"
    } else {
        $mins = [int][math]::Floor((Get-CloudAgeSeconds $queuedAt $now $script:cloudClockFrequency) / 60)
        $why = "recibido hace $mins min sin poder imprimirse"
    }
    Write-Log "Nube: trabajo #$id ($name) caducado: $why; NO se imprime" "ERROR"
    Complete-CloudJob $id "error" "Trabajo caducado: $why; verifique en Odoo antes de reimprimir"
    return $true
}

function Invoke-CloudJob {
    # Descarga, valida, imprime y confirma UN trabajo. Si la descarga falla de
    # forma transitoria LANZA: el trabajo sigue en la cola local y se reintenta
    # en el proximo ciclo (hasta 5 veces; seguro porque aun no se imprimio).
    param($job)
    $id = [string]$job.id
    if ($id -notmatch '^\d+$') {
        Write-Log "Nube: trabajo con id invalido ('$id'), se ignora" "WARN"
        return
    }
    if ($script:cloudHandled.ContainsKey($id)) {
        # Ya atendido en esta sesion: jamas se reimprime. Se reenvia el
        # resultado conocido para que Odoo no lo deje colgado en "printing".
        Write-Log "Nube: el trabajo #$id ya fue atendido en esta sesion; NO se reimprime" "WARN"
        $prev = $script:cloudHandled[$id]
        if ($prev.status -eq "done" -or $prev.status -eq "error") {
            [void](Send-CloudAck $id $prev.status $prev.message)
        } else {
            Complete-CloudJob $id "error" "LidaPrint no pudo confirmar si se imprimio; revise el papel antes de reimprimir"
        }
        return
    }

    # Nombre saneado: sin rutas ni caracteres invalidos (mismas reglas que /print/file)
    $name = ""
    try { $name = [System.IO.Path]::GetFileName(([string]$job.filename -replace '[<>|"*?\x00-\x1f]', '_')) } catch { $name = "" }
    if (-not $name) { $name = "trabajo.pdf" }
    if ($name.Length -gt 100) { $name = $name.Substring($name.Length - 100) }
    if (-not $name.ToLower().EndsWith(".pdf")) { $name += ".pdf" }
    $dest = Join-Path $script:tempDir ("job-$id-$name")

    # Caducidad, primera comprobacion: ni siquiera se descarga.
    if (Complete-ExpiredCloudJob $id $name) { return }

    $size = [long]0
    try { $size = [long]$job.size } catch { }
    if (-not $script:cloudAttempts.ContainsKey($id)) {
        Write-Log "Nube: trabajo #$id recibido ($name, $size bytes)" "INFO"
    }
    if ($size -gt $script:cloudMaxPdfBytes) {
        Write-Log "Nube: trabajo #$id rechazado: $size bytes supera el limite de 50 MB ($name)" "ERROR"
        Complete-CloudJob $id "error" "PDF demasiado grande (> 50 MB)"
        return
    }

    try {
        [void](Invoke-CloudRequest -Method "GET" -Path "/job/$id/pdf" -TimeoutSec 60 -OutFile $dest)
    } catch {
        $err = $_
        Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
        $code = Get-CloudErrorCode $err
        $detail = $err.Exception.Message
        if (Test-CloudRetryable $code) {
            $n = 1
            if ($script:cloudAttempts.ContainsKey($id)) { $n = [int]$script:cloudAttempts[$id] + 1 }
            $script:cloudAttempts[$id] = $n
            if ($n -lt 5) {
                Write-Log "Nube: trabajo #${id}: fallo la descarga del PDF ($detail), intento $n/5; se reintenta" "WARN"
                # Marca para Invoke-CloudLoop: es un reintento de descarga, no
                # una caida de la conexion (no cambia el estado ni lo loguea).
                $err.Exception.Data["CloudDownloadRetry"] = $true
                throw $err
            }
            Write-Log "Nube: trabajo #${id}: no se pudo descargar el PDF tras $n intentos ($detail)" "ERROR"
            Complete-CloudJob $id "error" "No se pudo descargar el PDF tras $n intentos: $detail"
            return
        }
        Write-Log "Nube: trabajo #${id}: Odoo nego la descarga del PDF ($detail)" "ERROR"
        Complete-CloudJob $id "error" "Descarga del PDF rechazada: $detail"
        return
    }

    # Validar tamano real y magic bytes "%PDF-" (0x25 50 44 46 2D)
    $len = [long]0
    $head = New-Object byte[] 5
    $read = 0
    try {
        $len = (Get-Item -LiteralPath $dest).Length
        $fs = [System.IO.File]::OpenRead($dest)
        try { $read = $fs.Read($head, 0, 5) } finally { $fs.Close() }
    } catch { $read = 0 }
    $isPdf = ($read -ge 5 -and $head[0] -eq 0x25 -and $head[1] -eq 0x50 -and $head[2] -eq 0x44 -and $head[3] -eq 0x46 -and $head[4] -eq 0x2D)
    if ($len -gt $script:cloudMaxPdfBytes -or -not $isPdf) {
        $why = if ($len -gt $script:cloudMaxPdfBytes) { "PDF demasiado grande (> 50 MB)" } else { "El archivo recibido no es un PDF" }
        Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
        Write-Log "Nube: trabajo #$id rechazado: $why ($name)" "ERROR"
        Complete-CloudJob $id "error" $why
        return
    }

    # Caducidad, segunda comprobacion, justo antes de imprimir: una descarga
    # lenta (hasta 60 s por intento) o un lote largo pudo cruzar el limite.
    if (Complete-ExpiredCloudJob $id $name) {
        Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
        return
    }

    # Atendido ANTES de imprimir: pase lo que pase despues, este id no se
    # vuelve a imprimir en esta sesion (seguridad fiscal).
    $script:cloudHandled[$id] = @{ status = "printing"; message = "" }
    $result = $null
    try {
        $result = Invoke-Print $dest
    } catch {
        $result = @{ Success = $false; Message = "Excepcion imprimiendo ${name}: $($_.Exception.Message)" }
    }
    [void](Remove-Invoice $dest)
    if ($result.Success) {
        Write-Log "Nube #${id}: $($result.Message)" "OK"
        Complete-CloudJob $id "done"
    } else {
        Write-Log "Nube #${id}: $($result.Message)" "ERROR"
        Complete-CloudJob $id "error" $result.Message
    }
}

function Invoke-CloudKeepAlive {
    # Entre dos trabajos del mismo lote. El lote (hasta 10) se atiende entero
    # antes del siguiente poll, y Odoo da por desconectado a un equipo sin
    # contacto en 60 s (columna "En linea" y aviso "no esta conectado" al
    # imprimir). Si pasaron mas de 30 s desde el ultimo contacto, GET /ping
    # actualiza last_seen sin reclamar trabajos. Un fallo no interrumpe el
    # lote: queda un WARN y se reintenta a los 30 s, no en cada trabajo.
    # Devuelve $true si el ping llego a Odoo.
    $now = Get-CloudClock
    if (-not (Test-CloudKeepAliveDue $script:cloudLastContact $now $script:cloudClockFrequency $script:cloudKeepAliveSeconds)) { return $false }
    $script:cloudLastContact = $now
    try {
        [void](Invoke-CloudRequest -Method "GET" -Path "/ping" -TimeoutSec 10)
        return $true
    } catch {
        Write-Log "Nube: no se pudo avisar a Odoo entre dos trabajos (GET /ping: $($_.Exception.Message)); se sigue con el lote" "WARN"
        return $false
    }
}

function Invoke-CloudBatch {
    # Atiende la cola local en orden, con Invoke-CloudKeepAlive entre trabajos.
    # Invoke-CloudJob lanza si una descarga fallo de forma transitoria: ese
    # trabajo queda primero en la cola y el lote sigue en el proximo ciclo.
    while ($script:cloudQueue.Count -gt 0) {
        Invoke-CloudJob $script:cloudQueue[0]
        $script:cloudQueue.RemoveAt(0)
        if ($script:cloudQueue.Count -gt 0) { [void](Invoke-CloudKeepAlive) }
    }
}

function Invoke-CloudLoop {
    # Ciclo: acks pendientes -> poll -> atender trabajos -> dormir next_poll.
    # Solo se loguean los CAMBIOS de estado de la conexion, nunca cada poll.
    $state = ""              # "", "ok", "offline", "unauthorized", "config"
    $backoff = 0
    $unauthorizedCount = 0   # 401 seguidos: 60 s de espera, 300 s desde el tercero
    $nextPoll = $script:cloudDefaultPoll
    $pollBody = @{ hostname = $env:COMPUTERNAME; version = $script:cloudVersion; printer = [string]$config.printer }
    while ($true) {
        $sleepSec = $nextPoll
        try {
            if ($script:cloudPendingAcks.Count -gt 0) { Send-PendingCloudAcks }   # nunca lanza ni bloquea el poll
            $data = Invoke-CloudRequest -Method "POST" -Path "/poll" -Body $pollBody
            $script:cloudLastContact = Get-CloudClock

            if ($state -eq "offline") { Write-Log "Conexion con Odoo restablecida" "OK" }
            elseif ($state -eq "unauthorized") { Write-Log "Odoo acepto el token de nuevo: conexion restablecida" "OK" }
            elseif ($state -eq "config") { Write-Log "Odoo responde en $($script:cloudBase): URL y base de datos resueltas, conexion restablecida" "OK" }
            elseif ($state -eq "") { Write-Log "Conectado a Odoo ($($script:cloudBase))" "OK" }
            $state = "ok"; $backoff = 0; $unauthorizedCount = 0

            # El servidor manda el intervalo; acotado a [1, 300] s.
            $nextPoll = $script:cloudDefaultPoll
            if ($data -and $null -ne $data.next_poll) {
                try { $nextPoll = [int][math]::Round([double]$data.next_poll) } catch { $nextPoll = $script:cloudDefaultPoll }
            }
            if ($nextPoll -lt 1)   { $nextPoll = 1 }
            if ($nextPoll -gt 300) { $nextPoll = 300 }
            $sleepSec = $nextPoll

            # Los que esperan reintento de descarga van primero; sin duplicados.
            if ($data -and $data.jobs) {
                foreach ($job in @($data.jobs)) {
                    $jid = [string]$job.id
                    $dup = $false
                    foreach ($q in $script:cloudQueue) { if ([string]$q.id -eq $jid) { $dup = $true } }
                    if (-not $dup) {
                        [void]$script:cloudQueue.Add($job)
                        if (-not $script:cloudQueuedAt.ContainsKey($jid)) { $script:cloudQueuedAt[$jid] = Get-CloudClock }
                    }
                }
            }
            Invoke-CloudBatch   # lanza si una descarga fallo de forma transitoria
        } catch {
            $code = Get-CloudErrorCode $_
            $isDownloadRetry = $false
            $ex = $_.Exception
            while ($ex) {
                if ($ex.Data -and $ex.Data.Contains("CloudDownloadRetry")) { $isDownloadRetry = $true; break }
                $ex = $ex.InnerException
            }
            if ($isDownloadRetry) {
                # Fallo transitorio de UNA descarga (ya logueado en
                # Invoke-CloudJob): no es un cambio de estado de la conexion.
                # Espera corta para no girar en vacio; el poll siguiente dira
                # si la conexion de verdad se perdio.
                $sleepSec = 3
            } elseif ((Get-CloudFailureKind $code) -eq "unauthorized") {
                # Equipo archivado o token revocado (o mal copiado): no martillar
                # al servidor. 60 s, y 300 s a partir del tercer 401 seguido.
                $unauthorizedCount++
                if ($state -ne "unauthorized") {
                    Write-Log "Odoo rechazo el token (HTTP 401): equipo archivado o token revocado (o mal copiado). Genera un token nuevo en Odoo y cargalo en el Configurator. Se reintenta cada 60 s (cada 300 s tras 3 rechazos seguidos)." "ERROR"
                }
                $state = "unauthorized"
                $sleepSec = if ($unauthorizedCount -ge 3) { 300 } else { 60 }
            } else {
                # Mismo backoff exponencial para todo lo demas (2, 4, 8... 60 s).
                if ($backoff -lt 1) { $backoff = 2 } else { $backoff = [math]::Min(60, $backoff * 2) }
                if ((Get-CloudFailureKind $code) -eq "config") {
                    # 404/400 del poll: la peticion no llega al modulo (URL o base
                    # de datos). Se registra una sola vez, como el 401.
                    if ($state -ne "config") {
                        Write-Log "Odoo respondio HTTP ${code} a $($script:cloudBase)/poll. $(Get-CloudConfigHint). Se reintenta con espera creciente (hasta 60 s)." "ERROR"
                    }
                    $state = "config"
                } else {
                    # Red caida, timeout, TLS o error del servidor.
                    if ($state -eq "") { Write-Log "Sin conexion con Odoo: $($_.Exception.Message)" "WARN" }
                    elseif ($state -ne "offline") { Write-Log "Conexion con Odoo perdida: $($_.Exception.Message)" "WARN" }
                    $state = "offline"
                }
                $sleepSec = $backoff
            }
        }
        Start-Sleep -Seconds $sleepSec
    }
}

# ===================== MONITOR PRINCIPAL =====================
Write-Log "========================================"
Write-Log "LidaPrint - INICIO"
Write-Log "========================================"
Write-Log "Impresora:    $($config.printer)"
Write-Log "Copias:       $($config.copies)"
Write-Log "Orientacion:  $($config.orientation)"
Write-Log "Paper Size:   $($config.paperSize)"
Write-Log "Escala:       $($config.scale)%"
Write-Log "DPI:          $($config.dpi)"
Write-Log "Margenes:     T=$($config.marginTop) B=$($config.marginBottom) L=$($config.marginLeft) R=$($config.marginRight)mm"
Write-Log "Forma cont.:  $($config.continuousForm) (largo=$($config.formLength)mm)"
Write-Log "Descargas:    $($config.downloadFolder)"
Write-Log "Patron:       $($config.invoicePattern) (activo: $($config.usePattern))"
Write-Log "Motor:        Ghostscript ($gsResolved)"
Write-Log "Web HTTP:     $($config.webEnabled) (puerto $($config.webPort))"
Write-Log "Modo:         $($script:runMode)"
if ($script:runMode -eq "cloud") {
    Write-Log "Nube:         $($script:cloudBase) (cada $($script:cloudDefaultPoll)s salvo que Odoo indique otro intervalo)"
}
Write-Log "========================================"

if ($script:runMode -eq "cloud") {
    # MODO NUBE: ni listener HTTP ni carpeta de descargas. Solo conexiones
    # salientes a Odoo por HTTPS.
    # TLS 1.2: PS 5.1 sobre .NET viejo puede traer solo SSL3/TLS 1.0. Si el
    # valor es SystemDefault (0) no se toca: el sistema ya negocia 1.2/1.3 y
    # sumarle Tls12 desactivaria TLS 1.3. Keep-alive queda activo.
    $sp = [Net.ServicePointManager]::SecurityProtocol
    if ([int]$sp -ne 0) { [Net.ServicePointManager]::SecurityProtocol = $sp -bor [Net.SecurityProtocolType]::Tls12 }
    # Sin "Expect: 100-continue": ahorra una ida y vuelta en cada poll.
    [Net.ServicePointManager]::Expect100Continue = $false
    # Sin barra de progreso: en el exe (-noConsole) apareceria una ventana en cada peticion.
    $ProgressPreference = "SilentlyContinue"
    # URL con ruta (/odoo, /web...) o http:// en la red local: se usa igual,
    # pero queda constancia (la ruta ya se quito al normalizar).
    if ($script:cloudUrlCheck.Notice) { Write-Log "Nube: $($script:cloudUrlCheck.Notice) Corrige la URL en el Configurator y Guarda." "WARN" }
    if ($script:cloudUrlCheck.Warning) { Write-Log "Nube: $($script:cloudUrlCheck.Warning)" "WARN" }
    # Acks de trabajos que se imprimieron antes de un reinicio y no llegaron a confirmarse.
    Import-PendingCloudAcks
    Write-Log "Monitor activo en modo Nube. Esperando trabajos de Odoo..." "OK"
    Invoke-CloudLoop
    # Invoke-CloudLoop no retorna. Si lo hiciera, salir: el loop de abajo
    # imprimiria la carpeta de descargas, cosa que el modo Nube no debe hacer.
    exit 1
}

# Iniciar listener web
Start-WebListener

$seenFiles = @{}
$apiWaitLogged = @{}  # en modo API, loguear una sola vez por archivo que espera orden

Write-Log "Monitor activo (polling 1s). Esperando facturas..." "OK"

try {
    while ($true) {
        try {
            # Escanear carpeta
            $allPdf = Get-ChildItem -Path $config.downloadFolder -Filter "*.pdf" -File -ErrorAction SilentlyContinue
            foreach ($file in $allPdf) {
                $fp = $file.FullName
                $fn = $file.Name
                if ($seenFiles.ContainsKey($fp)) { continue }

                $shouldProcess = $false

                if ($script:runMode -eq "api") {
                    # MODO API: Solo imprimir archivos en la printQueue
                    if ($fn -in $script:printQueue.ToArray()) {
                        $shouldProcess = $true
                        $script:printQueue.Remove($fn)
                        Write-Log "API: $fn en cola de impresion" "OK"
                    } elseif ($fn -in $script:skipList.ToArray()) {
                        Write-Log "API: $fn en lista de omitidos, ignorando" "INFO"
                        $script:skipList.Remove($fn)
                    } else {
                        # No esta en ninguna cola: se ignora POR DISENO (Odoo decide).
                        # Loguear una vez por archivo para que sea visible en el log.
                        if (-not $apiWaitLogged.ContainsKey($fn)) {
                            $apiWaitLogged[$fn] = $true
                            Write-Log "API activa: '$fn' descargado pero SIN orden de impresion de Odoo. En modo API las descargas locales NO se imprimen solas (usa POST /print, o desactiva la API para modo local)." "WARN"
                        }
                    }
                } else {
                    # MODO LOCAL: Usar patron si esta habilitado
                    if ($config.usePattern) {
                        if ($fn -match $config.invoicePattern) {
                            $shouldProcess = $true
                        }
                    } else {
                        # Sin patron, imprimir todo PDF que aparezca
                        $shouldProcess = $true
                    }
                }

                if ($shouldProcess) {
                    $seenFiles[$fp] = $true
                    Process-InvoiceFile $fp
                } elseif ($script:runMode -ne "api") {
                    # En modo local, marcar como visto para no reprocesar.
                    # Loguear el motivo: un archivo ignorado en silencio es indepurable.
                    Write-Log "Ignorado (no coincide con el patron '$($config.invoicePattern)'): $fn" "INFO"
                    $seenFiles[$fp] = $true
                }
                # En modo API, no marcar si no estaba en cola - se reintentara en el proximo poll
            }

            # Limpiar tracking de archivos que ya no existen
            $toRemove = @()
            foreach ($key in $seenFiles.Keys) {
                if (-not (Test-Path -LiteralPath $key)) { $toRemove += $key }
            }
            foreach ($key in $toRemove) { $seenFiles.Remove($key) }

        } catch {
            Write-Log "Error en monitor: $_" "ERROR"
        }
        Start-Sleep -Seconds 1
    }
} finally {
    Stop-WebListener
}
