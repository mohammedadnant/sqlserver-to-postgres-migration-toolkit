function Import-DotEnv {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Missing env file: $Path"
    }

    Get-Content $Path | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith('#')) { return }
        $idx = $line.IndexOf('=')
        if ($idx -lt 1) { return }

        $name = $line.Substring(0, $idx).Trim()
        $value = $line.Substring($idx + 1).Trim()
        [System.Environment]::SetEnvironmentVariable($name, $value, 'Process')
    }
}

function Require-Env {
    param([string[]]$Names)

    foreach ($name in $Names) {
        $value = [System.Environment]::GetEnvironmentVariable($name, 'Process')
        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "Missing required env var: $name"
        }
    }
}

function New-Directory {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Resolve-DockerHost {
    param([string]$HostName)

    if ($HostName -eq 'localhost' -or $HostName -eq '127.0.0.1') {
        return 'host.docker.internal'
    }
    return $HostName
}

function Invoke-PsqlCommand {
    param(
        [string[]]$Arguments,
        [string]$WorkspaceRoot
    )

    if (Get-Command psql -ErrorAction SilentlyContinue) {
        & psql @Arguments
        return
    }

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw 'Neither psql nor docker is available to run PostgreSQL commands.'
    }

    $mountRoot = $WorkspaceRoot.Replace('\\', '/')
    & docker run --rm -e PGPASSWORD=$env:PGPASSWORD -v "${mountRoot}:/workspace" postgres:16-alpine psql @Arguments
}
