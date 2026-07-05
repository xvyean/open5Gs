$ErrorActionPreference = 'Continue'

function Write-Result {
    param(
        [string]$Status,
        [string]$Name,
        [string]$Detail = ''
    )
    $line = "{0,-6} {1}" -f "[$Status]", $Name
    if ($Detail) { $line += " - $Detail" }
    Write-Host $line
}

function Test-CommandOk {
    param(
        [string]$Name,
        [scriptblock]$Command,
        [string]$Pass,
        [string]$Fail
    )
    try {
        $global:LASTEXITCODE = 0
        $output = & $Command 2>&1
        $commandSucceeded = $?
        $exitCode = $global:LASTEXITCODE
        if ($commandSucceeded -and $exitCode -eq 0) {
            Write-Result 'PASS' $Name $Pass
            if ($output) { $output | Select-Object -First 5 | ForEach-Object { Write-Host "       $_" } }
        } else {
            Write-Result 'FAIL' $Name "$Fail (exit=$exitCode)"
            if ($output) { $output | Select-Object -First 8 | ForEach-Object { Write-Host "       $_" } }
        }
    } catch {
        Write-Result 'FAIL' $Name "$Fail ($($_.Exception.Message))"
    }
}

Write-Host 'Checking prerequisites for shijian Open5GS + Kamailio IMS + srsRAN lab...'
Write-Host ''

Test-CommandOk 'WSL installed' { wsl -l -v } 'WSL is available.' 'Install/enable WSL2 first.'

Test-CommandOk 'Ubuntu WSL distro' {
    wsl -d Ubuntu -- bash -lc 'cat /etc/os-release | grep PRETTY_NAME; uname -r'
} 'Ubuntu distro is callable.' 'Install an Ubuntu WSL distro named Ubuntu.'

Test-CommandOk 'Docker Desktop engine' {
    docker info
} 'Docker engine is reachable from Windows.' 'Start Docker Desktop and wait for the Linux engine.'

Test-CommandOk 'Docker Compose' {
    docker compose version
} 'Docker Compose v2 is installed.' 'Install Docker Compose v2.'

Test-CommandOk 'Docker CLI inside WSL' {
    wsl -d Ubuntu -- bash -lc 'command -v docker >/dev/null && docker --version >/dev/null && docker compose version >/dev/null'
} 'Docker CLI and Compose are installed in Ubuntu WSL.' 'Install docker-ce-cli and docker-compose-plugin in Ubuntu WSL.'

Test-CommandOk 'Docker Desktop WSL daemon bridge' {
    wsl -d Ubuntu -- bash -lc 'docker info >/dev/null'
} 'Ubuntu WSL can reach a Docker daemon.' 'Docker CLI is installed, but Docker Desktop WSL integration/proxy is not connected. Use Windows Docker scripts or restart Docker Desktop WSL integration.'

Test-CommandOk 'WSL radio tools' {
    wsl -d Ubuntu -- bash -lc 'command -v uhd_find_devices >/dev/null && command -v pcsc_scan >/dev/null && command -v lsusb >/dev/null'
} 'UHD, PC/SC, and usbutils are installed in WSL.' 'Run: wsl -d Ubuntu -- bash -lc "cd /mnt/g/study/Third/lab/shijian && bash scripts/bootstrap-wsl.sh"'

$usbipdPath = $null
$usbipdCommand = Get-Command usbipd -ErrorAction SilentlyContinue
if ($usbipdCommand) {
    $usbipdPath = $usbipdCommand.Source
}
if (-not $usbipdPath) {
    $defaultUsbipd = 'C:\Program Files\usbipd-win\usbipd.exe'
    if (Test-Path -LiteralPath $defaultUsbipd) {
        $usbipdPath = $defaultUsbipd
    }
}

if ($usbipdPath) {
    Write-Result 'PASS' 'usbipd' 'USB/IP tooling is installed. Use usbipd list/attach if WSL cannot see the USRP.'
    & $usbipdPath list 2>$null | Select-Object -First 12 | ForEach-Object { Write-Host "       $_" }
} else {
    Write-Result 'WARN' 'usbipd' 'Not found. Install usbipd-win if USRP B210 or SIM reader must be passed into WSL.'
}

$usrp = Get-PnpDevice -PresentOnly | Where-Object { $_.FriendlyName -match 'USRP|Ettus|B200|B210|National Instruments' }
if ($usrp) {
    Write-Result 'PASS' 'USRP visible to Windows' 'A likely USRP device is present.'
    $usrp | Select-Object Class,FriendlyName,Status,InstanceId | Format-Table -AutoSize
} else {
    Write-Result 'WARN' 'USRP visible to Windows' 'No USRP/B210-like device detected. Connect it over USB 3.0 before OTA testing.'
}

Write-Host ''
Write-Host 'RF safety: use a shield box or attenuators and the test PLMN 001/01. Do not radiate on licensed bands outside the lab.'
