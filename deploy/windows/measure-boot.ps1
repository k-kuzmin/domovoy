#Requires -Version 5.1
<#
.SYNOPSIS
  Хронология загрузки Windows: от старта ОС до готовности стека в движке —
  дистрибутив, docker, каждый контейнер, смены статуса /health (#147).

.DESCRIPTION
  Ставится deploy/windows/engine-setup.ps1 -Install задачей
  domovoy-measure-boot: при запуске системы, от пользователя с типом входа
  S4U и обычными правами — не SYSTEM: сценарий лежит в клоне, который
  пользователь может менять.

  Каждые -IntervalSeconds (5 с):
    - http://127.0.0.1:<Port>/health — статус стека;
    - wsl.exe --list --running --quiet — и только если дистрибутив -Distro
      уже работает, зонд внутри него:
        wsl.exe -d <Distro> -u root --cd <клон> --exec bash deploy/windows/boot-probe.sh <Project>
      Замер сам дистрибутив не поднимает: до старта держалки его нет в
      списке работающих, и wsl.exe -d не вызывается.

  -Port, -Distro и -Project задаются при регистрации: API_HTTP_PORT и
  COMPOSE_PROJECT_NAME из .env клона, без них — значения по умолчанию из
  docker-compose.yml. В сценарии чисел портов нет.

  Статус /health: 200 с телом ровно {"status":"healthy"} или
  {"status":"degraded"} и 503 с телом {"status":"unhealthy"} — форма
  анонимного /health. Иной ответ 200 — чужой слушатель на порту, он
  отмечается и статусом не считается.

  Журнал -LogPath (по умолчанию %LOCALAPPDATA%\domovoy-engine\measure-boot.log;
  установщик задаёт путь явно), UTF-8 с BOM. Строка на событие, дописывается
  в момент события — жёсткое выключение хоста в окне замера не теряет уже
  записанное. У каждой строки метка загрузки boot=<старт ОС>, момент в
  местном времени Windows с секундами от старта ОС и источник момента:
  src=windows — часы Windows (опрос), src=engine — момент изнутри ВМ,
  переданный зондом секундами Unix.

    os_start           событие System / Microsoft-Windows-Kernel-General
                       ID 12 (старт ядра); рядом last_boot — LastBootUpTime
                       (после «Завершения работы» при быстром запуске —
                       гибридная загрузка), fw_post_ms — FwPOSTTime, port;
    distro_start       старт дистрибутива (один раз);
    docker_active      docker.service active (один раз);
    container_start    старт контейнера проекта, name=<имя>; новый старт
                       того же контейнера в окне замера — ещё одна строка с
                       пометкой restart, и его healthy ждётся заново;
    container_healthy  опрос, на котором контейнер впервые после старта
                       увиден healthy (точность — -IntervalSeconds); у
                       контейнера без healthcheck — healthcheck=нет и момент
                       его старта;
    health             смена статуса /health, status=<статус>;
    probe_error        отказ зонда с новым текстом — первой строкой stderr;
    итоговая строка    first_response, first_200, foreign (если был чужой
                       ответ 200), distro_start=нет данных (если дистрибутив
                       так и не увиден), stop, result.

  Опрос кончается, когда /health healthy и каждый контейнер с healthcheck
  healthy (пустой набор контейнеров этого не выполняет) — stop=ready, когда
  статус /health и состояния контейнеров не менялись -StableMinutes (5)
  подряд — stop=stable, или по -TimeoutMinutes (30) — stop=timeout; рядом с
  причиной — фактическое время опроса в минутах. Итог result=ok и код 0 —
  только при /health healthy и переходе в healthy каждого контейнера; без
  ответа 200 формы стека — «нет ответа 200 за <время опроса> мин опроса»;
  без данных о контейнерах — «нет данных о контейнерах», даже при healthy
  /health.

  Адресов, имён хоста и пользователя в строках нет.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 65535)]
    [int]$Port,
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9][a-z0-9_-]*$')]
    [string]$Project,
    [string]$Distro = 'domovoy-engine',
    [ValidateRange(0.01, 1440)]
    [double]$TimeoutMinutes = 30,
    [ValidateRange(0.01, 1440)]
    [double]$StableMinutes = 5,
    [ValidateRange(1, 300)]
    [int]$IntervalSeconds = 5,
    [string]$LogPath = (Join-Path $env:LOCALAPPDATA 'domovoy-engine\measure-boot.log'),
    # wsl.exe; тест подменяет его, чтобы видеть вызовы.
    [string]$WslExe = (Join-Path $env:SystemRoot 'System32\wsl.exe')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$invariant = [Globalization.CultureInfo]::InvariantCulture
