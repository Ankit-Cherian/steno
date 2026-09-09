"""Regression tests for unsafe workflow structure and policy bypasses."""

import importlib.util
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

    def test_tab_indentation_and_document_indirection_rejected(self):
        self.assertTrue(POLICY.check_workflow(VALID.replace('  test:', '\ttest:')))
        self.assertTrue(POLICY.check_workflow('---\n' + VALID))


if __name__ == '__main__':
    unittest.main()
