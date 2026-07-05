param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'
$csv = Join-Path $Root 'config\subscribers.csv'

docker ps --format '{{.Names}}' | Select-String -SimpleMatch 'webui' | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Container 'webui' is not running. Start core/IMS first."
}

Import-Csv -LiteralPath $csv | ForEach-Object {
    Write-Host "Provisioning $($_.card) IMSI=$($_.imsi)"
    docker exec webui misc/db/open5gs-dbctl remove_ue $_.imsi *> $null

    docker exec webui misc/db/open5gs-dbctl add_ue_with_apn $_.imsi $_.ki $_.opc internet
    if ($LASTEXITCODE -ne 0) {
        throw "add_ue_with_apn failed for $($_.imsi)"
    }

    docker exec webui misc/db/open5gs-dbctl update_apn $_.imsi ims 0
    if ($LASTEXITCODE -ne 0) {
        throw "update_apn ims failed for $($_.imsi)"
    }
}

Write-Host 'Open5GS HSS subscriber provisioning completed.'
