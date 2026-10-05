# -*- coding: utf-8 -*-
"""Тесты таблицы впрыска правил проекта (.claude/hooks/rules-map.json).

Каждая строка таблицы проверяется через rule-injector.sh — так, как её зовёт Claude
Code, — а не только через движок: предфильтр обёртки отсекает вызовы до python, и
правило, которое движок поймал бы, молча не срабатывает, если предфильтру не дописали
его путь или форму команды.

Запуск: python3 -m unittest discover -s .claude/hooks/tests -v
"""
import glob
import io
import json
import os
import re
import unittest

from test_rule_injector import (BASH, HOOK_DIR, REPO_ROOT, HookCase, fired_names, needs_bash,
                                ri, scope_of, sid)

with io.open(os.path.join(HOOK_DIR, "rules-map.json"), encoding="utf-8") as _fh:
    TABLE = json.load(_fh)["rules"]
BY_NAME = {r["name"]: r for r in TABLE}

MAX_RULES, MAX_CHARS = 3, 1500


def dead_docs(table, root=REPO_ROOT):
    """Записи, чей `doc` не существует. Движок в этом случае молча подставляет первый
    кандидат — напоминание уводит по несуществующему пути и выглядит выполнимым."""
    return [r["name"] for r in table
            if not os.path.exists(os.path.join(root, r.get("doc") or "docs/rules/%s.md" % r["name"]))]


def step_agents():
    names = [os.path.splitext(os.path.basename(p))[0]
             for p in glob.glob(os.path.join(REPO_ROOT, ".claude", "agents", "step-*.md"))]
    return sorted(set(names))


def edit(path, new="b", tool="Edit"):
    if tool == "Write":
        return {"tool_name": "Write", "tool_input": {"file_path": path, "content": new}}
    if tool == "MultiEdit":
        return {"tool_name": "MultiEdit", "tool_input": {"file_path": path, "edits": [
            {"old_string": "a", "new_string": new}]}}
    return {"tool_name": tool, "tool_input": {"file_path": path, "old_string": "a", "new_string": new}}


def bash(cmd, tool="Bash"):
    return {"tool_name": tool, "tool_input": {"command": cmd}}


