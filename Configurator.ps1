<#
.SYNOPSIS
    Configurador grafico para LidaPrint.
.DESCRIPTION
    GUI con Windows Forms en modo oscuro. Organizada en pestanas por tarea:
    Conexion, Impresora, Forma continua / Ticketera, Avanzado, Drivers y formatos.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Continue"

# ===================== CARGAR CONFIGURACION =====================
$scriptDir = if ($Global:LidaPrintExeDir) { $Global:LidaPrintExeDir } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$configPath = Join-Path $scriptDir "config.json"

# Modo de operacion: "local" | "api" | "cloud". Configs viejas no traen "mode":
# se deriva de webEnabled. Copia identica en LidaPrint.ps1: en el exe unico el
# monitor corre dentro de la rama -Service y la GUI fuera, no comparten funciones.
function Get-LidaPrintMode {
    param($cfg)
    $m = ""
    if ($cfg -and ($cfg.PSObject.Properties.Name -contains 'mode') -and $cfg.mode) { $m = ([string]$cfg.mode).Trim().ToLower() }
    if ($m -eq "local" -or $m -eq "api" -or $m -eq "cloud") { return $m }
    if ($cfg -and $cfg.webEnabled) { return "api" }
    return "local"
}

function Load-Config {
    $defaults = [ordered]@{
        printer = ""; copies = 2; orientation = "portrait"
        paperSize = "A4"; paperWidth = 210; paperHeight = 297
        useCustomPaper = $false; scale = 100; dpi = 300
        marginTop = 0; marginBottom = 0; marginLeft = 0; marginRight = 0
        continuousForm = $false; formLength = 279; topOffset = 0; linePitch = 4.23
        gsPath = ""; renderAsImage = $false
        downloadFolder = ""; installPath = ""
        autoStart = $true; enableLogging = $true
        usePattern = $true; invoicePattern = "^(F|ND|NC)-\d{8}\.pdf$"
        webEnabled = $false; webPort = 8080; webApiKey = ""
        escposEnabled = $false; escposWidthMm = 64; escposHdpi = 158.75; escposVdpi = 72; escposDensity = 1
        escposLineSpacing = 16; escposThreshold = 170; escposAntialias = $true
        cloudUrl = ""; cloudToken = ""; cloudPollSeconds = 3
    }
    $cfg = $null
    if (Test-Path $configPath) {
        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
    }
    if (-not $cfg) { $cfg = [PSCustomObject]@{} }
    # "mode" NO va en los defaults: en configs viejas se deriva de webEnabled
    # (antes del backfill, que pondria webEnabled=false). Tambien normaliza
    # valores invalidos escritos a mano.
    $cfg | Add-Member -NotePropertyName mode -NotePropertyValue (Get-LidaPrintMode $cfg) -Force
    # Backfill keys that are absent or null (minimal or hand-edited configs)
    # so the UI never binds a null into a NumericUpDown or ComboBox.
    $present = $cfg.PSObject.Properties.Name
    foreach ($key in $defaults.Keys) {
        if ($present -notcontains $key -or $null -eq $cfg.$key) {
            $cfg | Add-Member -NotePropertyName $key -NotePropertyValue $defaults[$key] -Force
        }
    }
    # Defaults dinamicos: la carpeta de descargas del usuario actual si esta vacia.
    # Nunca se persiste una ruta de otra maquina como valor por defecto.
    if (-not $cfg.downloadFolder) {
        $cfg | Add-Member -NotePropertyName downloadFolder -NotePropertyValue (Join-Path $env:USERPROFILE "Downloads") -Force
    }
    return $cfg
}

