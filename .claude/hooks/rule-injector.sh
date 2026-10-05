#!/usr/bin/env bash
# PreToolUse / UserPromptSubmit: впрыск напоминания о правиле проекта.
# Таблица — rules-map.json рядом, движок — rule-injector.py рядом.
#
# Этот скрипт — предфильтр на чистом bash. Хук висит на Write, Edit, MultiEdit,
# NotebookEdit, Bash и PowerShell, то есть на самых частых вызовах, а полный путь «bash →
# поиск интерпретатора → python → разбор таблицы» стоит сотни миллисекунд на вызов.
# Поэтому два сокращения.
#
# 1. ПРЕДФИЛЬТР. Отсеиваем вызовы, которые заведомо ни с чем не совпадут, не запуская
#    python вовсе. Фильтр построен от таблицы: КАЖДОЕ правило для Write и Edit требует
#    совпадения по пути или по содержимому правки (кроме счётчика собственных правок —
#    его ведёт сама обёртка, см. own_edit_threshold), а правило для Bash и PowerShell —
#    формы git- или gh-команды либо записи в защищаемый путь. Проверки независимы: ни
#    одна не отменяет другую. Остальные инструменты (Agent) и реплика человека идут в
#    python без фильтра.
#    **Новый путь или форма команды без строки здесь молча не срабатывает.** Добавил
#    правило в таблицу — допиши сюда; тест таблицы гоняет каждую её строку через этот
#    скрипт и ловит забытое.
#    Сверяется только ввод инструмента (tool_input), а не весь вход хука: в нём ещё
#    transcript_path и cwd, а путь журнала сессии лежит в ~/.claude/projects/ и
#    совпадал бы с шаблоном .claude/ на КАЖДОМ вызове.
# 2. КЕШ ИНТЕРПРЕТАТОРА. Найденный путь python запоминается рядом со скриптом
#    (.python-path) и переиспользуется. Это и точка подмены: что записано в кеше, то и
#    исполняется, поэтому кеш сверяется с именем python, а не берётся на веру.
#
# Код выхода — всегда 0: напоминание не граница, и сбой хука не вправе блокировать вызов.
# Без python хук пропускает вызов молча.

