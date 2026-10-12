#Requires -Version 5.1
<#
.SYNOPSIS
  Docker Engine в WSL2-дистрибутиве domovoy-engine с запуском при старте
  Windows без входа пользователя (#6, запись 0028).

.DESCRIPTION
  Воспроизводимая настройка хоста на Windows 11 — и для переезда на другой ПК.

    powershell -ExecutionPolicy Bypass -File deploy/windows/engine-setup.ps1 -Install          # терминал администратора
    powershell -ExecutionPolicy Bypass -File deploy/windows/engine-setup.ps1 -Install -DryRun  # что было бы сделано
    powershell -ExecutionPolicy Bypass -File deploy/windows/engine-setup.ps1 -Check            # только чтение

  -Install (повторный запуск ничего не дублирует):
    1. дистрибутив domovoy-engine: wsl --import официального образа Ubuntu
       24.04 для WSL (cloud-images.ubuntu.com), SHA256 сверяется с SHA256SUMS
       того же каталога; уже зарегистрированный не трогается;
    2. провижининг внутри под root — deploy/windows/provision-engine.sh:
       systemd, Docker Engine с compose, git, safe.directory клона. Если
       systemd ещё не запущен, первый проход только включает его, затем
       wsl --terminate domovoy-engine (только этот дистрибутив) и второй
       проход под systemd;
    3. задача domovoy-engine: при запуске системы, от текущего пользователя
       с типом входа S4U (пароль не хранится), держалка
       wsl.exe -d domovoy-engine --exec sleep infinity — экземпляр WSL живёт,
       пока жив хоть один процесс wsl.exe; без предела времени
       (ExecutionTimeLimit 0), не останавливается на батарее (UPS по USB
       Windows видит батареей), перезапуск при сбое;
    4. задача domovoy-measure-boot: при запуске системы, под SYSTEM,
       deploy/windows/measure-boot.ps1 -Port <порт API>;
    5. %USERPROFILE%\.wslconfig: [wsl2] networkingMode=mirrored — порты
       дистрибутива видны на адресе хоста. Прежний файл сохраняется копией
       .wslconfig.domovoy-backup, отсутствие — отметкой .wslconfig.domovoy-absent.
       Другое значение networkingMode — отказ: чужая настройка не переписывается.
       Применяется после wsl --shutdown — его -Install не выполняет (гасит
       все дистрибутивы, в том числе Docker Desktop);
    6. правило Hyper-V firewall domovoy-engine-ports: входящие TCP на порты
       API и Home Assistant, только с локальной подсети и с адресов петли
       хоста (127.0.0.1, ::1);
    7. последним шагом — расписание бэкапа:
       ops/backup/install-schedule.ps1 -Install -LogonType S4U.

  Порты: API_HTTP_PORT и HA_HTTP_PORT из .env клона, без них — значения по
  умолчанию из docker-compose.yml. Проект compose — COMPOSE_PROJECT_NAME так
  же. Чисел портов в сценарии нет.

  -Check только читает: ничего не запускает и не останавливает, внутрь
  дистрибутива заходит, только если он уже работает. Каждое звено — строка
  OK / FAIL / SKIP; код 0 — только если все OK. SKIP — «не проверено»
  (дистрибутив не запущен, нет прав прочитать правило), код тоже ненулевой.

  Предусловия, которые сценарий не проверяет: в BIOS «восстановление после
  пропадания питания — включиться»; BitLocker без PIN до загрузки.
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Check,
    [switch]$DryRun,
    [string]$WslConfigPath = (Join-Path $env:USERPROFILE '.wslconfig'),
    [string]$DistroDir = (Join-Path $env:LOCALAPPDATA 'domovoy-engine')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Distro = 'domovoy-engine'
$KeeperTask = 'domovoy-engine'
$MeasureTask = 'domovoy-measure-boot'
$BackupTask = 'domovoy-backup'
$RuleName = 'domovoy-engine-ports'
# VMCreatorId WSL для правил Hyper-V firewall (документация WSL, mirrored).
$WslVmCreatorId = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
$ImageBase = 'https://cloud-images.ubuntu.com/wsl/releases/24.04/current'
$ImageFile = 'ubuntu-noble-wsl-amd64-24.04lts.rootfs.tar.gz'
$RemoteAddresses = @('LocalSubnet', '127.0.0.1', '::1')

function Stop-WithError([string]$Message, [int]$Code = 1) {
    [Console]::Error.WriteLine("engine-setup: $Message")
    exit $Code
}

if ($Install -and $Check) { Stop-WithError 'укажите один режим: -Install или -Check' 2 }
if (-not $Install -and -not $Check) { Stop-WithError 'укажите режим: -Install или -Check' 2 }
if ($DryRun -and -not $Install) { Stop-WithError '-DryRun — только с -Install' 2 }

$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).ProviderPath
$envFile = Join-Path $root '.env'
$composeFile = Join-Path $root 'docker-compose.yml'
$measureScript = Join-Path $root 'deploy\windows\measure-boot.ps1'
$scheduleScript = Join-Path $root 'ops\backup\install-schedule.ps1'
$wslExe = Join-Path $env:SystemRoot 'System32\wsl.exe'
$invariant = [Globalization.CultureInfo]::InvariantCulture

