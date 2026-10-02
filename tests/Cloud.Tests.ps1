# Pruebas del modo Nube: funciones puras de LidaPrint.ps1 y Configurator.ps1.
# Como en Get.Tests.ps1, solo se cargan las definiciones de funciones (via
# AST): ningun script se ejecuta. El reloj y las llamadas a Odoo se simulan.
Describe "Modo Nube: funciones puras" {
    BeforeAll {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        function Get-ScriptFunctionText {
            param([string]$path)
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
            $map = @{}
            $defs = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
            foreach ($d in $defs) { $map[$d.Name] = $d.Extent.Text }
            return $map
        }
        $script:monitorFns = Get-ScriptFunctionText (Join-Path $repoRoot "LidaPrint.ps1")
        $script:guiFns     = Get-ScriptFunctionText (Join-Path $repoRoot "Configurator.ps1")
        # Copias identicas en los dos scripts (en el exe no comparten funciones).
        $script:sharedNames = @("Test-CloudLocalHost", "Get-CloudUrlCheck", "Get-CloudFailureKind", "Get-CloudConfigHint", "Get-CloudRequestHeaders")
        $monitorNames = $script:sharedNames + @("Test-CloudRetryable", "Get-CloudAgeSeconds", "Test-CloudJobExpired",
            "Test-CloudKeepAliveDue", "Invoke-CloudKeepAlive", "Invoke-CloudBatch")
        foreach ($name in $monitorNames) { Invoke-Expression $script:monitorFns[$name] }
        Invoke-Expression $script:guiFns["Get-CloudTokenWarning"]

        # Dobles de prueba. Get-CloudClock de LidaPrint.ps1 NO se carga: esta
        # version devuelve el reloj simulado que fija cada prueba.
        function Get-CloudClock { return @{ Mono = $script:fakeMono; Wall = $script:fakeWall } }
        function Invoke-CloudJob {
            param($job)
            $script:processed += [string]$job.id
            $script:fakeMono += $script:jobCost
        }
        function Invoke-CloudRequest {
            param([string]$Method, [string]$Path, $Body = $null, [int]$TimeoutSec = 15, [string]$OutFile = "")
            $script:requests += "$Method $Path"
            if ($script:pingFails) { throw "sin red" }
        }
        function Write-Log {
            param([string]$message, [string]$level = "INFO")
            $script:logLines += "[$level] $message"
        }
    }

    It "las funciones compartidas son copias identicas en LidaPrint.ps1 y Configurator.ps1" {
        foreach ($name in $script:sharedNames) {
            $script:monitorFns[$name] | Should -Not -BeNullOrEmpty -Because "$name en LidaPrint.ps1"
            $script:guiFns[$name] | Should -Be $script:monitorFns[$name] -Because "$name debe ser igual en los dos scripts"
        }
    }

    Context "Red local (http:// permitido)" {
        It "reconoce esta PC y la red local" {
            $locals = @("localhost", "LOCALHOST", "caja1.local", "127.0.0.1", "10.1.2.3", "172.16.0.1",
                "172.31.255.255", "192.168.1.50", "169.254.10.20", "100.64.0.1", "100.127.255.254",
                "::1", "[::1]", "fc00::1", "fd12:3456::1", "fe80::1", "febf::1", "::ffff:10.0.0.1")
            foreach ($h in $locals) {
                Test-CloudLocalHost $h | Should -BeTrue -Because $h
            }
        }
        It "no confunde hosts publicos con la red local" {
            $publics = @("cliente.example.com", "8.8.8.8", "11.0.0.1", "172.15.0.1", "172.32.0.1",
                "100.63.255.255", "100.128.0.1", "169.253.1.1", "2001:db8::1", "fec0::1",
                "::ffff:8.8.8.8", "local", "local.example.com", "")
            foreach ($h in $publics) {
                Test-CloudLocalHost $h | Should -BeFalse -Because "'$h'"
            }
        }
    }

    Context "URL de Odoo" {
        It "deja solo esquema, host y puerto" {
            $cases = @(
                @("https://cliente.example.com", "https://cliente.example.com"),
                @("  https://cliente.example.com/  ", "https://cliente.example.com"),
                @("https://Cliente.Example.COM", "https://cliente.example.com"),
                @("https://cliente.example.com:443/", "https://cliente.example.com"),
                @("https://cliente.example.com:8443", "https://cliente.example.com:8443"),
                @("https://cliente.example.com/odoo", "https://cliente.example.com"),
                @("https://cliente.example.com/web#action=12", "https://cliente.example.com"),
                @("https://cliente.example.com:8443/odoo/?db=x", "https://cliente.example.com:8443")
            )
            foreach ($c in $cases) {
                $r = Get-CloudUrlCheck $c[0]
                $r.Error | Should -BeNullOrEmpty -Because $c[0]
                $r.Url | Should -Be $c[1] -Because $c[0]
            }
        }
        It "avisa cuando quita una ruta y no cuando no hay nada que quitar" {
            $odoo = (Get-CloudUrlCheck "https://cliente.example.com/odoo").Notice
            $web  = (Get-CloudUrlCheck "https://cliente.example.com/web#action=12").Notice
            $none = (Get-CloudUrlCheck "https://cliente.example.com/").Notice
            $odoo | Should -Match '/odoo'
            $web  | Should -Match '/web'
            $none | Should -BeNullOrEmpty
        }
        It "https siempre; http solo hacia la red local, con advertencia" {
            $lan = Get-CloudUrlCheck "http://192.168.1.10:8069"
            $lan.Error | Should -BeNullOrEmpty
            $lan.Warning | Should -Not -BeNullOrEmpty
            $lan.Url | Should -Be "http://192.168.1.10:8069"

            $v6 = Get-CloudUrlCheck "http://[::1]:8069/odoo"
            $v6.Error | Should -BeNullOrEmpty
            $v6.Warning | Should -Not -BeNullOrEmpty
            $v6.Notice | Should -Not -BeNullOrEmpty
            $v6.Url | Should -Be "http://[::1]:8069"

            $mdns = Get-CloudUrlCheck "http://caja1.local:8069"
            $mdns.Error | Should -BeNullOrEmpty

            $tls = Get-CloudUrlCheck "https://cliente.example.com"
            $tls.Warning | Should -BeNullOrEmpty
        }
        It "rechaza http hacia un host publico, otros esquemas y URL sin esquema" {
            $bad = @("http://cliente.example.com", "http://8.8.8.8/odoo", "ftp://cliente.example.com",
                "cliente.example.com", "cliente.example.com:8069", "", "   ")
            foreach ($u in $bad) {
                $r = Get-CloudUrlCheck $u
                $r.Error | Should -Not -BeNullOrEmpty -Because "'$u'"
            }
        }
    }

    Context "Filtro opcional de base de datos" {
        It "escapa metacaracteres y limita el filtro al nombre exacto sin espacios externos" {
            $headers = Get-CloudRequestHeaders " token " '  cliente.prod+[1](x){2}^$|a\b?*  '
            $headers.Authorization | Should -Be "Bearer token"
            $headers['X-Odoo-dbfilter'] | Should -Be '^cliente\.prod\+\[1]\(x\)\{2}\^\$\|a\\b\?\*$'
            'cliente.prod+[1](x){2}^$|a\b?*' -cmatch $headers['X-Odoo-dbfilter'] | Should -BeTrue
            'clienteXprod+[1](x){2}^$|a\b?*' -cmatch $headers['X-Odoo-dbfilter'] | Should -BeFalse
        }
        It "omite la cabecera con base ausente, vacia o solo espacios" {
            foreach ($db in @($null, '', " `t ")) {
                $headers = Get-CloudRequestHeaders "token" $db
                $headers.Count | Should -Be 1
                $headers.ContainsKey('X-Odoo-dbfilter') | Should -BeFalse
            }
        }
    }

    Context "Codigos HTTP" {
        It "clasifica los fallos del ping y del poll" {
            $expected = @{
                401 = "unauthorized"; 404 = "config"; 400 = "config"
                0 = "transient"; 408 = "transient"; 429 = "transient"; 500 = "transient"; 502 = "transient"; 503 = "transient"
                403 = "other"; 405 = "other"; 409 = "other"
            }
            foreach ($code in $expected.Keys) {
                Get-CloudFailureKind $code | Should -Be $expected[$code] -Because "HTTP $code"
            }
        }
        It "reintenta descargas y acks solo ante fallos transitorios o 401" {
            foreach ($code in @(0, 401, 408, 429, 500, 503)) {
                Test-CloudRetryable $code | Should -BeTrue -Because "HTTP $code"
            }
            foreach ($code in @(400, 403, 404, 409, 413)) {
                Test-CloudRetryable $code | Should -BeFalse -Because "HTTP $code"
            }
        }
        It "el aviso de configuracion pide la URL sin ruta y dbfilter" {
            $hint = Get-CloudConfigHint
            $hint | Should -Match '/odoo ni /web'
            $hint | Should -Match 'dbfilter'
        }
    }

    Context "Formato del token" {
        It "acepta el formato de secrets.token_urlsafe(32) y avisa en los demas casos" {
            $good = ("AbC-_" * 8) + "xyz"   # 43 caracteres del alfabeto URL-safe
            $short = $good.Substring(0, 42)
            $long = $good + "A"
            $base64 = $short + "+"
            $spaced = $good.Substring(0, 21) + " " + $good.Substring(22)
            $padded = "  $good  "
            Get-CloudTokenWarning $good | Should -BeNullOrEmpty
            Get-CloudTokenWarning $padded | Should -BeNullOrEmpty
            foreach ($t in @($short, $long, $base64, $spaced, "")) {
                Get-CloudTokenWarning $t | Should -Match 'Se copio completo' -Because "'$t'"
            }
        }
    }

    Context "Caducidad local (marcas inyectadas)" {
        BeforeAll {
            $script:t0 = ([DateTime]::new(2026, 9, 14, 10, 0, 0)).Ticks
            $script:minute = [TimeSpan]::TicksPerMinute
        }
        It "caduca a los 10 minutos del reloj monotono" {
            $queued = @{ Mono = 0; Wall = $script:t0 }
            $before = Test-CloudJobExpired $queued @{ Mono = 599999; Wall = $script:t0 } 1000 10
            $after  = Test-CloudJobExpired $queued @{ Mono = 600000; Wall = $script:t0 } 1000 10
            $before | Should -BeFalse
            $after | Should -BeTrue
        }
        It "atrasar la hora de Windows no alarga la ventana" {
            $queued = @{ Mono = 0; Wall = $script:t0 }
            $now = @{ Mono = 600000; Wall = $script:t0 - (60 * $script:minute) }
            Test-CloudJobExpired $queued $now 1000 10 | Should -BeTrue
        }
        It "una suspension tampoco la alarga: cuenta el reloj de pared" {
            $queued = @{ Mono = 0; Wall = $script:t0 }
            $now = @{ Mono = 1000; Wall = $script:t0 + (11 * $script:minute) }
            Test-CloudJobExpired $queued $now 1000 10 | Should -BeTrue
        }
        It "un trabajo sin marca conocida cuenta como caducado" {
            Test-CloudJobExpired $null @{ Mono = 0; Wall = $script:t0 } 1000 10 | Should -BeTrue
        }
        It "marcas en orden inverso no dan una edad negativa" {
            $age = Get-CloudAgeSeconds @{ Mono = 5000; Wall = $script:t0 } @{ Mono = 1000; Wall = $script:t0 } 1000
            $age | Should -Be 0
        }
        It "el ping entre trabajos toca solo con MAS de 30 s sin contacto" {
            $last = @{ Mono = 0; Wall = $script:t0 }
            Test-CloudKeepAliveDue $last @{ Mono = 30000; Wall = $script:t0 } 1000 30 | Should -BeFalse
            Test-CloudKeepAliveDue $last @{ Mono = 30001; Wall = $script:t0 } 1000 30 | Should -BeTrue
            Test-CloudKeepAliveDue $null @{ Mono = 0; Wall = $script:t0 } 1000 30 | Should -BeTrue
        }
    }

    Context "Ping entre trabajos de un lote (reloj simulado)" {
        BeforeEach {
            $script:cloudClockFrequency = 1000   # 1000 marcas = 1 s
            $script:cloudKeepAliveSeconds = 30
            $script:fakeMono = 0
            $script:fakeWall = 0
            $script:jobCost = 20000              # cada trabajo tarda 20 s
            $script:cloudLastContact = @{ Mono = 0; Wall = 0 }   # el poll acaba de responder
            $script:processed = @()
            $script:requests = @()
            $script:logLines = @()
            $script:pingFails = $false
            $script:cloudQueue = New-Object System.Collections.ArrayList
        }
        It "hace un GET /ping cuando pasaron mas de 30 s desde el ultimo contacto" {
            foreach ($i in 1..4) { [void]$script:cloudQueue.Add(@{ id = $i }) }
            Invoke-CloudBatch
            ($script:processed -join ",") | Should -Be "1,2,3,4"
            # 20 s: no; 40 s: ping; 60 s: 20 s desde el ping, no; tras el ultimo, nada.
            @($script:requests).Count | Should -Be 1
            $script:requests[0] | Should -Be "GET /ping"
        }
        It "no hace ping con trabajos rapidos ni despues del ultimo" {
            $script:jobCost = 5000
            foreach ($i in 1..6) { [void]$script:cloudQueue.Add(@{ id = $i }) }
            Invoke-CloudBatch
            @($script:processed).Count | Should -Be 6
            @($script:requests).Count | Should -Be 0
        }
        It "un ping fallido no corta el lote ni se repite en cada trabajo" {
            $script:pingFails = $true
            foreach ($i in 1..6) { [void]$script:cloudQueue.Add(@{ id = $i }) }
            Invoke-CloudBatch
            ($script:processed -join ",") | Should -Be "1,2,3,4,5,6"
            # Intentos a los 40 s y a los 80 s (30 s despues del anterior).
            @($script:requests).Count | Should -Be 2
            @($script:logLines | Where-Object { $_ -like '`[WARN`]*' }).Count | Should -Be 2
        }
    }
}

