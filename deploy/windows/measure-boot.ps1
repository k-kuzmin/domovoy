#Requires -Version 5.1
<#
.SYNOPSIS
  Замер после загрузки Windows: от старта ОС до первого ответа /health стека.

.DESCRIPTION
  Ставится deploy/windows/engine-setup.ps1 -Install задачей
  domovoy-measure-boot: при запуске системы, от пользователя с типом входа
  S4U и обычными правами — не SYSTEM: сценарий лежит в клоне, который
  пользователь может менять. Дистрибутив WSL задаче не нужен, она только
  опрашивает порт с хоста:

    http://127.0.0.1:<Port>/health — каждые -IntervalSeconds (5 с),
    пока не придёт ответ 200 формы стека или не выйдет -TimeoutMinutes (30).

  -Port задаётся при регистрации: API_HTTP_PORT из .env клона, без него —
  значение по умолчанию из docker-compose.yml. В сценарии числа нет.

  Засчитывается только ответ 200 с телом ровно {"status":"healthy"} или
  {"status":"degraded"} — форма анонимного /health. Иной ответ 200 — чужой
  слушатель на порту, он отмечается и не засчитывается. 503 до готовности
  базы или Home Assistant — «первый ответ», но не «первый 200».

  Одна строка на загрузку дописывается в -LogPath (по умолчанию
  %LOCALAPPDATA%\domovoy-engine\measure-boot.log; установщик задаёт путь
  явно), UTF-8:

    os_start      — событие System / Microsoft-Windows-Kernel-General ID 12
                    (старт ядра); рядом last_boot — LastBootUpTime, который
                    после «Завершения работы» при быстром запуске показывает
                    гибридную загрузку;
    fw_post_ms    — FwPOSTTime (время POST прошивки), «нет данных», если
                    прошивка его не отдаёт;
    first_response, first_200 — моменты и секунды от os_start;
    foreign       — первый ответ 200 чужой формы, если был;
    result        — ok или «нет ответа 200».

  Адресов, имён хоста и пользователя в строке нет.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 65535)]
    [int]$Port,
    [ValidateRange(0.01, 1440)]
    [double]$TimeoutMinutes = 30,
    [ValidateRange(1, 300)]
    [int]$IntervalSeconds = 5,
    [string]$LogPath = (Join-Path $env:LOCALAPPDATA 'domovoy-engine\measure-boot.log')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$invariant = [Globalization.CultureInfo]::InvariantCulture
$stamp = 'yyyy-MM-ddTHH:mm:ss'
# Форма анонимного /health (HealthEndpoints.cs, README «Быстрый старт»).
$stackBody = '^\s*\{\s*"status"\s*:\s*"(healthy|degraded)"\s*\}\s*$'

function Format-Moment($moment) {
    if ($null -eq $moment) { return 'нет данных' }
    return $moment.ToString($stamp, $invariant)
}

function Format-Since($moment, $origin) {
    if ($null -eq $moment -or $null -eq $origin) { return '' }
    return (' (+{0} с)' -f [math]::Round(($moment - $origin).TotalSeconds).ToString($invariant))
}

$kernelStart = $null
try {
    $bootEvent = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-General'; Id = 12 } `
        -MaxEvents 1 -ErrorAction Stop
    $kernelStart = $bootEvent.TimeCreated
}
catch {
    $kernelStart = $null
}

$lastBoot = $null
try { $lastBoot = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime } catch { $lastBoot = $null }

$fwPost = 'нет данных'
$power = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue
if ($power -and $power.PSObject.Properties['FwPOSTTime'] -and $power.FwPOSTTime) {
    $fwPost = [string]$power.FwPOSTTime
}

# HttpClient, а не Invoke-WebRequest: в Windows PowerShell 5.1 и pwsh 7
# ответ 503 и тело без типа JSON у Invoke-WebRequest приходят по-разному.
Add-Type -AssemblyName System.Net.Http
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.UseProxy = $false
$client = New-Object System.Net.Http.HttpClient($handler)
# Отказ соединения на закрытый порт Windows ждёт около 2 с — запас.
$client.Timeout = [TimeSpan]::FromSeconds(10)
# 127.0.0.1, не localhost: IPv6-петля ::1 до движка WSL не проходит
# (правило Hyper-V её не принимает), и запрос висел бы до тайм-аута.
$url = 'http://127.0.0.1:{0}/health' -f $Port

$firstResponse = $null
$firstCode = ''
$first200 = $null
$foreign = $null
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)

try {
    while ((Get-Date) -lt $deadline) {
        $now = Get-Date
        try {
            $response = $client.GetAsync($url).GetAwaiter().GetResult()
            $code = [int]$response.StatusCode
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $response.Dispose()
            if ($null -eq $firstResponse) {
                $firstResponse = $now
                $firstCode = [string]$code
            }
            if ($code -eq 200) {
                if ($body -match $stackBody) {
                    $first200 = $now
                    break
                }
                if ($null -eq $foreign) { $foreign = $now }
            }
        }
        catch {
            # Нет слушателя или тайм-аут: ответа ещё нет, опрос продолжается.
            $null = $_
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
}
finally {
    $client.Dispose()
}

$parts = New-Object System.Collections.Generic.List[string]
$parts.Add('os_start=' + (Format-Moment $kernelStart))
$parts.Add('last_boot=' + (Format-Moment $lastBoot))
$parts.Add('fw_post_ms=' + $fwPost)
$parts.Add('port=' + $Port)
if ($firstResponse) {
    $parts.Add(('first_response={0} код {1}{2}' -f (Format-Moment $firstResponse), $firstCode, (Format-Since $firstResponse $kernelStart)))
}
else {
    $parts.Add('first_response=нет')
}
if ($first200) {
    $parts.Add(('first_200={0}{1}' -f (Format-Moment $first200), (Format-Since $first200 $kernelStart)))
}
else {
    $parts.Add('first_200=нет')
}
if ($foreign) {
    $parts.Add(('foreign={0} чужой слушатель: ответ 200 не формы стека' -f (Format-Moment $foreign)))
}
if ($first200) {
    $parts.Add('result=ok')
}
else {
    $parts.Add(('result=нет ответа 200 за {0} мин' -f $TimeoutMinutes.ToString($invariant)))
}

$line = ($parts -join '; ')
$dir = Split-Path -Parent $LogPath
if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
    $null = New-Item -ItemType Directory -Path $dir -Force
}
# UTF-8 с BOM: Get-Content в Windows PowerShell 5.1 без BOM читает файл в
# кодировке ANSI, и русские слова строки приходят в чужой кодировке.
# AppendAllText кладёт BOM, только когда файла нет. Журнал прежней версии
# (UTF-8 без BOM) получает BOM в начало: байты строк не перекодируются —
# они и так UTF-8.
if (Test-Path -LiteralPath $LogPath -PathType Leaf) {
    $existing = [IO.File]::ReadAllBytes($LogPath)
    $hasBom = $existing.Length -ge 3 -and $existing[0] -eq 0xEF -and $existing[1] -eq 0xBB -and $existing[2] -eq 0xBF
    if ($existing.Length -and -not $hasBom) {
        [IO.File]::WriteAllBytes($LogPath, [byte[]](@(0xEF, 0xBB, 0xBF) + $existing))
    }
}
[IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine, (New-Object Text.UTF8Encoding($true)))
Write-Output $line
if ($first200) { exit 0 }
exit 1
