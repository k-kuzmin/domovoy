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
    powershell -ExecutionPolicy Bypass -File deploy/windows/engine-setup.ps1 -Uninstall        # снос движка, терминал администратора
    powershell -ExecutionPolicy Bypass -File deploy/windows/engine-setup.ps1 -Uninstall -DryRun

  -Install (повторный запуск ничего не дублирует; дистрибутив при нём
  кратко перезапускается — wsl --terminate в шаге 2, — и если держалка или
  дистрибутив работали до запуска, держалка сразу после регистрации задач
  запускается снова: стек не лежит до перезагрузки):
    1. дистрибутив domovoy-engine: wsl --import официального образа Ubuntu
       24.04 для WSL (cloud-images.ubuntu.com), SHA256 сверяется с SHA256SUMS
       того же каталога — это проверка целостности загрузки, не подлинности:
       подпись SHA256SUMS не проверяется, и подменённый на сервере образ
       вместе с его суммой проверку пройдёт; уже зарегистрированный не
       трогается. Диск дистрибутива — разреженный: сразу после импорта
       wsl --manage domovoy-engine --set-sparse true; у зарегистрированного
       без атрибута SparseFile у ext4.vhdx (путь — BasePath из
       HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss) — то же в окне
       после wsl --terminate шага 2, до возврата держалки. Флаг
       --allow-unsafe сценарий не ставит. Отказ wsl -Install не обрывает:
       остальные шаги доводятся, в конце — ненулевой код с текстом wsl
       (как при отказе расписания бэкапа); решение за владельцем, звено
       -Check «диск дистрибутива разреженный» красное, пока диск не разрежен;
    2. провижининг внутри под root — deploy/windows/provision-engine.sh:
       systemd, Docker Engine с compose, git, safe.directory клона, журнал
       systemd на диске со сбросом раз в 10 с и драйвер логов docker
       journald (действует после перезапуска дистрибутива ниже). Если
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
       -Distro domovoy-engine -Project <COMPOSE_PROJECT_NAME>
       -DeployDir <каталог развёртывания>
       -LogPath %LOCALAPPDATA%\domovoy-engine\measure-boot.log — хронология
       загрузки: дистрибутив, docker, контейнеры проекта, статус /health;
       зонд внутри дистрибутива идёт в каталоге развёртывания;
    5. %USERPROFILE%\.wslconfig: [wsl2] networkingMode=nat (запись 0030) —
       127.0.0.1 и ::1 хоста доводит до движка wslrelay (localhostForwarding);
       [experimental] sparseVhd=true (новые диски разреженные) и
       autoMemoryReclaim=gradual (ВМ отдаёт хосту освободившуюся память).
       Прежний файл сохраняется копией .wslconfig.domovoy-backup, отсутствие —
       отметкой .wslconfig.domovoy-absent; уже сохранённое не перезаписывается.
       mirrored, записанный прежним -Install по 0028 (рядом копия или
       отметка), переписывается на nat. Другое значение networkingMode,
       localhostForwarding=false, sparseVhd иное, чем true, или
       autoMemoryReclaim иное, чем gradual, — отказ до первого изменения:
       чужая настройка не переписывается.
       Применяется после wsl --shutdown — его -Install не выполняет (гасит
       все дистрибутивы пользователя), выполняет владелец (README);
    6. правило firewall Windows domovoy-engine-ports: входящие TCP на порты
       API и Home Assistant, только с локальной подсети, только в профиле
       Private и только к svchost.exe службы IP Helper — слушателю portproxy.
       Сеть хоста должна быть частной. Закрытость портов шире правила держат
       профили firewall Windows: все три (Domain, Private, Public) должны
       быть включены и по умолчанию блокировать входящие — иначе отказ до
       первого изменения. Прежнее правило Hyper-V firewall с тем же именем
       (0028) снимается до записи правила Windows;
    7. portproxy v4tov4 с адреса хоста в ЛВС на 127.0.0.1 того же порта —
       по записи на порт API и Home Assistant: доступ из ЛВС. Адрес —
       IPv4 интерфейса с маршрутом по умолчанию в частной сети, с наименьшим
       весом (метрика маршрута + метрика интерфейса); два адреса с равным
       весом или ни одного — отказ. Свои записи на прежнем адресе снимаются,
       чужие не трогаются: чужая запись на выбранном адресе и порту стека —
       отказ до первого изменения. Служба IP Helper (iphlpsvc), без которой portproxy
       не работает, должна запускаться автоматически — иначе отказ до
       первого изменения. Адрес в
       вывод не попадает. Сменился адрес (DHCP, другая сеть) — повторный
       -Install;
    8. последним шагом — расписание бэкапа:
       ops/backup/install-schedule.ps1 -Install -DeployDir <каталог> (S4U).

  Настройки стека — API_HTTP_PORT, HA_HTTP_PORT, COMPOSE_PROJECT_NAME — из
  .env каталога развёртывания -DeployDir (по умолчанию /srv/domovoy) внутри
  дистрибутива, только несекретные ключи и только через
  wsl.exe -d domovoy-engine -u root --cd <DeployDir> --exec bash deploy/envfile.sh get .env <ключи>
  Читаются в -Install, если дистрибутив зарегистрирован; в -Install -DryRun,
  -Check и -Uninstall — только если он уже работает. Иначе, а также если в
  каталоге нет .env или deploy/envfile.sh (хост до переноса стека), —
  значения по умолчанию из docker-compose.yml с причиной: строка
  settings.source сухого прогона, звено SKIP «настройки каталога
  развёртывания» в -Check; -Install при этом не обрывается. Каталог есть, а
  get отказал — отказ, а не значения по умолчанию. .env клона не читается.
  Чисел портов в сценарии нет.

  -Check только читает: ничего не запускает и не останавливает, внутрь
  дистрибутива заходит, только если он уже работает. Каждое звено — строка
  OK / FAIL / SKIP; код 0 — только если все OK. SKIP — «не проверено»
  (дистрибутив не запущен, нет прав прочитать правило), код тоже ненулевой.
  Внутри работающего дистрибутива — юниты автозапуска, журнал systemd на
  диске со сбросом не реже 10 с (systemd-analyze cat-config), драйвер логов
  docker journald (docker info), restart: unless-stopped и драйвер логов
  journald у контейнеров проекта (созданные до смены драйвера — FAIL с
  подсказкой --force-recreate), порт замера, стек поднят из каталога
  развёртывания (метка com.docker.compose.project.working_dir контейнеров
  проекта). Диск дистрибутива разреженный (атрибут SparseFile ext4.vhdx).
  Сеть и память: .wslconfig с nat, sparseVhd=true и autoMemoryReclaim=gradual —
  каждый ключ звеном, правило firewall Windows, профили firewall Domain, Private и Public —
  каждый звеном (включён, входящие по умолчанию блокируются), адрес в ЛВС,
  записи portproxy на нём,
  IP Helper, слушатель portproxy на адресе и /health на 127.0.0.1, [::1] и
  адресе в ЛВС — все в итоге. Адрес в ЛВС в вывод не попадает.

  -Uninstall — снос движка (терминал администратора), без отката куда-либо:
    1. если дистрибутив работает — docker compose --profile ha stop внутри
       него, в каталоге развёртывания; отказ — выход до любых удалений. Не работает — стек
       не трогается (дистрибутив ради этого не запускается);
    2. задачи domovoy-engine и domovoy-measure-boot снимаются, работающая
       держалка перед этим останавливается;
    3. расписание бэкапа снимается — ops/backup/install-schedule.ps1
       -Uninstall: без движка задача ночью будила бы WSL;
    4. wsl --terminate domovoy-engine;
    5. свои записи portproxy (порты API и HA с целью 127.0.0.1 того же
       порта, на любом адресе), правило firewall Windows domovoy-engine-ports
       и прежнее правило Hyper-V с тем же именем удаляются;
    6. .wslconfig возвращается из .wslconfig.domovoy-backup или, при отметке
       .wslconfig.domovoy-absent, удаляется; копия и отметка расходуются.
  Откат к 0028 (mirrored и правило Hyper-V) — этот -Uninstall, затем -Install
  версии 0028 (запись 0030, «Откат»).
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
    [switch]$DryRun,
    [string]$WslConfigPath = (Join-Path $env:USERPROFILE '.wslconfig'),
    [string]$DistroDir = (Join-Path $env:LOCALAPPDATA 'domovoy-engine'),
    # Только с -DryRun: подмена состояния держалки и дистрибутива для теста
    # (deploy/windows/engine-setup.test.sh). Без него состояние читается с хоста.
    # Absent — дистрибутив не зарегистрирован (движок не установлен).
    [ValidateSet('', 'Running', 'Stopped', 'Absent')]
    [string]$AssumeEngineState = '',
    # Только с -DryRun: подмена адреса прослушивания portproxy для теста —
    # вывод сухого прогона не зависит от сети машины. Без него адрес
    # выбирается по маршрутам хоста (Select-ListenAddress).
    [string]$AssumeListenAddress = '',
    # Только с -DryRun: подмена типа запуска службы IP Helper для теста —
    # вывод и код сухого прогона не зависят от службы машины.
    [ValidateSet('', 'Automatic', 'Manual', 'Disabled')]
    [string]$AssumeIpHelperStartType = '',
    # Только с -DryRun: подмена профилей firewall Windows для теста. None —
    # все три включены и блокируют входящие; имя профиля — этот пропускает
    # входящие по умолчанию.
    [ValidateSet('', 'None', 'Domain', 'Private', 'Public')]
    [string]$AssumeOpenFirewallProfile = '',
    # Каталог развёртывания внутри дистрибутива: оттуда настройки стека,
    # бэкап, зонд замера и остановка при сносе (#162).
    [string]$DeployDir = '/srv/domovoy',
    # Только с -DryRun: подмена настроек каталога развёртывания для теста,
    # 'KEY=значение;KEY=значение' — ключи белого списка deploy/envfile.sh get.
    # Каталог развёртывания при этом считается настроенным.
    [string]$AssumeDeploySettings = '',
    # Только с -DryRun: wsl.exe для теста (подделка пишет вызовы).
    [string]$WslExe = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Distro = 'domovoy-engine'
$KeeperTask = 'domovoy-engine'
$MeasureTask = 'domovoy-measure-boot'
$BackupTask = 'domovoy-backup'
# Имя правила firewall Windows. Правило Hyper-V firewall с тем же именем
# ставил -Install по 0028 — -Install и -Uninstall его снимают.
$RuleName = 'domovoy-engine-ports'
$ImageBase = 'https://cloud-images.ubuntu.com/wsl/releases/24.04/current'
$ImageFile = 'ubuntu-noble-wsl-amd64-24.04lts.rootfs.tar.gz'
# Источники правила — только локальная подсеть: с самого хоста стек идёт
# через петлю (wslrelay), правило ей не нужно.
$RemoteAddresses = @('LocalSubnet')
# Цель portproxy: петля, которую в NAT слушает wslrelay. Не адрес ВМ — он
# меняется на каждой загрузке (0028, «Отвергнутые варианты»).
$ProxyTarget = '127.0.0.1'
# Записи portproxy v4tov4 TCP — их хранит служба IP Helper (iphlpsvc).
$PortProxyKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\PortProxy\v4tov4\tcp'
$IpHelperService = 'iphlpsvc'
# Юниты автозапуска в systemd дистрибутива. domovoy-mss-clamp — MSS 1340 для
# трафика контейнеров (provision-engine.sh): без него HTTPS из сети моста
# через интерфейс с MTU меньше 1500 (VPN хоста) висит.
$EngineUnits = @('docker.service', 'containerd.service', 'domovoy-mss-clamp.service')
# Oneshot с RemainAfterExit=yes: в -Check — и is-enabled, и is-active.
$OneshotUnits = @('domovoy-mss-clamp.service')
# Профиль сети правила: только частная — в общественной сети порты закрыты.
# Хост — ноутбук: без профиля LocalSubnet чужой Wi-Fi видел бы порты стека.
$RuleProfile = 'Private'

function Stop-WithError([string]$Message, [int]$Code = 1) {
    [Console]::Error.WriteLine("engine-setup: $Message")
    exit $Code
}