# Пути, которые интересуют правила на пути (миграции, зависимости, конфигурация, новый
# файл правила). Функция, а не две копии case: обе ветки — правка инструментом и правка
# командой — спрашивают одно и то же, а разошедшиеся копии отличались бы молча.
touches_protected_path() {
  # Каталог миграций — без хвостового слэша: `cd src/Domovoy.Data/Migrations && sed -i …
  # X.cs` называет каталог без него, а файл — голым именем.
  # Обратные слэши — в прямые: на Windows Write и Edit присылают путь вида
  # D:\\x\\src\\..., и шаблоны со слэшем молча отсекали бы вызов до python. Заменяем
  # ПАРУ: в JSON каждый обратный слэш экранирован.
  # Замена идёт по срезу, а не по всему вводу: глобальная замена `${x//…/…}` квадратична
  # по числу совпадений, и Write в мегабайт текста с путями Windows стоил бы минуты.
  # Кроме начала — ещё и хвост: команда пишет файл, где захочет, и путь цели нередко
  # стоит последней строкой после длинного тела. `${1: -4096}` — с пробелом перед
  # минусом, иначе bash 3.2 прочтёт это как подстановку значения по умолчанию.
  local probe="${1:0:32768}"
  [ "${#1}" -gt 32768 ] && probe="$probe ${1: -4096}"
  probe="${probe//\\\\//}"
  case "$probe" in
    *domovoy.data/migrations*|*directory.packages.props*|*appsettings*.json*|*options.cs*) return 0 ;;
  esac
  # Эти пути нужны только правилам на СОЗДАНИЕ файла (new_file_only): новое правило в
  # docs/rules/. Правка существующего файла через Edit их не задевает.
  [ "$2" = "edit" ] && return 1
  case "$probe" in
    *docs/rules/*) return 0 ;;
  esac
  return 1
}

# Признак в СОДЕРЖИМОМ правки .cs: реализация IAgentTool (правило agent-tool) и
# AllowAnonymous (правило anonymous-endpoint). Путь сам по себе ничего не решает — любой
# .cs, — поэтому нужны оба признака. Содержимое смотрится срезом: признак в середине
# мегабайтного Write не стоит квадратичного разбора.
cs_content_marker() {
  case "$_path" in *.cs) ;; *) return 1 ;; esac
  case "${ti:0:262144}" in *iagenttool*|*allowanonymous*) return 0 ;; esac
  return 1
}

# Каталог скрипта — срезом строки, а не `$(cd "$(dirname …)" && pwd)`: подстановка команды
# — это форк, а на Windows форк стоит десятки миллисекунд на каждом вызове хука. Путь может
# прийти с обратными слэшами (запуск из Python на Windows), поэтому срезаем по обоим видам и
# берём более короткий срез. Обратный слэш — через переменную: внутри "${x%…}" в кавычках
# `\\` превращается в экранирование звёздочки.
_src="${BASH_SOURCE[0]}"; _bs='\'
DIR="${_src%/*}"; _alt="${_src%"$_bs"*}"
if [ "$DIR" = "$_src" ] || { [ "$_alt" != "$_src" ] && [ "${#_alt}" -gt "${#DIR}" ]; }; then
  DIR="$_alt"
fi
[ "$DIR" = "$_src" ] && DIR="."

# Ключ учёта «сессия плюс агент» в глобальные _scope и _aid; считается один раз на вызов.
# Результат — в переменных, а не через $(…): подстановка команды — форк. Только встроенные
# средства bash. agent_id ищется ещё и в хвосте: порядок полей не обещан, а субагент,
# принятый за главного агента, получил бы напоминание о пороге делегирования, которое
# адресовано оркестратору. Пустой _scope — учёт невозможен. Формула — та же, что
# fired_scope() в rule-injector.py.
_scope=""; _aid=""; _scope_done=""
hook_scope() {
  [ -n "$_scope_done" ] && return 0
  _scope_done=1
  local head="${1:0:3000}" tail="" sid=""
  [ "${#1}" -gt 3000 ] && tail="${1: -4096}"
  case "$head" in *'"session_id"'*)
    sid="${head#*\"session_id\"}"; sid="${sid#*\"}"; sid="${sid%%\"*}" ;;
  esac
  case "$head" in
    *'"agent_id"'*) _aid="${head#*\"agent_id\"}" ;;
    *) case "$tail" in *'"agent_id"'*) _aid="${tail##*\"agent_id\"}" ;; esac ;;
  esac
  _aid="${_aid#*\"}"; _aid="${_aid%%\"*}"
  sid="${sid//[^A-Za-z0-9_]/}"; _aid="${_aid//[^A-Za-z0-9_]/}"
  _scope="${sid:0:40}"
  [ -n "$_scope" ] && [ -n "$_aid" ] && _scope="$_scope-${_aid:0:40}"
  return 0
}

# Значение file_path (notebook_path) в _path: от кавычки до кавычки, слэши прямые. Срез fp
# несёт после пути ещё и начало текста правки, а проверки ниже решают по самому пути:
# упоминание каталога в тексте правки не должно ни включать, ни исключать правило. Ключа не
# нашли (fp — ввод целиком) — _path пуст.
_path=""
path_value() {
  [ -n "$fp_key" ] || return 0
  local v="${fp#*\"}"
  v="${v%%\"*}"
  _path="${v//\\\\//}"
}

# Первая правка кода в сессии — повод напомнить карточку развилки (правило ceremony-card,
# bash_flag). Напоминание одно на сессию и агента, а правка кода — самый частый вызов,
# поэтому после первого раза python не запускается вовсе: его флаг-файл виден здесь.
# Список каталогов и расширений — тот же, что path_any и path_ext правила в таблице.
first_code_edit() {
  local p="$_path"
  case "$p" in
    *src/*|*tests/*) ;;
    *) return 1 ;;
  esac
  case "$p" in
    *.cs|*.csproj|*.xaml) ;;
    *) return 1 ;;
  esac
  hook_scope "$1"
  [ -n "$_scope" ] || return 0
  [ -e "$DIR/.rule-flags/$_scope-ceremony-card" ] && return 1
  return 0
}

# Первая правка обвязки — повод спросить про совет (правило harness-edit-council,
# bash_flag). Устроено как first_code_edit: после первого напоминания python на таких
# правках не запускается. Список — тот же, что path_any и repo_root_any правила; python
# сверяет .claude/CLAUDE.md и .claude/settings.json с корнем репозитория, а здесь они
# ловятся в любом каталоге: предфильтр обязан быть шире разбора — лишнее совпадение стоит
# запуска python, пропущенное стоит правила.
first_harness_edit() {
  local p="$_path"
  [ -n "$p" ] || return 1
  case "$p" in
    *.claude/skills/*|*.claude/hooks/*|*.claude/agents/*|*.claude/claude.md|\
    *.claude/settings.json|*.claude/settings.local.example.json|*docs/rules/*|*scripts/*|*.github/*|*.githooks/*|\
    *.gitleaks.toml) ;;
    *) return 1 ;;
  esac
  hook_scope "$input"
  [ -n "$_scope" ] || return 0
  [ -e "$DIR/.rule-flags/$_scope-harness-edit-council" ] && return 1
  return 0
}

# Счётчик разных файлов, правленных самим главным агентом (правило
# delegation-thresholds-own-edits): страховка порога делегирования, который иначе никто не
# проверяет снаружи. Считается здесь, а не в python: правка — самый частый вызов. Файл —
# пустой маркер в .rule-flags, число файлов — глоб по маркерам сессии. python зовётся
# только на пороге (4-й и 7-й файл), число уходит ему переменной RI_OWN_EDITS.
# Условие «не меньше порога и порог ещё не отмечен», а не «ровно порог»: хуки параллельных
# вызовов идут одновременно, два новых файла разом видят 5 — и точное 4 проскочило бы.
# Субагенты не считаются: они и есть делегирование. Не считаются журнал и план задачи
# (docs/tasks/), вердикты совета (.council/ — их сохраняет оркестратор, по три-четыре за
# круг), память и scratchpad сессии: это не правки кода.
# Слабые места: запись командой (sed, heredoc) не считается, счёт идёт на сессию, а не на
# задачу, и регистр пути не сводится (bash 3.2 без ${x,,}) — один файл в двух написаниях
# посчитается дважды.
own_edit_threshold() {
  [ -n "$_path" ] || return 1
  hook_scope "$input"
  { [ -n "$_scope" ] && [ -z "$_aid" ]; } || return 1
  case "$_path" in
    *docs/tasks/*|*.council/*|*/.claude/projects/*|*/temp/claude/*|*/tmp/claude*|*/T/claude*) return 1 ;;
  esac
  # Хвост имени, а не путь целиком: на Windows полный путь каталога флагов, scope и путь
  # файла вместе упираются в предел длины пути в 260 символов.
  local k="${_path//[^A-Za-z0-9_]/_}" d="$DIR/.rule-flags"
  [ "${#k}" -gt 120 ] && k="${k: -120}"
  [ -e "$d/$_scope-own-edit-$k" ] && return 1
  [ -d "$d" ] || mkdir -p "$d" 2>/dev/null
  : > "$d/$_scope-own-edit-$k" 2>/dev/null || return 1
  # nullglob только на время глоба: без него пустой глоб считается за один файл.
  local had_null="" n t
  shopt -q nullglob && had_null=1
  shopt -s nullglob
  set -- "$d/$_scope-own-edit-"*
  n=$#
  [ -n "$had_null" ] || shopt -u nullglob
  for t in 7 4; do
    [ "$n" -ge "$t" ] || continue
    [ -e "$d/$_scope-own-thr$t" ] && return 1
    : > "$d/$_scope-own-thr$t" 2>/dev/null
    RI_OWN_EDITS="$n"; export RI_OWN_EDITS
    return 0
  done
  return 1
}

