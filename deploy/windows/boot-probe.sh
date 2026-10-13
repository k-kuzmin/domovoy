#!/usr/bin/env bash
# Зонд хронологии загрузки внутри дистрибутива domovoy-engine (#147).
#
#   wsl.exe -d domovoy-engine -u root --cd <клон> --exec bash deploy/windows/boot-probe.sh <проект compose>
#
# Вызывает deploy/windows/measure-boot.ps1 на каждом опросе — и только
# когда дистрибутив уже работает: сам зонд дистрибутив не поднимает, это
# делает wsl.exe, а замер проверяет список работающих до вызова.
#
# Печатает строки key=value; все моменты — секунды Unix (epoch): они не
# зависят от часового пояса ВМ, и замер переводит их в местное время
# Windows без неоднозначности. Местное время с зоной зонд не печатает.
#
#   distro_start=<секунды>   старт дистрибутива: сейчас минус возраст PID 1
#                            (ps -o etimes=);
#   docker_active=<секунды>  docker.service перешёл в active
#                            (systemctl show --timestamp=unix);
#   container name=<имя> started_at=<секунды> health=<состояние>
#                            по строке на контейнер проекта: последний
#                            старт ({{.State.StartedAt}}, UTC) и состояние
#                            healthcheck, без него — none. Не печатается
#                            контейнер, ни разу не стартовавший, и
#                            неработающий (.State.Running false): у него
#                            StartedAt и Health.Status прошлого запуска.
#
# Код не 0 — данных на этом опросе нет или они неполные: docker.service ещё
# не active или docker не ответил. Напечатанное до отказа замер засчитывает
# построчно.

set -euo pipefail

project="${1:-}"
[ -n "$project" ] || { echo "boot-probe: нужен аргумент — имя проекта compose" >&2; exit 2; }

now="$(date +%s)"
age="$(ps -o etimes= -p 1 | tr -d '[:space:]')"
case "$age" in
  '' | *[!0-9]*) echo "boot-probe: возраст PID 1 не разобран: «$age»" >&2; exit 1 ;;
esac
echo "distro_start=$((now - age))"

active="$(systemctl show docker.service --timestamp=unix -p ActiveEnterTimestamp --value)"
active="${active#@}"
case "$active" in
  '' | *[!0-9]* | 0) echo "boot-probe: docker.service ещё не active" >&2; exit 1 ;;
esac
echo "docker_active=$active"

names="$(docker ps -a --filter "label=com.docker.compose.project=$project" --format '{{.Names}}')"
[ -n "$names" ] || exit 0
# shellcheck disable=SC2086 # имена контейнеров compose без пробелов
inspected="$(docker inspect -f '{{.Name}}|{{.State.StartedAt}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.State.Running}}' $names)"
while IFS='|' read -r name started health running; do
  [ -n "$name" ] || continue
  [ "$running" = true ] || continue
  # Ни разу не стартовавший контейнер: StartedAt 0001-01-01T00:00:00Z.
  case "$started" in 0001-*) continue ;; esac
  seconds="$(date -u -d "$started" +%s)"
  echo "container name=${name#/} started_at=$seconds health=$health"
done <<<"$inspected"