# Значение ключа из .env без исполнения файла — та же логика, что
# Get-DotEnvValue в ops/backup/install-schedule.ps1 и ops/backup/dotenv.sh.
function Get-DotEnvValue([string]$Path, [string]$Key) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $value = ''
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line.StartsWith("$Key=", [StringComparison]::Ordinal)) {
            $value = $line.Substring($Key.Length + 1)
        }
    }
    $value = $value.TrimEnd("`r").TrimStart(' ', "`t")
    if ($value -cmatch '^"([^"]*)"[ \t]*(#.*)?$' -or $value -cmatch "^'([^']*)'[ \t]*(#.*)?$") {
        $value = $Matches[1]
    }
    else {
        $value = ($value -creplace '[ \t]#.*$', '').TrimEnd(' ', "`t")
    }
    if ($value -match '<.*>') { return '' }
    return $value
}

# Значение по умолчанию переменной из docker-compose.yml: ${KEY:-значение}.
function Get-ComposeDefault([string]$Key) {
    if (-not (Test-Path -LiteralPath $composeFile -PathType Leaf)) { return '' }
    $m = [regex]::Match([IO.File]::ReadAllText($composeFile), '\$\{' + [regex]::Escape($Key) + ':-([^}]*)\}')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

function Get-Setting([string]$Key) {
    $value = Get-DotEnvValue $envFile $Key
    if (-not $value) { $value = Get-ComposeDefault $Key }
    return $value
}

function Get-Port([string]$Key) {
    $value = Get-Setting $Key
    $port = 0
    if (-not [int]::TryParse($value, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        Stop-WithError "$Key — не порт: «$value» (.env клона или значение по умолчанию в docker-compose.yml)" 2
    }
    return $port
}

# Внешняя программа с выводом stdout и stderr одной строкой. stderr при
# 2>&1 в Windows PowerShell 5.1 приходит записями ошибок, и при
# ErrorActionPreference Stop первая строка прервала бы сценарий.
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(& $Exe @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{ Code = $code; Lines = $lines; Text = ($lines -join "`n").Trim() }
}

# wsl.exe по умолчанию пишет UTF-16; WSL_UTF8 переводит вывод в UTF-8.
function Invoke-Wsl([string[]]$Arguments) {
    $env:WSL_UTF8 = '1'
    return Invoke-Native $wslExe $Arguments
}

function Get-WslNames([string[]]$Arguments) {
    if (-not (Test-Path -LiteralPath $wslExe -PathType Leaf)) { return @() }
    $result = Invoke-Wsl $Arguments
    if ($result.Code -ne 0) { return @() }
    return @($result.Text -split "`r?`n" | ForEach-Object { $_.Trim([char]0, ' ') } | Where-Object { $_ })
}

# Новое содержимое .wslconfig: mirrored в [wsl2], прочее не трогается.
# Changed = $false — файл уже такой; Conflict — задан другой networkingMode.
function Get-WslConfigPlan([string]$Path) {
    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    $current = if ($exists) { [IO.File]::ReadAllText($Path) } else { '' }
    $mode = [regex]::Match($current, '(?im)^\s*networkingMode\s*=\s*(\S+)\s*$')
    if ($mode.Success) {
        if ($mode.Groups[1].Value -ieq 'mirrored') {
            return [pscustomobject]@{ Exists = $exists; Changed = $false; Conflict = ''; Content = $current }
        }
        return [pscustomobject]@{ Exists = $exists; Changed = $false; Conflict = $mode.Groups[1].Value; Content = $current }
    }
    if ($current -match '(?im)^\s*\[wsl2\]\s*$') {
        $content = [regex]::Replace($current, '(?im)^(\s*\[wsl2\]\s*)$', "`$1`r`nnetworkingMode=mirrored", 1)
    }
    elseif ($current.Trim()) {
        $content = $current.TrimEnd() + "`r`n`r`n[wsl2]`r`nnetworkingMode=mirrored`r`n"
    }
    else {
        $content = "[wsl2]`r`nnetworkingMode=mirrored`r`n"
    }
    return [pscustomobject]@{ Exists = $exists; Changed = $true; Conflict = ''; Content = $content }
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal $identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Ответ /health формы стека: 200 и тело {"status":"healthy|degraded"}.
# HttpClient одинаково ведёт себя в Windows PowerShell 5.1 и pwsh 7.
function Get-Health([string]$Url) {
    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.UseProxy = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(5)
    try {
        $response = $client.GetAsync($Url).GetAwaiter().GetResult()
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $code = [int]$response.StatusCode
        $response.Dispose()
        $stack = $code -eq 200 -and $body -match '^\s*\{\s*"status"\s*:\s*"(healthy|degraded)"\s*\}\s*$'
        return [pscustomobject]@{ Code = $code; Stack = $stack; Error = '' }
    }
    catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        return [pscustomobject]@{ Code = 0; Stack = $false; Error = $inner.Message }
    }
    finally {
        $client.Dispose()
    }
}

$apiPort = Get-Port 'API_HTTP_PORT'
$haPort = Get-Port 'HA_HTTP_PORT'
$project = Get-Setting 'COMPOSE_PROJECT_NAME'
$userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name

if ($Install) {
    # Объекты задач и параметры правила собираются до любых действий; сухой
    # прогон печатает их свойства: что напечатано, то и регистрируется.
    $bootTrigger = New-ScheduledTaskTrigger -AtStartup
    $keeperAction = New-ScheduledTaskAction -Execute $wslExe -Argument ('-d {0} --exec sleep infinity' -f $Distro)
    $keeperPrincipal = New-ScheduledTaskPrincipal -UserId $userId -LogonType S4U -RunLevel Limited
    $keeperSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew

    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $measureArgument = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Port {1}' -f $measureScript, $apiPort
    $measureAction = New-ScheduledTaskAction -Execute $powershellExe -Argument $measureArgument
    $measurePrincipal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $measureSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 1) -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew

    $ruleParams = @{
        Name            = $RuleName
        DisplayName     = 'Домовой: порты стека в WSL из локальной сети'
        Direction       = 'Inbound'
        VMCreatorId     = $WslVmCreatorId
        Protocol        = 'TCP'
        LocalPorts      = @([string]$apiPort, [string]$haPort)
        RemoteAddresses = $RemoteAddresses
        Action          = 'Allow'
    }

    $wslConfig = Get-WslConfigPlan $WslConfigPath
    $registered = (Get-WslNames @('--list', '--quiet')) -contains $Distro
    $diskDir = Join-Path $DistroDir 'disk'
    $downloadDir = Join-Path $DistroDir 'download'
    $tar = Join-Path $downloadDir $ImageFile
    $importArgs = @('--import', $Distro, $diskDir, $tar, '--version', '2')
    $provisionArgs = @('-d', $Distro, '-u', 'root', '--cd', $root, '--exec', 'bash', 'deploy/windows/provision-engine.sh')
    $scheduleArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $scheduleScript, '-Install', '-LogonType', 'S4U')
    if ($DryRun) { $scheduleArgs += '-DryRun' }

    if ($DryRun) {
        Write-Output "distro: $Distro"
        Write-Output ('distro.registered: {0}' -f $registered)
        if (-not $registered) {
            Write-Output "distro.image: $ImageBase/$ImageFile"
            Write-Output "distro.sha256sums: $ImageBase/SHA256SUMS"
            Write-Output ('distro.import: wsl.exe {0}' -f ($importArgs -join ' '))
        }
        Write-Output ('provision: wsl.exe {0}' -f ($provisionArgs -join ' '))
        Write-Output ('provision.restart: код 3 — wsl.exe --terminate {0} и повтор' -f $Distro)
        Write-Output ('provision.terminate: wsl.exe --terminate {0}' -f $Distro)
        foreach ($task in @(
                @{ Prefix = 'keeper'; Name = $KeeperTask; Action = $keeperAction; Principal = $keeperPrincipal; Settings = $keeperSettings },
                @{ Prefix = 'measure'; Name = $MeasureTask; Action = $measureAction; Principal = $measurePrincipal; Settings = $measureSettings })) {
            $p = $task.Prefix
            Write-Output "${p}.task: $($task.Name)"
            Write-Output "${p}.trigger: $($bootTrigger.CimClass.CimClassName)"
            Write-Output "${p}.execute: $($task.Action.Execute)"
            Write-Output "${p}.arguments: $($task.Action.Arguments)"
            # Имя SYSTEM локализовано («СИСТЕМА» в русской Windows) — печатается и SID.
            Write-Output "${p}.userid: $($task.Principal.UserId)"
            $sid = (New-Object Security.Principal.NTAccount($task.Principal.UserId)).Translate([Security.Principal.SecurityIdentifier]).Value
            Write-Output "${p}.usersid: $sid"
            Write-Output "${p}.logontype: $($task.Principal.LogonType)"
            Write-Output "${p}.runlevel: $($task.Principal.RunLevel)"
            Write-Output "${p}.executiontimelimit: $($task.Settings.ExecutionTimeLimit)"
            Write-Output "${p}.disallowstartifonbatteries: $($task.Settings.DisallowStartIfOnBatteries)"
            Write-Output "${p}.stopifgoingonbatteries: $($task.Settings.StopIfGoingOnBatteries)"
            Write-Output "${p}.multipleinstances: $($task.Settings.MultipleInstances)"
            if ($task.Settings.RestartCount) {
                Write-Output "${p}.restartcount: $($task.Settings.RestartCount)"
                Write-Output "${p}.restartinterval: $($task.Settings.RestartInterval)"
            }
        }
        if ($wslConfig.Conflict) {
            Write-Output "wslconfig.conflict: networkingMode=$($wslConfig.Conflict)"
        }
        else {
            Write-Output ('wslconfig.exists: {0}' -f $wslConfig.Exists)
            Write-Output ('wslconfig.changed: {0}' -f $wslConfig.Changed)
            foreach ($line in ($wslConfig.Content -split "`r?`n")) {
                if ($line) { Write-Output "wslconfig.line: $line" }
            }
        }
        foreach ($key in 'Name', 'Direction', 'VMCreatorId', 'Protocol', 'Action') {
            Write-Output ('firewall.{0}: {1}' -f $key.ToLowerInvariant(), $ruleParams[$key])
        }
        Write-Output ('firewall.localports: {0}' -f ($ruleParams.LocalPorts -join ','))
        Write-Output ('firewall.remoteaddresses: {0}' -f ($ruleParams.RemoteAddresses -join ','))
        $schedule = Invoke-Native (Get-Process -Id $PID).Path $scheduleArgs
        $scheduleCode = $schedule.Code
        foreach ($line in $schedule.Lines) { Write-Output "backup.$line" }
        Write-Output "backup.exitcode: $scheduleCode"
        Write-Output 'DryRun: nothing changed'
        if ($wslConfig.Conflict -or $scheduleCode -ne 0) { exit 1 }
        exit 0
    }

    if (-not (Test-Administrator)) {
        Stop-WithError 'нужен терминал администратора. Запустите терминал «от имени администратора» и повторите.'
    }
    if ($wslConfig.Conflict) {
        Stop-WithError "$WslConfigPath задаёт networkingMode=$($wslConfig.Conflict) — чужая настройка не переписывается; движку нужен mirrored (README, «Автозапуск после перезагрузки»)"
    }
    if (-not (Test-Path -LiteralPath $wslExe -PathType Leaf)) {
        Stop-WithError 'wsl.exe не найден — включите WSL2 (wsl --install) и повторите'
    }

    # 1. Дистрибутив.
    if ($registered) {
        Write-Output "дистрибутив $Distro уже зарегистрирован — не трогается"
    }
    else {
        $null = New-Item -ItemType Directory -Force -Path $downloadDir, $diskDir
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri "$ImageBase/$ImageFile" -OutFile $tar -UseBasicParsing
        # SHA256SUMS — файлом на диск: в Windows PowerShell 5.1 Content этого
        # ответа приходит массивом байт, в pwsh 7 — строкой.
        $sumsFile = Join-Path $downloadDir 'SHA256SUMS'
        Invoke-WebRequest -Uri "$ImageBase/SHA256SUMS" -OutFile $sumsFile -UseBasicParsing
        $m = [regex]::Match([IO.File]::ReadAllText($sumsFile), '(?m)^([0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($ImageFile) + '\s*$')
        $expected = if ($m.Success) { $m.Groups[1].Value.ToLowerInvariant() } else { '' }
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $tar).Hash.ToLowerInvariant()
        if (-not $expected -or $actual -ne $expected) {
            Remove-Item -LiteralPath $tar -Force -ErrorAction SilentlyContinue
            Stop-WithError "SHA256 образа не сошёлся с SHA256SUMS (ожидалось «$expected», получено «$actual») — образ удалён, дистрибутив не создан"
        }
        $import = Invoke-Wsl $importArgs
        if ($import.Code -ne 0) { Stop-WithError "wsl --import: код $($import.Code): $($import.Text)" }
        Remove-Item -LiteralPath $tar, $sumsFile -Force -ErrorAction SilentlyContinue
        Write-Output "дистрибутив $Distro создан из $ImageFile (SHA256 сошёлся)"
    }

    # 2. Провижининг. Код 3 — systemd записан в wsl.conf, но ещё не PID 1:
    # перезапуск только этого дистрибутива и второй проход уже под systemd.
    $env:WSL_UTF8 = '1'
    & $wslExe @provisionArgs
    $provisionCode = $LASTEXITCODE
    if ($provisionCode -eq 3) {
        $null = Invoke-Wsl @('--terminate', $Distro)
        & $wslExe @provisionArgs
        $provisionCode = $LASTEXITCODE
    }
    if ($provisionCode -ne 0) { Stop-WithError "провижининг дистрибутива: код $provisionCode" }
    $null = Invoke-Wsl @('--terminate', $Distro)
    $enabled = Invoke-Wsl @('-d', $Distro, '-u', 'root', '--exec', 'systemctl', 'is-enabled', 'docker.service', 'containerd.service')
    $null = Invoke-Wsl @('--terminate', $Distro)
    if ($enabled.Code -ne 0) { Stop-WithError "docker или containerd не в автозапуске: $($enabled.Text)" }
    Write-Output 'docker.service и containerd.service в автозапуске systemd дистрибутива'

    # 3–4. Задачи; -Force заменяет прежние.
    $null = Register-ScheduledTask -TaskName $KeeperTask -Trigger $bootTrigger -Action $keeperAction -Principal $keeperPrincipal `
        -Settings $keeperSettings -Description 'Домовой: держит WSL-дистрибутив движка Docker после загрузки, без входа' -Force
    Write-Output "задача $KeeperTask зарегистрирована: при запуске системы, S4U"
    $null = Register-ScheduledTask -TaskName $MeasureTask -Trigger $bootTrigger -Action $measureAction -Principal $measurePrincipal `
        -Settings $measureSettings -Description 'Домовой: замер от старта ОС до первого ответа /health' -Force
    Write-Output "задача $MeasureTask зарегистрирована: порт $apiPort, журнал %ProgramData%\domovoy-engine\measure-boot.log"

    # 5. .wslconfig.
    if ($wslConfig.Changed) {
        $backup = "$WslConfigPath.domovoy-backup"
        $absent = "$WslConfigPath.domovoy-absent"
        if ($wslConfig.Exists) {
            if (-not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $WslConfigPath -Destination $backup }
        }
        elseif (-not (Test-Path -LiteralPath $absent)) {
            $null = New-Item -ItemType File -Path $absent
        }
        [IO.File]::WriteAllText($WslConfigPath, $wslConfig.Content, (New-Object Text.UTF8Encoding($false)))
        Write-Output "${WslConfigPath}: networkingMode=mirrored записан; применится после wsl --shutdown (окно переезда, README)"
    }
    else {
        Write-Output "${WslConfigPath}: networkingMode=mirrored уже задан"
    }

    # 6. Правило firewall: пересоздаётся с теми же параметрами.
    if (Get-NetFirewallHyperVRule -Name $RuleName -ErrorAction SilentlyContinue) {
        Remove-NetFirewallHyperVRule -Name $RuleName
    }
    $null = New-NetFirewallHyperVRule @ruleParams
    Write-Output ('правило {0}: TCP {1}, с адресов {2}' -f $RuleName, ($ruleParams.LocalPorts -join ','), ($RemoteAddresses -join ','))

    # 7. Расписание бэкапа — последним шагом.
    $hostExe = (Get-Process -Id $PID).Path
    & $hostExe @scheduleArgs
    $scheduleCode = $LASTEXITCODE

    Write-Output @"

Дальше — окно переезда (README, «Автозапуск после перезагрузки»): остановить
стек на Docker Desktop, бэкап, wsl --shutdown, Start-ScheduledTask $KeeperTask,
восстановление внутри дистрибутива, -Check.
Предусловия: BIOS — включаться после пропадания питания; BitLocker без PIN.
"@
    if ($scheduleCode -ne 0) {
        Stop-WithError "расписание бэкапа не поставлено (ops/backup/install-schedule.ps1, код $scheduleCode) — остальное настроено"
    }
    exit 0
}

