"""The local check command runs every step and reports stranded test helpers."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]


def executable(path, source):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(source)
    path.chmod(0o755)


class LocalCheckTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='local-check-test-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.repo = self.root / 'repo'
        (self.repo / 'scripts/ci').mkdir(parents=True)
        shutil.copyfile(ROOT / 'scripts/check.sh', self.repo / 'scripts/check.sh')
        shutil.copyfile(ROOT / 'scripts/ci/tools.sh', self.repo / 'scripts/ci/tools.sh')
        executable(self.repo / 'StenoTests/ExampleTests.swift', '')
        self.log = self.root / 'commands.log'
        version = next(line for line in (ROOT / 'scripts/ci/tools.sh').read_text().splitlines()
                       if 'XcodeGen/releases/download/' in line).split('/download/')[1].split('/')[0]
        executable(self.repo / 'build/ci-tools/xcodegen/xcodegen/bin/xcodegen', f'''#!/bin/sh
if [ "$1" = --version ]; then echo "Version: {version}"; exit 0; fi
echo "xcodegen $*" >> "{self.log}"
mkdir -p Steno.xcodeproj
printf '%s\\n' "${{STUB_PROJECT_CONTENT-/* ExampleTests.swift in Sources */}}" > Steno.xcodeproj/project.pbxproj
''')
        commands = self.root / 'commands'
        executable(commands / 'uname', '#!/bin/sh\necho Darwin\n')
        executable(commands / 'swift', f'''#!/bin/sh
echo "swift $*" >> "{self.log}"
if [ -n "$STUB_LEFTOVER" ] && [ "$1" = test ]; then
  nohup "$STUB_LEFTOVER" 60 >/dev/null 2>&1 &
  echo $! > "$STUB_LEFTOVER.pid"
fi
''')
        executable(commands / 'xcodebuild', f'''#!/bin/sh
echo "xcodebuild $1" >> "{self.log}"
if [ "$1" = test ]; then exit "${{STUB_TEST_STATUS:-0}}"; fi
''')
        self.environment = {**os.environ, 'PATH': f'{commands}{os.pathsep}{os.environ["PATH"]}'}
        for name in ('STUB_LEFTOVER', 'STUB_TEST_STATUS', 'STUB_PROJECT_CONTENT'):
            self.environment.pop(name, None)

    def fake_helper(self):
        # A sleeper inside a temporary steno-* directory, like a test's fake helper.
        directory = Path(tempfile.mkdtemp(prefix='steno-leftover-'))
        self.addCleanup(shutil.rmtree, directory, True)
        helper = directory / 'fake-runtime'
        executable(helper, '#!/usr/bin/env python3\nimport sys, time\ntime.sleep(float(sys.argv[1]))\n')
        def stop():
            pid_file = Path(str(helper) + '.pid')
            if pid_file.exists():
                try:
                    os.kill(int(pid_file.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass
        self.addCleanup(stop)
        return helper

    def run_check(self, *arguments, **environment):
        return subprocess.run(['bash', str(self.repo / 'scripts/check.sh'), *arguments], cwd=self.root,
                              env={**self.environment, **environment}, capture_output=True, text=True)

    def test_runs_every_step_in_order_and_passes_without_leftovers(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.log.read_text().splitlines(), [
            'xcodegen generate --quiet', 'swift test --package-path StenoKit', 'xcodebuild build', 'xcodebuild test'])
        self.assertIn('No test helper processes were left running.', result.stdout)
        self.assertTrue(result.stdout.rstrip().endswith('All local checks passed.'))

    def test_clean_option_discards_the_package_build_first(self):
        result = self.run_check('--clean')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.log.read_text().splitlines()[1:3], [
            'swift package --package-path StenoKit clean', 'swift test --package-path StenoKit'])

    def test_helper_left_running_fails_the_check(self):
        helper = self.fake_helper()
        result = self.run_check(STUB_LEFTOVER=str(helper))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('test helper processes were left running', result.stderr)
        self.assertIn(str(helper), result.stderr)
        self.assertNotIn('All local checks passed.', result.stdout)

    def test_failed_step_still_reports_leftovers_and_keeps_failing(self):
        helper = self.fake_helper()
        result = self.run_check(STUB_LEFTOVER=str(helper), STUB_TEST_STATUS='65')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(str(helper), result.stderr)

    def test_helper_running_before_the_check_is_not_blamed_on_it(self):
        helper = self.fake_helper()
        process = subprocess.Popen([str(helper), '60'])
        self.addCleanup(process.wait)
        self.addCleanup(process.kill)
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_hosted_test_source_missing_from_the_project_fails(self):
        result = self.run_check(STUB_PROJECT_CONTENT='/* OtherTests.swift in Sources */')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('StenoTests/ExampleTests.swift', result.stderr)
        self.assertNotIn('swift test', self.log.read_text())


if __name__ == '__main__':
    unittest.main()
