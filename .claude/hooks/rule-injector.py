#!/usr/bin/env python3
"""PreToolUse / UserPromptSubmit-хук: впрыскивает напоминание о правиле, когда действие
задевает защищаемое место.

Зачем. Правила проекта лежат в `.claude/CLAUDE.md` и `docs/rules/` и читаются по
надобности. Для правил с ТИХИМ отказом (не падает, а молча портит данные или процесс)
«по надобности» ненадёжно: надобность как раз и не осознаётся. Хук делает её видимой —
кладёт напоминание ровно в тот момент, когда рука уже занесена над защищаемым местом.

Напоминание не заменяет чтения файла: в тексте всегда стоит путь к правилу.

Разбирается ИМЕННО ввод инструмента (tool_input), а не сырой stdin: сырой вход несёт
ещё путь журнала сессии и cwd, и совпадение по ним было бы совпадением ни с чем.

Одно правило — одно напоминание на сессию и агента: повтор на каждой правке того же
файла превращает подсказку в шум, который перестают читать. Исключение — правила, у
которых в таблице стоит "repeat": true.

Таблица — `.claude/hooks/rules-map.json`. Движок перенесён из соседнего проекта и
очищен от его специфики; ключи таблицы, которые он понимает, перечислены в
KNOWN_KEYS, и тест таблицы держит набор закрытым.
"""
import json
import os
import re
import sys
import time
# tempfile импортируется в функции, где нужен: хук висит на самых частых вызовах, и
# каждый модуль на старте стоит времени.

HOOK_DIR = os.path.dirname(os.path.abspath(__file__))
MAP_PATH = os.path.join(HOOK_DIR, "rules-map.json")
REPO = os.path.dirname(os.path.dirname(HOOK_DIR))

# Условия по вызову инструмента. Правило без единого из них — правило только для
# реплики человека или только для промпта субагента: с вызовами оно не совпадает.
TOOL_SIDE = ("tools", "path_any", "path_all", "path_ext", "repo_root_any", "command_any",
             "command_regex", "input_field", "input_fields")
PATH_KEYS = ("path_any", "path_all", "path_ext", "repo_root_any")
# Все ключи, которые движок читает. Опечатка в ключе ничем себя не проявляет — правило
# просто перестаёт совпадать, — поэтому тест таблицы сверяет её с этим списком.
KNOWN_KEYS = set(TOOL_SIDE) | {
    "name", "note", "doc", "repeat", "new_file_only", "existing_file_only", "skip_path_any",
    "input_any", "prompt_any", "prompt_note", "prompt_regex", "for_subagents",
    "subagent_note", "bash_flag", "no_shell", "shell_targets_only", "own_edits_gate",
}


def rule_path(rule):
    """Где лежит правило: явный `doc` из таблицы либо docs/rules/<имя>.md.

    Существование проверяется, но при отсутствии обоих возвращается первый кандидат —
    молча. Поэтому существование `doc` держит тест таблицы, а не этот код.
    """
    name = rule["name"] if isinstance(rule, dict) else rule
    cands = []
    if isinstance(rule, dict) and rule.get("doc"):
        cands.append(rule["doc"])
    cands.append("docs/rules/%s.md" % name)
    for rel in cands:
        if os.path.exists(os.path.join(REPO, rel)):
            return rel
    return cands[0]


def norm(path):
    """Прямые слэши и нижний регистр — сравнение не должно зависеть от ОС."""
    return str(path or "").replace("\\", "/").lower()


def at_repo_root(cand, entries):
    """Путь лежит в корне этого репозитория: файл (`.claude/CLAUDE.md`) или каталог.

    Подстрока здесь не годится: такие же имена бывают в чужих каталогах (рабочие копии,
    личные настройки пользователя), и шаблон по подстроке задевал бы и их. Сравнение
    идёт с путём от корня, который хук знает по своему расположению, а относительный
    путь (запуск из корня) — с самим шаблоном.
    """
    root = norm(REPO).rstrip("/") + "/"
    for entry in entries:
        e = norm(entry)
        for full in (root + e, e):
            if (cand.startswith(full) if e.endswith("/") else cand == full):
                return True
    return False