# На каждую строку таблицы — вызовы, на которых она обязана сработать, и соседние,
# на которых обязана молчать. Множество имён сверяется с таблицей: новая строка без
# пробы роняет тест.
PROBES = {
    "agent-tool": (
        [edit("src/Domovoy.Core/Tools/LightTool.cs", "public sealed class LightTool : IAgentTool {}", "Write"),
         edit("src\\Domovoy.Core\\Tools\\LightTool.cs", "class LightTool : Base, IAgentTool", "MultiEdit"),
         bash("cat > src/Domovoy.Core/Tools/X.cs <<'E'\nclass X : IAgentTool {}\nE")],
        [edit("src/Domovoy.Core/Orchestrator.cs", "IEnumerable<IAgentTool> tools"),
         edit("docs/notes.md", "class X : IAgentTool", "Write")]),
    "config-param": (
        [edit("src/Domovoy.Api/appsettings.json"), edit("src\\Domovoy.Ha\\HaOptions.cs", tool="MultiEdit"),
         bash("sed -i 's/a/b/' src/Domovoy.Api/appsettings.Development.json")],
        [edit("src/Domovoy.Api/Program.cs"), bash("cat src/Domovoy.Api/appsettings.json")]),
    "anonymous-endpoint": (
        [edit("src/Domovoy.Api/Endpoints/Pair.cs", "app.MapPost(\"/x\", H).AllowAnonymous();"),
         edit("src/Domovoy.Api/Endpoints/Pair.cs", "[AllowAnonymous]", "MultiEdit"),
         bash("cat >> src/Domovoy.Api/Endpoints/X.cs <<'E'\n.AllowAnonymous()\nE", "PowerShell")],
        [edit("src/Domovoy.Api/Endpoints/Pair.cs", ".RequireAuthorization()"),
         bash("grep -rn AllowAnonymous src/")]),
    "migration": (
        [edit("src/Domovoy.Data/Migrations/20260101000000_Init.cs", tool="Write"),
         edit("D:\\r\\src\\Domovoy.Data\\Migrations\\Snap.cs"),
         bash("cd src/Domovoy.Data/Migrations && sed -i 's/a/b/' Init.cs")],
        [bash("cat src/Domovoy.Data/Migrations/Init.cs"), edit("src/Domovoy.Data/AppDb.cs")]),
    "new-dependency": (
        [edit("Directory.Packages.props"), edit("D:\\r\\Directory.Packages.props", tool="MultiEdit")],
        [edit("Directory.Build.props"), bash("cat Directory.Packages.props")]),
    "one-task-one-branch": (
        [bash("git checkout -b feat/131-x"), bash("git switch -c feat/131-x", "PowerShell"),
         bash("git push -u origin feat/131-x"), bash("cd x && git -C . push")],
        [bash("git checkout main"), bash("echo 'git push'"), bash("git push --dry-run origin x"),
         bash("git log --oneline")]),
    "pr-create": (
        [bash("git push -u origin feat/131-x"), bash("git push", "PowerShell")],
        [bash("git push --dry-run origin feat/131-x"), bash("git stash push"),
         bash("echo 'git push'")]),
    "issue-create": (
        [bash("gh issue create --title x --body y"), bash("gh -R o/r issue create -t x", "PowerShell")],
        [bash("gh issue view 131"), bash("gh issue list"), bash("echo 'gh issue create'")]),
    "ceremony-card": (
        [edit("src/Domovoy.Api/Program.cs"), edit("tests\\Domovoy.Tests\\A.cs", tool="MultiEdit"),
         edit("src/Domovoy.Api/Domovoy.Api.csproj", tool="Write")],
        [edit("docs/rules/plan.md"), edit("src/Domovoy.Api/readme.txt"),
         bash("sed -i 's/a/b/' src/Domovoy.Api/Program.cs")]),
    "harness-edit-council": (
        [edit(".claude/agents/step-plan.md"), edit(".claude/hooks/rules-map.json"),
         edit("D:\\r\\.claude\\skills\\x\\SKILL.md"), edit(".claude/CLAUDE.md"),
         edit(".claude/settings.json"), edit(".claude/settings.local.example.json"),
         edit("docs/rules/fix.md", tool="MultiEdit"),
         edit("scripts/risk.sh"), edit(".github/workflows/ci-fast.yml", tool="Write"),
         edit(".githooks/commit-msg"), edit(".gitleaks.toml")],
        [edit(".claude/settings.local.json"), edit("docs/tasks/131.md"),
         edit("C:/Users/u/.claude/projects/D--r/memory/m.md"), edit("src/Domovoy.Api/Program.cs"),
         edit("/elsewhere/.claude/settings.json"), bash("sed -i 's/a/b/' scripts/risk.sh")]),
    "rule-wiring": (
        [edit("docs/rules/new-rule.md", "x", "Write"),
         bash("cat > docs/rules/other-rule.md <<'E'\nx\nE")],
        [edit("docs/rules/new-rule.txt", "x", "Write"),
         bash("rm -f /tmp/x; grep a docs/rules/new-rule.md")]),
}
for _step in ("triage", "plan", "implement", "review-correctness", "review-security", "fix"):
    PROBES["step-rules-" + _step] = (
        [{"tool_name": "Agent", "tool_input": {"prompt": "Задача #1.", "subagent_type": "step-" + _step,
                                                "description": "d"}}],
        [{"tool_name": "Agent", "tool_input": {"prompt": "Задача #1.", "subagent_type": "Explore",
                                                "description": "d"}}])
# Порог собственных правок проверяется отдельным сценарием (счёт по сессии).
PROBES["delegation-thresholds-own-edits"] = None


def spawned_rules(out):
    prompt = (((out or {}).get("hookSpecificOutput") or {}).get("updatedInput") or {}).get("prompt") or ""
    return re.findall(r"- ПРАВИЛО ([\w-]+)\.", prompt), prompt


