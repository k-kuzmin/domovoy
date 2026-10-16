#Requires -Version 5.1
<#
.SYNOPSIS
  Задача Планировщика Windows для ночного бэкапа Домового.

.DESCRIPTION
  Вызывается установщиком развёртывания (#6), отдельного шага у владельца
  нет; -Install требует терминала администратора:

    powershell -ExecutionPolicy Bypass -File ops/backup/install-schedule.ps1         # то же, что -Install
    powershell -ExecutionPolicy Bypass -File ops/backup/install-schedule.ps1 -Check  # состояние и хвост backup.log
    powershell -ExecutionPolicy Bypass -File ops/backup/install-schedule.ps1 -Uninstall

  -Install регистрирует задачу domovoy-backup: ежедневно в 03:30 (-At ЧЧ:ММ)
  запускает ops/backup/backup.sh каталога развёртывания -DeployDir (по
  умолчанию /srv/domovoy, #162). Каталог и лимит в задачу не попадают:
  backup.sh читает BACKUP_DIR и BACKUP_MAX_SIZE_GB из .env своего каталога
  при каждом запуске, и правка .env не требует переустановки. Секретов в
  аргументах задачи нет. Повторный -Install заменяет задачу.

  Движок Docker живёт в WSL-дистрибутиве domovoy-engine
  (deploy/windows/engine-setup.ps1, #6), задача идёт без входа пользователя
  и без хранимого пароля — тип входа S4U:

    wsl.exe -d domovoy-engine --cd "<DeployDir>" --exec bash ops/backup/backup.sh

  backup.sh выполняется внутри дистрибутива: docker там — сам движок, без
  обёртки и без интерактивной оболочки; BACKUP_DIR вида D:/… переводит
  wslpath (ops/backup/dotenv.sh).

  BACKUP_DIR для проверки при установке — из .env каталога развёртывания
  через deploy/envfile.sh get внутри дистрибутива: в -Install, если
  дистрибутив зарегистрирован; в -Install -DryRun и -Check — только если он
  уже работает. Иначе, а также если в каталоге нет .env или
  deploy/envfile.sh (хост до переноса стека), задача остаётся прежней —
  backup.sh клона, --cd "<клон>", BACKUP_DIR из .env клона, — и это
  печатается. Каталог есть, а get отказал — отказ.

  Принципал — текущий пользователь, обычные права (RunLevel Limited). Тип
  входа с хранимым паролем сценарий не собирает. Пропущенный запуск (хост
  был выключен) выполняется при первой возможности — сразу после загрузки
  dockerd может ещё подниматься, тогда прогон отказывает строкой в
  backup.log, и следующий идёт в срок; прогон дольше 2 ч останавливается;
  второй экземпляр не запускается.

  -DryRun печатает собранную задачу и ничего не регистрирует; прав
  администратора не требует. Подмены для теста — -AssumeEngineState,
  -AssumeDeploySettings, -WslExe — только с ним; engine-setup.ps1 -DryRun
  передаёт свои.
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Check,
    [switch]$Uninstall,
    [string]$At = '03:30',
    [switch]$DryRun,
    # Каталог развёртывания внутри дистрибутива (#162).
    [string]$DeployDir = '/srv/domovoy',
    # Только с -DryRun: подмена состояния дистрибутива (как у engine-setup.ps1).
    [ValidateSet('', 'Running', 'Stopped', 'Absent')]
    [string]$AssumeEngineState = '',
    # Только с -DryRun: 'KEY=значение;…' — настройки каталога развёртывания;
    # каталог при этом считается настроенным.
    [string]$AssumeDeploySettings = '',
    # Только с -DryRun: wsl.exe для теста.
    [string]$WslExe = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TaskName = 'domovoy-backup'
# Имя дистрибутива движка — то же, что в deploy/windows/engine-setup.ps1.
$Distro = 'domovoy-engine'

function Stop-WithError([string]$Message, [int]$Code = 1) {
    [Console]::Error.WriteLine("install-schedule: $Message")
    exit $Code
}

$modes = @($Install, $Check, $Uninstall | Where-Object { $_ })
if ($modes.Count -gt 1) { Stop-WithError 'укажите один режим: -Install, -Check или -Uninstall' 2 }
if ($modes.Count -eq 0) { $Install = [switch]$true }
foreach ($assumed in @(@('-AssumeEngineState', $AssumeEngineState), @('-AssumeDeploySettings', $AssumeDeploySettings), @('-WslExe', $WslExe))) {
    if ($assumed[1] -and -not $DryRun) { Stop-WithError "$($assumed[0]) — только с -DryRun" 2 }
}
if ($DeployDir -cnotmatch '^(/[A-Za-z0-9_][A-Za-z0-9._-]*)+$') {
    Stop-WithError "-DeployDir — абсолютный путь внутри дистрибутива (/srv/domovoy), без пробелов и кавычек: «$DeployDir»" 2
}
# Белый список deploy/envfile.sh get (GET_KEYS) — как в engine-setup.ps1.
$DeploySettingKeys = @('API_HTTP_PORT', 'HA_HTTP_PORT', 'COMPOSE_PROJECT_NAME', 'BACKUP_DIR', 'BACKUP_MAX_SIZE_GB', 'COMPOSE_FILE', 'DOMOVOY_IMAGE_REPO', 'DOMOVOY_IMAGE_TAG')
$assumedSettings = $null
if ($AssumeDeploySettings) {
    $assumedSettings = @{}
    foreach ($part in ($AssumeDeploySettings -split ';')) {
        $m = [regex]::Match($part, '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$')
        if (-not $m.Success -or $DeploySettingKeys -cnotcontains $m.Groups[1].Value) {
            Stop-WithError ("-AssumeDeploySettings — 'KEY=значение;KEY=значение', ключи: {0}" -f ($DeploySettingKeys -join ', ')) 2
        }
        $assumedSettings[$m.Groups[1].Value] = $m.Groups[2].Value
    }
}

$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).ProviderPath
$envFile = Join-Path $root '.env'
$backupScript = Join-Path $root 'ops\backup\backup.sh'
$systemWslExe = Join-Path $env:SystemRoot 'System32\wsl.exe'
# $WslExe и $wslExe — одна переменная (имена без учёта регистра): подделка
# запоминается до замены.
$wslFake = $WslExe
$wslExe = if ($wslFake) { $wslFake } else { $systemWslExe }

# wsl.exe с выводом в UTF-8 (WSL_UTF8): Lines — stdout, Err — stderr;
# stderr при 2>&1 приходит записями ошибок, и при ErrorActionPreference
# Stop первая прервала бы сценарий. Кодировка чтения канала — UTF-8 на
# время вызова (как Invoke-Native в deploy/windows/engine-setup.ps1).
function Invoke-Wsl([string[]]$Arguments) {
    $env:WSL_UTF8 = '1'
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = New-Object System.Collections.Generic.List[string]
    $err = New-Object System.Collections.Generic.List[string]
    $encoding = $null
    try { $encoding = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { $encoding = $null }
    try {
        & $wslExe @Arguments 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $err.Add([string]$_) } else { $out.Add([string]$_) }
        }
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
        if ($null -ne $encoding) { try { [Console]::OutputEncoding = $encoding } catch { } }
    }
    return [pscustomobject]@{ Code = $code; Lines = @($out); Err = ((@($err) | Where-Object { $_.Trim() }) -join '; ').Trim() }
}

function Test-DistroListed([string[]]$Arguments) {
    if (-not (Test-Path -LiteralPath $wslExe -PathType Leaf)) { return $false }
    $result = Invoke-Wsl $Arguments
    if ($result.Code -ne 0) { return $false }
    return [bool]@($result.Lines | ForEach-Object { $_.Trim([char]0, ' ') } | Where-Object { $_ -ieq $Distro }).Count
}

# Настройки каталога развёртывания: Source deploy, assumed или clone
# (каталог недоступен — задача прежняя), Reason — причина строкой ASCII,
# Error — каталог есть, а прочитать не удалось. Только ключ BACKUP_DIR.
function Read-DeploySettings {
    if ($null -ne $assumedSettings) { return [pscustomobject]@{ Source = 'assumed'; Reason = '-AssumeDeploySettings'; Error = ''; Values = $assumedSettings } }
    function Clone([string]$Reason) { return [pscustomobject]@{ Source = 'clone'; Reason = $Reason; Error = ''; Values = @{} } }
    $registered = Test-DistroListed @('--list', '--quiet')
    $running = Test-DistroListed @('--list', '--running', '--quiet')
    if ($AssumeEngineState) {
        $running = $AssumeEngineState -eq 'Running'
        if ($AssumeEngineState -eq 'Absent') { $registered = $false }
    }
    $read = if ($Install -and -not $DryRun) { $registered } else { $running }
    if (-not $registered -and -not $running) { return Clone 'distro not registered' }
    if (-not $read) { return Clone 'distro not running' }
    if ($AssumeEngineState -and -not $wslFake) { return Clone 'engine state assumed, distro not read' }
    $present = Invoke-Wsl @('-d', $Distro, '-u', 'root', '--exec', 'test', '-f', "$DeployDir/.env", '-a', '-f', "$DeployDir/deploy/envfile.sh")
    if ($present.Code -eq 1) { return Clone "deploy dir ${DeployDir}: no .env or deploy/envfile.sh" }
    if ($present.Code -ne 0) {
        return [pscustomobject]@{ Source = 'clone'; Reason = ''; Values = @{}; Error = "проверка каталога развёртывания $DeployDir внутри ${Distro}: wsl.exe код $($present.Code): $($present.Err)" }
    }
    $got = Invoke-Wsl @('-d', $Distro, '-u', 'root', '--cd', $DeployDir, '--exec', 'bash', 'deploy/envfile.sh', 'get', '.env', 'BACKUP_DIR')
    if ($got.Code -ne 0) {
        return [pscustomobject]@{ Source = 'clone'; Reason = ''; Values = @{}; Error = "deploy/envfile.sh get в $DeployDir внутри ${Distro}: код $($got.Code): $($got.Err)" }
    }
    $values = @{}
    foreach ($line in $got.Lines) {
        $m = [regex]::Match([string]$line, '^BACKUP_DIR=(.*)$')
        if ($m.Success) { $values['BACKUP_DIR'] = $m.Groups[1].Value.TrimEnd("`r") }
    }
    return [pscustomobject]@{ Source = 'deploy'; Reason = "$DeployDir/.env"; Error = ''; Values = $values }
}

# Значение ключа из .env без исполнения файла — как ops/backup/dotenv.sh:
# последняя строка KEY=…; значение в кавычках — текст между ними, после
# закрывающей допустим только комментарий « # …»; без кавычек хвостовой
# комментарий (пробел или таб перед #) и пробелы по краям снимаются, как
# в compose; плейсхолдер в угловых скобках — не задано.
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

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal $identity
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-Administrator {
    if (-not (Test-Administrator)) {
        Stop-WithError 'нужен терминал администратора. Запустите терминал «от имени администратора» и повторите.'
    }
}

if ($Install) {
    try {
        $time = [datetime]::ParseExact($At, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        Stop-WithError "-At — время ЧЧ:ММ, получено «$At»" 2
    }

    # Задача в 03:30 не видит окружения этого терминала: BACKUP_DIR
    # проверяется по .env того каталога, где пойдёт backup.sh.
    $deploySettings = Read-DeploySettings
    if ($deploySettings.Error) { Stop-WithError "настройки каталога развёртывания не прочитаны: $($deploySettings.Error)" }
    $execute = $systemWslExe
    if ($deploySettings.Source -eq 'clone') {
        # Каталога развёртывания нет: задача прежняя — backup.sh клона.
        $backupDir = Get-DotEnvValue $envFile 'BACKUP_DIR'
        if (-not $backupDir) {
            Stop-WithError "в $envFile не задан BACKUP_DIR — каталог бэкапов на внешнем носителе (см. .env.example, блок «Бэкап»)"
        }
        if (-not (Test-Path -LiteralPath $backupScript -PathType Leaf)) { Stop-WithError "нет $backupScript" }
        # Без входа: backup.sh внутри дистрибутива движка, путь сценария — от
        # корня клона, который wsl.exe делает текущим каталогом.
        $argument = '-d {0} --cd "{1}" --exec bash ops/backup/backup.sh' -f $Distro, $root
        $workingDirectory = $root
    }
    else {
        $backupDir = [string]$deploySettings.Values['BACKUP_DIR']
        if (-not $backupDir) {
            Stop-WithError "в $DeployDir/.env внутри $Distro не задан BACKUP_DIR — каталог бэкапов на внешнем носителе (см. .env.example, блок «Бэкап»)"
        }
        # backup.sh каталога развёртывания: клон на ночной бэкап не влияет.
        # Рабочий каталог Windows не задаётся — задача не зависит от клона.
        $argument = '-d {0} --cd "{1}" --exec bash ops/backup/backup.sh' -f $Distro, $DeployDir
        $workingDirectory = ''
    }

    # Внутри дистрибутива переводится только запись Windows (D:/… или D:\…)
    # и путь /mnt/…; запись Git Bash вида /d/… там не существует.
    if ($backupDir -notmatch '^[A-Za-z]:[\\/]' -and $backupDir -notmatch '^/mnt/') {
        Write-Warning "BACKUP_DIR ($backupDir) — не путь Windows вида D:/…: внутри дистрибутива $Distro такой каталог не найдётся, и бэкап будет отказывать"
    }
    $userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name

    # Объекты задачи — локальные, прав администратора не требуют. Сухой
    # прогон печатает их свойства, а не описание: что напечатано, то и
    # регистрируется.
    if ($workingDirectory) { $action = New-ScheduledTaskAction -Execute $execute -Argument $argument -WorkingDirectory $workingDirectory }
    else { $action = New-ScheduledTaskAction -Execute $execute -Argument $argument }
    $trigger = New-ScheduledTaskTrigger -Daily -At $time
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType S4U -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
        -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    if ($DryRun) {
        $invariant = [Globalization.CultureInfo]::InvariantCulture
        # StartBoundary хранится в UTC; в выводе — местное время запуска.
        $start = [DateTimeOffset]::Parse($trigger.StartBoundary, $invariant).ToLocalTime()
        # ASCII: вывод идёт в кодировке консоли.
        Write-Output "Settings: $($deploySettings.Source) ($($deploySettings.Reason))"
        Write-Output "Task: $TaskName"
        Write-Output ('Daily: {0}' -f $start.ToString('HH:mm', $invariant))
        Write-Output "DaysInterval: $($trigger.DaysInterval)"
        Write-Output "Execute: $($action.Execute)"
        Write-Output "Arguments: $($action.Arguments)"
        Write-Output "WorkingDirectory: $($action.WorkingDirectory)"
        Write-Output "UserId: $($principal.UserId)"
        Write-Output "LogonType: $($principal.LogonType)"
        Write-Output "RunLevel: $($principal.RunLevel)"
        Write-Output "StartWhenAvailable: $($settings.StartWhenAvailable)"
        Write-Output "ExecutionTimeLimit: $($settings.ExecutionTimeLimit)"
        Write-Output "MultipleInstances: $($settings.MultipleInstances)"
        Write-Output "DisallowStartIfOnBatteries: $($settings.DisallowStartIfOnBatteries)"
        Write-Output "StopIfGoingOnBatteries: $($settings.StopIfGoingOnBatteries)"
        Write-Output "BACKUP_DIR: $backupDir"
        Write-Output 'DryRun: not registered'
        exit 0
    }

    Assert-Administrator
    if ($deploySettings.Source -eq 'clone') {
        Write-Output "каталог развёртывания $DeployDir не используется ($($deploySettings.Reason)) — задача бэкапа прежняя, с --cd клона"
    }
    if (-not (Test-Path -LiteralPath $backupDir -PathType Container)) {
        Write-Warning "каталог BACKUP_DIR ($backupDir) сейчас недоступен — задача ставится, но бэкап будет отказывать, пока носитель не подключён"
    }

    $null = Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Description 'Домовой: ночной бэкап БД и тома Home Assistant (ops/backup/backup.sh)' -Force
    Write-Output ("задача {0} зарегистрирована: ежедневно {1}, {2}, {3} {4}" -f $TaskName,
        $time.ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture), $principal.LogonType, $execute, $argument)
    Write-Output 'проверка: powershell -ExecutionPolicy Bypass -File ops/backup/install-schedule.ps1 -Check'
    exit 0
}

if ($Check) {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) { Stop-WithError "задачи $TaskName нет — поставьте: powershell -ExecutionPolicy Bypass -File ops/backup/install-schedule.ps1" }
    $info = $task | Get-ScheduledTaskInfo
    $action = @($task.Actions)[0]
    Write-Output "Task: $TaskName"
    Write-Output "State: $($task.State)"
    Write-Output "LogonType: $($task.Principal.LogonType)"
    Write-Output "Execute: $($action.Execute) $($action.Arguments)"
    Write-Output "LastRunTime: $($info.LastRunTime)"
    Write-Output ('LastTaskResult: {0} (0x{0:X})' -f $info.LastTaskResult)
    Write-Output "NextRunTime: $($info.NextRunTime)"
    # BACKUP_DIR — по тому же правилу, что при установке: каталог
    # развёртывания работающего дистрибутива, иначе .env клона.
    $deploySettings = Read-DeploySettings
    if ($deploySettings.Error) { Stop-WithError "настройки каталога развёртывания не прочитаны: $($deploySettings.Error)" }
    if ($deploySettings.Source -eq 'clone') {
        $backupDir = Get-DotEnvValue $envFile 'BACKUP_DIR'
        $backupSource = $envFile
    }
    else {
        $backupDir = [string]$deploySettings.Values['BACKUP_DIR']
        $backupSource = "$DeployDir/.env"
    }
    Write-Output "Settings: $($deploySettings.Source) ($($deploySettings.Reason))"
    if ($action.Arguments -notmatch ('--cd "' + [regex]::Escape($DeployDir) + '"')) {
        Write-Output "DeployDir: задача не в $DeployDir — переустановите: engine-setup.ps1 -Install"
    }
    if (-not $backupDir) {
        Write-Output "backup.log: BACKUP_DIR в $backupSource не задан"
    }
    else {
        $log = Join-Path $backupDir 'backup.log'
        if (Test-Path -LiteralPath $log -PathType Leaf) {
            Write-Output "backup.log ($log), последние строки:"
            Get-Content -LiteralPath $log -Tail 10 -Encoding UTF8 | ForEach-Object { Write-Output "  $_" }
        }
        else {
            Write-Output "backup.log: $log недоступен — носитель не подключён или бэкапов ещё не было"
        }
    }
    exit 0
}

if ($Uninstall) {
    Assert-Administrator
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Output "задача $TaskName удалена"
    }
    else {
        Write-Output "задачи $TaskName нет"
    }
    exit 0
}
