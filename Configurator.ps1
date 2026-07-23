<#
.SYNOPSIS
    Configurador grafico para LidaPrint.
.DESCRIPTION
    GUI con Windows Forms en modo oscuro. Organizada en pestanas:
    Impresion, Papel, Forma Continua, Monitoreo, Sistema.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Continue"

# ===================== CARGAR CONFIGURACION =====================
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptDir "config.json"

function Load-Config {
    $cfg = $null
    if (Test-Path $configPath) {
        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
    }
    if (-not $cfg) {
        $cfg = [PSCustomObject]@{
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
            "La configuracion se guardo, pero no se pudo restringir el acceso al archivo config.json.`n`nDetalle: $errDetail`n`nOtros usuarios del sistema podrian leer la API Key si existe.",
            "Advertencia de seguridad", "OK", "Warning"
        ) | Out-Null
    }
}

$config = Load-Config

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
if (Test-Path $logoPath) {
    # Cargar el bitmap una sola vez y mantenerlo en scope de script para
    # evitar que el GC lo libere mientras el formulario lo necesita.
    $script:logoBitmap = New-Object System.Drawing.Bitmap($logoPath)
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

# ===================== TABCONTROL =====================
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(10, $tabY)
$tabs.Size = New-Object System.Drawing.Size(620, 400)
Set-DarkTheme $tabs

# ===================== TAB 1: IMPRESION =====================
$t1 = New-Object System.Windows.Forms.TabPage
$t1.Text = "Impresion"
Set-DarkTheme $t1

$grpPrinter = New-Object System.Windows.Forms.GroupBox
$grpPrinter.Text = "Impresora"
$grpPrinter.Location = New-Object System.Drawing.Point(10, 10)
$grpPrinter.Size = New-Object System.Drawing.Size(590, 60)
Set-DarkTheme $grpPrinter
$t1.Controls.Add($grpPrinter)

$lblPrinter = New-Object System.Windows.Forms.Label
$lblPrinter.Text = "Impresora:"
$lblPrinter.Location = New-Object System.Drawing.Point(10, 25)
$lblPrinter.Size = New-Object System.Drawing.Size(80, 20)
Set-DarkTheme $lblPrinter
$grpPrinter.Controls.Add($lblPrinter)

$cmbPrinter = New-Object System.Windows.Forms.ComboBox
$cmbPrinter.Location = New-Object System.Drawing.Point(100, 23)
$cmbPrinter.Size = New-Object System.Drawing.Size(350, 21)
$cmbPrinter.DropDownStyle = "DropDownList"
foreach ($p in $printers) { $cmbPrinter.Items.Add($p) | Out-Null }
if ($config.printer -and $cmbPrinter.Items.Contains($config.printer)) {
    $cmbPrinter.SelectedItem = $config.printer
} elseif ($cmbPrinter.Items.Count -gt 0) { $cmbPrinter.SelectedIndex = 0 }
Set-DarkTheme $cmbPrinter
$grpPrinter.Controls.Add($cmbPrinter)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = "Refrescar"
$btnRefresh.Location = New-Object System.Drawing.Point(470, 22)
$btnRefresh.Size = New-Object System.Drawing.Size(100, 23)
$btnRefresh.Add_Click({
    $cmbPrinter.Items.Clear()
    foreach ($p in (Get-PrinterList)) { $cmbPrinter.Items.Add($p) | Out-Null }
    if ($cmbPrinter.Items.Count -gt 0) { $cmbPrinter.SelectedIndex = 0 }
})
Set-DarkTheme $btnRefresh
$grpPrinter.Controls.Add($btnRefresh)

$grpOptions = New-Object System.Windows.Forms.GroupBox
$grpOptions.Text = "Opciones de impresion"
$grpOptions.Location = New-Object System.Drawing.Point(10, 80)
$grpOptions.Size = New-Object System.Drawing.Size(590, 60)
Set-DarkTheme $grpOptions
$t1.Controls.Add($grpOptions)

$lblCopies = New-Object System.Windows.Forms.Label
$lblCopies.Text = "Copias:"
$lblCopies.Location = New-Object System.Drawing.Point(10, 25)
$lblCopies.Size = New-Object System.Drawing.Size(60, 20)
Set-DarkTheme $lblCopies
$grpOptions.Controls.Add($lblCopies)

$nudCopias = New-Object System.Windows.Forms.NumericUpDown
$nudCopias.Location = New-Object System.Drawing.Point(80, 23)
$nudCopias.Size = New-Object System.Drawing.Size(60, 20)
$nudCopias.Minimum = 1
$nudCopias.Maximum = 10
$nudCopias.Value = $config.copies
Set-DarkTheme $nudCopias
$grpOptions.Controls.Add($nudCopias)

$lblOrient = New-Object System.Windows.Forms.Label
$lblOrient.Text = "Orientacion:"
$lblOrient.Location = New-Object System.Drawing.Point(160, 25)
$lblOrient.Size = New-Object System.Drawing.Size(80, 20)
Set-DarkTheme $lblOrient
$grpOptions.Controls.Add($lblOrient)

$cmbOrient = New-Object System.Windows.Forms.ComboBox
$cmbOrient.Location = New-Object System.Drawing.Point(250, 23)
$cmbOrient.Size = New-Object System.Drawing.Size(100, 21)
$cmbOrient.DropDownStyle = "DropDownList"
@("portrait", "landscape") | ForEach-Object { $cmbOrient.Items.Add($_) | Out-Null }
if ($config.orientation -eq "landscape") { $cmbOrient.SelectedIndex = 1 } else { $cmbOrient.SelectedIndex = 0 }
Set-DarkTheme $cmbOrient
$grpOptions.Controls.Add($cmbOrient)

$grpQuality = New-Object System.Windows.Forms.GroupBox
$grpQuality.Text = "Calidad"
$grpQuality.Location = New-Object System.Drawing.Point(10, 150)
$grpQuality.Size = New-Object System.Drawing.Size(590, 88)
Set-DarkTheme $grpQuality
$t1.Controls.Add($grpQuality)

$lblScale = New-Object System.Windows.Forms.Label
$lblScale.Text = "Escala (%):"
$lblScale.Location = New-Object System.Drawing.Point(10, 25)
$lblScale.Size = New-Object System.Drawing.Size(80, 20)
Set-DarkTheme $lblScale
$grpQuality.Controls.Add($lblScale)

$nudScale = New-Object System.Windows.Forms.NumericUpDown
$nudScale.Location = New-Object System.Drawing.Point(100, 23)
$nudScale.Size = New-Object System.Drawing.Size(60, 20)
$nudScale.Minimum = 10
$nudScale.Maximum = 200
$nudScale.Value = $config.scale
Set-DarkTheme $nudScale
$grpQuality.Controls.Add($nudScale)

$lblDPI = New-Object System.Windows.Forms.Label
$lblDPI.Text = "DPI:"
$lblDPI.Location = New-Object System.Drawing.Point(180, 25)
$lblDPI.Size = New-Object System.Drawing.Size(40, 20)
Set-DarkTheme $lblDPI
$grpQuality.Controls.Add($lblDPI)

$cmbDPI = New-Object System.Windows.Forms.ComboBox
$cmbDPI.Location = New-Object System.Drawing.Point(230, 23)
$cmbDPI.Size = New-Object System.Drawing.Size(80, 21)
# DropDown (editable): permite escribir un DPI a mano ademas de los presets.
# Se valida al Guardar (72-1200).
$cmbDPI.DropDownStyle = "DropDown"
@("72", "96", "150", "203", "240", "300", "600") | ForEach-Object { $cmbDPI.Items.Add($_) | Out-Null }
$cmbDPI.Text = if ($config.dpi) { $config.dpi.ToString() } else { "300" }
Set-DarkTheme $cmbDPI
$grpQuality.Controls.Add($cmbDPI)

# DPI por defecto del driver de la impresora seleccionada
$lblPrinterDpi = New-Object System.Windows.Forms.Label
$lblPrinterDpi.Text = ""
$lblPrinterDpi.Location = New-Object System.Drawing.Point(10, 56)
$lblPrinterDpi.Size = New-Object System.Drawing.Size(390, 20)
$lblPrinterDpi.ForeColor = $dkAccent
$grpQuality.Controls.Add($lblPrinterDpi)

$btnUseDpi = New-Object System.Windows.Forms.Button
$btnUseDpi.Text = "Usar este DPI"
$btnUseDpi.Location = New-Object System.Drawing.Point(410, 52)
$btnUseDpi.Size = New-Object System.Drawing.Size(110, 23)
$btnUseDpi.Enabled = $false
Set-DarkTheme $btnUseDpi
$grpQuality.Controls.Add($btnUseDpi)

$script:printerDefaultDpi = $null
$updatePrinterDpiHint = {
    $script:printerDefaultDpi = $null
    $btnUseDpi.Enabled = $false
    if ($cmbPrinter.SelectedItem) {
        $res = Get-PrinterDefaultDpi $cmbPrinter.SelectedItem
        if ($res) {
            $script:printerDefaultDpi = $res[0]
            $lblPrinterDpi.Text = "DPI por defecto del driver: $($res[0]) x $($res[1])"
            $btnUseDpi.Enabled = $true
        } else {
            $lblPrinterDpi.Text = "DPI por defecto del driver: no reportado"
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

$tabs.TabPages.Add($t1)

# ===================== TAB 2: PAPEL =====================
$t2 = New-Object System.Windows.Forms.TabPage
$t2.Text = "Papel"
Set-DarkTheme $t2

$grpPaper = New-Object System.Windows.Forms.GroupBox
$grpPaper.Text = "Tamano de papel"
$grpPaper.Location = New-Object System.Drawing.Point(10, 10)
$grpPaper.Size = New-Object System.Drawing.Size(590, 100)
Set-DarkTheme $grpPaper
$t2.Controls.Add($grpPaper)

$lblPaper = New-Object System.Windows.Forms.Label
$lblPaper.Text = "Paper Size:"
$lblPaper.Location = New-Object System.Drawing.Point(10, 25)
$lblPaper.Size = New-Object System.Drawing.Size(80, 20)
Set-DarkTheme $lblPaper
$grpPaper.Controls.Add($lblPaper)

$cmbPaper = New-Object System.Windows.Forms.ComboBox
$cmbPaper.Location = New-Object System.Drawing.Point(100, 23)
$cmbPaper.Size = New-Object System.Drawing.Size(120, 21)
$cmbPaper.DropDownStyle = "DropDownList"
@("A4", "Letter", "Legal", "Tabloid", "A5", "Continuo", "Custom") | ForEach-Object { $cmbPaper.Items.Add($_) | Out-Null }
$paperIdx = $cmbPaper.Items.IndexOf($config.paperSize)
if ($paperIdx -ge 0) { $cmbPaper.SelectedIndex = $paperIdx } else { $cmbPaper.SelectedIndex = 0 }
Set-DarkTheme $cmbPaper
$grpPaper.Controls.Add($cmbPaper)

$chkCustom = New-Object System.Windows.Forms.CheckBox
$chkCustom.Text = "Tamano personalizado (mm)"
$chkCustom.Location = New-Object System.Drawing.Point(10, 55)
$chkCustom.Size = New-Object System.Drawing.Size(200, 20)
$chkCustom.Checked = $config.useCustomPaper
Set-DarkTheme $chkCustom
$grpPaper.Controls.Add($chkCustom)

$lblWidth = New-Object System.Windows.Forms.Label
$lblWidth.Text = "Ancho:"
$lblWidth.Location = New-Object System.Drawing.Point(220, 57)
$lblWidth.Size = New-Object System.Drawing.Size(50, 20)
Set-DarkTheme $lblWidth
$grpPaper.Controls.Add($lblWidth)

$nudWidth = New-Object System.Windows.Forms.NumericUpDown
$nudWidth.Location = New-Object System.Drawing.Point(280, 55)
$nudWidth.Size = New-Object System.Drawing.Size(70, 20)
$nudWidth.Minimum = 50
$nudWidth.Maximum = 2000
$nudWidth.Value = $config.paperWidth
$nudWidth.Enabled = $config.useCustomPaper
Set-DarkTheme $nudWidth
$grpPaper.Controls.Add($nudWidth)

$lblHeight = New-Object System.Windows.Forms.Label
$lblHeight.Text = "Alto:"
$lblHeight.Location = New-Object System.Drawing.Point(360, 57)
$lblHeight.Size = New-Object System.Drawing.Size(40, 20)
Set-DarkTheme $lblHeight
$grpPaper.Controls.Add($lblHeight)

$nudHeight = New-Object System.Windows.Forms.NumericUpDown
$nudHeight.Location = New-Object System.Drawing.Point(410, 55)
$nudHeight.Size = New-Object System.Drawing.Size(70, 20)
$nudHeight.Minimum = 50
$nudHeight.Maximum = 2000
$nudHeight.Value = $config.paperHeight
$nudHeight.Enabled = $config.useCustomPaper
Set-DarkTheme $nudHeight
$grpPaper.Controls.Add($nudHeight)

$lblmm = New-Object System.Windows.Forms.Label
$lblmm.Text = "mm"
$lblmm.Location = New-Object System.Drawing.Point(490, 57)
$lblmm.Size = New-Object System.Drawing.Size(30, 20)
Set-DarkTheme $lblmm
$grpPaper.Controls.Add($lblmm)

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

$grpMargins = New-Object System.Windows.Forms.GroupBox
$grpMargins.Text = "Margenes (mm) - cada uno empuja el contenido en su direccion, sin escalarlo"
$grpMargins.Location = New-Object System.Drawing.Point(10, 120)
$grpMargins.Size = New-Object System.Drawing.Size(590, 70)
Set-DarkTheme $grpMargins
$t2.Controls.Add($grpMargins)

$lblMTop = New-Object System.Windows.Forms.Label
$lblMTop.Text = "Superior:"
$lblMTop.Location = New-Object System.Drawing.Point(10, 25)
$lblMTop.Size = New-Object System.Drawing.Size(70, 20)
Set-DarkTheme $lblMTop
$grpMargins.Controls.Add($lblMTop)

$nudMTop = New-Object System.Windows.Forms.NumericUpDown
$nudMTop.Location = New-Object System.Drawing.Point(90, 23)
$nudMTop.Size = New-Object System.Drawing.Size(60, 20)
$nudMTop.Minimum = 0
$nudMTop.Maximum = 200
$nudMTop.Value = $config.marginTop
Set-DarkTheme $nudMTop
$grpMargins.Controls.Add($nudMTop)

$lblMBot = New-Object System.Windows.Forms.Label
$lblMBot.Text = "Inferior:"
$lblMBot.Location = New-Object System.Drawing.Point(170, 25)
$lblMBot.Size = New-Object System.Drawing.Size(70, 20)
Set-DarkTheme $lblMBot
$grpMargins.Controls.Add($lblMBot)

$nudMBot = New-Object System.Windows.Forms.NumericUpDown
$nudMBot.Location = New-Object System.Drawing.Point(250, 23)
$nudMBot.Size = New-Object System.Drawing.Size(60, 20)
$nudMBot.Minimum = 0
$nudMBot.Maximum = 200
$nudMBot.Value = $config.marginBottom
Set-DarkTheme $nudMBot
$grpMargins.Controls.Add($nudMBot)

$lblMLeft = New-Object System.Windows.Forms.Label
$lblMLeft.Text = "Izquierdo:"
$lblMLeft.Location = New-Object System.Drawing.Point(330, 25)
$lblMLeft.Size = New-Object System.Drawing.Size(70, 20)
Set-DarkTheme $lblMLeft
$grpMargins.Controls.Add($lblMLeft)

$nudMLeft = New-Object System.Windows.Forms.NumericUpDown
$nudMLeft.Location = New-Object System.Drawing.Point(410, 23)
$nudMLeft.Size = New-Object System.Drawing.Size(60, 20)
$nudMLeft.Minimum = 0
$nudMLeft.Maximum = 200
$nudMLeft.Value = $config.marginLeft
Set-DarkTheme $nudMLeft
$grpMargins.Controls.Add($nudMLeft)

$lblMRight = New-Object System.Windows.Forms.Label
$lblMRight.Text = "Derecho:"
$lblMRight.Location = New-Object System.Drawing.Point(10, 50)
$lblMRight.Size = New-Object System.Drawing.Size(70, 20)
Set-DarkTheme $lblMRight
$grpMargins.Controls.Add($lblMRight)

$nudMRight = New-Object System.Windows.Forms.NumericUpDown
$nudMRight.Location = New-Object System.Drawing.Point(90, 48)
$nudMRight.Size = New-Object System.Drawing.Size(60, 20)
$nudMRight.Minimum = 0
$nudMRight.Maximum = 200
$nudMRight.Value = $config.marginRight
Set-DarkTheme $nudMRight
$grpMargins.Controls.Add($nudMRight)

$tabs.TabPages.Add($t2)

# ===================== TAB 3: FORMA CONTINUA =====================
$t3 = New-Object System.Windows.Forms.TabPage
$t3.Text = "Forma Continua"
Set-DarkTheme $t3

$grpContinuous = New-Object System.Windows.Forms.GroupBox
$grpContinuous.Text = "Configuracion de forma continua"
$grpContinuous.Location = New-Object System.Drawing.Point(10, 10)
$grpContinuous.Size = New-Object System.Drawing.Size(590, 100)
Set-DarkTheme $grpContinuous
$t3.Controls.Add($grpContinuous)

$chkContinuous = New-Object System.Windows.Forms.CheckBox
$chkContinuous.Text = "Activar modo forma continua"
$chkContinuous.Location = New-Object System.Drawing.Point(10, 25)
$chkContinuous.Size = New-Object System.Drawing.Size(250, 20)
$chkContinuous.Checked = $config.continuousForm
Set-DarkTheme $chkContinuous
$grpContinuous.Controls.Add($chkContinuous)

$lblFormLen = New-Object System.Windows.Forms.Label
$lblFormLen.Text = "Largo del formulario (mm):"
$lblFormLen.Location = New-Object System.Drawing.Point(10, 55)
$lblFormLen.Size = New-Object System.Drawing.Size(170, 20)
Set-DarkTheme $lblFormLen
$grpContinuous.Controls.Add($lblFormLen)

$nudFormLen = New-Object System.Windows.Forms.NumericUpDown
$nudFormLen.Location = New-Object System.Drawing.Point(190, 53)
$nudFormLen.Size = New-Object System.Drawing.Size(70, 20)
$nudFormLen.Minimum = 50
$nudFormLen.Maximum = 5000
$nudFormLen.Value = $config.formLength
Set-DarkTheme $nudFormLen
$grpContinuous.Controls.Add($nudFormLen)

$lblTopOff = New-Object System.Windows.Forms.Label
$lblTopOff.Text = "Desplazamiento superior (mm):"
$lblTopOff.Location = New-Object System.Drawing.Point(10, 80)
$lblTopOff.Size = New-Object System.Drawing.Size(190, 20)
Set-DarkTheme $lblTopOff
$grpContinuous.Controls.Add($lblTopOff)

$nudTopOff = New-Object System.Windows.Forms.NumericUpDown
$nudTopOff.Location = New-Object System.Drawing.Point(210, 78)
$nudTopOff.Size = New-Object System.Drawing.Size(70, 20)
$nudTopOff.Minimum = 0
$nudTopOff.Maximum = 500
$nudTopOff.Value = $config.topOffset
Set-DarkTheme $nudTopOff
$grpContinuous.Controls.Add($nudTopOff)

$grpAlignment = New-Object System.Windows.Forms.GroupBox
$grpAlignment.Text = "Alineacion de contenido"
$grpAlignment.Location = New-Object System.Drawing.Point(10, 120)
$grpAlignment.Size = New-Object System.Drawing.Size(590, 60)
Set-DarkTheme $grpAlignment
$t3.Controls.Add($grpAlignment)

$lblLinePitch = New-Object System.Windows.Forms.Label
$lblLinePitch.Text = "Salto de linea / Interlineado (mm):"
$lblLinePitch.Location = New-Object System.Drawing.Point(10, 25)
$lblLinePitch.Size = New-Object System.Drawing.Size(220, 20)
Set-DarkTheme $lblLinePitch
$grpAlignment.Controls.Add($lblLinePitch)

$nudLinePitch = New-Object System.Windows.Forms.NumericUpDown
$nudLinePitch.Location = New-Object System.Drawing.Point(240, 23)
$nudLinePitch.Size = New-Object System.Drawing.Size(70, 20)
$nudLinePitch.Minimum = 1
$nudLinePitch.Maximum = 100
$nudLinePitch.DecimalPlaces = 1
$nudLinePitch.Increment = 0.1
$nudLinePitch.Value = $config.linePitch
Set-DarkTheme $nudLinePitch
$grpAlignment.Controls.Add($nudLinePitch)

$tabs.TabPages.Add($t3)

# ===================== TAB: CALIDAD =====================
$tQ = New-Object System.Windows.Forms.TabPage
$tQ.Text = "Calidad"
Set-DarkTheme $tQ

$grpEngine = New-Object System.Windows.Forms.GroupBox
$grpEngine.Text = "Motor de impresion: Ghostscript"
$grpEngine.Location = New-Object System.Drawing.Point(10, 10)
$grpEngine.Size = New-Object System.Drawing.Size(590, 90)
Set-DarkTheme $grpEngine
$tQ.Controls.Add($grpEngine)

$chkRenderImage = New-Object System.Windows.Forms.CheckBox
$chkRenderImage.Text = "Suavizado maximo de texto y graficos (renderizar como imagen)"
$chkRenderImage.Location = New-Object System.Drawing.Point(10, 22)
$chkRenderImage.Size = New-Object System.Drawing.Size(420, 20)
$chkRenderImage.Checked = [bool]$config.renderAsImage
Set-DarkTheme $chkRenderImage
$grpEngine.Controls.Add($chkRenderImage)

$lblGs = New-Object System.Windows.Forms.Label
$lblGs.Text = "Ghostscript:"
$lblGs.Location = New-Object System.Drawing.Point(10, 52)
$lblGs.Size = New-Object System.Drawing.Size(75, 20)
Set-DarkTheme $lblGs
$grpEngine.Controls.Add($lblGs)

$txtGs = New-Object System.Windows.Forms.TextBox
$txtGs.Location = New-Object System.Drawing.Point(90, 50)
$txtGs.Size = New-Object System.Drawing.Size(330, 20)
$txtGs.Text = if ($config.gsPath) { $config.gsPath } else { Find-Ghostscript }
Set-DarkTheme $txtGs
$grpEngine.Controls.Add($txtGs)

$btnBrowseGs = New-Object System.Windows.Forms.Button
$btnBrowseGs.Text = "..."
$btnBrowseGs.Location = New-Object System.Drawing.Point(430, 49)
$btnBrowseGs.Size = New-Object System.Drawing.Size(45, 23)
$btnBrowseGs.Add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = "Ghostscript|gswin64c.exe;gswin32c.exe"
    if ($ofd.ShowDialog() -eq "OK") { $txtGs.Text = $ofd.FileName }
})
Set-DarkTheme $btnBrowseGs
$grpEngine.Controls.Add($btnBrowseGs)

$btnDetectGs = New-Object System.Windows.Forms.Button
$btnDetectGs.Text = "Detectar"
$btnDetectGs.Location = New-Object System.Drawing.Point(480, 49)
$btnDetectGs.Size = New-Object System.Drawing.Size(90, 23)
$btnDetectGs.Add_Click({
    $found = Find-Ghostscript
    if ($found) { $txtGs.Text = $found }
    else { [System.Windows.Forms.MessageBox]::Show("Ghostscript no encontrado. Instalalo con el instalador o desde ghostscript.com", "Info", "OK", "Information") }
})
Set-DarkTheme $btnDetectGs
$grpEngine.Controls.Add($btnDetectGs)

$grpConv = New-Object System.Windows.Forms.GroupBox
$grpConv.Text = "Conversor DPI / pixeles (para forma continua)"
$grpConv.Location = New-Object System.Drawing.Point(10, 110)
$grpConv.Size = New-Object System.Drawing.Size(590, 110)
Set-DarkTheme $grpConv
$tQ.Controls.Add($grpConv)

# Fila 1: mm + DPI -> pixeles
$lblCvMm = New-Object System.Windows.Forms.Label
$lblCvMm.Text = "Milimetros:"
$lblCvMm.Location = New-Object System.Drawing.Point(10, 28)
$lblCvMm.Size = New-Object System.Drawing.Size(70, 20)
Set-DarkTheme $lblCvMm
$grpConv.Controls.Add($lblCvMm)

$nudCvMm = New-Object System.Windows.Forms.NumericUpDown
$nudCvMm.Location = New-Object System.Drawing.Point(85, 26)
$nudCvMm.Size = New-Object System.Drawing.Size(80, 20)
$nudCvMm.Minimum = 1; $nudCvMm.Maximum = 5000
$nudCvMm.DecimalPlaces = 1; $nudCvMm.Increment = 0.5
$nudCvMm.Value = 210
Set-DarkTheme $nudCvMm
$grpConv.Controls.Add($nudCvMm)

$lblCvDpi1 = New-Object System.Windows.Forms.Label
$lblCvDpi1.Text = "a DPI:"
$lblCvDpi1.Location = New-Object System.Drawing.Point(175, 28)
$lblCvDpi1.Size = New-Object System.Drawing.Size(45, 20)
Set-DarkTheme $lblCvDpi1
$grpConv.Controls.Add($lblCvDpi1)

$nudCvDpi1 = New-Object System.Windows.Forms.NumericUpDown
$nudCvDpi1.Location = New-Object System.Drawing.Point(225, 26)
$nudCvDpi1.Size = New-Object System.Drawing.Size(70, 20)
$nudCvDpi1.Minimum = 72; $nudCvDpi1.Maximum = 1200
$nudCvDpi1.Value = 203
Set-DarkTheme $nudCvDpi1
$grpConv.Controls.Add($nudCvDpi1)

$lblCvPxOut = New-Object System.Windows.Forms.Label
$lblCvPxOut.Text = ""
$lblCvPxOut.Location = New-Object System.Drawing.Point(310, 28)
$lblCvPxOut.Size = New-Object System.Drawing.Size(260, 20)
$lblCvPxOut.ForeColor = $dkAccent
$lblCvPxOut.Font = New-Object System.Drawing.Font("Consolas", 9)
$grpConv.Controls.Add($lblCvPxOut)

# Fila 2: pixeles + DPI -> mm
$lblCvPx = New-Object System.Windows.Forms.Label
$lblCvPx.Text = "Pixeles:"
$lblCvPx.Location = New-Object System.Drawing.Point(10, 62)
$lblCvPx.Size = New-Object System.Drawing.Size(70, 20)
Set-DarkTheme $lblCvPx
$grpConv.Controls.Add($lblCvPx)

$nudCvPx = New-Object System.Windows.Forms.NumericUpDown
$nudCvPx.Location = New-Object System.Drawing.Point(85, 60)
$nudCvPx.Size = New-Object System.Drawing.Size(80, 20)
$nudCvPx.Minimum = 1; $nudCvPx.Maximum = 100000
$nudCvPx.Value = 1678
Set-DarkTheme $nudCvPx
$grpConv.Controls.Add($nudCvPx)

$lblCvDpi2 = New-Object System.Windows.Forms.Label
$lblCvDpi2.Text = "a DPI:"
$lblCvDpi2.Location = New-Object System.Drawing.Point(175, 62)
$lblCvDpi2.Size = New-Object System.Drawing.Size(45, 20)
Set-DarkTheme $lblCvDpi2
$grpConv.Controls.Add($lblCvDpi2)

$nudCvDpi2 = New-Object System.Windows.Forms.NumericUpDown
$nudCvDpi2.Location = New-Object System.Drawing.Point(225, 60)
$nudCvDpi2.Size = New-Object System.Drawing.Size(70, 20)
$nudCvDpi2.Minimum = 72; $nudCvDpi2.Maximum = 1200
$nudCvDpi2.Value = 203
Set-DarkTheme $nudCvDpi2
$grpConv.Controls.Add($nudCvDpi2)

$lblCvMmOut = New-Object System.Windows.Forms.Label
$lblCvMmOut.Text = ""
$lblCvMmOut.Location = New-Object System.Drawing.Point(310, 62)
$lblCvMmOut.Size = New-Object System.Drawing.Size(260, 20)
$lblCvMmOut.ForeColor = $dkAccent
$lblCvMmOut.Font = New-Object System.Drawing.Font("Consolas", 9)
$grpConv.Controls.Add($lblCvMmOut)

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

$lblQHint = New-Object System.Windows.Forms.Label
$lblQHint.Text = "Ghostscript rasteriza cada pagina al DPI exacto configurado (203 en matriciales / forma continua) y la envia ya renderizada, sin depender de como el driver interprete las fuentes. Si el texto imprime borroso, activa el suavizado maximo."
$lblQHint.Location = New-Object System.Drawing.Point(12, 228)
$lblQHint.Size = New-Object System.Drawing.Size(585, 50)
Set-DarkTheme $lblQHint
$tQ.Controls.Add($lblQHint)

$tabs.TabPages.Add($tQ)

# ===================== TAB 4: MONITOREO =====================
$t4 = New-Object System.Windows.Forms.TabPage
$t4.Text = "Monitoreo"
Set-DarkTheme $t4

$grpFiles = New-Object System.Windows.Forms.GroupBox
$grpFiles.Text = "Carpeta de archivos"
$grpFiles.Location = New-Object System.Drawing.Point(10, 10)
$grpFiles.Size = New-Object System.Drawing.Size(590, 100)
Set-DarkTheme $grpFiles
$t4.Controls.Add($grpFiles)

$lblDownloads = New-Object System.Windows.Forms.Label
$lblDownloads.Text = "Descargas:"
$lblDownloads.Location = New-Object System.Drawing.Point(10, 25)
$lblDownloads.Size = New-Object System.Drawing.Size(80, 20)
Set-DarkTheme $lblDownloads
$grpFiles.Controls.Add($lblDownloads)

$txtDownloads = New-Object System.Windows.Forms.TextBox
$txtDownloads.Location = New-Object System.Drawing.Point(100, 23)
$txtDownloads.Size = New-Object System.Drawing.Size(380, 20)
$txtDownloads.Text = $config.downloadFolder
Set-DarkTheme $txtDownloads
$grpFiles.Controls.Add($txtDownloads)

$btnBrowseDL = New-Object System.Windows.Forms.Button
$btnBrowseDL.Text = "..."
$btnBrowseDL.Location = New-Object System.Drawing.Point(490, 22)
$btnBrowseDL.Size = New-Object System.Drawing.Size(45, 23)
$btnBrowseDL.Add_Click({
    $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
    $fbd.Description = "Seleccionar carpeta de descargas"
    if ($fbd.ShowDialog() -eq "OK") { $txtDownloads.Text = $fbd.SelectedPath }
})
Set-DarkTheme $btnBrowseDL
$grpFiles.Controls.Add($btnBrowseDL)

$btnOpenFolder = New-Object System.Windows.Forms.Button
$btnOpenFolder.Text = "Abrir"
$btnOpenFolder.Location = New-Object System.Drawing.Point(540, 22)
$btnOpenFolder.Size = New-Object System.Drawing.Size(45, 23)
$btnOpenFolder.Add_Click({
    if (Test-Path $txtDownloads.Text) {
        Start-Process explorer.exe $txtDownloads.Text
    } else {
        [System.Windows.Forms.MessageBox]::Show("La carpeta no existe.", "Error", "OK", "Warning")
    }
})
Set-DarkTheme $btnOpenFolder
$grpFiles.Controls.Add($btnOpenFolder)

$lblPattern = New-Object System.Windows.Forms.Label
$lblPattern.Text = "Patron factura:"
$lblPattern.Location = New-Object System.Drawing.Point(10, 52)
$lblPattern.Size = New-Object System.Drawing.Size(80, 20)
Set-DarkTheme $lblPattern
$grpFiles.Controls.Add($lblPattern)

$txtPattern = New-Object System.Windows.Forms.TextBox
$txtPattern.Location = New-Object System.Drawing.Point(100, 50)
$txtPattern.Size = New-Object System.Drawing.Size(280, 20)
$txtPattern.Text = $config.invoicePattern
$txtPattern.Font = New-Object System.Drawing.Font("Consolas", 9)
Set-DarkTheme $txtPattern
$grpFiles.Controls.Add($txtPattern)

$chkUsePattern = New-Object System.Windows.Forms.CheckBox
$chkUsePattern.Text = "Usar patron (deshabilitar si usa API)"
$chkUsePattern.Location = New-Object System.Drawing.Point(100, 72)
$chkUsePattern.Size = New-Object System.Drawing.Size(300, 20)
$chkUsePattern.Checked = $config.usePattern
Set-DarkTheme $chkUsePattern
$grpFiles.Controls.Add($chkUsePattern)

$grpWeb = New-Object System.Windows.Forms.GroupBox
$grpWeb.Text = "Conexion Web (API)"
$grpWeb.Location = New-Object System.Drawing.Point(10, 120)
$grpWeb.Size = New-Object System.Drawing.Size(590, 100)
Set-DarkTheme $grpWeb
$t4.Controls.Add($grpWeb)

$chkWeb = New-Object System.Windows.Forms.CheckBox
$chkWeb.Text = "Activar API web (LidaPrint controla que archivos se imprimen)"
$chkWeb.Location = New-Object System.Drawing.Point(10, 22)
$chkWeb.Size = New-Object System.Drawing.Size(400, 20)
$chkWeb.Checked = $config.webEnabled
Set-DarkTheme $chkWeb
$grpWeb.Controls.Add($chkWeb)

$lblPort = New-Object System.Windows.Forms.Label
$lblPort.Text = "Puerto:"
$lblPort.Location = New-Object System.Drawing.Point(10, 50)
$lblPort.Size = New-Object System.Drawing.Size(50, 20)
Set-DarkTheme $lblPort
$grpWeb.Controls.Add($lblPort)

$nudPort = New-Object System.Windows.Forms.NumericUpDown
$nudPort.Location = New-Object System.Drawing.Point(70, 48)
$nudPort.Size = New-Object System.Drawing.Size(70, 20)
$nudPort.Minimum = 1
$nudPort.Maximum = 65535
$nudPort.Value = $config.webPort
Set-DarkTheme $nudPort
$grpWeb.Controls.Add($nudPort)

$lblApiKey = New-Object System.Windows.Forms.Label
$lblApiKey.Text = "API Key:"
$lblApiKey.Location = New-Object System.Drawing.Point(160, 50)
$lblApiKey.Size = New-Object System.Drawing.Size(60, 20)
Set-DarkTheme $lblApiKey
$grpWeb.Controls.Add($lblApiKey)

$txtApiKey = New-Object System.Windows.Forms.TextBox
$txtApiKey.Location = New-Object System.Drawing.Point(230, 48)
$txtApiKey.Size = New-Object System.Drawing.Size(200, 20)
$txtApiKey.Text = $config.webApiKey
$txtApiKey.UseSystemPasswordChar = $true
Set-DarkTheme $txtApiKey
$grpWeb.Controls.Add($txtApiKey)

$lblApiUrl = New-Object System.Windows.Forms.Label
$lblApiUrl.Text = ""
$lblApiUrl.Location = New-Object System.Drawing.Point(10, 75)
$lblApiUrl.Size = New-Object System.Drawing.Size(560, 20)
$lblApiUrl.ForeColor = $dkAccent
$lblApiUrl.Font = New-Object System.Drawing.Font("Consolas", 8)
$grpWeb.Controls.Add($lblApiUrl)

$chkWeb.Add_CheckedChanged({
    $chkUsePattern.Enabled = -not $chkWeb.Checked
    if ($chkWeb.Checked) {
        $chkUsePattern.Checked = $false
        $lblApiUrl.Text = "URL: http://localhost:$([int]$nudPort.Value)/print/status"
    } else {
        $lblApiUrl.Text = ""
    }
})
$nudPort.Add_ValueChanged({
    if ($chkWeb.Checked) { $lblApiUrl.Text = "URL: http://localhost:$([int]$nudPort.Value)/print/status" }
})

$btnToggleKey = New-Object System.Windows.Forms.Button
$btnToggleKey.Text = "Mostrar"
$btnToggleKey.Location = New-Object System.Drawing.Point(440, 47)
$btnToggleKey.Size = New-Object System.Drawing.Size(70, 23)
$btnToggleKey.Add_Click({
    $txtApiKey.UseSystemPasswordChar = -not $txtApiKey.UseSystemPasswordChar
    $btnToggleKey.Text = if ($txtApiKey.UseSystemPasswordChar) { "Mostrar" } else { "Ocultar" }
})
Set-DarkTheme $btnToggleKey
$grpWeb.Controls.Add($btnToggleKey)

$tabs.TabPages.Add($t4)

# ===================== TAB 5: SISTEMA =====================
$t5 = New-Object System.Windows.Forms.TabPage
$t5.Text = "Sistema"
Set-DarkTheme $t5

$grpSystem = New-Object System.Windows.Forms.GroupBox
$grpSystem.Text = "Opciones del sistema"
$grpSystem.Location = New-Object System.Drawing.Point(10, 10)
$grpSystem.Size = New-Object System.Drawing.Size(590, 70)
Set-DarkTheme $grpSystem
$t5.Controls.Add($grpSystem)

$chkAutoStart = New-Object System.Windows.Forms.CheckBox
$chkAutoStart.Text = "Auto-iniciar con Windows (Task Scheduler)"
$chkAutoStart.Location = New-Object System.Drawing.Point(10, 25)
$chkAutoStart.Size = New-Object System.Drawing.Size(350, 20)
$chkAutoStart.Checked = $config.autoStart
Set-DarkTheme $chkAutoStart
$grpSystem.Controls.Add($chkAutoStart)

$chkLogging = New-Object System.Windows.Forms.CheckBox
$chkLogging.Text = "Generar logs de impresion"
$chkLogging.Location = New-Object System.Drawing.Point(10, 50)
$chkLogging.Size = New-Object System.Drawing.Size(250, 20)
$chkLogging.Checked = $config.enableLogging
Set-DarkTheme $chkLogging
$grpSystem.Controls.Add($chkLogging)

$btnViewLog = New-Object System.Windows.Forms.Button
$btnViewLog.Text = "Ver Log"
$btnViewLog.Location = New-Object System.Drawing.Point(280, 46)
$btnViewLog.Size = New-Object System.Drawing.Size(90, 23)
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
Set-DarkTheme $btnViewLog
$grpSystem.Controls.Add($btnViewLog)

$grpExamples = New-Object System.Windows.Forms.GroupBox
$grpExamples.Text = "Ejemplos de nombres validos"
$grpExamples.Location = New-Object System.Drawing.Point(10, 90)
$grpExamples.Size = New-Object System.Drawing.Size(590, 50)
Set-DarkTheme $grpExamples
$t5.Controls.Add($grpExamples)

$lblEx = New-Object System.Windows.Forms.Label
$lblEx.Text = "F-12345678.pdf    ND-00001234.pdf    NC-00005678.pdf"
$lblEx.Location = New-Object System.Drawing.Point(10, 22)
$lblEx.Size = New-Object System.Drawing.Size(500, 20)
$lblEx.Font = New-Object System.Drawing.Font("Consolas", 10)
$lblEx.ForeColor = $dkAccent
$grpExamples.Controls.Add($lblEx)

$tabs.TabPages.Add($t5)

$form.Controls.Add($tabs)

# ===================== BOTONES INFERIORES =====================
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
$btnTest.Text = "Probar Impresion"
$btnTest.Location = New-Object System.Drawing.Point(10, $btnY)
$btnTest.Size = New-Object System.Drawing.Size(150, 35)
$btnTest.BackColor = $dkBtnTest
$btnTest.ForeColor = $dkText
$btnTest.FlatStyle = "Flat"
$btnTest.FlatAppearance.BorderColor = $dkBorder
$btnTest.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(78, 110, 160)
$btnTest.Add_Click({
    if (-not $txtGs.Text -or -not (Test-Path $txtGs.Text)) {
        [System.Windows.Forms.MessageBox]::Show("Ghostscript no encontrado. Usa 'Detectar' en la pestana Calidad o re-ejecuta el instalador.", "Error", "OK", "Error"); return
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

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = "Guardar"
$btnSave.Location = New-Object System.Drawing.Point(170, $btnY)
$btnSave.Size = New-Object System.Drawing.Size(120, 35)
$btnSave.BackColor = $dkGreenBg
$btnSave.ForeColor = $dkGreen
$btnSave.FlatStyle = "Flat"
$btnSave.FlatAppearance.BorderColor = $dkGreen
$btnSave.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(70, 110, 70)
$btnSave.Font = New-Object System.Drawing.Font("Segoe UI", 9, [Drawing.FontStyle]::Bold)
$btnSave.Add_Click({
    # ----- Validaciones antes de guardar -----
    if (-not $cmbPrinter.SelectedItem) {
        [System.Windows.Forms.MessageBox]::Show("Seleccione una impresora.", "Error", "OK", "Error"); return
    }
    if (-not $txtDownloads.Text -or -not (Test-Path $txtDownloads.Text)) {
        [System.Windows.Forms.MessageBox]::Show("La carpeta de descargas no existe o no es accesible.", "Error", "OK", "Error"); return
    }
    if (-not $txtGs.Text -or -not (Test-Path $txtGs.Text)) {
        [System.Windows.Forms.MessageBox]::Show("La ruta de Ghostscript no es valida. Usa 'Detectar' en la pestana Calidad o re-ejecuta el instalador.", "Error", "OK", "Error"); return
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
    if ($chkWeb.Checked -and -not $txtApiKey.Text) {
        [System.Windows.Forms.MessageBox]::Show("La API web esta activada pero no hay API Key.`n`nPor seguridad, el listener no se inicia sin una clave. Configura una API Key antes de guardar.", "Error", "OK", "Error"); return
    }
    if ($chkWeb.Checked -and [int]$nudPort.Value -lt 1024) {
        $r = [System.Windows.Forms.MessageBox]::Show("El puerto $([int]$nudPort.Value) es un puerto reservado (<1024) y puede requerir permisos de administrador. Continuar?", "Advertencia", "YesNo", "Warning")
        if ($r -ne "Yes") { return }
    }

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
        webEnabled     = $chkWeb.Checked
        webPort        = [int]$nudPort.Value
        webApiKey      = $txtApiKey.Text
    }

    Save-Config $newConfig

    # La tarea programada SIEMPRE apunta a donde vive este script ($scriptDir),
    # nunca a una ruta guardada que puede estar muerta. Si la tarea existente
    # apunta a otra ruta (instalacion vieja o carpeta movida), se re-registra.
    $taskName = "LidaPrint"
    $monitorPath = Join-Path $scriptDir "LidaPrint.ps1"
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    $taskStale = $false
    if ($existingTask) {
        $firstAction = $existingTask.Actions | Select-Object -First 1
        # Obsoleta si apunta a otra ruta O si no usa conhost --headless
        # (lanzadores viejos: Hidden colgaba en Win11, Minimized dejaba ventana cerrable)
        if ($firstAction.Arguments -notlike "*$monitorPath*" -or $firstAction.Execute -notlike "*conhost*") { $taskStale = $true }
    }

    if ($chkAutoStart.Checked -and (-not $existingTask -or $taskStale)) {
        try {
            if ($existingTask) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop }
            # conhost --headless: consola sin ventana (esquiva Windows Terminal en Win11,
            # donde Hidden cuelga y ocultar la ventana no funciona). Nada que cerrar.
            $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\conhost.exe" -Argument "--headless powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$monitorPath`""
            $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
            $tsSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 0)
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $tsSettings -Description "LidaPrint - Impresion automatica de facturas Odoo" | Out-Null
            if ($taskStale) {
                [System.Windows.Forms.MessageBox]::Show("La tarea programada apuntaba a una ruta vieja y fue reparada.`nAhora apunta a:`n$monitorPath", "Tarea reparada", "OK", "Information")
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
    if ($chkAutoStart.Checked) {
        try {
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            # Matar tambien monitores huerfanos (procesos fuera de la tarea):
            # con el candado de instancia unica, un huerfano vivo bloquearia
            # al monitor nuevo y seguiria corriendo con la config vieja.
            Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -like "*LidaPrint.ps1*" } |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Milliseconds 500
            Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
        } catch {
            [System.Windows.Forms.MessageBox]::Show("No se pudo reiniciar el monitor: $_", "Advertencia", "OK", "Warning")
        }
    }

    [System.Windows.Forms.MessageBox]::Show(
        "Configuracion guardada. Monitor reiniciado con la nueva configuracion.`n`nImpresora: $($newConfig.printer)`nCopias: $($newConfig.copies)`nOrientacion: $($newConfig.orientation)`nPaper: $($newConfig.paperSize)`nEscala: $($newConfig.scale)%`nDPI: $($newConfig.dpi)`nMotor: Ghostscript`nForma continua: $($newConfig.continuousForm)`nPatron: $($newConfig.usePattern)`nAPI: $($newConfig.webEnabled)",
        "Guardado", "OK", "Information"
    )
})
$form.Controls.Add($btnSave)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = "Cancelar"
$btnCancel.Location = New-Object System.Drawing.Point(300, $btnY)
$btnCancel.Size = New-Object System.Drawing.Size(100, 35)
$btnCancel.BackColor = $dkBtnBg
$btnCancel.ForeColor = $dkTextDim
$btnCancel.FlatStyle = "Flat"
$btnCancel.FlatAppearance.BorderColor = $dkBorder
$btnCancel.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(88, 91, 112)
$btnCancel.Add_Click({ $form.Close() })
$form.Controls.Add($btnCancel)

$btnTestMonitor = New-Object System.Windows.Forms.Button
$btnTestMonitor.Text = "Probar Monitor"
$btnTestMonitor.Location = New-Object System.Drawing.Point(410, $btnY)
$btnTestMonitor.Size = New-Object System.Drawing.Size(150, 35)
$btnTestMonitor.BackColor = $dkBtnTest
$btnTestMonitor.ForeColor = $dkText
$btnTestMonitor.FlatStyle = "Flat"
$btnTestMonitor.FlatAppearance.BorderColor = $dkBorder
$btnTestMonitor.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(78, 110, 160)
$btnTestMonitor.Add_Click({
    # Prueba de punta a punta: crea una factura valida en la carpeta vigilada.
    # Si el monitor esta corriendo, la detecta, imprime y borra en segundos.
    if (-not (Test-Path $txtDownloads.Text)) {
        [System.Windows.Forms.MessageBox]::Show("La carpeta de descargas no existe.", "Error", "OK", "Error"); return
    }
    $monitorProc = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*LidaPrint.ps1*" }
    if (-not $monitorProc) {
        [System.Windows.Forms.MessageBox]::Show("El monitor NO esta corriendo. Guarda la configuracion (boton Guardar) para iniciarlo y proba de nuevo.", "Monitor detenido", "OK", "Warning"); return
    }
    $testInvoice = Join-Path $txtDownloads.Text "F-99999999.pdf"
    New-TestPdf $testInvoice "PRUEBA MONITOR LIDAPRINT"
    [System.Windows.Forms.MessageBox]::Show(
        "Factura de prueba creada:`n$testInvoice`n`nEl monitor deberia imprimirla y borrarla en unos segundos.`n`n1. Revisa la impresora (hoja 'PRUEBA MONITOR LIDAPRINT')`n2. Usa 'Ver Log' (pestana Sistema) para ver el resultado",
        "Prueba en curso", "OK", "Information"
    )
})
$form.Controls.Add($btnTestMonitor)

# ===================== TOOLTIPS =====================
$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.AutoPopDelay = 8000
$toolTip.InitialDelay = 400
$toolTip.ReshowDelay  = 200
$toolTip.SetToolTip($nudCopias,    "Cantidad de copias que se imprimen de cada documento.")
$toolTip.SetToolTip($cmbDPI,       "Resolucion de impresion (72-1200). Elegi un preset o escribi el valor a mano. 203 para matriciales/termicas, 300 para laser.")
$toolTip.SetToolTip($txtPattern,   "Expresion regular. El nombre del archivo debe coincidir completamente.")
$toolTip.SetToolTip($chkUsePattern,"Filtra por nombre en modo local. Se desactiva al usar la API.")
$toolTip.SetToolTip($chkContinuous,"Activar solo para impresoras matriciales con papel tractor.")
$toolTip.SetToolTip($nudLinePitch, "Distancia en mm entre lineas para forma continua. 4.23mm = 6 LPI.")
$toolTip.SetToolTip($txtApiKey,    "Obligatoria cuando la API esta activa. Sin una API Key el listener no arranca.")
$toolTip.SetToolTip($chkWeb,       "En modo API, Odoo decide que archivos se imprimen via HTTP.")
$toolTip.SetToolTip($nudScale,     "Porcentaje del tamano original (10-200%).")

# ===================== MOSTRAR =====================
[void]$form.ShowDialog()
$form.Dispose()
