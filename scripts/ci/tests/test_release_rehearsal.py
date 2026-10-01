"""The release rehearsal must be unable to tag, publish, attest or ship a build."""
import importlib.util
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location('rehearsal_policy', ROOT / 'scripts/ci/check-policy.py')
POLICY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POLICY)
WORKFLOW_PATH = ROOT / '.github/workflows/release-rehearsal.yml'


def steps_using(job, action):
    return [step for step in job['steps'] if str(step.get('uses', '')).split('@', 1)[0] == action]


class ReleaseRehearsalTests(unittest.TestCase):
    def setUp(self):
        self.source = WORKFLOW_PATH.read_text()
        self.workflow = POLICY.parse_workflow(self.source)
        self.jobs = self.workflow['jobs']

    def test_passes_the_shared_workflow_policy(self):
        self.assertEqual(POLICY.check_workflow(self.source), [])

    def test_manual_dispatch_on_main_with_version_and_mode(self):
        self.assertEqual(list(self.workflow['on']), ['workflow_dispatch'])
        inputs = self.workflow['on']['workflow_dispatch']['inputs']
        self.assertEqual(set(inputs), {'version', 'mode'})
        self.assertEqual(inputs['mode']['options'], ['signing', 'full'])
        self.assertEqual(inputs['mode']['default'], 'signing')
        self.assertEqual(self.jobs['plan']['if'], "github.ref == 'refs/heads/main'")

    def test_no_scope_can_write_attest_or_mint_identity_tokens(self):
        scopes = [('workflow', self.workflow['permissions'])]
        scopes += [(name, job.get('permissions', {})) for name, job in self.jobs.items()]
        for owner, permissions in scopes:
            with self.subTest(owner=owner):
                self.assertIsInstance(permissions, dict)
                self.assertNotIn('id-token', permissions)
                self.assertNotIn('attestations', permissions)
                self.assertTrue(all(value in ('read', 'none') for value in permissions.values()), permissions)
        for name, job in self.jobs.items():
            with self.subTest(job=name):
                self.assertEqual(job.get('permissions'), {'contents': 'read'})

    def test_never_attests_tags_drafts_or_publishes(self):
        for name, job in self.jobs.items():
            for step in job['steps']:
                with self.subTest(job=name, step=step.get('name') or step.get('uses')):
                    self.assertNotIn('attest', str(step.get('uses', '')))
                    command = step.get('run', '')
                    for forbidden in ('gh release', 'git tag', 'git push', 'release-publish.py',
                                      'gh attestation', '--method', '-X '):
                        self.assertNotIn(forbidden, command)

    def test_uploads_only_the_notary_receipt_and_hash_summary(self):
        uploads = steps_using(self.jobs['rehearse'], 'actions/upload-artifact')
        self.assertEqual(sorted(step['with']['path'] for step in uploads), [
            '${{ runner.temp }}/steno-rehearsal-summary/rehearsal-summary.json',
            '${{ runner.temp }}/steno-release-distribution/release-notary-receipt.json',
        ])
        self.assertEqual(steps_using(self.jobs['plan'], 'actions/upload-artifact'), [])
        for step in uploads:
            self.assertNotRegex(step['with']['path'], r'\.dmg|\.app|steno-release-assets|\*')

    def test_signed_build_is_discarded_before_anything_is_uploaded(self):
        steps = self.jobs['rehearse']['steps']
        discard = next(index for index, step in enumerate(steps)
                       if 'rm -rf "$RUNNER_TEMP/steno-release-assets"' in step.get('run', ''))
        first_upload = min(index for index, step in enumerate(steps)
                           if str(step.get('uses', '')).startswith('actions/upload-artifact@'))
        self.assertLess(discard, first_upload)
        self.assertEqual(steps[discard]['if'], "always() && inputs.mode == 'full'")

    def test_own_concurrency_group_never_replaces_a_pending_release(self):
        release = POLICY.parse_workflow((ROOT / '.github/workflows/release.yml').read_text())
        self.assertNotEqual(self.workflow['concurrency']['group'], release['concurrency']['group'])
        self.assertEqual(self.workflow['concurrency']['cancel-in-progress'], 'false')

    def test_both_modes_check_release_facts_first_and_use_the_release_environment(self):
        self.assertIn('python3 scripts/ci/release-guard.py plan "$RELEASE_VERSION"',
                      [step.get('run') for step in self.jobs['plan']['steps']])
        rehearse = self.jobs['rehearse']
        self.assertEqual(rehearse['needs'], 'plan')
        self.assertNotIn('if', rehearse)
        self.assertEqual(rehearse['environment'], 'release')
        conditions = {step.get('run'): step.get('if') for step in rehearse['steps'] if 'run' in step}
        self.assertEqual(conditions['bash scripts/ci/release-rehearsal-signing.sh'], "inputs.mode == 'signing'")
        self.assertEqual(conditions['bash scripts/ci/release-sign.sh'], "inputs.mode == 'full'")

    def test_signing_rehearsal_repeats_the_release_keychain_and_probe_steps_exactly(self):
        release = (ROOT / 'scripts/ci/release-sign.sh').read_text().splitlines()
        rehearsal = (ROOT / 'scripts/ci/release-rehearsal-signing.sh').read_text().splitlines()
        start = release.index(next(line for line in release if line.startswith('PRIVATE_DIR="$(mktemp')))
        end = release.index("echo 'Signing preflight passed.'")
        # Only the release build's environment exports differ.
        expected = [line for line in release[start:end + 1]
                    if not re.match(r'export STENO_(NOTARY_|SIGNING_KEYCHAIN)', line)]
        position = 0
        for line in expected:
            try:
                position = rehearsal.index(line, position) + 1
            except ValueError:
                self.fail(f'signing rehearsal no longer repeats: {line}')
        self.assertFalse(any('release-dmg.sh' in line or 'notarytool submit' in line for line in rehearsal))


if __name__ == '__main__':
    unittest.main()
