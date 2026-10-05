# -*- coding: utf-8 -*-
"""Тесты движка впрыска правил: ключи таблицы, разбор команды, учёт срабатываний,
промпт субагента, реплика человека и устойчивость обёртки.

Таблица проекта здесь не используется: каждый тест строит свою синтетическую. Тесты
таблицы проекта — test_rules_map.py.

Запуск: python3 -m unittest discover -s .claude/hooks/tests -v

Хук хранит состояние рядом с собой (.rule-flags/, .python-path) и во временном каталоге
ОС (учёт «уже напоминали»). Поэтому каждый тест работает на копии каталога хука во
временном каталоге с раскладкой <tmp>/.claude/hooks/ — движок вычисляет корень
репозитория как два уровня вверх от себя — и с TMPDIR/TEMP/TMP на свой каталог.
Настоящий .claude/hooks/rule-injector.sh тесты не запускают: он оставил бы состояние в
рабочем дереве.
"""
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

HOOK_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_ROOT = os.path.dirname(os.path.dirname(HOOK_DIR))
WRAPPER = os.path.join(HOOK_DIR, "rule-injector.sh")
ENGINE = os.path.join(HOOK_DIR, "rule-injector.py")
MAP = os.path.join(HOOK_DIR, "rules-map.json")


def find_bash():
    """Тот bash, который умеет запускать скрипт обёртки.

    На Windows голое имя bash из Python резолвится в WSL, а он про пути вида C:/... ничего
    не знает. Claude Code запускает хуки в Git Bash, поэтому проверять надо им же.
    """
    cands = [os.environ.get("BASH")]
    if os.name == "nt":
        cands += [r"C:\Program Files\Git\bin\bash.exe",
                  r"C:\Program Files (x86)\Git\bin\bash.exe",
                  os.path.expandvars(r"%LOCALAPPDATA%\Programs\Git\bin\bash.exe")]
    else:
        cands += ["/bin/bash", "/usr/bin/bash", shutil.which("bash")]
    for c in cands:
        if c and os.path.exists(c):
            return c
    return None


BASH = find_bash()


