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
  запускает ops/backup/backup.sh этого клона. Каталог и лимит в задачу не
  попадают: backup.sh читает BACKUP_DIR и BACKUP_MAX_SIZE_GB из .env клона
  при каждом запуске, и правка .env не требует переустановки. Секретов в
  аргументах задачи нет. Повторный -Install заменяет задачу.

  -LogonType S4U (по умолчанию, #6) — движок Docker живёт в WSL-дистрибутиве
  domovoy-engine (deploy/windows/engine-setup.ps1), задача идёт без входа
  пользователя и без хранимого пароля:

    wsl.exe -d domovoy-engine --cd "<клон>" -- bash ops/backup/backup.sh

  backup.sh выполняется внутри дистрибутива: docker там — сам движок, без
  обёртки и без интерактивной оболочки; клон виден как /mnt/<диск>/…,
  BACKUP_DIR вида D:/… переводит wslpath (ops/backup/dotenv.sh).

  -LogonType Interactive — откат на Docker Desktop, который работает только
  в сессии вошедшего пользователя: задача запускает bash.exe Git for Windows
  с одним аргументом — путём к backup.sh — и стартует, только пока
  пользователь вошёл; Docker Desktop не запущен — backup.sh отказывает с
  ненулевым кодом и строкой в backup.log.

  В обоих случаях — текущий пользователь, обычные права (RunLevel Limited).
  Тип входа с хранимым паролем сценарий не собирает. Пропущенный запуск (хост
  был выключен) выполняется при первой возможности — сразу после загрузки
  dockerd может ещё подниматься, тогда прогон отказывает строкой в
  backup.log, и следующий идёт в срок; прогон дольше 2 ч останавливается;
  второй экземпляр не запускается.

  bash.exe для Interactive — только из Git for Windows: InstallPath из
  HKLM:\SOFTWARE\GitForWindows, затем HKCU, затем рядом с git.exe из PATH.
  C:\Windows\System32\bash.exe — это WSL, с ним задача не ставится. Путь
  можно задать явно: -BashPath.

  -DryRun печатает собранную задачу и ничего не регистрирует; прав
  администратора не требует.
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Check,
    [switch]$Uninstall,
    [string]$At = '03:30',
    [ValidateSet('S4U', 'Interactive')]
    [string]$LogonType = 'S4U',
    [string]$BashPath,
    [switch]$DryRun
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

$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).ProviderPath
$envFile = Join-Path $root '.env'
$backupScript = Join-Path $root 'ops\backup\backup.sh'

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

function Test-WslBash([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    foreach ($dir in 'System32', 'Sysnative', 'SysWOW64') {
        if ($full -ieq (Join-Path $env:SystemRoot "$dir\bash.exe")) { return $true }
    }
    return $false
}

function Find-GitBash {
    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($hive in 'HKLM:\SOFTWARE\GitForWindows', 'HKCU:\SOFTWARE\GitForWindows') {
        $item = Get-ItemProperty -LiteralPath $hive -ErrorAction SilentlyContinue
        if ($item -and $item.PSObject.Properties['InstallPath'] -and $item.InstallPath) {
            $candidates.Add((Join-Path $item.InstallPath 'bin\bash.exe'))
        }
    }
    $git = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($git) {
        # git.exe лежит в cmd\, bin\ или mingw64\bin\ установки.
        $gitDir = Split-Path -Parent $git.Source
        $candidates.Add((Join-Path $gitDir '..\bin\bash.exe'))
        $candidates.Add((Join-Path $gitDir '..\..\bin\bash.exe'))
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $full = [IO.Path]::GetFullPath($candidate)
            if (-not (Test-WslBash $full)) { return $full }
        }
    }
    return $null
}

function Resolve-Bash {
    if ($BashPath) {
        if (Test-WslBash $BashPath) {
            Stop-WithError "$BashPath — это bash WSL, а не Git for Windows: бэкап в нём не работает с Docker Desktop хоста"
        }
        if (-not (Test-Path -LiteralPath $BashPath -PathType Leaf)) { Stop-WithError "bash.exe не найден: $BashPath" }
        return [IO.Path]::GetFullPath($BashPath)
    }
    $found = Find-GitBash
    if ($found) { return $found }
    $any = Get-Command bash.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($any -and (Test-WslBash $any.Source)) {
        Stop-WithError "найден только bash.exe WSL ($($any.Source)) — нужен Git for Windows; путь можно задать -BashPath"
    }
    Stop-WithError 'bash.exe Git for Windows не найден (реестр GitForWindows, git.exe в PATH) — путь можно задать -BashPath'
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
    # проверяется только по .env клона.
    $backupDir = Get-DotEnvValue $envFile 'BACKUP_DIR'
    if (-not $backupDir) {
        Stop-WithError "в $envFile не задан BACKUP_DIR — каталог бэкапов на внешнем носителе (см. .env.example, блок «Бэкап»)"
    }
    if (-not (Test-Path -LiteralPath $backupScript -PathType Leaf)) { Stop-WithError "нет $backupScript" }

    if ($LogonType -eq 'S4U') {
        # Внутри дистрибутива переводится только запись Windows (D:/… или
        # D:\…) и путь /mnt/…; запись Git Bash вида /d/… там не существует.
        if ($backupDir -notmatch '^[A-Za-z]:[\\/]' -and $backupDir -notmatch '^/mnt/') {
            Write-Warning "BACKUP_DIR ($backupDir) — не путь Windows вида D:/…: внутри дистрибутива $Distro такой каталог не найдётся, и бэкап будет отказывать"
        }
        # Без входа: backup.sh внутри дистрибутива движка, путь сценария —
        # от корня клона, который wsl.exe делает текущим каталогом.
        $execute = Join-Path $env:SystemRoot 'System32\wsl.exe'
        $argument = '-d {0} --cd "{1}" -- bash ops/backup/backup.sh' -f $Distro, $root
    }
    else {
        $execute = Resolve-Bash
        $argument = '"{0}"' -f $backupScript.Replace('\', '/')
    }
    $userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name

    # Объекты задачи — локальные, прав администратора не требуют. Сухой
    # прогон печатает их свойства, а не описание: что напечатано, то и
    # регистрируется.
    $action = New-ScheduledTaskAction -Execute $execute -Argument $argument -WorkingDirectory $root
    $trigger = New-ScheduledTaskTrigger -Daily -At $time
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType $LogonType -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
        -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    if ($DryRun) {
        $invariant = [Globalization.CultureInfo]::InvariantCulture
        # StartBoundary хранится в UTC; в выводе — местное время запуска.
        $start = [DateTimeOffset]::Parse($trigger.StartBoundary, $invariant).ToLocalTime()
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
    $backupDir = Get-DotEnvValue $envFile 'BACKUP_DIR'
    if (-not $backupDir) {
        Write-Output "backup.log: BACKUP_DIR в $envFile не задан"
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
