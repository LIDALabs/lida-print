Describe "Proteccion contra reimpresion al arrancar Windows" {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $service = Get-Content (Join-Path $repoRoot "LidaPrint.ps1") -Raw
        $configurator = Get-Content (Join-Path $repoRoot "Configurator.ps1") -Raw
        $installer = Get-Content (Join-Path $repoRoot "Install.ps1") -Raw
        $webInstaller = Get-Content (Join-Path $repoRoot "get.ps1") -Raw
        $config = Get-Content (Join-Path $repoRoot "config.json") -Raw | ConvertFrom-Json
    }

    It "activa el modo de impresion directa en el monitor y los instaladores" {
        $service | Should -Match '\+direct'
        $configurator | Should -Match '\+direct'
        $installer | Should -Match '\+direct'
        $webInstaller | Should -Match '\+direct'
        $configurator | Should -Match 'Verb RunAs'
        $installer | Should -Match 'Verb RunAs'
        $webInstaller | Should -Match 'Verb RunAs'
    }

    It "usa la impresion directa por defecto" {
        $config.directPrint | Should -BeTrue
        $configurator | Should -Match 'directPrint\s*=\s*\$true'
        $webInstaller | Should -Match 'directPrint\s*=\s*\$true'
    }

    It "identifica los trabajos nuevos con el nombre de LidaPrint" {
        $service | Should -Match 'DocumentName \(\$docPsName\)'
        $service | Should -Match 'LidaPrint: " \+ \$fileName'
        $service | Should -Match 'Remove-LidaStalePrinterJobs'
    }

    It "no vacia indiscriminadamente la cola" {
        $service | Should -Match 'Ghostscript \(Output\|document\)'
        $configurator | Should -Match 'Ghostscript \(Output\|document\)'
        $service | Should -Not -Match 'Remove-PrintJob[^\r\n]+foreach'
    }
}