# Вход читается как есть, байтами: разбирает его python, сам декодируя UTF-8 (кодировка
# консоли на Windows — cp1251, и она испортила бы русский текст).
input=$(cat 2>/dev/null) || exit 0
[ -n "$input" ] || exit 0
# Число правок передаёт только own_edit_threshold этого же вызова; унаследованное от
# родителя значение подняло бы правило о пороге на каждой правке.
unset RI_OWN_EDITS

# Регистронезависимость через shopt, а не через tr: tr — отдельный процесс на КАЖДЫЙ
# вызов хука. Именно shopt, а не ${var,,}: подстановка требует bash 4, а на macOS до сих
# пор стоковый bash 3.2.
shopt -s nocasematch

# Ввод инструмента: всё, что после ключа "tool_input". Claude Code кладёт transcript_path
# и cwd раньше него, и этого достаточно, чтобы путь журнала не совпадал с .claude/.
# Хвост справа (tool_use_id) НЕ снимается: `${x%,"tool_use_id"*}` в bash квадратичен по
# длине строки. Не нашли ключ — сверяем весь вход: шире значит медленнее, но не глухо.
ti="$input"
case "$ti" in *'"tool_input":'*) ti="${ti#*\"tool_input\":}" ;; esac

# Путь файла у Write / Edit / MultiEdit / NotebookEdit — срез от ключа file_path
# (notebook_path) на килобайт: пути правил сверяются с ним, а не с содержимым файла. Ключ
# ищется в начале ввода; нет там — в хвосте (модель вправе прислать content раньше
# file_path); нет и там — ввод целиком, touches_protected_path сверит его начало и хвост.
fp="$ti"; fp_key=""
case "${ti:0:4096}" in
  *'"file_path":'*) fp="${ti#*\"file_path\":}"; fp="${fp:0:1024}"; fp_key=1 ;;
  *'"notebook_path":'*) fp="${ti#*\"notebook_path\":}"; fp="${fp:0:1024}"; fp_key=1 ;;
  *)
    if [ "${#ti}" -gt 4096 ]; then
      tail_ti="${ti: -4096}"
      case "$tail_ti" in
        *'"file_path":'*) fp="${tail_ti##*\"file_path\":}"; fp="${fp:0:1024}"; fp_key=1 ;;
        *'"notebook_path":'*) fp="${tail_ti##*\"notebook_path\":}"; fp="${fp:0:1024}"; fp_key=1 ;;
      esac
    fi
    ;;
