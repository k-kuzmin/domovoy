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
    powershell -ExecutionPolicy Bypass -File deploy/windows/engine-setup.ps1 -Uninstall        # откат, терминал администратора
    powershell -ExecutionPolicy Bypass -File deploy/windows/engine-setup.ps1 -Uninstall -DryRun
    powershell -ExecutionPolicy Bypass -File deploy/windows/engine-setup.ps1 -Install -Migrate  # установка и переезд, администратор
    powershell -ExecutionPolicy Bypass -File deploy/windows/engine-setup.ps1 -Migrate -DryRun

  -Install (повторный запуск ничего не дублирует; дистрибутив при нём
  кратко перезапускается — wsl --terminate в шаге 2, — и если держалка или
  дистрибутив работали до запуска, держалка сразу после регистрации задач
  запускается снова: стек не лежит до перезагрузки):
    1. дистрибутив domovoy-engine: wsl --import официального образа Ubuntu
       24.04 для WSL (cloud-images.ubuntu.com), SHA256 сверяется с SHA256SUMS
       того же каталога — это проверка целостности загрузки, не подлинности:
       подпись SHA256SUMS не проверяется, и подменённый на сервере образ
       вместе с его суммой проверку пройдёт; уже зарегистрированный не
       трогается;
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
    4. задача domovoy-measure-boot: при запуске системы, тем же принципалом,
       что держалка (пользователь, S4U, обычные права): она исполняет файл
       из клона, а клон пользователь может менять — под SYSTEM это было бы
       повышением прав. deploy/windows/measure-boot.ps1 -Port <порт API>
       -LogPath %LOCALAPPDATA%\domovoy-engine\measure-boot.log;
    5. %USERPROFILE%\.wslconfig: [wsl2] networkingMode=mirrored — порты
       дистрибутива видны на адресе хоста. Прежний файл сохраняется копией
       .wslconfig.domovoy-backup, отсутствие — отметкой .wslconfig.domovoy-absent.
       Другое значение networkingMode — отказ: чужая настройка не переписывается.
       Применяется после wsl --shutdown — его -Install не выполняет (гасит
       все дистрибутивы, в том числе Docker Desktop), выполняет -Migrate;
    6. правило Hyper-V firewall domovoy-engine-ports: входящие TCP на порты
       API и Home Assistant, только с локальной подсети и с адресов петли
       хоста (127.0.0.1, ::1);
    7. последним шагом — расписание бэкапа:
       ops/backup/install-schedule.ps1 -Install -LogonType S4U.

  Порты: API_HTTP_PORT и HA_HTTP_PORT из .env клона, без них — значения по
  умолчанию из docker-compose.yml. Проект compose — COMPOSE_PROJECT_NAME так
  же. Чисел портов в сценарии нет.

  -Migrate — переезд стека с Docker Desktop в движок одной командой
  (терминал администратора). Вместе с -Install сначала полностью
  отрабатывает установка, затем переезд; один -Migrate требует
  установленного движка (дистрибутив, задача держалки, mirrored в
  .wslconfig), иначе отказ с подсказкой.
    0. предусловия — до любых действий, отказ без изменений: Git Bash
       (bash.exe Git for Windows, не bash WSL из System32); BACKUP_DIR —
       путь Windows, каталог есть и лежит вне клона; имя проекта годится
       для restore.sh; Docker Desktop отвечает, у docker.exe есть команда
       desktop (docker desktop version — ею шаг 4 останавливает Desktop), у
       Desktop есть контейнеры проекта и работают postgres и
       homeassistant; в движке нет ни
       контейнеров, ни томов проекта — повторный перенос данные не
       затирает. Для последней пробы дистрибутив запускается; если он не
       работал, при отказе гасится только он;
    1. Docker Desktop (docker.exe хоста, в каталоге клона): docker compose
       stop api;
    2. ops/backup/backup.sh <BACKUP_DIR> через Git Bash; переносится ровно
       тот бэкап, что появился в BACKUP_DIR этим шагом;
    3. docker compose --profile ha stop — stop: тома Desktop остаются
       путём отката;
    4. docker desktop stop и ожидание ухода процессов Desktop (предел
       времени, процессы не убиваются);
    5. автозапуск Desktop при входе выключается: %APPDATA%\Docker\
       settings-store.json, ключ AutoStart (старые версии — settings.json,
       autoStart); прежний файл — копией .domovoy-backup. Файла нет — WARN.
       Запускает Desktop при входе значение «Docker Desktop» в
       HKCU\...\CurrentVersion\Run: если оно есть, значение того же имени
       в Explorer\StartupApproved\Run получает 03 00 00 00 + время
       (выключено, как в Диспетчере задач); прежнее значение — копией
       StartupApproved-Run.domovoy-backup (hex) или отметкой
       StartupApproved-Run.domovoy-absent рядом с настройками Desktop.
       Записи Run нет или она уже выключена — не трогается;
    6. держалка, если работает, — Stop-ScheduledTask, затем wsl --shutdown —
       гасит ВСЕ дистрибутивы WSL, применяет mirrored. Задача держалки
       с MultipleInstances IgnoreNew: «зависший» Running молча проглотил
       бы запуск в шаге 7;
    7. Start-ScheduledTask domovoy-engine, ожидание State Running задачи
       (иначе отказ), затем docker в дистрибутиве (предел времени);
    8. внутри дистрибутива, в клоне: ops/backup/restore.sh --project
       <COMPOSE_PROJECT_NAME> --from <бэкап шага 2>; стек поднимает сам
       restore.sh;
    9. -Check — его код выхода и есть код -Migrate.
  Отказ после шага 1 ничего не откатывает сам: печатается, что тома Docker
  Desktop целы, и команды отката — до ухода процессов Desktop в шаге 4
  включительно: docker desktop start и docker compose --profile ha start;
  после — -Uninstall, wsl --shutdown, docker desktop start и тот же start. -Migrate -DryRun печатает план и отказывает
  по тем же предусловиям, что проверяются без docker.exe и WSL.

  -Check только читает: ничего не запускает и не останавливает, внутрь
  дистрибутива заходит, только если он уже работает. Каждое звено — строка
  OK / FAIL / SKIP; код 0 — только если все OK. SKIP — «не проверено»
  (дистрибутив не запущен, нет прав прочитать правило), код тоже ненулевой.
  Звено «автозапуск Docker Desktop при входе выключен» — FAIL, если
  запись Run «Docker Desktop» есть и не выключена через StartupApproved
  или в настройках Desktop AutoStart true.
  Исключение — звено «/health из ЛВС»: в mirrored хост не достаёт до
  дистрибутива по своему адресу в ЛВС, поэтому оно всегда SKIP, в итог и
  код не входит, а проверяется с устройства в домашней сети.

  -Uninstall — откат на Docker Desktop (терминал администратора):
    1. если дистрибутив работает — docker compose --profile ha stop внутри
       него, в клоне; отказ — выход до любых удалений. Не работает — стек
       не трогается (дистрибутив ради этого не запускается);
    2. задачи domovoy-engine и domovoy-measure-boot снимаются, работающая
       держалка перед этим останавливается;
    3. расписание бэкапа — ops/backup/install-schedule.ps1 -Install
       -LogonType Interactive; не встало — задача снимается, чтобы ночью не
       будить движок WSL, и код ненулевой;
    4. wsl --terminate domovoy-engine;
    5. правило firewall domovoy-engine-ports удаляется;
    6. .wslconfig возвращается из .wslconfig.domovoy-backup или, при отметке
       .wslconfig.domovoy-absent, удаляется; копия и отметка расходуются;
    7. автозапуск Docker Desktop: если -Migrate оставил копию настроек
       .domovoy-backup, ключ AutoStart (autoStart) получает прежнее значение
       из неё — остальные настройки Desktop не трогаются; копия расходуется.
       Значение StartupApproved\Run «Docker Desktop» возвращается из копии
       StartupApproved-Run.domovoy-backup или, по отметке
       StartupApproved-Run.domovoy-absent, убирается; копия и отметка
       расходуются.
  Дистрибутив не удаляется: в нём тома стека. wsl --unregister domovoy-engine
  уничтожает их — только руками владельца. wsl --shutdown, без которого
  возврат .wslconfig не применится, -Uninstall не выполняет.

  Предусловия, которые сценарий не проверяет: в BIOS «восстановление после
  пропадания питания — включиться»; BitLocker без PIN до загрузки.
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Check,
    [switch]$Uninstall,
    [switch]$Migrate,
    [switch]$DryRun,
    [string]$WslConfigPath = (Join-Path $env:USERPROFILE '.wslconfig'),
    [string]$DistroDir = (Join-Path $env:LOCALAPPDATA 'domovoy-engine'),
    # Каталог настроек Docker Desktop (автозапуск при входе); тест подменяет его.
    [string]$DockerSettingsDir = (Join-Path $env:APPDATA 'Docker'),
    # Ветка реестра автозапуска при входе: под ней Run и
    # Explorer\StartupApproved\Run. Тест подменяет её своей веткой.
    [string]$StartupRegistryRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion',
    # Только с -DryRun: подмена состояния держалки и дистрибутива для теста
    # (deploy/windows/engine-setup.test.sh). Без него состояние читается с хоста.
    # Absent — дистрибутив не зарегистрирован (движок не установлен).
    [ValidateSet('', 'Running', 'Stopped', 'Absent')]
    [string]$AssumeEngineState = ''
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

$modeCount = @($Install, $Check, $Uninstall, $Migrate | Where-Object { $_ }).Count
# Вместе допустимы только -Install -Migrate: сначала установка, затем переезд.
$installThenMigrate = $modeCount -eq 2 -and $Install -and $Migrate
if ($modeCount -gt 1 -and -not $installThenMigrate) { Stop-WithError 'укажите один режим: -Install, -Check, -Uninstall или -Migrate (вместе — только -Install -Migrate)' 2 }
if ($modeCount -eq 0) { Stop-WithError 'укажите режим: -Install, -Check, -Uninstall или -Migrate' 2 }
if ($DryRun -and $Check) { Stop-WithError '-DryRun — только с -Install, -Uninstall или -Migrate' 2 }
if ($AssumeEngineState -and -not $DryRun) { Stop-WithError '-AssumeEngineState — только с -DryRun' 2 }

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