def tool_matches(rule, tool_name):
    """Имя инструмента: точное совпадение либо префикс (для групп mcp__*).

    Правило, которое ловится путём, ловится и у Bash с PowerShell, даже если в
    таблице перечислены только Write и Edit. Иначе выбор инструмента решает, придёт
    ли правило: один и тот же файл, правленный `sed`'ом или heredoc'ом вместо Write,
    проходил мимо ловушки молча.

    Исключение — "no_shell": true. Путь из команды выловлен грубо: любой путь-подобный
    токен при признаке записи, включая текст heredoc'а. Правилу, которое срабатывает
    один раз на сессию, такое ложное совпадение не шумит, а гасит его: учёт «уже
    напоминали» ставится на команде, где файл только упомянут, и настоящая правка
    проходит молча.
    """
    wanted = rule.get("tools") or []
    if not wanted:
        return True
    if any(tool_name == w or tool_name.startswith(w) for w in wanted):
        return True
    if rule.get("no_shell"):
        return False
    return tool_name in ("Bash", "PowerShell") and any(rule.get(k) for k in PATH_KEYS)


# Признаки того, что команда ФАЙЛ ПИШЕТ, а не читает. Нужны, чтобы `cat` и `grep` по
# защищаемому пути не поднимали правило: читать эти файлы никто не запрещал.
#
# Короткие глаголы ищутся ТОЛЬКО как отдельные слова. Подстрокой `rm ` ловились
# «confi(rm t)est», «perfo(rm c)heck» — то есть обычное английское слово в комментарии
# превращало чтение в запись. Такое срабатывание хуже пропуска: оно учит пролистывать
# напоминание не читая.
#
# Список покрывает обе оболочки: в PowerShell запись идёт не перенаправлением, а
# глаголами (`Copy-Item`, `Move-Item`) или вызовом .NET.
_WRITE_WORDS = ("rm", "cp", "mv", "tee", "touch", "truncate", "install",
                # Алиасы PowerShell: в нём пишут `ni`, `ren`, `del`, `copy`, а не
                # полные Copy-Item и New-Item. Короткие формы и есть идиоматичные.
                "ni", "ri", "sc", "si", "ren", "del", "erase", "copy", "move", "rd",
                "rmdir", "unlink", "shred", "dd")
_WRITE_LITERALS = (" > ", " >> ", "sed -i", "<<", "set-content", "out-file",
                   "add-content", "new-item", "remove-item", "copy-item", "move-item",
                   "rename-item", "writealltext", "writeallbytes", "writealllines",
                   ".write(", ".write_text(", ".write_bytes(", "'w'", '"w"')
# Формы, которые словом или литералом не выражаются: `git checkout <ref> -- <путь>`
# перезаписывает файл из другой ревизии, а `git apply` накладывает патч.
_WRITE_PATTERNS = (re.compile(r"git\s+checkout\b[^|;&]*\s--\s"),
                   re.compile(r"git\s+apply\b"))
_WRITE_WORD_RE = re.compile(r"(?<![\w./-])(?:%s)\s" % "|".join(_WRITE_WORDS))


def has_write_marker(command):
    """Похоже ли, что команда пишет файл. Нормализованная строка на входе."""
    if any(lit in command for lit in _WRITE_LITERALS):
        return True
    if _WRITE_WORD_RE.search(command):
        return True
    return any(p.search(command) for p in _WRITE_PATTERNS)


# Токен, похожий на путь: либо с буквой диска, либо со слэшем и расширением.
_PATH_TOKEN = re.compile(r"""[a-z]:[\/][^\s'"`;|()<>]+|[^\s'"`;|()<>]*[\/][^\s'"`;|()<>]*\.[a-z0-9]{1,8}""")
# Голое имя файла с расширением и каталог из `cd ...` перед ним: в heredoc'ах путь к
# файлу почти всегда относительный, и без склейки с каталогом условие вида «каталог И
# расширение» не сходится.
_BARE_TOKEN = re.compile(r"""(?<![\w./\\-])[\w-]+\.[a-z0-9]{1,8}(?![\w./\\-])""")
_CD_TARGET = re.compile(r"""(?:^|&&|;|\n)\s*cd\s+["']?([^"'&;\n]+)""")


_PATHS_CACHE = {}


def command_paths(command):
    """Пути, которые команда предположительно пишет (уже нормализованная строка).

    Разбор нарочно грубый: точный список записываемых файлов из произвольного шелла
    не вывести, а цена ошибки несимметрична. Лишнее напоминание — это одна строка раз
    в сессию, пропущенное — молча нарушенное правило.
    """
    if not has_write_marker(command):
        return []
    bases = [b.strip().rstrip("/") for b in _CD_TARGET.findall(command)]
    out = []
    for tok in _PATH_TOKEN.findall(command):
        out.append(tok)
        if not tok.startswith("/") and not re.match(r"^[a-z]:", tok):
            out.extend(base + "/" + tok for base in bases)
    # Голое имя файла после `cd` в его каталог: `cd src/Domovoy.Data/Migrations && sed -i …
    # X.cs`. Слэша в имени нет, и токен пути его не видит. Одно голое имя без `cd`
    # кандидатом не становится: оно слишком часто просто упомянуто в тексте. И даже после
    # `cd` берётся только имя в позиции цели записи — не из текста заметки
    # (`echo 'см. X.cs' > notes.txt`, тело `cat > notes.md <<EOF`).
    if bases:
        for tok in write_targets(command):
            if _BARE_TOKEN.fullmatch(tok):
                out.extend(base + "/" + tok for base in bases)
    return out


