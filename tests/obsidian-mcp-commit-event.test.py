#!/usr/bin/env python3
import json
import os
import shutil
import signal
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PRODUCER = ROOT / "packages/client/bin/obsidian-mcp-commit-event"
IDENTITY = {
    "GIT_AUTHOR_NAME": "Test Author",
    "GIT_AUTHOR_EMAIL": "author@example.invalid",
    "GIT_COMMITTER_NAME": "Test Committer",
    "GIT_COMMITTER_EMAIL": "committer@example.invalid",
}


class CommitEventTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.repo = self.root / "fixture repo"
        self.repo.mkdir()
        self.git("init", "-b", "codex/939-native-capture")
        self.repo = self.repo.resolve()

    def tearDown(self):
        self.temp.cleanup()

    def environment(self, **overrides):
        env = os.environ.copy()
        env.update(IDENTITY)
        env.update(
            {
                "HOME": str(self.home),
                "XDG_CONFIG_HOME": str(self.home / ".config"),
                "GIT_CONFIG_NOSYSTEM": "1",
                "LC_ALL": "C.UTF-8",
            }
        )
        env.update(overrides)
        return env

    def git(self, *args, cwd=None, env=None, check=True):
        target = cwd or self.repo
        target.mkdir(parents=True, exist_ok=True)
        return subprocess.run(
            ["git", "-C", str(target), *args],
            env=env or self.environment(),
            capture_output=True,
            check=check,
            text=True,
        )

    def commit(
        self, name="first file.txt", body="first\n", date="2026-10-09T08:07:00-04:00"
    ):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
        self.git("add", "--", name)
        env = self.environment(GIT_AUTHOR_DATE=date, GIT_COMMITTER_DATE=date)
        self.git("commit", "-m", f"commit {name}", env=env)
        return self.git("rev-parse", "HEAD").stdout.strip()

    def event(self, commit, repository=None, **updates):
        value = {
            "schemaVersion": 1,
            "event": "git.commit",
            "outcome": "success",
            "repository": str(repository or self.repo),
            "commit": commit,
        }
        value.update(updates)
        return value

    def run_producer(self, event=None, raw=None, env=None, arguments=()):
        if raw is None:
            raw = "" if event is None else json.dumps(event)
        process_env = env or self.environment()
        producer = process_env.get("OBSIDIAN_MCP_EVENT_BIN", str(PRODUCER))
        return subprocess.run(
            [producer, *arguments],
            input=raw,
            env=process_env,
            capture_output=True,
            text=True,
            check=False,
            timeout=15,
        )

    def intercepted_git(self, body):
        real_git = shutil.which("git")
        self.assertIsNotNone(real_git)
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        stub = bin_dir / "git"
        stub.write_text(
            "#!/usr/bin/env python3\n"
            "import os, subprocess, sys, time\nfrom pathlib import Path\n"
            f"repository = {str(self.repo)!r}\nreal_git = {real_git!r}\n"
            "if sys.argv[1:3] != ['-C', repository]:\n    sys.exit(99)\n"
            + body
            + "\nos.execv(real_git, [real_git, *sys.argv[1:]])\n",
            encoding="utf-8",
        )
        stub.chmod(0o755)
        return self.environment(PATH=str(bin_dir) + os.pathsep + os.environ["PATH"])

    def assert_error(self, result, code):
        self.assertEqual(result.returncode, 64, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, f"error:{code}\n")

    def test_successful_event_emits_bounded_metadata(self):
        commit = self.commit("notes/space and ünicode.md")
        self.git(
            "remote",
            "add",
            "origin",
            "https://github.com/example-owner/example.repo.git",
        )

        result = self.run_producer(self.event(commit))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(result.stdout),
            {
                "schemaVersion": 1,
                "hash": commit,
                "branch": "codex/939-native-capture",
                "files": ["notes/space and ünicode.md"],
                "org_repo": "example-owner/example.repo",
                "repo_name": "example.repo",
                "ticket": "939",
                "date": "2026-10-09",
                "time": "08:07",
            },
        )
        self.assertNotIn(str(self.repo), result.stdout)

    def test_missing_failed_and_stale_events_are_rejected(self):
        first = self.commit()
        self.assert_error(self.run_producer(), "INPUT_EMPTY")
        self.assert_error(
            self.run_producer(self.event(first, outcome="failure")), "EVENT_INVALID"
        )
        second = self.commit("second.txt", "second\n")
        self.assertNotEqual(first, second)
        self.assert_error(self.run_producer(self.event(first)), "COMMIT_STALE")

    def test_boolean_schema_and_cli_arguments_are_rejected(self):
        commit = self.commit()
        self.assert_error(
            self.run_producer(self.event(commit, schemaVersion=True)), "EVENT_INVALID"
        )
        self.assert_error(
            self.run_producer(
                self.event(commit), arguments=("--repository", "ignored")
            ),
            "CLI_INVALID",
        )

    def test_invalid_commit_refs_and_repository_mismatch_are_rejected(self):
        commit = self.commit()
        for invalid in ("HEAD", commit[:12], commit.upper(), "../HEAD"):
            with self.subTest(invalid=invalid):
                self.assert_error(
                    self.run_producer(self.event(invalid)), "EVENT_INVALID"
                )
        self.assert_error(self.run_producer(self.event("0" * 40)), "COMMIT_INVALID")
        blob = self.git("rev-parse", "HEAD:first file.txt").stdout.strip()
        self.assert_error(self.run_producer(self.event(blob)), "COMMIT_INVALID")
        self.assert_error(
            self.run_producer(self.event(commit, repository=self.repo.parent)),
            "REPOSITORY_INVALID",
        )

    def test_secreted_remote_is_sanitized_and_malformed_remote_fails_closed(self):
        commit = self.commit()
        secret = "do-not-emit-this-secret"
        self.git(
            "remote",
            "add",
            "origin",
            f"https://user:{secret}@github.com/safe-owner/safe-repo.git?token={secret}#x",
        )

        result = self.run_producer(self.event(commit))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["org_repo"], "safe-owner/safe-repo")
        self.assertNotIn(secret, result.stdout + result.stderr)

        self.git(
            "remote",
            "set-url",
            "origin",
            f"https://github.com/safe-owner/{secret}/repo.git",
        )
        rejected = self.run_producer(self.event(commit))
        self.assert_error(rejected, "REMOTE_INVALID")
        self.assertNotIn(secret, rejected.stdout + rejected.stderr)

    def test_scp_and_ssh_remotes_are_sanitized(self):
        commit = self.commit()
        for remote in (
            "git@github.com:owner-one/repo-one.git",
            "ssh://deploy:password@example.invalid/owner-two/repo-two.git",
        ):
            with self.subTest(remote=remote):
                if self.git("remote", "get-url", "origin", check=False).returncode == 0:
                    self.git("remote", "set-url", "origin", remote)
                else:
                    self.git("remote", "add", "origin", remote)
                result = self.run_producer(self.event(commit))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertRegex(
                    json.loads(result.stdout)["org_repo"],
                    r"^owner-(?:one|two)/repo-(?:one|two)$",
                )
                self.assertNotIn("password", result.stdout + result.stderr)

    def test_absent_origin_uses_safe_local_mainclone_name(self):
        commit = self.commit()

        result = self.run_producer(self.event(commit))

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["org_repo"], "local/fixture-repo")
        self.assertEqual(payload["repo_name"], "fixture-repo")

    def test_detached_head_and_root_commit(self):
        commit = self.commit("root ünicode.txt")
        self.git("checkout", "--detach", commit)

        result = self.run_producer(self.event(commit))

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["branch"], "")
        self.assertEqual(payload["ticket"], "")
        self.assertEqual(payload["files"], ["root ünicode.txt"])

    def test_merge_commit_reports_first_parent_changes(self):
        self.commit("base.txt")
        self.git("switch", "-c", "feature")
        self.commit("feature.txt")
        self.git("switch", "codex/939-native-capture")
        self.commit("main.txt")
        env = self.environment(
            GIT_AUTHOR_DATE="2026-10-09T09:10:00-04:00",
            GIT_COMMITTER_DATE="2026-10-09T09:10:00-04:00",
        )
        self.git("merge", "--no-ff", "feature", "-m", "merge feature", env=env)
        commit = self.git("rev-parse", "HEAD").stdout.strip()

        result = self.run_producer(self.event(commit))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["files"], ["feature.txt"])

    def test_linked_worktree_uses_mainclone_name(self):
        commit = self.commit()
        linked = self.root / "unrelated linked checkout"
        self.git("worktree", "add", "--detach", str(linked), commit)

        result = self.run_producer(self.event(commit, repository=linked))

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["org_repo"], "local/fixture-repo")
        self.assertEqual(payload["repo_name"], "fixture-repo")

    def test_git_override_environment_is_scrubbed(self):
        commit = self.commit()
        hostile = self.root / "hostile"
        hostile.mkdir()
        self.git("init", "-b", "wrong", cwd=hostile)
        hostile_commit = self.commit_in(hostile, "hostile.txt")
        env = self.environment(
            GIT_DIR=str(hostile / ".git"),
            GIT_WORK_TREE=str(hostile),
            GIT_INDEX_FILE=str(hostile / ".git" / "index"),
            GIT_OBJECT_DIRECTORY=str(hostile / ".git" / "objects"),
            GIT_ALTERNATE_OBJECT_DIRECTORIES=str(self.repo / ".git" / "objects"),
        )

        result = self.run_producer(self.event(commit), env=env)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["hash"], commit)
        self.assertNotIn(hostile_commit, result.stdout)

    def commit_in(self, repo, name):
        (repo / name).write_text("hostile\n", encoding="utf-8")
        self.git("add", "--", name, cwd=repo)
        self.git("commit", "-m", "hostile", cwd=repo)
        return self.git("rev-parse", "HEAD", cwd=repo).stdout.strip()

    def test_input_and_git_record_limits_fail_safely(self):
        commit = self.commit()
        oversized = "{" + ("x" * 65536) + "}"
        self.assert_error(self.run_producer(raw=oversized), "INPUT_TOO_LARGE")

        for index in range(4097):
            name = f"many/{index:04d}.txt"
            path = self.repo / name
            path.parent.mkdir(exist_ok=True)
            path.write_text("x", encoding="utf-8")
        self.git("add", "--", "many")
        self.git("commit", "-m", "too many files")
        head = self.git("rev-parse", "HEAD").stdout.strip()
        self.assert_error(self.run_producer(self.event(head)), "GIT_OUTPUT_LIMIT")
        self.assertNotEqual(commit, head)

    def test_incomplete_open_input_has_a_deadline(self):
        producer = os.environ.get("OBSIDIAN_MCP_EVENT_BIN", str(PRODUCER))
        process = subprocess.Popen(
            [producer],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=self.environment(),
            text=True,
        )
        try:
            process.stdin.write('{"schemaVersion":')
            process.stdin.flush()
            process.wait(timeout=7)
            self.assertEqual(process.returncode, 64)
            self.assertEqual(process.stdout.read(), "")
            self.assertEqual(process.stderr.read(), "error:INPUT_TIMEOUT\n")
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
            process.stdin.close()
            process.stdout.close()
            process.stderr.close()

    def assert_git_timeout_terminates_descendants(self, leader_exits):
        commit = self.commit()
        pid_file = self.root / "child.pid"
        group_file = self.root / "group.pid"
        env = self.intercepted_git(
            "if sys.argv[3:] == ['rev-parse', '--show-toplevel']:\n"
            f"    Path({str(group_file)!r}).write_text(str(os.getpid()))\n"
            "    child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])\n"
            f"    Path({str(pid_file)!r}).write_text(str(child.pid))\n"
            + ("    sys.exit(0)\n" if leader_exits else "    time.sleep(60)\n")
        )
        try:
            self.assert_error(
                self.run_producer(self.event(commit), env=env), "GIT_TIMEOUT"
            )
            self.assertTrue(pid_file.exists())
            child_pid = pid_file.read_text()
            status = subprocess.run(
                ["ps", "-o", "stat=", "-p", child_pid],
                capture_output=True,
                text=True,
                check=False,
                timeout=5,
            )
            self.assertIn(status.returncode, (0, 1))
            state = status.stdout.strip()
            self.assertTrue(not state or state.startswith("Z"), state)
        finally:
            if group_file.exists():
                try:
                    os.killpg(int(group_file.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_git_timeout_terminates_descendant_processes(self):
        self.assert_git_timeout_terminates_descendants(False)

    def test_git_timeout_terminates_descendants_after_leader_exit(self):
        self.assert_git_timeout_terminates_descendants(True)

    def test_head_change_during_collection_rejects_all_metadata(self):
        previous = self.commit()
        commit = self.commit("second.txt")
        counter = self.root / "head-checks"
        env = self.intercepted_git(
            "if sys.argv[3:] == ['rev-parse', '--verify', 'HEAD']:\n"
            f"    counter = Path({str(counter)!r})\n"
            "    count = int(counter.read_text()) if counter.exists() else 0\n"
            "    counter.write_text(str(count + 1))\n"
            "    if count == 1:\n"
            f"        subprocess.run([real_git, '-C', repository, 'update-ref', 'HEAD', {previous!r}], check=True)\n"
        )
        self.assert_error(
            self.run_producer(self.event(commit), env=env), "COMMIT_STALE"
        )
        self.assertEqual(counter.read_text(), "2")
        self.assertEqual(self.git("rev-parse", "HEAD").stdout.strip(), previous)


if __name__ == "__main__":
    unittest.main()
