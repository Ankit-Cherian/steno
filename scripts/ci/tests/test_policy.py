"""Regression tests for unsafe workflow structure and policy bypasses."""

import importlib.util
import os
import subprocess
import tempfile
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location('workflow_policy', Path(__file__).parents[1] / 'check-policy.py')
POLICY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POLICY)

VALID = '''name: Test
on:
  pull_request:
permissions:
  contents: read
jobs:
  test:
    runs-on: ubuntu-24.04
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@1111111111111111111111111111111111111111
        with:
          persist-credentials: false
      - name: Check
        run: |
          echo 'uses: not-a-real-action@v1'
          echo 'permissions: write-all'
'''


class WorkflowPolicyTests(unittest.TestCase):
    def assert_rejected(self, source, fragment):
        errors = POLICY.check_workflow(source)
        self.assertTrue(errors, 'unsafe workflow unexpectedly passed')
        self.assertIn(fragment, '\n'.join(errors))

    def test_explicit_safe_workflow_and_shell_body_pass(self):
        self.assertEqual(POLICY.check_workflow(VALID), [])

    def test_unpinned_action(self):
        self.assert_rejected(VALID.replace('1111111111111111111111111111111111111111', 'v4'), 'full commit SHA')

    def test_short_sha_and_docker_tag(self):
        for reference in ('actions/checkout@abcdef1', 'docker://alpine:latest'):
            with self.subTest(reference=reference):
                self.assert_rejected(VALID.replace('actions/checkout@' + '1' * 40, reference), 'full commit SHA')

    def test_quoted_uses_key_is_checked(self):
        self.assert_rejected(VALID.replace('uses:', '"uses":').replace('1' * 40, 'v4'), 'full commit SHA')

    def test_checkout_must_disable_credentials(self):
        for replacement in ('true', '${{ false }}'):
            with self.subTest(value=replacement):
                self.assert_rejected(VALID.replace('persist-credentials: false', f'persist-credentials: {replacement}'), 'persist-credentials: false')
        self.assert_rejected(VALID.replace('        with:\n          persist-credentials: false\n', ''), 'persist-credentials: false')

    def test_forbidden_event_all_supported_spellings(self):
        for declaration in ('on: [pull_request_target]', "'on': pull_request_target", 'on:\n  "pull_request_target":', 'on:\n  - pull_request_target'):
            with self.subTest(declaration=declaration):
                self.assert_rejected(VALID.replace('on:\n  pull_request:', declaration), 'forbidden workflow trigger')

    def test_workflow_run_is_not_privileged_pr_escape_hatch(self):
        self.assert_rejected(VALID.replace('pull_request:', 'workflow_run:'), 'forbidden workflow trigger')

    def test_flow_mapping_and_aliases_fail_closed(self):
        replacements = [
            ('on:\n  pull_request:', 'on: {pull_request_target: null}'),
            ('permissions:\n  contents: read', 'permissions: &grants\n  contents: write'),
            ('permissions:\n  contents: read', 'permissions: *grants'),
            ('    timeout-minutes: 10', '    <<: *defaults'),
        ]
        for before, after in replacements:
            with self.subTest(after=after):
                self.assertTrue(POLICY.check_workflow(VALID.replace(before, after)))

    def test_duplicate_keys_fail_closed(self):
        self.assert_rejected(VALID.replace('          persist-credentials: false', '          persist-credentials: false\n          persist-credentials: true'), 'duplicate key')

    def test_write_all_and_workflow_write_scope_rejected(self):
        self.assert_rejected(VALID.replace('permissions:\n  contents: read', 'permissions: write-all'), 'least-privilege')
        self.assert_rejected(VALID.replace('contents: read', 'contents: write'), 'read-only')
        self.assert_rejected(VALID.replace('    runs-on:', '    permissions: write-all\n    runs-on:'), 'explicit scope map')

    def test_missing_or_excessive_timeout(self):
        self.assert_rejected(VALID.replace('    timeout-minutes: 10\n', ''), 'timeout-minutes')
        for value in ('0', '121', '${{ inputs.timeout }}'):
            self.assert_rejected(VALID.replace('timeout-minutes: 10', 'timeout-minutes: ' + value), 'timeout-minutes')

    def test_step_timeout_does_not_substitute_for_job_timeout(self):
        source = VALID.replace('    timeout-minutes: 10\n', '').replace('      - name: Check', '      - name: Check\n        timeout-minutes: 10')
        self.assert_rejected(source, 'timeout-minutes')

    def test_pinned_reusable_job_needs_no_runner_timeout(self):
        source = VALID.split('jobs:')[0] + 'jobs:\n  call:\n    uses: ./.github/workflows/validate.yml\n'
        self.assertEqual(POLICY.check_workflow(source), [])

    def test_reusable_external_workflow_must_be_pinned(self):
        source = VALID.split('jobs:')[0] + 'jobs:\n  call:\n    uses: owner/repo/.github/workflows/build.yml@main\n'
        self.assert_rejected(source, 'full commit SHA')

    def test_matrix_runner_values_are_checked(self):
        source = VALID.replace('runs-on: ubuntu-24.04', 'runs-on: ${{ matrix.os }}\n    strategy:\n      matrix:\n        os: [macos-15, macos-26]')
        self.assertEqual(POLICY.check_workflow(source), [])
        self.assert_rejected(source.replace('macos-26]', 'self-hosted]'), 'approved GitHub-hosted runner')

    def test_event_interpolation_is_rejected_but_env_is_supported(self):
        self.assert_rejected(VALID.replace("echo 'uses: not-a-real-action@v1'", 'echo "${{ github.event.pull_request.title }}"'), 'pass event data through env')
        source = VALID.replace('        run: |', '        env:\n          TITLE: ${{ github.event.pull_request.title }}\n        run: |')
        self.assertEqual(POLICY.check_workflow(source), [])

    def codeql_workflow(self, action, workflow_env=None, job_env=None, step_env=None):
        source = VALID.replace('actions/checkout@', f'github/codeql-action/{action}@')
        for marker, indent, values in (
            ('jobs:', '', workflow_env),
            ('    steps:', '    ', job_env),
            ('        with:', '        ', step_env),
        ):
            if values is not None:
                env = indent + 'env:\n'
                env += ''.join(f'{indent}  {key}: {value}\n' for key, value in values.items())
                source = source.replace(marker, env + marker)
        return source

    def test_codeql_requires_full_source_queries_for_init_and_analyze(self):
        for action in ('init', 'analyze'):
            with self.subTest(action=action):
                self.assert_rejected(self.codeql_workflow(action), 'CODEQL_ACTION_DIFF_INFORMED_QUERIES')

    def test_codeql_inherits_explicit_false_at_each_environment_scope(self):
        for action in ('init', 'analyze'):
            for scope in ('workflow_env', 'job_env', 'step_env'):
                for literal in ('false', '"false"', "'false'"):
                    with self.subTest(action=action, scope=scope, literal=literal):
                        source = self.codeql_workflow(action, **{scope: {
                            'CODEQL_ACTION_DIFF_INFORMED_QUERIES': literal,
                        }})
                        self.assertEqual(POLICY.check_workflow(source), [])

    def test_codeql_rejects_nonliteral_or_enabled_queries_at_each_scope(self):
        for action in ('init', 'analyze'):
            for scope in ('workflow_env', 'job_env', 'step_env'):
                for value in ('true', '${{ false }}', '${{ vars.DIFF_QUERIES }}', '""', 'False', ''):
                    with self.subTest(action=action, scope=scope, value=value):
                        source = self.codeql_workflow(action, **{scope: {
                            'CODEQL_ACTION_DIFF_INFORMED_QUERIES': value,
                        }})
                        self.assert_rejected(source, 'CODEQL_ACTION_DIFF_INFORMED_QUERIES')

    def test_codeql_narrower_unsafe_override_cannot_hide_behind_workflow_false(self):
        for action in ('init', 'analyze'):
            for scope in ('job_env', 'step_env'):
                for value in ('true', '${{ false }}', ''):
                    with self.subTest(action=action, scope=scope, value=value):
                        source = self.codeql_workflow(action,
                            workflow_env={'CODEQL_ACTION_DIFF_INFORMED_QUERIES': 'false'},
                            **{scope: {'CODEQL_ACTION_DIFF_INFORMED_QUERIES': value}})
                        self.assert_rejected(source, 'CODEQL_ACTION_DIFF_INFORMED_QUERIES')

    def test_codeql_uses_most_specific_environment_value(self):
        for action in ('init', 'analyze'):
            with self.subTest(action=action):
                source = self.codeql_workflow(action,
                    workflow_env={'CODEQL_ACTION_DIFF_INFORMED_QUERIES': 'true'},
                    job_env={'CODEQL_ACTION_DIFF_INFORMED_QUERIES': 'true'},
                    step_env={'CODEQL_ACTION_DIFF_INFORMED_QUERIES': 'false'})
                self.assertEqual(POLICY.check_workflow(source), [])
                inherited = self.codeql_workflow(action,
                    workflow_env={'CODEQL_ACTION_DIFF_INFORMED_QUERIES': 'false'},
                    job_env={'OTHER': 'true'}, step_env={'ANOTHER': 'true'})
                self.assertEqual(POLICY.check_workflow(inherited), [])

    def test_codeql_environment_indirection_fails_closed(self):
        for action in ('init', 'analyze'):
            for scope, marker in (('workflow_env', 'jobs:'), ('job_env', '    steps:'), ('step_env', '        with:')):
                for value in ('${{ fromJSON(vars.ENV) }}', '[false]', ''):
                    with self.subTest(action=action, scope=scope, value=value):
                        source = self.codeql_workflow(action)
                        indent = marker[:len(marker) - len(marker.lstrip())]
                        source = source.replace(marker, f'{indent}env: {value}\n' + marker)
                        self.assert_rejected(source, 'CodeQL env must be an explicit mapping')

    def test_codeql_similarly_named_or_unrelated_actions_do_not_require_flag(self):
        for action in ('upload-sarif', 'init-extra', 'analyze-extra'):
            with self.subTest(action=action):
                self.assertEqual(POLICY.check_workflow(self.codeql_workflow(action)), [])

    def test_ci_avoids_duplicate_feature_pushes_and_keeps_validation_entrypoints(self):
        workflow = POLICY.parse_workflow((Path(__file__).parents[3] / '.github/workflows/ci.yml').read_text())
        self.assertEqual(workflow['on']['push'], {'branches': ['main']})
        self.assertTrue({'pull_request', 'merge_group', 'workflow_dispatch'} <= set(workflow['on']))
        self.assertEqual(workflow['jobs']['validate']['uses'], './.github/workflows/validate.yml')
        self.assertNotIn('if', workflow['jobs']['validate'])

    def test_security_workflow_dispatches_cpp_review_and_preserves_gate_failure(self):
        workflow = POLICY.parse_workflow((Path(__file__).parents[3] / '.github/workflows/security.yml').read_text())
        steps = [step for step in workflow['jobs']['native']['steps']
                 if step.get('name') == 'Block high and critical findings']
        self.assertEqual(len(steps), 1)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            command = root / 'python3'
            command.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$ARGUMENT_LOG"\nexit "$GATE_EXIT_STATUS"\n')
            command.chmod(0o755)
            arguments = root / 'arguments.txt'
            for category in ('/language:c-cpp', '/language:swift'):
                for status in (0, 31):
                    with self.subTest(category=category, status=status):
                        environment = {**os.environ, 'PATH': str(root) + os.pathsep + os.environ['PATH'],
                            'ANALYSIS_CATEGORY': category, 'ARGUMENT_LOG': str(arguments),
                            'GATE_EXIT_STATUS': str(status)}
                        result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', steps[0]['run']],
                                                env=environment, cwd=root, capture_output=True, text=True)
                        self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                        expected = ['scripts/ci/check-sarif.py', '--directory', 'build/codeql-results',
                                    '--category', category]
                        if category == '/language:c-cpp':
                            expected += ['--reviewed-dispositions', 'scripts/ci/reviewed-findings.json',
                                         '--source-root', '.']
                        self.assertEqual(arguments.read_text().splitlines(), expected)

    def test_tab_indentation_and_document_indirection_rejected(self):
        self.assertTrue(POLICY.check_workflow(VALID.replace('  test:', '\ttest:')))
        self.assertTrue(POLICY.check_workflow('---\n' + VALID))


if __name__ == '__main__':
    unittest.main()
