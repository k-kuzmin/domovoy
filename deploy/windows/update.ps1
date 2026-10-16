#Requires -Version 5.1
<#
.SYNOPSIS
  Обновление стека в каталоге развёртывания одной командой (#162).

.DESCRIPTION
  Тонкая обёртка над deploy/update.sh внутри дистрибутива движка. Вся
  логика обновления — в update.sh: бэкап, checkout коммита из main,
  синхронизация .env, образы из реестра, миграция, перезапуск, /health,
  откат при провале и чистка.

  Обёртка проверяет до любого вызова внутрь дистрибутива:
    1. wsl.exe --list --quiet — дистрибутив -Distro зарегистрирован;
    2. wsl.exe --list --running --quiet — он работает. Вызов wsl.exe -d
       до этой проверки не делается: он поднял бы остановленный дистрибутив
       молча, в обход держалки;
    3. wsl.exe -d <Distro> -u root --exec test -d <DeployDir>/.git —
       каталог развёртывания на месте.
  Отказ любой проверки — код 1 и причина.

  Затем:
    wsl.exe -d <Distro> -u root --cd <DeployDir> --exec bash deploy/update.sh …
  От root: каталог развёртывания клонирует root (README, «Перенос стека в
  каталог развёртывания»), и владелец клона совпадает с вызывающим — git не
  отказывает по dubious ownership. Код update.sh возвращается как есть.

  После кода 0 без -DryRun — engine-setup.ps1 -Check рядом со сценарием:
  звенья хоста (firewall, portproxy, задачи, .wslconfig) от образа не
  зависят, поэтому их провал образ не откатывает — код 5 и список звеньев
  в выводе -Check.

  Коды:
    0 — обновлено (или сухой прогон);
    1 — отказ до первого изменения (обёртка или update.sh);
    2 — ошибка вызова update.sh;
    3 — провал, откат выполнен, стек на прежнем коммите отвечает;
    4 — провал и отказ отката — нужен человек;
    5 — обновлено, но engine-setup.ps1 -Check красный.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File deploy/windows/update.ps1 -DryRun
  powershell -ExecutionPolicy Bypass -File deploy/windows/update.ps1
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    # Целевой коммит; без него — голова main на origin.
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$Ref = '',
    # Первый запуск из каталога развёртывания: стек ещё поднят из клона Windows.
    [switch]$Adopt,
    # Тот же шаблон, что у -DeployDir в engine-setup.ps1: абсолютный путь
    # без пробелов, кавычек и сегментов . и .. — он уходит в --cd wsl.exe и
    # в -Check.
    [ValidatePattern('^(/[A-Za-z0-9_][A-Za-z0-9._-]*)+$')]
    [string]$DeployDir = '/srv/domovoy',
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$Distro = 'domovoy-engine',
    # wsl.exe; тест подменяет его, чтобы видеть вызовы.
    [string]$WslExe = (Join-Path $env:SystemRoot 'System32\wsl.exe')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Вывод в UTF-8: причины отказа и вывод bash читаются тестом и человеком
# одинаково, а консоль русской Windows — CP866. Без консоли установка может
# бросить — тогда кодировка не меняется.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

function Stop-WithRefusal([string]$Text) {
    [Console]::Error.WriteLine("update.ps1: отказ: $Text")
    exit 1
}

# wsl.exe: stdout и stderr раздельно, как Invoke-Wsl в measure-boot.ps1.
function Invoke-Wsl([string[]]$Arguments) {
    $env:WSL_UTF8 = '1'
    $previousAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = New-Object System.Collections.Generic.List[string]
    $err = New-Object System.Collections.Generic.List[string]
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
    }
    return [pscustomobject]@{ Code = $code; Lines = @($out); ErrLines = @($err | Where-Object { $_.Trim() }) }
}

# Имена из wsl.exe --list. Если wsl.exe WSL_UTF8 не учёл и отдал UTF-16LE
# с BOM, между буквами остаются NUL, а BOM — U+FEFF или U+FFFD: они
# убираются во всей строке.
function ConvertFrom-WslList([string[]]$Lines) {
    $text = ($Lines -join "`n") -replace "[\u0000﻿�]", ''
    return @($text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# Ordinal, а не -contains: культурное сравнение пропускает NUL.
function Test-DistroListed([string[]]$Arguments) {
    $list = Invoke-Wsl $Arguments
    if ($list.Code -ne 0) {
        Stop-WithRefusal ("wsl.exe {0} — код {1}: {2}" -f ($Arguments -join ' '), $list.Code, ($list.ErrLines -join ' '))
    }
    return [bool]@(ConvertFrom-WslList $list.Lines | Where-Object { [string]::Equals($_, $Distro, [StringComparison]::OrdinalIgnoreCase) }).Count
}

if (-not (Test-Path -LiteralPath $WslExe -PathType Leaf)) {
    Stop-WithRefusal "не найден $WslExe — WSL не установлен"
}

if (-not (Test-DistroListed @('--list', '--quiet'))) {
    Stop-WithRefusal "дистрибутив $Distro не зарегистрирован — движок не установлен (deploy/windows/engine-setup.ps1 -Install)"
}

if (-not (Test-DistroListed @('--list', '--running', '--quiet'))) {
    Stop-WithRefusal "дистрибутив $Distro не работает — движок не запущен; обновление его не поднимает (README, «Автозапуск после перезагрузки»)"
}

$probe = Invoke-Wsl @('-d', $Distro, '-u', 'root', '--exec', 'test', '-d', "$DeployDir/.git")
if ($probe.Code -ne 0) {
    Stop-WithRefusal "каталог развёртывания $DeployDir не найден в $Distro (нет $DeployDir/.git) — README, «Перенос стека в каталог развёртывания»"
}

$updateArgs = New-Object System.Collections.Generic.List[string]
foreach ($a in @('-d', $Distro, '-u', 'root', '--cd', $DeployDir, '--exec', 'bash', 'deploy/update.sh')) { $updateArgs.Add($a) }
if ($DryRun) { $updateArgs.Add('--dry-run') }
if ($Adopt) { $updateArgs.Add('--adopt') }
if ($Ref) { $updateArgs.Add('--ref'); $updateArgs.Add($Ref) }

# Вывод update.sh идёт как есть, без перехвата: обновление длится минуты,
# и строки нужны по мере появления.
$env:WSL_UTF8 = '1'
$previousAction = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & $WslExe @($updateArgs.ToArray())
    $code = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previousAction
}

if ($code -ne 0 -or $DryRun) { exit $code }

$check = Join-Path $PSScriptRoot 'engine-setup.ps1'
$shell = (Get-Process -Id $PID).Path
Write-Output 'update.ps1: обновление готово, проверка хоста: engine-setup.ps1 -Check'
& $shell -NoProfile -ExecutionPolicy Bypass -File $check -Check -DeployDir $DeployDir
if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine('update.ps1: стек обновлён, но engine-setup.ps1 -Check красный — звенья выше; образ не откатывается: они от него не зависят')
    exit 5
}
exit 0
