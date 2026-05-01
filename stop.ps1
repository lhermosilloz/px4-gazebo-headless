<#
.SYNOPSIS
    Stop a running px4sim container (or any named container).

.PARAMETER ContainerName
    Docker container name to stop (default: px4sim)

.EXAMPLE
    .\stop.ps1
    .\stop.ps1 -ContainerName px4sim
#>

param(
    [string] $ContainerName = "px4sim"
)

$id = docker ps -q --filter "name=^${ContainerName}$" 2>$null

if (-not $id) {
    Write-Host "No running container named '$ContainerName' found."
    exit 0
}

Write-Host "Stopping $ContainerName ..."
docker stop $ContainerName | Out-Null
Write-Host "Done."