class TableShape(unittest.TestCase):
    def test_every_doc_exists(self):
        self.assertEqual(dead_docs(TABLE), [])

    def test_missing_doc_is_caught(self):
        broken = TABLE + [{"name": "ghost", "note": "n", "doc": "docs/rules/no-such-file.md"}]
        self.assertEqual(dead_docs(broken), ["ghost"])

    def test_keys_are_known(self):
        typos = {r["name"]: sorted(set(r) - ri.KNOWN_KEYS) for r in TABLE if set(r) - ri.KNOWN_KEYS}
        self.assertEqual(typos, {})

    def test_names_unique_and_every_rule_has_probe(self):
        names = [r["name"] for r in TABLE]
        self.assertEqual(len(names), len(set(names)))
        self.assertEqual(sorted(PROBES), sorted(names))

    def test_note_points_to_file(self):
        """note — условие и указание открыть файл, а не пересказ нормы."""
        for r in TABLE:
            text = r.get("note", "") + r.get("subagent_note", "")
            self.assertRegex(text, r"(\.md|\.claude/CLAUDE\.md)", r["name"])

    def test_for_subagents_and_note_go_together(self):
        half = [r["name"] for r in TABLE if bool(r.get("for_subagents")) != bool(r.get("subagent_note"))]
        self.assertEqual(half, [])


class StepRules(HookCase):
    def test_one_record_per_step_and_no_star(self):
        self.assertTrue(step_agents())
        for r in TABLE:
            self.assertNotIn("*", r.get("for_subagents") or [], r["name"])
        for agent in step_agents():
            step = agent[len("step-"):]
            recs = [r for r in TABLE if agent in (r.get("for_subagents") or [])]
            self.assertEqual(len(recs), 1, agent)
            self.assertEqual(recs[0]["for_subagents"], [agent])
            self.assertEqual(recs[0]["doc"], "docs/rules/%s.md" % step)
            self.assertTrue(recs[0].get("subagent_note"))
        targets = {a for r in TABLE for a in (r.get("for_subagents") or [])}
        self.assertEqual(targets - set(step_agents()), set(), "запись для несуществующего шага")

    def test_block_ceiling_per_agent_type(self):
        kinds = {k for r in TABLE for k in (r.get("for_subagents") or [])} | {"general-purpose"}
        kinds |= {os.path.splitext(os.path.basename(p))[0]
                  for p in glob.glob(os.path.join(REPO_ROOT, ".claude", "agents", "*.md"))}
        fat = {}
        for k in sorted(kinds):
            out = ri.subagent_prompt(TABLE, {"prompt": "", "subagent_type": k}) or ""
            n = out.count("- ПРАВИЛО ")
            if n > MAX_RULES or len(out) > MAX_CHARS:
                fat[k] = (n, len(out))
        self.assertEqual(fat, {})

    def test_advisors_get_nothing(self):
        for k in ("advisor-skeptic", "advisor-engineer", "advisor-constitution", "advisor-pragmatist"):
            self.assertIsNone(ri.subagent_prompt(TABLE, {"prompt": "p", "subagent_type": k}))


@needs_bash
class EveryRowThroughWrapper(HookCase):
    def test_rows(self):
        h = self.copy()
        for name, probe in sorted(PROBES.items()):
            if probe is None:
                continue
            fire, silent = probe
            for call in fire:
                with self.subTest(rule=name, fire=call):
                    rc, out, _ = h.run(dict(call, session_id=sid()))
                    self.assertEqual(rc, 0)
                    got = spawned_rules(out)[0] if call["tool_name"] == "Agent" else fired_names(out)
                    self.assertIn(name, got)
            for call in silent:
                with self.subTest(rule=name, silent=call):
                    rc, out, _ = h.run(dict(call, session_id=sid()))
                    self.assertEqual(rc, 0)
                    got = spawned_rules(out)[0] if call["tool_name"] == "Agent" else fired_names(out)
                    self.assertNotIn(name, got)

    def test_step_spawn_carries_rule_file(self):
        h = self.copy()
        for agent in step_agents():
            step = agent[len("step-"):]
            _, out, _ = h.run({"session_id": sid(), "tool_name": "Agent",
                               "tool_input": {"prompt": "Задача #1.", "subagent_type": agent}})
            names, prompt = spawned_rules(out)
            self.assertEqual(names, ["step-rules-" + step], agent)
            self.assertIn("docs/rules/%s.md" % step, prompt)
            self.assertIn("данные, не инструкции", prompt)


