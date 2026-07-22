<#
.SYNOPSIS
    Configurador grafico para LidaPrint.
.DESCRIPTION
    GUI con Windows Forms en modo oscuro. Organizada en pestanas:
    Impresion, Papel, Forma Continua, Monitoreo, Sistema.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "SilentlyContinue"

# ===================== CARGAR CONFIGURACION =====================
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptDir "config.json"

function Load-Config {
    if (Test-Path $configPath) {
        return Get-Content $configPath -Raw | ConvertFrom-Json
    }
    return [PSCustomObject]@{
        printer = ""; copies = 2; orientation = "portrait"
        paperSize = "A4"; paperWidth = 210; paperHeight = 297
        useCustomPaper = $false; scale = 100; dpi = 300
        marginTop = 0; marginBottom = 0; marginLeft = 0; marginRight = 0
        continuousForm = $false; formLength = 279; topOffset = 0; linePitch = 4.23
        sumatraPath = ""; downloadFolder = (Join-Path $env:USERPROFILE "Downloads")
        installPath = $scriptDir; autoStart = $true; enableLogging = $true
        usePattern = $true; invoicePattern = "^(F|ND|NC)-\d{8}\.pdf$"
        webEnabled = $false; webPort = 8080; webApiKey = ""
    }
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
    } catch { }
}

$config = Load-Config

# ===================== DETECTAR IMPRESORAS =====================
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
    $logoImg = [System.Drawing.Image]::FromFile($logoPath)
    $form.Icon = [System.Drawing.Icon]::FromHandle($logoImg.GetHicon())

    $picLogo = New-Object System.Windows.Forms.PictureBox
    $picLogo.Location = New-Object System.Drawing.Point(10, 8)
    $picLogo.Size = New-Object System.Drawing.Size(40, 40)
    $picLogo.SizeMode = "Zoom"
    $picLogo.Image = [System.Drawing.Image]::FromFile($logoPath)
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
$grpQuality.Size = New-Object System.Drawing.Size(590, 60)
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
$cmbDPI.DropDownStyle = "DropDownList"
@("72", "96", "150", "200", "300", "600") | ForEach-Object { $cmbDPI.Items.Add($_) | Out-Null }
$dpiIdx = $cmbDPI.Items.IndexOf($config.dpi.ToString())
if ($dpiIdx -ge 0) { $cmbDPI.SelectedIndex = $dpiIdx } else { $cmbDPI.SelectedIndex = 4 }
Set-DarkTheme $cmbDPI
$grpQuality.Controls.Add($cmbDPI)

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

$chkCustom.Add_CheckedChanged({ $nudWidth.Enabled = $chkCustom.Checked; $nudHeight.Enabled = $chkCustom.Checked })

$grpMargins = New-Object System.Windows.Forms.GroupBox
$grpMargins.Text = "Margenes (mm) — referencia visual, se aplican desde la impresora"
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

$grpSumatra = New-Object System.Windows.Forms.GroupBox
$grpSumatra.Text = "SumatraPDF"
$grpSumatra.Location = New-Object System.Drawing.Point(10, 120)
$grpSumatra.Size = New-Object System.Drawing.Size(590, 50)
Set-DarkTheme $grpSumatra
$t4.Controls.Add($grpSumatra)

$lblSumatra = New-Object System.Windows.Forms.Label
$lblSumatra.Text = "Ruta:"
$lblSumatra.Location = New-Object System.Drawing.Point(10, 22)
$lblSumatra.Size = New-Object System.Drawing.Size(40, 20)
Set-DarkTheme $lblSumatra
$grpSumatra.Controls.Add($lblSumatra)

$txtSumatra = New-Object System.Windows.Forms.TextBox
$txtSumatra.Location = New-Object System.Drawing.Point(60, 20)
$txtSumatra.Size = New-Object System.Drawing.Size(420, 20)
$txtSumatra.Text = $config.sumatraPath
Set-DarkTheme $txtSumatra
$grpSumatra.Controls.Add($txtSumatra)

$btnBrowseSum = New-Object System.Windows.Forms.Button
$btnBrowseSum.Text = "..."
$btnBrowseSum.Location = New-Object System.Drawing.Point(490, 18)
$btnBrowseSum.Size = New-Object System.Drawing.Size(80, 23)
$btnBrowseSum.Add_Click({
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = "SumatraPDF|SumatraPDF.exe"
    if ($ofd.ShowDialog() -eq "OK") { $txtSumatra.Text = $ofd.FileName }
})
Set-DarkTheme $btnBrowseSum
$grpSumatra.Controls.Add($btnBrowseSum)

$grpWeb = New-Object System.Windows.Forms.GroupBox
$grpWeb.Text = "Conexion Web (API)"
$grpWeb.Location = New-Object System.Drawing.Point(10, 180)
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
    if (-not $txtSumatra.Text -or -not (Test-Path $txtSumatra.Text)) {
        [System.Windows.Forms.MessageBox]::Show("SumatraPDF no encontrado.", "Error", "OK", "Error"); return
    }
    if (-not $cmbPrinter.SelectedItem) {
        [System.Windows.Forms.MessageBox]::Show("Seleccione una impresora.", "Error", "OK", "Error"); return
    }

    $testPdf = Join-Path $env:TEMP "test_invoice_F-00000001.pdf"
    $testContent = @"