# Внешняя программа: Lines и Text — только stdout, по ним идут сравнения;
# stderr — отдельно, ErrLines и Err, для деталей в выводе. Предупреждения
# wsl.exe в stderr иначе попадали бы в «enabled» и в список контейнеров.
# stderr при 2>&1 приходит записями ошибок — по ним потоки и делятся; при
# ErrorActionPreference Stop первая такая запись прервала бы сценарий.
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = New-Object System.Collections.Generic.List[string]
    $err = New-Object System.Collections.Generic.List[string]
    try {
        & $Exe @Arguments 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $err.Add([string]$_) } else { $out.Add([string]$_) }
        }
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    $lines = @($out)
    $errLines = @($err | Where-Object { $_.Trim() })
    return [pscustomobject]@{ Code = $code; Lines = $lines; Text = ($lines -join "`n").Trim(); ErrLines = $errLines; Err = ($errLines -join '; ').Trim() }
}

# Текст для деталей: stdout, затем stderr с пометкой.
function Format-Native($Result) {
    $parts = @()
    if ($Result.Text) { $parts += $Result.Text }
    if ($Result.Err) { $parts += "stderr: $($Result.Err)" }
    return ($parts -join '; ')
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
    # Вставка — перед переводом строки после [wsl2] и тем же переводом, что
    # в файле. \s в заголовке захватил бы CR: в .NET $ при (?m) стоит
    # только перед LF.
    $wsl2 = '(?im)^([ \t]*\[wsl2\][ \t]*)(?=\r?$)'
    # Файл без CRLF остаётся с LF; новый или с CRLF — CRLF.
    $newline = if ($current -and -not $current.Contains("`r`n") -and $current.Contains("`n")) { "`n" } else { "`r`n" }
    if ($current -match $wsl2) {
        # Экземпляр, а не [regex]::Replace: у статического четвёртый аргумент —
        # RegexOptions, а не число замен.
        $content = ([regex]$wsl2).Replace($current, "`$1${newline}networkingMode=mirrored", 1)
    }
    elseif ($current.Trim()) {
        $content = $current.TrimEnd() + "$newline$newline[wsl2]${newline}networkingMode=mirrored$newline"
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
        # Тип, а не текст: текст сокетной ошибки несёт адрес:порт, а адрес
        # хоста в ЛВС в вывод -Check не попадает.
        return [pscustomobject]@{ Code = 0; Stack = $false; Error = $inner.GetType().Name }
    }
    finally {
        $client.Dispose()
    }
}

# Длинный шаг (compose, backup.sh, restore.sh): вывод идёт сразу, по мере
# появления, stdout — в stdout, stderr — в stderr, как разделяет
# Invoke-Native. Код — в $script:passCode: возвращаемое значение функции —
# это её вывод.
function Invoke-Passthru([string]$Exe, [string[]]$Arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Exe @Arguments 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { [Console]::Error.WriteLine([string]$_) } else { Write-Output ([string]$_) }
        }
        $script:passCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

# bash.exe Git for Windows — та же логика, что Find-GitBash и Test-WslBash
# в ops/backup/install-schedule.ps1. bash.exe из System32 — это WSL: с ним
# backup.sh не видит Docker Desktop хоста.
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

# Автозапуск Docker Desktop при входе. Docker Desktop 4.x хранит его в
# %APPDATA%\Docker\settings-store.json ключом AutoStart, старые версии — в
# settings.json ключом autoStart. Значение меняется заменой в тексте:
# остальные байты файла не трогаются (ConvertTo-Json в 5.1 переформатировал
# бы весь файл).
$desktopSettingsFiles = @(
    @{ Leaf = 'settings-store.json'; Key = 'AutoStart' },
    @{ Leaf = 'settings.json'; Key = 'autoStart' })

# 'true', 'false' или '' — ключа нет.
function Get-JsonBool([string]$Text, [string]$Key) {
    $m = [regex]::Match($Text, '"' + [regex]::Escape($Key) + '"\s*:\s*(true|false)')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

# Value '' — ключ убирается; $null — в тексте нет объекта JSON.
function Set-JsonBool([string]$Text, [string]$Key, [string]$Value) {
    $pair = '"' + [regex]::Escape($Key) + '"\s*:\s*(?:true|false)'
    if ($Value) {
        if ([regex]::IsMatch($Text, $pair)) { return ([regex]$pair).Replace($Text, ('"{0}": {1}' -f $Key, $Value), 1) }
        $open = $Text.IndexOf('{')
        if ($open -lt 0) { return $null }
        $rest = $Text.Substring($open + 1)
        $separator = if ($rest.Trim().StartsWith('}')) { '' } else { ',' }
        return $Text.Substring(0, $open + 1) + ('"{0}": {1}{2}' -f $Key, $Value, $separator) + $rest
    }
    foreach ($pattern in @(($pair + '\s*,\s*'), (',\s*' + $pair), $pair)) {
        if ([regex]::IsMatch($Text, $pattern)) { return ([regex]$pattern).Replace($Text, '', 1) }
    }
    return $Text
}

# Первый существующий файл настроек Desktop; нет ни одного — $null.
function Get-DesktopSettings {
    foreach ($file in $desktopSettingsFiles) {
        $path = Join-Path $DockerSettingsDir $file.Leaf
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $text = [IO.File]::ReadAllText($path)
            return [pscustomobject]@{ Path = $path; Leaf = $file.Leaf; Key = $file.Key; Text = $text; Value = (Get-JsonBool $text $file.Key); Backup = "$path.domovoy-backup" }
        }
    }
    return $null
}

# Копия настроек, оставленная -Migrate; нет — $null.
function Get-DesktopSettingsBackup {
    foreach ($file in $desktopSettingsFiles) {
        $path = Join-Path $DockerSettingsDir $file.Leaf
        if (Test-Path -LiteralPath "$path.domovoy-backup" -PathType Leaf) {
            $text = [IO.File]::ReadAllText("$path.domovoy-backup")
            return [pscustomobject]@{ Path = $path; Leaf = $file.Leaf; Key = $file.Key; Backup = "$path.domovoy-backup"; Value = (Get-JsonBool $text $file.Key) }
        }
    }
    return $null
}

# Автозапуск Docker Desktop при входе запускает не settings-store.json, а
# значение «Docker Desktop» в ветке Run; выключенным его делает значение
# того же имени в Explorer\StartupApproved\Run (так выключает Диспетчер
# задач, «Автозагрузка»). Первый байт значения: 02 и 06 — включено, 03 —
# выключено; значения нет — включено. Прежнее значение -Migrate сохраняет
# копией (hex) или отметкой «не было» рядом с копией настроек Desktop.
$DesktopRunName = 'Docker Desktop'
$desktopRunKey = Join-Path $StartupRegistryRoot 'Run'
$desktopApprovedKey = Join-Path $StartupRegistryRoot 'Explorer\StartupApproved\Run'
$desktopApprovedBackup = Join-Path $DockerSettingsDir 'StartupApproved-Run.domovoy-backup'
$desktopApprovedAbsent = Join-Path $DockerSettingsDir 'StartupApproved-Run.domovoy-absent'

# State: none — записи Run нет; enabled; disabled; unknown — первый байт не
# из известных. Hex — значение StartupApproved или '' (его нет).
function Get-DesktopStartup {
    $runItem = Get-ItemProperty -LiteralPath $desktopRunKey -Name $DesktopRunName -ErrorAction SilentlyContinue
    $approvedItem = Get-ItemProperty -LiteralPath $desktopApprovedKey -Name $DesktopRunName -ErrorAction SilentlyContinue
    $bytes = $null
    if ($approvedItem) { $bytes = [byte[]]@($approvedItem.$DesktopRunName) }
    $hex = if ($bytes -and $bytes.Count) { [BitConverter]::ToString($bytes) } else { '' }
    if (-not $runItem) { $state = 'none' }
    elseif (-not $hex) { $state = 'enabled' }
    elseif ($bytes[0] -eq 3) { $state = 'disabled' }
    elseif ($bytes[0] -eq 2 -or $bytes[0] -eq 6) { $state = 'enabled' }
    else { $state = 'unknown' }
    return [pscustomobject]@{ State = $state; Hex = $hex }
}

# Выключенное значение: 03 00 00 00 и время выключения (FILETIME), как
# пишет Диспетчер задач.
function Get-DisabledStartupBytes {
    return [byte[]](@([byte]3, [byte]0, [byte]0, [byte]0) + [BitConverter]::GetBytes([DateTime]::UtcNow.ToFileTimeUtc()))
}

# Значение StartupApproved записывается; ветки нет — создаётся. New-Item
# -Force по существующей ветке реестра стёр бы её значения — только при
# её отсутствии.
function Set-DesktopApproved([byte[]]$Bytes) {
    if (-not (Test-Path -LiteralPath $desktopApprovedKey)) { $null = New-Item -Path $desktopApprovedKey -Force }
    $null = New-ItemProperty -LiteralPath $desktopApprovedKey -Name $DesktopRunName -PropertyType Binary -Value $Bytes -Force
}

$apiPort = Get-Port 'API_HTTP_PORT'
$haPort = Get-Port 'HA_HTTP_PORT'
$project = Get-Setting 'COMPOSE_PROJECT_NAME'
$userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name

