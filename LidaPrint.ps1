<#
.SYNOPSIS
    LidaPrint - Monitor de impresion automatica de facturas Odoo.
.DESCRIPTION
    Vigila carpeta local y/o recibe archivos via HTTP.
    Imprime con SumatraPDF y elimina el archivo.
    La API permite a Odoo controlar que archivos se imprimen.
.NOTES
    Se ejecuta via Task Scheduler al iniciar sesion.
#>

$ErrorActionPreference = "Stop"

# ===================== CARGAR CONFIGURACION =====================
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
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

# Ocultar la propia ventana de consola. La tarea lanza con -WindowStyle Minimized
# porque Hidden puede colgar el arranque en Windows 11 (el host de consola por
# defecto, Windows Terminal, tiene problemas creando consolas ocultas en segundo
# plano). Arrancamos visibles-minimizados (seguro) y nos escondemos aca.
try {
    $sig = '[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);'
    $win32 = Add-Type -MemberDefinition $sig -Name "Win32ShowWindow" -Namespace "Native" -PassThru
    $hwnd = (Get-Process -Id $PID).MainWindowHandle
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

$sumatraResolved = Resolve-ToolPath $config.sumatraPath @(
    (Join-Path $scriptDir "bin\SumatraPDF.exe"),
    "$env:LOCALAPPDATA\SumatraPDF\SumatraPDF.exe",
    "$env:ProgramFiles\SumatraPDF\SumatraPDF.exe",
    "${env:ProgramFiles(x86)}\SumatraPDF\SumatraPDF.exe"
)

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
if (-not $sumatraResolved -and -not $gsResolved) {
    Write-BootLog "Ni SumatraPDF ni Ghostscript encontrados - abortando. Re-ejecuta el instalador." "ERROR"
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
    switch ($level) {
        "ERROR" { Write-Host $line -ForegroundColor Red }
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        "OK"    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line -ForegroundColor Gray }
    }
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

function Invoke-PrintSumatra {
    param([string]$filePath)
    $fileName = Split-Path $filePath -Leaf
    $settings = @()
    $settings += "$($config.copies)x"
    if ($config.orientation) { $settings += $config.orientation }

    if ($config.useCustomPaper) {
        $wPts = [math]::Round($config.paperWidth * 2.835)
        $hPts = [math]::Round($config.paperHeight * 2.835)
        $settings += "paper=${wPts}x${hPts}"
    } elseif ($config.continuousForm) {
        $wPts = [math]::Round(210 * 2.835)
        $hPts = [math]::Round($config.formLength * 2.835)
        $settings += "paper=${wPts}x${hPts}"
    } elseif ($config.paperSize -and $config.paperSize -notin @("Custom","Continuo")) {
        $settings += "paper=$($config.paperSize)"
    }

    if ($config.scale -and $config.scale -ne 100) { $settings += "scale=$($config.scale)" }
    $settingsStr = $settings -join ","

    $exitCode = Invoke-ProcessCapture $sumatraResolved "-silent -print-to `"$($config.printer)`" -print-settings `"$settingsStr`" `"$filePath`""

    if ($exitCode -eq 0) {
        return @{ Success = $true; Message = "Impreso (Sumatra): $fileName -> $($config.printer) [$settingsStr]" }
    } else {
        $reason = switch ($exitCode) {
            2 { "No se pudo abrir el archivo" }
            3 { "El documento no permite impresion" }
            4 { "Impresora no encontrada" }
            5 { "Error del driver" }
            6 { "Impresion deshabilitada" }
            default { "Error desconocido: $exitCode" }
        }
        return @{ Success = $false; Message = "Error imprimiendo $fileName - $reason" }
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

    # Papel personalizado o forma continua: fijar el medio en puntos
    if ($config.useCustomPaper -or $config.continuousForm) {
        $wMm = if ($config.useCustomPaper) { $config.paperWidth } else { 210 }
        $hMm = if ($config.useCustomPaper) { $config.paperHeight } else { $config.formLength }
        $wPts = [math]::Round($wMm * 2.835)
        $hPts = [math]::Round($hMm * 2.835)
        $gsArgs += @("-dDEVICEWIDTHPOINTS=$wPts", "-dDEVICEHEIGHTPOINTS=$hPts", "-dFIXEDMEDIA", "-dFitPage")
    }

    $gsArgs += "-sOutputFile=%printer%$($config.printer)"
    $gsArgs += "-f"
    $gsArgs += "`"$filePath`""
    $argStr = ($gsArgs | ForEach-Object { if ($_ -match '^-sOutputFile=') { "`"$_`"" } else { $_ } }) -join " "

    $exitCode = Invoke-ProcessCapture $gsResolved $argStr

    if ($exitCode -eq 0) {
        return @{ Success = $true; Message = "Impreso (Ghostscript ${dpi}dpi): $fileName -> $($config.printer)" }
    } else {
        return @{ Success = $false; Message = "Error Ghostscript ($exitCode) imprimiendo $fileName" }
    }
}

function Invoke-Print {
    param([string]$filePath)
    # Motor segun configuracion, con fallback cruzado si el elegido no esta.
    if ($config.renderEngine -eq "ghostscript") {
        if ($gsResolved) { return Invoke-PrintGhostscript $filePath }
        Write-Log "Ghostscript configurado pero no encontrado. Fallback a SumatraPDF." "WARN"
    }
    if ($sumatraResolved) { return Invoke-PrintSumatra $filePath }
    if ($gsResolved) {
        Write-Log "SumatraPDF no encontrado. Usando Ghostscript." "WARN"
        return Invoke-PrintGhostscript $filePath
    }
    return @{ Success = $false; Message = "Ningun motor de impresion disponible" }
}

function Remove-Invoice {
    param([string]$filePath)
    for ($i = 0; $i -lt 5; $i++) {
        try { Remove-Item -LiteralPath $filePath -Force; return $true } catch { Start-Sleep -Seconds 1 }
    }
    return $false
}

function Process-InvoiceFile {
    param([string]$fp)
    $fileName = Split-Path $fp -Leaf

    # Esperar tamano estable
    $lastSize = -1; $stable = 0; $ready = $false
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        try { $sz = (Get-Item -LiteralPath $fp).Length } catch { break }
        if ($sz -eq $lastSize -and $sz -gt 0) { $stable++; if ($stable -ge 3) { $ready = $true; break } }
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
            param($listener, $dlFolder, $apiKey, $pq, $sl)
            while ($listener.IsListening) {
                try {
                    $ctx = $listener.GetContext()
                    $req = $ctx.Request
                    $resp = $ctx.Response

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
                        $resp.Close()
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
                        $resp.Close()
                        continue
                    }

                    if ($req.HttpMethod -ne "POST") {
                        $resp.StatusCode = 405; $resp.Close(); continue
                    }

                    if ($apiKey -and $req.Headers["X-Api-Key"] -ne $apiKey) {
                        $body = [System.Text.Encoding]::UTF8.GetBytes('{"error":"unauthorized"}')
                        $resp.StatusCode = 401; $resp.ContentType = "application/json"
                        $resp.ContentLength64 = $body.Length; $resp.OutputStream.Write($body, 0, $body.Length)
                        $resp.Close(); continue
                    }

                    # POST /print - Agregar archivo(s) a la cola de impresion
                    if ($req.Url.AbsolutePath -eq "/print") {
                        $reader = New-Object System.IO.StreamReader($req.InputStream)
                        $rawBody = $reader.ReadToEnd(); $reader.Close()

                        $json = $rawBody | ConvertFrom-Json

                        $added = @()
                        $files = @()
                        if ($json.filename) { $files = @($json.filename) }
                        elseif ($json.filenames) { $files = @($json.filenames) }

                        foreach ($fn in $files) {
                            if (-not $fn.EndsWith(".pdf")) { $fn += ".pdf" }
                            if ($fn -notin $pq.ToArray()) {
                                [void]$pq.Add($fn)
                                $added += $fn
                                # Quitar de skipList si estaba ahi
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
                        $resp.OutputStream.Write($body, 0, $body.Length); $resp.Close()
                        continue
                    }

                    # POST /skip - Marcar archivo(s) para NO imprimir
                    if ($req.Url.AbsolutePath -eq "/skip") {
                        $reader = New-Object System.IO.StreamReader($req.InputStream)
                        $rawBody = $reader.ReadToEnd(); $reader.Close()

                        $json = $rawBody | ConvertFrom-Json

                        $added = @()
                        $files = @()
                        if ($json.filename) { $files = @($json.filename) }
                        elseif ($json.filenames) { $files = @($json.filenames) }

                        foreach ($fn in $files) {
                            if (-not $fn.EndsWith(".pdf")) { $fn += ".pdf" }
                            if ($fn -notin $sl.ToArray()) {
                                [void]$sl.Add($fn)
                                $added += $fn
                                # Quitar de printQueue si estaba ahi
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
                        $resp.OutputStream.Write($body, 0, $body.Length); $resp.Close()
                        continue
                    }

                    # POST /clear - Limpiar colas
                    if ($req.Url.AbsolutePath -eq "/clear") {
                        $pq.Clear()
                        $sl.Clear()
                        $body = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true,"printQueue":[],"skipList":[]}')
                        $resp.ContentType = "application/json"; $resp.ContentLength64 = $body.Length
                        $resp.OutputStream.Write($body, 0, $body.Length); $resp.Close()
                        continue
                    }

                    # POST /print/file - Subir PDF directamente
                    if ($req.Url.AbsolutePath -eq "/print/file") {
                        # Limite de tamano: proteccion contra abuso / agotamiento de disco
                        $maxUploadBytes = 50MB
                        if ($req.ContentLength64 -gt $maxUploadBytes) {
                            $body = [System.Text.Encoding]::UTF8.GetBytes('{"error":"file too large"}')
                            $resp.StatusCode = 413; $resp.ContentType = "application/json"
                            $resp.ContentLength64 = $body.Length; $resp.OutputStream.Write($body, 0, $body.Length)
                            $resp.Close(); continue
                        }

                        $fileName = $req.Headers["X-Filename"]
                        if (-not $fileName) { $fileName = "web_upload_$(Get-Date -Format 'yyyyMMddHHmmss').pdf" }
                        # Sanear: solo el nombre del archivo, sin rutas (evita path traversal)
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
                            $resp.Close(); continue
                        }

                        [System.IO.File]::WriteAllBytes($destPath, $bytes)

                        # Auto-agregar a printQueue
                        if ($fileName -notin $pq.ToArray()) {
                            [void]$pq.Add($fileName)
                        }

                        $body = [System.Text.Encoding]::UTF8.GetBytes("{`"ok`":true,`"file`":`"$fileName`"}")
                        $resp.ContentType = "application/json"; $resp.ContentLength64 = $body.Length
                        $resp.OutputStream.Write($body, 0, $body.Length); $resp.Close()
                        continue
                    }

                    $resp.StatusCode = 404; $resp.Close()
                } catch {
                    Start-Sleep -Milliseconds 100
                }
            }
        }).AddArgument($script:httpListener).AddArgument($config.downloadFolder).AddArgument($config.webApiKey).AddArgument($script:printQueue).AddArgument($script:skipList).BeginInvoke() | Out-Null

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
Write-Log "Motor:        $(if ($config.renderEngine -eq 'ghostscript') { 'Ghostscript' } else { 'SumatraPDF' })"
Write-Log "SumatraPDF:   $(if ($sumatraResolved) { $sumatraResolved } else { 'no encontrado' })"
Write-Log "Ghostscript:  $(if ($gsResolved) { $gsResolved } else { 'no encontrado' })"
Write-Log "Web HTTP:     $($config.webEnabled) (puerto $($config.webPort))"
Write-Log "========================================"

# Iniciar listener web
Start-WebListener

$seenFiles = @{}

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
                        # No esta en ninguna cola - ignorar
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