# Начало heredoc. Строки в кавычках съедаются первыми ветками: `echo "see <<eof"` — текст,
# а не heredoc, и без этого весь хвост команды считался бы его телом. `<<<` — here-string,
# тела у него нет вовсе: `(?<!<)` и `(?!<)` не дают принять его за `<<`.
_HEREDOC_SCAN = re.compile(r"""'[^']*'|"[^"]*"|(?<!<)<<(?!<)-?[ \t]*(['"]?)([a-z_][\w-]*)\1""")
# Токен команды: строка в кавычках целиком либо слово без пробелов и кавычек.
_SH_TOKEN = re.compile(r"""'[^']*'|"[^"]*"|[^\s'"]+""")
_SH_SPLIT = re.compile(r"&&|\|\||[;|\n]")
_COPY_VERBS = ("cp", "mv", "copy", "move", "copy-item", "move-item", "install")
_PS_WRITE_VERBS = ("set-content", "add-content", "out-file", "new-item", "sc", "ac", "ni")
_PS_PATH_OPTS = ("-path", "-literalpath", "-filepath", "-destination")
# Глаголы, у которых каждый позиционный аргумент — затрагиваемый файл: создание и удаление.
_TOUCH_VERBS = ("touch", "rm", "unlink", "truncate", "shred", "del", "erase", "ri",
                "remove-item")
# Интерпретатор, чей код пришёл строкой (`-c`) или телом heredoc: запись в таком коде
# выражена вызовом, а не формой шелла. Имя — отдельным словом или хвостом пути
# (`/usr/bin/python3`), но не расширением: `cat > run.py <<EOF` интерпретатор не кормит.
_INTERP = (r"(?<![\w.-])(?:python[\d.]*|py|bash|sh|zsh|pwsh|powershell|node|perl|ruby)"
           r"(?:\.exe)?(?![\w.-])")
_INTERP_RE = re.compile(_INTERP)
_INLINE_CODE = re.compile(_INTERP + r"""[^'"\n;&|]*?\s-(?:\w*c|command|e)\s+(?:"([^"]*)"|'([^']*)')""")
# Имя файла в вызове записи внутри кода: open(…, 'w'), Path(…).write_text, .NET WriteAll*,
# fs.writeFileSync. Первые — только в коде интерпретатора; .NET-вызовы (_NET_WRITE) стоят и
# прямо в команде PowerShell. Голое `'a'` в любом месте строки признаком не считается:
# слишком часто это просто строка.
_NET_WRITE = (
    re.compile(r"""::(?:writeall\w*|appendall\w*|create|delete|createtext|appendtext)\(\s*['"]?([^'",)\s]+)"""),
    re.compile(r"""::(?:copy|move|replace)\(\s*['"]?[^'",)]+['"]?\s*,\s*['"]?([^'",)\s]+)"""),
)
_CODE_WRITE = _NET_WRITE + (
    re.compile(r"""open\(\s*['"]([^'"]+)['"]\s*,\s*(?:mode\s*=\s*)?['"][rwax]*[wax+]"""),
    re.compile(r"""\(\s*['"]([^'"]+)['"]\s*\)\s*\.(?:write_text|write_bytes|touch|unlink)\("""),
    re.compile(r"""os\.(?:remove|unlink)\(\s*['"]([^'"]+)['"]"""),
    re.compile(r"""(?:writefile|appendfile)(?:sync)?\(\s*['"]([^'"]+)['"]"""),
)


def _heredoc_open(line, scan=_HEREDOC_SCAN):
    """Разделитель heredoc в строке либо None. Кавычки и here-string heredoc'ом не бывают."""
    for m in scan.finditer(line):
        if m.group(2):
            return m.group(2)
    return None


