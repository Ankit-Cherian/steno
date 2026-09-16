import copy
import hashlib
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

FILE = Path(__file__).resolve().parents[1] / 'release-recovery.py'
spec = importlib.util.spec_from_file_location('release_recovery', FILE)
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.run = {'id': r.RUN, 'head_sha': r.SOURCE, 'head_branch': 'main',
                    'path': '.github/workflows/release.yml', 'event': 'workflow_dispatch',
                    'status': 'completed', 'conclusion': 'failure', 'run_attempt': 2,
                    'repository': {'full_name': r.REPOSITORY}}
        self.jobs = [{'name': name, 'id': number, 'run_id': r.RUN, 'head_sha': r.SOURCE,
                      'status': 'completed', 'conclusion': 'success'}
                     for name, number in r.SUCCESS_JOBS.items()]
        self.jobs += [{'name': name, 'id': number, 'run_id': r.RUN, 'head_sha': r.SOURCE,
                       'status': 'completed', 'conclusion': conclusion}
                      for name, (number, conclusion) in r.OTHER_JOBS.items()]
        self.logs = {
            104633948619: b'SecKeychainItemImport: MAC verification failed',
            104993063349: b'** BUILD SUCCEEDED **\n==> sign bundled runtime\n'
                         b'The specified item could not be found in the keychain.\n'
                         b'Process completed with exit code 1.',
        }
        self.hashes = {n: hashlib.sha256(value).hexdigest() for n, value in self.logs.items()}
        self.env = {'GITHUB_SHA': 'a' * 40, 'GITHUB_REPOSITORY': r.REPOSITORY,
                    'GITHUB_REF': 'refs/heads/main', 'GITHUB_EVENT_NAME': 'workflow_dispatch',
                    'GITHUB_WORKFLOW_REF': r.WORKFLOW + '@refs/heads/main',
                    'GITHUB_RUN_ATTEMPT': '1', 'RELEASE_SHA': r.SOURCE,
                    'RELEASE_VERSION': r.VERSION, 'RECOVERY_AUTHORIZED': 'true'}

    def test_capture_preserves_raw_logs_with_old_and_new_cli(self):
        raw = b'\x1b[36mreviewed log\x1b[0m\n'
        for help_text, flags in [('', []), ('--allow-escape-sequences', ['--allow-escape-sequences'])]:
            with self.subTest(help_text=help_text), patch.object(r, 'command', return_value=help_text), \
                    patch.object(r.subprocess, 'check_output', return_value=raw) as capture:
                logs = r.capture_signing_logs()
                self.assertEqual(logs, {number: raw for number in r.FAILED_SIGN_LOGS})
                self.assertEqual(capture.call_count, 2)
                for call, number in zip(capture.call_args_list, r.FAILED_SIGN_LOGS):
                    self.assertEqual(call.args, (['gh', 'api', *flags,
                        f'repos/{r.REPOSITORY}/actions/jobs/{number}/logs'],))
                    self.assertEqual(call.kwargs, {})

    def test_log_download_failure_is_not_suppressed(self):
        import subprocess
        with patch.object(r, 'command', return_value='--allow-escape-sequences'), \
                patch.object(r.subprocess, 'check_output', side_effect=subprocess.CalledProcessError(1, 'gh')):
            with self.assertRaises(subprocess.CalledProcessError):
                r.capture_signing_logs()

    def test_accept_exact_successful_checks_despite_later_signing_failure(self):
        with patch.object(r, 'FAILED_SIGN_LOGS', self.hashes):
            result = r.validate_prior_signing(self.run, self.jobs, self.logs, [])
        self.assertEqual(result['source_sha'], r.SOURCE)
        self.assertEqual(len(result['successful_jobs']), len(r.SUCCESS_JOBS))
        self.assertNotIn('sign', [j['name'] for j in result['successful_jobs']])

    def test_reject_changed_run_source_attempt_workflow_or_repository(self):
        for key, value in [('head_sha', 'b' * 40), ('run_attempt', 3),
                           ('path', '.github/workflows/ci.yml'), ('event', 'pull_request'),
                           ('status', 'in_progress'), ('repository', {'full_name': 'other/repo'})]:
            with self.subTest(key=key):
                changed = dict(self.run, **{key: value})
                with self.assertRaises(ValueError):
                    r.validate_run(changed)

    def test_missing_duplicate_skipped_failed_or_mismatched_jobs_fail(self):
        for field, value in [('id', 1), ('run_id', 1), ('head_sha', 'b' * 40),
                             ('status', 'queued'), ('conclusion', 'skipped'),
                             ('conclusion', 'failure')]:
            changed = copy.deepcopy(self.jobs)
            changed[0][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                r.validate_jobs(changed)
        for jobs in [self.jobs[:-1], self.jobs + [self.jobs[0]],
                     [self.jobs[0]] + self.jobs[:-1]]:
            with self.assertRaises(ValueError):
                r.validate_jobs(jobs)

    def test_log_digest_and_submission_stage_are_both_required(self):
        with patch.object(r, 'FAILED_SIGN_LOGS', self.hashes):
            with self.assertRaises(ValueError):
                r.validate_prior_signing(self.run, self.jobs, {}, [])
            changed = dict(self.logs)
            changed[104993063349] += b' changed'
            with self.assertRaises(ValueError):
                r.validate_prior_signing(self.run, self.jobs, changed, [])
        for suffix in [b'\n==> notarize DMG', b'']:
            changed = dict(self.logs)
            changed[104993063349] = b'failure' + suffix
            hashes = {n: hashlib.sha256(v).hexdigest() for n, v in changed.items()}
            with patch.object(r, 'FAILED_SIGN_LOGS', hashes), self.assertRaises(ValueError):
                r.validate_prior_signing(self.run, self.jobs, changed, [])

    def test_existing_notary_or_signed_artifact_blocks_retry(self):
        for name in ['notary-recovery-35041760947-2', 'signed-release-any-source']:
            with patch.object(r, 'FAILED_SIGN_LOGS', self.hashes), self.assertRaises(ValueError):
                r.validate_prior_signing(self.run, self.jobs, self.logs, [{'name': name}])

    def test_dispatch_separates_control_source_and_requires_authorization(self):
        self.assertEqual(r.validate_dispatch(self.env), 'a' * 40)
        for key, value in [('GITHUB_REF', 'refs/tags/v1.0.0'), ('RELEASE_SHA', 'b' * 40),
                           ('GITHUB_WORKFLOW_REF', r.WORKFLOW + '@refs/heads/other'),
                           ('RECOVERY_AUTHORIZED', 'false'), ('GITHUB_RUN_ATTEMPT', '2')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                r.validate_dispatch(dict(self.env, **{key: value}))

    def test_prior_recovery_that_started_signing_blocks_new_dispatch(self):
        runs = [{'id': 1}, {'id': 2}]
        r.require_no_prior_recovery(runs, lambda _: [], 2)
        r.require_no_prior_recovery(runs, lambda _: [
            {'name': 'sign', 'started_at': 'date', 'conclusion': 'skipped'}], 2)
        with self.assertRaises(ValueError):
            r.require_no_prior_recovery(runs, lambda _: [
                {'name': 'sign', 'started_at': 'date', 'conclusion': 'failure'}], 2)

    def test_existing_draft_or_release_blocks_creation(self):
        r.require_no_release([{'tag_name': 'v0.2.0'}])
        for draft in [True, False]:
            with self.assertRaises(ValueError):
                r.require_no_release([{'tag_name': 'v1.0.0', 'draft': draft}])

    def test_manifest_binds_workflow_source_and_exact_reused_receipt(self):
        receipt = r.validate_jobs(self.jobs)
        manifest = {'workflow_source_sha': 'a' * 40, 'producing_workflow': r.WORKFLOW,
                    'validation_run': r.RUN, 'validation_attempt': 1,
                    'validation_receipt': receipt,
                    'workflow_run': f'https://github.com/{r.REPOSITORY}/actions/runs/123'}
        r.validate_manifest(manifest, 'a' * 40, receipt, '123')
        for key in manifest:
            changed = copy.deepcopy(manifest)
            changed[key] = 'wrong'
            with self.subTest(key=key), self.assertRaises(ValueError):
                r.validate_manifest(changed, 'a' * 40, receipt, '123')

    def test_attested_assets_still_use_existing_exact_three_file_guard(self):
        publisher = r.module('release-publish')
        import tempfile
        import json
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            name = 'Steno-1.0.0.dmg'
            (root / name).write_bytes(b'test artifact')
            digest = hashlib.sha256(b'test artifact').hexdigest()
            (root / 'SHA256SUMS').write_text(f'{digest}  {name}\n')
            (root / 'release-manifest.json').write_text(json.dumps({
                'version': r.VERSION, 'source_sha': r.SOURCE, 'tag': 'v1.0.0',
                'asset': name, 'sha256': digest, 'notarized': True,
                'architecture': 'arm64', 'minimum_macos': '13.0'}))
            self.assertEqual(len(publisher.validate_assets(root, r.VERSION, r.SOURCE)), 3)
            (root / name).write_bytes(b'changed artifact')
            with self.assertRaises(ValueError):
                publisher.validate_assets(root, r.VERSION, r.SOURCE)

    def test_checkout_name_respects_existing_distribution_hygiene(self):
        # The unchanged packager forbids non-product checkout leaf names anywhere
        # in bundle strings. A generic "source" checkout would reject valid text.
        import subprocess
        import tempfile
        policy = r.module('check-policy')
        workflow = policy.parse_workflow((r.CONTROL / '.github/workflows/recover-release.yml').read_text())
        packaging = (r.CONTROL / 'scripts/release-dmg.sh').read_text()
        scan = packaging[packaging.index('scan_distribution_hygiene() {'):packaging.index('\ncreate_dmg() {')]
        for job in workflow['jobs'].values():
            checkout = next(step for step in job['steps'] if step.get('with', {}).get('ref') == r.SOURCE)
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                app = root / 'app/Contents'
                app.mkdir(parents=True)
                (app / 'fixture.txt').write_text('Open-source speech recognition')
                result = subprocess.run(['bash', '-c', scan + '\nscan_distribution_hygiene "$1"',
                                         'test', str(app.parent)], capture_output=True, text=True,
                    env=dict(r.os.environ, REPO_ROOT='/workflow/' + checkout['with']['path'], APP_NAME='Steno'))
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_notes_are_complete_and_include_acceptance_limits(self):
        notes = r.release_notes()
        self.assertIn('manual acceptance matrix', notes)
        self.assertNotIn('{{', notes)
        self.assertNotIn('<!--', notes)


if __name__ == '__main__':
    unittest.main()
