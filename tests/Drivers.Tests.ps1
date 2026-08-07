Describe "drivers.json manifest" {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $script:manifest = Get-Content (Join-Path $repoRoot "drivers/drivers.json") -Raw | ConvertFrom-Json
        $script:repoRoot = $repoRoot
    }
    It "has schemaVersion 1 and at least 2 drivers" {
        $script:manifest.schemaVersion | Should -Be 1
        @($script:manifest.drivers).Count | Should -BeGreaterOrEqual 2
    }
    It "every entry has the required fields" {
        foreach ($d in $script:manifest.drivers) {
            $d.id      | Should -Match '^[a-z0-9-]+$'
            $d.name    | Should -Not -BeNullOrEmpty
            $d.file    | Should -Match '^drivers/'
            $d.type    | Should -BeIn @("exe", "zip")
            $d.sha256  | Should -Match '^[A-F0-9]{64}$'
        }
    }
    It "every referenced file exists and its hash matches" {
        foreach ($d in $script:manifest.drivers) {
            $path = Join-Path $script:repoRoot $d.file
            Test-Path $path | Should -BeTrue
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash | Should -Be $d.sha256
        }
    }
    It "no driver file exceeds the GitHub 100MB limit" {
        foreach ($d in $script:manifest.drivers) {
            (Get-Item (Join-Path $script:repoRoot $d.file)).Length | Should -BeLessThan 100MB
        }
    }
    It "postInstall (si existe) tiene tipos validos" {
        foreach ($d in $script:manifest.drivers) {
            if ($d.PSObject.Properties.Name -contains 'postInstall' -and $d.postInstall) {
                $pi = $d.postInstall
                if ($pi.PSObject.Properties.Name -contains 'printerNameMatch') { $pi.printerNameMatch | Should -Not -BeNullOrEmpty }
                if ($pi.PSObject.Properties.Name -contains 'usbPortMatch')     { $pi.usbPortMatch     | Should -Not -BeNullOrEmpty }
                foreach ($flag in 'rebindToUsb','disableBidi','clearOffline') {
                    if ($pi.PSObject.Properties.Name -contains $flag) { $pi.$flag | Should -BeOfType [bool] }
                }
            }
        }
    }
    It "el driver EPSON TM-U220 declara la reparacion post-instalacion" {
        $epson = $script:manifest.drivers | Where-Object { $_.id -eq 'epson-tm-u220pd' }
        $epson.postInstall.rebindToUsb | Should -BeTrue
        $epson.postInstall.disableBidi | Should -BeTrue
    }
    It "calibration (si existe) usa claves escpos conocidas y tipos validos" {
        $known = @('escposEnabled','escposWidthMm','escposHdpi','escposVdpi',
                   'escposDensity','escposLineSpacing','escposThreshold','escposAntialias')
        foreach ($d in $script:manifest.drivers) {
            if ($d.PSObject.Properties.Name -contains 'calibration' -and $d.calibration) {
                foreach ($prop in $d.calibration.PSObject.Properties) {
                    $prop.Name | Should -BeIn $known
                }
                foreach ($flag in 'escposEnabled','escposAntialias') {
                    if ($d.calibration.PSObject.Properties.Name -contains $flag) {
                        $d.calibration.$flag | Should -BeOfType [bool]
                    }
                }
                foreach ($num in 'escposWidthMm','escposHdpi','escposVdpi','escposDensity','escposLineSpacing','escposThreshold') {
                    if ($d.calibration.PSObject.Properties.Name -contains $num) {
                        $d.calibration.$num | Should -BeGreaterThan 0
                    }
                }
            }
        }
    }
    It "el driver EPSON TM-U220 trae la calibracion ESC/POS medida" {
        $epson = $script:manifest.drivers | Where-Object { $_.id -eq 'epson-tm-u220pd' }
        $epson.calibration | Should -Not -BeNullOrEmpty
        $epson.calibration.escposEnabled | Should -BeTrue
        $epson.calibration.escposWidthMm | Should -Be 64
        $epson.calibration.escposHdpi | Should -Be 158.75
        $epson.calibration.escposLineSpacing | Should -Be 16
    }
}