def load_engine():
    spec = importlib.util.spec_from_file_location("rule_injector", ENGINE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ri = load_engine()


def sid():
    return str(uuid.uuid4())


def scope_of(session):
    return re.sub(r"\W", "", session, flags=re.A)[:40]


def fired_names(out):
    """Имена правил из ответа хука (напоминания оркестратору)."""
    ctx = ((out or {}).get("hookSpecificOutput") or {}).get("additionalContext") or ""
    return re.findall(r"ПРАВИЛО ([\w-]+)", ctx)


class HookCopy:
    """Копия каталога хука во временном корне: <root>/.claude/hooks/.

    table — своя таблица (список правил) либо None для таблицы проекта. engine_src —
    подменённый текст движка (заглушка), если нужен.
    """

    def __init__(self, table=None, engine_src=None, cache_python=True):
        self.root = tempfile.mkdtemp(prefix="ri-test-")
        self.dir = os.path.join(self.root, ".claude", "hooks")
        os.makedirs(self.dir)
        self.tmp = os.path.join(self.root, "_tmp")
        os.makedirs(self.tmp)
        shutil.copy(WRAPPER, os.path.join(self.dir, "rule-injector.sh"))
        if engine_src is None:
            shutil.copy(ENGINE, os.path.join(self.dir, "rule-injector.py"))
        else:
            self.put("rule-injector.py", engine_src)
        if table is None:
            shutil.copy(MAP, os.path.join(self.dir, "rules-map.json"))
        else:
            self.put("rules-map.json", json.dumps({"rules": table}, ensure_ascii=False))
        if cache_python:
            self.put(".python-path", sys.executable)

    def put(self, name, text, mode="w"):
        with io.open(os.path.join(self.dir, name), mode, encoding="utf-8", newline="\n") as fh:
            fh.write(text)

    def env(self, extra=None):
        e = dict(os.environ, TMPDIR=self.tmp, TEMP=self.tmp, TMP=self.tmp)
        e.pop("RI_OWN_EDITS", None)
        e.update(extra or {})
        return e

    def run(self, payload, via="sh", env=None):
        """(код выхода, ответ JSON или None, сырой stdout)."""
        if via == "sh":
            cmd = [BASH, os.path.join(self.dir, "rule-injector.sh")]
        else:
            cmd = [sys.executable, os.path.join(self.dir, "rule-injector.py")]
        data = payload if isinstance(payload, bytes) else \
            json.dumps(payload, ensure_ascii=False).encode("utf-8")
        p = subprocess.run(cmd, input=data, capture_output=True, env=self.env(env),
                           cwd=self.root, timeout=60)
        raw = p.stdout.decode("utf-8", "replace").strip()
        try:
            parsed = json.loads(raw) if raw else None
        except ValueError:
            parsed = None
        return p.returncode, parsed, raw

    def flags(self):
        d = os.path.join(self.dir, ".rule-flags")
        return sorted(os.listdir(d)) if os.path.isdir(d) else []

    def close(self):
        shutil.rmtree(self.root, ignore_errors=True)


def needs_bash(test):
    return unittest.skipIf(BASH is None, "bash не найден: задай BASH=<путь к Git Bash>")(test)


class HookCase(unittest.TestCase):
    def copy(self, table=None, **kw):
        h = HookCopy(table, **kw)
        self.addCleanup(h.close)
        return h


# --- ключи движка: условия совпадения ---------------------------------------------

class RuleMatchKeys(unittest.TestCase):
    def setUp(self):
        self._env = os.environ.pop("RI_OWN_EDITS", None)

    def tearDown(self):
        if self._env is not None:
            os.environ["RI_OWN_EDITS"] = self._env

    def m(self, rule, tool, tool_input):
        rule = dict({"name": "r", "note": "n"}, **rule)
        return ri.rule_matches(rule, tool, tool_input)

    def test_rule_without_tool_side_never_matches_a_call(self):
        rule = {"prompt_any": ["x"]}
        self.assertFalse(self.m(rule, "Bash", {"command": "ls"}))
        self.assertFalse(self.m(rule, "Write", {"file_path": "a.cs", "content": "x"}))
        rule = {"for_subagents": ["step-x"], "subagent_note": "s"}
        self.assertFalse(self.m(rule, "Agent", {"prompt": "p", "subagent_type": "step-x"}))

    def test_tools_exact_and_prefix(self):
        self.assertTrue(self.m({"tools": ["Edit"], "path_any": ["a/"]}, "Edit", {"file_path": "a/x"}))
        self.assertFalse(self.m({"tools": ["Edit"], "path_any": ["a/"]}, "Write", {"file_path": "a/x"}))
        self.assertTrue(self.m({"tools": ["mcp__x__"], "command_any": ["q"]}, "mcp__x__y",
                               {"command": "q"}))

    def test_path_rule_also_catches_shell_write_unless_no_shell(self):
        rule = {"tools": ["Edit"], "path_any": ["src/data/"]}
        cmd = {"command": "sed -i 's/a/b/' src/data/x.cs"}
        self.assertTrue(self.m(rule, "Bash", cmd))
        self.assertTrue(self.m(rule, "PowerShell", cmd))
        self.assertFalse(self.m(dict(rule, no_shell=True), "Bash", cmd))

    def test_shell_read_is_not_a_write(self):
        rule = {"tools": ["Edit"], "path_any": ["src/data/"]}
        self.assertFalse(self.m(rule, "Bash", {"command": "cat src/data/x.cs"}))
        self.assertFalse(self.m(rule, "Bash", {"command": "grep -n confirm src/data/x.cs"}))

    def test_path_any_all_ext_on_one_candidate(self):
        rule = {"tools": ["Write"], "path_all": ["src/", "/migrations/"], "path_ext": [".cs"]}
        self.assertTrue(self.m(rule, "Write", {"file_path": "D:\\r\\src\\Data\\Migrations\\A.cs"}))
        self.assertFalse(self.m(rule, "Write", {"file_path": "src/Data/Migrations/A.json"}))
        self.assertFalse(self.m(rule, "Write", {"file_path": "src/Data/A.cs"}))
        # Условия не складываются из двух разных путей команды.
        self.assertFalse(self.m(rule, "Bash",
                                {"command": "touch src/a.txt /migrations/b.cs"}))

    def test_skip_path_any(self):
        rule = {"tools": ["Edit"], "path_any": ["docs/"], "skip_path_any": ["docs/tasks/"]}
        self.assertTrue(self.m(rule, "Edit", {"file_path": "docs/rules/a.md"}))
        self.assertFalse(self.m(rule, "Edit", {"file_path": "docs/tasks/131.md"}))

    def test_repo_root_any_compares_with_repo_root(self):
        rule = {"tools": ["Edit"], "repo_root_any": [".claude/settings.json"]}
        self.assertTrue(self.m(rule, "Edit", {"file_path": ".claude/settings.json"}))
        self.assertTrue(self.m(rule, "Edit", {"file_path": os.path.join(ri.REPO, ".claude", "settings.json")}))
        self.assertFalse(self.m(rule, "Edit", {"file_path": "/elsewhere/.claude/settings.json"}))

    def test_new_and_existing_file_only(self):
        existing = os.path.relpath(ENGINE, ri.REPO)
        new = {"tools": ["Write"], "path_any": [".claude/hooks/"], "new_file_only": True}
        old = dict(new, new_file_only=False, existing_file_only=True)
        self.assertFalse(self.m(new, "Write", {"file_path": existing}))
        self.assertTrue(self.m(new, "Write", {"file_path": ".claude/hooks/no-such-file.py"}))
        self.assertTrue(self.m(old, "Write", {"file_path": existing}))
        self.assertFalse(self.m(old, "Write", {"file_path": ".claude/hooks/no-such-file.py"}))

    def test_command_any_and_regex(self):
        self.assertTrue(self.m({"tools": ["Bash"], "command_any": ["issue create"]}, "Bash",
                               {"command": "gh ISSUE Create --title x"}))
        rule = {"tools": ["Bash"], "command_regex": r"(?:^|;)\s*git\s+push\b"}
        self.assertTrue(self.m(rule, "Bash", {"command": "git push"}))
        self.assertFalse(self.m(rule, "Bash", {"command": "echo 'git push'"}))

    def test_shell_targets_only(self):
        rule = {"tools": ["Write"], "path_any": ["docs/rules/"], "path_ext": [".md"],
                "shell_targets_only": True}
        self.assertTrue(self.m(rule, "Bash", {"command": "cat > docs/rules/new.md <<'E'\nx\nE"}))
        self.assertFalse(self.m(rule, "Bash", {"command": "rm -f /tmp/x; grep a docs/rules/new.md"}))

    def test_input_fields_any(self):
        rule = {"tools": ["Write", "Edit", "MultiEdit"], "path_ext": [".cs"],
                "input_fields": ["content", "new_string", "edits", "command"],
                "input_any": [": iagenttool"]}
        self.assertTrue(self.m(rule, "Write", {"file_path": "A.cs", "content": "class A : IAgentTool {}"}))
        self.assertTrue(self.m(rule, "Edit", {"file_path": "A.cs", "old_string": "x",
                                              "new_string": "class A : IAgentTool"}))
        self.assertTrue(self.m(rule, "MultiEdit", {"file_path": "A.cs", "edits": [
            {"old_string": "x", "new_string": "class A : IAgentTool"}]}))
        self.assertFalse(self.m(rule, "Write", {"file_path": "A.cs", "content": "class A {}"}))
        self.assertFalse(self.m(rule, "Write", {"file_path": "A.md", "content": "A : IAgentTool"}))

    def test_own_edits_gate_needs_count_from_wrapper(self):
        rule = {"tools": ["Edit"], "own_edits_gate": True}
        self.assertFalse(self.m(rule, "Edit", {"file_path": "a.txt"}))
        os.environ["RI_OWN_EDITS"] = "4"
        try:
            self.assertTrue(self.m(rule, "Edit", {"file_path": "a.txt"}))
            os.environ["RI_OWN_EDITS"] = "4; rm -rf"
            self.assertEqual(ri.own_edits_count(), "")
        finally:
            del os.environ["RI_OWN_EDITS"]


class CommandParsing(unittest.TestCase):
    def test_write_marker_words_are_whole_words(self):
        self.assertFalse(ri.has_write_marker("echo confirm test"))
        self.assertTrue(ri.has_write_marker("rm x"))
        self.assertTrue(ri.has_write_marker("set-content -path a.cs"))
        self.assertTrue(ri.has_write_marker("git checkout main -- a.cs"))

    def test_bare_name_after_cd(self):
        paths = ri.command_paths("cd src/domovoy.data/migrations && sed -i 's/a/b/' x.cs")
        self.assertIn("src/domovoy.data/migrations/x.cs", paths)

    def test_heredoc_body_of_data_is_not_a_target_but_code_is(self):
        self.assertNotIn("x.cs", ri.write_targets("cat > notes.md <<'e'\nsee x.cs\ne"))
        self.assertIn("out.cs", ri.write_targets("python - <<'e'\nopen('out.cs', 'w')\ne"))


# --- учёт срабатываний, флаги, промпт субагента — через процесс ------------------

PATH_RULE = {"name": "p-rule", "note": "n", "tools": ["Edit", "Write"], "path_any": ["src/data/"]}


class FiringAndState(HookCase):
    def test_once_per_session_and_agent(self):
        h = self.copy([PATH_RULE])
        s = sid()
        call = {"session_id": s, "tool_name": "Edit", "tool_input": {"file_path": "src/data/a.cs"}}
        self.assertEqual(fired_names(h.run(call, via="py")[1]), ["p-rule"])
        self.assertEqual(fired_names(h.run(call, via="py")[1]), [])
        self.assertEqual(fired_names(h.run(dict(call, agent_id="agent-1"), via="py")[1]), ["p-rule"])
        self.assertEqual(fired_names(h.run(dict(call, session_id=sid()), via="py")[1]), ["p-rule"])

    def test_repeat_fires_every_time(self):
        h = self.copy([dict(PATH_RULE, repeat=True)])
        call = {"session_id": sid(), "tool_name": "Edit", "tool_input": {"file_path": "src/data/a.cs"}}
        for _ in range(3):
            self.assertEqual(fired_names(h.run(call, via="py")[1]), ["p-rule"])

    def test_bash_flag_leaves_flag_file(self):
        h = self.copy([dict(PATH_RULE, bash_flag=True)])
        s = sid()
        h.run({"session_id": s, "tool_name": "Edit", "tool_input": {"file_path": "src/data/a.cs"}}, via="py")
        self.assertIn(scope_of(s) + "-p-rule", h.flags())

    def test_reminder_has_path_and_no_permission_decision(self):
        h = self.copy([dict(PATH_RULE, doc="docs/x.md")])
        rc, out, _ = h.run({"session_id": sid(), "tool_name": "Edit",
                            "tool_input": {"file_path": "src/data/a.cs"}}, via="py")
        hso = out["hookSpecificOutput"]
        self.assertEqual(rc, 0)
        self.assertIn("docs/x.md", hso["additionalContext"])
        self.assertNotIn("permissionDecision", hso)
        self.assertNotIn("decision", out)


SPAWN = {"prompt": "Сделай шаг.\n", "subagent_type": "step-x", "description": "d",
         "run_in_background": True}
SUB_RULE = {"name": "sub-rule", "note": "для оркестратора", "doc": "docs/rules/x.md",
            "for_subagents": ["step-x"], "subagent_note": "Если делаешь x — читай правило."}


class SubagentPrompt(HookCase):
    def test_spawn_gets_block_and_keeps_other_fields(self):
        h = self.copy([SUB_RULE])
        for via in (["py", "sh"] if BASH else ["py"]):
            rc, out, _ = h.run({"session_id": sid(), "tool_name": "Agent",
                                "tool_input": dict(SPAWN)}, via=via)
            hso = out["hookSpecificOutput"]
            upd = hso["updatedInput"]
            self.assertEqual(rc, 0)
            self.assertEqual(hso["hookEventName"], "PreToolUse")
            self.assertEqual({k: v for k, v in upd.items() if k != "prompt"},
                             {k: v for k, v in SPAWN.items() if k != "prompt"})
            self.assertTrue(upd["prompt"].startswith(SPAWN["prompt"].rstrip()))
            self.assertIn("ПРАВИЛО sub-rule.", upd["prompt"])
            self.assertIn(SUB_RULE["subagent_note"], upd["prompt"])
            self.assertNotIn(SUB_RULE["note"], upd["prompt"])
            self.assertIn("docs/rules/x.md", upd["prompt"])
            self.assertEqual(upd["prompt"].count("вписаны хуком rule-injector"), 1)
            self.assertNotIn("permissionDecision", hso)

    def test_second_spawn_gets_block_again_but_marked_prompt_does_not(self):
        h = self.copy([SUB_RULE])
        s = sid()
        first = h.run({"session_id": s, "tool_name": "Agent", "tool_input": dict(SPAWN)}, via="py")[1]
        second = h.run({"session_id": s, "tool_name": "Agent", "tool_input": dict(SPAWN)}, via="py")[1]
        self.assertIn("updatedInput", second["hookSpecificOutput"])
        marked = dict(SPAWN, prompt=first["hookSpecificOutput"]["updatedInput"]["prompt"])
        again = h.run({"session_id": sid(), "tool_name": "Agent", "tool_input": marked}, via="py")[1]
        self.assertNotIn("updatedInput", (again or {}).get("hookSpecificOutput", {}))

    def test_other_types_and_tools_untouched(self):
        h = self.copy([SUB_RULE])
        for inp in (dict(SPAWN, subagent_type="Explore"),
                    {k: v for k, v in SPAWN.items() if k != "subagent_type"},
                    dict(SPAWN, prompt=None)):
            out = h.run({"session_id": sid(), "tool_name": "Agent", "tool_input": inp}, via="py")[1]
            self.assertNotIn("updatedInput", (out or {}).get("hookSpecificOutput", {}))
        out = h.run({"session_id": sid(), "tool_name": "Write",
                     "tool_input": {"file_path": "a.txt", "subagent_type": "step-x", "prompt": "x"}},
                    via="py")[1]
        self.assertNotIn("updatedInput", (out or {}).get("hookSpecificOutput", {}))

    def test_star_and_halves(self):
        star = [{"name": "x", "note": "n", "for_subagents": ["*"], "subagent_note": "Если x — y."}]
        self.assertIsNotNone(ri.subagent_prompt(star, {"prompt": "p", "subagent_type": "Explore"}))
        self.assertIsNone(ri.subagent_prompt([{"name": "y", "note": "n", "subagent_note": "s"}],
                                             {"prompt": "p", "subagent_type": "step-x"}))
        self.assertIsNone(ri.subagent_prompt([{"name": "z", "note": "n", "for_subagents": ["step-x"]}],
                                             {"prompt": "p", "subagent_type": "step-x"}))


# --- реплика человека ---------------------------------------------------------------

PROMPT_RULE = {"name": "ask-rule", "note": "n", "doc": "docs/rules/x.md",
               "prompt_any": ["заведи задачу"], "prompt_regex": r"(?i)/issue\s+#\d+"}
NOTICE = ("<task-notification>\n<task-id>b1</task-id>\n<summary>Agent finished: заведи задачу"
          "</summary>\n</task-notification>")


class PromptSubmit(HookCase):
    def ask(self, h, text, via="py"):
        out = h.run({"session_id": sid(), "hook_event_name": "UserPromptSubmit", "prompt": text},
                    via=via)[1]
        ctx = ((out or {}).get("hookSpecificOutput") or {}).get("additionalContext") or ""
        return re.findall(r"ПРАВИЛО ([\w-]+)\.", ctx), ctx

    def test_stem_and_regex(self):
        h = self.copy([PROMPT_RULE])
        names, ctx = self.ask(h, "Заведи задачу про это")
        self.assertEqual(names, ["ask-rule"])
        self.assertIn("docs/rules/x.md", ctx)
        self.assertEqual(self.ask(h, "/issue #131")[0], ["ask-rule"])
        self.assertEqual(self.ask(h, "посмотри логи")[0], [])

    def test_repeat_request_fires_again(self):
        h = self.copy([PROMPT_RULE])
        self.assertEqual(self.ask(h, "заведи задачу")[0], ["ask-rule"])
        self.assertEqual(self.ask(h, "заведи задачу")[0], ["ask-rule"])

    @needs_bash
    def test_cyrillic_through_wrapper(self):
        h = self.copy([PROMPT_RULE])
        self.assertEqual(self.ask(h, "заведи задачу", via="sh")[0], ["ask-rule"])

    def test_agent_report_and_notifications_are_silent(self):
        h = self.copy([PROMPT_RULE])
        report = 'Session sent:\n<agent-message from="a1">\nзаведи задачу'
        for text in (report, NOTICE, NOTICE + "\n" + NOTICE,
                     "[SYSTEM NOTIFICATION - NOT USER INPUT]\nauto\n\n" + NOTICE,
                     NOTICE[:-len("</task-notification>")]):
            self.assertEqual(self.ask(h, text)[0], [], text[:40])

    def test_human_text_around_notification_is_heard(self):
        h = self.copy([PROMPT_RULE])
        self.assertEqual(self.ask(h, NOTICE + "\nзаведи задачу, пожалуйста")[0], ["ask-rule"])
        self.assertEqual(self.ask(h, "смотри, что пришло: " + NOTICE)[0], ["ask-rule"])


# --- обёртка: синтаксис, устойчивость, предфильтр -----------------------------------

@needs_bash
class WrapperRobustness(HookCase):
    def test_wrapper_parses(self):
        p = subprocess.run([BASH, "-n", WRAPPER], capture_output=True)
        self.assertEqual(p.returncode, 0, p.stderr.decode("utf-8", "replace"))

    def call(self):
        return {"session_id": sid(), "tool_name": "Edit",
                "tool_input": {"file_path": "src/Domovoy.Data/Migrations/A.cs"}}

    RULE = {"name": "mig", "note": "n", "tools": ["Edit"], "path_any": ["src/domovoy.data/migrations/"]}

    def test_baseline_fires(self):
        h = self.copy([self.RULE])
        rc, out, _ = h.run(self.call())
        self.assertEqual((rc, fired_names(out)), (0, ["mig"]))

    def test_missing_engine_exit_0_empty(self):
        h = self.copy([self.RULE])
        os.remove(os.path.join(h.dir, "rule-injector.py"))
        rc, _, raw = h.run(self.call())
        self.assertEqual((rc, raw), (0, ""))

    def test_broken_entries_dropped_rest_work(self):
        h = self.copy(["строка", {"tools": ["Edit"], "path_any": ["src/"], "note": "без имени"}, self.RULE])
        rc, out, _ = h.run(self.call())
        self.assertEqual((rc, fired_names(out)), (0, ["mig"]))

    def test_broken_map_exit_0(self):
        h = self.copy([self.RULE])
        h.put("rules-map.json", "{не json")
        rc, _, raw = h.run(self.call())
        self.assertEqual((rc, raw), (0, ""))

    def test_engine_syntax_error_exit_0_empty(self):
        h = self.copy([self.RULE])
        h.put("rule-injector.py", "\ndef (:\n", "a")
        rc, _, raw = h.run(self.call())
        self.assertEqual((rc, raw), (0, ""))

    def test_exception_in_main_exit_0_empty(self):
        with io.open(ENGINE, encoding="utf-8") as fh:
            src = fh.read()
        broken = src.replace('if __name__ == "__main__":',
                             '_main = None  # вызов упадёт TypeError\nif __name__ == "__main__":')
        h = self.copy([self.RULE], engine_src=broken)
        rc, _, raw = h.run(self.call())
        self.assertEqual((rc, raw), (0, ""))

    def test_non_python_in_cache_is_ignored(self):
        h = self.copy([self.RULE])
        h.put("fake-bin", "#!/bin/sh\nexit 2\n")
        h.put(".python-path", os.path.join(h.dir, "fake-bin").replace("\\", "/"))
        rc, out, _ = h.run(self.call())
        self.assertEqual((rc, fired_names(out)), (0, ["mig"]))

    def test_without_python_hook_passes_call(self):
        """Без python — код 0 и пустой вывод; та же копия с python срабатывает."""
        h = self.copy([self.RULE], cache_python=False)
        fake = os.path.join(h.root, "fakebin")
        os.makedirs(fake)
        for name in ("python3", "python", "py"):
            path = os.path.join(fake, name)
            with io.open(path, "w", encoding="utf-8", newline="\n") as fh:
                fh.write("#!/bin/sh\nexit 1\n")
            os.chmod(path, 0o755)
        bash_fake = fake.replace("\\", "/")
        if re.match(r"^[A-Za-z]:/", bash_fake):
            bash_fake = "/" + bash_fake[0].lower() + bash_fake[2:]
        script = 'PATH="%s:$PATH" exec bash "%s"' % (
            bash_fake, os.path.join(h.dir, "rule-injector.sh").replace("\\", "/"))
        p = subprocess.run([BASH, "-c", script], input=json.dumps(self.call()).encode("utf-8"),
                           capture_output=True, env=h.env(), timeout=60)
        self.assertEqual((p.returncode, p.stdout.strip()), (0, b""))
        self.assertFalse(os.path.exists(os.path.join(h.dir, ".python-path")))
        rc, out, _ = h.run(self.call())
        self.assertEqual((rc, fired_names(out)), (0, ["mig"]))


STUB = "import os, sys; sys.stdin.buffer.read(); print('PY-CALLED N=' + os.environ.get('RI_OWN_EDITS', ''))\n"


@needs_bash
class Prefilter(HookCase):
    """Копия обёртки с заглушкой вместо движка: видно, пустил ли предфильтр вызов дальше."""

    def reaches(self, h, tool, tool_input, session=None, extra=None):
        payload = dict({"session_id": session or sid(),
                        "transcript_path": "C:\\Users\\dev\\.claude\\projects\\D--x\\s.jsonl",
                        "cwd": "D:\\work\\repo", "hook_event_name": "PreToolUse",
                        "tool_name": tool, "tool_input": tool_input, "tool_use_id": "toolu_1"},
                       **(extra or {}))
        _, _, raw = h.run(payload, env={"RI_OWN_EDITS": "99"})
        return raw.split("N=")[1].strip() if "PY-CALLED" in raw else None

    def test_real_input_with_transcript_path_does_not_reach_python(self):
        h = self.copy([], engine_src=STUB)
        self.assertIsNone(self.reaches(h, "Write", {"file_path": "D:\\r\\notes.txt", "content": "x"}))
        self.assertIsNone(self.reaches(h, "Bash", {"command": "git status"}))
        self.assertIsNone(self.reaches(h, "Bash", {"command": "cat src/Domovoy.Data/Migrations/A.cs"}))

    def test_flag_file_stops_python_on_next_code_edit(self):
        h = self.copy([], engine_src=STUB)
        s = sid()
        edit = {"file_path": "D:\\r\\src\\A.cs", "old_string": "a", "new_string": "b"}
        self.assertEqual(self.reaches(h, "Edit", edit, s), "")
        os.makedirs(os.path.join(h.dir, ".rule-flags"), exist_ok=True)
        open(os.path.join(h.dir, ".rule-flags", scope_of(s) + "-ceremony-card"), "w").close()
        self.assertIsNone(self.reaches(h, "Edit", edit, s))

    def test_large_write_is_fast(self):
        h = self.copy([], engine_src=STUB)
        t0 = time.perf_counter()
        self.reaches(h, "Write", {"file_path": "D:\\r\\big.txt", "content": "x = 1\n" * 170000})
        self.assertLess(time.perf_counter() - t0, 5)
        slashy = "C:\\Users\\u\\AppData\\x.log строка\n" * 20000
        t0 = time.perf_counter()
        hit = self.reaches(h, "Write", {"content": slashy,
                                        "file_path": "D:\\r\\src\\Domovoy.Data\\Migrations\\A.cs"})
        self.assertLess(time.perf_counter() - t0, 5)
        self.assertIsNotNone(hit)

    def test_inherited_count_does_not_pass(self):
        h = self.copy([], engine_src=STUB)
        hit = self.reaches(h, "Edit", {"file_path": "src/Domovoy.Data/Migrations/A.cs",
                                       "old_string": "a", "new_string": "b"})
        self.assertEqual(hit, "")


if __name__ == "__main__":
    unittest.main()