def _split_heredocs(command, scan=_HEREDOC_SCAN):
    """Команда без тел heredoc и список пар (строка-открытие, тело).

    Текст создаваемого файла командой не является: в нём упоминания, а не цели записи.
    Тело нужно отдельно, потому что heredoc, который кормит интерпретатор, — это код.
    """
    lines, out, bodies, i = command.split("\n"), [], [], 0
    while i < len(lines):
        opener = lines[i]
        out.append(opener)
        delim = _heredoc_open(opener, scan)
        i += 1
        if delim:
            body = []
            while i < len(lines) and lines[i].strip() != delim:
                body.append(lines[i])
                i += 1
            i += 1
            bodies.append((opener, "\n".join(body)))
    return "\n".join(out), bodies


def _code_targets(code, depth):
    """Цели записи в коде интерпретатора: шелл-формы плюс вызовы записи python/.NET/node."""
    targets = write_targets(code, depth + 1)
    for pat in _CODE_WRITE:
        targets.extend(pat.findall(code))
    return targets


def write_targets(command, depth=0):
    """Слова в позиции цели записи: за `>`/`>>`, аргументы `tee`, `touch` и `rm`, файлы
    `sed -i`, назначение `cp`/`mv`, имена файлов у Set-Content и соседей, пути после `--`
    у git checkout, путь .NET-записи. Плюс цели в коде, который команда отдаёт
    интерпретатору строкой `-c` или телом heredoc.

    Строка в кавычках с пробелом внутри — это текст, а не имя файла, и в цели не идёт.
    Разбор грубый и нужен только голым именам: пути со слэшем по-прежнему ловит
    _PATH_TOKEN по всей команде.
    """
    targets = []
    if depth > 3:
        return targets
    stripped, bodies = _split_heredocs(command)
    for opener, body in bodies:
        # Тело `cat > notes.md <<EOF` — данные, тело `python - <<EOF` — код.
        if _INTERP_RE.search(opener):
            targets.extend(_code_targets(body, depth))
    for m in _INLINE_CODE.finditer(stripped):
        code = m.group(1) if m.group(1) is not None else m.group(2)
        targets.extend(_code_targets(code, depth))
    for pat in _NET_WRITE:
        targets.extend(pat.findall(stripped))
    for seg in _SH_SPLIT.split(stripped):
        toks = []
        for t in _SH_TOKEN.findall(seg):
            if t[:1] in "'\"":
                if re.search(r"\s", t):
                    toks.append("\0")  # текст — место занимает, целью не бывает
                    continue
                t = t[1:-1]
            toks.append(t)
        # Перенаправление: `> f`, `>> f`, `>f`, `2> f` не пишет в интересный файл, но вреда нет.
        for i, t in enumerate(toks):
            if t in (">", ">>") and i + 1 < len(toks):
                targets.append(toks[i + 1])
            elif t.startswith(">") and len(t) > 1:
                targets.append(t.lstrip(">"))
        if not toks:
            continue
        # Текст в кавычках остаётся среди позиционных меткой "\0": `sed -i 's/a b/c/' X.cs`
        # иначе принял бы X.cs за скрипт, а не за файл.
        verb, args = toks[0], toks[1:]
        plain = [a for a in args if not a.startswith("-") and not a.startswith(">")]
        if verb == "tee" or verb in _TOUCH_VERBS:
            targets.extend(plain)
        elif verb == "sed" and any(a == "-i" or a.startswith("-i") or a == "--in-place" for a in args):
            # Первый позиционный — скрипт (если не было -e/-f), остальные — файлы.
            script_given = any(a in ("-e", "-f") for a in args)
            targets.extend(plain if script_given else plain[1:])
        elif verb in _COPY_VERBS and plain:
            targets.append(plain[-1])
        if verb in _PS_WRITE_VERBS or verb in ("copy-item", "move-item"):
            for i, a in enumerate(args):
                if a in _PS_PATH_OPTS and i + 1 < len(args):
                    targets.append(args[i + 1])
            if verb in _PS_WRITE_VERBS:
                # Позиционный путь стоит где угодно: `-Encoding UTF8 f.sql $x`, `-ItemType
                # File f.sql`. Первый позиционный — часто значение опции, поэтому берём все,
                # похожие на имя файла, кроме значения -Value: это содержимое, а не путь.
                skip = {i + 1 for i, a in enumerate(args) if a == "-value"}
                targets.extend(a for i, a in enumerate(args) if i not in skip
                               and not a.startswith("-") and _BARE_TOKEN.fullmatch(a))
        if verb == "git" and "checkout" in args and "--" in args:
            targets.extend(args[args.index("--") + 1:])
    return [t for t in targets if t and t != "\0"]


def is_new_file(candidate):
    """Файла ещё нет — команда или Write его создаёт.

    Кандидат из команды бывает относительным, поэтому пробуем и путь как есть, и от
    корня репозитория. Не нашли нигде — считаем новым: это и есть целевой случай,
    файл создаётся прямо этим вызовом.
    """
    return not any(os.path.exists(x) for x in (candidate, os.path.join(REPO, candidate)))


