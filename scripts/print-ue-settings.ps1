param(
    [switch]$ShowSecrets
)

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$envFile = Join-Path $root '.env.shijian'
$csv = Join-Path $root 'config\subscribers.csv'

$vars = @{}
Get-Content -LiteralPath $envFile | ForEach-Object {
    if ($_ -match '^([^#][^=]+)=(.*)$') {
        $vars[$matches[1]] = $matches[2]
    }
}

Write-Host "PLMN: $($vars.MCC)$($vars.MNC)  MCC=$($vars.MCC) MNC=$($vars.MNC) TAC=$($vars.TAC)"
Write-Host "Core/IMS host: $($vars.DOCKER_HOST_IP)"
Write-Host ''
Write-Host 'Phone APNs:'
Write-Host '  internet: APN=internet, type=default,supl, protocol=IPv4'
Write-Host '  ims:      APN=ims,      type=ims,          protocol=IPv4'
Write-Host ''
Write-Host 'Subscribers:'
Import-Csv -LiteralPath $csv | ForEach-Object {
    Write-Host "  $($_.card): IMSI=$($_.imsi) MSISDN=$($_.msisdn) AMF=$($_.amf)"
    if ($ShowSecrets) {
        Write-Host "      Ki=$($_.ki)"
        Write-Host "      OPc=$($_.opc)"
    }
}

Write-Host ''
Write-Host 'Use manual network selection on the phone and select the test PLMN 00101 if it is not selected automatically.'