function Save-Config {
    param($config)
    $config | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding UTF8
    # config.json puede contener la API Key: restringir el acceso solo al usuario actual.
    try {
        $acl = Get-Acl $configPath
        $acl.SetAccessRuleProtection($true, $false)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($env:USERNAME, 'FullControl', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl $configPath $acl
    } catch {
        # No es fatal: la config se guardo. Advertir al operador.
        $errDetail = $_.Exception.Message
        try {
            $logDir = Join-Path $scriptDir "logs"
            if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
            Add-Content -Path (Join-Path $logDir "PrintLog_$(Get-Date -Format 'yyyy-MM').txt") -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [WARN] No se pudo restringir el ACL de config.json: $errDetail" -Encoding UTF8
        } catch { }
        [System.Windows.Forms.MessageBox]::Show(
            "La configuracion se guardo, pero no se pudo restringir el acceso al archivo config.json.`n`nDetalle: $errDetail`n`nOtros usuarios del sistema podrian leer la API Key o el token de Odoo si existen.",
            "Advertencia de seguridad", "OK", "Warning"
        ) | Out-Null
    }
}

$config = Load-Config

# ===================== DRIVER FUNCTIONS =====================
function Get-DriverBaseRef {
    if ($Global:LidaPrintVersion -and $Global:LidaPrintVersion -notmatch 'dev') { "v$($Global:LidaPrintVersion)" } else { "main" }
}

function Get-DriverManifest {
    $url = "https://raw.githubusercontent.com/LIDALabs/lida-print/$(Get-DriverBaseRef)/drivers/drivers.json"
    try {
        Invoke-RestMethod -Uri $url -UseBasicParsing -TimeoutSec 10
    } catch {
        # Fallback: an installed exe whose tag was deleted, or dev checkout.
        try { Invoke-RestMethod -Uri "https://raw.githubusercontent.com/LIDALabs/lida-print/main/drivers/drivers.json" -UseBasicParsing -TimeoutSec 10 }
        catch { $null }
    }
}

function Get-FormatManifest {
    $url = "https://raw.githubusercontent.com/LIDALabs/lida-print/$(Get-DriverBaseRef)/formats/formats.json"
    try {
        Invoke-RestMethod -Uri $url -UseBasicParsing -TimeoutSec 10
    } catch {
        # Fallback: an installed exe whose tag was deleted, or dev checkout.
        try { Invoke-RestMethod -Uri "https://raw.githubusercontent.com/LIDALabs/lida-print/main/formats/formats.json" -UseBasicParsing -TimeoutSec 10 }
        catch { $null }
    }
}

function Install-PrinterDriver {
    param(
        [Parameter(Mandatory)]$Driver,
        [Parameter(Mandatory)][string]$BaseUrl
    )
    $url = if ($Driver.file -match '^https?://') { $Driver.file } else { "$BaseUrl/$($Driver.file)" }
    $ext = [IO.Path]::GetExtension($Driver.file)
    # %TEMP% may be a dead 8.3 short path (alias generation disabled on the
    # volume); use the registry-backed long LocalAppData path instead.
    $tempRoot = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "Temp"
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $tmp = Join-Path $tempRoot ("lidadrv_" + $Driver.id + $ext)
    $extractDir = $null
    try {
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 600
        $actual = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash
        if ($actual -ne $Driver.sha256) { throw "La verificacion SHA256 del driver fallo" }
        if ($Driver.type -eq "zip") {
            $extractDir = Join-Path $tempRoot ("lidadrv_" + $Driver.id + "_x")
            Expand-Archive -LiteralPath $tmp -DestinationPath $extractDir -Force
            $setup = Join-Path $extractDir $Driver.setupPath
        } else {
            $setup = $tmp
        }
        $spArgs = @{ FilePath = $setup; Wait = $true; PassThru = $true }
        if ($Driver.silentArgs) { $spArgs.ArgumentList = $Driver.silentArgs }
        (Start-Process @spArgs).ExitCode
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        if ($extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Repair-PrinterConnectivity {
    <#
    .SYNOPSIS
        Deja utilizable una impresora recien instalada que quedo inalcanzable.
    .DESCRIPTION
        Algunas ticketeras EPSON (APD) conectadas por un adaptador USB-a-paralelo
        (p. ej. CH340) quedan atadas al puerto propio de EPSON (ESDPRT), que usa
        deteccion USB nativa EPSON y NUNCA encuentra al adaptador generico. El
        trabajo entra al spooler pero no sale papel. Ademas el driver hace polling
        bidireccional de estado que el adaptador no responde, dejando la impresora
        "Sin conexion".

        Esta rutina, declarada por driver en drivers.json ("postInstall"), corrige
        eso sin intervencion: reasigna la impresora al puerto USB estandar del
        adaptador, desactiva el bidireccional y limpia el estado offline. Es
        idempotente y no lanza: cualquier fallo se registra y se continua.

        Bloque postInstall (todos los campos opcionales):
          printerNameMatch : regex del nombre de la impresora instalada.
          rebindToUsb      : reasignar de un puerto ESDPRT/EPSON al USB del equipo.
          usbPortMatch     : regex de la descripcion del puerto USB fisico a elegir.
          disableBidi      : apagar el soporte bidireccional (EnableBIDI=false).
          clearOffline     : quitar el flag "usar impresora sin conexion".
    #>
    param(
        [Parameter(Mandatory)]$Driver,
        [scriptblock]$Log = { param($m) }
    )
    $pi = $Driver.postInstall
    if (-not $pi) { return }
    $nameRe = if ($pi.printerNameMatch) { $pi.printerNameMatch } else { $Driver.name }

    $printers = @(Get-Printer -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $nameRe })
    if (-not $printers) {
        & $Log "Repair: no se encontro impresora que coincida con '$nameRe' (¿se completo el asistente del driver?)."
        return
    }

    foreach ($printer in $printers) {
        # 1) Reasignar del puerto EPSON (ESDPRT) al puerto USB del adaptador.
        if ($pi.rebindToUsb -and $printer.PortName -notmatch '^USB\d+') {
            $usbRe = if ($pi.usbPortMatch) { $pi.usbPortMatch } else { '.' }
            # Puertos USB con un dispositivo real: la descripcion trae el ID 1284
            # de la impresora, no el marcador vacio de "puerto virtual".
            $usbPort = Get-PrinterPort -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^USB\d+' -and $_.Description -match $usbRe } |
                Select-Object -First 1
            if ($usbPort) {
                try {
                    Set-Printer -Name $printer.Name -PortName $usbPort.Name -ErrorAction Stop
                    & $Log "Repair: '$($printer.Name)' reasignada de $($printer.PortName) a $($usbPort.Name)."
                } catch {
                    & $Log "Repair: no se pudo reasignar el puerto de '$($printer.Name)': $($_.Exception.Message)"
                }
            } else {
                & $Log "Repair: no hay puerto USB que coincida con '$usbRe' para '$($printer.Name)'."
            }
        }

        # 2) Desactivar el bidireccional: el adaptador paralelo no responde el
        #    protocolo de estado EPSON y sin esto la impresora queda "offline".
        if ($pi.disableBidi) {
            try {
                $wmi = Get-CimInstance -ClassName Win32_Printer -Filter "Name='$($printer.Name)'" -ErrorAction Stop
                Set-CimInstance -InputObject $wmi -Property @{ EnableBIDI = $false } -ErrorAction Stop
                & $Log "Repair: bidireccional desactivado en '$($printer.Name)'."
            } catch {
                & $Log "Repair: no se pudo desactivar el bidireccional de '$($printer.Name)': $($_.Exception.Message)"
            }
        }

        # 3) Limpiar el flag "usar impresora sin conexion".
        if ($pi.clearOffline) {
            & rundll32.exe printui.dll,PrintUIEntry /Xs /n $printer.Name attributes -WorkOffline 2>&1 | Out-Null
            & $Log "Repair: estado 'sin conexion' limpiado en '$($printer.Name)'."
        }
    }

    # Reiniciar el spooler para que la nueva asignacion de puerto tome efecto.
    try {
        Restart-Service Spooler -Force -ErrorAction Stop
        & $Log "Repair: spooler reiniciado."
    } catch {
        & $Log "Repair: no se pudo reiniciar el spooler: $($_.Exception.Message)"
    }
}

function Apply-DriverCalibration {
    <#
    .SYNOPSIS
        Escribe en config.json la calibracion ESC/POS especifica de la impresora
        recien instalada, declarada por driver en drivers.json ("calibration").

    .DESCRIPTION
        Objetivo: en cualquier PC nueva, instalar el driver deja el DPI, el ancho
        imprimible y el interlineado ya ajustados para ESE modelo, sin tener que
        pasar por la pestana Calibracion a mano. Los valores del bloque
        "calibration" son los medidos fisicamente sobre el hardware real (ver
        README, seccion "Calibracion (ESC/POS)").

        Solo toca las claves presentes en el bloque; el resto de config.json queda
        intacto. Idempotente: reinstalar reaplica los mismos valores. No lanza:
        cualquier fallo se registra y se continua.

        Devuelve una tabla hash con las claves aplicadas (o $null si el driver no
        declara calibracion) para que la UI refleje los valores en sus controles.

        Bloque calibration (todas las claves opcionales, mismos nombres que
        config.json): escposEnabled, escposWidthMm, escposHdpi, escposVdpi,
        escposDensity, escposLineSpacing, escposThreshold, escposAntialias.
    #>
    param(
        [Parameter(Mandatory)]$Driver,
        [scriptblock]$Log = { param($m) }
    )
    $cal = $Driver.calibration
    if (-not $cal) { return $null }

    try {
        # Releer del disco para no pisar cambios de otras pestanas aun sin guardar.
        $cfg = Load-Config
        $applied = @{}
        foreach ($prop in $cal.PSObject.Properties) {
            $cfg | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
            $applied[$prop.Name] = $prop.Value
        }
        Save-Config $cfg
        $resumen = ($applied.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ", "
        & $Log "Calibracion aplicada a config.json para '$($Driver.name)': $resumen"
        return $applied
    } catch {
        & $Log "Calibracion: no se pudo aplicar para '$($Driver.name)': $($_.Exception.Message)"
        return $null
    }
}

function Set-NudClamped {
    # Asigna un valor a un NumericUpDown sin lanzar si cae fuera de Min/Max:
    # lo recorta al rango del control. Usado al reflejar la calibracion del driver.
    param($Nud, $Value)
    try {
        $d = [decimal]$Value
        if ($d -lt $Nud.Minimum) { $d = $Nud.Minimum }
        if ($d -gt $Nud.Maximum) { $d = $Nud.Maximum }
        $Nud.Value = $d
    } catch { }
}

# ===================== CALIBRACION ESC/POS =====================
# Helper de impresion CRUDA (RAW) para las pruebas de calibracion: manda bytes
# ESC/POS directos a la impresora, sin pasar por el render GDI del driver.
if (-not ("LidaRawCfg" -as [type])) {
Add-Type -Language CSharp -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public class LidaRawCfg {
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
    var di=new DI(); di.n="LidaPrint calib"; di.t="RAW";
    if(!StartDocPrinter(h,1,ref di)){ClosePrinter(h);return "StartDoc FAIL "+Marshal.GetLastWin32Error();}
    StartPagePrinter(h); int w; bool ok=WritePrinter(h,d,d.Length,out w);
    EndPagePrinter(h); EndDocPrinter(h); ClosePrinter(h);
    return ok ? "OK" : "WritePrinter FAIL "+Marshal.GetLastWin32Error(); } }
"@
}

function Get-CalibrationBytes {
    # Construye las barras de calibracion: texto + una barra ESC * de cada ancho
    # en $widths (puntos). El usuario mide el ancho real en mm de cada barra
    # para deducir la densidad horizontal y el ancho maximo imprimible.
    param([int[]]$widths = @(200, 400))
    $b = New-Object System.Collections.Generic.List[byte]
    $ESC = 0x1B; $LF = 0x0A
    function AddStr($s) { foreach ($c in [System.Text.Encoding]::ASCII.GetBytes($s)) { $b.Add($c) } }
    $b.Add($ESC); $b.Add(0x40)                 # ESC @ init
    $b.Add($ESC); $b.Add(0x33); $b.Add(14)     # interlineado
    AddStr "LIDAPRINT - CALIBRACION`n`n"
    foreach ($wd in $widths) {
        AddStr "Barra $wd puntos:`n"
        $nL = $wd -band 0xFF; $nH = ($wd -shr 8) -band 0xFF
        for ($i = 0; $i -lt 3; $i++) {
            $b.Add($ESC); $b.Add(0x2A); $b.Add(1); $b.Add([byte]$nL); $b.Add([byte]$nH)
            for ($x = 0; $x -lt $wd; $x++) { $b.Add(0xFF) }
            $b.Add($LF)
        }
        AddStr "`n"
    }
    AddStr "Mida cada barra en mm.`n`n`n`n"
    return $b.ToArray()
}

# ===================== DETECTAR MOTOR DE IMPRESION =====================
function Find-Ghostscript {
    $local = Join-Path $scriptDir "bin\gswin64c.exe"
    if (Test-Path $local) { return $local }
    foreach ($base in @("$env:ProgramFiles\gs", "${env:ProgramFiles(x86)}\gs", "$env:LOCALAPPDATA\Programs\gs")) {
        if (Test-Path $base) {
            $found = Get-ChildItem -Path $base -Recurse -Filter "gswin*c.exe" -ErrorAction SilentlyContinue |
                Sort-Object FullName -Descending | Select-Object -First 1
            if ($found) { return $found.FullName }
        }
    }
    return ""
}

# ===================== DETECTAR IMPRESORAS =====================
function Get-PrinterDefaultDpi {
    # DPI por defecto reportado por el driver (DEVMODE) via WMI.
    # Funciona con cualquier marca: Epson matricial (180/360), Bixolon
    # termica (203), Canon laser (600), etc. Devuelve $null si el driver
    # no lo reporta.
    param([string]$printerName)
    try {
        $escaped = $printerName -replace "'", "''"
        $p = Get-CimInstance Win32_Printer -Filter "Name = '$escaped'" -ErrorAction Stop
        if ($p -and $p.HorizontalResolution -gt 0) {
            return @([int]$p.HorizontalResolution, [int]$p.VerticalResolution)
        }
    } catch { }
    return $null
}

function Get-PrinterList {
    try {
        return (Get-Printer | Where-Object { $_.Type -ne "Virtual" -and $_.Name -notlike "*PDF*" -and $_.Name -notlike "*XPS*" } |
            Select-Object -ExpandProperty Name) | Sort-Object
    } catch { return @() }
}
$printers = Get-PrinterList

# ===================== COLORES TEMA OSCURO =====================
$dkBg      = [Drawing.Color]::FromArgb(30, 30, 46)
$dkTab     = [Drawing.Color]::FromArgb(36, 36, 54)
$dkCard    = [Drawing.Color]::FromArgb(49, 50, 68)
$dkInput   = [Drawing.Color]::FromArgb(49, 50, 68)
$dkBorder  = [Drawing.Color]::FromArgb(69, 71, 90)
$dkText    = [Drawing.Color]::FromArgb(205, 214, 244)
$dkTextDim = [Drawing.Color]::FromArgb(147, 153, 178)
$dkAccent  = [Drawing.Color]::FromArgb(137, 180, 250)
$dkGreen   = [Drawing.Color]::FromArgb(166, 227, 161)
$dkGreenBg = [Drawing.Color]::FromArgb(48, 80, 48)
$dkBtnBg   = [Drawing.Color]::FromArgb(69, 71, 90)
$dkBtnTest = [Drawing.Color]::FromArgb(58, 90, 130)

function Set-DarkTheme {
    param($control)
    if ($control -is [System.Windows.Forms.Form]) {
        $control.BackColor = $dkBg
        $control.ForeColor = $dkText
    } elseif ($control -is [System.Windows.Forms.TabControl]) {
        $control.BackColor = $dkTab
        $control.ForeColor = $dkText
    } elseif ($control -is [System.Windows.Forms.TabPage]) {
        $control.BackColor = $dkTab
        $control.ForeColor = $dkText
    } elseif ($control -is [System.Windows.Forms.GroupBox]) {
        $control.BackColor = $dkTab
        $control.ForeColor = $dkAccent
    } elseif ($control -is [System.Windows.Forms.Label]) {
        $control.BackColor = [Drawing.Color]::Transparent
        $control.ForeColor = $dkTextDim
    } elseif ($control -is [System.Windows.Forms.TextBox]) {
        $control.BackColor = $dkInput
        $control.ForeColor = $dkText
        $control.BorderStyle = "FixedSingle"
    } elseif ($control -is [System.Windows.Forms.ComboBox]) {
        $control.BackColor = $dkInput
        $control.ForeColor = $dkText
        $control.FlatStyle = "Flat"
    } elseif ($control -is [System.Windows.Forms.NumericUpDown]) {
        $control.BackColor = $dkInput
        $control.ForeColor = $dkText
        $control.BorderStyle = "FixedSingle"
    } elseif ($control -is [System.Windows.Forms.CheckBox]) {
        $control.BackColor = [Drawing.Color]::FromArgb(220, 220, 230)
        $control.ForeColor = [Drawing.Color]::Black
        $control.FlatStyle = "System"
    } elseif ($control -is [System.Windows.Forms.RadioButton]) {
        # Mismo criterio que CheckBox: FlatStyle System dibuja el texto en negro.
        $control.BackColor = [Drawing.Color]::FromArgb(220, 220, 230)
        $control.ForeColor = [Drawing.Color]::Black
        $control.FlatStyle = "System"
    } elseif ($control -is [System.Windows.Forms.ListBox]) {
        $control.BackColor = $dkInput
        $control.ForeColor = $dkText
        $control.BorderStyle = "FixedSingle"
    } elseif ($control -is [System.Windows.Forms.Button]) {
        $control.BackColor = $dkBtnBg
        $control.ForeColor = $dkText
        $control.FlatStyle = "Flat"
        $control.FlatAppearance.BorderColor = $dkBorder
        $control.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(88, 91, 112)
    }
}

# ===================== CREAR FORMULARIO =====================
$form = New-Object System.Windows.Forms.Form
$form.Text = "LidaPrint - Configuracion"
$form.Size = New-Object System.Drawing.Size(650, 565)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false
Set-DarkTheme $form

# ===================== LOGO =====================
$logoPath = Join-Path $scriptDir "logo.png"
$logoImage = $null
if ($Global:LidaPrintLogoB64) {
    try {
        $ms = New-Object System.IO.MemoryStream(,[Convert]::FromBase64String($Global:LidaPrintLogoB64))
        $script:logoStream = $ms
        $logoImage = [System.Drawing.Image]::FromStream($ms)
    } catch { $logoImage = $null }
}
if (-not $logoImage -and (Test-Path $logoPath)) {
    $logoImage = [System.Drawing.Image]::FromFile($logoPath)
}
if ($logoImage) {
    # Cargar el bitmap una sola vez y mantenerlo en scope de script para
    # evitar que el GC lo libere mientras el formulario lo necesita.
    $script:logoBitmap = $logoImage
    # Convertir a Icon via GetHicon() y liberar el handle de GDI inmediatamente
    # con DestroyIcon para evitar leak. El Icon resultante tiene su propia copia.
    $hicon = $script:logoBitmap.GetHicon()
    $script:formIcon = [System.Drawing.Icon]::FromHandle($hicon)
    $form.Icon = $script:formIcon
    # Liberar el handle GDI original (el Icon ya tiene su propia copia interna)
    try {
        $destroySig = 'public static extern bool DestroyIcon(IntPtr handle);'
        Add-Type -MemberDefinition $destroySig -Name "IconHelper" -Namespace "NativeGdi" -ErrorAction SilentlyContinue
        [NativeGdi.IconHelper]::DestroyIcon($hicon) | Out-Null
    } catch { }

    $picLogo = New-Object System.Windows.Forms.PictureBox
    $picLogo.Location = New-Object System.Drawing.Point(10, 8)
    $picLogo.Size = New-Object System.Drawing.Size(40, 40)
    $picLogo.SizeMode = "Zoom"
    $picLogo.Image = $script:logoBitmap
    $form.Controls.Add($picLogo)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "LidaPrint"
    $lblTitle.Location = New-Object System.Drawing.Point(56, 10)
    $lblTitle.Size = New-Object System.Drawing.Size(200, 36)
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 18, [Drawing.FontStyle]::Bold)
    $lblTitle.ForeColor = $dkText
    $lblTitle.TextAlign = "MiddleLeft"
    $form.Controls.Add($lblTitle)
    $tabY = 55
} else {
    $tabY = 10
}

# ===================== LAYOUT (grilla comun) =====================
# Posicionamiento absoluto, pero con UNA grilla para todas las pestanas:
# una columna de etiquetas y una de controles (mas una segunda pareja para
# filas con dos campos), filas de alto uniforme y grupos del mismo ancho.
$L_GX  = 10    # x de los GroupBox dentro de la pestana
$L_GW  = 590   # ancho uniforme de los GroupBox
$L_GAP = 8     # separacion vertical entre GroupBox
$L_TOP = 22    # y de la primera fila dentro de un GroupBox
$L_ROW = 28    # alto uniforme de fila
$L_LX1 = 12;  $L_LW1 = 134; $L_CX1 = 150   # columna 1: etiqueta / control
$L_LX2 = 310; $L_LW2 = 116; $L_CX2 = 430   # columna 2: etiqueta / control
$L_FULL = 566  # ancho de una fila completa (de $L_LX1 al borde derecho, x=578)

$dkRed  = [Drawing.Color]::FromArgb(243, 139, 168)
$dkWarn = [Drawing.Color]::FromArgb(249, 226, 175)

function New-Group {
    # GroupBox de ancho uniforme; el alto sale de la cantidad de filas.
    param($parent, [string]$text, [int]$y, [int]$rows, [int]$x = $L_GX, [int]$w = $L_GW, [int]$h = 0)
    $g = New-Object System.Windows.Forms.GroupBox
    $g.Text = $text
    if ($h -le 0) { $h = $L_TOP + $rows * $L_ROW + 4 }
    $g.Location = New-Object System.Drawing.Point($x, $y)
    $g.Size = New-Object System.Drawing.Size($w, $h)
    Set-DarkTheme $g
    $parent.Controls.Add($g)
    return $g
}

function Add-Ctl {
    # Ubica un control en la fila $row del grupo, en la x y ancho dados.
    # Etiquetas y checks bajan unos pixeles para alinear el texto con las cajas.
    param($parent, $ctl, [int]$row, [int]$x, [int]$w, [int]$h = 0)
    $y = $L_TOP + $row * $L_ROW
    if ($ctl -is [System.Windows.Forms.Label]) { $y += 3 }
    elseif ($ctl -is [System.Windows.Forms.CheckBox] -or $ctl -is [System.Windows.Forms.RadioButton]) { $y += 1 }
    if ($h -le 0) { if ($ctl -is [System.Windows.Forms.Button]) { $h = 23 } else { $h = 20 } }
    $ctl.Location = New-Object System.Drawing.Point($x, $y)
    $ctl.Size = New-Object System.Drawing.Size($w, $h)
    Set-DarkTheme $ctl
    $parent.Controls.Add($ctl)
}

function Add-Label {
    # Etiqueta de la columna de etiquetas (1 o 2).
    param($parent, [string]$text, [int]$row, [int]$x = $L_LX1, [int]$w = $L_LW1)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    Add-Ctl $parent $l $row $x $w
    return $l
}

# ===================== HELPERS MODO NUBE =====================
function Get-LidaPrintUserAgent {
    if ($Global:LidaPrintVersion) { return "LidaPrint/$($Global:LidaPrintVersion)" }
    return "LidaPrint/dev"
}

function Get-HttpStatusCode {
    # Codigo HTTP de un error de Invoke-WebRequest, o 0 si no hubo respuesta.
    param($err)
    $ex = $err.Exception
    while ($ex -and -not ($ex -is [System.Net.WebException])) { $ex = $ex.InnerException }
    if (-not $ex -or -not $ex.Response) { return 0 }
    $code = 0
    try { $code = [int]$ex.Response.StatusCode } catch { }
    try { $ex.Response.Close() } catch { }
    return $code
}

# ----- Funciones compartidas del modo Nube -----
# Copia identica en LidaPrint.ps1, por el mismo motivo que Get-LidaPrintMode.
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
# ----- Fin de las funciones compartidas -----

function Get-CloudTokenWarning {
    # "" si el token tiene el formato que genera Odoo (secrets.token_urlsafe(32):
    # 43 caracteres A-Z a-z 0-9 _ -). Si no, un aviso que NO bloquea: suele ser
    # un token copiado a medias o con espacios, pero el que decide es Odoo.
    param([string]$token)
    $t = ([string]$token).Trim()
    if ($t -match '^[A-Za-z0-9_-]{43}$') { return "" }
    return "El token no tiene el formato que genera Odoo (43 caracteres: letras, numeros, - y _; este tiene $($t.Length)). Se copio completo?"
}

# IP de esta PC en la LAN, para la pista de URL del modo Red local.
$script:lanIp = "IP-DE-ESTA-PC"
try {
    $ip4 = [System.Net.Dns]::GetHostAddresses($env:COMPUTERNAME) |
        Where-Object { $_.AddressFamily -eq 'InterNetwork' -and $_.ToString() -notmatch '^(127\.|169\.254\.)' } |
        Select-Object -First 1
    if ($ip4) { $script:lanIp = $ip4.ToString() }
} catch { }

# ===================== TABCONTROL =====================
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(10, $tabY)
$tabs.Size = New-Object System.Drawing.Size(620, 400)
Set-DarkTheme $tabs

# Un unico ToolTip para toda la ventana: las explicaciones largas viven aqui
# (bloque TOOLTIPS al final) y no en etiquetas.
$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.AutoPopDelay = 20000
$toolTip.InitialDelay = 400
$toolTip.ReshowDelay  = 200

# ===================== TAB 1: CONEXION =====================
# Como llegan los PDF: un selector de modo y SOLO el panel del modo elegido.
$tConn = New-Object System.Windows.Forms.TabPage
$tConn.Text = "Conexion"
Set-DarkTheme $tConn

$grpMode = New-Group $tConn "Modo de operacion" 10 2

$rbLocal = New-Object System.Windows.Forms.RadioButton
$rbLocal.Text = "Local (por nombre de archivo)"
Add-Ctl $grpMode $rbLocal 0 $L_LX1 185

$rbApi = New-Object System.Windows.Forms.RadioButton
$rbApi.Text = "Red local (Odoo envia a esta PC)"
Add-Ctl $grpMode $rbApi 0 205 205

$rbCloud = New-Object System.Windows.Forms.RadioButton
$rbCloud.Text = "Nube (Odoo en VPS)"
Add-Ctl $grpMode $rbCloud 0 420 150

$lblModeHint = New-Object System.Windows.Forms.Label
Add-Ctl $grpMode $lblModeHint 1 $L_LX1 $L_FULL
$lblModeHint.AutoEllipsis = $true   # una linea: "..." en vez de cortar la segunda
$lblModeHint.ForeColor = $dkAccent

$initialMode = Get-LidaPrintMode $config
switch ($initialMode) {
    "api"   { $rbApi.Checked = $true }
    "cloud" { $rbCloud.Checked = $true }
    default { $rbLocal.Checked = $true }
}

$panelY = $grpMode.Bottom + $L_GAP

# --- Carpeta de descargas (modos Local y Red local) ---
# Red local tambien la usa: /print/file guarda ahi y /print busca ahi.
$grpFolder = New-Group $tConn "Carpeta de descargas" $panelY 1
[void](Add-Label $grpFolder "Carpeta:" 0)

$txtDownloads = New-Object System.Windows.Forms.TextBox
$txtDownloads.Text = $config.downloadFolder
Add-Ctl $grpFolder $txtDownloads 0 $L_CX1 300

$btnBrowseDL = New-Object System.Windows.Forms.Button
$btnBrowseDL.Text = "..."
$btnBrowseDL.Add_Click({
    $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
    $fbd.Description = "Seleccionar carpeta de descargas"
    if ($fbd.ShowDialog() -eq "OK") { $txtDownloads.Text = $fbd.SelectedPath }
})
Add-Ctl $grpFolder $btnBrowseDL 0 456 40

$btnOpenFolder = New-Object System.Windows.Forms.Button
$btnOpenFolder.Text = "Abrir"
$btnOpenFolder.Add_Click({
    if ($txtDownloads.Text -and (Test-Path $txtDownloads.Text)) {
        Start-Process explorer.exe $txtDownloads.Text
    } else {
        [System.Windows.Forms.MessageBox]::Show("La carpeta no existe.", "Error", "OK", "Warning")
    }
})
Add-Ctl $grpFolder $btnOpenFolder 0 502 76

$panel2Y = $grpFolder.Bottom + $L_GAP

# --- Panel Local: filtro por nombre ---
$grpLocal = New-Group $tConn "Filtro por nombre (modo Local)" $panel2Y 3
[void](Add-Label $grpLocal "Patron de nombre:" 0)

$txtPattern = New-Object System.Windows.Forms.TextBox
$txtPattern.Text = $config.invoicePattern
$txtPattern.Font = New-Object System.Drawing.Font("Consolas", 9)
Add-Ctl $grpLocal $txtPattern 0 $L_CX1 300

$chkUsePattern = New-Object System.Windows.Forms.CheckBox
$chkUsePattern.Text = "Usar patron (sin patron se imprime todo PDF)"
Add-Ctl $grpLocal $chkUsePattern 1 $L_CX1 300

$lblEx = New-Object System.Windows.Forms.Label
$lblEx.Text = "Validos: F-12345678.pdf  ND-00001234.pdf  NC-00005678.pdf"
Add-Ctl $grpLocal $lblEx 2 $L_LX1 $L_FULL
$lblEx.Font = New-Object System.Drawing.Font("Consolas", 9)
$lblEx.ForeColor = $dkAccent

# --- Panel Red local: API HTTP ---
$grpApi = New-Group $tConn "Red local (Odoo envia los PDF a esta PC)" $panel2Y 3
[void](Add-Label $grpApi "Puerto:" 0)

$nudPort = New-Object System.Windows.Forms.NumericUpDown
$nudPort.Minimum = 1
$nudPort.Maximum = 65535
Set-NudClamped $nudPort $config.webPort
Add-Ctl $grpApi $nudPort 0 $L_CX1 80

[void](Add-Label $grpApi "API Key:" 1)

$txtApiKey = New-Object System.Windows.Forms.TextBox
$txtApiKey.Text = $config.webApiKey
$txtApiKey.UseSystemPasswordChar = $true
Add-Ctl $grpApi $txtApiKey 1 $L_CX1 220

$btnToggleKey = New-Object System.Windows.Forms.Button
$btnToggleKey.Text = "Mostrar"
$btnToggleKey.Add_Click({
    $txtApiKey.UseSystemPasswordChar = -not $txtApiKey.UseSystemPasswordChar
    $btnToggleKey.Text = if ($txtApiKey.UseSystemPasswordChar) { "Mostrar" } else { "Ocultar" }
})
Add-Ctl $grpApi $btnToggleKey 1 378 70

$lblApiReq = New-Object System.Windows.Forms.Label
$lblApiReq.Text = "Obligatoria"
Add-Ctl $grpApi $lblApiReq 1 456 122
$lblApiReq.ForeColor = $dkWarn

$lblApiUrl = New-Object System.Windows.Forms.Label
Add-Ctl $grpApi $lblApiUrl 2 $L_LX1 $L_FULL
$lblApiUrl.ForeColor = $dkAccent
$lblApiUrl.Font = New-Object System.Drawing.Font("Consolas", 8)

$updateApiUrl = {
    $port = [int]$nudPort.Value
    $lblApiUrl.Text = "En Odoo: http://$($script:lanIp):$port   (en esta PC: http://localhost:$port/print/status)"
}
$nudPort.Add_ValueChanged($updateApiUrl)
& $updateApiUrl

# --- Panel Nube: esta PC consulta a Odoo por HTTPS ---
$grpCloud = New-Group $tConn "Nube (Odoo en un VPS o en internet)" $panelY 5
[void](Add-Label $grpCloud "URL de Odoo:" 0)

$txtCloudUrl = New-Object System.Windows.Forms.TextBox
$txtCloudUrl.Text = [string]$config.cloudUrl
Add-Ctl $grpCloud $txtCloudUrl 0 $L_CX1 428

[void](Add-Label $grpCloud "Token:" 1)

$txtCloudToken = New-Object System.Windows.Forms.TextBox
$txtCloudToken.Text = [string]$config.cloudToken
$txtCloudToken.UseSystemPasswordChar = $true
Add-Ctl $grpCloud $txtCloudToken 1 $L_CX1 340

$btnToggleToken = New-Object System.Windows.Forms.Button
$btnToggleToken.Text = "Mostrar"
$btnToggleToken.Add_Click({
    $txtCloudToken.UseSystemPasswordChar = -not $txtCloudToken.UseSystemPasswordChar
    $btnToggleToken.Text = if ($txtCloudToken.UseSystemPasswordChar) { "Mostrar" } else { "Ocultar" }
})
Add-Ctl $grpCloud $btnToggleToken 1 498 80

[void](Add-Label $grpCloud "Consultar cada (s):" 2)

$nudCloudPoll = New-Object System.Windows.Forms.NumericUpDown
$nudCloudPoll.Minimum = 1
$nudCloudPoll.Maximum = 300
Set-NudClamped $nudCloudPoll $config.cloudPollSeconds
Add-Ctl $grpCloud $nudCloudPoll 2 $L_CX1 60

$btnCloudTest = New-Object System.Windows.Forms.Button
$btnCloudTest.Text = "Probar conexion"
Add-Ctl $grpCloud $btnCloudTest 3 $L_CX1 130

$lblCloudStatus = New-Object System.Windows.Forms.Label
Add-Ctl $grpCloud $lblCloudStatus 3 290 288
$lblCloudStatus.AutoEllipsis = $true   # nombres largos de equipo/compania

# Una linea; el otro camino (menu de Facturacion) y los pasos, en el tooltip.
$lblCloudHint = New-Object System.Windows.Forms.Label
$lblCloudHint.Text = "Token: en Odoo (administrador), Ajustes > API de integracion > LidaPrint > Equipos LidaPrint."
Add-Ctl $grpCloud $lblCloudHint 4 $L_LX1 $L_FULL
$lblCloudHint.AutoEllipsis = $true

$btnCloudTest.Add_Click({
    # GET /ping con los valores escritos en el formulario (sin guardar).
    # No reclama trabajos: solo verifica URL, token y equipo.
    $chk = Get-CloudUrlCheck $txtCloudUrl.Text
    $token = $txtCloudToken.Text.Trim()
    if ($chk.Error) {
        $lblCloudStatus.ForeColor = $dkRed; $lblCloudStatus.Text = "URL invalida"
        [System.Windows.Forms.MessageBox]::Show($chk.Error, "Probar conexion", "OK", "Error") | Out-Null; return
    }
    if (-not $token) {
        $lblCloudStatus.ForeColor = $dkRed; $lblCloudStatus.Text = "Falta el token"
        [System.Windows.Forms.MessageBox]::Show("Pega el token generado en Odoo.", "Probar conexion", "OK", "Error") | Out-Null; return
    }
    if ($chk.Notice) {
        # A la vista queda la URL que se prueba, que es tambien la que se guardara.
        $txtCloudUrl.Text = $chk.Url
        [System.Windows.Forms.MessageBox]::Show($chk.Notice, "Probar conexion", "OK", "Information") | Out-Null
    }
    $tokenWarn = Get-CloudTokenWarning $token
    $lblCloudStatus.ForeColor = $dkTextDim; $lblCloudStatus.Text = "Probando..."
    $lblCloudStatus.Refresh()
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        # Tls12 solo si no es SystemDefault (0): sumarlo ahi desactivaria TLS 1.3.
        $sp = [Net.ServicePointManager]::SecurityProtocol
        if ([int]$sp -ne 0) { [Net.ServicePointManager]::SecurityProtocol = $sp -bor [Net.SecurityProtocolType]::Tls12 }
        $ProgressPreference = "SilentlyContinue"
        $resp = Invoke-WebRequest -Uri "$($chk.Url)/lidaprint/v1/ping" -Method Get -Headers @{ Authorization = "Bearer $token" } `
            -UserAgent (Get-LidaPrintUserAgent) -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
        # UTF-8 a mano: sin charset, PS 5.1 decodificaria como ISO-8859-1.
        $text = [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
        $data = $null
        try { $data = $text | ConvertFrom-Json -ErrorAction Stop } catch { $data = $null }
        if ($data -and $data.ok) {
            $lblCloudStatus.ForeColor = $dkGreen
            $lblCloudStatus.Text = "OK: $($data.device) ($($data.company))"
            $warn = if ($chk.Warning) { "`n`nAtencion: $($chk.Warning)" } else { "" }
            [System.Windows.Forms.MessageBox]::Show("Conexion correcta.`n`nEquipo: $($data.device)`nCompania: $($data.company)$warn`n`nGuarda la configuracion para que el monitor empiece a consultar a Odoo.", "Probar conexion", "OK", "Information") | Out-Null
        } else {
            $lblCloudStatus.ForeColor = $dkRed; $lblCloudStatus.Text = "Respuesta no valida"
            [System.Windows.Forms.MessageBox]::Show("La URL respondio, pero no parece Odoo con el modo Nube de LidaPrint. Verifica la URL.", "Probar conexion", "OK", "Error") | Out-Null
        }
    } catch {
        $err = $_
        $code = Get-HttpStatusCode $err
        $kind = Get-CloudFailureKind $code
        if ($kind -eq "unauthorized") {
            $short = "Token rechazado (401)"
            $msg = "Odoo rechazo el token (HTTP 401): equipo archivado o token revocado, o el token se copio mal.`n`nGenera un token nuevo en Odoo (Equipos LidaPrint > Generar token) y pegalo aqui."
            if ($tokenWarn) { $msg += "`n`n$tokenWarn" }
        } elseif ($kind -eq "config") {
            $short = "URL o base de datos (HTTP $code)"
            $msg = "Odoo respondio HTTP ${code}. $(Get-CloudConfigHint).`n`nSi la URL y la base estan bien, verifica que el modulo de Odoo este actualizado a una version con modo Nube (18.0.2.4.0 o posterior)."
        } elseif ($code) {
            $short = "Error HTTP $code"
            $msg = "Odoo respondio HTTP $code."
        } else {
            $short = "Sin conexion"
            $msg = "No se pudo conectar con Odoo:`n$($err.Exception.Message)`n`nRevisa la URL, la conexion a internet y que el certificado HTTPS del servidor sea valido."
        }
        $lblCloudStatus.ForeColor = $dkRed; $lblCloudStatus.Text = $short
        [System.Windows.Forms.MessageBox]::Show($msg, "Probar conexion", "OK", "Error") | Out-Null
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})

# --- Cambio de modo: mostrar solo el panel del modo elegido ---
$getSelectedMode = {
    if ($rbCloud.Checked) { return "cloud" }
    if ($rbApi.Checked) { return "api" }
    return "local"
}

# El patron solo aplica en modo Local. Al salir de Local se desactiva y
# desmarca (como antes al activar la API); al volver se restaura lo que el
# usuario tenia, para no quedar sin querer en "imprimir todo PDF".
$chkUsePattern.Checked = if ($initialMode -eq "local") { [bool]$config.usePattern } else { $true }
$script:usePatternLocal = $chkUsePattern.Checked

$applyModeUi = {
    $m = & $getSelectedMode
    $grpFolder.Visible = ($m -ne "cloud")
    $grpLocal.Visible  = ($m -eq "local")
    $grpApi.Visible    = ($m -eq "api")
    $grpCloud.Visible  = ($m -eq "cloud")
    switch ($m) {
        "api"   { $lblModeHint.Text = "Odoo, en la misma red, envia cada PDF a esta PC por HTTP (puerto abierto)." }
        "cloud" { $lblModeHint.Text = "Esta PC consulta a Odoo por HTTPS. Sirve con Odoo en un VPS, sin abrir puertos." }
        default { $lblModeHint.Text = "Imprime los PDF que Odoo descarga en esta PC si el nombre coincide con el patron." }
    }
    if ($m -eq "local") {
        if (-not $chkUsePattern.Enabled) {
            $chkUsePattern.Enabled = $true
            $chkUsePattern.Checked = $script:usePatternLocal
        }
    } else {
        if ($chkUsePattern.Enabled) {
            $script:usePatternLocal = $chkUsePattern.Checked
            $chkUsePattern.Enabled = $false
        }
        $chkUsePattern.Checked = $false
    }
}
$rbLocal.Add_CheckedChanged($applyModeUi)
$rbApi.Add_CheckedChanged($applyModeUi)
$rbCloud.Add_CheckedChanged($applyModeUi)
& $applyModeUi

$tabs.TabPages.Add($tConn)

# ===================== TAB 2: IMPRESORA =====================
# Impresora, papel, margenes, escala y DPI (antes: pestanas Impresion y Papel).
$tPrn = New-Object System.Windows.Forms.TabPage
$tPrn.Text = "Impresora"
Set-DarkTheme $tPrn

$grpPrinter = New-Group $tPrn "Impresora" 10 3
[void](Add-Label $grpPrinter "Impresora:" 0)

$cmbPrinter = New-Object System.Windows.Forms.ComboBox
$cmbPrinter.DropDownStyle = "DropDownList"
foreach ($p in $printers) { $cmbPrinter.Items.Add($p) | Out-Null }
if ($config.printer -and $cmbPrinter.Items.Contains($config.printer)) {
    $cmbPrinter.SelectedItem = $config.printer
} elseif ($cmbPrinter.Items.Count -gt 0) { $cmbPrinter.SelectedIndex = 0 }
Add-Ctl $grpPrinter $cmbPrinter 0 $L_CX1 320

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = "Refrescar"
$btnRefresh.Add_Click({
    $cmbPrinter.Items.Clear()
    foreach ($p in (Get-PrinterList)) { $cmbPrinter.Items.Add($p) | Out-Null }
    if ($cmbPrinter.Items.Count -gt 0) { $cmbPrinter.SelectedIndex = 0 }
})
Add-Ctl $grpPrinter $btnRefresh 0 478 100

[void](Add-Label $grpPrinter "Copias:" 1)

$nudCopias = New-Object System.Windows.Forms.NumericUpDown
$nudCopias.Minimum = 1
$nudCopias.Maximum = 10
$nudCopias.Value = $config.copies
Add-Ctl $grpPrinter $nudCopias 1 $L_CX1 60

[void](Add-Label $grpPrinter "Orientacion:" 1 $L_LX2 $L_LW2)

$cmbOrient = New-Object System.Windows.Forms.ComboBox
$cmbOrient.DropDownStyle = "DropDownList"
@("portrait", "landscape") | ForEach-Object { $cmbOrient.Items.Add($_) | Out-Null }
if ($config.orientation -eq "landscape") { $cmbOrient.SelectedIndex = 1 } else { $cmbOrient.SelectedIndex = 0 }
Add-Ctl $grpPrinter $cmbOrient 1 $L_CX2 110

[void](Add-Label $grpPrinter "DPI:" 2)

$cmbDPI = New-Object System.Windows.Forms.ComboBox
# DropDown (editable): permite escribir un DPI a mano ademas de los presets.
# Se valida al Guardar (72-1200).
$cmbDPI.DropDownStyle = "DropDown"
@("72", "96", "150", "203", "240", "300", "600") | ForEach-Object { $cmbDPI.Items.Add($_) | Out-Null }
$cmbDPI.Text = if ($config.dpi) { $config.dpi.ToString() } else { "300" }
Add-Ctl $grpPrinter $cmbDPI 2 $L_CX1 80

# DPI por defecto del driver de la impresora seleccionada
$lblPrinterDpi = New-Object System.Windows.Forms.Label
$lblPrinterDpi.Text = ""
Add-Ctl $grpPrinter $lblPrinterDpi 2 240 232
$lblPrinterDpi.AutoEllipsis = $true
$lblPrinterDpi.ForeColor = $dkAccent

$btnUseDpi = New-Object System.Windows.Forms.Button
$btnUseDpi.Text = "Usar este DPI"
$btnUseDpi.Enabled = $false
Add-Ctl $grpPrinter $btnUseDpi 2 478 100

$script:printerDefaultDpi = $null
$updatePrinterDpiHint = {
    $script:printerDefaultDpi = $null
    $btnUseDpi.Enabled = $false
    if ($cmbPrinter.SelectedItem) {
        $res = Get-PrinterDefaultDpi $cmbPrinter.SelectedItem
        if ($res) {
            $script:printerDefaultDpi = $res[0]
            $lblPrinterDpi.Text = "Driver: $($res[0]) x $($res[1]) DPI"
            $btnUseDpi.Enabled = $true
        } else {
            $lblPrinterDpi.Text = "Driver: DPI no reportado"
        }
    } else {
        $lblPrinterDpi.Text = ""
    }
}
$btnUseDpi.Add_Click({
    if ($script:printerDefaultDpi) { $cmbDPI.Text = $script:printerDefaultDpi.ToString() }
})
$cmbPrinter.Add_SelectedIndexChanged($updatePrinterDpiHint)
& $updatePrinterDpiHint

$grpPaper = New-Group $tPrn "Papel" ($grpPrinter.Bottom + $L_GAP) 2
[void](Add-Label $grpPaper "Tamano:" 0)

$cmbPaper = New-Object System.Windows.Forms.ComboBox
$cmbPaper.DropDownStyle = "DropDownList"
@("A4", "Letter", "Legal", "Tabloid", "A5", "Continuo", "Custom") | ForEach-Object { $cmbPaper.Items.Add($_) | Out-Null }
$paperIdx = $cmbPaper.Items.IndexOf($config.paperSize)
if ($paperIdx -ge 0) { $cmbPaper.SelectedIndex = $paperIdx } else { $cmbPaper.SelectedIndex = 0 }
Add-Ctl $grpPaper $cmbPaper 0 $L_CX1 120

$chkCustom = New-Object System.Windows.Forms.CheckBox
$chkCustom.Text = "Tamano personalizado"
$chkCustom.Checked = $config.useCustomPaper
Add-Ctl $grpPaper $chkCustom 0 $L_LX2 180

[void](Add-Label $grpPaper "Ancho (mm):" 1)

$nudWidth = New-Object System.Windows.Forms.NumericUpDown
$nudWidth.Minimum = 50
$nudWidth.Maximum = 2000
$nudWidth.Value = $config.paperWidth
$nudWidth.Enabled = $config.useCustomPaper
Add-Ctl $grpPaper $nudWidth 1 $L_CX1 70

[void](Add-Label $grpPaper "Alto (mm):" 1 $L_LX2 $L_LW2)

$nudHeight = New-Object System.Windows.Forms.NumericUpDown
$nudHeight.Minimum = 50
$nudHeight.Maximum = 2000
$nudHeight.Value = $config.paperHeight
$nudHeight.Enabled = $config.useCustomPaper
Add-Ctl $grpPaper $nudHeight 1 $L_CX2 70

# Acople bidireccional: el check de tamano personalizado y el combo de Paper
# Size nunca quedan en estados contradictorios.
$chkCustom.Add_CheckedChanged({
    $nudWidth.Enabled = $chkCustom.Checked
    $nudHeight.Enabled = $chkCustom.Checked
    if ($chkCustom.Checked) {
        $cmbPaper.SelectedIndex = $cmbPaper.Items.IndexOf("Custom")
        $cmbPaper.Enabled = $false
    } else {
        $cmbPaper.Enabled = $true
        if ($cmbPaper.SelectedItem -eq "Custom") { $cmbPaper.SelectedIndex = $cmbPaper.Items.IndexOf("A4") }
    }
})
$cmbPaper.Add_SelectedIndexChanged({
    if ($cmbPaper.SelectedItem -eq "Custom" -and -not $chkCustom.Checked) { $chkCustom.Checked = $true }
})
# Estado inicial coherente al abrir con configuracion cargada
if ($chkCustom.Checked) {
    $cmbPaper.SelectedIndex = $cmbPaper.Items.IndexOf("Custom")
    $cmbPaper.Enabled = $false
}

$grpMargins = New-Group $tPrn "Margenes (mm) y escala" ($grpPaper.Bottom + $L_GAP) 3

[void](Add-Label $grpMargins "Superior:" 0)
$nudMTop = New-Object System.Windows.Forms.NumericUpDown
$nudMTop.Minimum = 0
$nudMTop.Maximum = 200
$nudMTop.Value = $config.marginTop
Add-Ctl $grpMargins $nudMTop 0 $L_CX1 60

[void](Add-Label $grpMargins "Inferior:" 0 $L_LX2 $L_LW2)
$nudMBot = New-Object System.Windows.Forms.NumericUpDown
$nudMBot.Minimum = 0
$nudMBot.Maximum = 200
$nudMBot.Value = $config.marginBottom
Add-Ctl $grpMargins $nudMBot 0 $L_CX2 60

[void](Add-Label $grpMargins "Izquierdo:" 1)
$nudMLeft = New-Object System.Windows.Forms.NumericUpDown
$nudMLeft.Minimum = 0
$nudMLeft.Maximum = 200
$nudMLeft.Value = $config.marginLeft
Add-Ctl $grpMargins $nudMLeft 1 $L_CX1 60

[void](Add-Label $grpMargins "Derecho:" 1 $L_LX2 $L_LW2)
$nudMRight = New-Object System.Windows.Forms.NumericUpDown
$nudMRight.Minimum = 0
$nudMRight.Maximum = 200
$nudMRight.Value = $config.marginRight
Add-Ctl $grpMargins $nudMRight 1 $L_CX2 60

[void](Add-Label $grpMargins "Escala (%):" 2)
$nudScale = New-Object System.Windows.Forms.NumericUpDown
$nudScale.Minimum = 10
$nudScale.Maximum = 200
$nudScale.Value = $config.scale
Add-Ctl $grpMargins $nudScale 2 $L_CX1 60

$lblMarginHint = New-Object System.Windows.Forms.Label
$lblMarginHint.Text = "Cada margen desplaza el contenido sin escalarlo; para achicarlo usa Escala."
$lblMarginHint.Location = New-Object System.Drawing.Point(($L_GX + 2), ($grpMargins.Bottom + 6))
$lblMarginHint.Size = New-Object System.Drawing.Size(($L_GW - 4), 20)
Set-DarkTheme $lblMarginHint
$tPrn.Controls.Add($lblMarginHint)

$tabs.TabPages.Add($tPrn)

# ===================== TAB 3: FORMA CONTINUA / TICKETERA =====================
# Papel tractor y ticketeras ESC/POS con su calibracion (antes: pestanas
# Forma Continua y Calibracion).
$tCont = New-Object System.Windows.Forms.TabPage
$tCont.Text = "Forma continua / Ticketera"
Set-DarkTheme $tCont

$grpContinuous = New-Group $tCont "Forma continua (matriciales con papel tractor)" 10 2

$chkContinuous = New-Object System.Windows.Forms.CheckBox
$chkContinuous.Text = "Activar modo forma continua"
$chkContinuous.Checked = $config.continuousForm
Add-Ctl $grpContinuous $chkContinuous 0 $L_LX1 250

[void](Add-Label $grpContinuous "Largo (mm):" 1)
$nudFormLen = New-Object System.Windows.Forms.NumericUpDown
$nudFormLen.Minimum = 50
$nudFormLen.Maximum = 5000
$nudFormLen.Value = $config.formLength
Add-Ctl $grpContinuous $nudFormLen 1 $L_CX1 70

[void](Add-Label $grpContinuous "Desplaz. sup. (mm):" 1 $L_LX2 $L_LW2)
$nudTopOff = New-Object System.Windows.Forms.NumericUpDown
$nudTopOff.Minimum = 0
$nudTopOff.Maximum = 500
$nudTopOff.Value = $config.topOffset
Add-Ctl $grpContinuous $nudTopOff 1 $L_CX2 70

$grpEsc = New-Group $tCont "Ticketera ESC/POS (bytes crudos)" ($grpContinuous.Bottom + $L_GAP) 5

$chkEscpos = New-Object System.Windows.Forms.CheckBox
$chkEscpos.Text = "Imprimir por ESC/POS crudo (para impresoras cuyo driver no acepta GDI)"
$chkEscpos.Checked = [bool]$config.escposEnabled
Add-Ctl $grpEsc $chkEscpos 0 $L_LX1 $L_FULL

[void](Add-Label $grpEsc "Ancho imprimible (mm):" 1)
$nudEscWidth = New-Object System.Windows.Forms.NumericUpDown
$nudEscWidth.Minimum = 10; $nudEscWidth.Maximum = 300
$nudEscWidth.DecimalPlaces = 1; $nudEscWidth.Increment = 0.5
$nudEscWidth.Value = [decimal]$config.escposWidthMm
Add-Ctl $grpEsc $nudEscWidth 1 $L_CX1 70

[void](Add-Label $grpEsc "Densidad (0/1):" 1 $L_LX2 $L_LW2)
$nudEscDensity = New-Object System.Windows.Forms.NumericUpDown
$nudEscDensity.Minimum = 0; $nudEscDensity.Maximum = 1
$nudEscDensity.Value = [decimal]$config.escposDensity
Add-Ctl $grpEsc $nudEscDensity 1 $L_CX2 50

[void](Add-Label $grpEsc "DPI horizontal:" 2)
$nudEscHdpi = New-Object System.Windows.Forms.NumericUpDown
$nudEscHdpi.Minimum = 50; $nudEscHdpi.Maximum = 400
$nudEscHdpi.DecimalPlaces = 2; $nudEscHdpi.Increment = 0.25
$nudEscHdpi.Value = [decimal]$config.escposHdpi
Add-Ctl $grpEsc $nudEscHdpi 2 $L_CX1 70

[void](Add-Label $grpEsc "DPI vertical:" 2 $L_LX2 $L_LW2)
$nudEscVdpi = New-Object System.Windows.Forms.NumericUpDown
$nudEscVdpi.Minimum = 50; $nudEscVdpi.Maximum = 400
$nudEscVdpi.DecimalPlaces = 2; $nudEscVdpi.Increment = 0.25
$nudEscVdpi.Value = [decimal]$config.escposVdpi
Add-Ctl $grpEsc $nudEscVdpi 2 $L_CX2 70

[void](Add-Label $grpEsc "Interlineado (n):" 3)
$nudEscLineSp = New-Object System.Windows.Forms.NumericUpDown
$nudEscLineSp.Minimum = 1; $nudEscLineSp.Maximum = 64
$nudEscLineSp.Value = [decimal]$config.escposLineSpacing
Add-Ctl $grpEsc $nudEscLineSp 3 $L_CX1 60

[void](Add-Label $grpEsc "Umbral negro:" 3 $L_LX2 $L_LW2)
$nudEscThr = New-Object System.Windows.Forms.NumericUpDown
$nudEscThr.Minimum = 1; $nudEscThr.Maximum = 254
$nudEscThr.Value = [decimal]$config.escposThreshold
Add-Ctl $grpEsc $nudEscThr 3 $L_CX2 60

# linePitch: separacion extra al final de cada ticket. Solo la usa la via
# ESC/POS (con o sin forma continua), por eso vive en este grupo.
[void](Add-Label $grpEsc "Separacion extra (mm):" 4)
$nudLinePitch = New-Object System.Windows.Forms.NumericUpDown
$nudLinePitch.Minimum = 0
$nudLinePitch.Maximum = 100
$nudLinePitch.DecimalPlaces = 1
$nudLinePitch.Increment = 0.1
$nudLinePitch.Value = $config.linePitch
Add-Ctl $grpEsc $nudLinePitch 4 $L_CX1 70

$chkEscAA = New-Object System.Windows.Forms.CheckBox
$chkEscAA.Text = "Antialiasing (trazo mas firme)"
$chkEscAA.Checked = [bool]$config.escposAntialias
Add-Ctl $grpEsc $chkEscAA 4 $L_LX2 268

# Boton: imprimir barras de calibracion
$btnCalibBars = New-Object System.Windows.Forms.Button
$btnCalibBars.Text = "Imprimir barras de calibracion"
$btnCalibBars.Location = New-Object System.Drawing.Point($L_GX, ($grpEsc.Bottom + $L_GAP))
$btnCalibBars.Size = New-Object System.Drawing.Size(230, 28)
$btnCalibBars.Add_Click({
    if (-not $cmbPrinter.SelectedItem) {
        [System.Windows.Forms.MessageBox]::Show("Seleccione una impresora en la pestana Impresora.", "LidaPrint") | Out-Null; return
    }
    $res = [LidaRawCfg]::Send([string]$cmbPrinter.SelectedItem, (Get-CalibrationBytes @(200, 400)))
    if ($res -eq "OK") {
        [System.Windows.Forms.MessageBox]::Show("Barras enviadas. Mida cada una en mm:`n`n- El ancho maximo (barra que llena el papel) es el Ancho imprimible.`n- DPI horiz. = puntos / (mm / 25.4). Ej: 200 pts / 32 mm -> 158.75.", "Calibracion") | Out-Null
    } else {
        [System.Windows.Forms.MessageBox]::Show("No se pudo imprimir: $res", "Error", "OK", "Error") | Out-Null
    }
})
Set-DarkTheme $btnCalibBars
$tCont.Controls.Add($btnCalibBars)

$lblCalibHint = New-Object System.Windows.Forms.Label
$lblCalibHint.Text = "Mida las barras en mm (ayuda: mouse sobre cada campo)."
$lblCalibHint.Location = New-Object System.Drawing.Point(250, ($grpEsc.Bottom + $L_GAP + 6))
# Alto de dos lineas: si el texto llegara a envolver, no se corta.
$lblCalibHint.Size = New-Object System.Drawing.Size(350, 34)
Set-DarkTheme $lblCalibHint
$tCont.Controls.Add($lblCalibHint)

$tabs.TabPages.Add($tCont)

# ===================== TAB 4: AVANZADO =====================
# Motor Ghostscript, conversor DPI/pixeles y opciones del sistema (antes:
# pestanas Calidad y Sistema).
$tAdv = New-Object System.Windows.Forms.TabPage
$tAdv.Text = "Avanzado"
Set-DarkTheme $tAdv

$grpEngine = New-Group $tAdv "Motor de impresion: Ghostscript" 10 2
[void](Add-Label $grpEngine "Ghostscript:" 0)

$txtGs = New-Object System.Windows.Forms.TextBox
$txtGs.Text = if ($config.gsPath) { $config.gsPath } else { Find-Ghostscript }
Add-Ctl $grpEngine $txtGs 0 $L_CX1 300

$btnBrowseGs = New-Object System.Windows.Forms.Button
$btnBrowseGs.Text = "..."
$btnBrowseGs.Add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = "Ghostscript|gswin64c.exe;gswin32c.exe"
    if ($ofd.ShowDialog() -eq "OK") { $txtGs.Text = $ofd.FileName }
})
Add-Ctl $grpEngine $btnBrowseGs 0 456 40