# ---------------------------------------------------------------- -Migrate
# Пределы ожидания: docker в дистрибутиве после старта и уход процессов
# Docker Desktop после docker desktop stop.
$EngineWaitSeconds = 180
$DesktopWaitSeconds = 120
# Предел ожидания состояния Running у задачи держалки после запуска.
$KeeperWaitSeconds = 30
# Аргументы шагов на Docker Desktop — одни на план сухого прогона и на
# действие: что напечатано, то и выполняется.
$desktopStopApiArgs = @('compose', 'stop', 'api')
$desktopStopStackArgs = @('compose', '--profile', 'ha', 'stop')
$desktopQuitArgs = @('desktop', 'stop')
# Проба до шага 1: есть ли у docker.exe команда desktop, которой шаг 4
# останавливает Desktop (её нет у старых версий).
$desktopCliProbeArgs = @('desktop', 'version')
$backupScriptPath = 'ops/backup/backup.sh'

# docker в дистрибутиве: опрос docker info до ответа или предела времени.
# Обращение через wsl.exe -d запускает дистрибутив, если он не работал.
function Wait-EngineDocker {
    $deadline = (Get-Date).AddSeconds($EngineWaitSeconds)
    while ($true) {
        $info = Invoke-Wsl @('-d', $Distro, '-u', 'root', '--exec', 'docker', 'info', '--format', '{{.ServerVersion}}')
        if (($info.Code -eq 0 -and $info.Text) -or (Get-Date) -ge $deadline) { return $info }
        Start-Sleep -Seconds 3
    }
}

# Держалка запускается заново; $true — задача дошла до State Running за
# предел времени. Задача зарегистрирована с MultipleInstances IgnoreNew:
# пока прежний экземпляр числится Running (wsl --shutdown и
# wsl --terminate убивают его wsl.exe, а состояние задачи может отстать),
# Start-ScheduledTask молча ничего не делает. Поэтому прежний экземпляр
# сначала останавливается, а после запуска ожидается Running: иначе
# дистрибутив, поднятый чужим wsl.exe, погас бы по простою незаметно.
function Start-Keeper {
    if ([string](Get-ScheduledTask -TaskName $KeeperTask -ErrorAction Stop).State -eq 'Running') {
        Stop-ScheduledTask -TaskName $KeeperTask
    }
    Start-ScheduledTask -TaskName $KeeperTask
    $deadline = (Get-Date).AddSeconds($KeeperWaitSeconds)
    while ([string](Get-ScheduledTask -TaskName $KeeperTask -ErrorAction Stop).State -ne 'Running') {
        if ((Get-Date) -ge $deadline) { return $false }
        Start-Sleep -Seconds 1
    }
    return $true
}

# $true — процессов Docker Desktop нет (те же имена, что в -Check); не
# убиваются, только ожидаются.
function Wait-DesktopGone {
    $deadline = (Get-Date).AddSeconds($DesktopWaitSeconds)
    while (@(Get-Process -Name 'Docker Desktop', 'com.docker.backend' -ErrorAction SilentlyContinue).Count) {
        if ((Get-Date) -ge $deadline) { return $false }
        Start-Sleep -Seconds 2
    }
    return $true
}

# Полные бэкапы в BACKUP_DIR — имя ровно как у ротации backup.sh и выбора
# в restore.sh; .partial не засчитывается. Нечитаемый каталог — исключение.
function Get-BackupNames([string]$Dir) {
    return @(Get-ChildItem -LiteralPath $Dir -Directory -ErrorAction Stop |
            Where-Object { $_.Name -cmatch '^domovoy-backup-\d{8}T\d{6}Z$' } | ForEach-Object { $_.Name })
}

# restore.sh --project внутри движка, в клоне. --from обязателен: без него
# restore.sh выбирает последний бэкап только в режиме --check. Путь — запись
# Windows с прямыми слэшами: внутри дистрибутива его переводит wslpath.
function Get-RestoreArgs([string]$From) {
    return @('-d', $Distro, '-u', 'root', '--cd', $root, '--exec', 'bash', 'ops/backup/restore.sh', '--project', $project, '--from', $From)
}