$modeCount = @($Install, $Check, $Uninstall | Where-Object { $_ }).Count
if ($modeCount -gt 1) { Stop-WithError 'укажите один режим: -Install, -Check или -Uninstall' 2 }
if ($modeCount -eq 0) { Stop-WithError 'укажите режим: -Install, -Check или -Uninstall' 2 }
if ($DryRun -and $Check) { Stop-WithError '-DryRun — только с -Install или -Uninstall' 2 }
if ($AssumeEngineState -and -not $DryRun) { Stop-WithError '-AssumeEngineState — только с -DryRun' 2 }
if ($AssumeIpHelperStartType -and -not $DryRun) { Stop-WithError '-AssumeIpHelperStartType — только с -DryRun' 2 }
if ($AssumeOpenFirewallProfile -and -not $DryRun) { Stop-WithError '-AssumeOpenFirewallProfile — только с -DryRun' 2 }
if ($AssumeListenAddress) {
    if (-not $DryRun) { Stop-WithError '-AssumeListenAddress — только с -DryRun' 2 }
    # IPv4 одного узла: петля и подстановочный адрес дали бы петлю portproxy.
    $assumed = $null
    if (-not [Net.IPAddress]::TryParse($AssumeListenAddress, [ref]$assumed) -or
        $assumed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        @(0, 127) -contains [int]$assumed.GetAddressBytes()[0]) {
        Stop-WithError '-AssumeListenAddress — IPv4-адрес узла (не петля и не 0.0.0.0)' 2
    }
}
if ($AssumeDeploySettings -and -not $DryRun) { Stop-WithError '-AssumeDeploySettings — только с -DryRun' 2 }
if ($WslExe -and -not $DryRun) { Stop-WithError '-WslExe — только с -DryRun' 2 }
# Абсолютный путь Linux без пробелов, кавычек и сегментов . и ..: он уходит
# в аргументы wsl.exe и задач Планировщика.
if ($DeployDir -cnotmatch '^(/[A-Za-z0-9_][A-Za-z0-9._-]*)+$') {
    Stop-WithError "-DeployDir — абсолютный путь внутри дистрибутива (/srv/domovoy), без пробелов и кавычек: «$DeployDir»" 2
}

# Ключи настроек каталога развёртывания — белый список deploy/envfile.sh get
# (GET_KEYS): -AssumeDeploySettings вне его не принимается.
$DeploySettingKeys = @('API_HTTP_PORT', 'HA_HTTP_PORT', 'COMPOSE_PROJECT_NAME', 'BACKUP_DIR', 'BACKUP_MAX_SIZE_GB', 'COMPOSE_FILE', 'DOMOVOY_IMAGE_REPO', 'DOMOVOY_IMAGE_TAG')
# Настройки стека, которые читает этот сценарий.
$StackSettingKeys = @('API_HTTP_PORT', 'HA_HTTP_PORT', 'COMPOSE_PROJECT_NAME')

# 'KEY=значение;KEY=значение' -> хеш-таблица; $null — форма не та или ключ
# вне белого списка.
function ConvertFrom-AssumedSettings([string]$Text, [string[]]$Allowed) {
    $values = @{}
    foreach ($part in ($Text -split ';')) {
        $m = [regex]::Match($part, '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$')
        if (-not $m.Success -or $Allowed -cnotcontains $m.Groups[1].Value) { return $null }
        $values[$m.Groups[1].Value] = $m.Groups[2].Value
    }
    return $values
}

$assumedSettings = $null
if ($AssumeDeploySettings) {
    $assumedSettings = ConvertFrom-AssumedSettings $AssumeDeploySettings $DeploySettingKeys
    if ($null -eq $assumedSettings) {
        Stop-WithError ("-AssumeDeploySettings — 'KEY=значение;KEY=значение', ключи: {0}" -f ($DeploySettingKeys -join ', ')) 2
    }
}

$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).ProviderPath
$composeFile = Join-Path $root 'docker-compose.yml'
$measureScript = Join-Path $root 'deploy\windows\measure-boot.ps1'
$scheduleScript = Join-Path $root 'ops\backup\install-schedule.ps1'
# $WslExe и $wslExe — одна переменная (имена без учёта регистра): подделка
# запоминается до замены.
$wslFake = $WslExe
$wslExe = if ($wslFake) { $wslFake } else { Join-Path $env:SystemRoot 'System32\wsl.exe' }
$invariant = [Globalization.CultureInfo]::InvariantCulture