$btnDetectGs = New-Object System.Windows.Forms.Button
$btnDetectGs.Text = "Detectar"
$btnDetectGs.Add_Click({
    $found = Find-Ghostscript
    if ($found) { $txtGs.Text = $found }
    else { [System.Windows.Forms.MessageBox]::Show("Ghostscript no encontrado. Instalalo con el instalador o desde ghostscript.com", "Info", "OK", "Information") }
})
Add-Ctl $grpEngine $btnDetectGs 0 502 76

$chkRenderImage = New-Object System.Windows.Forms.CheckBox
$chkRenderImage.Text = "Suavizado maximo de texto y graficos (renderizar como imagen)"
$chkRenderImage.Checked = [bool]$config.renderAsImage
Add-Ctl $grpEngine $chkRenderImage 1 $L_LX1 420

$grpConv = New-Group $tAdv "Conversor DPI / pixeles (para forma continua)" ($grpEngine.Bottom + $L_GAP) 2

# Fila 1: mm + DPI -> pixeles. Fila de formula: columnas propias (excepcion a la grilla).
[void](Add-Label $grpConv "Milimetros:" 0)
$nudCvMm = New-Object System.Windows.Forms.NumericUpDown
$nudCvMm.Minimum = 1; $nudCvMm.Maximum = 5000
$nudCvMm.DecimalPlaces = 1; $nudCvMm.Increment = 0.5
$nudCvMm.Value = 210
Add-Ctl $grpConv $nudCvMm 0 $L_CX1 80

