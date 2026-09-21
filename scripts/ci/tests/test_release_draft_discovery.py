"""Draft creation receipts are verified without publishing or contacting GitHub."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


def load(name):
    path = Path(__file__).resolve().parents[1] / (name + '.py')
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


publisher = load('release-publish')
recovery = load('release-recovery')
REPOSITORY = recovery.REPOSITORY
VERSION = recovery.VERSION
SHA = recovery.SOURCE


class DraftDiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.assets_root = self.root / 'assets'
        self.assets_root.mkdir()
        filename = 'Steno-1.0.0.dmg'
        (self.assets_root / filename).write_bytes(b'test installer')
        digest = hashlib.sha256(b'test installer').hexdigest()
        (self.assets_root / 'SHA256SUMS').write_text(f'{digest}  {filename}\n')
        (self.assets_root / 'release-manifest.json').write_text(json.dumps({
            'version': VERSION, 'source_sha': SHA, 'tag': 'v' + VERSION,
            'asset': filename, 'sha256': digest, 'notarized': True,
            'architecture': 'arm64', 'minimum_macos': '13.0'}))
        self.assets = publisher.validate_assets(self.assets_root, VERSION, SHA)
        self.receipt = {
            'id': 42, 'draft': True, 'prerelease': False,
            'tag_name': 'v' + VERSION, 'target_commitish': SHA,
            'html_url': 'https://github.com/owner/repo/releases/tag/v1.0.0',
            'body': 'Reviewed notes',
            'assets': [{'name': Path(path).name, 'state': 'uploaded',
                        'digest': 'sha256:' + hashlib.sha256(Path(path).read_bytes()).hexdigest()}
                       for path in self.assets],
        }
        self.output = self.root / 'output'
        self.env = {'GITHUB_REPOSITORY': REPOSITORY, 'RELEASE_VERSION': VERSION,
                    'RELEASE_SHA': SHA, 'RELEASE_ASSETS': str(self.assets_root),
                    'GITHUB_OUTPUT': str(self.output), 'RUNNER_TEMP': str(self.root)}

    def discover(self):
        return publisher.created_draft_receipt(REPOSITORY, VERSION, SHA, self.assets)

    def run_create(self, recovery_path):
        if recovery_path:
            with mock.patch.object(recovery, 'verify_assets', return_value=(publisher, self.assets)), \
                    mock.patch.object(recovery, 'release_notes', return_value='Reviewed notes'):
                recovery.draft()
        else:
            with mock.patch.object(publisher.sys, 'argv', ['release-publish.py']):
                publisher.main()

    def test_later_page_draft_is_refetched_by_numeric_id(self):
        pages = [[{'tag_name': 'v0.2.0'}], [self.receipt]]
        with mock.patch.object(publisher.subprocess, 'check_output',
                               side_effect=[json.dumps(pages), json.dumps(self.receipt)]) as read:
            self.assertEqual(self.discover(), self.receipt)
        self.assertEqual(read.call_args_list[0].args[0], ['gh', 'api', '--paginate', '--slurp',
                         f'repos/{REPOSITORY}/releases?per_page=100'])
        self.assertEqual(read.call_args_list[1].args[0],
                         ['gh', 'api', f'repos/{REPOSITORY}/releases/42'])

    def test_absent_duplicate_and_published_matches_are_rejected(self):
        cases = [[[]], [[self.receipt], [self.receipt]],
                 [[dict(self.receipt, draft=False)]]]
        for pages in cases:
            with self.subTest(pages=pages), mock.patch.object(publisher.subprocess, 'check_output',
                    return_value=json.dumps(pages)) as read, self.assertRaises(ValueError):
                self.discover()
            self.assertEqual(read.call_count, 1)

    def test_invalid_ids_never_become_api_paths(self):
        for value in [True, False, 0, -1, '42', '../latest', 10**20]:
            with self.subTest(value=value), mock.patch.object(publisher.subprocess, 'check_output',
                    return_value=json.dumps([[dict(self.receipt, id=value)]])) as read, \
                    self.assertRaises(ValueError):
                self.discover()
            self.assertEqual(read.call_count, 1)

    def test_source_upload_and_digest_must_match_before_and_after_discovery(self):
        bad_digest = copy.deepcopy(self.receipt['assets'])
        bad_digest[0]['digest'] = 'sha256:' + '0' * 64
        uploading = copy.deepcopy(self.receipt['assets'])
        uploading[0]['state'] = 'new'
        for changes in [{'target_commitish': 'b' * 40}, {'prerelease': True},
                        {'draft': False}, {'assets': []},
                        {'assets': bad_digest}, {'assets': uploading}]:
            for stage in ['list', 'refetch']:
                changed = dict(self.receipt, **changes)
                listed = changed if stage == 'list' else self.receipt
                fetched = changed if stage == 'refetch' else self.receipt
                with self.subTest(changes=changes, stage=stage), \
                        mock.patch.object(publisher.subprocess, 'check_output',
                            side_effect=[json.dumps([[listed]]), json.dumps(fetched)]), \
                        self.assertRaises(ValueError):
                    self.discover()

    def test_refetch_rejects_changed_id_or_tag(self):
        for changes in [{'id': 43}, {'tag_name': 'v2.0.0'}]:
            with self.subTest(changes=changes), \
                    mock.patch.object(publisher.subprocess, 'check_output', side_effect=[
                        json.dumps([[self.receipt]]), json.dumps(dict(self.receipt, **changes))]), \
                    self.assertRaises(ValueError):
                self.discover()

    def test_both_creation_paths_retain_exact_verified_id(self):
        for recovery_path in [False, True]:
            self.output.write_text('')
            with self.subTest(recovery_path=recovery_path), mock.patch.dict(publisher.os.environ, self.env), \
                    mock.patch.object(publisher.subprocess, 'run') as create, \
                    mock.patch.object(publisher.subprocess, 'check_output', side_effect=[
                        '[[]]', json.dumps([[self.receipt]]), json.dumps(self.receipt)]) as read:
                self.run_create(recovery_path)
            create.assert_called_once()
            self.assertEqual(create.call_args.args[0][:3], ['gh', 'release', 'create'])
            self.assertIn('--verify-tag', create.call_args.args[0])
            self.assertIn('--draft', create.call_args.args[0])
            self.assertEqual(self.output.read_text(), 'release_id=42\n')
            self.assertFalse(any('/releases/tags/' in str(call) for call in read.call_args_list))

    def test_both_paths_stop_without_retry_on_ambiguous_create_or_read_failure(self):
        for recovery_path in [False, True]:
            for stage in ['create', 'listing', 'refetch', 'ambiguous']:
                self.output.write_text('')
                failure = subprocess.CalledProcessError(1, 'gh')
                responses = ['[[]]']
                if stage == 'listing':
                    responses += [failure]
                elif stage == 'refetch':
                    responses += [json.dumps([[self.receipt]]), failure]
                elif stage == 'ambiguous':
                    responses += [json.dumps([[self.receipt, self.receipt]])]
                with self.subTest(recovery_path=recovery_path, stage=stage), \
                        mock.patch.dict(publisher.os.environ, self.env), \
                        mock.patch.object(publisher.subprocess, 'run',
                            side_effect=failure if stage == 'create' else None) as create, \
                        mock.patch.object(publisher.subprocess, 'check_output', side_effect=responses), \
                        self.assertRaises((ValueError, subprocess.CalledProcessError)):
                    self.run_create(recovery_path)
                create.assert_called_once()
                self.assertEqual(self.output.read_text(), '')

    def test_recovery_requires_reviewed_notes_before_exporting_id(self):
        with mock.patch.dict(publisher.os.environ, self.env), \
                mock.patch.object(publisher.subprocess, 'run'), \
                mock.patch.object(publisher.subprocess, 'check_output', side_effect=[
                    '[[]]', json.dumps([[self.receipt]]),
                    json.dumps(dict(self.receipt, body='Unexpected notes'))]), \
                self.assertRaises(ValueError):
            self.run_create(True)
        self.assertFalse(self.output.exists())


if __name__ == '__main__':
    unittest.main()
