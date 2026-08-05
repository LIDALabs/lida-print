Describe "Build.ps1 merge" {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $outDir = Join-Path ([IO.Path]::GetTempPath()) "lidaprint-build-test"
        Remove-Item $outDir -Recurse -Force -ErrorAction SilentlyContinue
        & (Join-Path $repoRoot "build/Build.ps1") -Version "9.9.9" -MergeOnly -OutDir $outDir
        $script:mergedPath = Join-Path $outDir "LidaPrint.merged.ps1"
        $script:content = Get-Content $script:mergedPath -Raw
    }
    It "generates the merged script" {
        Test-Path $script:mergedPath | Should -BeTrue
    }
    It "parses without errors" {
        $t = $e = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:mergedPath, [ref]$t, [ref]$e)
        $e.Count | Should -Be 0
    }
    It "starts with the dispatcher param block" {
        $script:content | Should -Match '(?s)^\s*param\(\[switch\]\$Service,\s*\[switch\]\$Uninstall\)'
    }
    It "defines the global contract variables with the given version" {
        # Pester 6: Should -Match does not evaluate method calls inline; pre-assign.
        $patVersion = [regex]::Escape("`$Global:LidaPrintVersion = '9.9.9'")
        $patExeDir  = [regex]::Escape('$Global:LidaPrintExeDir')
        $patLogoB64 = [regex]::Escape('$Global:LidaPrintLogoB64')
        $script:content | Should -Match $patVersion
        $script:content | Should -Match $patExeDir
        $script:content | Should -Match $patLogoB64
    }
    It "embeds the three sources" {
        # Markers present in each source today:
        $script:content | Should -Match 'LidaPrintMonitor'      # mutex in LidaPrint.ps1
        $script:content | Should -Match 'Load-Config'           # function in Configurator.ps1
        $script:content | Should -Match 'AutoPrintFacturas'     # legacy path in uninstall.ps1
    }
    It "neutralizes Write-Host for -noConsole" {
        $script:content | Should -Match 'function\s+Write-Host'
    }
}