def own_edits_count():
    """Число разных файлов, правленных главным агентом, если обёртка передала его сейчас.

    Строка из цифр или пустая: значение попадает в текст напоминания, а переменная
    окружения — чужой ввод.
    """
    value = os.environ.get("RI_OWN_EDITS", "")
    return value if value.isdigit() else ""


def input_value(rule, tool_input):
    """Значение поля правила: первое непустое из объявленных имён, уже нормализованное.

    Поле может быть не строкой (у MultiEdit текст правки лежит в массиве `edits`) —
    тогда сравнивается его строковое представление.
    """
    names = rule.get("input_fields") or ([rule["input_field"]] if rule.get("input_field") else [])
    for name in names:
        value = norm(tool_input.get(name))
        if value:
            return value
    return ""


def rule_matches(rule, tool_name, tool_input):
    # Правило только для просьб человека или только для промпта субагента (нет ни
    # одного условия по вызову) не должно совпадать ни с чем: пустой набор условий иначе
    # читается как «подходит всему» и правило пришло бы на каждый вызов инструмента.
    if not any(rule.get(k) for k in TOOL_SIDE):
        return False
    if not tool_matches(rule, tool_name):
        return False
    # Счёт собственных правок главного агента ведёт обёртка rule-injector.sh, а не python:
    # иначе каждая правка у всех платила бы запуском интерпретатора. Обёртка передаёт число
    # файлов переменной окружения только на пересечении порога; без неё правило, у которого
    # из условий одни инструменты, совпало бы с каждым Write и Edit.
    if rule.get("own_edits_gate") and not own_edits_count():
        return False

    path = norm(tool_input.get("file_path") or tool_input.get("notebook_path"))
    command = norm(tool_input.get("command"))

    # Кандидаты на «правленый файл»: либо явный file_path инструмента, либо пути,
    # выловленные из команды. Условия пути проверяются на ОДНОМ кандидате целиком —
    # иначе каталог из одного пути и расширение из другого сложились бы в
    # несуществующее совпадение.
    candidates = [path] if path else []
    if not candidates and any(rule.get(k) for k in PATH_KEYS):
        # Разбор команды один на вызов хука, а не на каждое правило с путём: поиск токена
        # пути на длинной строке без пробелов стоит секунды.
        if command not in _PATHS_CACHE:
            _PATHS_CACHE.clear()
            _PATHS_CACHE[command] = command_paths(command)
        candidates = list(_PATHS_CACHE[command])
        # "shell_targets_only": из команды берутся только цели записи, а не любой путь рядом
        # с признаком записи. `rm -f /tmp/x; grep … docs/rules/new.md` иначе читалось бы как
        # создание нового правила.
        if rule.get("shell_targets_only") and command:
            targets = set(write_targets(command))
            candidates = [c for c in candidates
                          if any(c == t or c.endswith("/" + t) for t in targets)]

    if any(rule.get(k) for k in PATH_KEYS):
        kept = []
        for cand in candidates:
            # path_any и repo_root_any — одно условие «путь из списка»: хватает любого из них.
            if (rule.get("path_any") or rule.get("repo_root_any")) and not (
                    any(norm(p) in cand for p in rule.get("path_any") or [])
                    or at_repo_root(cand, rule.get("repo_root_any") or [])):
                continue
            if rule.get("path_all") and not all(norm(p) in cand for p in rule["path_all"]):
                continue
            if rule.get("path_ext") and not any(cand.endswith(norm(e)) for e in rule["path_ext"]):
                continue
            # Исключение внутри защищаемого каталога. Список дублируется в предфильтре
            # обёртки — разойдутся молча, поэтому оба держит тест.
            if rule.get("skip_path_any") and any(norm(p) in cand for p in rule["skip_path_any"]):
                continue
            kept.append(cand)
        if not kept:
            return False
        candidates = kept
    if rule.get("new_file_only"):
        if not any(is_new_file(c) for c in candidates):
            return False
    # Зеркало new_file_only: правке существующего файла нужно своё напоминание, а созданию
    # нового — своё.
    if rule.get("existing_file_only"):
        if all(is_new_file(c) for c in candidates):
            return False
    if rule.get("command_any"):
        if not command or not any(norm(c) in command for c in rule["command_any"]):
            return False
    if rule.get("command_regex"):
        raw = tool_input.get("command") or ""
        if not re.search(rule["command_regex"], raw):
            return False
    if rule.get("input_field") or rule.get("input_fields"):
        # Точечное совпадение по полю ввода вместо свипа по всем строкам: признак обязан
        # прийти из содержимого правки, а не из случайного текста рядом. Имя поля
        # перечисляется списком: у Write текст в `content`, у Edit — в `new_string`, у
        # MultiEdit — в `edits`, у команды — в `command`.
        value = input_value(rule, tool_input)
        if not value:
            return False
        if not any(norm(x) in value for x in rule.get("input_any", [])):
            return False
    return True


