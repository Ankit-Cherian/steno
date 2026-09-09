"""Negative release guards run without Apple credentials or GitHub writes."""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), ROOT / 'scripts' / 'ci' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


guard = load('release-guard')
publish = load('release-publish')
SHA = 'a' * 40


class ReleaseIdentityTests(unittest.TestCase):
    def test_exact_main_source_requires_manual_acceptance(self):
        guard.validate_identity('1.0.0', SHA, SHA, 'refs/heads/main', 'true')
        for args in [
            ('1.0.0', SHA, SHA, 'refs/heads/feature', 'true'),
            ('1.0.0', SHA, 'b' * 40, 'refs/heads/main', 'true'),
            ('1.0.0', SHA, SHA, 'refs/heads/main', 'false'),
            ('1.0.0', SHA, SHA, 'refs/heads/main', ''),
        ]:
            with self.subTest(args=args), self.assertRaises(ValueError):
                guard.validate_identity(*args)

    def test_versions_and_references_cannot_be_shell_or_git_expressions(self):
        for version in ['v1.0.0', '1.0', '01.0.0', '1.0.0-beta', '1.0.0; touch bad', '../1.0.0']:
            with self.subTest(version=version), self.assertRaises(ValueError):
                guard.validate_identity(version, SHA, SHA, 'refs/heads/main', 'true')
        for sha in ['main', 'a' * 7, 'A' * 40, SHA + '^', '--help', SHA + '\n']:
            with self.subTest(sha=sha), self.assertRaises(ValueError):
                guard.validate_identity('1.0.0', sha, sha, 'refs/heads/main', 'true')

    def test_source_rejects_moved_tag_wrong_checkout_and_wrong_metadata(self):
        with tempfile.TemporaryDirectory() as temp:
            repo = Path(temp)
            (repo / 'project.yml').write_text('  MARKETING_VERSION: 1.0.0\n')
            with mock.patch.object(guard, 'run', side_effect=[SHA, SHA]), mock.patch.object(guard.subprocess, 'run'):
                guard.validate_source(repo, '1.0.0', SHA)
            for results in [[SHA, 'b' * 40], ['b' * 40]]:
                with mock.patch.object(guard, 'run', side_effect=results), self.assertRaises(ValueError):
                    guard.validate_source(repo, '1.0.0', SHA)
            with mock.patch.object(guard, 'run', side_effect=[SHA, SHA]), mock.patch.object(guard.subprocess, 'run'), self.assertRaises(ValueError):
                guard.validate_source(repo, '2.0.0', SHA)
            with mock.patch.object(guard, 'run', side_effect=[SHA, SHA]), mock.patch.object(guard.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'git')), self.assertRaises(subprocess.CalledProcessError):
                guard.validate_source(repo, '1.0.0', SHA)

    def test_remote_tag_and_main_ancestry_are_rechecked(self):
        for status in ['identical', 'behind']:
            with mock.patch.object(guard, 'run', side_effect=[json.dumps({'sha': SHA}), json.dumps({'status': status})]):
                guard.validate_remote('owner/repo', '1.0.0', SHA)
        for responses in [[{'sha': 'b' * 40}], [{'sha': SHA}, {'status': 'ahead'}], [{'sha': SHA}, {'status': 'diverged'}]]:
            with mock.patch.object(guard, 'run', side_effect=[json.dumps(r) for r in responses]), self.assertRaises(ValueError):
                guard.validate_remote('owner/repo', '1.0.0', SHA)