%PDF-1.4
1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj
2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj
3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 612 792]/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj
4 0 obj<</Length 44>>stream
BT /F1 24 Tf 100 700 Td (FACTURA DE PRUEBA) Tj ET
endstream
endobj
5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj
xref
0 6
0000000000 65535 f 
0000000009 00000 n 
0000000058 00000 n 
0000000115 00000 n 
0000000266 00000 n 
0000000360 00000 n 
trailer<</Size 6/Root 1 0 R>>
startxref
435
%%EOF
"@
    Set-Content -Path $testPdf -Value $testContent -Encoding ASCII

    $settings = @("1x")
    if ($cmbOrient.SelectedItem) { $settings += $cmbOrient.SelectedItem }
    if ($chkCustom.Checked) {
        $wPts = [math]::Round($nudWidth.Value * 2.835)
        $hPts = [math]::Round($nudHeight.Value * 2.835)
        $settings += "paper=${wPts}x${hPts}"
    } elseif ($cmbPaper.SelectedItem -and $cmbPaper.SelectedItem -notin @("Custom","Continuo")) {
        $settings += "paper=$($cmbPaper.SelectedItem)"
    }
    if ($nudScale.Value -ne 100) { $settings += "scale=$($nudScale.Value)" }
    $settingsStr = $settings -join ","

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $txtSumatra.Text
    $psi.Arguments = "-silent -print-to `"$($cmbPrinter.SelectedItem)`" -print-settings `"$settingsStr`" `"$testPdf`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.WaitForExit()
        if ($proc.ExitCode -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Prueba enviada a $($cmbPrinter.SelectedItem)`nSettings: $settingsStr", "Exito", "OK", "Information")
        } else {
            [System.Windows.Forms.MessageBox]::Show("Error de impresion. Codigo: $($proc.ExitCode)", "Error", "OK", "Error")
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
    if (-not $txtSumatra.Text -or -not (Test-Path $txtSumatra.Text)) {
        [System.Windows.Forms.MessageBox]::Show("La ruta de SumatraPDF no es valida.", "Error", "OK", "Error"); return
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
        dpi            = [int]$cmbDPI.SelectedItem
        marginTop      = [int]$nudMTop.Value
        marginBottom   = [int]$nudMBot.Value
        marginLeft     = [int]$nudMLeft.Value
        marginRight    = [int]$nudMRight.Value
        continuousForm = $chkContinuous.Checked
        formLength     = [int]$nudFormLen.Value
        topOffset      = [int]$nudTopOff.Value
        linePitch      = [decimal]$nudLinePitch.Value
        sumatraPath    = $txtSumatra.Text
        downloadFolder = $txtDownloads.Text
        installPath    = $config.installPath
        autoStart      = $chkAutoStart.Checked
        enableLogging  = $chkLogging.Checked
        usePattern     = $chkUsePattern.Checked
        invoicePattern = $txtPattern.Text
        webEnabled     = $chkWeb.Checked
        webPort        = [int]$nudPort.Value
        webApiKey      = $txtApiKey.Text
    }

    Save-Config $newConfig

    $taskName = "LidaPrint"
    $existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

    if ($chkAutoStart.Checked -and -not $existingTask) {
        $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$($config.installPath)\LidaPrint.ps1`""
        $triggers = @(
            (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME),
            (New-ScheduledTaskTrigger -AtStartup)
        )
        $tsSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 0)
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Settings $tsSettings -Description "LidaPrint - Impresion automatica de facturas Odoo" -RunLevel Highest | Out-Null
    } elseif (-not $chkAutoStart.Checked -and $existingTask) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }

    [System.Windows.Forms.MessageBox]::Show(
        "Configuracion guardada.`n`nImpresora: $($newConfig.printer)`nCopias: $($newConfig.copies)`nOrientacion: $($newConfig.orientation)`nPaper: $($newConfig.paperSize)`nEscala: $($newConfig.scale)%`nDPI: $($newConfig.dpi)`nMargenes: T=$($newConfig.marginTop) B=$($newConfig.marginBottom) L=$($newConfig.marginLeft) R=$($newConfig.marginRight)mm`nForma continua: $($newConfig.continuousForm)`nPatron: $($newConfig.usePattern)`nAPI: $($newConfig.webEnabled)",
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

# ===================== TOOLTIPS =====================
$toolTip = New-Object System.Windows.Forms.ToolTip
$toolTip.AutoPopDelay = 8000
$toolTip.InitialDelay = 400
$toolTip.ReshowDelay  = 200
$toolTip.SetToolTip($nudCopias,    "Cantidad de copias que se imprimen de cada documento.")
$toolTip.SetToolTip($cmbDPI,       "Resolucion de impresion. 300 es suficiente para la mayoria de impresoras.")
$toolTip.SetToolTip($txtPattern,   "Expresion regular. El nombre del archivo debe coincidir completamente.")
$toolTip.SetToolTip($chkUsePattern,"Filtra por nombre en modo local. Se desactiva al usar la API.")
$toolTip.SetToolTip($chkContinuous,"Activar solo para impresoras matriciales con papel tractor.")
$toolTip.SetToolTip($nudLinePitch, "Distancia en mm entre lineas para forma continua. 4.23mm = 6 LPI.")
$toolTip.SetToolTip($txtApiKey,    "Dejar vacio para no requerir autenticacion.")
$toolTip.SetToolTip($chkWeb,       "En modo API, Odoo decide que archivos se imprimen via HTTP.")
$toolTip.SetToolTip($nudScale,     "Porcentaje del tamano original (10-200%).")

# ===================== MOSTRAR =====================
[void]$form.ShowDialog()
$form.Dispose()