def fired_scope(payload):
    """Ключ учёта «уже напоминали»: сессия плюс агент. Пустая строка — учёт невозможен.

    Ту же формулу повторяет предфильтр rule-injector.sh (буквы, цифры и `_`, 40
    символов), чтобы найти флаг правила с bash_flag без запуска python. Меняешь здесь —
    меняй и там, иначе флаг не найдётся и первая правка кода станет каждой.
    """
    session_id = payload.get("session_id")
    if not session_id:
        return ""
    # re.A: \W только в ASCII — ровно как [^A-Za-z0-9_] в bash.
    scope = re.sub(r"\W", "", session_id, flags=re.A)[:40]
    agent_id = re.sub(r"\W", "", str(payload.get("agent_id") or ""), flags=re.A)[:40]
    if agent_id:
        scope += "-" + agent_id
    return scope


FLAG_DIR = os.path.join(HOOK_DIR, ".rule-flags")


def mark_bash_flags(payload, rules):
    """Флаг-файл для правил с "bash_flag": true — предфильтр видит его без python.

    Такое правило висит на частом вызове (правка кода), а напомнить должно один раз на
    сессию и агента. Учёт в JSON bash прочитать не может, и без флага каждая правка кода
    платила бы запуском python ради напоминания, которое уже было.
    """
    scope = fired_scope(payload)
    if not scope:
        return
    flagged = [r for r in rules if r.get("bash_flag")]
    if not flagged:
        return
    try:
        os.makedirs(FLAG_DIR, exist_ok=True)
        # Флаги лежат рядом с хуком, а не во временном каталоге ОС (bash должен найти
        # их без python), поэтому чистить их некому, кроме нас. Ставится флаг раз на
        # сессию и агента — тогда же и убираем флаги старше двух суток.
        stale = time.time() - 2 * 86400
        for name in os.listdir(FLAG_DIR):
            full = os.path.join(FLAG_DIR, name)
            if os.path.getmtime(full) < stale:
                os.remove(full)
    except Exception:
        pass
    for rule in flagged:
        try:
            open(os.path.join(FLAG_DIR, "%s-%s" % (scope, rule["name"])), "a").close()
        except Exception:
            pass


def already_fired(payload, names):
    """Дедупликация в пределах сессии и агента. Отказ файловой системы не должен ломать хук.

    Учёт ведётся отдельно для каждого агента. Вызовы субагента приходят в хук с тем же
    session_id, что и у главной сессии, и отличаются только полем agent_id. Общий учёт
    отдавал бы напоминание тому, кто сработал первым: правило, уже показанное
    оркестратору, субагенту не приходило бы вовсе, хотя контекст у субагента свой.
    """
    scope = fired_scope(payload)
    if not scope:
        return set()
    import tempfile
    marker = os.path.join(tempfile.gettempdir(), "claude-rule-injector-%s.json" % scope)
    seen = set()
    try:
        with open(marker, "r", encoding="utf-8") as fh:
            seen = set(json.load(fh))
    except Exception:
        seen = set()
    fresh = [n for n in names if n not in seen]
    if fresh:
        try:
            with open(marker, "w", encoding="utf-8") as fh:
                json.dump(sorted(seen | set(names)), fh)
        except Exception:
            pass
    return seen


SUBAGENT_MARK = "[Правила проекта для этой задачи — вписаны хуком rule-injector]"