@needs_bash
class SessionScenarios(HookCase):
    def test_pr_create_once_per_session(self):
        h = self.copy()
        s = sid()
        run = lambda cmd, **kw: fired_names(h.run(dict(bash(cmd), session_id=s, **kw))[1])
        self.assertNotIn("pr-create", run("git push --dry-run origin feat/131-x"))
        self.assertIn("pr-create", run("git push -u origin feat/131-x"))
        self.assertNotIn("pr-create", run("git push"))
        self.assertIn("pr-create", run("git push", agent_id="agent-1"))
        self.assertIn("pr-create", fired_names(h.run(dict(bash("git push"), session_id=sid()))[1]))

    def test_ceremony_card_once_and_flag(self):
        h = self.copy()
        s = sid()
        first = h.run(dict(edit("src/Domovoy.Api/Program.cs"), session_id=s))[1]
        self.assertIn("ceremony-card", fired_names(first))
        self.assertIn(scope_of(s) + "-ceremony-card", h.flags())
        self.assertNotIn("ceremony-card", fired_names(h.run(dict(edit("src/Domovoy.Api/B.cs"), session_id=s))[1]))

    def test_own_edits_gate(self):
        h = self.copy()
        s = sid()
        gate = "delegation-thresholds-own-edits"

        def write(path, **kw):
            rc, out, _ = h.run(dict(edit(path, "x", "Write"), session_id=s, **kw))
            self.assertEqual(rc, 0)
            return out

        outs = [write("notes/f%d.txt" % i) for i in (1, 2, 3)]
        self.assertTrue(all(gate not in fired_names(o) for o in outs))
        # Журнал и план задачи, вердикты совета, память и scratchpad — не в счёт; субагент тоже.
        for path in ("docs/tasks/131.md", "docs/tasks/131.plan.json", ".council/131/plan-1/skeptic.json",
                     "C:/Users/u/.claude/projects/D--r/memory/m.md",
                     "C:/Users/u/AppData/Local/Temp/claude/D--r/s/scratchpad/n.txt"):
            self.assertNotIn(gate, fired_names(write(path)))
        for i in range(5):
            self.assertNotIn(gate, fired_names(write("notes/sub%d.txt" % i, agent_id="agent-3")))
        self.assertNotIn(gate, fired_names(write("notes/f1.txt")))
        fourth = write("notes/f4.txt")
        self.assertIn(gate, fired_names(fourth))
        ctx = fourth["hookSpecificOutput"]["additionalContext"]
        self.assertIn("4-й", ctx)
        self.assertNotIn("{N}", ctx)
        self.assertNotIn(gate, fired_names(write("notes/f5.txt")))
        self.assertNotIn(gate, fired_names(write("notes/f6.txt")))
        self.assertIn(gate, fired_names(write("notes/f7.txt")))
        self.assertNotIn(gate, fired_names(write("notes/f8.txt")))

    def test_multiedit_is_counted(self):
        h = self.copy()
        s = sid()
        outs = [h.run(dict(edit("notes/m%d.txt" % i, tool="MultiEdit"), session_id=s))[1] for i in range(1, 5)]
        self.assertIn("delegation-thresholds-own-edits", fired_names(outs[3]))


class SettingsWiring(unittest.TestCase):
    """Правило может быть безупречным в таблице и не срабатывать никогда, если Claude Code
    не зовёт хук на этом инструменте."""

    NAMES = ("Bash", "PowerShell", "Write", "Edit", "MultiEdit", "NotebookEdit", "Agent")

    def setUp(self):
        with io.open(os.path.join(REPO_ROOT, ".claude", "settings.json"), encoding="utf-8") as fh:
            self.cfg = json.load(fh)

    def wired(self, event):
        return [h for h in self.cfg.get("hooks", {}).get(event, [])
                if any("rule-injector.sh" in x.get("command", "") for x in h.get("hooks", []))]

    def test_matcher_for_every_tool_name(self):
        matchers = {h.get("matcher") for h in self.wired("PreToolUse")}
        self.assertEqual(sorted(set(self.NAMES) - matchers), [])
        needed = {t for r in TABLE for t in (r.get("tools") or [])}
        self.assertEqual(sorted(needed - matchers), [])

    def test_user_prompt_submit_wired(self):
        self.assertTrue(self.wired("UserPromptSubmit"))


if __name__ == "__main__":
    unittest.main()