[void](Add-Label $grpConv "a DPI:" 0 240 44)
$nudCvDpi1 = New-Object System.Windows.Forms.NumericUpDown
$nudCvDpi1.Minimum = 72; $nudCvDpi1.Maximum = 1200
$nudCvDpi1.Value = 203
Add-Ctl $grpConv $nudCvDpi1 0 286 64

$lblCvPxOut = New-Object System.Windows.Forms.Label
$lblCvPxOut.Text = ""
Add-Ctl $grpConv $lblCvPxOut 0 360 218
$lblCvPxOut.ForeColor = $dkAccent
$lblCvPxOut.Font = New-Object System.Drawing.Font("Consolas", 9)

# Fila 2: pixeles + DPI -> mm
[void](Add-Label $grpConv "Pixeles:" 1)
$nudCvPx = New-Object System.Windows.Forms.NumericUpDown
$nudCvPx.Minimum = 1; $nudCvPx.Maximum = 100000
$nudCvPx.Value = 1678
Add-Ctl $grpConv $nudCvPx 1 $L_CX1 80

[void](Add-Label $grpConv "a DPI:" 1 240 44)
$nudCvDpi2 = New-Object System.Windows.Forms.NumericUpDown
$nudCvDpi2.Minimum = 72; $nudCvDpi2.Maximum = 1200
$nudCvDpi2.Value = 203
Add-Ctl $grpConv $nudCvDpi2 1 286 64

