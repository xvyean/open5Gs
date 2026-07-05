param(
    [string]$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string]$BaseUrl = 'http://127.0.0.1:8080'
)

$ErrorActionPreference = 'Stop'

$payloadDir = Join-Path $Root 'runtime\pyhss-payloads'
$csv = Join-Path $Root 'config\subscribers.csv'

function Invoke-PyHssJson {
    param(
        [ValidateSet('GET', 'PUT', 'PATCH')]
        [string]$Method,
        [string]$Path,
        [object]$Body = $null
    )

    $uri = "$BaseUrl$Path"
    try {
        if ($null -eq $Body) {
            return Invoke-RestMethod -Method $Method -Uri $uri -ErrorAction Stop
        }

        $json = $Body | ConvertTo-Json -Depth 20
        return Invoke-RestMethod -Method $Method -Uri $uri -ContentType 'application/json' -Body $json -ErrorAction Stop
    } catch {
        $text = $_.ErrorDetails.Message
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            try {
                return $text | ConvertFrom-Json
            } catch {
                return $text
            }
        }

        $response = $_.Exception.Response
        if ($null -ne $response) {
            $stream = $response.GetResponseStream()
            if ($null -ne $stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                $text = $reader.ReadToEnd()
                if (-not [string]::IsNullOrWhiteSpace($text)) {
                    try {
                        return $text | ConvertFrom-Json
                    } catch {
                        return $text
                    }
                }
            }
        }
        if ($Method -eq 'GET' -and $_.Exception.Message -match '404|Not Found') {
            return [pscustomobject]@{ Result = 'Not Found' }
        }
        throw
    }
}

function Test-Found {
    param([object]$Value)
    if ($null -eq $Value) {
        return $false
    }
    if ($Value -is [string] -and ($Value.Trim() -eq '' -or $Value.Trim() -eq 'null')) {
        return $false
    }
    if ($Value.PSObject.Properties.Name -contains 'Result' -and $Value.Result -eq 'Not Found') {
        return $false
    }
    return $true
}

function Read-JsonFile {
    param([string]$Path)
    return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}

function Get-ApnId {
    param([string]$Name)
    $apns = Invoke-PyHssJson -Method GET -Path '/apn/list'
    $match = $apns | Where-Object { $_.apn -eq $Name } | Select-Object -First 1
    if ($null -eq $match) {
        return $null
    }
    return [int]$match.apn_id
}

function Ensure-Apn {
    param(
        [string]$Name,
        [string]$PayloadPath
    )

    $existingId = Get-ApnId -Name $Name
    if ($null -ne $existingId) {
        Write-Host "pyHSS APN '$Name' exists: apn_id=$existingId"
        return $existingId
    }

    Invoke-PyHssJson -Method PUT -Path '/apn/' -Body (Read-JsonFile -Path $PayloadPath) | Out-Null
    $createdId = Get-ApnId -Name $Name
    if ($null -eq $createdId) {
        throw "pyHSS APN '$Name' was not created."
    }
    Write-Host "pyHSS APN '$Name' created: apn_id=$createdId"
    return $createdId
}

function Ensure-Auc {
    param(
        [string]$Imsi,
        [string]$PayloadPath
    )

    $existing = Invoke-PyHssJson -Method GET -Path "/auc/imsi/$Imsi"
    if (Test-Found $existing) {
        Write-Host "pyHSS AuC exists: imsi=$Imsi auc_id=$($existing.auc_id)"
        return [int]$existing.auc_id
    }

    $created = Invoke-PyHssJson -Method PUT -Path '/auc/' -Body (Read-JsonFile -Path $PayloadPath)
    $aucId = $created.auc_id
    if ($null -eq $aucId) {
        $created = Invoke-PyHssJson -Method GET -Path "/auc/imsi/$Imsi"
        $aucId = $created.auc_id
    }
    if ($null -eq $aucId) {
        throw "pyHSS AuC was not created for IMSI $Imsi."
    }
    Write-Host "pyHSS AuC created: imsi=$Imsi auc_id=$aucId"
    return [int]$aucId
}

