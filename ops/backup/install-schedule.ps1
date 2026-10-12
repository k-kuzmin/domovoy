#Requires -Version 5.1
<#
.SYNOPSIS
  Задача Планировщика Windows для ночного бэкапа Домового.

.DESCRIPTION
  Ставится один раз при развёртывании, из терминала администратора:

    pwsh -File ops/backup/install-schedule.ps1            # то же, что -Install
    pwsh -File ops/backup/install-schedule.ps1 -Check     # состояние и хвост backup.log
    pwsh -File ops/backup/install-schedule.ps1 -Uninstall

  -Install регистрирует задачу domovoy-backup: ежедневно в 03:30 (-At ЧЧ:ММ)
  запускает bash.exe Git for Windows с одним аргументом — путём к
  ops/backup/backup.sh этого клона. Каталог и лимит в задачу не попадают:
  backup.sh читает BACKUP_DIR и BACKUP_MAX_SIZE_GB из .env клона при каждом
  запуске, и правка .env не требует переустановки. Секретов в аргументах
  задачи нет. Повторный -Install заменяет задачу.

  Задача идёт от текущего пользователя с LogonType S4U — без входа в
  систему и без хранения пароля, с обычными правами (RunLevel Limited).
  Регистрация S4U требует терминала администратора. Пропущенный запуск
  (хост был выключен) выполняется при первой возможности; прогон дольше
  2 ч останавливается; второй экземпляр не запускается.

  bash.exe — только из Git for Windows: InstallPath из
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
    [string]$BashPath,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TaskName = 'domovoy-backup'

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
# последняя строка KEY=…, обрамляющие кавычки снимаются, плейсхолдер в
# угловых скобках — не задано.
function Get-DotEnvValue([string]$Path, [string]$Key) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $value = ''
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line.StartsWith("$Key=", [StringComparison]::Ordinal)) {
            $value = $line.Substring($Key.Length + 1)
        }
    }
    $value = $value.TrimEnd("`r")
    if ($value.Length -ge 2) {
        $first = $value[0]
        $last = $value[$value.Length - 1]
        if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
            $value = $value.Substring(1, $value.Length - 2)
        }
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
        Stop-WithError 'нужен терминал администратора: задача S4U (без входа в систему) регистрируется только с правами администратора. Запустите терминал «от имени администратора» и повторите.'
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

    $bash = Resolve-Bash
    $argument = '"{0}"' -f $backupScript.Replace('\', '/')
    $userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name

    if ($DryRun) {
        Write-Output "Task: $TaskName"
        Write-Output ('Daily: {0}' -f $time.ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture))
        Write-Output "Execute: $bash"
        Write-Output "Arguments: $argument"
        Write-Output "WorkingDirectory: $root"
        Write-Output "UserId: $userId"
        Write-Output 'LogonType: S4U'
        Write-Output 'RunLevel: Limited'
        Write-Output 'Settings: StartWhenAvailable, ExecutionTimeLimit 02:00:00, MultipleInstances IgnoreNew, AllowStartIfOnBatteries, DontStopIfGoingOnBatteries'
        Write-Output "BACKUP_DIR: $backupDir"
        Write-Output 'DryRun: not registered'
        exit 0
    }

    Assert-Administrator
    if (-not (Test-Path -LiteralPath $backupDir -PathType Container)) {
        Write-Warning "каталог BACKUP_DIR ($backupDir) сейчас недоступен — задача ставится, но бэкап будет отказывать, пока носитель не подключён"
    }

    $action = New-ScheduledTaskAction -Execute $bash -Argument $argument -WorkingDirectory $root
    $trigger = New-ScheduledTaskTrigger -Daily -At $time
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType S4U -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
        -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $null = Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
        -Settings $settings -Description 'Домовой: ночной бэкап БД и тома Home Assistant (ops/backup/backup.sh)' -Force
    Write-Output ("задача {0} зарегистрирована: ежедневно {1}, {2} {3}" -f $TaskName,
        $time.ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture), $bash, $argument)
    Write-Output 'проверка: pwsh -File ops/backup/install-schedule.ps1 -Check'
    exit 0
}

if ($Check) {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) { Stop-WithError "задачи $TaskName нет — поставьте: pwsh -File ops/backup/install-schedule.ps1" }
    $info = $task | Get-ScheduledTaskInfo
    $action = @($task.Actions)[0]
    Write-Output "Task: $TaskName"
    Write-Output "State: $($task.State)"
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