$lblCvMmOut = New-Object System.Windows.Forms.Label
$lblCvMmOut.Text = ""
Add-Ctl $grpConv $lblCvMmOut 1 360 218
$lblCvMmOut.ForeColor = $dkAccent
$lblCvMmOut.Font = New-Object System.Drawing.Font("Consolas", 9)

# 1 pulgada = 25.4 mm. px = mm / 25.4 * dpi ; mm = px / dpi * 25.4
$updateConv = {
    $px = [math]::Round(($nudCvMm.Value / 25.4) * $nudCvDpi1.Value)
    $inch = [math]::Round($nudCvMm.Value / 25.4, 2)
    $lblCvPxOut.Text = "= $px px  ($inch pulgadas)"
    $mm = [math]::Round(($nudCvPx.Value / $nudCvDpi2.Value) * 25.4, 1)
    $lblCvMmOut.Text = "= $mm mm"
}
$nudCvMm.Add_ValueChanged($updateConv)
$nudCvDpi1.Add_ValueChanged($updateConv)
$nudCvPx.Add_ValueChanged($updateConv)
$nudCvDpi2.Add_ValueChanged($updateConv)
& $updateConv

$grpSystem = New-Group $tAdv "Sistema" ($grpConv.Bottom + $L_GAP) 2

$chkAutoStart = New-Object System.Windows.Forms.CheckBox
$chkAutoStart.Text = "Auto-iniciar con Windows (Task Scheduler)"
$chkAutoStart.Checked = $config.autoStart
Add-Ctl $grpSystem $chkAutoStart 0 $L_LX1 300

$chkLogging = New-Object System.Windows.Forms.CheckBox
$chkLogging.Text = "Generar logs de impresion"
$chkLogging.Checked = $config.enableLogging
Add-Ctl $grpSystem $chkLogging 1 $L_LX1 300