def subagent_prompt(rules, tool_input):
    """Промпт субагента с дописанным блоком правил, либо None, если дописывать нечего.

    Напоминание на вызове Agent уходит в контекст оркестратора, а у субагента контекст
    свой. Единственное, что субагент гарантированно читает, — свой промпт, поэтому
    правило вписывается туда.

    Блок ставится при каждом спавне и в учёте «уже напоминали» не участвует: каждый
    субагент начинает с чистого контекста, и второй спавн того же типа без блока
    остался бы без правила. Метка в тексте не даёт вписать блок дважды, если вызов
    повторяют с уже дополненным промптом.
    """
    prompt = tool_input.get("prompt")
    if not isinstance(prompt, str) or SUBAGENT_MARK in prompt:
        return None
    # Без явного типа Claude Code запускает general-purpose.
    kind = tool_input.get("subagent_type") or "general-purpose"
    # Правило выбирается по типу агента, а не по задаче: тот же тип приходит и править,
    # и только читать. Поэтому вписывается отдельный текст subagent_note, написанный
    # условно («если правишь…»), — агент на чужой задаче сам видит, что правило не про
    # него. Правило без такого текста не вписывается: безусловная формулировка для
    # оркестратора в промпте субагента звучит приказом.
    picked = [r for r in rules if r.get("subagent_note")
              and (kind in (r.get("for_subagents") or []) or "*" in (r.get("for_subagents") or []))]
    if not picked:
        return None
    lines = [SUBAGENT_MARK]
    for rule in picked:
        lines.append("- ПРАВИЛО %s. %s Прочитай %s целиком, прежде чем действовать по "
                     "нему: строка — указатель, а не полная норма."
                     % (rule["name"], rule["subagent_note"], rule_path(rule)))
    return prompt.rstrip() + "\n\n" + "\n".join(lines)


def emit(event, lines, updated_input=None):
    """Отдаёт подсказку и, для спавна субагента, подменённый вход вызова.

    Хук правил ничего не запрещает: напоминание — не граница, и решения
    `permissionDecision` он не ставит никогда.
    """
    out = {"hookSpecificOutput": {"hookEventName": event}}
    if lines:
        out["hookSpecificOutput"]["additionalContext"] = "\n\n".join(lines)
    if updated_input is not None:
        # Вход вызова заменяется ЦЕЛИКОМ, а не сливается с исходным: отдаём все поля,
        # иначе тип агента или описание пропали бы. permissionDecision при этом не
        # ставим: подмена входа с «allow» обходит запрос разрешения, а хуку правил
        # решать за человека, пускать ли агента, не положено.
        out["hookSpecificOutput"]["updatedInput"] = updated_input
    # Пишем байтами: на Windows кодировка консоли бывает cp1251, и обычный
    # sys.stdout.write кириллицы не переживёт — хук молча упадёт вместе с подсказкой.
    sys.stdout.buffer.write(json.dumps(out, ensure_ascii=False).encode("utf-8"))
    sys.stdout.buffer.flush()


_NOTICE_OPEN = "<task-notification>"
_NOTICE_CLOSE = "</task-notification>"
# Преамбула, которой харнесс местами предваряет уведомление («это не реплика человека»).
_NOTICE_PREAMBLE = "[system notification - not user input]"


def strip_notifications(raw):
    """Текст реплики без ведущих блоков <task-notification>…</task-notification>.

    Возвращает исходную строку, если уведомления в начале нет, и None, если блок в
    начале не закрыт: его хвост — всё ещё уведомление, а не реплика. Блоков подряд
    бывает несколько — харнесс склеивает уведомления, пришедшие за один ход.
    Узнаём только эту обёртку, а не любой ведущий тег: слэш-команда приходит как
    `<command-message>…`, и это просьба человека.
    """
    rest = raw
    head = rest.lstrip()
    if head.lower().startswith(_NOTICE_PREAMBLE):
        # Преамбула относится к уведомлению под ней; без уведомления это всё равно
        # служебный текст, а не просьба.
        start = head.find(_NOTICE_OPEN)
        if start < 0:
            return None
        rest = head[start:]
    while rest.lstrip().startswith(_NOTICE_OPEN):
        body = rest.lstrip()
        end = body.find(_NOTICE_CLOSE)
        if end < 0:
            return None
        rest = body[end + len(_NOTICE_CLOSE):]
    return rest