function Ensure-Subscriber {
    param(
        [string]$Imsi,
        [string]$PayloadPath,
        [int]$AucId,
        [int]$InternetApnId,
        [int]$ImsApnId
    )

    $payload = Read-JsonFile -Path $PayloadPath
    $payload.auc_id = $AucId
    $payload.default_apn = $InternetApnId
    $payload.apn_list = "$InternetApnId,$ImsApnId"

    $existing = Invoke-PyHssJson -Method GET -Path "/subscriber/imsi/$Imsi"
    if (Test-Found $existing -and $null -ne $existing.subscriber_id) {
        Invoke-PyHssJson -Method PATCH -Path "/subscriber/$($existing.subscriber_id)" -Body $payload | Out-Null
        Write-Host "pyHSS subscriber updated: imsi=$Imsi subscriber_id=$($existing.subscriber_id)"
        return [int]$existing.subscriber_id
    }

    $created = Invoke-PyHssJson -Method PUT -Path '/subscriber/' -Body $payload
    if ($null -eq $created.subscriber_id) {
        $created = Invoke-PyHssJson -Method GET -Path "/subscriber/imsi/$Imsi"
    }
    if ($null -eq $created.subscriber_id) {
        throw "pyHSS subscriber was not created for IMSI $Imsi."
    }
    Write-Host "pyHSS subscriber created: imsi=$Imsi subscriber_id=$($created.subscriber_id)"
    return [int]$created.subscriber_id
}

function Ensure-ImsSubscriber {
    param(
        [string]$Imsi,
        [string]$PayloadPath
    )

    $payload = Read-JsonFile -Path $PayloadPath
    $existing = Invoke-PyHssJson -Method GET -Path "/ims_subscriber/ims_subscriber_imsi/$Imsi"
    if (Test-Found $existing -and $null -ne $existing.ims_subscriber_id) {
        Invoke-PyHssJson -Method PATCH -Path "/ims_subscriber/$($existing.ims_subscriber_id)" -Body $payload | Out-Null
        Write-Host "pyHSS IMS subscriber updated: imsi=$Imsi ims_subscriber_id=$($existing.ims_subscriber_id)"
        return [int]$existing.ims_subscriber_id
    }

    $created = Invoke-PyHssJson -Method PUT -Path '/ims_subscriber/' -Body $payload
    if ($null -eq $created.ims_subscriber_id) {
        $created = Invoke-PyHssJson -Method GET -Path "/ims_subscriber/ims_subscriber_imsi/$Imsi"
    }
    if ($null -eq $created.ims_subscriber_id) {
        throw "pyHSS IMS subscriber was not created for IMSI $Imsi."
    }
    Write-Host "pyHSS IMS subscriber created: imsi=$Imsi ims_subscriber_id=$($created.ims_subscriber_id)"
    return [int]$created.ims_subscriber_id
}

Invoke-PyHssJson -Method GET -Path '/oam/ping' | Out-Null

$internetApnId = Ensure-Apn -Name 'internet' -PayloadPath (Join-Path $payloadDir 'apn-internet.json')
$imsApnId = Ensure-Apn -Name 'ims' -PayloadPath (Join-Path $payloadDir 'apn-ims.json')

Import-Csv -LiteralPath $csv | ForEach-Object {
    $label = $_.card
    $imsi = $_.imsi
    $aucId = Ensure-Auc -Imsi $imsi -PayloadPath (Join-Path $payloadDir "$label-auc.json")
    Ensure-Subscriber -Imsi $imsi -PayloadPath (Join-Path $payloadDir "$label-subscriber.json") -AucId $aucId -InternetApnId $internetApnId -ImsApnId $imsApnId | Out-Null
    Ensure-ImsSubscriber -Imsi $imsi -PayloadPath (Join-Path $payloadDir "$label-ims-subscriber.json") | Out-Null
}

Write-Host 'pyHSS APN, AuC, subscriber, and IMS subscriber provisioning completed.'
