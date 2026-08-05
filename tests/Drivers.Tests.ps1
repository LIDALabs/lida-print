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
}
