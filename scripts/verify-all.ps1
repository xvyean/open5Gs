<#
  verify-all.ps1  —— 一键验收自检脚本
  作用：逐项检查 Docker 引擎、核心网/IMS 网元、接口连通性、ZMQ 过渡验证 attach，
        在控制台打印 PASS/FAIL 清单，并生成一份带时间戳的验证报告存档（可截图作为验收证据）。
  用法：
        powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify-all.ps1
        加 -SkipZmq 跳过 ZMQ attach 检查（例如已切到 USRP 真机时）
  说明：PowerShell 5.1 兼容语法，不使用 && 与三元运算符。
#>
param(
    [switch]$SkipZmq
)

$ErrorActionPreference = 'Continue'
$ts    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$root  = Split-Path -Parent $PSScriptRoot
$report = Join-Path $root ("runtime\verify-report-{0}.txt" -f $stamp)

$script:pass = 0
$script:fail = 0
$script:lines = New-Object System.Collections.ArrayList

function Add-Line($text) { [void]$script:lines.Add($text) }

function Check($name, $ok, $detail) {
    if ($ok) { $status = 'PASS'; $script:pass++ } else { $status = 'FAIL'; $script:fail++ }
    $line = "[{0}] {1}  ::  {2}" -f $status, $name, $detail
    if ($ok) { Write-Host $line -ForegroundColor Green } else { Write-Host $line -ForegroundColor Red }
    Add-Line $line
}

function Info($text) {
    Write-Host $text -ForegroundColor Cyan
    Add-Line $text
}

Info "==================================================================="
Info " Open5GS + Kamailio IMS + srsRAN 实验环境自检报告"
Info " 时间: $ts"
Info "==================================================================="

# ---- 1. Docker 引擎 ----
Info ""
Info "--- 1. Docker 引擎 ---"
$dockerVer = docker version --format "Server {{.Server.Version}}" 2>$null
Check "Docker 引擎可用" ($LASTEXITCODE -eq 0 -and $dockerVer) $dockerVer

# ---- 2. 核心网 / IMS 网元容器 ----
Info ""
Info "--- 2. 核心网 / IMS 网元（VoLTE 关键路径）---"
$core = @('mongo','mysql','webui','hss','mme','sgwc','sgwu','smf','upf','pcrf','pcscf','icscf','scscf','pyhss','dns','rtpengine')
foreach ($c in $core) {
    $running = docker inspect -f "{{.State.Running}}" $c 2>$null
    Check ("容器 " + $c) ($running -eq 'true') ("State.Running=" + $running)
}

# ---- 3. 附加网元（监控 / CS 域，非 VoLTE 必需，仅提示）----
Info ""
Info "--- 3. 附加网元（监控 / CS 域，仅提示不计分）---"
$extra = @('grafana','metrics','osmohlr','osmomsc','smsc')
foreach ($c in $extra) {
    $running = docker inspect -f "{{.State.Running}}" $c 2>$null
    if ($running -eq 'true') { Info ("  [up]   " + $c) } else { Info ("  [down] " + $c + " (可忽略)") }
}

# ---- 4. 接口与信令连通性 ----
Info ""
Info "--- 4. 接口与信令连通性 ---"

$mmeLog = docker logs mme 2>&1 | Out-String
Check "MME S1AP 监听 (SCTP 36412)" ($mmeLog -match 's1ap_server') "日志出现 s1ap_server()"
Check "MME<->HSS Diameter 已连接"  ($mmeLog -match "CONNECTED TO 'hss") "日志出现 CONNECTED TO 'hss...'"

$pyhssOk = $false; $pyhssBody = ''
try {
    $r = Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:8080/oam/ping" -TimeoutSec 10
    $pyhssBody = $r.Content
    if ($pyhssBody -match 'OK') { $pyhssOk = $true }
} catch { $pyhssBody = "请求失败: $($_.Exception.Message)" }
Check "pyHSS OAM 存活 (:8080/oam/ping)" $pyhssOk $pyhssBody

$webuiOk = $false; $webuiCode = ''
try {
    $r = Invoke-WebRequest -UseBasicParsing "http://127.0.0.1:9999" -TimeoutSec 10
    $webuiCode = $r.StatusCode
    if ($webuiCode -eq 200) { $webuiOk = $true }
} catch { $webuiCode = "请求失败: $($_.Exception.Message)" }
Check "Open5GS WebUI (:9999)" $webuiOk ("HTTP " + $webuiCode)

# ---- 5. P-CSCF udp_mtu 修复核对 ----
Info ""
Info "--- 5. 关键修复核对 ---"
$pcscfCfg = Join-Path $root 'third_party\docker_open5gs\pcscf\kamailio_pcscf.cfg'
if (Test-Path $pcscfCfg) {
    $cfg = Get-Content $pcscfCfg -Raw
    $mtuActive = ($cfg -match '(?m)^\s*udp_mtu\s*=')
    Check "P-CSCF udp_mtu 已注释(终呼477修复)" (-not $mtuActive) $(if ($mtuActive) { "仍有生效的 udp_mtu 行" } else { "无生效 udp_mtu 行" })
} else {
    Info "  (未找到 kamailio_pcscf.cfg，跳过)"
}

# ---- 6. ZMQ 过渡验证 attach ----
if (-not $SkipZmq) {
    Info ""
    Info "--- 6. ZMQ 过渡验证（srsUE attach）---"
    $ueRunning = docker inspect -f "{{.State.Running}}" srsue_zmq 2>$null
    if ($ueRunning -eq 'true') {
        $ueLog = docker logs srsue_zmq 2>&1 | Out-String
        $attachOk = ($ueLog -match 'Network attach successful')
        $attachLine = ''
        $m = $ueLog -split "`n" | Select-String 'Network attach successful' | Select-Object -Last 1
        if ($m) { $attachLine = $m.ToString().Trim() }
        Check "srsUE 已 attach 并拿到 IP" $attachOk $attachLine
    } else {
        Info "  srsue_zmq 未运行（若已切 USRP 真机可加 -SkipZmq 忽略）"
    }
} else {
    Info ""
    Info "--- 6. ZMQ 过渡验证：已用 -SkipZmq 跳过（USRP 真机模式）---"
}

# ---- 汇总 ----
Info ""
Info "==================================================================="
$total = $script:pass + $script:fail
Info (" 结果: {0} 通过 / {1} 失败  (共 {2} 项计分检查)" -f $script:pass, $script:fail, $total)
if ($script:fail -eq 0) {
    Info " 结论: 全部通过，环境健康。"
} else {
    Info " 结论: 存在失败项，请查看上方 [FAIL] 行。"
}
Info "==================================================================="

# ---- 写报告 ----
try {
    $script:lines | Out-File -FilePath $report -Encoding UTF8
    $fixed = Join-Path $root 'runtime\verify-latest.txt'
    $script:lines | Out-File -FilePath $fixed -Encoding UTF8
    Write-Host ""
    Write-Host ("报告已保存: " + $report) -ForegroundColor Yellow
} catch {
    Write-Host ("报告写入失败: " + $_.Exception.Message) -ForegroundColor Red
}

if ($script:fail -gt 0) { exit 1 } else { exit 0 }