# ---------------------------------------------------------------- -Check
$results = New-Object System.Collections.Generic.List[object]
function Add-Result([string]$State, [string]$Link, [string]$Detail) {
    $results.Add([pscustomobject]@{ State = $State; Link = $Link; Detail = $Detail })
    $line = '{0,-4} {1}' -f $State, $Link
    if ($Detail) { $line += " — $Detail" }
    Write-Output $line
}

$registered = (Get-WslNames @('--list', '--quiet')) -contains $Distro
if ($registered) { Add-Result 'OK' 'дистрибутив зарегистрирован' $Distro }
else { Add-Result 'FAIL' 'дистрибутив зарегистрирован' "нет $Distro — engine-setup.ps1 -Install" }

$keeper = Get-ScheduledTask -TaskName $KeeperTask -ErrorAction SilentlyContinue
if (-not $keeper) {
    Add-Result 'FAIL' 'задача держалки' "нет задачи $KeeperTask"
}
else {
    $problems = New-Object System.Collections.Generic.List[string]
    if (-not (@($keeper.Triggers) | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskBootTrigger' })) { $problems.Add('нет триггера «при запуске системы»') }
    if ([string]$keeper.Principal.LogonType -ne 'S4U') { $problems.Add("LogonType $($keeper.Principal.LogonType), нужен S4U") }
    if ([string]$keeper.Settings.ExecutionTimeLimit -ne 'PT0S') { $problems.Add("ExecutionTimeLimit $($keeper.Settings.ExecutionTimeLimit), нужен PT0S") }
    if ($keeper.Settings.DisallowStartIfOnBatteries) { $problems.Add('не стартует на батарее') }
    if ($keeper.Settings.StopIfGoingOnBatteries) { $problems.Add('останавливается при переходе на батарею') }
    $keeperArgs = [string](@($keeper.Actions)[0].Arguments)
    if ($keeperArgs -notmatch ('(^|\s)-d\s+' + [regex]::Escape($Distro) + '(\s|$)')) { $problems.Add("действие не для $Distro") }
    if ($problems.Count) { Add-Result 'FAIL' 'задача держалки' ($problems -join '; ') }
    else { Add-Result 'OK' 'задача держалки' 'AtStartup, S4U, ExecutionTimeLimit 0, AllowStartIfOnBatteries, DontStopIfGoingOnBatteries' }
}

$measurePort = 0
$measure = Get-ScheduledTask -TaskName $MeasureTask -ErrorAction SilentlyContinue
if (-not $measure) {
    Add-Result 'FAIL' 'задача замера' "нет задачи $MeasureTask"
}
else {
    $m = [regex]::Match([string](@($measure.Actions)[0].Arguments), '-Port\s+(\d+)')
    if ($m.Success) { $measurePort = [int]$m.Groups[1].Value }
    if ($measurePort -ne $apiPort) { Add-Result 'FAIL' 'задача замера' "порт задачи $measurePort, API_HTTP_PORT $apiPort — переустановите: -Install" }
    else { Add-Result 'OK' 'задача замера' "порт $measurePort" }
}

$wslConfig = Get-WslConfigPlan $WslConfigPath
if (-not $wslConfig.Changed -and -not $wslConfig.Conflict) { Add-Result 'OK' '.wslconfig: networkingMode=mirrored' '' }
elseif ($wslConfig.Conflict) { Add-Result 'FAIL' '.wslconfig: networkingMode=mirrored' "задан $($wslConfig.Conflict)" }
else { Add-Result 'FAIL' '.wslconfig: networkingMode=mirrored' 'не задан' }

try {
    $rule = Get-NetFirewallHyperVRule -Name $RuleName -ErrorAction Stop
    $addresses = @($rule.RemoteAddresses | ForEach-Object { [string]$_ })
    $ports = @($rule.LocalPorts | ForEach-Object { [string]$_ })
    $problems = New-Object System.Collections.Generic.List[string]
    if ([string]$rule.Enabled -ne 'True') { $problems.Add('правило выключено') }
    if ($addresses -notcontains 'LocalSubnet') { $problems.Add('нет LocalSubnet') }
    $wider = @($addresses | Where-Object { $RemoteAddresses -notcontains $_ })
    if ($wider.Count) { $problems.Add('адреса шире локальной подсети и петли: ' + ($wider -join ',')) }
    foreach ($port in $apiPort, $haPort) {
        if ($ports -notcontains [string]$port) { $problems.Add("нет порта $port") }
    }
    if ($problems.Count) { Add-Result 'FAIL' 'правило firewall' ($problems -join '; ') }
    else { Add-Result 'OK' 'правило firewall' ('TCP {0} с {1}' -f ($ports -join ','), ($addresses -join ',')) }
}
catch {
    if (Get-Command Get-NetFirewallHyperVRule -ErrorAction SilentlyContinue) {
        if ($_.CategoryInfo.Category -eq 'ObjectNotFound') { Add-Result 'FAIL' 'правило firewall' "нет правила $RuleName" }
        else { Add-Result 'SKIP' 'правило firewall' "не проверено: $($_.Exception.Message) (нужен терминал администратора?)" }
    }
    else {
        Add-Result 'SKIP' 'правило firewall' 'не проверено: нет Get-NetFirewallHyperVRule (Windows 11 22H2+)'
    }
}

$desktop = @(Get-Process -Name 'Docker Desktop', 'com.docker.backend' -ErrorAction SilentlyContinue)
if ($desktop.Count) { Add-Result 'FAIL' 'Docker Desktop не запущен' 'процесс Docker Desktop работает — два движка делят порты' }
else { Add-Result 'OK' 'Docker Desktop не запущен' '' }

$running = (Get-WslNames @('--list', '--running', '--quiet')) -contains $Distro
$inner = @('docker.service в автозапуске', 'containerd.service в автозапуске', 'restart: unless-stopped у контейнеров проекта', 'порт замера = опубликованный порт api')
if (-not $running) {
    foreach ($link in $inner) { Add-Result 'SKIP' $link 'не проверено — дистрибутив не запущен' }
}
else {
    foreach ($unit in 'docker.service', 'containerd.service') {
        $isEnabled = (Invoke-Wsl @('-d', $Distro, '-u', 'root', '--exec', 'systemctl', 'is-enabled', $unit)).Text
        $isActive = (Invoke-Wsl @('-d', $Distro, '-u', 'root', '--exec', 'systemctl', 'is-active', $unit)).Text
        # OK — по is-enabled: «active» после ручного старта автозапуска не доказывает.
        if ($isEnabled -eq 'enabled') { Add-Result 'OK' "$unit в автозапуске" "is-enabled enabled; is-active $isActive" }
        else { Add-Result 'FAIL' "$unit в автозапуске" "is-enabled «$isEnabled»; is-active $isActive" }
    }
    $label = "label=com.docker.compose.project=$project"
    $listed = Invoke-Wsl @('-d', $Distro, '-u', 'root', '--exec', 'docker', 'ps', '-a', '--filter', $label, '--format', '{{.Names}}')
    $names = @($listed.Lines | Where-Object { $_ })
    if ($listed.Code -ne 0) {
        Add-Result 'FAIL' 'restart: unless-stopped у контейнеров проекта' "docker ps: код $($listed.Code): $($listed.Text)"
    }
    elseif (-not $names.Count) {
        Add-Result 'FAIL' 'restart: unless-stopped у контейнеров проекта' "контейнеров проекта $project нет"
    }
    else {
        $policies = (Invoke-Wsl (@('-d', $Distro, '-u', 'root', '--exec', 'docker', 'inspect', '-f', '{{.Name}} {{.HostConfig.RestartPolicy.Name}}') + $names)).Text -split "`r?`n" | Where-Object { $_ }
        $bad = @($policies | Where-Object { $_ -notmatch '\sunless-stopped$' })
        if ($bad.Count) { Add-Result 'FAIL' 'restart: unless-stopped у контейнеров проекта' ($bad -join '; ') }
        else { Add-Result 'OK' 'restart: unless-stopped у контейнеров проекта' ('{0} контейнеров' -f @($policies).Count) }
    }
    $apiPorts = (Invoke-Wsl @('-d', $Distro, '-u', 'root', '--exec', 'docker', 'ps', '--filter', $label, '--filter', 'label=com.docker.compose.service=api', '--format', '{{.Ports}}')).Text
    $published = [regex]::Match($apiPorts, ':(\d+)->\d+/tcp')
    if (-not $published.Success) { Add-Result 'FAIL' 'порт замера = опубликованный порт api' 'api не запущен или порт не опубликован' }
    elseif ([int]$published.Groups[1].Value -ne $measurePort) { Add-Result 'FAIL' 'порт замера = опубликованный порт api' "api опубликован на $($published.Groups[1].Value), задача замера — $measurePort" }
    else { Add-Result 'OK' 'порт замера = опубликованный порт api' "$measurePort" }
}

# /health с хоста: через петлю и через адрес хоста в ЛВС (сам адрес не
# печатается). Петля в mirrored при правиле только на LocalSubnet в опыте
# 2026-10-12 отвечала тайм-аутом; правило дополнено 127.0.0.1 и ::1.
$loop = Get-Health ('http://localhost:{0}/health' -f $apiPort)
if ($loop.Stack) { Add-Result 'OK' "/health на localhost:$apiPort" '200 формы стека' }
elseif ($loop.Code) { Add-Result 'FAIL' "/health на localhost:$apiPort" "код $($loop.Code)$(if ($loop.Code -eq 200) { ', тело не формы стека — чужой слушатель' })" }
else { Add-Result 'FAIL' "/health на localhost:$apiPort" "нет ответа: $($loop.Error)" }

$lanAddress = $null
try {
    $lanAddress = @(Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $_.IPv4DefaultGateway -and $_.IPv4Address } |
            ForEach-Object { @($_.IPv4Address)[0].IPAddress })[0]
}
catch { $lanAddress = $null }
if (-not $lanAddress) {
    Add-Result 'SKIP' "/health на адресе хоста в ЛВС, порт $apiPort" 'не проверено: нет интерфейса со шлюзом по умолчанию'
}
else {
    $lan = Get-Health ('http://{0}:{1}/health' -f $lanAddress, $apiPort)
    if ($lan.Stack) { Add-Result 'OK' "/health на адресе хоста в ЛВС, порт $apiPort" '200 формы стека' }
    elseif ($lan.Code) { Add-Result 'FAIL' "/health на адресе хоста в ЛВС, порт $apiPort" "код $($lan.Code)" }
    else { Add-Result 'FAIL' "/health на адресе хоста в ЛВС, порт $apiPort" "нет ответа: $($lan.Error)" }
}

# Расписание бэкапа (#8): S4U и состояние по install-schedule.ps1 -Check.
$backupTask = Get-ScheduledTask -TaskName $BackupTask -ErrorAction SilentlyContinue
if (-not $backupTask) {
    Add-Result 'FAIL' 'расписание бэкапа' "нет задачи $BackupTask"
}
else {
    $schedule = Invoke-Native (Get-Process -Id $PID).Path @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $scheduleScript, '-Check')
    $scheduleCode = $schedule.Code
    foreach ($line in $schedule.Lines) { Write-Output "     | $line" }
    if ([string]$backupTask.Principal.LogonType -ne 'S4U') { Add-Result 'FAIL' 'расписание бэкапа' "LogonType $($backupTask.Principal.LogonType), нужен S4U" }
    elseif ($scheduleCode -ne 0) { Add-Result 'FAIL' 'расписание бэкапа' "install-schedule.ps1 -Check: код $scheduleCode" }
    else { Add-Result 'OK' 'расписание бэкапа' 'S4U' }
}

$notOk = @($results | Where-Object { $_.State -ne 'OK' })
if ($notOk.Count) {
    Write-Output ('итог: не закрыто звеньев — {0}: {1}' -f $notOk.Count, (($notOk | ForEach-Object { $_.Link }) -join '; '))
    exit 1
}
Write-Output 'итог: все звенья OK'
exit 0