$stamp = 'yyyy-MM-ddTHH:mm:ss'
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).ProviderPath

function Format-Moment($moment) {
    if ($null -eq $moment) { return 'нет данных' }
    return $moment.ToString($stamp, $invariant)
}

function Format-Since($moment, $origin) {
    if ($null -eq $moment -or $null -eq $origin) { return '' }
    return (' (+{0} с)' -f [math]::Round(($moment - $origin).TotalSeconds).ToString($invariant))
}

# Статус /health по коду и телу — форма анонимного /health
# (HealthEndpoints.cs, README «Быстрый старт»). Status: healthy, degraded,
# unhealthy или '' — не статус стека; Foreign — ответ 200 чужой формы.
function Get-HealthStatus([int]$Code, [string]$Body) {
    $m = [regex]::Match($Body, '^\s*\{\s*"status"\s*:\s*"(healthy|degraded|unhealthy)"\s*\}\s*$')
    $status = ''
    if ($m.Success) {
        $value = $m.Groups[1].Value
        if (($Code -eq 200 -and $value -ne 'unhealthy') -or ($Code -eq 503 -and $value -eq 'unhealthy')) { $status = $value }
    }
    return [pscustomobject]@{ Status = $status; Foreign = ($Code -eq 200 -and -not $status) }
}

# Момент из секунд Unix — в местное время Windows; не число — $null (нет
# данных): местное время ВМ со своей зоной не угадывается.
function ConvertFrom-UnixSeconds([string]$Text) {
    $seconds = 0L
    if ($Text -notmatch '^\d{1,12}$' -or -not [long]::TryParse($Text, [ref]$seconds) -or $seconds -le 0) { return $null }
    return [DateTimeOffset]::FromUnixTimeSeconds($seconds).ToLocalTime().DateTime
}

# Вывод deploy/windows/boot-probe.sh: строки key=value, моменты — секунды
# Unix. Строка с моментом не числом — нет данных по ней, а не сдвинутое
# время; прочие строки пропускаются. Неполный вывод засчитывается построчно.
function ConvertFrom-BootProbe([string[]]$Lines) {
    $distroStart = $null
    $dockerActive = $null
    $containers = New-Object System.Collections.Generic.List[object]
    foreach ($raw in $Lines) {
        $line = ([string]$raw).Trim()
        if ($line -match '^distro_start=(\S*)$') { $distroStart = ConvertFrom-UnixSeconds $Matches[1] }
        elseif ($line -match '^docker_active=(\S*)$') { $dockerActive = ConvertFrom-UnixSeconds $Matches[1] }
        elseif ($line -match '^container name=(\S+) started_at=(\S*) health=(\S+)$') {
            $name = $Matches[1]
            $health = $Matches[3]
            $epoch = $Matches[2]
            $started = ConvertFrom-UnixSeconds $epoch
            if ($null -ne $started) {
                $containers.Add([pscustomobject]@{ Name = $name; StartedAt = $started; Epoch = $epoch; Health = $health })
            }
        }
    }
    # ToArray, а не @(): @(List) значением в [pscustomobject]@{} даёт
    # «Argument types do not match».
    return [pscustomobject]@{ DistroStart = $distroStart; DockerActive = $dockerActive; Containers = $containers.ToArray() }
}

# Кодировка, в которой PowerShell читает вывод внешней программы, — та же
# логика, что Set-NativeOutputEncoding в deploy/windows/engine-setup.ps1:
# wsl.exe с WSL_UTF8 и bash пишут UTF-8, а консоль русской Windows — CP866.
# Без консоли установка может бросить — тогда кодировка не меняется.
function Set-NativeOutputEncoding {
    $previous = $null
    try {
        $previous = [Console]::OutputEncoding
        [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    }
    catch { $previous = $null }
    return $previous
}

function Restore-NativeOutputEncoding($Previous) {
    if ($null -eq $Previous) { return }
    try { [Console]::OutputEncoding = $Previous } catch { }
}

# wsl.exe: stdout и stderr раздельно, как Invoke-Native в engine-setup.ps1.
function Invoke-Wsl([string[]]$Arguments) {
    $env:WSL_UTF8 = '1'
    $previousAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = New-Object System.Collections.Generic.List[string]
    $err = New-Object System.Collections.Generic.List[string]
    $encoding = Set-NativeOutputEncoding
    try {
        & $WslExe @Arguments 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $err.Add([string]$_) } else { $out.Add([string]$_) }
        }
        $code = $LASTEXITCODE
    }
    catch {
        $code = -1
        $err.Add($_.Exception.Message)
    }
    finally {
        $ErrorActionPreference = $previousAction
        Restore-NativeOutputEncoding $encoding
    }
    return [pscustomobject]@{ Code = $code; Lines = @($out); ErrLines = @($err | Where-Object { $_.Trim() }) }
}