Describe "Modo Nube: cabeceras HTTP y persistencia" {
    BeforeAll {
        $script:repoRoot = Split-Path -Parent $PSScriptRoot
        $script:guiAst = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:repoRoot 'Configurator.ps1'), [ref]$null, [ref]$null)
        $script:monitorAst = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:repoRoot 'LidaPrint.ps1'), [ref]$null, [ref]$null)
        foreach ($ast in @($script:guiAst, $script:monitorAst)) {
            foreach ($fn in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
                if ($fn.Name -in @('Load-Config', 'Get-LidaPrintMode', 'Get-CloudRequestHeaders', 'Invoke-CloudRequest')) {
                    Invoke-Expression $fn.Extent.Text
                }
            }
        }
    }

    It "incluye cabeceras comunes en ping, poll, PDF, ack y llamadas repetidas" {
        $script:cloudBase = 'https://odoo.example.com/lidaprint/v1'
        $script:cloudToken = 'token'
        $script:cloudVersion = 'test'
        $config = [PSCustomObject]@{ cloudDb = ' cliente.prod ' }
        Mock Invoke-WebRequest {
            [PSCustomObject]@{ RawContentStream = [System.IO.MemoryStream]::new() }
        }
        foreach ($attempt in 1..2) {
            Invoke-CloudRequest GET '/ping' -TimeoutSec 10
            Invoke-CloudRequest POST '/poll' @{ hostname = 'caja' }
            Invoke-CloudRequest GET '/job/1/pdf' -OutFile (Join-Path $TestDrive 'job.pdf') -TimeoutSec 60
            Invoke-CloudRequest POST '/job/1/ack' @{ status = 'done' }
        }
        Should -Invoke Invoke-WebRequest -Times 8 -Exactly -ParameterFilter {
            $Headers.Authorization -eq 'Bearer token' -and
            $Headers['X-Odoo-dbfilter'] -ceq '^cliente\.prod$' -and $UserAgent -eq 'LidaPrint/test'
        }
        $config.cloudDb = ' '
        Invoke-CloudRequest GET '/ping'
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            -not $Headers.ContainsKey('X-Odoo-dbfilter') -and $Headers.Authorization -eq 'Bearer token'
        }
    }

    It "guarda el campo de la GUI y lo recupera con Load-Config" {
        $configPath = Join-Path $TestDrive 'config.json'
        $txtCloudDb = [PSCustomObject]@{ Text = ' cliente.prod ' }
        $assignment = $script:guiAst.Find({
            $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $args[0].Left.Extent.Text -eq '$newConfig'
        }, $true)
        $entry = $assignment.Right.Find({
            $args[0] -is [System.Management.Automation.Language.HashtableAst]
        }, $true).KeyValuePairs | Where-Object { $_.Item1.Value -eq 'cloudDb' }
        $db = Invoke-Expression $entry.Item2.Extent.Text
        $db | Should -Be 'cliente.prod'
        $config = [PSCustomObject]@{ cloudDb = $db; downloadFolder = 'Downloads' }
        # Execute the real Save-Config serialization, without the Windows ACL/UI side effects.
        $save = $script:guiAst.Find({
            $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $args[0].Name -eq 'Save-Config'
        }, $true)
        Invoke-Expression $save.Body.EndBlock.Statements[0].Extent.Text
        (Load-Config).cloudDb | Should -Be 'cliente.prod'
        $config.PSObject.Properties.Remove('cloudDb')
        Invoke-Expression $save.Body.EndBlock.Statements[0].Extent.Text
        (Load-Config).cloudDb | Should -Be ''
        (Get-Content (Join-Path $script:repoRoot 'config.json') -Raw | ConvertFrom-Json).cloudDb | Should -Be ''
    }

    It "la prueba GUI usa el helper con el campo no guardado" {
        $script:guiAst.Extent.Text | Should -Match '-Headers \(Get-CloudRequestHeaders \$token \$txtCloudDb\.Text\)'
        $script:guiAst.Extent.Text | Should -Match 'Save-Config \$newConfig'
    }

    It "centraliza todas las llamadas HTTP del monitor en el helper Nube" {
        $calls = @($script:monitorAst.FindAll({
            $args[0] -is [System.Management.Automation.Language.CommandAst] -and
            $args[0].GetCommandName() -eq 'Invoke-WebRequest'
        }, $true))
        $calls.Count | Should -Be 1
        $parent = $calls[0].Parent
        while ($parent -and $parent -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) {
            $parent = $parent.Parent
        }
        $parent.Name | Should -Be 'Invoke-CloudRequest'
        foreach ($name in @('Send-CloudAck', 'Send-PendingCloudAcks', 'Invoke-CloudJob', 'Invoke-CloudKeepAlive', 'Invoke-CloudLoop')) {
            $fn = $script:monitorAst.Find({
                $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $args[0].Name -eq $name
            }, $true)
            $fn.Extent.Text | Should -Match 'Invoke-CloudRequest' -Because $name
        }
    }
}