def handle_prompt(payload, rules):
    """Просьба человека → правило, которое ею затронуто.

    Хук на вызове инструмента приходит поздно: он ловит уже выбранное действие, а
    правило иногда нужно знать до первого хода — иначе агент придумает порядок сам.

    Дедупликации здесь нет намеренно: человек, повторивший просьбу, хочет её
    выполнения сейчас, а не отсылки к тому, что ему уже говорили.
    """
    text = norm(payload.get("prompt"))
    if not text:
        return
    raw = payload.get("prompt") or ""
    # Отчёт субагента приходит в главную сессию тем же событием, что и реплика человека,
    # а в нём пересказаны и задача, и правила: один отчёт поднимал бы пачку правил разом,
    # и ни одно не было бы просьбой. Узнаём его по рамке, которой харнесс оборачивает
    # отчёт, и только в начале текста: цитата рамки в реплике человека не должна глушить хук.
    if "<agent-message from=" in raw[:300]:
        return
    # Уведомление фоновой задачи (Monitor, фоновый Bash, фоновый субагент) харнесс тоже
    # отдаёт этим событием. Признака источника во входе хука нет, поэтому узнаём по
    # тексту. Снимаем ведущие блоки уведомления целиком и разбираем остаток: человек,
    # который вставил уведомление и дописал под ним свою просьбу, остаётся услышан.
    rest = strip_notifications(raw)
    if rest is None:
        return
    if rest is not raw:
        raw, text = rest, norm(rest)
        if not text.strip():
            return
    lines = []
    for rule in rules:
        stems = rule.get("prompt_any") or []
        by_stem = any(norm(s) in text for s in stems)
        # Регулярка нужна там, где просьба опознаётся не словом, а формой: номер задачи
        # в «/command #131» кириллицы не несёт, и ни одна основа слова не совпадёт.
        by_re = bool(rule.get("prompt_regex")) and bool(re.search(rule["prompt_regex"], raw))
        if by_stem or by_re:
            lines.append(
                "ПО ЭТОЙ ПРОСЬБЕ ДЕЙСТВУЕТ ПРАВИЛО %s. %s Прочитай %s целиком, прежде "
                "чем действовать: строка выше — указатель, а не полная норма."
                % (rule["name"], rule.get("prompt_note") or rule.get("note", ""),
                   rule_path(rule)))
    if lines:
        emit("UserPromptSubmit", lines)


def main():
    """Хук правил ничего не роняет: любая его ошибка — тишина и код 0.

    Обёртка запускает python через exec, и код выхода python становится кодом хука. Код 1
    — это «hook error» в транскрипте на каждом Write, Edit и Bash, код 2 у PreToolUse
    блокирует сам вызов. Поэтому битая запись таблицы (строка вместо объекта, правило без
    имени) или ошибка в разборе не должны доходить до кода выхода. Лога у хука нет:
    ошибку ловят тесты, а не пользователь посреди работы. Синтаксическую ошибку самого
    файла этот try не видит — её гасит загрузчик в rule-injector.sh.
    """
    try:
        _main()
    except BaseException:
        pass


def _main():
    try:
        # Читаем байтами и декодируем UTF-8 явно. json.load(sys.stdin) берёт кодировку
        # консоли, а на Windows это cp1251: русский текст просьбы превратился бы в
        # мусор ещё до сравнения, и хук молчал бы, не падая.
        payload = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
    except Exception:
        return
    try:
        with open(MAP_PATH, "r", encoding="utf-8") as fh:
            rules = json.load(fh).get("rules", [])
    except Exception:
        return
    # Запись без имени или не объект — битая строка таблицы. Отбрасываем её одну, а не
    # роняем хук: иначе одна опечатка в таблице глушила бы все остальные правила.
    rules = [r for r in rules if isinstance(r, dict) and isinstance(r.get("name"), str)
             and r["name"] and isinstance(r.get("note", ""), str)]

    if payload.get("hook_event_name") == "UserPromptSubmit":
        handle_prompt(payload, rules)
        return

    tool_name = payload.get("tool_name") or ""
    tool_input = payload.get("tool_input") or {}
    if not isinstance(tool_input, dict):
        return

    # Вход субагента с вписанными правилами считается до выхода по «нет совпадений»:
    # у спавна может не быть ни одного напоминания для оркестратора, а блок для
    # субагента при этом нужен.
    updated = None
    if tool_name == "Agent":
        prompt = subagent_prompt(rules, tool_input)
        if prompt is not None:
            updated = dict(tool_input, prompt=prompt)

    hits = [r for r in rules if rule_matches(r, tool_name, tool_input)]
    mark_bash_flags(payload, hits)

    # Правила с "repeat": true напоминают о себе каждый раз и в учёте не участвуют.
    repeating = [r for r in hits if r.get("repeat")]
    dedupable = [r for r in hits if not r.get("repeat")]
    seen = already_fired(payload, [r["name"] for r in dedupable]) if dedupable else set()
    hits = repeating + [r for r in dedupable if r["name"] not in seen]
    if not hits:
        if updated is not None:
            emit("PreToolUse", [], updated_input=updated)
        return

    lines = []
    for rule in hits:
        note = rule.get("note", "")
        if rule.get("own_edits_gate"):
            note = note.replace("{N}", own_edits_count())
        lines.append(
            "ПРАВИЛО %s — %s Полный текст и оговорки: %s — прочитай его, "
            "прежде чем ссылаться на правило в обосновании."
            % (rule["name"], note, rule_path(rule))
        )
    emit("PreToolUse", lines, updated_input=updated)


if __name__ == "__main__":
    main()
    sys.exit(0)
