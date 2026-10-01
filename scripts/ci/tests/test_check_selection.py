"""Ensure documentation changes cannot accidentally waive required checks."""
import importlib.util
import itertools
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]

def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts/ci' / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

SELECT = load('select_checks', 'select-checks.py')
POLICY = load('selection_policy', 'check-policy.py')

class SelectionTests(unittest.TestCase):
    def test_only_documentation_paths_are_allowed(self):
        for path in ('README.md', 'docs/release/1.0-checklist.md', 'docs/images/app.png'):
            self.assertTrue(SELECT.documentation_path(path))
        for path in ('Steno/View.swift', '.github/workflows/ci.yml', 'scripts/ci/tool.py', 'docs/test.sh', 'docs/../scripts/test.md', 'new-file.md', 'docs/conf.py'):
            self.assertFalse(SELECT.documentation_path(path))

    def test_real_git_diff_and_rename(self):
        with tempfile.TemporaryDirectory() as directory:
            def git(*args):
                return subprocess.check_output(['git', '-C', directory, *args], text=True).strip()
            git('init', '-q')
            git('config', 'user.name', 'Test')
            git('config', 'user.email', 'test@example.invalid')
            root = Path(directory)
            (root / 'README.md').write_text('before\n')
            (root / 'program.py').write_text('pass\n')
            git('add', '.')
            git('commit', '-qm', 'baseline')
            base = git('rev-parse', 'HEAD')
            (root / 'README.md').write_text('after\n')
            git('commit', '-qam', 'docs')
            head = git('rev-parse', 'HEAD')
            original = Path.cwd()
            os.chdir(root)
            def pull_request(before, after):
                return {'pull_request': {'base': {'sha': before}, 'head': {'sha': after}}}
            try:
                self.assertEqual(SELECT.select('pull_request', pull_request(base, head), 'CI'), 'docs')
                self.assertEqual(SELECT.select('pull_request', pull_request(base, head), 'Security'), 'docs')
                self.assertEqual(SELECT.select('pull_request', pull_request(head, head), 'CI'), 'full')
                git('mv', 'program.py', 'CONTRIBUTING.md')
                git('commit', '-qm', 'rename executable')
                changed = git('rev-parse', 'HEAD')
                self.assertEqual(SELECT.select('pull_request', pull_request(head, changed), 'CI'), 'full')
                (root / 'README.md').unlink()
                (root / 'README.md').symlink_to('CONTRIBUTING.md')
                git('add', '.')
                git('commit', '-qm', 'symlink')
                self.assertEqual(SELECT.select('pull_request', pull_request(changed, git('rev-parse', 'HEAD')), 'CI'), 'full')
                before_delete = git('rev-parse', 'HEAD')
                (root / 'CONTRIBUTING.md').unlink()
                git('commit', '-qam', 'delete documentation')
                self.assertEqual(SELECT.select('pull_request', pull_request(before_delete, git('rev-parse', 'HEAD')), 'CI'), 'docs')
            finally:
                os.chdir(original)

    def test_documentation_only_main_pushes_and_merge_groups_require_full(self):
        # A release commit is often documentation only; main must still be fully tested.
        with tempfile.TemporaryDirectory() as directory:
            def git(*args):
                return subprocess.check_output(['git', '-C', directory, *args], text=True).strip()
            git('init', '-q')
            git('config', 'user.name', 'Test')
            git('config', 'user.email', 'test@example.invalid')
            root = Path(directory)
            (root / 'CHANGELOG.md').write_text('before\n')
            git('add', '.')
            git('commit', '-qm', 'baseline')
            base = git('rev-parse', 'HEAD')
            (root / 'CHANGELOG.md').write_text('after\n')
            git('commit', '-qam', 'docs')
            head = git('rev-parse', 'HEAD')
            original = Path.cwd()
            os.chdir(root)
            try:
                self.assertEqual(SELECT.select('pull_request', {'pull_request': {'base': {'sha': base}, 'head': {'sha': head}}}, 'CI'), 'docs')
                for workflow in ('CI', 'Security'):
                    self.assertEqual(SELECT.select('push', {'before': base, 'after': head}, workflow), 'full')
                    self.assertEqual(SELECT.select('merge_group', {'merge_group': {'base_sha': base, 'head_sha': head}}, workflow), 'full')
            finally:
                os.chdir(original)

    def test_release_schedule_dispatch_and_missing_base_require_full(self):
        for event in ('push', 'merge_group', 'schedule', 'workflow_dispatch', 'workflow_call', 'unknown'):
            self.assertEqual(SELECT.select(event, {}, 'CI'), 'full')
        # Both release callers reuse validation and security; each must get the full suite.
        for workflow in ('Release', 'Publish release'):
            for event in ('pull_request', 'push', 'workflow_dispatch'):
                with self.subTest(workflow=workflow, event=event):
                    self.assertEqual(SELECT.select(event, {}, workflow), 'full')
        self.assertEqual(SELECT.select('pull_request', {'pull_request': {'base': {'sha': '0' * 40}, 'head': {'sha': 'a' * 40}}}, 'CI'), 'full')

    def test_release_caller_names_match_the_release_workflows(self):
        for path, name in (('release.yml', 'Release'), ('publish-release.yml', 'Publish release')):
            workflow = POLICY.parse_workflow((ROOT / '.github/workflows' / path).read_text())
            self.assertEqual(workflow['name'], name)

    def test_unavailable_comparison_falls_back_to_full(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            event = root / 'event.json'
            output = root / 'output'
            for payload in ('{}', 'null', '[]', '{"pull_request": null}', '{"pull_request": {"base": {}, "head": {}}}'):
                event.write_text(payload)
                output.write_text('')
                with patch.dict(os.environ, {'GITHUB_EVENT_PATH': str(event), 'GITHUB_EVENT_NAME': 'pull_request', 'GITHUB_WORKFLOW': 'CI', 'GITHUB_OUTPUT': str(output)}):
                    SELECT.main()
                self.assertEqual(output.read_text(), 'scope=full\n')

    def test_actual_ci_gate_rejects_missing_failed_cancelled_and_wrong_skips(self):
        workflow = POLICY.parse_workflow((ROOT / '.github/workflows/validate.yml').read_text())
        command = workflow['jobs']['gate']['steps'][0]['run']
        for scope, policy, macos, runtime in itertools.product(('docs', 'full', ''), ('success', 'failure', 'skipped', 'cancelled'), ('success', 'failure', 'skipped', 'cancelled'), ('success', 'failure', 'skipped', 'cancelled')):
            env = dict(os.environ, SCOPE=scope, POLICY_RESULT=policy, MACOS_RESULT=macos, RUNTIME_RESULT=runtime)
            result = subprocess.run(['bash', '-e', '-c', command], env=env, capture_output=True)
            expected = policy == 'success' and ((scope == 'docs' and macos == runtime == 'skipped') or (scope == 'full' and macos == runtime == 'success'))
            self.assertEqual(result.returncode == 0, expected, env)

    def test_security_gate_rejects_failed_classification_or_unexpected_skip(self):
        workflow = POLICY.parse_workflow((ROOT / '.github/workflows/security.yml').read_text())
        command = workflow['jobs']['gate']['steps'][0]['run']
        for scope, classification, native in itertools.product(('docs', 'full', ''), ('success', 'failure', 'skipped'), ('success', 'failure', 'skipped', 'cancelled')):
            env = dict(os.environ, SCOPE=scope, SCOPE_RESULT=classification, NATIVE_RESULT=native, ACTIONS_RESULT='success', DEPENDENCY_RESULT='success', EVENT_NAME='pull_request')
            result = subprocess.run(['bash', '-e', '-c', command], env=env, capture_output=True)
            expected = classification == 'success' and ((scope == 'docs' and native == 'skipped') or (scope == 'full' and native == 'success'))
            self.assertEqual(result.returncode == 0, expected)

if __name__ == '__main__':
    unittest.main()
