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
if (-not (Test-Path $config.downloadFolder)) {
    Write-BootLog "Carpeta de descargas no encontrada: $($config.downloadFolder) - abortando" "ERROR"
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
    $paper = Get-PaperPoints
    $wPts = $paper[0]; $hPts = $paper[1]
    if ($config.orientation -eq "landscape") { $tmp = $wPts; $wPts = $hPts; $hPts = $tmp }

    $resized = Join-Path $script:tempDir ("lidaprint_fit_" + [System.IO.Path]::GetFileName($filePath))
    $fitArgs = "-dBATCH -dNOPAUSE -dQUIET -sDEVICE=pdfwrite -dDEVICEWIDTHPOINTS=$wPts -dDEVICEHEIGHTPOINTS=$hPts -dFIXEDMEDIA -dFitPage `"-sOutputFile=$resized`" -f `"$filePath`""
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
        $pageCmd = "<< /BeginPage { pop $offX $offY translate $userScale $userScale scale } >> setpagedevice"
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
    # Via ESC/POS raster: rasteriza el PDF a un bitmap monocromo del ancho
    # imprimible y lo manda como comandos de imagen (ESC *) en bytes crudos.
    # Para ticketeras 9-agujas / termicas cuyo driver no acepta impresion GDI
    # por el puerto disponible (p. ej. EPSON TM-U220 por adaptador CH340).
    #
    # Densidades calibradas por impresora (pestana Calibracion del Configurator):
    #   escposWidthMm : ancho imprimible real (barra de 400 puntos medida).
    #   escposHdpi    : puntos por pulgada horizontal (200 puntos / mm medidos).
    #   escposVdpi    : densidad vertical de la banda de 8 puntos.
    param([string]$filePath)
    $fileName = Split-Path $filePath -Leaf
    $widthMm = if ($config.escposWidthMm) { [double]$config.escposWidthMm } else { 64 }
    $hdpi    = if ($config.escposHdpi)    { [double]$config.escposHdpi }    else { 158.75 }
    $vdpi    = if ($config.escposVdpi)    { [double]$config.escposVdpi }    else { 72 }
    $m       = if ($null -ne $config.escposDensity) { [int]$config.escposDensity } else { 1 }

    try {
        # 1) Sonda de aspecto de pagina (render cuadrado a baja resolucion).
        $probe = Join-Path $script:tempDir ("escpos_probe_" + [System.IO.Path]::GetFileNameWithoutExtension($filePath) + ".pbm")
        $probeArgs = "-dBATCH -dNOPAUSE -dQUIET -sDEVICE=pbmraw -r24 `"-sOutputFile=$probe`" -f `"$filePath`""
        Invoke-ProcessCapture $gsResolved $probeArgs | Out-Null
        if (-not (Test-Path $probe)) { return @{ Success = $false; Message = "ESC/POS: no se pudo leer el PDF: $fileName" } }
        $pb = [System.IO.File]::ReadAllBytes($probe)
        $pi = 2
        $pw = [int](Read-PbmToken $pb ([ref]$pi)); $ph = [int](Read-PbmToken $pb ([ref]$pi))
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        $aspect = $ph / $pw

        # 2) Render final: ancho fijo (imprimible), alto por aspecto, densidades
        #    H/V separadas para que la proporcion en papel sea correcta.
        $wPts = [math]::Round($widthMm * 2.83465, 2)
        $hPts = [math]::Round($wPts * $aspect, 2)
        $pbm = Join-Path $script:tempDir ("escpos_" + [System.IO.Path]::GetFileNameWithoutExtension($filePath) + ".pbm")
        Remove-Item -LiteralPath $pbm -Force -ErrorAction SilentlyContinue
        $rArgs = "-dBATCH -dNOPAUSE -dQUIET -sDEVICE=pbmraw -dFIXEDMEDIA -dPDFFitPage " +
                 "-dDEVICEWIDTHPOINTS=$wPts -dDEVICEHEIGHTPOINTS=$hPts -r$hdpi" + "x" + "$vdpi " +
                 "`"-sOutputFile=$pbm`" -f `"$filePath`""
        $rc = Invoke-ProcessCapture $gsResolved $rArgs
        if (-not (Test-Path $pbm)) { return @{ Success = $false; Message = "ESC/POS: fallo el rasterizado (gs $rc): $fileName" } }

        # 3) Parsear PBM (P4 binario) y codificar a ESC * en bandas de 8 puntos.
        $raw = [System.IO.File]::ReadAllBytes($pbm)
        $idx = 2
        $w = [int](Read-PbmToken $raw ([ref]$idx)); $h = [int](Read-PbmToken $raw ([ref]$idx)); $idx++
        $rowBytes = [int][math]::Ceiling($w / 8.0); $pixStart = $idx
        $lineSpacing = [int][math]::Round(8 * 216 / $vdpi)

        $out = New-Object System.Collections.Generic.List[byte]
        $ESC = 0x1B; $LF = 0x0A
        $out.Add($ESC); $out.Add(0x40)                            # ESC @ init
        $out.Add($ESC); $out.Add(0x33); $out.Add([byte]$lineSpacing)  # ESC 3 n interlineado
        $nL = $w -band 0xFF; $nH = ($w -shr 8) -band 0xFF
        $bands = [int][math]::Ceiling($h / 8.0)
        for ($band = 0; $band -lt $bands; $band++) {
            $out.Add($ESC); $out.Add(0x2A); $out.Add([byte]$m); $out.Add([byte]$nL); $out.Add([byte]$nH)
            for ($x = 0; $x -lt $w; $x++) {
                $bv = 0
                for ($k = 0; $k -lt 8; $k++) {
                    $r = $band * 8 + $k
                    if ($r -lt $h) {
                        $bi = $pixStart + $r * $rowBytes + [int][math]::Floor($x / 8)
                        if ($bi -lt $raw.Length -and ((($raw[$bi] -shr (7 - ($x % 8))) -band 1) -eq 1)) {
                            $bv = $bv -bor (1 -shl (7 - $k))
                        }
                    }
                }
                $out.Add([byte]$bv)
            }
            $out.Add($LF)
        }
        1..6 | ForEach-Object { $out.Add($LF) }                   # avanzar para cortar
        Remove-Item -LiteralPath $pbm -Force -ErrorAction SilentlyContinue

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
    if (-not $config.webEnabled) { return }
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

                        [System.IO.File]::WriteAllBytes($destPath, $bytes)

                        if ($fileName -notin $pq.ToArray()) {
                            [void]$pq.Add($fileName)
                        }

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
Write-Log "========================================"

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

                if ($config.webEnabled) {
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
                } elseif (-not $config.webEnabled) {
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