class ReleaseOutputTests(unittest.TestCase):
    def test_existing_outputs_and_protected_roots_are_never_overwritten(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            repo = root / 'repo'
            repo.mkdir()
            candidate = repo / 'build' / 'Steno.app'
            candidate.mkdir(parents=True)
            sentinel = candidate / 'preserve'
            sentinel.write_text('original app')
            for output in ['/', str(root), str(repo), str(candidate), str(candidate / 'new'), 'relative/output']:
                with self.subTest(output=output), self.assertRaises(ValueError):
                    guard.validate_output(output, repo, root / 'home')
            self.assertEqual(sentinel.read_text(), 'original app')
            self.assertEqual(guard.validate_output(str(root / 'fresh-output'), repo, root / 'home'), str((root / 'fresh-output').resolve()))

    def test_symlink_cannot_bypass_candidate_protection(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            candidate = root / 'repo/build/Steno.app'
            candidate.mkdir(parents=True)
            alias = root / 'alias'
            alias.symlink_to(candidate, target_is_directory=True)
            with self.assertRaises(ValueError):
                guard.validate_output(str(alias / 'new'), root / 'repo', root / 'home')

    def test_preview_omits_hardened_library_validation_but_production_preserves_it(self):
        source = (ROOT / 'scripts/release-dmg.sh').read_text()
        function = source[source.index('sign_code() {'):source.index('\nsign_nested_code() {')]
        stub = "codesign() { printf '%s\\n' \"$@\"; }\n"
        for preview in [0, 1]:
            args = subprocess.check_output(['bash', '-c', stub + function +
                f'\nUNSIGNED_PREVIEW={preview}\nSIGNING_ARGS=(--timestamp=none)\nsign_code test.app test-identity\n'], text=True).splitlines()
            with self.subTest(preview=preview):
                self.assertEqual('--options' in args, preview == 0)
                self.assertEqual('runtime' in args, preview == 0)
                self.assertIn('test.app', args)
                self.assertIn('--timestamp=none', args)

    def test_packaging_preflight_preserves_existing_output_and_rejects_wrong_identity(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            sentinel = root / 'preserve'
            sentinel.write_text('unchanged')
            env = dict(guard.os.environ, STENO_DIST_DIR=temp)
            result = subprocess.run(['bash', str(ROOT / 'scripts/release-dmg.sh'), '--unsigned-preview'],
                                    env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('must not already exist', result.stderr)
            self.assertEqual(sentinel.read_text(), 'unchanged')
            output = root / 'fresh-output'
            env.update(STENO_DIST_DIR=str(output), STENO_DIST_SIGN_IDENTITY='Apple Development: test')
            result = subprocess.run(['bash', str(ROOT / 'scripts/release-dmg.sh'), '--skip-notarize'],
                                    env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Developer ID Application', result.stderr)
            self.assertFalse(output.exists())


class ReleaseAssetTests(unittest.TestCase):
    def write_assets(self, root):
        filename = 'Steno-1.0.0.dmg'
        (root / filename).write_bytes(b'final stapled test artifact')
        digest = hashlib.sha256((root / filename).read_bytes()).hexdigest()
        (root / 'SHA256SUMS').write_text(f'{digest}  {filename}\n')
        manifest = {'version': '1.0.0', 'source_sha': SHA, 'tag': 'v1.0.0', 'asset': filename,
                    'sha256': digest, 'notarized': True, 'architecture': 'arm64', 'minimum_macos': '13.0'}
        (root / 'release-manifest.json').write_text(json.dumps(manifest))

    def test_only_matching_final_assets_can_be_published(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.write_assets(root)
            self.assertEqual(len(publish.validate_assets(root, '1.0.0', SHA)), 3)
            with self.assertRaises(ValueError):
                publish.validate_assets(root, '1.0.0', 'b' * 40)
            (root / 'Steno-1.0.0.dmg').write_bytes(b'modified after attestation')
            with self.assertRaises(ValueError):
                publish.validate_assets(root, '1.0.0', SHA)

    def test_private_receipts_and_links_cannot_enter_public_assets(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.write_assets(root)
            extra = root / 'notary-log.json'
            extra.write_text('{}')
            with self.assertRaises(ValueError):
                publish.validate_assets(root, '1.0.0', SHA)
            extra.unlink()
            sums = root / 'SHA256SUMS'
            sums.unlink()
            sums.symlink_to(root / 'release-manifest.json')
            with self.assertRaises(ValueError):
                publish.validate_assets(root, '1.0.0', SHA)

    def test_final_publication_requires_exact_draft_and_uploaded_remote_digests(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.write_assets(root)
            assets = publish.validate_assets(root, '1.0.0', SHA)
            receipt = {'id': 42, 'draft': True, 'target_commitish': SHA, 'assets': [
                {'name': Path(p).name, 'state': 'uploaded',
                 'digest': 'sha256:' + hashlib.sha256(Path(p).read_bytes()).hexdigest()} for p in assets]}
            publish.verify_remote_assets(receipt, assets, SHA, '42')
            for change in [{'id': 43}, {'draft': False}, {'target_commitish': 'b' * 40}, {'assets': []}]:
                with self.subTest(change=change), self.assertRaises(ValueError):
                    publish.verify_remote_assets(dict(receipt, **change), assets, SHA, '42')
            receipt['assets'][0]['digest'] = None
            with self.assertRaises(ValueError):
                publish.verify_remote_assets(receipt, assets, SHA, '42')

    def download_fixture(self, root):
        source = root / 'source'
        source.mkdir()
        self.write_assets(source)
        payloads = {index: path.read_bytes() for index, path in enumerate(sorted(source.iterdir()), 1)}
        receipt = {'id': 42, 'draft': True, 'target_commitish': SHA, 'tag_name': 'v1.0.0',
                   'assets': [{'id': index, 'name': path.name, 'state': 'uploaded',
                               'size': path.stat().st_size,
                               'digest': 'sha256:' + hashlib.sha256(path.read_bytes()).hexdigest()}
                              for index, path in enumerate(sorted(source.iterdir()), 1)]}
        return receipt, payloads

    def test_existing_draft_download_uses_only_numeric_asset_ids(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            receipt, payloads = self.download_fixture(root)
            def download(command, *, stdout, check):
                self.assertEqual(command[:2], ['gh', 'api'])
                self.assertTrue(command[2].startswith('repos/owner/repo/releases/assets/'))
                stdout.write(payloads[int(command[2].rsplit('/', 1)[1])])
            with mock.patch.object(publish, 'release_receipt', return_value=receipt), mock.patch.object(publish.subprocess, 'run', side_effect=download) as call:
                publish.download_existing('owner/repo', '1.0.0', SHA, '42', root / 'download')
                self.assertEqual(call.call_count, 3)
            self.assertEqual(len(publish.validate_assets(root / 'download', '1.0.0', SHA)), 3)

    def test_existing_draft_download_rejects_wrong_id_or_unsafe_asset_before_writes(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            receipt, _ = self.download_fixture(root)
            cases = [dict(receipt, id=43), dict(receipt, draft=False)]
            evil = json.loads(json.dumps(receipt))
            evil['assets'][0]['name'] = '../../outside.dmg'
            cases.append(evil)
            missing_digest = json.loads(json.dumps(receipt))
            missing_digest['assets'][0]['digest'] = None
            cases.append(missing_digest)
            for case in cases:
                with self.subTest(case=case), mock.patch.object(publish, 'release_receipt', return_value=case), mock.patch.object(publish.subprocess, 'run') as call:
                    with self.assertRaises(ValueError):
                        publish.download_existing('owner/repo', '1.0.0', SHA, '42', root / 'download')
                    call.assert_not_called()
                    self.assertFalse((root / 'download').exists())
            for version, release_id in [('1.0.0', '../42'), ('../../evil', '42')]:
                with self.assertRaises(ValueError):
                    publish.download_existing('owner/repo', version, SHA, release_id, root / 'download')

    def test_existing_draft_download_rejects_remote_digest_mismatch(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp).resolve()
            receipt, payloads = self.download_fixture(root)
            receipt['assets'][0]['digest'] = 'sha256:' + '0' * 64
            def download(command, *, stdout, check):
                stdout.write(payloads[int(command[2].rsplit('/', 1)[1])])
            with mock.patch.object(publish, 'release_receipt', return_value=receipt), mock.patch.object(publish.subprocess, 'run', side_effect=download):
                with self.assertRaisesRegex(ValueError, 'checksum'):
                    publish.download_existing('owner/repo', '1.0.0', SHA, '42', root / 'download')

    def test_existing_draft_and_failed_listing_never_trigger_create(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.write_assets(root)
            env = {'RELEASE_VERSION': '1.0.0', 'RELEASE_SHA': SHA,
                   'RELEASE_ASSETS': temp, 'GITHUB_REPOSITORY': 'owner/repo'}
            with mock.patch.dict(publish.os.environ, env), mock.patch.object(publish.subprocess, 'check_output', return_value='[[{"tag_name":"v1.0.0","draft":true}]]'), mock.patch.object(publish.subprocess, 'run') as create:
                with self.assertRaises(ValueError):
                    publish.main()
                create.assert_not_called()
            with mock.patch.dict(publish.os.environ, env), mock.patch.object(publish.subprocess, 'check_output', side_effect=subprocess.CalledProcessError(1, 'gh')), mock.patch.object(publish.subprocess, 'run') as create:
                with self.assertRaises(subprocess.CalledProcessError):
                    publish.main()
                create.assert_not_called()


if __name__ == '__main__':
    unittest.main()