esac

# Счётчик правок стоит первым в цепочке: маркер файла ставится на каждой правке, а не только
# на той, что не прошла остальные проверки.
case "$input" in
  *'"tool_name":"Write"'*|*'"tool_name": "Write"'*)
    path_value
    own_edit_threshold || touches_protected_path "$fp" || cs_content_marker ||
      first_code_edit "$input" || first_harness_edit || exit 0
    ;;
  *'"tool_name":"Edit"'*|*'"tool_name": "Edit"'*|\
  *'"tool_name":"MultiEdit"'*|*'"tool_name": "MultiEdit"'*|\
  *'"tool_name":"NotebookEdit"'*|*'"tool_name": "NotebookEdit"'*)
    path_value
    own_edit_threshold || touches_protected_path "$fp" edit || cs_content_marker ||
      first_code_edit "$input" || first_harness_edit || exit 0
    ;;
  *'"tool_name":"Bash"'*|*'"tool_name": "Bash"'*|\
  *'"tool_name":"PowerShell"'*|*'"tool_name": "PowerShell"'*)
    # Независимые пропуски в python. Любой сработал — идём дальше; ни один — промах.
    # Списки шире разбора в python: лишнее совпадение (`git stash push`, упоминание в
    # тексте) стоит только запуска python, а начало команды, --dry-run и прочее различает
    # command_regex таблицы.
    pass=""
    # 1. Ветвление и пуш (one-task-one-branch, pr-create).
    case "$ti" in
      *git*" push"*|*"checkout "*"-b"*|*"switch "*"-c"*) pass=1 ;;
    esac
    # 2. Заведение задачи (issue-create).
    case "$ti" in *gh*"issue"*"create"*) pass=1 ;; esac
    # 3. Правка файла командой. Системный промпт местами предписывает менять файлы
    #    командой (sed, heredoc), поэтому пускаем при двух признаках сразу — защищаемый
    #    путь (или признак содержимого .cs) И форма записи. Одного пути мало: `cat` и `grep`
    #    по тем же файлам часты, а читать их никто не запрещал.
    if [ -z "$pass" ]; then
      hit=""
      touches_protected_path "$ti" && hit=1
      case "${ti:0:262144}" in *.cs*) case "${ti:0:262144}" in
        *iagenttool*|*allowanonymous*) hit=1 ;; esac ;; esac
      if [ -n "$hit" ]; then
        case "$ti" in
          *" > "*|*" >> "*|*"tee "*|*"sed -i"*|*"cp "*|*"mv "*|*"rm "*|*"touch "*|\
          *"<<"*|*set-content*|*out-file*|*add-content*|*new-item*|*remove-item*|\
          *copy-item*|*move-item*|*rename-item*|*writealltext*|*writeallbytes*|\
          *writealllines*|*".write("*|*".write_text("*|*".write_bytes("*|\
          *"'w'"*|*'"w"'*|*"git apply"*|*"checkout"*) pass=1 ;;
        esac
      fi
    fi
    [ -n "$pass" ] || exit 0
    ;;