$btnViewLog = New-Object System.Windows.Forms.Button
$btnViewLog.Text = "Ver Log"
$btnViewLog.Add_Click({
    $logDir = Join-Path $scriptDir "logs"
    # Abrir el log mas reciente (rotacion mensual: PrintLog_yyyy-MM.txt)
    $latest = Get-ChildItem -Path $logDir -Filter "PrintLog*.txt" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) {
        Start-Process notepad.exe $latest.FullName
    } else {
        [System.Windows.Forms.MessageBox]::Show("No hay log generado aun.", "Info", "OK", "Information")
    }
})
Add-Ctl $grpSystem $btnViewLog 1 478 100

$tabs.TabPages.Add($tAdv)

# ===================== TAB 5: DRIVERS Y FORMATOS =====================
# Descargas unicas del catalogo de LIDA, lado a lado (antes: dos pestanas).
$tDrv = New-Object System.Windows.Forms.TabPage
$tDrv.Text = "Drivers y formatos"
Set-DarkTheme $tDrv

$L_HALF = [int](($L_GW - 10) / 2)   # 290: dos columnas con 10 px entre ellas
$L_HIN  = $L_HALF - 24              # ancho interior de cada columna

$grpDrv = New-Group $tDrv "Drivers de impresora" 10 0 $L_GX $L_HALF 312

$lstDrv = New-Object System.Windows.Forms.ListBox
$lstDrv.Location = New-Object System.Drawing.Point(12, 22)
$lstDrv.Size = New-Object System.Drawing.Size($L_HIN, 160)
Set-DarkTheme $lstDrv

$lblDrvNotes = New-Object System.Windows.Forms.Label
$lblDrvNotes.Location = New-Object System.Drawing.Point(12, 188)
$lblDrvNotes.Size = New-Object System.Drawing.Size($L_HIN, 44)
$lblDrvNotes.Text = ""
Set-DarkTheme $lblDrvNotes

$btnDrvInstall = New-Object System.Windows.Forms.Button
$btnDrvInstall.Text = "Instalar driver seleccionado"
$btnDrvInstall.Location = New-Object System.Drawing.Point(12, 238)
$btnDrvInstall.Size = New-Object System.Drawing.Size($L_HIN, 28)
Set-DarkTheme $btnDrvInstall

$lblDrvStatus = New-Object System.Windows.Forms.Label
$lblDrvStatus.Location = New-Object System.Drawing.Point(12, 272)
$lblDrvStatus.Size = New-Object System.Drawing.Size($L_HIN, 32)
$lblDrvStatus.Text = ""
Set-DarkTheme $lblDrvStatus

$grpFmt = New-Group $tDrv "Formatos de factura" 10 0 ($L_GX + $L_HALF + 10) $L_HALF 312

$lstFmt = New-Object System.Windows.Forms.ListBox
$lstFmt.Location = New-Object System.Drawing.Point(12, 22)
$lstFmt.Size = New-Object System.Drawing.Size($L_HIN, 160)
Set-DarkTheme $lstFmt

$lblFmtNotes = New-Object System.Windows.Forms.Label
$lblFmtNotes.Location = New-Object System.Drawing.Point(12, 188)
$lblFmtNotes.Size = New-Object System.Drawing.Size($L_HIN, 44)
$lblFmtNotes.Text = ""
Set-DarkTheme $lblFmtNotes

$btnFmtDownload = New-Object System.Windows.Forms.Button
$btnFmtDownload.Text = "Descargar..."
$btnFmtDownload.Location = New-Object System.Drawing.Point(12, 238)
$btnFmtDownload.Size = New-Object System.Drawing.Size($L_HIN, 28)
Set-DarkTheme $btnFmtDownload

$lblFmtStatus = New-Object System.Windows.Forms.Label
$lblFmtStatus.Location = New-Object System.Drawing.Point(12, 272)
$lblFmtStatus.Size = New-Object System.Drawing.Size($L_HIN, 32)
$lblFmtStatus.Text = ""
Set-DarkTheme $lblFmtStatus

# Ambas listas se cargan (una sola vez) al entrar a la pestana.
$script:driverManifest = $null
$script:formatManifest = $null
$tDrv.Add_Enter({
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        if (-not $script:driverManifest) {
            $lblDrvStatus.Text = "Cargando lista de drivers..."
            $lblDrvStatus.Refresh()
            $script:driverManifest = Get-DriverManifest
            $lstDrv.Items.Clear()
            if ($script:driverManifest) {
                foreach ($d in $script:driverManifest.drivers) { [void]$lstDrv.Items.Add($d.name) }
                $lblDrvStatus.Text = ""
            } else {
                $lblDrvStatus.Text = "Sin conexion: no se pudo cargar la lista de drivers."
            }
        }
        if (-not $script:formatManifest) {
            $lblFmtStatus.Text = "Cargando lista de formatos..."
            $lblFmtStatus.Refresh()
            $script:formatManifest = Get-FormatManifest
            $lstFmt.Items.Clear()
            if ($script:formatManifest) {
                foreach ($f in $script:formatManifest.formats) { [void]$lstFmt.Items.Add($f.name) }
                $lblFmtStatus.Text = ""
            } else {
                $lblFmtStatus.Text = "Sin conexion: no se pudo cargar la lista de formatos."
            }
        }
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})

$lstDrv.Add_SelectedIndexChanged({
    if ($lstDrv.SelectedIndex -ge 0) {
        $lblDrvNotes.Text = $script:driverManifest.drivers[$lstDrv.SelectedIndex].notes
    }
})

$btnDrvInstall.Add_Click({
    if ($lstDrv.SelectedIndex -lt 0) {
        [System.Windows.Forms.MessageBox]::Show("Seleccione un driver de la lista.", "LidaPrint") | Out-Null
        return
    }
    $drv = $script:driverManifest.drivers[$lstDrv.SelectedIndex]
    $baseUrl = "https://raw.githubusercontent.com/LIDALabs/lida-print/$(Get-DriverBaseRef)"
    $btnDrvInstall.Enabled = $false
    $lblDrvStatus.Text = "Descargando e instalando $($drv.name)..."
    $lblDrvStatus.Refresh(); [System.Windows.Forms.Application]::DoEvents()
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $code = Install-PrinterDriver -Driver $drv -BaseUrl $baseUrl
        if ($code -eq 0) {
            # Dejar la impresora utilizable de inmediato (reasignar puerto USB,
            # desactivar bidireccional, limpiar offline) segun postInstall.
            $repairLog = {
                param($m)
                try {
                    $logDir = Join-Path $scriptDir "logs"
                    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
                    Add-Content -Path (Join-Path $logDir ("PrintLog_{0:yyyy-MM}.txt" -f (Get-Date))) `
                        -Value ("[{0:yyyy-MM-dd HH:mm:ss}] [DRIVER] {1}" -f (Get-Date), $m)
                } catch { }
            }
            Repair-PrinterConnectivity -Driver $drv -Log $repairLog

            # Aplicar la calibracion ESC/POS especifica del modelo (DPI, ancho
            # imprimible, interlineado) a config.json, para que la impresora quede
            # lista para imprimir 1:1 sin tocar la calibracion a mano.
            $applied = Apply-DriverCalibration -Driver $drv -Log $repairLog
            if ($applied) {
                # Reflejar los valores en la pestana Forma continua / Ticketera:
                # quedan visibles y un "Guardar" posterior no los pisa.
                if ($applied.ContainsKey('escposEnabled'))     { $chkEscpos.Checked = [bool]$applied['escposEnabled'] }
                if ($applied.ContainsKey('escposWidthMm'))     { Set-NudClamped $nudEscWidth   $applied['escposWidthMm'] }
                if ($applied.ContainsKey('escposHdpi'))        { Set-NudClamped $nudEscHdpi    $applied['escposHdpi'] }
                if ($applied.ContainsKey('escposVdpi'))        { Set-NudClamped $nudEscVdpi    $applied['escposVdpi'] }
                if ($applied.ContainsKey('escposDensity'))     { Set-NudClamped $nudEscDensity $applied['escposDensity'] }
                if ($applied.ContainsKey('escposLineSpacing')) { Set-NudClamped $nudEscLineSp  $applied['escposLineSpacing'] }
                if ($applied.ContainsKey('escposThreshold'))   { Set-NudClamped $nudEscThr     $applied['escposThreshold'] }
                if ($applied.ContainsKey('escposAntialias'))   { $chkEscAA.Checked = [bool]$applied['escposAntialias'] }
            }

            $calMsg = if ($applied) { "`n`nCalibracion ESC/POS aplicada automaticamente para este modelo." } else { "" }
            $lblDrvStatus.Text = "Driver instalado y configurado correctamente."
            [System.Windows.Forms.MessageBox]::Show("$($drv.name) instalado correctamente.$calMsg", "LidaPrint") | Out-Null
        } else {
            $lblDrvStatus.Text = "El instalador devolvio el codigo $code."
            [System.Windows.Forms.MessageBox]::Show("El instalador de $($drv.name) devolvio el codigo $code.", "LidaPrint") | Out-Null
        }
    } catch {
        $lblDrvStatus.Text = "Error: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("No se pudo instalar el driver: $($_.Exception.Message)", "LidaPrint",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $btnDrvInstall.Enabled = $true
        # Spec: driver install results are also recorded in the log file.
        try {
            $logDir = Join-Path $scriptDir "logs"
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            Add-Content -Path (Join-Path $logDir ("PrintLog_{0:yyyy-MM}.txt" -f (Get-Date))) `
                -Value ("[{0:yyyy-MM-dd HH:mm:ss}] [DRIVER] {1} -> {2}" -f (Get-Date), $drv.id, $lblDrvStatus.Text)
        } catch { }
    }
})

$lstFmt.Add_SelectedIndexChanged({
    if ($lstFmt.SelectedIndex -ge 0) {
        $lblFmtNotes.Text = $script:formatManifest.formats[$lstFmt.SelectedIndex].description
    }
})

$btnFmtDownload.Add_Click({
    if ($lstFmt.SelectedIndex -lt 0) {
        [System.Windows.Forms.MessageBox]::Show("Seleccione un formato de la lista.", "LidaPrint") | Out-Null
        return
    }
    $fmt = $script:formatManifest.formats[$lstFmt.SelectedIndex]
    $baseUrl = "https://raw.githubusercontent.com/LIDALabs/lida-print/$(Get-DriverBaseRef)"
    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.FileName = Split-Path -Leaf $fmt.file
    $sfd.Filter = "XML|*.xml"
    if ($sfd.ShowDialog() -ne "OK") { return }

    $btnFmtDownload.Enabled = $false
    $lblFmtStatus.Text = "Descargando $($fmt.name)..."
    $lblFmtStatus.Refresh(); [System.Windows.Forms.Application]::DoEvents()
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $url = "$baseUrl/$($fmt.file)"
        Invoke-WebRequest -Uri $url -OutFile $sfd.FileName -UseBasicParsing -TimeoutSec 60
        $lblFmtStatus.Text = "Formato descargado correctamente."
        [System.Windows.Forms.MessageBox]::Show("$($fmt.name) descargado en $($sfd.FileName).", "LidaPrint") | Out-Null
    } catch {
        $lblFmtStatus.Text = "Error: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("No se pudo descargar el formato: $($_.Exception.Message)", "LidaPrint",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $btnFmtDownload.Enabled = $true
    }
})

$grpDrv.Controls.AddRange(@($lstDrv, $lblDrvNotes, $btnDrvInstall, $lblDrvStatus))
$grpFmt.Controls.AddRange(@($lstFmt, $lblFmtNotes, $btnFmtDownload, $lblFmtStatus))
$tabs.TabPages.Add($tDrv)

$form.Controls.Add($tabs)

# ===================== BOTONES INFERIORES =====================
# Izquierda: pruebas (impresion, monitor). Derecha: Cancelar / Guardar.
function Get-LidaPrintMonitorProcess {
    # Monitores vivos de esta instalacion: powershell con LidaPrint.ps1 (dev) o
    # LidaPrint.exe -Service (exe), excluyendo este mismo proceso.
    $procs = @()
    $procs += @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*LidaPrint.ps1*" })
    $procs += @(Get-CimInstance Win32_Process -Filter "Name = 'LidaPrint.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*-Service*" -and $_.ProcessId -ne $PID })
    return $procs
}

function New-TestPdf {
    param([string]$path, [string]$texto = "PRUEBA LIDAPRINT")
    $content = @"
%PDF-1.4
1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj
4 0 obj<</Length 60>>stream
BT /F1 24 Tf 100 700 Td ($texto) Tj ET
endstream
endobj
5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj
trailer<</Size 6/Root 1 0 R>>
%%EOF
"@
    Set-Content -Path $path -Value $content -Encoding ASCII
}

$btnY = 465

