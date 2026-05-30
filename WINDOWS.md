# Windows 11 + Docker Desktop

The Linux deployment entry point remains `deploy-infra.sh`. On Windows 11,
run the native PowerShell entry point from the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy-infra.ps1 init
powershell -ExecutionPolicy Bypass -File .\deploy-infra.ps1 up
powershell -ExecutionPolicy Bypass -File .\deploy-infra.ps1 ps
```

Docker Desktop must be running with Linux containers enabled. The PowerShell
entry point creates local bind-mount directories under `.\data` by default,
instead of using the Linux host directory `/data`. To use another directory:

```powershell
$env:DATA_ROOT = "D:\docker-data"
powershell -ExecutionPolicy Bypass -File .\deploy-infra.ps1 up
```

The existing `.env.*` files are still used for images, credentials, ports, and
domains. Change their placeholder passwords before exposing services.

## Commands

```powershell
# All stacks
powershell -ExecutionPolicy Bypass -File .\deploy-infra.ps1 up
powershell -ExecutionPolicy Bypass -File .\deploy-infra.ps1 down

# Selected stacks
powershell -ExecutionPolicy Bypass -File .\deploy-infra.ps1 up db monitor
powershell -ExecutionPolicy Bypass -File .\deploy-infra.ps1 logs db

# Proxy lifecycle
powershell -ExecutionPolicy Bypass -File .\proxy\scripts\proxy.ps1 up
powershell -ExecutionPolicy Bypass -File .\proxy\scripts\proxy.ps1 test
```

The proxy PowerShell script renders nginx templates without requiring Bash,
WSL, or `envsubst`. For public HTTPS certificate operations, configure the
real domains and `CERTBOT_EMAIL` in `proxy\.env.proxy` first.