# Имена из wsl.exe --list. Если wsl.exe WSL_UTF8 не учёл и отдал UTF-16LE
# с BOM, при чтении как UTF-8 между буквами остаются NUL, а BOM — U+FEFF
# или U+FFFD: они убираются во всей строке, а не только по краям.
function ConvertFrom-WslList([string[]]$Lines) {
    $text = ($Lines -join "`n") -replace "[\u0000\uFEFF\uFFFD]", ''
    return @($text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-DistroRunning {
    if (-not (Test-Path -LiteralPath $WslExe -PathType Leaf)) { return $false }
    $list = Invoke-Wsl @('--list', '--running', '--quiet')
    if ($list.Code -ne 0) { return $false }
    # Ordinal, а не -contains: культурное сравнение PowerShell пропускает
    # NUL, и имя с NUL между буквами совпало бы — сломанный разбор был бы
    # незаметен.
    return [bool]@(ConvertFrom-WslList $list.Lines | Where-Object { [string]::Equals($_, $Distro, [StringComparison]::OrdinalIgnoreCase) }).Count
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

$bootLabel = 'boot=' + (Format-Moment $kernelStart)

# Журнал: UTF-8 с BOM — Get-Content в Windows PowerShell 5.1 без BOM читает
# файл в кодировке ANSI. AppendAllText кладёт BOM, только когда файла нет;
# журнал прежней версии (UTF-8 без BOM) получает BOM в начало, байты строк
# не перекодируются — они и так UTF-8.
$dir = Split-Path -Parent $LogPath
if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
    $null = New-Item -ItemType Directory -Path $dir -Force
}
if (Test-Path -LiteralPath $LogPath -PathType Leaf) {
    $existing = [IO.File]::ReadAllBytes($LogPath)
    $hasBom = $existing.Length -ge 3 -and $existing[0] -eq 0xEF -and $existing[1] -eq 0xBB -and $existing[2] -eq 0xBF
    if ($existing.Length -and -not $hasBom) {
        [IO.File]::WriteAllBytes($LogPath, [byte[]](@(0xEF, 0xBB, 0xBF) + $existing))
    }
}

# Событие — строкой сразу: до конца опроса может не дойти.
function Write-Event([string[]]$Parts) {
    $line = (@($bootLabel) + $Parts) -join '; '
    [IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine, (New-Object Text.UTF8Encoding($true)))
    Write-Output $line
}

function Get-MomentPart([string]$Key, $Moment) {
    return ('{0}={1}{2}' -f $Key, (Format-Moment $Moment), (Format-Since $Moment $kernelStart))
}

Write-Event @(('os_start=' + (Format-Moment $kernelStart)), ('last_boot=' + (Format-Moment $lastBoot)), ('fw_post_ms=' + $fwPost), ('port=' + $Port), 'src=windows')

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
$probeArgs = @('-d', $Distro, '-u', 'root', '--cd', $root, '--exec', 'bash', 'deploy/windows/boot-probe.sh', $Project)

$firstResponse = $null
$firstCode = ''
$first200 = $null
$foreign = $null
$health = ''
$distroSeen = $false
$dockerSeen = $false
$probeError = ''
# Имя контейнера → последний увиденный старт (секунды Unix), увиден ли
# healthy после него, есть ли healthcheck.
$containers = @{}
$started = Get-Date
$deadline = $started.AddMinutes($TimeoutMinutes)
$lastChange = $started
# Причина конца опроса: ready — /health и контейнеры healthy, stable —
# состояния не менялись -StableMinutes, timeout — вышел -TimeoutMinutes.
$stop = 'timeout'

try {
    while ((Get-Date) -lt $deadline) {
        $now = Get-Date
        $changed = $false

        try {
            $response = $client.GetAsync($url).GetAwaiter().GetResult()
            $code = [int]$response.StatusCode
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $response.Dispose()
            if ($null -eq $firstResponse) {
                $firstResponse = $now
                $firstCode = [string]$code
            }
            $parsed = Get-HealthStatus $code $body
            if ($parsed.Foreign -and $null -eq $foreign) { $foreign = $now }
            if ($parsed.Status) {
                if ($null -eq $first200 -and $code -eq 200) { $first200 = $now }
                if ($parsed.Status -ne $health) {
                    $health = $parsed.Status
                    $changed = $true
                    Write-Event @((Get-MomentPart 'health' $now), "status=$health", 'src=windows')
                }
            }
        }
        catch {
            # Нет слушателя или тайм-аут: ответа ещё нет, опрос продолжается.
            $null = $_
        }

        if (Test-DistroRunning) {
            $probe = Invoke-Wsl $probeArgs
            $data = ConvertFrom-BootProbe $probe.Lines
            if (-not $distroSeen -and $null -ne $data.DistroStart) {
                $distroSeen = $true
                $changed = $true
                Write-Event @((Get-MomentPart 'distro_start' $data.DistroStart), 'src=engine')
            }
            if (-not $dockerSeen -and $null -ne $data.DockerActive) {
                $dockerSeen = $true
                $changed = $true
                Write-Event @((Get-MomentPart 'docker_active' $data.DockerActive), 'src=engine')
            }
            foreach ($c in $data.Containers) {
                $known = $containers[$c.Name]
                if ($null -eq $known -or $known.Epoch -ne $c.Epoch) {
                    $parts = @((Get-MomentPart 'container_start' $c.StartedAt), "name=$($c.Name)")
                    if ($null -ne $known) { $parts += 'restart' }
                    Write-Event ($parts + 'src=engine')
                    $known = [pscustomobject]@{ Epoch = $c.Epoch; Healthy = $false; Check = ($c.Health -ne 'none') }
                    $containers[$c.Name] = $known
                    $changed = $true
                    if (-not $known.Check) {
                        $known.Healthy = $true
                        Write-Event @((Get-MomentPart 'container_healthy' $c.StartedAt), "name=$($c.Name)", 'healthcheck=нет', 'src=engine')
                    }
                }
                if ($known.Check -and -not $known.Healthy -and $c.Health -eq 'healthy') {
                    $known.Healthy = $true
                    $changed = $true
                    Write-Event @((Get-MomentPart 'container_healthy' $now), "name=$($c.Name)", 'src=windows')
                }
            }
            if ($probe.Code -ne 0) {
                $text = if (@($probe.ErrLines).Count) { ([string]@($probe.ErrLines)[0]).Trim() } else { "код $($probe.Code)" }
                if ($text.Length -gt 200) { $text = $text.Substring(0, 200) }
                if ($text -ne $probeError) {
                    $probeError = $text
                    Write-Event @((Get-MomentPart 'probe_error' $now), "text=$text", 'src=windows')
                }
            }
        }

        if ($changed) { $lastChange = $now }
        $allHealthy = $health -eq 'healthy' -and $containers.Count -gt 0 -and
            -not @($containers.Values | Where-Object { -not $_.Healthy }).Count
        if ($allHealthy) { $stop = 'ready'; break }
        if (((Get-Date) - $lastChange).TotalMinutes -ge $StableMinutes) { $stop = 'stable'; break }
        Start-Sleep -Seconds $IntervalSeconds
    }
}
finally {
    $client.Dispose()
}

$parts = New-Object System.Collections.Generic.List[string]
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
if (-not $distroSeen) { $parts.Add('distro_start=нет данных') }
$polled = ((Get-Date) - $started).TotalMinutes.ToString('0.##', $invariant)
$parts.Add(('stop={0} через {1} мин' -f $stop, $polled))
$notHealthy = @($containers.Keys | Where-Object { -not $containers[$_].Healthy } | Sort-Object)
$ok = $false
if (-not $first200) {
    $parts.Add(('result=нет ответа 200 за {0} мин опроса' -f $polled))
}
elseif (-not $containers.Count) {
    $parts.Add('result=нет данных о контейнерах')
}
elseif ($health -ne 'healthy' -or $notHealthy.Count) {
    $why = @()
    if ($health -ne 'healthy') { $why += "/health $health" }
    if ($notHealthy.Count) { $why += ('не healthy: ' + ($notHealthy -join ', ')) }
    $parts.Add('result=не готово: ' + ($why -join '; '))
}
else {
    $ok = $true
    $parts.Add('result=ok')
}
Write-Event @($parts)
if ($ok) { exit 0 }
exit 1