$btnTest = New-Object System.Windows.Forms.Button
$btnTest.Text = "Probar impresion"
$btnTest.Location = New-Object System.Drawing.Point(10, $btnY)
$btnTest.Size = New-Object System.Drawing.Size(140, 35)
$btnTest.BackColor = $dkBtnTest
$btnTest.ForeColor = $dkText
$btnTest.FlatStyle = "Flat"
$btnTest.FlatAppearance.BorderColor = $dkBorder
$btnTest.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(78, 110, 160)
$btnTest.Add_Click({
    if (-not $txtGs.Text -or -not (Test-Path $txtGs.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Ghostscript no encontrado. Usa 'Detectar' en la pestana Avanzado o re-ejecuta el instalador.", "Error", "OK", "Error"); return
    }
    if (-not $cmbPrinter.SelectedItem) {
        [System.Windows.Forms.MessageBox]::Show("Seleccione una impresora.", "Error", "OK", "Error"); return
    }

    $tmpDir = Join-Path $scriptDir "temp"
    if (-not (Test-Path $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null }
    $testPdf = Join-Path $tmpDir "test_invoice_F-00000001.pdf"
    New-TestPdf $testPdf "FACTURA DE PRUEBA"

    # Prueba con Ghostscript (mismo motor que usa el monitor)
    $dpiTest = 300
    if (-not [int]::TryParse($cmbDPI.Text, [ref]$dpiTest) -or $dpiTest -lt 72 -or $dpiTest -gt 1200) { $dpiTest = 300 }
    $gsTestArgs = "-dBATCH -dNOPAUSE -dQUIET -dNoCancel -sDEVICE=mswinpr2 -r$dpiTest -dNumCopies=1 `"-sOutputFile=%printer%$($cmbPrinter.SelectedItem)`" -f `"$testPdf`""

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $txtGs.Text
    $psi.Arguments = $gsTestArgs
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.WaitForExit()
        if ($proc.ExitCode -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Prueba enviada a $($cmbPrinter.SelectedItem) (Ghostscript ${dpiTest}dpi)", "Exito", "OK", "Information")
        } else {
            [System.Windows.Forms.MessageBox]::Show("Error de impresion. Codigo Ghostscript: $($proc.ExitCode)", "Error", "OK", "Error")
        }
    } catch { [System.Windows.Forms.MessageBox]::Show("Error: $_", "Error", "OK", "Error") }
    Remove-Item $testPdf -Force -ErrorAction SilentlyContinue
})
$form.Controls.Add($btnTest)

$btnTestMonitor = New-Object System.Windows.Forms.Button
$btnTestMonitor.Text = "Probar monitor"
$btnTestMonitor.Location = New-Object System.Drawing.Point(160, $btnY)
$btnTestMonitor.Size = New-Object System.Drawing.Size(140, 35)
$btnTestMonitor.BackColor = $dkBtnTest
$btnTestMonitor.ForeColor = $dkText
$btnTestMonitor.FlatStyle = "Flat"
$btnTestMonitor.FlatAppearance.BorderColor = $dkBorder
$btnTestMonitor.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(78, 110, 160)
$btnTestMonitor.Add_Click({
    # Prueba de punta a punta: crea una factura valida en la carpeta vigilada.
    # Si el monitor esta corriendo, la detecta, imprime y borra en segundos.
    $modeNow = & $getSelectedMode
    if ($modeNow -ne "cloud" -and (-not $txtDownloads.Text -or -not (Test-Path $txtDownloads.Text))) {
        [System.Windows.Forms.MessageBox]::Show("La carpeta de descargas no existe.", "Error", "OK", "Error"); return
    }
    $monitorProc = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*LidaPrint.ps1*" }
    if (-not $monitorProc) {
        # Also check for the compiled exe monitor (-Service mode), excluding this process
        $monitorProc = Get-CimInstance Win32_Process -Filter "Name='LidaPrint.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like "*-Service*" -and $_.ProcessId -ne $PID }
    }
    if (-not $monitorProc) {
        [System.Windows.Forms.MessageBox]::Show("El monitor NO esta corriendo. Guarda la configuracion (boton Guardar) para iniciarlo y proba de nuevo.", "Monitor detenido", "OK", "Warning"); return
    }
    if ($modeNow -eq "cloud") {
        # En modo Nube el monitor no mira la carpeta: una factura de prueba ahi
        # nunca se imprimiria y quedaria olvidada.
        [System.Windows.Forms.MessageBox]::Show(
            "El monitor esta corriendo.`n`nEn modo Nube no vigila la carpeta de descargas: para una prueba de punta a punta imprime una factura desde Odoo.`n`n'Probar conexion' (pestana Conexion) verifica la URL y el token; 'Ver Log' (pestana Avanzado) muestra el estado de la conexion.",
            "Modo Nube", "OK", "Information"
        ); return
    }
    if ($modeNow -eq "api") {
        # En Red local solo se imprime lo que Odoo encola: un PDF dejado en la
        # carpeta nunca se imprimiria y quedaria olvidado.
        $port = [int]$nudPort.Value
        [System.Windows.Forms.MessageBox]::Show(
            "El monitor esta corriendo.`n`nEn modo Red local solo imprime lo que Odoo le envia: un archivo dejado en la carpeta no se imprime.`n`nPara probar de punta a punta:`n- En Odoo: Ajustes > API de integracion > LidaPrint > Probar conexion, e imprimir una factura.`n- Desde esta PC (PowerShell):`n  curl.exe -X POST http://localhost:$port/print/file -H `"X-Api-Key: SU_CLAVE`" -H `"X-Filename: prueba.pdf`" --data-binary `"@C:\ruta\prueba.pdf`"",
            "Modo Red local", "OK", "Information"
        ); return
    }
    $testInvoice = Join-Path $txtDownloads.Text "F-99999999.pdf"
    New-TestPdf $testInvoice "PRUEBA MONITOR LIDAPRINT"
    [System.Windows.Forms.MessageBox]::Show(
        "Factura de prueba creada:`n$testInvoice`n`nEl monitor deberia imprimirla y borrarla en unos segundos.`n`n1. Revisa la impresora (hoja 'PRUEBA MONITOR LIDAPRINT')`n2. Usa 'Ver Log' (pestana Avanzado) para ver el resultado",
        "Prueba en curso", "OK", "Information"
    )
})
$form.Controls.Add($btnTestMonitor)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = "Cancelar"
$btnCancel.Location = New-Object System.Drawing.Point(400, $btnY)
$btnCancel.Size = New-Object System.Drawing.Size(100, 35)
$btnCancel.BackColor = $dkBtnBg
$btnCancel.ForeColor = $dkTextDim
$btnCancel.FlatStyle = "Flat"
$btnCancel.FlatAppearance.BorderColor = $dkBorder
$btnCancel.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(88, 91, 112)
$btnCancel.Add_Click({ $form.Close() })
$form.Controls.Add($btnCancel)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = "Guardar"
$btnSave.Location = New-Object System.Drawing.Point(510, $btnY)
$btnSave.Size = New-Object System.Drawing.Size(120, 35)
$btnSave.BackColor = $dkGreenBg
$btnSave.ForeColor = $dkGreen
$btnSave.FlatStyle = "Flat"
$btnSave.FlatAppearance.BorderColor = $dkGreen
$btnSave.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(70, 110, 70)
$btnSave.Font = New-Object System.Drawing.Font("Segoe UI", 9, [Drawing.FontStyle]::Bold)
$btnSave.Add_Click({
    # ----- Validaciones antes de guardar -----
    $mode = & $getSelectedMode
    if (-not $cmbPrinter.SelectedItem) {
        [System.Windows.Forms.MessageBox]::Show("Seleccione una impresora.", "Error", "OK", "Error"); return
    }
    if ($cmbPrinter.SelectedItem -match '"') {
        [System.Windows.Forms.MessageBox]::Show("El nombre de impresora no puede contener comillas dobles.`n`nNombre detectado: $($cmbPrinter.SelectedItem)", "Error", "OK", "Error"); return
    }
    # La carpeta solo se usa en Local y Red local; en Nube no se vigila.
    if ($mode -ne "cloud" -and (-not $txtDownloads.Text -or -not (Test-Path $txtDownloads.Text))) {
        [System.Windows.Forms.MessageBox]::Show("La carpeta de descargas no existe o no es accesible.", "Error", "OK", "Error"); return
    }
    if (-not $txtGs.Text -or -not (Test-Path $txtGs.Text)) {
        [System.Windows.Forms.MessageBox]::Show("La ruta de Ghostscript no es valida. Usa 'Detectar' en la pestana Avanzado o re-ejecuta el instalador.", "Error", "OK", "Error"); return
    }
    $dpiValue = 0
    if (-not [int]::TryParse($cmbDPI.Text, [ref]$dpiValue) -or $dpiValue -lt 72 -or $dpiValue -gt 1200) {
        [System.Windows.Forms.MessageBox]::Show("El DPI debe ser un numero entre 72 y 1200 (ej: 203, 300, 600).", "Error", "OK", "Error"); return
    }
    if ($chkUsePattern.Checked) {
        try { [void][regex]::new($txtPattern.Text) }
        catch {
            [System.Windows.Forms.MessageBox]::Show("El patron no es una expresion regular valida:`n$($_.Exception.Message)", "Error", "OK", "Error"); return
        }
    }
    if ($mode -eq "api" -and -not $txtApiKey.Text) {
        [System.Windows.Forms.MessageBox]::Show("El modo Red local (API web) esta activado pero no hay API Key.`n`nPor seguridad, el listener no se inicia sin una clave. Configura una API Key antes de guardar.", "Error", "OK", "Error"); return
    }
    if ($mode -eq "api" -and [int]$nudPort.Value -lt 1024) {
        $r = [System.Windows.Forms.MessageBox]::Show("El puerto $([int]$nudPort.Value) es un puerto reservado (<1024) y puede requerir permisos de administrador. Continuar?", "Advertencia", "YesNo", "Warning")
        if ($r -ne "Yes") { return }
    }
    $cloudCheck = Get-CloudUrlCheck $txtCloudUrl.Text
    if ($mode -eq "cloud") {
        if ($cloudCheck.Error) {
            [System.Windows.Forms.MessageBox]::Show("Modo Nube: $($cloudCheck.Error)", "Error", "OK", "Error"); return
        }
        if (-not $txtCloudToken.Text.Trim()) {
            [System.Windows.Forms.MessageBox]::Show("Modo Nube: falta el token.`n`nLo genera un administrador de Odoo en Ajustes > API de integracion > LidaPrint > Equipos LidaPrint (o en Facturacion > Configuracion > Equipos LidaPrint): abrir el equipo y pulsar Generar token. Pegalo en la pestana Conexion.", "Error", "OK", "Error"); return
        }
        # Avisos que no bloquean: URL con ruta (se guarda sin ella), http:// en
        # la red local y un token con un formato distinto del que genera Odoo.
        $cloudWarns = @()
        if ($cloudCheck.Notice) { $txtCloudUrl.Text = $cloudCheck.Url; $cloudWarns += $cloudCheck.Notice }
        if ($cloudCheck.Warning) { $cloudWarns += $cloudCheck.Warning }
        $tokenWarn = Get-CloudTokenWarning $txtCloudToken.Text
        if ($tokenWarn) { $cloudWarns += $tokenWarn }
        if ($cloudWarns.Count -gt 0) {
            $warnText = $cloudWarns -join "`n`n"
            $r = [System.Windows.Forms.MessageBox]::Show("Modo Nube:`n`n$warnText`n`nContinuar?", "Advertencia", "YesNo", "Warning")
            if ($r -ne "Yes") { return }
        }
    }
    $modeLabel = switch ($mode) { "api" { "Red local (API)" } "cloud" { "Nube" } default { "Local" } }

    $newConfig = [PSCustomObject]@{
        printer        = $cmbPrinter.SelectedItem
        copies         = [int]$nudCopias.Value
        orientation    = $cmbOrient.SelectedItem
        paperSize      = $cmbPaper.SelectedItem
        paperWidth     = [int]$nudWidth.Value
        paperHeight    = [int]$nudHeight.Value
        useCustomPaper = $chkCustom.Checked
        scale          = [int]$nudScale.Value
        dpi            = $dpiValue
        marginTop      = [int]$nudMTop.Value
        marginBottom   = [int]$nudMBot.Value
        marginLeft     = [int]$nudMLeft.Value
        marginRight    = [int]$nudMRight.Value
        continuousForm = $chkContinuous.Checked
        formLength     = [int]$nudFormLen.Value
        topOffset      = [int]$nudTopOff.Value
        linePitch      = [decimal]$nudLinePitch.Value
        gsPath         = $txtGs.Text
        renderAsImage  = $chkRenderImage.Checked
        downloadFolder = $txtDownloads.Text
        installPath    = $scriptDir
        autoStart      = $chkAutoStart.Checked
        enableLogging  = $chkLogging.Checked
        usePattern     = $chkUsePattern.Checked
        invoicePattern = $txtPattern.Text
        mode           = $mode
        # webEnabled se sigue escribiendo, coherente con mode, para lectores viejos.
        webEnabled     = ($mode -eq "api")
        webPort        = [int]$nudPort.Value
        webApiKey      = $txtApiKey.Text
        cloudUrl         = $cloudCheck.Url
        cloudToken       = $txtCloudToken.Text.Trim()
        cloudPollSeconds = [int]$nudCloudPoll.Value
        escposEnabled     = $chkEscpos.Checked
        escposWidthMm     = [decimal]$nudEscWidth.Value
        escposHdpi        = [decimal]$nudEscHdpi.Value
        escposVdpi        = [decimal]$nudEscVdpi.Value
        escposDensity     = [int]$nudEscDensity.Value
        escposLineSpacing = [int]$nudEscLineSp.Value
        escposThreshold   = [int]$nudEscThr.Value
        escposAntialias   = $chkEscAA.Checked
    }

    Save-Config $newConfig

    # La tarea programada SIEMPRE apunta a donde vive este script ($scriptDir),
    # nunca a una ruta guardada que puede estar muerta. Si la tarea existente
    # apunta a otra ruta (instalacion vieja o carpeta movida), se re-registra.
    $taskName = "LidaPrint"
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    $taskStale = $false
    if ($existingTask) {
        $firstAction = $existingTask.Actions | Select-Object -First 1
        # Obsoleta si apunta a otra ruta O si no usa conhost --headless (dev) ni LidaPrint.exe (exe)
        # (lanzadores viejos: Hidden colgaba en Win11, Minimized dejaba ventana cerrable)
        if ($Global:LidaPrintExeDir) {
            $expectedExe = Join-Path $scriptDir "LidaPrint.exe"
            if ($firstAction.Execute -ne $expectedExe -or $firstAction.Arguments -ne "-Service") { $taskStale = $true }
        } else {
            $monitorPath = Join-Path $scriptDir "LidaPrint.ps1"
            if ($firstAction.Arguments -notlike "*$monitorPath*" -or $firstAction.Execute -notlike "*conhost*") { $taskStale = $true }
        }
    }

    if ($chkAutoStart.Checked -and (-not $existingTask -or $taskStale)) {
        try {
            if ($existingTask) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop }
            if ($Global:LidaPrintExeDir) {
                $taskExecute  = Join-Path $scriptDir "LidaPrint.exe"
                $taskArgument = "-Service"
            } else {
                $monitorPath  = Join-Path $scriptDir "LidaPrint.ps1"
                $taskExecute  = "$env:SystemRoot\System32\conhost.exe"
                $taskArgument = "--headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$monitorPath`""
            }
            $action = New-ScheduledTaskAction -Execute $taskExecute -Argument $taskArgument
            $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
            $tsSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 0)
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $tsSettings -Description "LidaPrint - Impresion automatica de facturas Odoo" | Out-Null
            if ($taskStale) {
                [System.Windows.Forms.MessageBox]::Show("La tarea programada apuntaba a una ruta vieja y fue reparada.`nAhora apunta a:`n$taskExecute", "Tarea reparada", "OK", "Information")
            }
        } catch {
            [System.Windows.Forms.MessageBox]::Show("No se pudo registrar la tarea programada: $_`n`nProba ejecutar el Configurator como Administrador una vez.", "Advertencia", "OK", "Warning")
        }
    } elseif (-not $chkAutoStart.Checked -and $existingTask) {
        try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop } catch { }
    }

    # REINICIAR el monitor SIEMPRE que auto-inicio este activo. Dos razones:
    # 1. El monitor lee config.json solo al arrancar: sin reinicio, los cambios
    #    guardados no se aplican.
    # 2. Si el monitor murio al arrancar (ej: primera instalacion con la config
    #    plantilla sin impresora), este es el punto que lo revive.
    $monitorOk = $false
    $monitorProblem = ""
    if ($chkAutoStart.Checked) {
        try {
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            # Matar tambien monitores huerfanos (procesos fuera de la tarea):
            # con el candado de instancia unica, un huerfano vivo bloquearia
            # al monitor nuevo y seguiria corriendo con la config vieja.
            Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -like "*LidaPrint.ps1*" } |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            # Also kill orphan compiled exe monitors (-Service mode), excluding this process
            Get-CimInstance Win32_Process -Filter "Name = 'LidaPrint.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -like "*-Service*" -and $_.ProcessId -ne $PID } |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Milliseconds 500
            Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
            $monitorOk = $true
        } catch {
            $monitorProblem = "No se pudo reiniciar la tarea programada: $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show("No se pudo reiniciar el monitor: $_", "Advertencia", "OK", "Warning")
        }
    } else {
        # Sin auto-inicio no hay tarea programada (se acaba de eliminar): detener
        # el monitor que este corriendo y lanzarlo directo para esta sesion, con
        # el mismo comando que usaria la tarea. Sin esto la config nueva no se
        # aplicaba y el mensaje final decia "reiniciado" sin monitor alguno.
        $btnSave.Enabled = $false
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            Get-LidaPrintMonitorProcess | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Milliseconds 500
            if ($Global:LidaPrintExeDir) {
                Start-Process -FilePath (Join-Path $scriptDir "LidaPrint.exe") -ArgumentList "-Service" -WorkingDirectory $scriptDir -ErrorAction Stop
            } else {
                $monitorPath = Join-Path $scriptDir "LidaPrint.ps1"
                Start-Process -FilePath "$env:SystemRoot\System32\conhost.exe" -ArgumentList "--headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$monitorPath`"" -WorkingDirectory $scriptDir -ErrorAction Stop
            }
            # Confirmar que arranco (hasta ~6 s) sin congelar la ventana:
            # esperas cortas con DoEvents; Guardar queda deshabilitado mientras.
            $deadline = (Get-Date).AddSeconds(6)
            while (-not $monitorOk -and (Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 250
                [System.Windows.Forms.Application]::DoEvents()
                if (Get-LidaPrintMonitorProcess) { $monitorOk = $true }
            }
            if (-not $monitorOk) { $monitorProblem = "No arranco en 6 segundos." }
        } catch {
            $monitorProblem = "No se pudo iniciar: $($_.Exception.Message)"
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
            $btnSave.Enabled = $true
        }
    }

    $summary = "Modo: $modeLabel`nImpresora: $($newConfig.printer)`nCopias: $($newConfig.copies)`nOrientacion: $($newConfig.orientation)`nPaper: $($newConfig.paperSize)`nEscala: $($newConfig.scale)%`nDPI: $($newConfig.dpi)`nMotor: Ghostscript`nForma continua: $($newConfig.continuousForm)`nPatron: $($newConfig.usePattern)"
    if ($monitorOk) {
        $session = if ($chkAutoStart.Checked) { "" } else { "`n(Sin auto-inicio: corre solo en esta sesion; no arrancara solo al iniciar Windows.)" }
        [System.Windows.Forms.MessageBox]::Show(
            "Configuracion guardada. Monitor reiniciado con la nueva configuracion.$session`n`n$summary",
            "Guardado", "OK", "Information"
        )
    } else {
        [System.Windows.Forms.MessageBox]::Show(
            "Configuracion guardada, pero el monitor NO esta corriendo.`n$monitorProblem`n`nRevisa el log (pestana Avanzado > Ver Log) y vuelve a Guardar, o activa 'Auto-iniciar con Windows'.`n`n$summary",
            "Guardado con advertencia", "OK", "Warning"
        )
    }
})
$form.Controls.Add($btnSave)

