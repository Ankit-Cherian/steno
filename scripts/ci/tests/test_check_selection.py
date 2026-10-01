"""Ensure documentation changes cannot accidentally waive required checks."""
import importlib.util
import itertools
import os
from pathlib import Path
import re
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

# A gate skipped by its own condition reports success to required checks, so
# its wiring matters as much as its script.
GATES = {'validate.yml': 'policy', 'security.yml': 'changes'}
REFERENCE = re.compile(r'[A-Za-z_][A-Za-z0-9_-]*(?:\.[A-Za-z0-9_-]+)+')


def gate_wiring_errors(workflow, classifier):
    errors = []
    jobs = workflow['jobs']
    gate = jobs.get('gate', {})
    others = [name for name in jobs if name != 'gate']
    if gate.get('if') != 'always()':
        errors.append('gate must run with exactly if: always()')
    needs = gate.get('needs')
    needs = [needs] if isinstance(needs, str) else needs or []
    if sorted(needs) != sorted(others):
        errors.append(f'gate needs {sorted(needs)} instead of every other job {sorted(others)}')
    steps = gate.get('steps', [])
    environment = {}
    for step in steps:
        if 'if' in step or 'continue-on-error' in step:
            errors.append('gate steps must not be conditional or allowed to fail')
        environment.update(step.get('env', {}))
        environment.update(gate.get('env', {}))
    script = '\n'.join(step.get('run', '') for step in steps)
    results = {name: value for name, value in environment.items()
               if isinstance(value, str) and '.result' in value}
    for job in needs:
        mapped = [name for name, value in results.items() if value == '${{ needs.' + job + '.result }}']
        if len(mapped) != 1:
            errors.append(f'{job} result must reach the gate through exactly one variable, found {mapped}')
        elif '$' + mapped[0] not in script:
            errors.append(f'gate script never reads {mapped[0]}')
    for name, value in results.items():
        if not re.fullmatch(r'\$\{\{ needs\.[A-Za-z0-9_-]+\.result \}\}', value) or value[len('${{ needs.'):-len('.result }}')] not in needs:
            errors.append(f'{name} does not hold exactly one needed job result')
    if 'if' in jobs.get(classifier, {}):
        errors.append('the classifier itself must always run')
    for name in others:
        condition = jobs[name].get('if')
        if condition is None:
            continue
        for reference in REFERENCE.findall(condition):
            if reference.startswith(f'needs.{classifier}.outputs.'):
                job_needs = jobs[name].get('needs')
                job_needs = [job_needs] if isinstance(job_needs, str) else job_needs or []
                if classifier not in job_needs:
                    errors.append(f'{name} reads the classifier without needing it')
            elif reference == 'github.event_name' and environment.get('EVENT_NAME') == '${{ github.event_name }}':
                # The gate checks the same event, so it knows which result to expect.
                continue
            else:
                errors.append(f'{name} condition uses {reference}, which the gate cannot see')
    return errors


class GateWiringTests(unittest.TestCase):
    def workflow(self, path, replacements=()):
        source = (ROOT / '.github/workflows' / path).read_text()
        for old, new in replacements:
            self.assertEqual(source.count(old), 1, old)
            source = source.replace(old, new)
        return POLICY.parse_workflow(source)

    def test_both_gates_are_wired_to_every_job_and_always_run(self):
        for path, classifier in GATES.items():
            with self.subTest(workflow=path):
                self.assertEqual(gate_wiring_errors(self.workflow(path), classifier), [])

    def test_conditional_gate_is_rejected(self):
        for path, classifier in GATES.items():
            with self.subTest(workflow=path):
                workflow = self.workflow(path, [('\n    if: always()\n', f"\n    if: needs.{classifier}.result == 'success'\n")])
                self.assertIn('gate must run with exactly if: always()', gate_wiring_errors(workflow, classifier))

    def test_job_missing_from_gate_needs_is_rejected(self):
        validate = self.workflow('validate.yml', [('needs: [policy, macos, runtime]', 'needs: [policy, runtime]')])
        self.assertTrue(any('gate needs' in error for error in gate_wiring_errors(validate, 'policy')))
        security = self.workflow('security.yml', [('needs: [changes, dependency-review, actions, native]', 'needs: [changes, dependency-review, actions]')])
        self.assertTrue(any('gate needs' in error for error in gate_wiring_errors(security, 'changes')))

    def test_result_variable_pointing_at_the_wrong_job_is_rejected(self):
        validate = self.workflow('validate.yml', [('MACOS_RESULT: ${{ needs.macos.result }}', 'MACOS_RESULT: ${{ needs.runtime.result }}')])
        self.assertTrue(any('macos result' in error for error in gate_wiring_errors(validate, 'policy')))
        security = self.workflow('security.yml', [('NATIVE_RESULT: ${{ needs.native.result }}', 'NATIVE_RESULT: ${{ needs.actions.result }}')])
        self.assertTrue(any('native result' in error for error in gate_wiring_errors(security, 'changes')))

    def test_job_conditions_outside_the_classifier_are_rejected(self):
        validate = self.workflow('validate.yml', [("    if: needs.policy.outputs.scope == 'full'\n    name: Runtime",
                                                   "    if: github.ref == 'refs/heads/main'\n    name: Runtime")])
        self.assertTrue(any('github.ref' in error for error in gate_wiring_errors(validate, 'policy')))
        unchecked_event = self.workflow('security.yml', [('          EVENT_NAME: ${{ github.event_name }}\n', '')])
        self.assertTrue(any('github.event_name' in error for error in gate_wiring_errors(unchecked_event, 'changes')))

    def test_conditional_gate_step_is_rejected(self):
        validate = self.workflow('validate.yml', [('      - name: Require every validation job to succeed\n',
                                                   '      - name: Require every validation job to succeed\n        if: false\n')])
        self.assertIn('gate steps must not be conditional or allowed to fail', gate_wiring_errors(validate, 'policy'))


if __name__ == '__main__':
    unittest.main()
