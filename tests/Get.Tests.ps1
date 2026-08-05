Describe "get.ps1 helpers" {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        # Dot-source only the function definitions: load the script text and
        # extract Test-Sha256Sum to avoid running the installer body.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $repoRoot "get.ps1"), [ref]$null, [ref]$null)
        $fn = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) |
              Where-Object Name -eq "Test-Sha256Sum"
        Invoke-Expression $fn.Extent.Text
        $script:tmpFile = Join-Path ([IO.Path]::GetTempPath()) "lidaprint-hashtest.bin"
        [IO.File]::WriteAllBytes($script:tmpFile, [byte[]](1..32))
        $script:goodHash = (Get-FileHash -LiteralPath $script:tmpFile -Algorithm SHA256).Hash
    }
    It "accepts a matching hash" {
        Test-Sha256Sum -FilePath $script:tmpFile -SumsContent "$script:goodHash  LidaPrint.exe" -FileName "LidaPrint.exe" | Should -BeTrue
    }
    It "rejects a wrong hash" {
        $bad = "0" * 64
        Test-Sha256Sum -FilePath $script:tmpFile -SumsContent "$bad  LidaPrint.exe" -FileName "LidaPrint.exe" | Should -BeFalse
    }
    It "rejects when the file is not listed" {
        Test-Sha256Sum -FilePath $script:tmpFile -SumsContent "$script:goodHash  otro.exe" -FileName "LidaPrint.exe" | Should -BeFalse
    }
}