# ===================== TOOLTIPS =====================
# Las explicaciones largas (antes en parrafos dentro de las pestanas) viven aqui.
# Saltos de linea explicitos: el ToolTip de WinForms no ajusta el texto solo.
$toolTip.SetToolTip($rbLocal,       "Odoo descarga el PDF en esta PC y LidaPrint lo imprime si el nombre`ncoincide con el patron. No requiere red ni puertos.")
$toolTip.SetToolTip($rbApi,         "Odoo (en la misma red) envia cada PDF a esta PC por HTTP.`nRequiere que el servidor de Odoo llegue a esta PC: firewall, urlacl y API Key.")
$toolTip.SetToolTip($rbCloud,       "Esta PC consulta a Odoo por HTTPS (conexion saliente).`nSirve con Odoo en un VPS o en internet: no hay que abrir puertos.")
$toolTip.SetToolTip($txtDownloads,  "Carpeta que vigila el monitor (Local) o donde guarda los PDF recibidos (Red local).")
$toolTip.SetToolTip($txtPattern,    "Expresion regular. El nombre del archivo debe coincidir completamente.")
$toolTip.SetToolTip($chkUsePattern, "Filtra por nombre en modo Local. Sin patron se imprime todo PDF que aparezca.`nSe desactiva en los modos Red local y Nube.")
$toolTip.SetToolTip($nudPort,       "Puerto HTTP del listener. Tras cambiarlo: regla de firewall y urlacl del mismo puerto.")
$toolTip.SetToolTip($txtApiKey,     "Obligatoria en modo Red local. Sin una API Key el listener no arranca.`nEn Odoo va la misma clave.")
$toolTip.SetToolTip($lblApiUrl,     "La URL la usa el SERVIDOR de Odoo: localhost solo sirve si Odoo corre en esta misma PC.")
$toolTip.SetToolTip($txtCloudUrl,   "Direccion base de Odoo, ej: https://cliente.example.com (sin /odoo ni /web: si trae una ruta, se quita al probar o guardar).`nhttp:// solo se admite para localhost o un equipo de la red local.")
$toolTip.SetToolTip($txtCloudToken, "Token del equipo, generado en Odoo (se muestra una sola vez; 43 caracteres).`nSi se revoca el token o se archiva el equipo, Odoo responde 401 y LidaPrint deja de consultar seguido.")
$toolTip.SetToolTip($lblCloudHint,  "Solo un administrador de Odoo. Dos caminos a la misma lista:`n- Ajustes > API de integracion > LidaPrint > boton Equipos LidaPrint (con cualquier destino)`n- Facturacion > Configuracion > Equipos LidaPrint`nCrear o abrir el equipo, pulsar Generar token y pegarlo aqui, antes de pasar el destino de Odoo a Nube.")
$toolTip.SetToolTip($nudCloudPoll,  "Intervalo inicial entre consultas. Odoo puede indicar otro (next_poll) y ese manda.")
$toolTip.SetToolTip($btnCloudTest,  "Llama a GET /ping con la URL y el token escritos aqui (sin guardar).`nNo toma trabajos de la cola.")
$toolTip.SetToolTip($nudCopias,     "Cantidad de copias que se imprimen de cada documento.`nCon Odoo (Red local o Nube) usa 1: Odoo ya envia original y copia.")
$toolTip.SetToolTip($cmbDPI,        "Resolucion de impresion (72-1200). Elegi un preset o escribi el valor a mano.`n203 para matriciales/termicas, 300 para laser.")
$toolTip.SetToolTip($btnUseDpi,     "Usa el DPI que reporta el driver de la impresora seleccionada.")
$toolTip.SetToolTip($chkCustom,     "Habilita ancho y alto manuales; el tamano pasa a 'Custom' automaticamente.")
$toolTip.SetToolTip($nudScale,      "Porcentaje del tamano original (10-200%).")
$marginTip = "Cada margen EMPUJA el contenido en su direccion, sin escalarlo:`nizquierdo -> derecha, derecho -> izquierda, superior -> abajo, inferior -> arriba.`nMargenes opuestos se restan. Si el contenido se sale del papel se recorta:`npara achicarlo usa Escala."
foreach ($c in @($nudMTop, $nudMBot, $nudMLeft, $nudMRight, $lblMarginHint)) { $toolTip.SetToolTip($c, $marginTip) }
$toolTip.SetToolTip($chkContinuous, "Activar solo para impresoras matriciales con papel tractor.")
$toolTip.SetToolTip($nudTopOff,     "Desplazamiento superior en mm: empuja el contenido hacia abajo (forma continua).")
$toolTip.SetToolTip($chkEscpos,     "Para ticketeras 9-agujas/termicas cuyo driver no acepta impresion GDI (ej: EPSON TM-U220`npor adaptador USB-a-paralelo CH340). LidaPrint recorta el PDF al contenido, lo escala`nal ancho imprimible y lo envia como imagen ESC * en bytes crudos.")
$toolTip.SetToolTip($nudEscWidth,   "Ancho fisico maximo del cabezal: la barra de calibracion que llena el papel.`nEl reporte de Odoo debe disenarse a este ancho (pocos caracteres por linea).")
$toolTip.SetToolTip($nudEscHdpi,    "DPI horizontal = puntos / (mm / 25.4). Ej: barra de 400 puntos que mide 64 mm -> 158.75.")
$toolTip.SetToolTip($nudEscVdpi,    "Densidad vertical de la banda. 72 para 9-agujas; subir o bajar si la altura sale estirada o aplastada.")
$toolTip.SetToolTip($nudEscDensity, "Modo ESC *: 0 simple, 1 doble.")
$toolTip.SetToolTip($nudEscLineSp,  "ESC 3 n entre bandas. Imprima bloques solidos y elija el n mas grande sin rayas blancas`n(16 en la TM-U220: unidad 1/144 de pulgada).")
$toolTip.SetToolTip($nudEscThr,     "Umbral de negro (0-255): mas alto = trazo mas grueso.")
$toolTip.SetToolTip($chkEscAA,      "Suavizado al rasterizar: texto chico mas legible en impacto.")
$toolTip.SetToolTip($nudLinePitch,  "Avance extra de papel al final de cada ticket ESC/POS, en mm (0 = sin separacion extra).")
$calibTip = "(1) Imprima las barras y mida cada una: Ancho imprimible = la barra que llena el papel;`nDPI horizontal = puntos / mm x 25.4. (2) Interlineado: bloques solidos, el n mas grande sin`nrayas blancas. (3) Umbral: mas alto = trazo mas grueso."
$toolTip.SetToolTip($btnCalibBars,  $calibTip)
$toolTip.SetToolTip($lblCalibHint,  $calibTip)
$toolTip.SetToolTip($txtGs,         "Ruta a gswin64c.exe. Si queda obsoleta, el monitor la re-resuelve solo al arrancar.")
$toolTip.SetToolTip($chkRenderImage,"Ghostscript rasteriza cada pagina al DPI configurado (203 en matriciales) y la envia ya`nrenderizada, sin depender de como el driver interprete las fuentes.`nSi el texto sale borroso o serruchado, activa el suavizado maximo.")
$toolTip.SetToolTip($nudCvMm,       "pixeles = mm / 25.4 x DPI. Util para el largo de forma continua cuando el fabricante da pixeles.")
$toolTip.SetToolTip($nudCvPx,       "mm = pixeles / DPI x 25.4")
$toolTip.SetToolTip($chkAutoStart,  "Crea (o elimina) la tarea programada que lanza el monitor al iniciar sesion.")
$toolTip.SetToolTip($chkLogging,    "Escribe en logs\PrintLog_yyyy-MM.txt (un archivo por mes).")
$toolTip.SetToolTip($btnTestMonitor,"Local: deja una factura de prueba en la carpeta vigilada.`nRed local y Nube: verifica que el monitor corra y explica como probar desde Odoo.")

# ===================== MOSTRAR =====================
[void]$form.ShowDialog()
$form.Dispose()
