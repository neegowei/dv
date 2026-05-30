[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = "help",

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Stacks
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$Stacks = @($Stacks) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

$ScriptRoot = $PSScriptRoot
$DataRoot = if ($env:DATA_ROOT) { $env:DATA_ROOT } else { Join-Path $ScriptRoot "data" }
$DataRoot = [System.IO.Path]::GetFullPath($DataRoot)
$AllStacks = @("db", "monitor", "etcd", "rabbitmq", "minio", "proxy")
$StackDirs = @{
    proxy    = Join-Path $ScriptRoot "proxy"
    db       = Join-Path $ScriptRoot "db"
    monitor  = Join-Path $ScriptRoot "monitor"
    etcd     = Join-Path $ScriptRoot "etcd"
    rabbitmq = Join-Path $ScriptRoot "rabbitmq"
    minio    = Join-Path $ScriptRoot "minio"
}

function To-DockerPath([string]$Path) {
    return ([System.IO.Path]::GetFullPath($Path) -replace "\\", "/")
}

function Set-DefaultEnv([string]$Name, [string]$Value) {
    if (-not [Environment]::GetEnvironmentVariable($Name, "Process")) {
        [Environment]::SetEnvironmentVariable($Name, $Value, "Process")
    }
}

function Set-WindowsDataPaths {
    $paths = @{
        MYSQL_DATA_DIR     = "mysql"
        REDIS_DATA_DIR     = "redis"
        MONGO_DATA_DIR     = "mongo"
        PROMETHEUS_DATA_DIR = "prometheus"
        LOKI_DATA_DIR      = "loki"
        TEMPO_DATA_DIR     = "tempo"
        GRAFANA_DATA_DIR   = "grafana"
        BASE_LOG_DIR       = "logs"
        HOST_LOG_DIR       = "host-logs"
        HOST_ETCD_DATA_DIR = "etcd"
        RABBITMQ_DATA_DIR  = "rabbitmq"
        MINIO_DATA_DIR     = "minio"
        CERTBOT_WWW_DIR    = "certbot-www"
        LETSENCRYPT_DIR    = "letsencrypt"
    }
    foreach ($entry in $paths.GetEnumerator()) {
        Set-DefaultEnv $entry.Key (To-DockerPath (Join-Path $DataRoot $entry.Value))
    }
}

function Assert-LastExitCode([string]$Description) {
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE."
    }
}

function Assert-Docker {
    & docker compose version | Out-Null
    Assert-LastExitCode "docker compose version"
}

function Test-DockerNetwork([string]$Network) {
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & docker network inspect $Network *> $null
        return $LASTEXITCODE -eq 0
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Initialize-Data {
    Write-Host "=== Initializing Windows data directories: $DataRoot ==="
    @(
        "certbot-www", "letsencrypt", "mysql", "redis", "mongo",
        "prometheus", "loki", "tempo", "grafana", "logs", "host-logs",
        "etcd", "rabbitmq", "minio"
    ) | ForEach-Object {
        $path = Join-Path $DataRoot $_
        New-Item -ItemType Directory -Force -Path $path | Out-Null
        Write-Host "  $path"
    }
}

function Initialize-Networks {
    Assert-Docker
    Write-Host "=== Creating Docker networks ==="
    @("shared_proxy", "shared_db", "shared_monitor", "shared_etcd", "shared_rabbitmq", "shared_minio") |
        ForEach-Object {
            if (Test-DockerNetwork $_) {
                Write-Host "  exists: $_"
            } else {
                & docker network create $_ | Out-Null
                Assert-LastExitCode "docker network create $_"
                Write-Host "  created: $_"
            }
        }
}

function Get-SelectedStacks {
    if ($Stacks -and $Stacks.Count -gt 0) { return $Stacks }
    return $AllStacks
}

function Assert-Stack([string]$Stack) {
    if (-not $StackDirs.ContainsKey($Stack)) {
        throw "Unknown stack: $Stack"
    }
}

function Invoke-Compose([string]$Stack, [string[]]$Arguments) {
    Assert-Stack $Stack
    $dir = $StackDirs[$Stack]
    $envFile = Join-Path $dir ".env.$Stack"
    if (-not (Test-Path $envFile)) {
        throw "Environment file not found: $envFile"
    }
    & docker compose --env-file $envFile -f (Join-Path $dir "docker-compose.yaml") @Arguments
    Assert-LastExitCode "docker compose ($Stack)"
}

function Invoke-Proxy([string[]]$Arguments) {
    & (Join-Path $StackDirs.proxy "scripts/proxy.ps1") @Arguments
    if (-not $?) { throw "proxy.ps1 failed." }
}

function Invoke-Stack([string]$Stack, [string]$Action) {
    Assert-Stack $Stack
    Write-Host "=== $Action $Stack ==="
    if ($Stack -eq "proxy") {
        if ($Action -eq "restart") {
            Invoke-Proxy @("down")
            Invoke-Proxy @("up")
        } else {
            Invoke-Proxy @($Action)
        }
    } else {
        switch ($Action) {
            "up"      { Invoke-Compose $Stack @("up", "-d") }
            "down"    { Invoke-Compose $Stack @("down") }
            "ps"      { Invoke-Compose $Stack @("ps") }
            "restart" { Invoke-Compose $Stack @("restart") }
        }
    }
}

function Show-Usage {
    @"
Usage:
  .\deploy-infra.ps1 init-data
  .\deploy-infra.ps1 init-networks
  .\deploy-infra.ps1 init
  .\deploy-infra.ps1 up [stack ...]
  .\deploy-infra.ps1 down [stack ...]
  .\deploy-infra.ps1 restart [stack ...]
  .\deploy-infra.ps1 ps [stack ...]
  .\deploy-infra.ps1 logs <stack>

Stacks: proxy db monitor etcd rabbitmq minio
Default Windows data directory: .\data (override with DATA_ROOT)
"@
}

Set-WindowsDataPaths

switch ($Command) {
    "init-data"     { Initialize-Data }
    "init-networks" { Initialize-Networks }
    "init"          { Initialize-Data; Initialize-Networks }
    "up"            { Initialize-Data; Initialize-Networks; Get-SelectedStacks | ForEach-Object { Invoke-Stack $_ "up" } }
    "down"          { @(Get-SelectedStacks) | Sort-Object { if ($_ -eq "proxy") { 0 } else { 1 } } | ForEach-Object { Invoke-Stack $_ "down" } }
    "restart"       { Get-SelectedStacks | ForEach-Object { Invoke-Stack $_ "restart" } }
    { $_ -in @("ps", "status") } { Get-SelectedStacks | ForEach-Object { Invoke-Stack $_ "ps" } }
    "logs" {
        if ($Stacks.Count -ne 1) { throw "Usage: .\deploy-infra.ps1 logs <stack>" }
        if ($Stacks[0] -eq "proxy") { Invoke-Proxy @("logs") } else { Invoke-Compose $Stacks[0] @("logs", "-f") }
    }
    { $_ -in @("help", "-h", "--help") } { Show-Usage }
    default { Show-Usage; throw "Unknown command: $Command" }
}