# Значение по умолчанию переменной из docker-compose.yml: ${KEY:-значение}.
function Get-ComposeDefault([string]$Key) {
    if (-not (Test-Path -LiteralPath $composeFile -PathType Leaf)) { return '' }
    $m = [regex]::Match([IO.File]::ReadAllText($composeFile), '\$\{' + [regex]::Escape($Key) + ':-([^}]*)\}')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

# Значение настройки: из каталога развёртывания ($deploySettings, ниже),
# пустое или не прочитанное — значение по умолчанию из docker-compose.yml.
function Get-Setting([string]$Key) {
    $value = ''
    if ($deploySettings.Values.ContainsKey($Key)) { $value = [string]$deploySettings.Values[$Key] }
    if (-not $value) { $value = Get-ComposeDefault $Key }
    return $value
}

function Get-Port([string]$Key) {
    $value = Get-Setting $Key
    $port = 0
    if (-not [int]::TryParse($value, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        Stop-WithError "$Key — не порт: «$value» (.env каталога развёртывания или значение по умолчанию в docker-compose.yml)" 2
    }
    return $port
}

# Кодировка, в которой PowerShell читает вывод внешней программы из канала, —
# [Console]::OutputEncoding (в русской Windows — CP866). bash, docker и wsl.exe
# с WSL_UTF8 пишут UTF-8: без переключения русский вывод backup.sh и
# restore.sh приходит в чужой кодировке. Дочерний PowerShell пишет в
# кодировке консоли — для него не переключается. Без консоли (вывод
# перенаправлен) установка может бросить — тогда кодировка не меняется.
function Set-NativeOutputEncoding([string]$Exe) {
    $previous = $null
    if ($Exe -ieq (Get-Process -Id $PID).Path) { return $previous }
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
    $encoding = Set-NativeOutputEncoding $Exe
    try {
        & $Exe @Arguments 2>&1 | ForEach-Object {
            if ($_ -is [System.Management.Automation.ErrorRecord]) { $err.Add([string]$_) } else { $out.Add([string]$_) }
        }
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
        Restore-NativeOutputEncoding $encoding
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

# Новое содержимое .wslconfig, прочее не трогается: nat в [wsl2] (запись
# 0030) и в [experimental] sparseVhd=true и autoMemoryReclaim=gradual (#162).
# В NAT 127.0.0.1 и ::1 хоста принимает wslrelay и доводит до движка — для
# этого нужен localhostForwarding, он включён по умолчанию.
# Changed = $false — файл уже такой. Conflicts — чужие настройки парами
# ключ=значение (Conflict — они же строкой): networkingMode не nat,
# localhostForwarding=false, sparseVhd не true, autoMemoryReclaim не
# gradual; при них файл не меняется. Missing — ключи, которые -Install
# дописывает. Исключение из конфликтов — свой mirrored: его записал -Install
# по 0028, и рядом лежит копия .domovoy-backup или отметка .domovoy-absent —
# он переписывается на nat на месте, OwnMirrored = $true. firewall=false не
# мешает: порты стека на адресе хоста закрывает firewall Windows, а не
# firewall Hyper-V для VM WSL. Ключ ищется во всём файле, без учёта секции —
# как networkingMode.
function Get-WslConfigPlan([string]$Path) {
    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    $current = if ($exists) { [IO.File]::ReadAllText($Path) } else { '' }
    $owned = (Test-Path -LiteralPath "$Path.domovoy-backup" -PathType Leaf) -or (Test-Path -LiteralPath "$Path.domovoy-absent" -PathType Leaf)
    $conflicts = @()
    $conflictKeys = @()
    $missing = @()
    $ownMirrored = $false
    $forwarding = [regex]::Match($current, '(?im)^\s*localhostForwarding\s*=\s*(\S+)\s*$')
    if ($forwarding.Success -and $forwarding.Groups[1].Value -ieq 'false') {
        $conflicts += "localhostForwarding=$($forwarding.Groups[1].Value)"; $conflictKeys += 'localhostForwarding'
    }
    $content = $current
    $mode = [regex]::Match($current, '(?im)^\s*networkingMode\s*=\s*(\S+)\s*$')
    if ($mode.Success) {
        $value = $mode.Groups[1].Value
        if ($value -ieq 'mirrored' -and $owned) {
            # Замена значения в той же строке: отступ, пробелы у «=» и
            # перевод строки остаются как в файле.
            $line = '(?im)^([ \t]*networkingMode[ \t]*=[ \t]*)mirrored(?=[ \t]*\r?$)'
            $content = ([regex]$line).Replace($current, '${1}nat', 1)
            # Строка не той формы — не заменена: отказ, а не запись mirrored.
            if ($content -ceq $current) { $conflicts += "networkingMode=$value"; $conflictKeys += 'networkingMode' }
            else { $ownMirrored = $true }
        }
        elseif ($value -ine 'nat') { $conflicts += "networkingMode=$value"; $conflictKeys += 'networkingMode' }
    }
    else { $missing += 'networkingMode' }
    $experimental = [ordered]@{ sparseVhd = 'true'; autoMemoryReclaim = 'gradual' }
    foreach ($key in $experimental.Keys) {
        $found = [regex]::Match($current, '(?im)^\s*' + $key + '\s*=\s*(\S+)\s*$')
        if (-not $found.Success) { $missing += $key }
        elseif ($found.Groups[1].Value -ine $experimental[$key]) { $conflicts += "$key=$($found.Groups[1].Value)"; $conflictKeys += $key }
    }
    if ($conflicts.Count) {
        return [pscustomobject]@{ Exists = $exists; Changed = $false; Conflict = ($conflicts -join '; '); Conflicts = $conflicts; ConflictKeys = $conflictKeys
            Missing = $missing; Content = $current; OwnMirrored = $false }
    }
    # Перевод строки — тот, что в файле: без CRLF остаётся LF; новый или с
    # CRLF — CRLF.
    $newline = if ($current -and -not $current.Contains("`r`n") -and $current.Contains("`n")) { "`n" } else { "`r`n" }
    if ($missing -contains 'networkingMode') {
        # Вставка — перед переводом строки после [wsl2] и тем же переводом,
        # что в файле. \s в заголовке захватил бы CR: в .NET $ при (?m)
        # стоит только перед LF.
        $wsl2 = '(?im)^([ \t]*\[wsl2\][ \t]*)(?=\r?$)'
        if ($content -match $wsl2) {
            # Экземпляр, а не [regex]::Replace: у статического четвёртый
            # аргумент — RegexOptions, а не число замен.
            $content = ([regex]$wsl2).Replace($content, "`$1${newline}networkingMode=nat", 1)
        }
        elseif ($content.Trim()) {
            $content = $content.TrimEnd() + "$newline$newline[wsl2]${newline}networkingMode=nat$newline"
        }
        else {
            $content = "[wsl2]${newline}networkingMode=nat$newline"
        }
    }
    $add = @($experimental.Keys | Where-Object { $missing -contains $_ } | ForEach-Object { "$_=$($experimental[$_])" })
    if ($add.Count) {
        # Секция [experimental] есть — ключи сразу после заголовка, тем же
        # способом, что nat после [wsl2]; нет — секция в конце файла.
        $section = '(?im)^([ \t]*\[experimental\][ \t]*)(?=\r?$)'
        if ($content -match $section) {
            $content = ([regex]$section).Replace($content, "`$1$newline" + ($add -join $newline), 1)
        }
        else {
            $content = $content.TrimEnd() + "$newline$newline[experimental]$newline" + ($add -join $newline) + $newline
        }
    }
    return [pscustomobject]@{ Exists = $exists; Changed = ($content -cne $current); Conflict = ''; Conflicts = @(); ConflictKeys = @()
        Missing = $missing; Content = $content; OwnMirrored = $ownMirrored }
}

# Звено -Check «.wslconfig: networkingMode=nat» по плану Get-WslConfigPlan:
# State OK или FAIL и деталь — только по networkingMode и
# localhostForwarding. Свой mirrored прежней установки — не «не задан»:
# значение задано, и его переписывает -Install.
function Get-WslConfigCheck($Plan) {
    $own = @($Plan.Conflicts | Where-Object { $_ -match '^(networkingMode|localhostForwarding)=' })
    if ($own.Count) { return [pscustomobject]@{ State = 'FAIL'; Detail = "задан $($own -join '; ')" } }
    if ($Plan.OwnMirrored) { return [pscustomobject]@{ State = 'FAIL'; Detail = 'задан mirrored прежней установки — engine-setup.ps1 -Install, затем wsl --shutdown' } }
    if (@($Plan.Missing) -contains 'networkingMode') { return [pscustomobject]@{ State = 'FAIL'; Detail = 'не задан — engine-setup.ps1 -Install, затем wsl --shutdown' } }
    return [pscustomobject]@{ State = 'OK'; Detail = '' }
}

# Звено -Check «.wslconfig: <ключ>» по ключу [experimental] (sparseVhd,
# autoMemoryReclaim) по плану Get-WslConfigPlan: только по этому ключу.
function Get-WslConfigKeyCheck($Plan, [string]$Key) {
    $own = @($Plan.Conflicts | Where-Object { $_ -like "$Key=*" })
    if ($own.Count) { return [pscustomobject]@{ State = 'FAIL'; Detail = "задан $($own -join '; ') — чужая настройка, -Install её не переписывает" } }
    if (@($Plan.Missing) -contains $Key) { return [pscustomobject]@{ State = 'FAIL'; Detail = 'не задан — engine-setup.ps1 -Install, затем wsl --shutdown' } }
    return [pscustomobject]@{ State = 'OK'; Detail = '' }
}

# Путь ext4.vhdx дистрибутива по записям реестра
# HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss\{guid} (объекты с
# DistributionName и BasePath): имя — без учёта регистра; BasePath может
# прийти с префиксом \\?\. '' — записи нет.
function Select-DistroDiskPath($Entries, [string]$Name) {
    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) { continue }
        $nameProp = $entry.PSObject.Properties['DistributionName']
        $baseProp = $entry.PSObject.Properties['BasePath']
        if (-not $nameProp -or -not $baseProp -or [string]$nameProp.Value -ine $Name) { continue }
        $base = [string]$baseProp.Value
        if ($base.StartsWith('\\?\')) { $base = $base.Substring(4) }
        if (-not $base) { continue }
        return ($base.TrimEnd('\') + '\ext4.vhdx')
    }
    return ''
}

# Записи Lxss текущего пользователя — только чтение реестра.
function Get-DistroDiskPath([string]$Name) {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path -LiteralPath $key)) { return '' }
    $entries = @(Get-ChildItem -LiteralPath $key -ErrorAction SilentlyContinue | ForEach-Object { Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue })
    return Select-DistroDiskPath $entries $Name
}

# Атрибуты файла диска; $null — файла нет.
function Get-DiskAttributes([string]$Path) {
    if (-not $Path) { return $null }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item) { return $null }
    return $item.Attributes
}

# Звено -Check «диск дистрибутива разреженный»: атрибут SparseFile у
# ext4.vhdx. $Attributes — [IO.FileAttributes] или $null, если файла нет.
function Get-SparseDiskCheck([string]$Path, $Attributes) {
    if (-not $Path) { return [pscustomobject]@{ State = 'FAIL'; Detail = 'путь ext4.vhdx дистрибутива не найден в HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss' } }
    if ($null -eq $Attributes) { return [pscustomobject]@{ State = 'FAIL'; Detail = "нет файла $Path" } }
    if (([IO.FileAttributes]$Attributes -band [IO.FileAttributes]::SparseFile) -ne 0) { return [pscustomobject]@{ State = 'OK'; Detail = "SparseFile: $Path" } }
    return [pscustomobject]@{ State = 'FAIL'; Detail = "у $Path нет атрибута SparseFile — engine-setup.ps1 -Install (wsl --manage --set-sparse true при остановленном дистрибутиве)" }
}

# Разреженный диск дистрибутива: wsl --manage <имя> --set-sparse true, без
# --allow-unsafe. '' — сделано; иначе текст отказа wsl и что делать
# владельцу. Не обрывает -Install: остальные шаги доводятся, отказ уходит в
# ненулевой код в конце; звено -Check «диск дистрибутива разреженный»
# остаётся красным, пока диск не разрежен.
function Set-DistroSparse([string]$Name) {
    $result = Invoke-Wsl @('--manage', $Name, '--set-sparse', 'true')
    if ($result.Code -eq 0) { return '' }
    return "wsl --manage $Name --set-sparse true: код $($result.Code): $(Format-Native $result) — диск дистрибутива не разреженный. Флаг --allow-unsafe сценарий не ставит: если WSL требует его из-за риска порчи данных, решение за владельцем (wsl --version, wsl --manage $Name --set-sparse true вручную при остановленном дистрибутиве); повторный -Install попробует снова"
}

# Аргументы wsl.exe: метка working_dir каждого контейнера проекта, строкой
# на контейнер. Имя метки — строкой Go в обратных кавычках: двойные кавычки
# Windows PowerShell 5.1 в аргументах внешней программы не экранирует.
function Get-WorkingDirQuery([string]$Distro, [string]$Project) {
    return @('-d', $Distro, '-u', 'root', '--exec', 'docker', 'ps', '-a', '--filter', "label=com.docker.compose.project=$Project",
        '--format', '{{.Label `com.docker.compose.project.working_dir`}}')
}

# Звено -Check «стек поднят из каталога развёртывания»: метки working_dir
# всех контейнеров проекта равны $DeployDir (без / в конце). Контейнеров
# нет или у контейнера нет метки — FAIL: проверять нечего.
function Get-StackWorkingDirCheck([string[]]$WorkingDirs, [string]$DeployDir) {
    $dirs = @($WorkingDirs | Where-Object { $null -ne $_ } | ForEach-Object { ([string]$_).Trim() })
    if (-not $dirs.Count) { return [pscustomobject]@{ State = 'FAIL'; Detail = 'контейнеров проекта нет' } }
    $want = $DeployDir.TrimEnd('/')
    $other = @($dirs | Where-Object { $_.TrimEnd('/') -cne $want } | Sort-Object -Unique)
    if ($other.Count) {
        $shown = @($other | ForEach-Object { if ($_) { $_ } else { '(без метки)' } }) -join ', '
        return [pscustomobject]@{ State = 'FAIL'; Detail = "контейнеры подняты из $shown, а не из $DeployDir — стек поднят не из каталога развёртывания" }
    }
    return [pscustomobject]@{ State = 'OK'; Detail = "$($dirs.Count) контейнеров, $DeployDir" }
}

# Как сохраняется прежнее состояние .wslconfig перед записью: копия или
# отметка уже есть — ничего. Они описывают файл до первого -Install, и
# копия своего mirrored поверх них вернула бы при -Uninstall mirrored.
# backup — копия .domovoy-backup, absent — отметка .domovoy-absent.
function Get-WslConfigSave([string]$Path, [bool]$Exists) {
    if ((Test-Path -LiteralPath "$Path.domovoy-backup" -PathType Leaf) -or (Test-Path -LiteralPath "$Path.domovoy-absent" -PathType Leaf)) { return 'none' }
    if ($Exists) { return 'backup' }
    return 'absent'
}

# Профиль правила — только Private. Прочитанное правило отдаёт Profiles
# перечислением или числом (2 — Private); Any (0) и сочетания с Public —
# нет. Та же функция — в сухом прогоне и в -Check.
function Test-PrivateProfileOnly($Value) {
    $text = [string]$Value
    return ($text -eq 'Private' -or $text -eq '2')
}

# Профиль firewall Windows (Get-NetFirewallProfile, ActiveStore): закрыт,
# только пока включён и по умолчанию блокирует входящие. Значения —
# перечисления; сравнивается их текст. В хранилище по умолчанию без явной
# настройки стоит NotConfigured — не OK. Пустой список — замечаний нет.
function Get-FirewallProfileProblems($Setting) {
    $found = @()
    if ([string]$Setting.Enabled -ne 'True') { $found += "Enabled $($Setting.Enabled), нужен True" }
    if ([string]$Setting.DefaultInboundAction -ne 'Block') { $found += "DefaultInboundAction $($Setting.DefaultInboundAction), нужен Block" }
    return $found
}

# Все три профиля firewall Windows — закрытость портов стека держат они
# вместе. В Private правило пропускает только локальную подсеть, и то, пока
# профиль блокирует остальное. В Public и Domain правила нет: слушатель
# portproxy привязан к адресу, а не к сети, и сеть того же адреса с другим
# профилем (сеть сменила профиль, чужая сеть с тем же адресом) закрывает
# только блокировка входящих по умолчанию. Запись на профиль — Name и
# Problems; профиль, которого нет среди прочитанных, — замечание.
function Get-FirewallProfileStates($Settings) {
    $states = @()
    foreach ($name in 'Domain', 'Private', 'Public') {
        $setting = @($Settings | Where-Object { $null -ne $_ -and [string]$_.Name -eq $name })
        if (-not $setting.Count) { $states += [pscustomobject]@{ Name = $name; Problems = @('профиль не прочитан') }; continue }
        $states += [pscustomobject]@{ Name = $name; Problems = @(Get-FirewallProfileProblems $setting[0]) }
    }
    return $states
}

# Адрес прослушивания portproxy. Кандидат — IPv4-адрес интерфейса с
# маршрутом по умолчанию (0.0.0.0/0) и профилем сети Private (перечисление
# NetworkCategory: Private — 1; DomainAuthenticated — 2 — не кандидат),
# кроме петли, 0.0.0.0 и APIPA 169.254/16. Вес — наименьшая RouteMetric
# маршрута по умолчанию интерфейса плюс его InterfaceMetric, как считает
# Windows. Берётся кандидат с наименьшим весом; ни одного или два с равным
# наименьшим (в том числе два адреса одного интерфейса) — отказ с причиной:
# выбор наугад открыл бы стек не там. Входы — объекты с InterfaceIndex и
# RouteMetric (Get-NetRoute), InterfaceMetric (Get-NetIPInterface),
# NetworkCategory (Get-NetConnectionProfile), IPAddress (Get-NetIPAddress).
# Причина адресов не называет: адрес хоста в вывод не попадает.
function Select-ListenAddress($Routes, $Interfaces, $Profiles, $Addresses) {
    $candidates = @()
    foreach ($entry in @($Addresses)) {
        if ($null -eq $entry) { continue }
        $ip = $null
        if (-not [Net.IPAddress]::TryParse([string]$entry.IPAddress, [ref]$ip)) { continue }
        if ($ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { continue }
        $bytes = $ip.GetAddressBytes()
        if ($bytes[0] -eq 0 -or $bytes[0] -eq 127 -or ($bytes[0] -eq 169 -and $bytes[1] -eq 254)) { continue }
        $index = [int]$entry.InterfaceIndex
        $categories = @($Profiles | Where-Object { $null -ne $_ -and [int]$_.InterfaceIndex -eq $index } | ForEach-Object { [string]$_.NetworkCategory })
        if (-not $categories.Count -or @($categories | Where-Object { $_ -ne 'Private' -and $_ -ne '1' }).Count) { continue }
        $routeMetrics = @($Routes | Where-Object { $null -ne $_ -and [int]$_.InterfaceIndex -eq $index } | ForEach-Object { [int]$_.RouteMetric })
        $interfaceMetrics = @($Interfaces | Where-Object { $null -ne $_ -and [int]$_.InterfaceIndex -eq $index } | ForEach-Object { [int]$_.InterfaceMetric })
        if (-not $routeMetrics.Count -or -not $interfaceMetrics.Count) { continue }
        $weight = [int](($routeMetrics | Measure-Object -Minimum).Minimum + ($interfaceMetrics | Measure-Object -Minimum).Minimum)
        $candidates += [pscustomobject]@{ Address = $ip.ToString(); Index = $index; Weight = $weight }
    }
    if (-not $candidates.Count) {
        return [pscustomobject]@{ Address = ''; Reason = 'нет IPv4-адреса в частной сети с маршрутом по умолчанию (профиль сети Private; петля, 0.0.0.0 и APIPA не в счёт) — сеть хоста частная и подключена?' }
    }
    $least = [int](($candidates | Measure-Object -Property Weight -Minimum).Minimum)
    $best = @($candidates | Where-Object { $_.Weight -eq $least })
    if ($best.Count -gt 1) {
        $indexes = (@($best | ForEach-Object { $_.Index } | Sort-Object -Unique) -join ', ')
        return [pscustomobject]@{ Address = ''; Reason = "наименьший вес $least (метрика маршрута по умолчанию + метрика интерфейса) у $($best.Count) адресов, интерфейсы $indexes — выбор неоднозначен: оставьте один адрес в частной сети или задайте интерфейсам разные метрики" }
    }
    return [pscustomobject]@{ Address = $best[0].Address; Reason = '' }
}

# Запись portproxy в форме реестра (PortProxy\v4tov4\tcp): имя —
# «адрес/порт» прослушивания, значение — «адрес/порт» цели. Порт, который не
# разобран, — 0.
function ConvertFrom-PortProxyEntry($Entry) {
    $ends = foreach ($text in @([string]$Entry.Name, [string]$Entry.Value)) {
        $slash = $text.LastIndexOf('/')
        $port = 0
        if ($slash -lt 0 -or -not [int]::TryParse($text.Substring($slash + 1), [ref]$port)) { $slash = $text.Length; $port = 0 }
        [pscustomobject]@{ Address = $text.Substring(0, $slash); Port = $port }
    }
    return [pscustomobject]@{ Name = [string]$Entry.Name; ListenAddress = $ends[0].Address; ListenPort = $ends[0].Port; ConnectAddress = $ends[1].Address; ConnectPort = $ends[1].Port }
}

# Свои записи portproxy: порт стека с целью 127.0.0.1 того же порта — на
# любом адресе прослушивания. Их снимает -Uninstall, а -Install — те, что на
# прежнем адресе. Чужие (другой порт или другая цель) не трогаются.
function Select-OwnPortProxy($Entries, $Ports) {
    $wanted = @($Ports | ForEach-Object { [int]$_ })
    return @($Entries | Where-Object { $null -ne $_ } | ForEach-Object { ConvertFrom-PortProxyEntry $_ } | Where-Object {
            $wanted -contains $_.ListenPort -and $_.ConnectAddress -eq '127.0.0.1' -and $_.ConnectPort -eq $_.ListenPort })
}

# Порты стека, на которых по адресу $Address стоит чужая запись — та, что
# Select-OwnPortProxy своей не считает. Адрес в ответе не возвращается.
function Select-ForeignPortProxyPorts($Entries, [string]$Address, $Ports) {
    $wanted = @($Ports | ForEach-Object { [int]$_ })
    $own = @(Select-OwnPortProxy $Entries $Ports | ForEach-Object { $_.Name })
    return @($Entries | Where-Object { $null -ne $_ } | ForEach-Object { ConvertFrom-PortProxyEntry $_ } | Where-Object {
            $_.ListenAddress -eq $Address -and $wanted -contains $_.ListenPort -and $own -notcontains $_.Name } |
        ForEach-Object { $_.ListenPort } | Sort-Object -Unique)
}

# Записи portproxy портов стека против нужного: на каждый порт ровно одна
# запись — с адреса $Address на 127.0.0.1 того же порта. Подстановочный
# адрес или петля в прослушивании — петля portproxy → 127.0.0.1 →
# portproxy. Замечание называет порт, но не адрес. Записи других портов не
# проверяются. Пустой список — замечаний нет.
function Get-PortProxyProblems($Entries, [string]$Address, $Ports) {
    $parsed = @($Entries | Where-Object { $null -ne $_ } | ForEach-Object { ConvertFrom-PortProxyEntry $_ })
    $found = @()
    foreach ($port in @($Ports | ForEach-Object { [int]$_ })) {
        $mine = @($parsed | Where-Object { $_.ListenPort -eq $port })
        if (-not $mine.Count) { $found += "порт ${port}: записи portproxy нет — engine-setup.ps1 -Install"; continue }
        if ($mine.Count -gt 1) { $found += "порт ${port}: записей portproxy $($mine.Count), нужна одна — engine-setup.ps1 -Install" }
        foreach ($e in $mine) {
            $listen = $e.ListenAddress
            if (-not $listen -or $listen -eq '*' -or $listen -eq '0.0.0.0' -or $listen -like '127.*' -or $listen -ieq 'localhost') {
                $found += "порт ${port}: portproxy слушает подстановочный адрес или петлю — петля через 127.0.0.1; снимите запись (netsh interface portproxy delete v4tov4) и -Install"
            }
            elseif ($listen -ne $Address) {
                $found += "порт ${port}: запись portproxy на другом адресе — адрес хоста в ЛВС сменился; engine-setup.ps1 -Install"
            }
            if ($e.ConnectAddress -ne '127.0.0.1' -or $e.ConnectPort -ne $port) {
                $found += "порт ${port}: цель portproxy не 127.0.0.1:$port"
            }
        }
    }
    return $found
}

# Правило firewall Windows по свойствам Get-NetFirewallRule и его фильтров
# (поля Enabled, Direction, Action, Protocol, LocalPorts, RemoteAddresses,
# Profiles, Program, Service): включено, входящие, Allow, TCP, источники —
# только LocalSubnet, профиль — только Private, порты — ровно порты стека,
# программа и служба — слушатель portproxy: svchost.exe службы iphlpsvc
# ($IpHelperService). Путь программы правило хранит как задан — с
# %SystemRoot% или в другом регистре. Пустой список — замечаний нет.
function Get-HostRuleProblems($Rule, $Ports) {
    $found = @()
    $svchost = Join-Path $env:SystemRoot 'System32\svchost.exe'
    if ([Environment]::ExpandEnvironmentVariables([string]$Rule.Program) -ine $svchost) {
        $found += "программа $($Rule.Program), нужна svchost.exe: правило шире слушателя portproxy"
    }
    if ([string]$Rule.Service -ine 'iphlpsvc') { $found += "служба $($Rule.Service), нужна iphlpsvc: правило шире слушателя portproxy" }
    if ([string]$Rule.Enabled -ne 'True') { $found += 'правило выключено' }
    if ([string]$Rule.Direction -ne 'Inbound') { $found += "направление $($Rule.Direction), нужно Inbound" }
    if ([string]$Rule.Action -ne 'Allow') { $found += "действие $($Rule.Action), нужно Allow" }
    if ([string]$Rule.Protocol -ne 'TCP') { $found += "протокол $($Rule.Protocol), нужен TCP" }
    $addresses = @($Rule.RemoteAddresses | ForEach-Object { [string]$_ })
    if ($addresses.Count -ne 1 -or $addresses[0] -ne 'LocalSubnet') {
        $found += "источники — $($addresses.Count) значений, нужен только LocalSubnet: шире локальной подсети порты стека открыты"
    }
    if (-not (Test-PrivateProfileOnly $Rule.Profiles)) { $found += "профиль $($Rule.Profiles), нужен только Private: в общественной сети правило открывало бы порты" }
    $have = @($Rule.LocalPorts | ForEach-Object { [string]$_ })
    $want = @($Ports | ForEach-Object { [string]$_ })
    foreach ($port in $want) {
        if ($have -notcontains $port) { $found += "нет порта $port" }
    }
    $extra = @($have | Where-Object { $want -notcontains $_ })
    if ($extra.Count) { $found += 'порты шире стека: ' + ($extra -join ',') }
    return $found
}

# Интервал systemd в секундах: «10», «10s», «1min 30s», «500ms»; $null —
# не разобран. Единицы — systemd.time(7).
function ConvertFrom-SystemdTimeSpan([string]$Text) {
    $units = @{ '' = 1; 'us' = 1e-6; 'usec' = 1e-6; 'ms' = 1e-3; 'msec' = 1e-3; 's' = 1; 'sec' = 1; 'second' = 1; 'seconds' = 1
        'm' = 60; 'min' = 60; 'minute' = 60; 'minutes' = 60; 'h' = 3600; 'hr' = 3600; 'hour' = 3600; 'hours' = 3600 }
    $rest = $Text.Trim()
    if (-not $rest) { return $null }
    $total = 0.0
    while ($rest) {
        $m = [regex]::Match($rest, '^(\d+(?:\.\d+)?)\s*([a-z]*)\s*')
        if (-not $m.Success -or -not $units.ContainsKey($m.Groups[2].Value)) { return $null }
        $total += [double]::Parse($m.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture) * $units[$m.Groups[2].Value]
        $rest = $rest.Substring($m.Length)
    }
    return $total
}

# Настройка журнала systemd по выводу systemd-analyze cat-config
# systemd/journald.conf: нужны Storage=persistent и SyncIntervalSec не
# больше 10 с. Действует последнее присваивание (drop-in читаются после
# основного файла); строки # и ; — комментарии; без SyncIntervalSec или с
# пустым значением — 5 мин по умолчанию. Пустой список — замечаний нет.
function Get-JournaldProblems([string]$Text) {
    $storage = ''
    $sync = ''
    foreach ($raw in ($Text -split "`r?`n")) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#') -or $line.StartsWith(';') -or $line.StartsWith('[')) { continue }
        $m = [regex]::Match($line, '^(Storage|SyncIntervalSec)\s*=\s*(.*)$')
        if (-not $m.Success) { continue }
        if ($m.Groups[1].Value -eq 'Storage') { $storage = $m.Groups[2].Value.Trim() } else { $sync = $m.Groups[2].Value.Trim() }
    }
    $found = @()
    if ($storage -ne 'persistent') {
        $shown = if ($storage) { $storage } else { 'не задан (auto)' }
        $found += "Storage $shown, нужен persistent"
    }
    if (-not $sync) { $found += 'SyncIntervalSec не задан (по умолчанию 5 мин), нужен не больше 10 с' }
    else {
        $seconds = ConvertFrom-SystemdTimeSpan $sync
        if ($null -eq $seconds) { $found += "SyncIntervalSec «$sync» не разобран" }
        elseif ($seconds -gt 10) { $found += "SyncIntervalSec $sync, нужен не больше 10 с" }
    }
    return $found
}

# Драйвер логов контейнеров проекта по строкам docker inspect
# «/имя драйвер»: каждый должен быть journald. Строк меньше, чем
# контейнеров, — замечание, а не OK: пустой ответ не проверил ничего.
function Get-ContainerLogProblems([string[]]$Names, [string[]]$InspectLines) {
    $lines = @($InspectLines | Where-Object { $_ -and $_.Trim() })
    $found = @()
    if ($lines.Count -ne @($Names).Count) {
        $found += "драйверов логов $($lines.Count) из $(@($Names).Count) контейнеров"
    }
    $bad = @($lines | Where-Object { $_.Trim() -notmatch '\sjournald$' } | ForEach-Object { $_.Trim().TrimStart('/') })
    if ($bad.Count) {
        $found += ('не journald: {0} — созданы до смены драйвера; пересоздать: docker compose --profile ha up -d --force-recreate (через обёртку)' -f ($bad -join '; '))
    }
    return $found
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

# Записи portproxy v4tov4 TCP — из реестра: читаются без прав
# администратора и без разбора локализованного вывода netsh.
function Get-PortProxyRegistry {
    if (-not (Test-Path -LiteralPath $PortProxyKey)) { return @() }
    $key = Get-Item -LiteralPath $PortProxyKey
    return @($key.GetValueNames() | ForEach-Object { [pscustomobject]@{ Name = $_; Value = [string]$key.GetValue($_) } })
}

# Адрес прослушивания portproxy по маршрутам, метрикам и профилям сети хоста.
function Get-HostListenAddress {
    $routes = @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue)
    $interfaces = @(Get-NetIPInterface -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    $profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)
    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred -ErrorAction SilentlyContinue)
    return Select-ListenAddress $routes $interfaces $profiles $addresses
}

# netsh: вывод — в кодировке консоли, как его пишет netsh; stderr при 2>&1
# приходит записями ошибок, и при ErrorActionPreference Stop первая прервала
# бы сценарий.
function Invoke-Netsh([string[]]$Arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $text = (& (Join-Path $env:SystemRoot 'System32\netsh.exe') @Arguments 2>&1 | ForEach-Object { [string]$_ }) -join '; '
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
    return [pscustomobject]@{ Code = $code; Text = $text.Trim() }
}

# Правило Hyper-V firewall с именем $RuleName ставил -Install по 0028. На
# Windows без командлетов Hyper-V firewall (до 11 22H2) его не было.
# Get-NetFirewallHyperVRule -Name отдаёт под тем же именем и правило firewall
# Windows (VMCreatorId Any, источник HostFirewallLocal); его удаление
# командлетом Hyper-V — «Отказано в доступе» (живой -Install, #151). Прежнее
# правило отличает VMCreatorId WSL.
$WslVmCreatorId = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
function Remove-LegacyHyperVRule {
    if (-not (Get-Command Get-NetFirewallHyperVRule -ErrorAction SilentlyContinue)) { return "прежнего правила Hyper-V $RuleName нет (нет Get-NetFirewallHyperVRule)" }
    $legacy = @(Get-NetFirewallHyperVRule -Name $RuleName -ErrorAction SilentlyContinue | Where-Object { $_.VMCreatorId -eq $WslVmCreatorId })
    if ($legacy.Count) {
        $legacy | Remove-NetFirewallHyperVRule
        return "прежнее правило Hyper-V $RuleName удалено"
    }
    return "прежнего правила Hyper-V $RuleName нет"
}

# Состояние дистрибутива — до чтения настроек: чтение в -Install поднимает
# остановленный дистрибутив, а решение о держалке смотрит на состояние до
# запуска сценария.
$registered = (Get-WslNames @('--list', '--quiet')) -contains $Distro
$distroRunning = (Get-WslNames @('--list', '--running', '--quiet')) -contains $Distro
if ($AssumeEngineState) {
    $distroRunning = $AssumeEngineState -eq 'Running'
    if ($AssumeEngineState -eq 'Absent') { $registered = $false }
}

# Настройки стека из .env каталога развёртывания — только ключи
# $StackSettingKeys, через deploy/envfile.sh get. Source: deploy, assumed
# или defaults; Reason — причина defaults для сухого прогона (ASCII), Detail —
# она же для -Check и -Install; Error — каталог есть, а прочитать не
# удалось (не тихие значения по умолчанию).
function Read-DeploySettings {
    if ($null -ne $assumedSettings) {
        return [pscustomobject]@{ Source = 'assumed'; Reason = '-AssumeDeploySettings'; Detail = 'подменены -AssumeDeploySettings'; Error = ''; Values = $assumedSettings }
    }
    function Defaults([string]$Reason, [string]$Detail) {
        return [pscustomobject]@{ Source = 'defaults'; Reason = $Reason; Detail = $Detail; Error = ''; Values = @{} }
    }
    # -Install читает, если дистрибутив зарегистрирован (дистрибутив при
    # этом поднимается); прочие режимы и сухой прогон — только работающий.
    $read = if ($Install -and -not $DryRun) { $registered } else { $distroRunning }
    if (-not $registered -and -not $distroRunning) { return Defaults 'distro not registered' "дистрибутива $Distro нет" }
    if (-not $read) { return Defaults 'distro not running' "дистрибутив $Distro не работает — внутрь сценарий не заходит" }
    # Подменённое состояние без подделки wsl.exe: настоящий дистрибутив
    # сухой прогон не читает.
    if ($AssumeEngineState -and -not $wslFake) { return Defaults 'engine state assumed, distro not read' 'состояние движка подменено' }
    $present = Invoke-Wsl @('-d', $Distro, '-u', 'root', '--exec', 'test', '-f', "$DeployDir/.env", '-a', '-f', "$DeployDir/deploy/envfile.sh")
    if ($present.Code -eq 1) {
        return Defaults "deploy dir ${DeployDir}: no .env or deploy/envfile.sh" "в каталоге развёртывания $DeployDir нет .env или deploy/envfile.sh — стек ещё не перенесён"
    }
    if ($present.Code -ne 0) {
        return [pscustomobject]@{ Source = 'defaults'; Reason = ''; Detail = ''; Values = @{}
            Error = "проверка каталога развёртывания $DeployDir внутри ${Distro}: wsl.exe код $($present.Code): $(Format-Native $present)" }
    }
    $got = Invoke-Wsl (@('-d', $Distro, '-u', 'root', '--cd', $DeployDir, '--exec', 'bash', 'deploy/envfile.sh', 'get', '.env') + $StackSettingKeys)
    if ($got.Code -ne 0) {
        # Только stderr: get печатает значения лишь несекретных ключей, но
        # в отказе им взяться неоткуда.
        return [pscustomobject]@{ Source = 'defaults'; Reason = ''; Detail = ''; Values = @{}
            Error = "deploy/envfile.sh get в $DeployDir внутри ${Distro}: код $($got.Code): $($got.Err)" }
    }
    $values = @{}
    foreach ($line in $got.Lines) {
        $m = [regex]::Match([string]$line, '^([A-Z_][A-Z0-9_]*)=(.*)$')
        if ($m.Success -and $StackSettingKeys -ccontains $m.Groups[1].Value) { $values[$m.Groups[1].Value] = $m.Groups[2].Value.TrimEnd("`r") }
    }
    return [pscustomobject]@{ Source = 'deploy'; Reason = "$DeployDir/.env"; Detail = "$DeployDir/.env"; Error = ''; Values = $values }
}

$deploySettings = Read-DeploySettings
# Отказ чтения — до первого изменения; -Check показывает его звеном.
if ($deploySettings.Error -and -not $Check) { Stop-WithError "настройки стека не прочитаны: $($deploySettings.Error)" }

$apiPort = Get-Port 'API_HTTP_PORT'
$haPort = Get-Port 'HA_HTTP_PORT'
$stackPorts = @($apiPort, $haPort)
$project = Get-Setting 'COMPOSE_PROJECT_NAME'
$userId = [Security.Principal.WindowsIdentity]::GetCurrent().Name

# Строка сухого прогона об источнике настроек (ASCII).
function Format-SettingsSource {
    if ($deploySettings.Source -eq 'defaults') { return "settings.source: defaults ($($deploySettings.Reason))" }
    return "settings.source: $($deploySettings.Source) ($($deploySettings.Reason))"
}

# Предел ожидания состояния Running у задачи держалки после запуска.
$KeeperWaitSeconds = 30

# Держалка запускается заново; $true — задача дошла до State Running за
# предел времени. Задача зарегистрирована с MultipleInstances IgnoreNew:
# пока прежний экземпляр числится Running (wsl --terminate убивает его
# wsl.exe, а состояние задачи может отстать), Start-ScheduledTask молча
# ничего не делает. Поэтому прежний экземпляр сначала останавливается, а
# после запуска ожидается Running: иначе дистрибутив, поднятый чужим
# wsl.exe, погас бы по простою незаметно.
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

if ($Uninstall) {
    # Снос движка без отката. Состояние читается до любых действий: стек
    # останавливается, только пока дистрибутив работает, — запускать его
    # ради остановки сценарий не станет. Стек останавливается в каталоге
    # развёртывания: оттуда его поднимает deploy/update.sh.
    $engineRunning = $distroRunning
    $stopArgs = @('-d', $Distro, '-u', 'root', '--cd', $DeployDir, '--exec', 'docker', 'compose', '--profile', 'ha', 'stop')
    # Расписание бэкапа снимается: без движка задача ночью будила бы WSL.
    # У install-schedule.ps1 -Uninstall сухого прогона нет — -DryRun его
    # только печатает.
    $scheduleUninstallArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $scheduleScript, '-Uninstall')
    # Один список на план и на действие: что напечатано, то и снимается.
    $autostartTasks = @($KeeperTask, $MeasureTask)
    $wslBackup = "$WslConfigPath.domovoy-backup"
    $wslAbsent = "$WslConfigPath.domovoy-absent"
    $wslAction = 'keep'
    if (Test-Path -LiteralPath $wslBackup -PathType Leaf) { $wslAction = 'restore' }
    elseif (Test-Path -LiteralPath $wslAbsent -PathType Leaf) { $wslAction = 'remove' }

    if ($DryRun) {
        # ASCII, как строки сухого прогона -Install.
        Write-Output (Format-SettingsSource)
        Write-Output "uninstall.distro: $Distro"
        Write-Output ('uninstall.distro.registered: {0}' -f $registered)
        Write-Output ('uninstall.engine.running: {0}' -f [bool]$engineRunning)
        if ($engineRunning) { Write-Output ('uninstall.stack.stop: wsl.exe {0}' -f ($stopArgs -join ' ')) }
        else { Write-Output 'uninstall.stack.stop: none (distro not running; its containers start again with the distro - restart: unless-stopped)' }
        foreach ($taskName in $autostartTasks) {
            Write-Output "uninstall.task.unregister: $taskName"
        }
        Write-Output ('uninstall.backup: install-schedule.ps1 {0}' -f (($scheduleUninstallArgs | Select-Object -Skip 6) -join ' '))
        Write-Output "uninstall.terminate: wsl.exe --terminate $Distro"
        # Правило, а не перечень записей: записи хоста несут его адрес в ЛВС.
        Write-Output ('uninstall.portproxy.remove: own v4tov4 entries on ports {0} ({1}, same port) at any listen address' -f ($stackPorts -join ','), "connect $ProxyTarget")
        # Порядок — как у исполнения: прежнее правило Hyper-V до правила Windows.
        Write-Output "uninstall.firewall.hyperv.remove: $RuleName"
        Write-Output "uninstall.firewall.remove: $RuleName"
        if ($wslAction -eq 'restore') { Write-Output ('uninstall.wslconfig: restore from {0}' -f (Split-Path -Leaf $wslBackup)) }
        elseif ($wslAction -eq 'remove') { Write-Output ('uninstall.wslconfig: remove (marker {0})' -f (Split-Path -Leaf $wslAbsent)) }
        else { Write-Output 'uninstall.wslconfig: keep (no .domovoy-backup copy and no .domovoy-absent marker)' }
        Write-Output "uninstall.distro.kept: $Distro - stack volumes inside; remove by hand: wsl --unregister $Distro (destroys the volumes)"
        Write-Output 'DryRun: nothing changed'
        exit 0
    }

    if (-not (Test-Administrator)) {
        Stop-WithError 'нужен терминал администратора. Запустите терминал «от имени администратора» и повторите.'
    }

    # 1. Стек внутри движка — stop, тома целы. Отказ — до любых удалений.
    if ($engineRunning) {
        $env:WSL_UTF8 = '1'
        $encoding = Set-NativeOutputEncoding $wslExe
        try {
            & $wslExe @stopArgs
            $stopCode = $LASTEXITCODE
        }
        finally { Restore-NativeOutputEncoding $encoding }
        if ($stopCode -ne 0) {
            Stop-WithError "docker compose --profile ha stop внутри $Distro в ${DeployDir}: код $stopCode — ничего не удалено"
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

    # 3. Расписание бэкапа: без движка задача ночью будила бы WSL.
    $hostExe = (Get-Process -Id $PID).Path
    & $hostExe @scheduleUninstallArgs
    $scheduleCode = $LASTEXITCODE
    $backupProblem = ''
    if ($scheduleCode -ne 0) {
        $backupProblem = "расписание бэкапа не снято (install-schedule.ps1 -Uninstall, код $scheduleCode) — снимите: powershell -ExecutionPolicy Bypass -File ops/backup/install-schedule.ps1 -Uninstall"
    }

    # 4. Дистрибутив гасится, но не удаляется: в нём тома стека.
    if ($registered) {
        $terminated = Invoke-Wsl @('--terminate', $Distro)
        if ($terminated.Code -ne 0) { Write-Warning "wsl --terminate ${Distro}: код $($terminated.Code): $(Format-Native $terminated)" }
        else { Write-Output "дистрибутив $Distro остановлен" }
    }

    # 5. Доступ из ЛВС: свои записи portproxy, правило firewall Windows и
    # прежнее правило Hyper-V. Адрес записи в вывод не попадает.
    $proxyProblems = @()
    foreach ($own in @(Select-OwnPortProxy (Get-PortProxyRegistry) $stackPorts)) {
        $deleted = Invoke-Netsh @('interface', 'portproxy', 'delete', 'v4tov4', "listenaddress=$($own.ListenAddress)", "listenport=$($own.ListenPort)")
        if ($deleted.Code -ne 0) { $proxyProblems += "порт $($own.ListenPort): netsh код $($deleted.Code)" }
        else { Write-Output "запись portproxy порта $($own.ListenPort) удалена" }
    }
    Write-Output (Remove-LegacyHyperVRule)
    if (Get-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue) {
        Remove-NetFirewallRule -Name $RuleName
        Write-Output "правило $RuleName удалено"
    }
    else {
        Write-Output "правила $RuleName нет"
    }
    if ($proxyProblems.Count) {
        $backupProblem = (@("записи portproxy не сняты: $($proxyProblems -join '; ') — netsh interface portproxy show v4tov4") + @($backupProblem | Where-Object { $_ })) -join '; '
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

    Write-Output @"

Дистрибутив $Distro не удалён: в нём тома стека. Удалить вручную, когда
данные не нужны: wsl --unregister $Distro — тома уничтожаются без возврата.

Возврат .wslconfig применится после wsl --shutdown (гасит все дистрибутивы
пользователя) — его -Uninstall не выполняет. Функцию docker() из ~/.bashrc
убрать руками, если движок больше не нужен.
"@
    if ($backupProblem) { Stop-WithError $backupProblem }
    exit 0
}

if ($Install) {
    # Объекты задач и параметры правила собираются до любых действий; сухой
    # прогон печатает их свойства: что напечатано, то и регистрируется.
    $bootTrigger = New-ScheduledTaskTrigger -AtStartup
    # Задача — всегда с wsl.exe системы, и при подделке -WslExe.
    $keeperAction = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\wsl.exe') -Argument ('-d {0} --exec sleep infinity' -f $Distro)
    $keeperPrincipal = New-ScheduledTaskPrincipal -UserId $userId -LogonType S4U -RunLevel Limited
    $keeperSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew

    $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    # Журнал — в профиле пользователя: путь задаётся при регистрации, задача
    # под S4U не зависит от того, загружено ли окружение профиля.
    $measureLog = Join-Path $env:LOCALAPPDATA 'domovoy-engine\measure-boot.log'
    # Дистрибутив и проект compose — для зонда хронологии (boot-probe.sh):
    # замер спрашивает о контейнерах этого проекта.
    if ($project -cnotmatch '^[a-z0-9][a-z0-9_-]*$') {
        Stop-WithError "COMPOSE_PROJECT_NAME «$project» — строчные буквы, цифры, - и _ (имя проекта compose; .env каталога развёртывания или значение по умолчанию в docker-compose.yml)" 2
    }
    # Зонд замера — в каталоге развёртывания; каталога нет — measure-boot.ps1
    # сам идёт в клон.
    $measureArgument = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Port {1} -Distro {3} -Project {4} -DeployDir "{5}" -LogPath "{2}"' -f $measureScript, $apiPort, $measureLog, $Distro, $project, $DeployDir
    $measureAction = New-ScheduledTaskAction -Execute $powershellExe -Argument $measureArgument
    # Не SYSTEM: действие исполняет файл из клона, который пользователь
    # может менять. Журнал System (Kernel-General 12), LastBootUpTime и
    # FwPOSTTime читаются без прав администратора.
    $measurePrincipal = New-ScheduledTaskPrincipal -UserId $userId -LogonType S4U -RunLevel Limited
    $measureSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 1) -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew

    # Правило firewall Windows: входящие на порты стека, которые слушает
    # portproxy на адресе хоста в ЛВС, — только к его слушателю:
    # svchost.exe службы IP Helper.
    $ruleParams = @{
        Name          = $RuleName
        DisplayName   = 'Домовой: порты стека из локальной сети (portproxy на движок в WSL)'
        Direction     = 'Inbound'
        Protocol      = 'TCP'
        LocalPort     = @([string]$apiPort, [string]$haPort)
        RemoteAddress = $RemoteAddresses
        Profile       = $RuleProfile
        Program       = (Join-Path $env:SystemRoot 'System32\svchost.exe')
        Service       = $IpHelperService
        Action        = 'Allow'
    }

    # Адрес прослушивания portproxy — до любых действий: без него доступа
    # из ЛВС не будет, и это отказ, а не установка наполовину.
    if ($AssumeListenAddress) { $listen = [pscustomobject]@{ Address = $AssumeListenAddress; Reason = '' } }
    else { $listen = Get-HostListenAddress }
    $ipHelper = Get-Service -Name $IpHelperService -ErrorAction SilentlyContinue
    if ($AssumeIpHelperStartType) { $ipHelperStart = $AssumeIpHelperStartType }
    else { $ipHelperStart = if ($ipHelper) { [string]$ipHelper.StartType } else { 'не найдена' } }
    # portproxy держит служба IP Helper: без автозапуска записи после
    # загрузки не слушают.
    $ipHelperProblem = if ($ipHelperStart -ne 'Automatic') {
        "служба IP Helper ($IpHelperService): запуск $ipHelperStart, нужен Automatic — без неё portproxy не работает; Set-Service $IpHelperService -StartupType Automatic"
    } else { '' }
    # Профили firewall Windows (Get-FirewallProfileStates): правило и
    # portproxy открывают порты стека на адресе хоста, и закрытыми шире
    # правила их держат только профили, блокирующие входящие по умолчанию.
    # Открытый профиль — отказ до первого изменения.
    if ($AssumeOpenFirewallProfile) {
        $profileSettings = foreach ($name in 'Domain', 'Private', 'Public') {
            [pscustomobject]@{ Name = $name; Enabled = 'True'; DefaultInboundAction = $(if ($name -eq $AssumeOpenFirewallProfile) { 'Allow' } else { 'Block' }) }
        }
    }
    else {
        try { $profileSettings = @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop) }
        catch { $profileSettings = @() }
    }
    $openProfiles = @(Get-FirewallProfileStates $profileSettings | Where-Object { $_.Problems.Count })
    $firewallProfileProblem = ''
    if ($openProfiles.Count) {
        $firewallProfileProblem = 'firewall Windows: {0} — порты стека были бы открыты шире правила; Set-NetFirewallProfile -Profile {1} -Enabled True -DefaultInboundAction Block' -f `
        ((@($openProfiles | ForEach-Object { "профиль $($_.Name): $($_.Problems -join ', ')" }) -join '; '), (@($openProfiles | ForEach-Object { $_.Name }) -join ','))
    }
    # add заменяет запись того же адреса и порта: чужая запись на выбранном
    # адресе и порту стека иначе была бы молча переписана.
    $foreignProxyPorts = @(if (-not $listen.Reason) { Select-ForeignPortProxyPorts (Get-PortProxyRegistry) $listen.Address $stackPorts })
    $foreignProxyProblem = ''
    if ($foreignProxyPorts.Count) {
        $foreignProxyProblem = 'portproxy: на адресе хоста в ЛВС порт {0} занят чужой записью (цель не 127.0.0.1 того же порта) — чужая запись не переписывается; netsh interface portproxy show v4tov4' -f ($foreignProxyPorts -join ',')
    }

    $wslConfig = Get-WslConfigPlan $WslConfigPath
    $wslSave = Get-WslConfigSave $WslConfigPath $wslConfig.Exists
    # Провижининг делает wsl --terminate дистрибутива: держалка и движок
    # гибнут. Работали до -Install — держалка запускается снова после
    # регистрации задач, иначе стек лежал бы до перезагрузки. Состояние —
    # прочитанное до настроек каталога развёртывания.
    if ($AssumeEngineState) {
        $engineRunning = $distroRunning
    }
    else {
        $keeperNow = Get-ScheduledTask -TaskName $KeeperTask -ErrorAction SilentlyContinue
        $engineRunning = ($keeperNow -and [string]$keeperNow.State -eq 'Running') -or $distroRunning
    }
    $diskDir = Join-Path $DistroDir 'disk'
    $downloadDir = Join-Path $DistroDir 'download'
    $tar = Join-Path $downloadDir $ImageFile
    $importArgs = @('--import', $Distro, $diskDir, $tar, '--version', '2')
    $provisionArgs = @('-d', $Distro, '-u', 'root', '--cd', $root, '--exec', 'bash', 'deploy/windows/provision-engine.sh')
    # Разреженный диск: новый — сразу после импорта; зарегистрированный без
    # атрибута SparseFile — в окне после wsl --terminate провижининга, до
    # возврата держалки: --set-sparse требует остановленного дистрибутива.
    # --allow-unsafe не ставится.
    $sparseArgs = @('--manage', $Distro, '--set-sparse', 'true')
    if (-not $registered) { $sparseStep = 'after-import' }
    elseif ($DryRun -and ($AssumeEngineState -or $wslFake)) { $sparseStep = 'not-inspected' }
    else {
        $diskPath = Get-DistroDiskPath $Distro
        $sparseStep = if ((Get-SparseDiskCheck $diskPath (Get-DiskAttributes $diskPath)).State -eq 'OK') { 'none' } else { 'after-provision' }
    }
    # Отказ --set-sparse -Install не обрывает: остальные шаги доводятся, в
    # конце — ненулевой код с этим текстом, как при отказе расписания бэкапа.
    $sparseProblem = ''
    $scheduleArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $scheduleScript, '-Install')
    if ($DryRun) { $scheduleArgs += '-DryRun' }
    $scheduleArgs += @('-DeployDir', $DeployDir)
    # Подмены сухого прогона — и вложенному сухому прогону расписания.
    if ($DryRun) {
        if ($AssumeEngineState) { $scheduleArgs += @('-AssumeEngineState', $AssumeEngineState) }
        if ($AssumeDeploySettings) { $scheduleArgs += @('-AssumeDeploySettings', $AssumeDeploySettings) }
        if ($wslFake) { $scheduleArgs += @('-WslExe', $wslFake) }
    }

    if ($DryRun) {
        Write-Output (Format-SettingsSource)
        Write-Output "distro: $Distro"
        Write-Output ('distro.registered: {0}' -f $registered)
        if (-not $registered) {
            Write-Output "distro.image: $ImageBase/$ImageFile"
            Write-Output "distro.sha256sums: $ImageBase/SHA256SUMS"
            Write-Output ('distro.import: wsl.exe {0}' -f ($importArgs -join ' '))
            Write-Output ('distro.sparse: wsl.exe {0} (after import)' -f ($sparseArgs -join ' '))
        }
        Write-Output ('provision: wsl.exe {0}' -f ($provisionArgs -join ' '))
        Write-Output ('provision.restart: код 3 — wsl.exe --terminate {0} и повтор' -f $Distro)
        Write-Output ('provision.terminate: wsl.exe --terminate {0}' -f $Distro)
        if ($sparseStep -eq 'after-provision') { Write-Output ('distro.sparse: wsl.exe {0} (disk not sparse; after provision terminate, before keeper resume)' -f ($sparseArgs -join ' ')) }
        elseif ($sparseStep -eq 'none') { Write-Output 'distro.sparse: none (ext4.vhdx already SparseFile)' }
        elseif ($sparseStep -eq 'not-inspected') { Write-Output ('distro.sparse: disk not inspected (assumed engine state or -WslExe); not SparseFile - wsl.exe {0} after provision terminate' -f ($sparseArgs -join ' ')) }
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
            Write-Output "wslconfig.conflict: $($wslConfig.Conflict)"
        }
        else {
            Write-Output ('wslconfig.exists: {0}' -f $wslConfig.Exists)
            Write-Output ('wslconfig.changed: {0}' -f $wslConfig.Changed)
            if (-not $wslConfig.Changed) { Write-Output 'wslconfig.save: none (file unchanged)' }
            elseif ($wslSave -eq 'backup') { Write-Output 'wslconfig.save: backup copy' }
            elseif ($wslSave -eq 'absent') { Write-Output 'wslconfig.save: absent marker' }
            else { Write-Output 'wslconfig.save: none (backup copy or absent marker already there)' }
            # Байт в байт, как запишет -Install: строки ниже делятся по
            # переводу строки и лишний CR не показывают.
            Write-Output ('wslconfig.base64: {0}' -f [Convert]::ToBase64String((New-Object Text.UTF8Encoding($false)).GetBytes($wslConfig.Content)))
            foreach ($line in ($wslConfig.Content -split "`r?`n")) {
                if ($line) { Write-Output "wslconfig.line: $line" }
            }
        }
        if ($firewallProfileProblem) { Write-Output "firewall.hostprofiles.conflict: $firewallProfileProblem" }
        else { Write-Output 'firewall.hostprofiles: ok (Domain, Private, Public: Enabled True, DefaultInboundAction Block)' }
        # Порядок — как у исполнения: прежнее правило Hyper-V снимается до
        # записи правила Windows с тем же именем.
        Write-Output "firewall.hyperv.remove: $RuleName"
        foreach ($key in 'Name', 'Direction', 'Protocol', 'Action', 'Program', 'Service') {
            Write-Output ('firewall.{0}: {1}' -f $key.ToLowerInvariant(), $ruleParams[$key])
        }
        Write-Output ('firewall.profiles: {0}' -f $ruleParams.Profile)
        Write-Output ('firewall.localports: {0}' -f ($ruleParams.LocalPort -join ','))
        Write-Output ('firewall.remoteaddresses: {0}' -f ($ruleParams.RemoteAddress -join ','))
        Write-Output ('firewall.profiles.private_only: {0}' -f (Test-PrivateProfileOnly $ruleParams.Profile))
        # Адрес прослушивания не печатается ни подменённый, ни выбранный.
        if ($listen.Reason) { Write-Output "listen.conflict: $($listen.Reason)" }
        elseif ($AssumeListenAddress) { Write-Output 'listen.address: assumed (-AssumeListenAddress, not printed)' }
        else { Write-Output 'listen.address: selected (not printed)' }
        foreach ($port in $stackPorts) {
            Write-Output ('portproxy.add: v4tov4 listenport={0} connectaddress={1} connectport={0}' -f $port, $ProxyTarget)
        }
        Write-Output ('portproxy.remove: own v4tov4 entries on ports {0} ({1}, same port) at other listen addresses' -f ($stackPorts -join ','), "connect $ProxyTarget")
        Write-Output "iphlpsvc.starttype: $ipHelperStart"
        if ($ipHelperProblem) { Write-Output "iphlpsvc.conflict: $ipHelperProblem" }
        if ($foreignProxyProblem) { Write-Output "portproxy.conflict: $foreignProxyProblem" }
        Write-Output ('backup: install-schedule.ps1 {0}' -f (($scheduleArgs | Select-Object -Skip 6) -join ' '))
        $schedule = Invoke-Native (Get-Process -Id $PID).Path $scheduleArgs
        $scheduleCode = $schedule.Code
        foreach ($line in $schedule.Lines) { Write-Output "backup.$line" }
        foreach ($line in $schedule.ErrLines) { Write-Output "backup.stderr: $line" }
        Write-Output "backup.exitcode: $scheduleCode"
        if ($wslConfig.Conflict -or $listen.Reason -or $ipHelperProblem -or $firewallProfileProblem -or $foreignProxyProblem -or $scheduleCode -ne 0) {
            Write-Output 'DryRun: nothing changed'
            exit 1
        }
        Write-Output 'DryRun: nothing changed'
        exit 0
    }

    if (-not (Test-Administrator)) {
        Stop-WithError 'нужен терминал администратора. Запустите терминал «от имени администратора» и повторите.'
    }
    if ($wslConfig.Conflict) {
        Stop-WithError "$WslConfigPath задаёт $($wslConfig.Conflict) — чужая настройка не переписывается; движку нужны networkingMode=nat, localhostForwarding, sparseVhd=true и autoMemoryReclaim=gradual (README, «Автозапуск после перезагрузки»)"
    }
    if ($deploySettings.Source -eq 'deploy') { Write-Output "настройки стека: из $DeployDir/.env внутри $Distro" }
    else { Write-Output "настройки стека: значения по умолчанию из docker-compose.yml — $($deploySettings.Detail)" }
    if ($listen.Reason) { Stop-WithError "адрес хоста в ЛВС для portproxy: $($listen.Reason)" }
    if ($ipHelperProblem) { Stop-WithError $ipHelperProblem }
    if ($firewallProfileProblem) { Stop-WithError $firewallProfileProblem }
    if ($foreignProxyProblem) { Stop-WithError $foreignProxyProblem }
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
        # Разреженный диск — сразу после импорта: дистрибутив ещё не запущен.
        $sparseProblem = Set-DistroSparse $Distro
        if (-not $sparseProblem) { Write-Output "диск дистрибутива $Distro разреженный (wsl --manage --set-sparse true)" }
        else { Write-Warning $sparseProblem }
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
    $encoding = Set-NativeOutputEncoding $wslExe
    try {
        & $wslExe @provisionArgs
        $provisionCode = $LASTEXITCODE
    }
    finally { Restore-NativeOutputEncoding $encoding }
    if ($provisionCode -eq 3) {
        $null = Invoke-Wsl @('--terminate', $Distro)
        $encoding = Set-NativeOutputEncoding $wslExe
        try {
            & $wslExe @provisionArgs
            $provisionCode = $LASTEXITCODE
        }
        finally { Restore-NativeOutputEncoding $encoding }
    }
    if ($provisionCode -ne 0) { Stop-Install "провижининг дистрибутива: код $provisionCode" }
    $null = Invoke-Wsl @('--terminate', $Distro)
    # По одному юниту: is-enabled со списком даёт код 0, если включён хоть
    # один. Признак — вывод enabled, как в -Check.
    $disabled = New-Object System.Collections.Generic.List[string]
    foreach ($unit in $EngineUnits) {
        $isEnabled = Invoke-Wsl @('-d', $Distro, '-u', 'root', '--exec', 'systemctl', 'is-enabled', $unit)
        if ($isEnabled.Text -ne 'enabled') { $disabled.Add("$unit «$(Format-Native $isEnabled)»") }
    }
    $null = Invoke-Wsl @('--terminate', $Distro)
    if ($disabled.Count) { Stop-Install "не в автозапуске systemd дистрибутива: $($disabled -join '; ')" }
    Write-Output "$($EngineUnits -join ', ') в автозапуске systemd дистрибутива"

    # Разреженный диск зарегистрированного дистрибутива без SparseFile — в
    # окне после wsl --terminate выше, до возврата держалки: --set-sparse
    # требует остановленного дистрибутива.
    if ($sparseStep -eq 'after-provision') {
        $sparseProblem = Set-DistroSparse $Distro
        if (-not $sparseProblem) { Write-Output "диск дистрибутива $Distro сделан разреженным (wsl --manage --set-sparse true)" }
        else { Write-Warning $sparseProblem }
    }

    # 3–4. Задачи; -Force заменяет прежние.
    # Отказ регистрации — тоже после остановки дистрибутива: через Stop-Install.
    try {
        $null = Register-ScheduledTask -TaskName $KeeperTask -Trigger $bootTrigger -Action $keeperAction -Principal $keeperPrincipal `
            -Settings $keeperSettings -Description 'Домовой: держит WSL-дистрибутив движка Docker после загрузки, без входа' -Force
        Write-Output "задача $KeeperTask зарегистрирована: при запуске системы, S4U"
        $null = Register-ScheduledTask -TaskName $MeasureTask -Trigger $bootTrigger -Action $measureAction -Principal $measurePrincipal `
            -Settings $measureSettings -Description 'Домовой: хронология загрузки — дистрибутив, docker, контейнеры, /health' -Force
        Write-Output "задача $MeasureTask зарегистрирована: порт $apiPort, проект $project, S4U, журнал $measureLog"
    }
    catch {
        Stop-Install "регистрация задач: $($_.Exception.Message)"
    }

    # Держалка — сразу после регистрации, до шагов, которые могут отказать.
    try { $resumed = Resume-Keeper }
    catch { Stop-WithError "держалка $KeeperTask работала до -Install, а запустить её снова не удалось: $($_.Exception.Message) — Start-ScheduledTask $KeeperTask" }
    if ($resumed) { Write-Output "держалка $KeeperTask работала до -Install — запущена снова; контейнеры поднимет restart: unless-stopped" }

    # 5. .wslconfig. Копия или отметка пишется, только если их ещё нет
    # (Get-WslConfigSave): они описывают файл до первого -Install.
    if ($wslConfig.Changed) {
        if ($wslSave -eq 'backup') { Copy-Item -LiteralPath $WslConfigPath -Destination "$WslConfigPath.domovoy-backup" }
        elseif ($wslSave -eq 'absent') { $null = New-Item -ItemType File -Path "$WslConfigPath.domovoy-absent" }
        [IO.File]::WriteAllText($WslConfigPath, $wslConfig.Content, (New-Object Text.UTF8Encoding($false)))
        Write-Output ("${WslConfigPath}: дописано {0}; применится после wsl --shutdown (README)" -f ((@($wslConfig.Missing) + @(if ($wslConfig.OwnMirrored) { 'networkingMode=nat вместо своего mirrored' })) -join ', '))
    }
    else {
        Write-Output "${WslConfigPath}: networkingMode=nat, sparseVhd=true и autoMemoryReclaim=gradual уже заданы"
    }

    # 6. Правило firewall Windows: пересоздаётся с теми же параметрами.
    # Прежнее правило Hyper-V (0028) в NAT не нужно — снимается до записи
    # правила Windows с тем же именем.
    Write-Output (Remove-LegacyHyperVRule)
    if (Get-NetFirewallRule -Name $RuleName -ErrorAction SilentlyContinue) {
        Remove-NetFirewallRule -Name $RuleName
    }
    $null = New-NetFirewallRule @ruleParams
    Write-Output ('правило {0}: TCP {1}, с адресов {2}, профиль {3}, служба {4}' -f $RuleName, ($ruleParams.LocalPort -join ','), ($RemoteAddresses -join ','), $RuleProfile, $IpHelperService)

    # 7. portproxy: свои записи на прежнем адресе снимаются, на нынешнем
    # пишутся заново (add заменяет запись того же адреса и порта). Адрес в
    # вывод не попадает.
    if ([string]$ipHelper.Status -ne 'Running') { Start-Service -Name $IpHelperService }
    foreach ($own in @(Select-OwnPortProxy (Get-PortProxyRegistry) $stackPorts)) {
        if ($own.ListenAddress -eq $listen.Address) { continue }
        $deleted = Invoke-Netsh @('interface', 'portproxy', 'delete', 'v4tov4', "listenaddress=$($own.ListenAddress)", "listenport=$($own.ListenPort)")
        if ($deleted.Code -ne 0) { Stop-WithError "portproxy: запись порта $($own.ListenPort) на прежнем адресе не снята, netsh код $($deleted.Code) — netsh interface portproxy show v4tov4" }
        Write-Output "portproxy: запись порта $($own.ListenPort) на прежнем адресе снята"
    }
    foreach ($port in $stackPorts) {
        $added = Invoke-Netsh @('interface', 'portproxy', 'add', 'v4tov4', "listenaddress=$($listen.Address)", "listenport=$port", "connectaddress=$ProxyTarget", "connectport=$port")
        if ($added.Code -ne 0) { Stop-WithError "portproxy: запись порта $port не добавлена, netsh код $($added.Code)" }
    }
    Write-Output ('portproxy: порты {0} с адреса хоста в ЛВС на {1} того же порта' -f ($stackPorts -join ','), $ProxyTarget)

    # 8. Расписание бэкапа — последним шагом.
    $hostExe = (Get-Process -Id $PID).Path
    & $hostExe @scheduleArgs
    $scheduleCode = $LASTEXITCODE

    # .wslconfig изменён — работающий экземпляр WSL идёт по прежней сети до
    # wsl --shutdown, и при повторном запуске тоже.
    if ($resumed -and -not $wslConfig.Changed) {
        Write-Output @"

Повторный запуск: дистрибутив $Distro перезапускался (wsl --terminate), держалка
запущена снова. Проверка всех звеньев — -Check.
"@
    }
    else {
        Write-Output @"

Дальше (README, «Автозапуск после перезагрузки»): wsl --shutdown — применяет
.wslconfig (networkingMode=nat, sparseVhd, autoMemoryReclaim) и гасит все
дистрибутивы пользователя; затем
Start-ScheduledTask $KeeperTask и проверка всех звеньев — -Check.
Предусловия: BIOS — включаться после пропадания питания; BitLocker без PIN;
адрес хоста в ЛВС закреплён в DHCP роутера — сменился адрес, повторите -Install.
"@
    }
    # Отказы шагов, после которых остальное доведено: ненулевой код в конце.
    $finalProblems = @()
    if ($sparseProblem) { $finalProblems += $sparseProblem }
    if ($scheduleCode -ne 0) {
        $finalProblems += "расписание бэкапа не поставлено (ops/backup/install-schedule.ps1, код $scheduleCode)"
    }
    if ($finalProblems.Count) {
        Stop-WithError (($finalProblems -join '; ') + ' — остальное настроено')
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

if ($registered) { Add-Result 'OK' 'дистрибутив зарегистрирован' $Distro }
else { Add-Result 'FAIL' 'дистрибутив зарегистрирован' "нет $Distro — engine-setup.ps1 -Install" }

# Настройки стека (порты, проект) — из .env каталога развёртывания; не
# прочитаны — дальше звенья идут по значениям по умолчанию.
$settingsLink = 'настройки каталога развёртывания'
if ($deploySettings.Error) { Add-Result 'FAIL' $settingsLink "$($deploySettings.Error) — дальше значения по умолчанию из docker-compose.yml" }
elseif ($deploySettings.Source -eq 'deploy') { Add-Result 'OK' $settingsLink $deploySettings.Detail }
else { Add-Result 'SKIP' $settingsLink "не прочитаны: $($deploySettings.Detail) — дальше значения по умолчанию из docker-compose.yml" }

# Диск дистрибутива — разреженный: атрибут файла, а не обещание WSL.
$sparseLink = 'диск дистрибутива разреженный'
if (-not $registered) { Add-Result 'SKIP' $sparseLink 'не проверено — дистрибутив не зарегистрирован' }
else {
    $diskPath = Get-DistroDiskPath $Distro
    $sparseCheck = Get-SparseDiskCheck $diskPath (Get-DiskAttributes $diskPath)
    Add-Result $sparseCheck.State $sparseLink $sparseCheck.Detail
}

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
    $measureArgs = [string](@($measure.Actions)[0].Arguments)
    $m = [regex]::Match($measureArgs, '-Port\s+(\d+)')
    if ($m.Success) { $measurePort = [int]$m.Groups[1].Value }
    $m = [regex]::Match($measureArgs, '-Project\s+(\S+)')
    $measureProject = if ($m.Success) { $m.Groups[1].Value } else { '' }
    $m = [regex]::Match($measureArgs, '-Distro\s+(\S+)')
    $measureDistro = if ($m.Success) { $m.Groups[1].Value } else { '' }
    $m = [regex]::Match($measureArgs, '-DeployDir\s+"?([^"\s]+)')
    $measureDeployDir = if ($m.Success) { $m.Groups[1].Value } else { '' }
    if ($measurePort -ne $apiPort) { Add-Result 'FAIL' 'задача замера' "порт задачи $measurePort, API_HTTP_PORT $apiPort — переустановите: -Install" }
    elseif ($measureProject -cne $project -or $measureDistro -cne $Distro) {
        Add-Result 'FAIL' 'задача замера' "проект задачи «$measureProject», COMPOSE_PROJECT_NAME «$project»; дистрибутив «$measureDistro» — хронология контейнеров не та; переустановите: -Install"
    }
    elseif ($measureDeployDir -cne $DeployDir) {
        Add-Result 'FAIL' 'задача замера' "каталог развёртывания задачи «$measureDeployDir», нужен «$DeployDir» — зонд идёт не там; переустановите: -Install"
    }
    elseif ([string]$measure.Principal.LogonType -ne 'S4U' -or [string]$measure.Principal.RunLevel -ne 'Limited') {
        Add-Result 'FAIL' 'задача замера' "принципал $($measure.Principal.UserId), $($measure.Principal.LogonType), $($measure.Principal.RunLevel) — нужен пользователь с S4U и Limited: задача исполняет файл из клона"
    }
    else { Add-Result 'OK' 'задача замера' "порт $measurePort, проект $measureProject" }
}

$wslPlan = Get-WslConfigPlan $WslConfigPath
$wslCheck = Get-WslConfigCheck $wslPlan
Add-Result $wslCheck.State '.wslconfig: networkingMode=nat' $wslCheck.Detail
$wslCheck = Get-WslConfigKeyCheck $wslPlan 'sparseVhd'
Add-Result $wslCheck.State '.wslconfig: sparseVhd=true' $wslCheck.Detail
$wslCheck = Get-WslConfigKeyCheck $wslPlan 'autoMemoryReclaim'
Add-Result $wslCheck.State '.wslconfig: autoMemoryReclaim=gradual' $wslCheck.Detail

# Правило firewall Windows: через него устройства в ЛВС доходят до
# portproxy на адресе хоста.
$ruleLink = 'правило firewall'
try {
    $rule = Get-NetFirewallRule -Name $RuleName -ErrorAction Stop
    $portFilter = $rule | Get-NetFirewallPortFilter
    $addressFilter = $rule | Get-NetFirewallAddressFilter
    $applicationFilter = $rule | Get-NetFirewallApplicationFilter
    $serviceFilter = $rule | Get-NetFirewallServiceFilter
    $ruleView = [pscustomobject]@{ Enabled = $rule.Enabled; Direction = $rule.Direction; Action = $rule.Action; Protocol = $portFilter.Protocol
        LocalPorts = @($portFilter.LocalPort); RemoteAddresses = @($addressFilter.RemoteAddress); Profiles = $rule.Profile
        Program = $applicationFilter.Program; Service = $serviceFilter.Service }
    $ruleProblems = @(Get-HostRuleProblems $ruleView $stackPorts)
    if ($ruleProblems.Count) { Add-Result 'FAIL' $ruleLink (($ruleProblems -join '; ') + ' — engine-setup.ps1 -Install') }
    else { Add-Result 'OK' $ruleLink ('TCP {0} с LocalSubnet, профиль Private, svchost.exe службы {1}' -f ($stackPorts -join ','), $IpHelperService) }
}
catch {
    if ($_.CategoryInfo.Category -eq 'ObjectNotFound') { Add-Result 'FAIL' $ruleLink "нет правила $RuleName — engine-setup.ps1 -Install" }
    else { Add-Result 'SKIP' $ruleLink "не проверено: $($_.Exception.Message)" }
}

# Профили firewall Windows (Get-FirewallProfileStates), каждый своим звеном:
# Private — правило выше сужает доступ, только пока профиль блокирует
# остальное; Public и Domain — слушатель portproxy привязан к адресу, а не к
# сети, и в сети этих профилей порты стека закрывает только блокировка
# входящих по умолчанию. ActiveStore — действующие значения: в хранилище по
# умолчанию без явной настройки стоит NotConfigured.
try {
    $profileStates = @(Get-FirewallProfileStates @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop))
    foreach ($state in $profileStates) {
        $profileLink = "firewall Windows: профиль $($state.Name)"
        if ($state.Problems.Count) { Add-Result 'FAIL' $profileLink (($state.Problems -join '; ') + " — в сети профиля $($state.Name) порты стека открыты шире правила; Set-NetFirewallProfile -Profile $($state.Name) -Enabled True -DefaultInboundAction Block") }
        else { Add-Result 'OK' $profileLink 'Enabled True, DefaultInboundAction Block' }
    }
}
catch {
    foreach ($name in 'Domain', 'Private', 'Public') { Add-Result 'SKIP' "firewall Windows: профиль $name" "не проверено: $($_.Exception.Message)" }
}

# Адрес хоста в ЛВС — тем же выбором, что у -Install: смена адреса (DHCP,
# другая сеть) видна как запись portproxy на другом адресе. Адрес в вывод
# не попадает.
$listen = Get-HostListenAddress
$listenLink = 'адрес хоста в ЛВС для portproxy'
if ($listen.Reason) { Add-Result 'FAIL' $listenLink $listen.Reason }
else { Add-Result 'OK' $listenLink 'выбран (в вывод не попадает)' }

$proxyLink = 'portproxy: записи портов стека'
if ($listen.Reason) { Add-Result 'SKIP' $proxyLink 'не проверено — адрес хоста в ЛВС не выбран' }
else {
    $proxyProblems = @(Get-PortProxyProblems (Get-PortProxyRegistry) $listen.Address $stackPorts)
    if ($proxyProblems.Count) { Add-Result 'FAIL' $proxyLink ($proxyProblems -join '; ') }
    else { Add-Result 'OK' $proxyLink ('порты {0} с адреса в ЛВС на {1} того же порта' -f ($stackPorts -join ','), $ProxyTarget) }
}

$ipHelper = Get-Service -Name $IpHelperService -ErrorAction SilentlyContinue
$ipHelperLink = "служба IP Helper ($IpHelperService) для portproxy"
if (-not $ipHelper) { Add-Result 'FAIL' $ipHelperLink 'службы нет' }
elseif ([string]$ipHelper.Status -ne 'Running' -or [string]$ipHelper.StartType -ne 'Automatic') {
    Add-Result 'FAIL' $ipHelperLink "состояние $($ipHelper.Status), запуск $($ipHelper.StartType) — нужны Running и Automatic: Set-Service $IpHelperService -StartupType Automatic; Start-Service $IpHelperService"
}
else { Add-Result 'OK' $ipHelperLink 'Running, Automatic' }

# Запись в реестре не значит, что служба слушает: адрес мог появиться после
# её старта, а порт — быть занят другим процессом. Слушатель на адресе и
# порту должен принадлежать процессу службы IP Helper.
$listenerLink = 'portproxy слушает адрес в ЛВС'
if ($listen.Reason) { Add-Result 'SKIP' $listenerLink 'не проверено — адрес хоста в ЛВС не выбран' }
else {
    $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$IpHelperService'" -ErrorAction SilentlyContinue
    $servicePid = if ($service) { [int]$service.ProcessId } else { 0 }
    $listenerProblems = @()
    foreach ($port in $stackPorts) {
        $owners = @(Get-NetTCPConnection -State Listen -LocalAddress $listen.Address -LocalPort $port -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.OwningProcess })
        if (-not $owners.Count) { $listenerProblems += "порт ${port}: слушателя нет" }
        elseif (-not $servicePid -or $owners -notcontains $servicePid) { $listenerProblems += "порт ${port}: слушает не служба IP Helper — Get-NetTCPConnection -State Listen -LocalPort $port" }
    }
    if ($listenerProblems.Count) { Add-Result 'FAIL' $listenerLink ($listenerProblems -join '; ') }
    else { Add-Result 'OK' $listenerLink ('порты {0}, процесс службы {1}' -f ($stackPorts -join ','), $IpHelperService) }
}

$running = (Get-WslNames @('--list', '--running', '--quiet')) -contains $Distro
$journalLink = 'журнал systemd на диске, сброс ≤ 10 с'
$driverLink = 'docker: драйвер логов journald'
$containerLogLink = 'логи контейнеров проекта в journald'
$workingDirLink = 'стек поднят из каталога развёртывания'
$inner = @($EngineUnits | ForEach-Object { "$_ в автозапуске" }) + @($journalLink, $driverLink, 'restart: unless-stopped у контейнеров проекта', $containerLogLink, 'порт замера = опубликованный порт api', $workingDirLink)
if (-not $running) {
    foreach ($link in $inner) { Add-Result 'SKIP' $link 'не проверено — дистрибутив не запущен' }
}
else {
    foreach ($unit in $EngineUnits) {
        $isEnabled = Invoke-Wsl @('-d', $Distro, '-u', 'root', '--exec', 'systemctl', 'is-enabled', $unit)
        $activeResult = Invoke-Wsl @('-d', $Distro, '-u', 'root', '--exec', 'systemctl', 'is-active', $unit)
        $isActive = Format-Native $activeResult
        # OK — по is-enabled: «active» после ручного старта автозапуска не
        # доказывает. Oneshot с RemainAfterExit (MSS clamp) после загрузки
        # обязан быть и active: упавший на старте юнит is-enabled не видно.
        $needActive = $OneshotUnits -contains $unit
        if ($isEnabled.Text -ne 'enabled') { Add-Result 'FAIL' "$unit в автозапуске" "is-enabled «$(Format-Native $isEnabled)»; is-active $isActive" }
        elseif ($needActive -and $activeResult.Text -ne 'active') { Add-Result 'FAIL' "$unit в автозапуске" "is-enabled enabled, но is-active «$isActive» — юнит упал на загрузке: systemctl status $unit" }
        else { Add-Result 'OK' "$unit в автозапуске" "is-enabled enabled; is-active $isActive" }
    }
    # Логи переживают выключение хоста: журнал systemd на диске со сбросом
    # раз в 10 с (provision-engine.sh, ensure_journald) — по действующей
    # настройке, с drop-in, а не по одному файлу.
    $journalConfig = Invoke-Wsl @('-d', $Distro, '-u', 'root', '--exec', 'systemd-analyze', 'cat-config', 'systemd/journald.conf')
    if ($journalConfig.Code -ne 0) { Add-Result 'FAIL' $journalLink "systemd-analyze cat-config: код $($journalConfig.Code): $(Format-Native $journalConfig)" }
    else {
        $journalProblems = @(Get-JournaldProblems $journalConfig.Text)
        if ($journalProblems.Count) { Add-Result 'FAIL' $journalLink (($journalProblems -join '; ') + ' — engine-setup.ps1 -Install') }
        else { Add-Result 'OK' $journalLink 'Storage=persistent, SyncIntervalSec ≤ 10 с' }
    }
    # Драйвер движка (provision-engine.sh, ensure_docker_log_driver) —
    # действующий, после перезапуска docker.
    $loggingDriver = Invoke-Wsl @('-d', $Distro, '-u', 'root', '--exec', 'docker', 'info', '--format', '{{.LoggingDriver}}')
    if ($loggingDriver.Code -ne 0) { Add-Result 'FAIL' $driverLink "docker info: код $($loggingDriver.Code): $(Format-Native $loggingDriver)" }
    elseif ($loggingDriver.Text -ne 'journald') { Add-Result 'FAIL' $driverLink "драйвер «$($loggingDriver.Text)» — engine-setup.ps1 -Install, затем перезапуск дистрибутива" }
    else { Add-Result 'OK' $driverLink 'journald' }
    $label = "label=com.docker.compose.project=$project"
    $listed = Invoke-Wsl @('-d', $Distro, '-u', 'root', '--exec', 'docker', 'ps', '-a', '--filter', $label, '--format', '{{.Names}}')
    $names = @($listed.Lines | Where-Object { $_ })
    if ($listed.Code -ne 0) {
        Add-Result 'FAIL' 'restart: unless-stopped у контейнеров проекта' "docker ps: код $($listed.Code): $(Format-Native $listed)"
        Add-Result 'FAIL' $containerLogLink "docker ps: код $($listed.Code): $(Format-Native $listed)"
    }
    elseif (-not $names.Count) {
        Add-Result 'FAIL' 'restart: unless-stopped у контейнеров проекта' "контейнеров проекта $project нет"
        Add-Result 'FAIL' $containerLogLink "контейнеров проекта $project нет"
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
        # Драйвер задаётся контейнеру при создании: созданные до смены
        # драйвера движка остаются на json-file, пока их не пересоздать.
        $logConfigs = Invoke-Wsl (@('-d', $Distro, '-u', 'root', '--exec', 'docker', 'inspect', '-f', '{{.Name}} {{.HostConfig.LogConfig.Type}}') + $names)
        $logProblems = @(Get-ContainerLogProblems $names @($logConfigs.Text -split "`r?`n"))
        if ($logConfigs.Code -ne 0) { Add-Result 'FAIL' $containerLogLink "docker inspect: код $($logConfigs.Code): $(Format-Native $logConfigs)" }
        elseif ($logProblems.Count) { Add-Result 'FAIL' $containerLogLink ($logProblems -join '; ') }
        else { Add-Result 'OK' $containerLogLink ('{0} контейнеров' -f $names.Count) }
    }
    $apiPorts = Invoke-Wsl @('-d', $Distro, '-u', 'root', '--exec', 'docker', 'ps', '--filter', $label, '--filter', 'label=com.docker.compose.service=api', '--format', '{{.Ports}}')
    $published = [regex]::Match($apiPorts.Text, ':(\d+)->\d+/tcp')
    if ($apiPorts.Code -ne 0) { Add-Result 'FAIL' 'порт замера = опубликованный порт api' "docker ps: код $($apiPorts.Code): $(Format-Native $apiPorts)" }
    elseif (-not $published.Success) { Add-Result 'FAIL' 'порт замера = опубликованный порт api' 'api не запущен или порт не опубликован' }
    elseif ([int]$published.Groups[1].Value -ne $measurePort) { Add-Result 'FAIL' 'порт замера = опубликованный порт api' "api опубликован на $($published.Groups[1].Value), задача замера — $measurePort" }
    else { Add-Result 'OK' 'порт замера = опубликованный порт api' "$measurePort" }
    # Стек поднят из каталога развёртывания, а не из клона Windows: метка
    # working_dir, которую compose ставит контейнерам при создании.
    $workingDirs = Invoke-Wsl (Get-WorkingDirQuery $Distro $project)
    if ($workingDirs.Code -ne 0) { Add-Result 'FAIL' $workingDirLink "docker ps: код $($workingDirs.Code): $(Format-Native $workingDirs)" }
    else {
        # Строка на контейнер; пустая — контейнер без метки.
        $workingDirCheck = Get-StackWorkingDirCheck @($workingDirs.Lines) $DeployDir
        Add-Result $workingDirCheck.State $workingDirLink $workingDirCheck.Detail
    }
}

# /health с хоста тремя путями, все в итоге. 127.0.0.1 и [::1] — петля, в
# NAT её принимает wslrelay и доводит до движка; адрес в ЛВС — portproxy
# на 127.0.0.1, путь телефона в домашней сети без роутера. Адреса —
# явные, не localhost: localhost Windows разрешает сначала в ::1, и по
# строке не было бы видно, какой путь проверен.
function Add-HealthResult([string]$Link, $Answer) {
    if ($Answer.Stack) { Add-Result 'OK' $Link '200 формы стека' }
    elseif ($Answer.Code) { Add-Result 'FAIL' $Link "код $($Answer.Code)$(if ($Answer.Code -eq 200) { ', тело не формы стека — чужой слушатель' })" }
    else { Add-Result 'FAIL' $Link "нет ответа: $($Answer.Error)" }
}
$loop = Get-Health ('http://127.0.0.1:{0}/health' -f $apiPort)
Add-HealthResult "/health на 127.0.0.1:$apiPort" $loop
Add-HealthResult "/health на [::1]:$apiPort" (Get-Health ('http://[::1]:{0}/health' -f $apiPort))
# Метка без адреса: адрес хоста в ЛВС в вывод не попадает, и ошибка
# Get-Health называет тип исключения, а не текст с адресом.
$lanLink = "/health по адресу в ЛВС, порт $apiPort"
if ($listen.Reason) { Add-Result 'SKIP' $lanLink 'не проверено — адрес хоста в ЛВС не выбран' }
else { Add-HealthResult $lanLink (Get-Health ('http://{0}:{1}/health' -f $listen.Address, $apiPort)) }

# Расписание бэкапа (#8): S4U и состояние по install-schedule.ps1 -Check.
$backupTaskObject = Get-ScheduledTask -TaskName $BackupTask -ErrorAction SilentlyContinue
if (-not $backupTaskObject) {
    Add-Result 'FAIL' 'расписание бэкапа' "нет задачи $BackupTask"
}
else {
    $schedule = Invoke-Native (Get-Process -Id $PID).Path @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $scheduleScript, '-Check', '-DeployDir', $DeployDir)
    $scheduleCode = $schedule.Code
    foreach ($line in $schedule.Lines) { Write-Output "     | $line" }
    foreach ($line in $schedule.ErrLines) { Write-Output "     | stderr: $line" }
    if ([string]$backupTaskObject.Principal.LogonType -ne 'S4U') { Add-Result 'FAIL' 'расписание бэкапа' "LogonType $($backupTaskObject.Principal.LogonType), нужен S4U" }
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
