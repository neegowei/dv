[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = "help",

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$CommandArgs
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$CommandArgs = @($CommandArgs)

$ScriptRoot = $PSScriptRoot
$ProxyRoot = Split-Path $ScriptRoot -Parent
$RepoRoot = Split-Path $ProxyRoot -Parent
$EnvFile = if ($env:PROXY_ENV_FILE) { $env:PROXY_ENV_FILE } else { Join-Path $ProxyRoot ".env.proxy" }
$ComposeFile = if ($env:PROXY_COMPOSE_FILE) { $env:PROXY_COMPOSE_FILE } else { Join-Path $ProxyRoot "docker-compose.yaml" }
$TemplateDir = Join-Path $ProxyRoot "templates"
$EnabledTemplateDir = Join-Path $ProxyRoot "templates-enabled"
$RenderedConfDir = Join-Path $ProxyRoot "conf.d-enabled"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Assert-LastExitCode([string]$Description) {
    if ($LASTEXITCODE -ne 0) { throw "$Description failed with exit code $LASTEXITCODE." }
}

function Set-DefaultEnv([string]$Name, [string]$Value) {
    if (-not [Environment]::GetEnvironmentVariable($Name, "Process")) {
        [Environment]::SetEnvironmentVariable($Name, $Value, "Process")
    }
}

function To-DockerPath([string]$Path) {
    return ([System.IO.Path]::GetFullPath($Path) -replace "\\", "/")
}

function Initialize-WindowsPaths {
    $dataRoot = if ($env:DATA_ROOT) { $env:DATA_ROOT } else { Join-Path $RepoRoot "data" }
    Set-DefaultEnv "CERTBOT_WWW_DIR" (To-DockerPath (Join-Path $dataRoot "certbot-www"))
    Set-DefaultEnv "LETSENCRYPT_DIR" (To-DockerPath (Join-Path $dataRoot "letsencrypt"))
    New-Item -ItemType Directory -Force -Path $env:CERTBOT_WWW_DIR, $env:LETSENCRYPT_DIR | Out-Null
}

function Read-DotEnv {
    if (-not (Test-Path $EnvFile)) { throw "Environment file not found: $EnvFile" }
    $values = @{}
    foreach ($line in Get-Content $EnvFile) {
        if ($line -match "^\s*#" -or $line -notmatch "^\s*([^=]+?)\s*=(.*)$") { continue }
        $values[$matches[1]] = $matches[2].Trim().Trim("'").Trim('"')
    }
    return $values
}

$DotEnv = Read-DotEnv

function Get-EnvValue([string]$Name, [string]$Default = "") {
    $value = [Environment]::GetEnvironmentVariable($Name, "Process")
    if ($value) { return $value }
    if ($DotEnv.ContainsKey($Name)) { return $DotEnv[$Name] }
    return $Default
}

function Invoke-Compose([string[]]$Arguments) {
    & docker compose --env-file $EnvFile -f $ComposeFile @Arguments
    Assert-LastExitCode "docker compose"
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

function Ensure-Network {
    $network = Get-EnvValue "PROXY_NETWORK" "shared_proxy"
    if (-not (Test-DockerNetwork $network)) {
        & docker network create $network | Out-Null
        Assert-LastExitCode "docker network create $network"
    }
}

function Reset-Templates {
    if (Test-Path $EnabledTemplateDir) { Remove-Item -Recurse -Force $EnabledTemplateDir }
    New-Item -ItemType Directory -Force -Path $EnabledTemplateDir | Out-Null
}

function Copy-Template([string]$Name, [string]$Target = "") {
    if (-not $Target) { $Target = $Name }
    Copy-Item (Join-Path $TemplateDir $Name) (Join-Path $EnabledTemplateDir $Target)
}

function Enable-HttpTemplates {
    Reset-Templates
    Copy-Template "05-upstreams.conf.template"
    Copy-Template "10-http.conf.template"
    Copy-Template "05-infra-upstreams.conf.template"
    Copy-Template "10-http-infra.conf.template"
}

function Enable-HttpsTemplates {
    Reset-Templates
    Copy-Template "05-upstreams.conf.template"
    Copy-Template "10-http-redirect.conf.template" "10-http.conf.template"
    Copy-Template "20-https.conf.template"
    Copy-Template "05-infra-upstreams.conf.template"
    Copy-Template "10-http-redirect-infra.conf.template"
    Copy-Template "20-https-infra.conf.template"
}

function Enable-InfraHttpsTemplates {
    Reset-Templates
    Copy-Template "05-infra-upstreams.conf.template"
    Copy-Template "10-http-redirect-infra.conf.template"
    Copy-Template "20-https-infra.conf.template"
}

function Render-Templates {
    New-Item -ItemType Directory -Force -Path $RenderedConfDir | Out-Null
    Get-ChildItem $RenderedConfDir -Filter "*.conf" -ErrorAction SilentlyContinue | Remove-Item -Force
    Get-ChildItem $EnabledTemplateDir -Filter "*.template" | ForEach-Object {
        $content = [System.IO.File]::ReadAllText($_.FullName)
        $content = [regex]::Replace($content, '\$\{([A-Za-z_][A-Za-z0-9_]*)\}', {
            param($match)
            return Get-EnvValue $match.Groups[1].Value ""
        })
        $output = Join-Path $RenderedConfDir $_.BaseName
        [System.IO.File]::WriteAllText($output, $content, $Utf8NoBom)
    }
}

function Reload-Nginx {
    Render-Templates
    Invoke-Compose @("exec", "nginx", "nginx", "-t")
    Invoke-Compose @("exec", "nginx", "nginx", "-s", "reload")
}

function Get-CertbotDomains {
    $raw = Get-EnvValue "CERTBOT_DOMAINS"
    if (-not $raw) { $raw = "$(Get-EnvValue "DOMAIN_WWW") $(Get-EnvValue "DOMAIN_ADMIN")" }
    $domains = @($raw -split "[,\s]+" | Where-Object { $_ })
    if ($domains.Count -eq 0) { throw "Set CERTBOT_DOMAINS or DOMAIN_WWW/DOMAIN_ADMIN in $EnvFile first." }
    return $domains
}

function Assert-CertbotEmail {
    $email = Get-EnvValue "CERTBOT_EMAIL"
    if (-not $email -or $email -eq "admin@example.com") { throw "Set CERTBOT_EMAIL in $EnvFile first." }
}

function Request-Certificate([string[]]$Domains, [string]$CertName, [switch]$Expand) {
    Assert-CertbotEmail
    if ($Domains.Count -eq 0) { throw "Set CERTBOT_DOMAINS or DOMAIN_WWW/DOMAIN_ADMIN in $EnvFile first." }
    $args = @("run", "--rm", "certbot", "certonly", "--webroot", "-w", "/var/www/certbot",
        "--email", (Get-EnvValue "CERTBOT_EMAIL"), "--agree-tos", "--no-eff-email", "--cert-name", $CertName)
    if ((Get-EnvValue "CERTBOT_STAGING" "0") -eq "1") { $args += "--test-cert" }
    if ($Expand) { $args += "--expand" }
    foreach ($domain in $Domains) { $args += @("-d", $domain) }
    Invoke-Compose $args
}

function Show-Usage {
    @"
Usage: .\proxy.ps1 <up|issue|issue-domain|expand|renew|enable-https|reload|test|ps|logs|down>
"@
}

Initialize-WindowsPaths

switch ($Command) {
    "up"           { Ensure-Network; Enable-HttpTemplates; Render-Templates; Invoke-Compose @("up", "-d", "nginx") }
    "issue"        { $domains = Get-CertbotDomains; Request-Certificate $domains (Get-EnvValue "CERT_NAME" $domains[0]); Enable-HttpsTemplates; Reload-Nginx }
    "issue-domain" {
        if ($CommandArgs.Count -ne 1) { throw "Usage: .\proxy.ps1 issue-domain <domain>" }
        Request-Certificate @($CommandArgs[0]) $CommandArgs[0]
    }
    "expand"       { $domains = Get-CertbotDomains; Request-Certificate $domains (Get-EnvValue "CERT_NAME" $domains[0]) -Expand; Reload-Nginx }
    "renew"        { Invoke-Compose @("run", "--rm", "certbot", "renew", "--webroot", "-w", "/var/www/certbot"); Reload-Nginx }
    "enable-https" { Ensure-Network; Enable-InfraHttpsTemplates; Reload-Nginx }
    "reload"       { Reload-Nginx }
    "test"         { Render-Templates; Invoke-Compose @("exec", "nginx", "nginx", "-t") }
    "ps"           { Invoke-Compose @("ps") }
    "logs"         { Invoke-Compose @("logs", "-f") }
    "down"         { Invoke-Compose @("down") }
    { $_ -in @("help", "-h", "--help") } { Show-Usage }
    default        { Show-Usage; throw "Unknown command: $Command" }
}
