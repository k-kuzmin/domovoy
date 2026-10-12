# shellcheck shell=bash
# Настройки бэкапа из .env клона — для backup.sh и restore.sh (source).
#
# .env не исполняется: в нём значения вида <ha-long-lived-token>, которые
# source превратил бы в перенаправления. Читаются только строки ровно
# KEY=значение; последняя строка с ключом побеждает, CR в конце снимается.
# Дальше — как compose: значение в кавычках — текст между ними, после
# закрывающей допустим только комментарий ` # …`; без кавычек хвостовой
# комментарий (пробел или таб перед #) и пробелы по краям снимаются,
# a#b остаётся a#b. Та же логика — Get-DotEnvValue в install-schedule.ps1.

# dotenv_value <файл> <ключ> — значение из файла; нет файла или строки — пусто.
dotenv_value() {
  local file="$1" key="$2" line value=''
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      "$key="*) value="${line#"$key="}" ;;
    esac
  done <"$file"
  value="${value#"${value%%[![:blank:]]*}"}"
  local double_quoted='^"([^"]*)"[[:blank:]]*(#.*)?$'
  local single_quoted="^'([^']*)'[[:blank:]]*(#.*)?\$"
  if [[ "$value" =~ $double_quoted ]] || [[ "$value" =~ $single_quoted ]]; then
    value="${BASH_REMATCH[1]}"
  else
    value="${value%%[[:blank:]]#*}"
    value="${value%"${value##*[![:blank:]]}"}"
  fi
  printf '%s' "$value"
}

# backup_setting <ключ> <корень-клона> — переменная окружения, если она
# задана (даже пустой), иначе значение из <корень>/.env. Значение с
# плейсхолдером в угловых скобках, как в .env.example, — не задано.
backup_setting() {
  local key="$1" root="$2" value
  if [ -n "${!key+x}" ]; then
    value="${!key}"
  else
    value="$(dotenv_value "$root/.env" "$key")"
  fi
  case "$value" in
    *'<'*'>'*) value='' ;;
  esac
  printf '%s' "$value"
}
