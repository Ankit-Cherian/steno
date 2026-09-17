"""Exercise signing setup and teardown with disposable command doubles."""
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / 'scripts/ci/release-sign.sh'
IDENTITY = 'Developer ID Application: Release Test (TEST123456)'

COMMAND = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['COMMAND_LOG'], 'a') as log:
    log.write(json.dumps([name, *args]) + '\n')
if name == 'security':
    if args == ['list-keychains', '-d', 'user'] and os.environ.get('EMPTY_SEARCH_LIST') != '1':
        print('    "/tmp/runner login.keychain-db"\n    "/Library/Keychains/System.keychain"')
    if args[0] == 'find-identity':
        if os.environ.get('INVALID_IDENTITY') != '1':
            print('  1) ' + 'A' * 40 + ' "' + os.environ['STENO_DIST_SIGN_IDENTITY'] + '"')
    if args[0] == 'import' and os.environ.get('IMPORT_FAILURE') == '1':
        sys.exit(7)
elif name == 'xcrun':
    pathlib.Path(args[args.index('-o') + 1]).write_text('disposable probe')
elif name == 'codesign':
    if '--sign' in args and os.environ.get('SIGN_FAILURE') == '1':
        sys.exit(8)
    if '-dv' in args:
        print('TeamIdentifier=' + os.environ.get('PROBE_TEAM', 'TEST123456'), file=sys.stderr)
elif name == 'bash':
    if args[0].endswith('/scripts/release-dmg.sh'):
        sys.exit(42)  # Reaching packaging proves preflight completed; never build/sign an app here.
    sys.exit(99)
'''


class SigningSetupTests(unittest.TestCase):
    def exercise(self, **extra):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            commands = root / 'bin'
            commands.mkdir()
            for name in ['security', 'codesign', 'xcrun', 'bash']:
                path = commands / name
                path.write_text(COMMAND)
                path.chmod(0o755)
            log = root / 'commands.jsonl'
            env = dict(os.environ, PATH=str(commands) + ':' + os.environ['PATH'],
                       RUNNER_TEMP=str(root), COMMAND_LOG=str(log),
                       APPLE_CERTIFICATE_P12_BASE64=base64.b64encode(b'test-only').decode(),
                       APPLE_CERTIFICATE_PASSWORD='synthetic-test-value',
                       APPLE_SIGNING_IDENTITY=IDENTITY, APPLE_TEAM_ID='TEST123456',
                       APPLE_NOTARY_KEY_P8_BASE64=base64.b64encode(b'test-only').decode(),
                       APPLE_NOTARY_KEY_ID='synthetic', APPLE_NOTARY_ISSUER_ID='synthetic',
                       RELEASE_VERSION='1.0.0', RELEASE_SHA='a' * 40)
            env.pop('STENO_RELEASE_SOURCE_ROOT', None)
            env.update(extra)
            result = subprocess.run(['/bin/bash', str(SCRIPT)], env=env, capture_output=True, text=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            self.assertFalse(list(root.glob('steno-signing.*')), result.stderr)
            return result, calls

    def assert_restored(self, calls):
        mutations = [call for call in calls if call[:5] == ['security', 'list-keychains', '-d', 'user', '-s']]
        self.assertEqual(mutations[-1], ['security', 'list-keychains', '-d', 'user', '-s',
                                        '/tmp/runner login.keychain-db', '/Library/Keychains/System.keychain'])
        delete = next(i for i, call in enumerate(calls) if call[:2] == ['security', 'delete-keychain'])
        restore = max(i for i, call in enumerate(calls) if call == mutations[-1])
        self.assertLess(restore, delete)

    def test_valid_probe_precedes_packaging_and_restores_search_list(self):
        result, calls = self.exercise()
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assert_restored(calls)
        registration = next(call for call in calls if call[:5] == ['security', 'list-keychains', '-d', 'user', '-s'])
        self.assertTrue(registration[5].endswith('/release.keychain-db'))
        self.assertEqual(registration[6:], ['/tmp/runner login.keychain-db', '/Library/Keychains/System.keychain'])
        sign = next(i for i, call in enumerate(calls) if call[0] == 'codesign' and '--sign' in call)
        packaging = next(i for i, call in enumerate(calls) if call[0] == 'bash')
        self.assertLess(sign, packaging)
        for option in ['--options', 'runtime', '--timestamp', '--keychain']:
            self.assertIn(option, calls[sign])

    def test_empty_search_list_is_restored_without_unbound_array_error(self):
        result, calls = self.exercise(EMPTY_SEARCH_LIST='1')
        self.assertEqual(result.returncode, 42, result.stderr)
        mutations = [call for call in calls if call[:5] == ['security', 'list-keychains', '-d', 'user', '-s']]
        self.assertEqual(mutations[-1], ['security', 'list-keychains', '-d', 'user', '-s'])

    def test_import_failure_restores_without_building(self):
        result, calls = self.exercise(IMPORT_FAILURE='1')
        self.assertEqual(result.returncode, 7)
        self.assert_restored(calls)
        self.assertFalse(any(call[0] in ['codesign', 'bash'] for call in calls))

    def test_invalid_identity_does_not_build_or_sign(self):
        result, calls = self.exercise(INVALID_IDENTITY='1')
        self.assertNotEqual(result.returncode, 0)
        self.assert_restored(calls)
        self.assertFalse(any(call[0] in ['codesign', 'bash'] for call in calls))

    def test_failed_signing_probe_does_not_build(self):
        result, calls = self.exercise(SIGN_FAILURE='1')
        self.assertEqual(result.returncode, 8)
        self.assert_restored(calls)
        self.assertFalse(any(call[0] == 'bash' for call in calls))

    def test_wrong_signing_team_does_not_build(self):
        result, calls = self.exercise(PROBE_TEAM='WRONG12345')
        self.assertNotEqual(result.returncode, 0)
        self.assert_restored(calls)
        self.assertFalse(any(call[0] == 'bash' for call in calls))

    def test_recovery_rejects_source_outside_workspace_before_keychain_access(self):
        result, calls = self.exercise(STENO_RELEASE_SOURCE_ROOT=str(ROOT), GITHUB_WORKSPACE='/nonexistent/workspace')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])


if __name__ == '__main__':
    unittest.main()