# Предусловия, которые проверяются без обращения к Docker Desktop и движку:
# установлен ли движок (с -Install — ставится им же), Git Bash, BACKUP_DIR,
# имя проекта. Сухой прогон отказывает по ним так же, как настоящий.
function Get-MigrateSetup {
    $problems = New-Object System.Collections.Generic.List[string]
    if (-not $Install) {
        $missing = New-Object System.Collections.Generic.List[string]
        if ($AssumeEngineState) {
            if ($AssumeEngineState -eq 'Absent') { $missing.Add("нет дистрибутива $Distro (-AssumeEngineState Absent)") }
        }
        else {
            if ((Get-WslNames @('--list', '--quiet')) -notcontains $Distro) { $missing.Add("нет дистрибутива $Distro") }
            if (-not (Get-ScheduledTask -TaskName $KeeperTask -ErrorAction SilentlyContinue)) { $missing.Add("нет задачи $KeeperTask") }
            $wslPlan = Get-WslConfigPlan $WslConfigPath
            if ($wslPlan.Changed -or $wslPlan.Conflict) { $missing.Add('в .wslconfig нет networkingMode=mirrored') }
        }
        if ($missing.Count) {
            $problems.Add("движок не установлен ($($missing -join '; ')) — сначала engine-setup.ps1 -Install, или одной командой: engine-setup.ps1 -Install -Migrate")
        }
    }
    $gitBash = Find-GitBash
    if (-not $gitBash) {
        $problems.Add('bash.exe Git for Windows не найден (реестр GitForWindows, git.exe в PATH) — бэкап на Docker Desktop идёт через него; bash.exe из System32 — это WSL и не подходит')
    }
    if ($project -cnotmatch '^[a-z0-9][a-z0-9_-]*$') {
        $problems.Add('COMPOSE_PROJECT_NAME — строчные буквы, цифры, - и _ (так требует restore.sh)')
    }
    $backupDir = ''
    $backupSetting = Get-Setting 'BACKUP_DIR'
    if (-not $backupSetting) {
        $problems.Add('BACKUP_DIR не задан в .env клона — каталог бэкапов на внешнем носителе (.env.example, блок «Бэкап»)')
    }
    elseif ($backupSetting -notmatch '^[A-Za-z]:[\\/]') {
        $problems.Add("BACKUP_DIR — не путь Windows вида D:/…: внутри $Distro restore.sh такой каталог не найдёт")
    }
    else {
        $backupDir = [IO.Path]::GetFullPath($backupSetting)
        $rootPrefix = $root.TrimEnd('\') + '\'
        if (-not (Test-Path -LiteralPath $backupDir -PathType Container)) {
            $problems.Add('каталога BACKUP_DIR нет — носитель не подключён?')
        }
        elseif (($backupDir.TrimEnd('\') + '\').StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $problems.Add('BACKUP_DIR внутри клона — backup.sh откажет: бэкап содержит секреты')
        }
    }
    return [pscustomobject]@{
        Problems         = $problems
        GitBash          = $gitBash
        BackupDir        = $backupDir
        BackupDirForward = $backupDir.Replace('\', '/')
    }
}

# Шаги переезда — один список на план сухого прогона и на действие: -DryRun
# печатает Key и Plan, настоящий прогон исполняет Run в том же порядке, —
# переставить шаг в одном месте, не переставив в другом, нельзя (тот же
# приём, что список задач в -Uninstall). Stage — какой откат печатает
# Stop-Migrate при отказе шага. Plan — строки ASCII: первая идёт после
# «Key: », остальные печатаются как есть. Run исполняется точкой
# (. $step.Run) в области сценария: переменные, которые шаг оставляет
# следующим ($restoreFrom), видны дальше.
$migrateSteps = @(
    [pscustomobject]@{
        Key   = 'migrate.stop_api'; Stage = 'desktop'
        Title = 'docker compose stop api (Docker Desktop) — Backend больше не пишет в базу'
        Plan  = { 'docker.exe {0}' -f ($desktopStopApiArgs -join ' ') }
        Run   = {
            Invoke-Passthru $dockerExe $desktopStopApiArgs
            if ($script:passCode -ne 0) { Stop-Migrate "docker compose stop api: код $($script:passCode)" }
        }
    },
    [pscustomobject]@{
        Key   = 'migrate.backup'; Stage = 'desktop'
        Title = 'ops/backup/backup.sh (Git Bash)'
        Plan  = { '{0} {1} <BACKUP_DIR>' -f $script:migrateSetup.GitBash, $backupScriptPath }
        # Каталог — аргументом, чтобы backup.sh и восстановление смотрели в
        # один каталог, а не в BACKUP_DIR окружения.
        Run   = {
            try { $backupsBefore = Get-BackupNames $script:migrateSetup.BackupDir }
            catch { Stop-Migrate "каталог BACKUP_DIR не читается: $($_.Exception.Message)" }
            Invoke-Passthru $script:migrateSetup.GitBash @($backupScriptPath, $script:migrateSetup.BackupDirForward)
            if ($script:passCode -ne 0) { Stop-Migrate "ops/backup/backup.sh: код $($script:passCode)" }
            try { $backupsAfter = Get-BackupNames $script:migrateSetup.BackupDir }
            catch { Stop-Migrate "каталог BACKUP_DIR не читается: $($_.Exception.Message)" }
            $newBackups = @($backupsAfter | Where-Object { $backupsBefore -notcontains $_ })
            if ($newBackups.Count -ne 1) { Stop-Migrate "после backup.sh в BACKUP_DIR новых полных бэкапов $($newBackups.Count), ожидался ровно один" }
            $restoreFrom = '{0}/{1}' -f $script:migrateSetup.BackupDirForward.TrimEnd('/'), $newBackups[0]
            Write-Output "бэкап для переноса: $($newBackups[0])"
        }
    },
    [pscustomobject]@{
        Key   = 'migrate.stop_stack'; Stage = 'desktop'
        Title = 'docker compose --profile ha stop (Docker Desktop, тома не трогаются)'
        Plan  = { 'docker.exe {0} (stop: Docker Desktop volumes stay - rollback path)' -f ($desktopStopStackArgs -join ' ') }
        Run   = {
            Invoke-Passthru $dockerExe $desktopStopStackArgs
            if ($script:passCode -ne 0) { Stop-Migrate "docker compose --profile ha stop: код $($script:passCode)" }
        }
    },
    [pscustomobject]@{
        Key   = 'migrate.desktop_stop'; Stage = 'desktop'
        Title = 'docker desktop stop — процессы не убиваются, ожидается их уход'
        Plan  = { 'docker.exe {0}; wait up to {1} s for Docker Desktop processes to exit (no kill)' -f ($desktopQuitArgs -join ' '), $DesktopWaitSeconds }
        Run   = {
            Invoke-Passthru $dockerExe $desktopQuitArgs
            if ($script:passCode -ne 0) { Stop-Migrate "docker desktop stop: код $($script:passCode)" }
            if (-not (Wait-DesktopGone)) { Stop-Migrate "процессы Docker Desktop не завершились за $DesktopWaitSeconds с — wsl --shutdown не выполнялся" }
        }
    },
    [pscustomobject]@{
        Key   = 'migrate.desktop_autostart'; Stage = 'engine'
        Title = 'автозапуск Docker Desktop при входе — выключить, иначе после входа он займёт порты стека'
        Plan  = {
            $desktopSettings = Get-DesktopSettings
            if (-not $desktopSettings) {
                'WARN no {0} in the Docker Desktop settings dir - AutoStart unchanged; turn it off in Docker Desktop, or at logon it takes the stack ports' -f (($desktopSettingsFiles | ForEach-Object { $_.Leaf }) -join ' or ')
            }
            elseif ($desktopSettings.Value -eq 'false') {
                "$($desktopSettings.Leaf) $($desktopSettings.Key) already false - unchanged"
            }
            else {
                $previousValue = if ($desktopSettings.Value) { $desktopSettings.Value } else { 'absent' }
                "$($desktopSettings.Leaf) $($desktopSettings.Key) $previousValue -> false (copy $($desktopSettings.Leaf).domovoy-backup; -Uninstall restores the value)"
            }
        }
        # Пишется после остановки Desktop: работающий Desktop переписывает файл.
        Run   = {
            $desktopSettings = Get-DesktopSettings
            if (-not $desktopSettings) {
                Write-Warning "в $DockerSettingsDir нет settings-store.json и settings.json — автозапуск Docker Desktop не выключен; выключите его в настройках Desktop, иначе после входа он займёт порты стека"
            }
            elseif ($desktopSettings.Value -eq 'false') {
                Write-Output "Docker Desktop, $($desktopSettings.Leaf): $($desktopSettings.Key) уже false — не тронут"
            }
            else {
                $disabledText = Set-JsonBool $desktopSettings.Text $desktopSettings.Key 'false'
                if ($null -eq $disabledText) {
                    Write-Warning "$($desktopSettings.Leaf) — не объект JSON; автозапуск Docker Desktop не выключен, выключите его в настройках Desktop"
                }
                else {
                    if (-not (Test-Path -LiteralPath $desktopSettings.Backup)) { Copy-Item -LiteralPath $desktopSettings.Path -Destination $desktopSettings.Backup }
                    [IO.File]::WriteAllText($desktopSettings.Path, $disabledText, (New-Object Text.UTF8Encoding($false)))
                    Write-Output "Docker Desktop, $($desktopSettings.Leaf): $($desktopSettings.Key) false (копия .domovoy-backup; -Uninstall вернёт прежнее значение)"
                }
            }
        }
    },
    [pscustomobject]@{
        Key   = 'migrate.desktop_logon_entry'; Stage = 'engine'
        Title = "запись автозапуска Docker Desktop при входе (реестр, Run) — выключить через StartupApproved"
        Plan  = {
            $startup = Get-DesktopStartup
            if ($startup.State -eq 'none') { "no value '$DesktopRunName' in $desktopRunKey - unchanged" }
            elseif ($startup.State -eq 'disabled') { "StartupApproved\Run '$DesktopRunName' $($startup.Hex) already disabled - unchanged" }
            else {
                $previousValue = if ($startup.Hex) { "$($startup.Hex), copy $(Split-Path -Leaf $desktopApprovedBackup)" } else { "absent, marker $(Split-Path -Leaf $desktopApprovedAbsent)" }
                "StartupApproved\Run '$DesktopRunName' -> 03-00-00-00 + FILETIME (disabled; previous value $previousValue; -Uninstall restores it)"
            }
        }
        Run   = {
            $startup = Get-DesktopStartup
            if ($startup.State -eq 'none') { Write-Output "записи автозапуска «$DesktopRunName» в $desktopRunKey нет — не тронуто" }
            elseif ($startup.State -eq 'disabled') { Write-Output "автозапуск «$DesktopRunName» уже выключен (StartupApproved\Run $($startup.Hex)) — не тронут" }
            else {
                # Прежнее значение — один раз: повторный -Migrate не затирает
                # копию первого.
                if (-not (Test-Path -LiteralPath $desktopApprovedBackup) -and -not (Test-Path -LiteralPath $desktopApprovedAbsent)) {
                    $null = New-Item -ItemType Directory -Force -Path $DockerSettingsDir
                    if ($startup.Hex) { [IO.File]::WriteAllText($desktopApprovedBackup, $startup.Hex, (New-Object Text.UTF8Encoding($false))) }
                    else { $null = New-Item -ItemType File -Path $desktopApprovedAbsent }
                }
                Set-DesktopApproved (Get-DisabledStartupBytes)
                $shownValue = if ($startup.Hex) { $startup.Hex } else { 'не было' }
                Write-Output "автозапуск «$DesktopRunName» при входе выключен (StartupApproved\Run; прежнее значение — $shownValue; -Uninstall вернёт)"
            }
        }
    },
    [pscustomobject]@{
        Key   = 'migrate.keeper_stop'; Stage = 'engine'
        Title = "держалка $KeeperTask — остановить, если работает (её всё равно гасит wsl --shutdown)"
        Plan  = { "Stop-ScheduledTask $KeeperTask if its State is Running - wsl --shutdown kills it anyway; a stale Running instance would make the start below a no-op (MultipleInstances IgnoreNew)" }
        Run   = {
            try {
                if ([string](Get-ScheduledTask -TaskName $KeeperTask -ErrorAction Stop).State -eq 'Running') { Stop-ScheduledTask -TaskName $KeeperTask }
            }
            catch { Stop-Migrate "Stop-ScheduledTask ${KeeperTask}: $($_.Exception.Message)" }
        }
    },
    [pscustomobject]@{
        Key   = 'migrate.wsl_shutdown'; Stage = 'engine'
        Title = 'wsl --shutdown — гасит все дистрибутивы WSL, применяет networkingMode=mirrored'
        Plan  = { "wsl.exe --shutdown - stops ALL WSL distributions, not only $Distro (applies networkingMode=mirrored)" }
        Run   = {
            $shutdown = Invoke-Wsl @('--shutdown')
            if ($shutdown.Code -ne 0) { Stop-Migrate "wsl --shutdown: код $($shutdown.Code): $(Format-Native $shutdown)" }
        }
    },
    [pscustomobject]@{
        Key   = 'migrate.keeper_start'; Stage = 'engine'
        Title = "Start-ScheduledTask $KeeperTask и ожидание State Running"
        Plan  = { "Start-ScheduledTask $KeeperTask; wait up to $KeeperWaitSeconds s for task State Running (refusal otherwise)" }
        Run   = {
            try { $keeperStarted = Start-Keeper }
            catch { Stop-Migrate "Start-ScheduledTask ${KeeperTask}: $($_.Exception.Message)" }
            if (-not $keeperStarted) {
                Stop-Migrate "задача $KeeperTask не перешла в Running за $KeeperWaitSeconds с — без держалки дистрибутив погаснет по простою; Get-ScheduledTask $KeeperTask, журнал Планировщика"
            }
            Write-Output "держалка $KeeperTask работает"
        }
    },
    [pscustomobject]@{
        Key   = 'migrate.engine_wait'; Stage = 'engine'
        Title = "ожидание docker в $Distro"
        Plan  = { "docker info in $Distro, up to $EngineWaitSeconds s" }
        Run   = {
            $engineInfo = Wait-EngineDocker
            if ($engineInfo.Code -ne 0 -or -not $engineInfo.Text) {
                Stop-Migrate "docker в $Distro не ответил за $EngineWaitSeconds с: код $($engineInfo.Code): $(Format-Native $engineInfo)"
            }
            Write-Output "docker в $Distro отвечает: $($engineInfo.Text)"
        }
    },
    [pscustomobject]@{
        Key   = 'migrate.restore'; Stage = 'engine'
        Title = "ops/backup/restore.sh --project $project (в $Distro); стек поднимает сам restore.sh"
        Plan  = { 'wsl.exe {0}' -f ((Get-RestoreArgs '<BACKUP_DIR>/<domovoy-backup-* new after migrate.backup>') -join ' ') }
        Run   = {
            $env:WSL_UTF8 = '1'
            Invoke-Passthru $wslExe (Get-RestoreArgs $restoreFrom)
            if ($script:passCode -ne 0) { Stop-Migrate "ops/backup/restore.sh: код $($script:passCode)" }
        }
    },
    [pscustomobject]@{
        Key   = 'migrate.check'; Stage = 'engine'
        Title = 'engine-setup.ps1 -Check — его код и есть код -Migrate'
        Plan  = { 'engine-setup.ps1 -Check - its exit code is the exit code of -Migrate' }
        Run   = {
            Invoke-Passthru (Get-Process -Id $PID).Path @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Check', '-WslConfigPath', $WslConfigPath, '-DockerSettingsDir', $DockerSettingsDir, '-StartupRegistryRoot', $StartupRegistryRoot)
            $checkCode = $script:passCode
            if ($checkCode -ne 0) {
                [Console]::Error.WriteLine("engine-setup: -Migrate: данные перенесены, но -Check не закрыл звенья (код $checkCode). Тома Docker Desktop не тронуты; откат — README, «Откат на Docker Desktop», или engine-setup.ps1 -Uninstall")
            }
            exit $checkCode
        }
    })

# План переезда для -DryRun: те же отказы по предусловиям, без действий и
# без обращений к docker.exe и WSL. ASCII, как остальные строки сухого
# прогона: кириллица в выводе Windows PowerShell уходит в OEM-кодировке.
function Write-MigratePlan {
    $script:migrateSetup = Get-MigrateSetup
    if ($script:migrateSetup.Problems.Count) { Stop-WithError ('переезд не начат: ' + ($script:migrateSetup.Problems -join '; ')) }
    $engineSource = if ($Install) { 'installed by -Install above' } elseif ($AssumeEngineState) { "assumed $AssumeEngineState" } else { 'distro, keeper task, mirrored' }
    Write-Output "migrate.engine: $Distro ($engineSource)"
    Write-Output "migrate.project: $project"
    Write-Output ("migrate.precheck: Docker Desktop answers docker info; docker.exe {0} answers (migrate.desktop_stop needs it); containers of project $project exist; postgres and homeassistant running (checked by the run, not by DryRun)" -f ($desktopCliProbeArgs -join ' '))
    Write-Output "migrate.precheck: no containers and no volumes of project $project in $Distro (the run starts the distro and waits for docker up to $EngineWaitSeconds s; stops it again on refusal)"
    foreach ($migrateStep in $migrateSteps) {
        $planLines = @(& $migrateStep.Plan)
        Write-Output ('{0}: {1}' -f $migrateStep.Key, $planLines[0])
        $planLines | Select-Object -Skip 1
    }
    # Граница откатов — по Stage шагов: что напечатано, то и выберет Stop-Migrate.
    $lastDesktopStep = @($migrateSteps | Where-Object { $_.Stage -eq 'desktop' })[-1].Key
    Write-Output "migrate.rollback: no automatic rollback; Docker Desktop volumes stay intact. Failure up to and including ${lastDesktopStep}: docker desktop start (if it stopped); docker compose --profile ha start. After it: engine-setup.ps1 -Uninstall (administrator); wsl --shutdown; docker desktop start; docker compose --profile ha start"
}

if ($Uninstall) {
    # Откат на Docker Desktop. Состояние читается до любых действий: стек
    # останавливается, только пока дистрибутив работает, — запускать его
    # ради остановки сценарий не станет.
    $registered = (Get-WslNames @('--list', '--quiet')) -contains $Distro
    if ($AssumeEngineState) {
        $engineRunning = $AssumeEngineState -eq 'Running'
        if ($AssumeEngineState -eq 'Absent') { $registered = $false }
    }
    else {
        $engineRunning = (Get-WslNames @('--list', '--running', '--quiet')) -contains $Distro
    }
    # Автозапуск Docker Desktop: -Migrate выключил его и оставил копию.
    $desktopBackup = Get-DesktopSettingsBackup
    # Запись автозапуска в реестре: копия прежнего значения или отметка «не было».
    $approvedAction = 'keep'
    if (Test-Path -LiteralPath $desktopApprovedBackup -PathType Leaf) { $approvedAction = 'restore' }
    elseif (Test-Path -LiteralPath $desktopApprovedAbsent -PathType Leaf) { $approvedAction = 'remove' }
    $stopArgs = @('-d', $Distro, '-u', 'root', '--cd', $root, '--exec', 'docker', 'compose', '--profile', 'ha', 'stop')
    $interactiveArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $scheduleScript, '-Install', '-LogonType', 'Interactive')
    if ($DryRun) { $interactiveArgs += '-DryRun' }
    # Один список на план и на действие: что напечатано, то и снимается.
    $autostartTasks = @($KeeperTask, $MeasureTask)
    $wslBackup = "$WslConfigPath.domovoy-backup"
    $wslAbsent = "$WslConfigPath.domovoy-absent"
    $wslAction = 'keep'
    if (Test-Path -LiteralPath $wslBackup -PathType Leaf) { $wslAction = 'restore' }
    elseif (Test-Path -LiteralPath $wslAbsent -PathType Leaf) { $wslAction = 'remove' }

    if ($DryRun) {
        # ASCII, как строки сухого прогона -Install.
        Write-Output "uninstall.distro: $Distro"
        Write-Output ('uninstall.distro.registered: {0}' -f $registered)
        Write-Output ('uninstall.engine.running: {0}' -f [bool]$engineRunning)
        if ($engineRunning) { Write-Output ('uninstall.stack.stop: wsl.exe {0}' -f ($stopArgs -join ' ')) }
        else { Write-Output 'uninstall.stack.stop: none (distro not running; its containers start again with the distro - restart: unless-stopped)' }
        foreach ($taskName in $autostartTasks) {
            Write-Output "uninstall.task.unregister: $taskName"
        }
        Write-Output ('uninstall.backup: install-schedule.ps1 {0}' -f (($interactiveArgs | Select-Object -Skip 6) -join ' '))
        $schedule = Invoke-Native (Get-Process -Id $PID).Path $interactiveArgs
        foreach ($line in $schedule.Lines) { Write-Output "backup.$line" }
        foreach ($line in $schedule.ErrLines) { Write-Output "backup.stderr: $line" }
        Write-Output "backup.exitcode: $($schedule.Code)"
        Write-Output "uninstall.terminate: wsl.exe --terminate $Distro"
        Write-Output "uninstall.firewall.remove: $RuleName"
        if ($wslAction -eq 'restore') { Write-Output ('uninstall.wslconfig: restore from {0}' -f (Split-Path -Leaf $wslBackup)) }
        elseif ($wslAction -eq 'remove') { Write-Output ('uninstall.wslconfig: remove (marker {0})' -f (Split-Path -Leaf $wslAbsent)) }
        else { Write-Output 'uninstall.wslconfig: keep (no .domovoy-backup copy and no .domovoy-absent marker)' }
        if ($desktopBackup) {
            $previousValue = if ($desktopBackup.Value) { $desktopBackup.Value } else { '(absent - key removed)' }
            Write-Output ('uninstall.desktop_autostart: restore {0}={1} from {2}' -f $desktopBackup.Key, $previousValue, (Split-Path -Leaf $desktopBackup.Backup))
        }
        else {
            Write-Output ('uninstall.desktop_autostart: keep (no {0} copy)' -f (($desktopSettingsFiles | ForEach-Object { "$($_.Leaf).domovoy-backup" }) -join ' or '))
        }
        if ($approvedAction -eq 'restore') {
            Write-Output ("uninstall.desktop_logon_entry: restore StartupApproved\Run '$DesktopRunName' = {0} from {1}" -f [IO.File]::ReadAllText($desktopApprovedBackup).Trim(), (Split-Path -Leaf $desktopApprovedBackup))
        }
        elseif ($approvedAction -eq 'remove') {
            Write-Output ("uninstall.desktop_logon_entry: remove StartupApproved\Run '$DesktopRunName' (marker {0})" -f (Split-Path -Leaf $desktopApprovedAbsent))
        }
        else {
            Write-Output ('uninstall.desktop_logon_entry: keep (no {0} copy and no {1} marker)' -f (Split-Path -Leaf $desktopApprovedBackup), (Split-Path -Leaf $desktopApprovedAbsent))
        }
        Write-Output "uninstall.distro.kept: $Distro - stack volumes inside; remove by hand: wsl --unregister $Distro (destroys the volumes)"
        Write-Output 'DryRun: nothing changed'
        if ($schedule.Code -ne 0) { exit 1 }
        exit 0
    }

    if (-not (Test-Administrator)) {
        Stop-WithError 'нужен терминал администратора. Запустите терминал «от имени администратора» и повторите.'
    }

    # 1. Стек внутри движка — stop, тома целы. Отказ — до любых удалений.
    if ($engineRunning) {
        $env:WSL_UTF8 = '1'
        & $wslExe @stopArgs
        $stopCode = $LASTEXITCODE
        if ($stopCode -ne 0) {
            Stop-WithError "docker compose --profile ha stop внутри ${Distro}: код $stopCode — ничего не удалено; без остановки после перезагрузки поднялись бы два стека"
        }
        Write-Output "стек внутри $Distro остановлен (stop, тома целы)"
    }
    elseif ($registered) {
        Write-Output "дистрибутив $Distro не работает — стек внутри не останавливался: при ручном запуске дистрибутива контейнеры поднимутся сами (restart: unless-stopped)"
    }

    # 2. Задачи автозапуска: держалка сначала останавливается, потом снимается.
    foreach ($taskName in $autostartTasks) {
        $taskNow = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($taskNow) {
            if ([string]$taskNow.State -eq 'Running') { Stop-ScheduledTask -TaskName $taskName }
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Write-Output "задача $taskName удалена"
        }
        else {
            Write-Output "задачи $taskName нет"
        }
    }

    # 3. Расписание бэкапа — под Docker Desktop, Interactive (README, раздел
    # бэкапа). Не встало — задача S4U снимается: ночью она будила бы движок
    # WSL.
    $hostExe = (Get-Process -Id $PID).Path
    & $hostExe @interactiveArgs
    $scheduleCode = $LASTEXITCODE
    $backupProblem = ''
    if ($scheduleCode -ne 0) {
        & $hostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $scheduleScript -Uninstall
        $backupProblem = "расписание бэкапа под Docker Desktop не поставлено (install-schedule.ps1 -LogonType Interactive, код $scheduleCode); задача $BackupTask снята (код $LASTEXITCODE), чтобы ночью не будить движок WSL. Поставить: powershell -ExecutionPolicy Bypass -File ops/backup/install-schedule.ps1 -LogonType Interactive"
    }

    # 4. Дистрибутив гасится, но не удаляется: в нём тома стека.
    if ($registered) {
        $terminated = Invoke-Wsl @('--terminate', $Distro)
        if ($terminated.Code -ne 0) { Write-Warning "wsl --terminate ${Distro}: код $($terminated.Code): $(Format-Native $terminated)" }
        else { Write-Output "дистрибутив $Distro остановлен" }
    }

    # 5. Правило firewall.
    if (Get-NetFirewallHyperVRule -Name $RuleName -ErrorAction SilentlyContinue) {
        Remove-NetFirewallHyperVRule -Name $RuleName
        Write-Output "правило $RuleName удалено"
    }
    else {
        Write-Output "правила $RuleName нет"
    }

    # 6. .wslconfig: копия и отметка расходуются — следующий -Install
    # сохранит файл заново, а не оставит устаревшую копию.
    if ($wslAction -eq 'restore') {
        Move-Item -LiteralPath $wslBackup -Destination $WslConfigPath -Force
        Remove-Item -LiteralPath $wslAbsent -Force -ErrorAction SilentlyContinue
        Write-Output "${WslConfigPath}: возвращён из копии .domovoy-backup"
    }
    elseif ($wslAction -eq 'remove') {
        Remove-Item -LiteralPath $WslConfigPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $wslAbsent -Force
        Write-Output "${WslConfigPath}: удалён — до -Install его не было (отметка .domovoy-absent)"
    }
    else {
        Write-Output "${WslConfigPath}: не тронут — нет ни копии .domovoy-backup, ни отметки .domovoy-absent"
    }

    # 7. Автозапуск Docker Desktop — прежнее значение ключа из копии, а не
    # файл целиком: другие настройки Desktop могли меняться после -Migrate.
    if ($desktopBackup) {
        if (Test-Path -LiteralPath $desktopBackup.Path -PathType Leaf) {
            $restored = Set-JsonBool ([IO.File]::ReadAllText($desktopBackup.Path)) $desktopBackup.Key $desktopBackup.Value
            if ($null -eq $restored) { Copy-Item -LiteralPath $desktopBackup.Backup -Destination $desktopBackup.Path -Force }
            else { [IO.File]::WriteAllText($desktopBackup.Path, $restored, (New-Object Text.UTF8Encoding($false))) }
        }
        else {
            Copy-Item -LiteralPath $desktopBackup.Backup -Destination $desktopBackup.Path
        }
        Remove-Item -LiteralPath $desktopBackup.Backup -Force
        $shownValue = if ($desktopBackup.Value) { $desktopBackup.Value } else { 'ключа не было — убран' }
        Write-Output "Docker Desktop, $($desktopBackup.Leaf): $($desktopBackup.Key) возвращён к прежнему значению ($shownValue)"
        if (@(Get-Process -Name 'Docker Desktop', 'com.docker.backend' -ErrorAction SilentlyContinue).Count) {
            Write-Warning 'Docker Desktop работает — при выходе он может записать свои настройки поверх; проверьте автозапуск в его настройках'
        }
    }
    else {
        Write-Output 'настройки Docker Desktop не тронуты — копии .domovoy-backup нет'
    }
    # Запись автозапуска в реестре — прежнее значение; копия и отметка расходуются.
    if ($approvedAction -eq 'restore') {
        $approvedHex = [IO.File]::ReadAllText($desktopApprovedBackup).Trim()
        Set-DesktopApproved ([byte[]]@($approvedHex -split '-' | ForEach-Object { [Convert]::ToByte($_, 16) }))
        Remove-Item -LiteralPath $desktopApprovedBackup -Force
        Write-Output "автозапуск «$DesktopRunName» (StartupApproved\Run) возвращён к прежнему значению $approvedHex"
    }
    elseif ($approvedAction -eq 'remove') {
        Remove-ItemProperty -LiteralPath $desktopApprovedKey -Name $DesktopRunName -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $desktopApprovedAbsent -Force
        Write-Output "автозапуск «$DesktopRunName»: значение StartupApproved\Run убрано — до -Migrate его не было"
    }
    else {
        Write-Output "автозапуск «$DesktopRunName» в реестре не тронут — нет ни копии, ни отметки -Migrate"
    }

    Write-Output @"

Дистрибутив $Distro не удалён: в нём тома стека. Удалить вручную, когда
данные не нужны: wsl --unregister $Distro — тома уничтожаются без возврата.

Дальше (README, «Откат на Docker Desktop»): убрать функцию docker() из
~/.bashrc и открыть новую оболочку Git Bash; wsl --shutdown — применяет
.wslconfig, гасит все дистрибутивы; docker desktop start;
docker compose --profile ha start.
"@
    if ($backupProblem) { Stop-WithError $backupProblem }
    exit 0
}

if ($Install) {
    # Объекты задач и параметры правила собираются до любых действий; сухой
    # прогон печатает их свойства: что напечатано, то и регистрируется.
    $bootTrigger = New-ScheduledTaskTrigger -AtStartup
    $keeperAction = New-ScheduledTaskAction -Execute $wslExe -Argument ('-d {0} --exec sleep infinity' -f $Distro)
    $keeperPrincipal = New-ScheduledTaskPrincipal -UserId $userId -LogonType S4U -RunLevel Limited
    $keeperSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew

    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    # Журнал — в профиле пользователя: путь задаётся при регистрации, задача
    # под S4U не зависит от того, загружено ли окружение профиля.
    $measureLog = Join-Path $env:LOCALAPPDATA 'domovoy-engine\measure-boot.log'
    $measureArgument = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Port {1} -LogPath "{2}"' -f $measureScript, $apiPort, $measureLog
    $measureAction = New-ScheduledTaskAction -Execute $powershellExe -Argument $measureArgument
    # Не SYSTEM: действие исполняет файл из клона, который пользователь
    # может менять. Журнал System (Kernel-General 12), LastBootUpTime и
    # FwPOSTTime читаются без прав администратора.
    $measurePrincipal = New-ScheduledTaskPrincipal -UserId $userId -LogonType S4U -RunLevel Limited
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
    # Провижининг делает wsl --terminate дистрибутива: держалка и движок
    # гибнут. Работали до -Install — держалка запускается снова после
    # регистрации задач, иначе стек лежал бы до перезагрузки.
    if ($AssumeEngineState) {
        $engineRunning = $AssumeEngineState -eq 'Running'
        if ($AssumeEngineState -eq 'Absent') { $registered = $false }
    }
    else {
        $keeperNow = Get-ScheduledTask -TaskName $KeeperTask -ErrorAction SilentlyContinue
        $engineRunning = ($keeperNow -and [string]$keeperNow.State -eq 'Running') -or
            ((Get-WslNames @('--list', '--running', '--quiet')) -contains $Distro)
    }
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
        Write-Output ('engine.running: {0}' -f [bool]$engineRunning)
        if ($engineRunning) { Write-Output ('keeper.resume: Start-ScheduledTask {0}' -f $KeeperTask) }
        # ASCII, как остальные строки сухого прогона: кириллица в выводе
        # Windows PowerShell уходит в OEM-кодировке консоли.
        else { Write-Output 'keeper.resume: none (keeper and distro were not running)' }
        foreach ($task in @(
                @{ Prefix = 'keeper'; Name = $KeeperTask; Action = $keeperAction; Principal = $keeperPrincipal; Settings = $keeperSettings },
                @{ Prefix = 'measure'; Name = $MeasureTask; Action = $measureAction; Principal = $measurePrincipal; Settings = $measureSettings })) {
            $p = $task.Prefix
            Write-Output "${p}.task: $($task.Name)"
            Write-Output "${p}.trigger: $($bootTrigger.CimClass.CimClassName)"
            Write-Output "${p}.execute: $($task.Action.Execute)"
            Write-Output "${p}.arguments: $($task.Action.Arguments)"
            # SID рядом с именем: имена встроенных учётных записей локализованы.
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
            # Байт в байт, как запишет -Install: строки ниже делятся по
            # переводу строки и лишний CR не показывают.
            Write-Output ('wslconfig.base64: {0}' -f [Convert]::ToBase64String((New-Object Text.UTF8Encoding($false)).GetBytes($wslConfig.Content)))
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
        foreach ($line in $schedule.ErrLines) { Write-Output "backup.stderr: $line" }
        Write-Output "backup.exitcode: $scheduleCode"
        if ($wslConfig.Conflict -or $scheduleCode -ne 0) {
            Write-Output 'DryRun: nothing changed'
            exit 1
        }
        # С -Migrate дальше — план переезда; строка сухого прогона одна, в конце.
        if ($Migrate) { Write-MigratePlan }
        Write-Output 'DryRun: nothing changed'
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
            Stop-WithError "SHA256 образа не сошёлся с SHA256SUMS (ожидалось «$expected», получено «$actual») — загрузка повреждена или неполна; образ удалён, дистрибутив не создан"
        }
        $import = Invoke-Wsl $importArgs
        if ($import.Code -ne 0) { Stop-WithError "wsl --import: код $($import.Code): $(Format-Native $import)" }
        Remove-Item -LiteralPath $tar, $sumsFile -Force -ErrorAction SilentlyContinue
        Write-Output "дистрибутив $Distro создан из $ImageFile (целостность загрузки: SHA256 сошёлся с SHA256SUMS того же сервера; подлинность не проверялась)"
    }

    # Держалка снова, если работала до -Install: $true — запущена.
    function Resume-Keeper {
        if (-not $engineRunning) { return $false }
        if (-not (Get-ScheduledTask -TaskName $KeeperTask -ErrorAction SilentlyContinue)) { return $false }
        if (-not (Start-Keeper)) { throw "задача $KeeperTask не перешла в Running за $KeeperWaitSeconds с" }
        return $true
    }
    # Отказ после остановки дистрибутива: прежнее состояние возвращается
    # до выхода, а не оставляется до перезагрузки.
    function Stop-Install([string]$Message) {
        try { $resumed = Resume-Keeper } catch { $resumed = $false; $Message += "; держалку запустить не удалось: $($_.Exception.Message)" }
        if ($resumed) { $Message += "; держалка $KeeperTask запущена снова, как работала до -Install" }
        Stop-WithError $Message
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
    if ($provisionCode -ne 0) { Stop-Install "провижининг дистрибутива: код $provisionCode" }
    $null = Invoke-Wsl @('--terminate', $Distro)
    # По одному юниту: is-enabled со списком даёт код 0, если включён хоть
    # один. Признак — вывод enabled, как в -Check.
    $disabled = New-Object System.Collections.Generic.List[string]
    foreach ($unit in 'docker.service', 'containerd.service') {
        $isEnabled = Invoke-Wsl @('-d', $Distro, '-u', 'root', '--exec', 'systemctl', 'is-enabled', $unit)
        if ($isEnabled.Text -ne 'enabled') { $disabled.Add("$unit «$(Format-Native $isEnabled)»") }
    }
    $null = Invoke-Wsl @('--terminate', $Distro)
    if ($disabled.Count) { Stop-Install "не в автозапуске systemd дистрибутива: $($disabled -join '; ')" }
    Write-Output 'docker.service и containerd.service в автозапуске systemd дистрибутива'

    # 3–4. Задачи; -Force заменяет прежние.
    # Отказ регистрации — тоже после остановки дистрибутива: через Stop-Install.
    try {
        $null = Register-ScheduledTask -TaskName $KeeperTask -Trigger $bootTrigger -Action $keeperAction -Principal $keeperPrincipal `
            -Settings $keeperSettings -Description 'Домовой: держит WSL-дистрибутив движка Docker после загрузки, без входа' -Force
        Write-Output "задача $KeeperTask зарегистрирована: при запуске системы, S4U"
        $null = Register-ScheduledTask -TaskName $MeasureTask -Trigger $bootTrigger -Action $measureAction -Principal $measurePrincipal `
            -Settings $measureSettings -Description 'Домовой: замер от старта ОС до первого ответа /health' -Force
        Write-Output "задача $MeasureTask зарегистрирована: порт $apiPort, S4U, журнал $measureLog"
    }
    catch {
        Stop-Install "регистрация задач: $($_.Exception.Message)"
    }

    # Держалка — сразу после регистрации, до шагов, которые могут отказать.
    try { $resumed = Resume-Keeper }
    catch { Stop-WithError "держалка $KeeperTask работала до -Install, а запустить её снова не удалось: $($_.Exception.Message) — Start-ScheduledTask $KeeperTask" }
    if ($resumed) { Write-Output "держалка $KeeperTask работала до -Install — запущена снова; контейнеры поднимет restart: unless-stopped" }

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

    if ($Migrate) {
        if ($scheduleCode -ne 0) {
            Stop-WithError "расписание бэкапа не поставлено (ops/backup/install-schedule.ps1, код $scheduleCode) — остальное настроено; переезд (-Migrate) не начинался"
        }
        Write-Output "`nустановка закончена — дальше переезд с Docker Desktop (-Migrate)`n"
    }
    elseif ($resumed) {
        Write-Output @"

Повторный запуск: дистрибутив $Distro перезапускался (wsl --terminate), держалка
запущена снова. Проверка всех звеньев — -Check.
"@
    }
    else {
        Write-Output @"

Дальше — переезд с Docker Desktop одной командой (README, «Автозапуск после
перезагрузки»): engine-setup.ps1 -Migrate — бэкап на Desktop, wsl --shutdown,
Start-ScheduledTask $KeeperTask, восстановление внутри дистрибутива, -Check.
Предусловия: BIOS — включаться после пропадания питания; BitLocker без PIN.
"@
    }
    if ($scheduleCode -ne 0) {
        Stop-WithError "расписание бэкапа не поставлено (ops/backup/install-schedule.ps1, код $scheduleCode) — остальное настроено"
    }
    if (-not $Migrate) { exit 0 }
}

if ($Migrate) {
    if ($DryRun) {
        Write-MigratePlan
        Write-Output 'DryRun: nothing changed'
        exit 0
    }
    if (-not (Test-Administrator)) {
        Stop-WithError 'нужен терминал администратора. Запустите терминал «от имени администратора» и повторите.'
    }
    $script:migrateSetup = Get-MigrateSetup
    if ($script:migrateSetup.Problems.Count) { Stop-WithError ("переезд не начат, ничего не изменено: " + ($script:migrateSetup.Problems -join '; ')) }

    # Docker Desktop: docker.exe хоста, в каталоге клона — compose берёт
    # docker-compose.yml и .env отсюда. Функция docker() из ~/.bashrc
    # (обёртка движка) сюда не попадает: это PowerShell.
    Set-Location -LiteralPath $root
    $dockerCommand = Get-Command docker.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $dockerCommand) { Stop-WithError 'переезд не начат: docker.exe Docker Desktop не найден в PATH' }
    $dockerExe = $dockerCommand.Source
    $projectLabel = "label=com.docker.compose.project=$project"

    # Предусловия на работающих системах — до любых действий, каждая проба
    # fail-closed: ненулевой код — отказ, пустой вывод «пустотой» не считается.
    $desktopInfo = Invoke-Native $dockerExe @('info', '--format', '{{.OperatingSystem}}')
    if ($desktopInfo.Code -ne 0 -or $desktopInfo.Text -notmatch 'Docker Desktop') {
        Stop-WithError "переезд не начат: Docker Desktop не отвечает (docker info: код $($desktopInfo.Code): $(Format-Native $desktopInfo)) — запустите его: docker desktop start"
    }
    $desktopCli = Invoke-Native $dockerExe $desktopCliProbeArgs
    if ($desktopCli.Code -ne 0) {
        Stop-WithError "переезд не начат: docker.exe не знает команды desktop (docker $($desktopCliProbeArgs -join ' '): код $($desktopCli.Code): $(Format-Native $desktopCli)) — шаг 4 останавливает ею Docker Desktop; обновите Docker Desktop"
    }
    $desktopAll = Invoke-Native $dockerExe @('ps', '-aq', '--filter', $projectLabel)
    if ($desktopAll.Code -ne 0) { Stop-WithError "переезд не начат: docker ps на Docker Desktop: код $($desktopAll.Code): $(Format-Native $desktopAll)" }
    if (-not $desktopAll.Text) { Stop-WithError "переезд не начат: на Docker Desktop нет контейнеров проекта $project — переносить нечего" }
    # backup.sh работает только при запущенных postgres и homeassistant.
    foreach ($service in 'postgres', 'homeassistant') {
        $desktopService = Invoke-Native $dockerExe @('ps', '-q', '--filter', $projectLabel, '--filter', "label=com.docker.compose.service=$service", '--filter', 'status=running')
        if ($desktopService.Code -ne 0) { Stop-WithError "переезд не начат: docker ps на Docker Desktop: код $($desktopService.Code): $(Format-Native $desktopService)" }
        if (-not $desktopService.Text) { Stop-WithError "переезд не начат: на Docker Desktop не запущен $service проекта $project — бэкапу он нужен; docker compose --profile ha up -d" }
    }

    # Движок: в нём нет ни контейнеров, ни томов проекта — иначе повторный
    # перенос затёр бы данные, а restore.sh отказал бы уже после остановки
    # Desktop. Проба запускает дистрибутив; не работал до неё — при отказе
    # гасится только он.
    $engineWasRunning = (Get-WslNames @('--list', '--running', '--quiet')) -contains $Distro
    $engineProblem = ''
    $engineInfo = Wait-EngineDocker
    if ($engineInfo.Code -ne 0 -or -not $engineInfo.Text) {
        $engineProblem = "docker в $Distro не ответил за $EngineWaitSeconds с: код $($engineInfo.Code): $(Format-Native $engineInfo)"
    }
    else {
        foreach ($probe in @(@('ps', '-aq', '--filter', $projectLabel), @('volume', 'ls', '-q', '--filter', $projectLabel))) {
            $engineProbe = Invoke-Wsl (@('-d', $Distro, '-u', 'root', '--exec', 'docker') + $probe)
            if ($engineProbe.Code -ne 0) { $engineProblem = "docker $($probe[0]) в ${Distro}: код $($engineProbe.Code): $(Format-Native $engineProbe)"; break }
            if ($engineProbe.Text) {
                $engineProblem = "в $Distro уже есть $(if ($probe[0] -eq 'ps') { 'контейнеры' } else { 'тома' }) проекта $project — перенос уже был или начат; данные движка не затираются. Сверьте их (-Check, docker через обёртку); удаление — только руками владельца"
                break
            }
        }
    }
    if ($engineProblem) {
        if (-not $engineWasRunning) { $null = Invoke-Wsl @('--terminate', $Distro) }
        Stop-WithError "переезд не начат, ничего не изменено: $engineProblem"
    }

    # Отказ после остановки api: автоматического отката нет — только текст;
    # какой — по Stage шага: desktop — до ухода процессов Docker Desktop
    # включительно, engine — после.
    $script:migrateStage = 'desktop'
    function Stop-Migrate([string]$Message) {
        if ($script:migrateStage -eq 'desktop') {
            # До ухода процессов Desktop: wsl --shutdown не выполнялся, Desktop
            # работает или остановлен частично (отказ docker desktop stop или
            # его ожидания).
            $rollback = "Тома Docker Desktop не тронуты, wsl --shutdown не выполнялся. Вернуть стек: docker desktop start (если Desktop остановился), затем из каталога клона docker compose --profile ha start"
        }
        else {
            $rollback = @"
Тома Docker Desktop не тронуты — данные там целы. Откат на Docker Desktop:
  powershell -ExecutionPolicy Bypass -File deploy/windows/engine-setup.ps1 -Uninstall   (терминал администратора)
  wsl --shutdown          (гасит все дистрибутивы WSL)
  docker desktop start
  docker compose --profile ha start   (из каталога клона, docker.exe Docker Desktop)
"@
        }
        Stop-WithError "-Migrate: $Message`n$rollback"
    }

    # Шаги — из того же списка, что печатает -DryRun, в том же порядке.
    $migrateStepNumber = 0
    foreach ($migrateStep in $migrateSteps) {
        $migrateStepNumber++
        $script:migrateStage = $migrateStep.Stage
        Write-Output "== $migrateStepNumber. $($migrateStep.Title)"
        . $migrateStep.Run
    }
    # Последний шаг (-Check) выходит сам; сюда сценарий не доходит.
    Stop-WithError '-Migrate: список шагов кончился без -Check'
}

# ---------------------------------------------------------------- -Check
$results = New-Object System.Collections.Generic.List[object]
# Counted = $false — звено, которое с хоста не проверяется по устройству
# сети: в вывод идёт, в итог и код выхода — нет.
function Add-Result([string]$State, [string]$Link, [string]$Detail, [bool]$Counted = $true) {
    $results.Add([pscustomobject]@{ State = $State; Link = $Link; Detail = $Detail; Counted = $Counted })
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
    Add-Result 'FAIL' 'держалка работает' "нет задачи $KeeperTask"
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
    # Свойства задачи не говорят, работает ли она: дистрибутив, поднятый
    # чужим wsl.exe (restore.sh, обёртка docker), без держалки гаснет по простою.
    if ([string]$keeper.State -eq 'Running') { Add-Result 'OK' 'держалка работает' "задача $KeeperTask Running" }
    else { Add-Result 'FAIL' 'держалка работает' "задача $KeeperTask в состоянии $($keeper.State) — без неё дистрибутив гаснет по простою; Start-ScheduledTask $KeeperTask" }
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
    elseif ([string]$measure.Principal.LogonType -ne 'S4U' -or [string]$measure.Principal.RunLevel -ne 'Limited') {
        Add-Result 'FAIL' 'задача замера' "принципал $($measure.Principal.UserId), $($measure.Principal.LogonType), $($measure.Principal.RunLevel) — нужен пользователь с S4U и Limited: задача исполняет файл из клона"
    }
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

# Автозапуск Docker Desktop при входе: при входе владельца он занял бы порты
# стека. Запускает его запись Run, а не файл настроек; файл с AutoStart
# true при старте Desktop вернул бы запись.
$startupNow = Get-DesktopStartup
$startupProblems = New-Object System.Collections.Generic.List[string]
$startupShown = if ($startupNow.Hex) { $startupNow.Hex } else { 'нет значения' }
if ($startupNow.State -eq 'enabled') { $startupProblems.Add("запись Run «$DesktopRunName» включена (StartupApproved\Run: $startupShown) — выключите: -Migrate или Диспетчер задач, «Автозагрузка»") }
elseif ($startupNow.State -eq 'unknown') { $startupProblems.Add("StartupApproved\Run «$DesktopRunName» = $($startupNow.Hex): первый байт не 02, 06 или 03 — состояние неизвестно") }
$desktopSettingsNow = Get-DesktopSettings
if ($desktopSettingsNow -and $desktopSettingsNow.Value -eq 'true') { $startupProblems.Add("$($desktopSettingsNow.Leaf): $($desktopSettingsNow.Key) true") }
if ($startupProblems.Count) { Add-Result 'FAIL' 'автозапуск Docker Desktop при входе выключен' ($startupProblems -join '; ') }
elseif ($startupNow.State -eq 'none') { Add-Result 'OK' 'автозапуск Docker Desktop при входе выключен' 'записи Run нет' }
else { Add-Result 'OK' 'автозапуск Docker Desktop при входе выключен' "StartupApproved\Run $($startupNow.Hex)" }

$running = (Get-WslNames @('--list', '--running', '--quiet')) -contains $Distro
$inner = @('docker.service в автозапуске', 'containerd.service в автозапуске', 'restart: unless-stopped у контейнеров проекта', 'порт замера = опубликованный порт api')
if (-not $running) {
    foreach ($link in $inner) { Add-Result 'SKIP' $link 'не проверено — дистрибутив не запущен' }
}
else {
    foreach ($unit in 'docker.service', 'containerd.service') {
        $isEnabled = Invoke-Wsl @('-d', $Distro, '-u', 'root', '--exec', 'systemctl', 'is-enabled', $unit)
        $isActive = Format-Native (Invoke-Wsl @('-d', $Distro, '-u', 'root', '--exec', 'systemctl', 'is-active', $unit))
        # OK — по is-enabled: «active» после ручного старта автозапуска не доказывает.
        if ($isEnabled.Text -eq 'enabled') { Add-Result 'OK' "$unit в автозапуске" "is-enabled enabled; is-active $isActive" }
        else { Add-Result 'FAIL' "$unit в автозапуске" "is-enabled «$(Format-Native $isEnabled)»; is-active $isActive" }
    }
    $label = "label=com.docker.compose.project=$project"
    $listed = Invoke-Wsl @('-d', $Distro, '-u', 'root', '--exec', 'docker', 'ps', '-a', '--filter', $label, '--format', '{{.Names}}')
    $names = @($listed.Lines | Where-Object { $_ })
    if ($listed.Code -ne 0) {
        Add-Result 'FAIL' 'restart: unless-stopped у контейнеров проекта' "docker ps: код $($listed.Code): $(Format-Native $listed)"
    }
    elseif (-not $names.Count) {
        Add-Result 'FAIL' 'restart: unless-stopped у контейнеров проекта' "контейнеров проекта $project нет"
    }
    else {
        $inspected = Invoke-Wsl (@('-d', $Distro, '-u', 'root', '--exec', 'docker', 'inspect', '-f', '{{.Name}} {{.HostConfig.RestartPolicy.Name}}') + $names)
        $policies = @($inspected.Text -split "`r?`n" | Where-Object { $_ })
        $bad = @($policies | Where-Object { $_ -notmatch '\sunless-stopped$' })
        # Отказ inspect или неполный ответ — не OK: пустой stdout дал бы
        # «0 контейнеров» без единой проверенной политики.
        if ($inspected.Code -ne 0 -or $policies.Count -ne $names.Count) {
            Add-Result 'FAIL' 'restart: unless-stopped у контейнеров проекта' "docker inspect: код $($inspected.Code), политик $($policies.Count) из $($names.Count): $(Format-Native $inspected)"
        }
        elseif ($bad.Count) { Add-Result 'FAIL' 'restart: unless-stopped у контейнеров проекта' ($bad -join '; ') }
        else { Add-Result 'OK' 'restart: unless-stopped у контейнеров проекта' ('{0} контейнеров' -f @($policies).Count) }
    }
    $apiPorts = Invoke-Wsl @('-d', $Distro, '-u', 'root', '--exec', 'docker', 'ps', '--filter', $label, '--filter', 'label=com.docker.compose.service=api', '--format', '{{.Ports}}')
    $published = [regex]::Match($apiPorts.Text, ':(\d+)->\d+/tcp')
    if ($apiPorts.Code -ne 0) { Add-Result 'FAIL' 'порт замера = опубликованный порт api' "docker ps: код $($apiPorts.Code): $(Format-Native $apiPorts)" }
    elseif (-not $published.Success) { Add-Result 'FAIL' 'порт замера = опубликованный порт api' 'api не запущен или порт не опубликован' }
    elseif ([int]$published.Groups[1].Value -ne $measurePort) { Add-Result 'FAIL' 'порт замера = опубликованный порт api' "api опубликован на $($published.Groups[1].Value), задача замера — $measurePort" }
    else { Add-Result 'OK' 'порт замера = опубликованный порт api' "$measurePort" }
}

# /health с хоста через петлю. Петля в mirrored при правиле только на
# LocalSubnet в опыте 2026-10-12 отвечала тайм-аутом; правило дополнено
# 127.0.0.1 и ::1.
$loop = Get-Health ('http://localhost:{0}/health' -f $apiPort)
if ($loop.Stack) { Add-Result 'OK' "/health на localhost:$apiPort" '200 формы стека' }
elseif ($loop.Code) { Add-Result 'FAIL' "/health на localhost:$apiPort" "код $($loop.Code)$(if ($loop.Code -eq 200) { ', тело не формы стека — чужой слушатель' })" }
else { Add-Result 'FAIL' "/health на localhost:$apiPort" "нет ответа: $($loop.Error)" }

# Доступ из ЛВС с хоста не проверяется: в mirrored хост не достаёт до
# слушателя дистрибутива по своему же адресу в ЛВС (hostAddressLoopback по
# умолчанию false, -Install его не пишет) — такой запрос отказал бы всегда.
# Его проверяет устройство в домашней сети (README, «Проверочные
# перезагрузки и замер»); звено печатается, но в итог и код не входит.
Add-Result 'SKIP' "/health из ЛВС, порт $apiPort" 'не проверяется с хоста в mirrored — доступ из ЛВС проверяет устройство в сети' $false

# Расписание бэкапа (#8): S4U и состояние по install-schedule.ps1 -Check.
$backupTaskObject = Get-ScheduledTask -TaskName $BackupTask -ErrorAction SilentlyContinue
if (-not $backupTaskObject) {
    Add-Result 'FAIL' 'расписание бэкапа' "нет задачи $BackupTask"
}
else {
    $schedule = Invoke-Native (Get-Process -Id $PID).Path @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $scheduleScript, '-Check')
    $scheduleCode = $schedule.Code
    foreach ($line in $schedule.Lines) { Write-Output "     | $line" }
    foreach ($line in $schedule.ErrLines) { Write-Output "     | stderr: $line" }
    if ([string]$backupTaskObject.Principal.LogonType -ne 'S4U') { Add-Result 'FAIL' 'расписание бэкапа' "LogonType $($backupTaskObject.Principal.LogonType), нужен S4U" }
    elseif ($scheduleCode -ne 0) { Add-Result 'FAIL' 'расписание бэкапа' "install-schedule.ps1 -Check: код $scheduleCode" }
    else { Add-Result 'OK' 'расписание бэкапа' 'S4U' }
}

$notOk = @($results | Where-Object { $_.Counted -and $_.State -ne 'OK' })
if ($notOk.Count) {
    Write-Output ('итог: не закрыто звеньев — {0}: {1}' -f $notOk.Count, (($notOk | ForEach-Object { $_.Link }) -join '; '))
    exit 1
}
Write-Output 'итог: все звенья, проверяемые с хоста, OK; доступ из ЛВС — с устройства в сети'
exit 0