esac

CACHE="$DIR/.python-path"
PY=""
if [ -r "$CACHE" ]; then
  # read, а не $(cat …): подстановка команды — лишний форк на каждом вызове хука.
  read -r PY < "$CACHE" 2>/dev/null
  # Кеш обязан указывать на python. Посторонний бинарь под exec отдал бы свой код выхода
  # как код хука, а код 2 у PreToolUse блокирует вызов инструмента. Имя сверяется по
  # последнему компоненту пути с любым из двух разделителей (на Windows кеш хранит `\`);
  # не python — кеш игнорируется и перезаписывается поиском ниже.
  _pyname="${PY##*/}"; _pyname="${_pyname##*"$_bs"}"
  case "$_pyname" in python*|py|py.exe) ;; *) PY="" ;; esac
  # Абсолютный путь проверяем существованием файла, а не `command -v`: последний —
  # отдельный процесс на каждый вызов хука.
  case "$PY" in
    /*|[A-Za-z]:[/\]*) [ -x "$PY" ] || PY="" ;;
    "") ;;
    *) command -v "$PY" >/dev/null 2>&1 || PY="" ;;
  esac
fi
if [ -z "$PY" ]; then
  for cand in python3 python py; do
    if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import sys" >/dev/null 2>&1; then
      # Кешируем АБСОЛЮТНЫЙ путь: на Windows имена python3/python резолвятся через
      # стаб App Execution Alias, и старт через него втрое дороже прямого exe.
      PY=$("$cand" -c "import sys; print(sys.executable)" 2>/dev/null)
      [ -n "$PY" ] && [ -x "$PY" ] || PY="$cand"
      printf '%s' "$PY" > "$CACHE" 2>/dev/null
      break
    fi
  done
fi
# Без python хук пропускает вызов: напоминание — не граница, и машина без python не
# должна вставать целиком.
[ -z "$PY" ] && exit 0

# exec и here-string вместо `printf | python`: конвейер держит лишний процесс bash, который
# ждёт python. Here-string дописывает перевод строки в конце — разбору JSON он безразличен.
# С exec код выхода хука — это код выхода python: код 1 даёт «hook error» в транскрипте на
# каждом вызове, код 2 у PreToolUse блокирует вызов инструмента. Поэтому скрипт запускается
# не напрямую, а коротким загрузчиком: он гасит всё, что main() поймать не может, —
# синтаксическую ошибку в самом файле, ошибку импорта — и всегда выходит с 0.
[ -f "$DIR/rule-injector.py" ] || exit 0
exec "$PY" -c 'import sys
p = sys.argv[1]
try:
    exec(compile(open(p, "rb").read(), p, "exec"), {"__name__": "__main__", "__file__": p})
except BaseException:
    pass
sys.exit(0)' "$DIR/rule-injector.py" 2>/dev/null <<<"$input"
