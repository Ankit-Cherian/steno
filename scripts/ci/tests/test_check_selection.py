"""Ensure change classification cannot accidentally waive required checks."""
import importlib.util
import io
import itertools
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]

def load(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'scripts/ci' / file)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

SELECT = load('select_checks', 'select-checks.py')
POLICY = load('selection_policy', 'check-policy.py')

FULL = {'scope': 'full', 'runtime_required': 'true', 'swift_scan_required': 'true', 'cpp_scan_required': 'true'}
DOCS = {'scope': 'docs', 'runtime_required': 'false', 'swift_scan_required': 'false', 'cpp_scan_required': 'false'}
TESTS = {'scope': 'full', 'runtime_required': 'false', 'swift_scan_required': 'false', 'cpp_scan_required': 'false'}
RUNTIME = {'scope': 'full', 'runtime_required': 'true', 'swift_scan_required': 'false', 'cpp_scan_required': 'false'}
NATIVE = {'scope': 'full', 'runtime_required': 'true', 'swift_scan_required': 'false', 'cpp_scan_required': 'true'}


def pull_request(before, after, ref='main'):
    return {'pull_request': {'base': {'sha': before, 'ref': ref}, 'head': {'sha': after}}}


class Repository:
    """A scratch Git repository; the classifier runs with it as the working directory."""

    def __init__(self, directory):
        self.root = Path(directory)
        self.git('init', '-q')
        self.git('config', 'user.name', 'Test')
        self.git('config', 'user.email', 'test@example.invalid')

    def git(self, *args, input=None):
        return subprocess.check_output(['git', '-C', str(self.root), *args], input=input).decode().strip()

    def write(self, path, text='content\n'):
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)

    def commit(self, message='change'):
        self.git('add', '-A')
        self.git('commit', '-qm', message, '--allow-empty')
        return self.git('rev-parse', 'HEAD')

    def add_index_entry(self, mode, path, content=b'content\n'):
        # Builds entries the case-insensitive scratch volume cannot hold.
        if mode == '160000':
            sha = '1' * 40
        else:
            sha = self.git('hash-object', '-w', '--stdin', input=content)
        self.git('update-index', '-z', '--add', '--index-info', input=f'{mode} {sha}\t{path}\0'.encode())

    def commit_index(self, message='index change'):
        self.git('commit', '-qm', message)
        return self.git('rev-parse', 'HEAD')


class ScratchRepositoryTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.repo = Repository(temporary.name)
        original = Path.cwd()
        os.chdir(self.repo.root)
        self.addCleanup(os.chdir, original)
        for path in ('README.md', 'Steno/ContentView.swift', 'StenoTests/ViewTests.swift',
                     'StenoKit/Sources/StenoKit/Services/LocalCleanupRanker.swift',
                     'StenoKit/Sources/StenoKit/Services/SessionCoordinator.swift',
                     'runtime-helper/steno_prompt_scoring.h', 'scripts/ci/select-checks.py',
                     'scripts/ci/reviewed-findings.json', 'program.py'):
            self.repo.write(path)
        self.base = self.repo.commit('baseline')

    def select(self, head, workflow='CI', base=None, ref='main'):
        return SELECT.select('pull_request', pull_request(base or self.base, head, ref), workflow)


class SelectionTests(ScratchRepositoryTest):
    def test_only_documentation_paths_are_allowed(self):
        for path in ('README.md', 'docs/release/1.0-checklist.md', 'docs/images/app.png'):
            self.assertTrue(SELECT.documentation_path(path))
        for path in ('Steno/View.swift', '.github/workflows/ci.yml', 'scripts/ci/tool.py', 'docs/test.sh', 'docs/../scripts/test.md', 'new-file.md', 'docs/conf.py'):
            self.assertFalse(SELECT.documentation_path(path))

    def test_real_git_diff_and_rename(self):
        self.repo.write('README.md', 'after\n')
        head = self.repo.commit('docs')
        for workflow in ('CI', 'Security'):
            self.assertEqual(self.select(head, workflow), DOCS)
        self.assertEqual(self.select(head, base=head), FULL)
        self.repo.git('mv', 'program.py', 'CONTRIBUTING.md')
        renamed = self.repo.commit('rename executable')
        # The unrecognized source side of the rename is still classified.
        self.assertEqual(self.select(renamed, base=head), FULL)
        (self.repo.root / 'README.md').unlink()
        (self.repo.root / 'README.md').symlink_to('CONTRIBUTING.md')
        linked = self.repo.commit('symlink')
        self.assertEqual(self.select(linked, base=renamed), FULL)
        (self.repo.root / 'CONTRIBUTING.md').unlink()
        self.assertEqual(self.select(self.repo.commit('delete documentation'), base=linked), DOCS)

    def test_each_kind_of_change_selects_its_jobs(self):
        cases = {
            'Steno/ContentView.swift': TESTS,
            'StenoTests/ViewTests.swift': TESTS,
            'StenoKit/Sources/StenoKit/Services/SessionCoordinator.swift': TESTS,
            'scripts/ci/reviewed-findings.json': TESTS,
            'StenoKit/Sources/StenoKit/Services/LocalCleanupRanker.swift': RUNTIME,
            'runtime-helper/steno_prompt_scoring.h': NATIVE,
            'scripts/ci/select-checks.py': FULL,
            'unrecognized/file.txt': FULL,
        }
        for path, expected in cases.items():
            with self.subTest(path=path):
                self.repo.git('checkout', '-q', '--detach', self.base)
                self.repo.write(path, 'edited\n')
                self.assertEqual(self.select(self.repo.commit(path)), expected)

    def test_mixed_changes_select_the_union(self):
        def change(*paths):
            self.repo.git('checkout', '-q', '--detach', self.base)
            for path in paths:
                self.repo.write(path, 'edited\n')
            return self.select(self.repo.commit())
        self.assertEqual(change('README.md', 'Steno/ContentView.swift'), TESTS)
        self.assertEqual(change('Steno/ContentView.swift', 'StenoKit/Sources/StenoKit/Services/LocalCleanupRanker.swift'), RUNTIME)
        self.assertEqual(change('StenoKit/Sources/StenoKit/Services/LocalCleanupRanker.swift', 'runtime-helper/steno_prompt_scoring.h'), NATIVE)
        self.assertEqual(change('Steno/ContentView.swift', 'scripts/ci/select-checks.py'), FULL)

    def test_deleting_or_renaming_into_a_runtime_path_selects_runtime(self):
        (self.repo.root / 'StenoKit/Sources/StenoKit/Services/LocalCleanupRanker.swift').unlink()
        self.assertEqual(self.select(self.repo.commit('delete')), RUNTIME)
        self.repo.git('checkout', '-q', '--detach', self.base)
        self.repo.git('mv', 'StenoTests/ViewTests.swift', 'StenoKit/Sources/StenoKit/Services/CommonEnglishWords.swift')
        self.assertEqual(self.select(self.repo.commit('rename')), RUNTIME)

    def test_symlink_or_submodule_anywhere_selects_full(self):
        for mode, path in (('120000', 'Steno/Link.swift'), ('160000', 'StenoTests/Vendor')):
            with self.subTest(mode=mode):
                self.repo.git('checkout', '-q', '--detach', self.base)
                self.repo.write('Steno/ContentView.swift', 'edited\n')
                self.repo.git('add', '-A')
                self.repo.add_index_entry(mode, path, b'../StenoKit/Sources/StenoKit/Services/LocalCleanupRanker.swift')
                self.assertEqual(self.select(self.repo.commit_index()), FULL)

    def test_case_or_unicode_collision_in_the_checkout_selects_full(self):
        composed, decomposed = 'StenoTests/Caf\u00e9.swift', 'StenoTests/Cafe\u0301.swift'
        for paths, expected in (([composed], TESTS), (['StenoTests/viewtests.swift'], FULL), ([composed, decomposed], FULL)):
            with self.subTest(paths=paths):
                self.repo.git('checkout', '-q', '--detach', self.base)
                for path in paths:
                    self.repo.add_index_entry('100644', path)
                self.assertEqual(self.select(self.repo.commit_index()), expected)

    def test_variants_of_costly_paths_never_select_less(self):
        self.assertEqual(SELECT.tier('stenokit/sources/stenokit/services/localcleanupranker.swift'), 'runtime')
        self.assertEqual(SELECT.tier('SCRIPTS/CI/select-checks.py'), 'infrastructure')
        self.assertEqual(SELECT.tier('scripts/ci/Reviewed-Findings.json'), 'infrastructure')
        self.assertEqual(SELECT.tier('Runtime-Helper/steno_prompt_scoring.h'), 'native')
        self.assertEqual(SELECT.tier('steno/ContentView.swift'), 'unknown')
        self.assertEqual(SELECT.fold('Caf\u00e9'), SELECT.fold('CAFE\u0301'))

    def test_pull_request_against_another_branch_selects_full(self):
        self.repo.write('README.md', 'after\n')
        head = self.repo.commit('docs')
        self.assertEqual(self.select(head), DOCS)
        for ref in ('release/1.1', 'Main', '', None):
            with self.subTest(ref=ref):
                self.assertEqual(self.select(head, ref=ref), FULL)
        event = {'pull_request': {'base': {'sha': self.base}, 'head': {'sha': head}}}
        self.assertEqual(SELECT.select('pull_request', event, 'CI'), FULL)

    def test_documentation_only_main_pushes_and_merge_groups_require_full(self):
        # A release commit is often documentation only; main must still be fully tested.
        self.repo.write('README.md', 'after\n')
        head = self.repo.commit('docs')
        self.assertEqual(self.select(head), DOCS)
        for workflow in ('CI', 'Security'):
            self.assertEqual(SELECT.select('push', {'before': self.base, 'after': head}, workflow), FULL)
            self.assertEqual(SELECT.select('merge_group', {'merge_group': {'base_sha': self.base, 'head_sha': head}}, workflow), FULL)

    def test_path_names_cannot_add_or_replace_outputs(self):
        self.repo.write('StenoKit/Sources/StenoKit/Services/LocalCleanupRanker.swift', 'edited\n')
        self.repo.git('add', '-A')
        hostile = ('Steno/x\n::set-output name=runtime_required::false\nruntime_required=false.swift',
                   'StenoTests/::warning::name|`<b>.swift')
        for path in hostile:
            self.repo.add_index_entry('100644', path)
        head = self.repo.commit_index()
        event = self.repo.root / '.git' / 'event.json'
        event.write_text(json.dumps(pull_request(self.base, head)))
        output = self.repo.root / '.git' / 'output'
        summary = self.repo.root / '.git' / 'summary'
        stdout = io.StringIO()
        with patch.dict(os.environ, {'GITHUB_EVENT_PATH': str(event), 'GITHUB_EVENT_NAME': 'pull_request',
                                     'GITHUB_WORKFLOW': 'CI', 'GITHUB_OUTPUT': str(output),
                                     'GITHUB_STEP_SUMMARY': str(summary)}), redirect_stdout(stdout):
            SELECT.main()
        self.assertEqual(output.read_text().splitlines(), [f'{key}={RUNTIME[key]}' for key in SELECT.KEYS])
        self.assertNotIn('::', stdout.getvalue())
        self.assertNotIn('Steno/x', stdout.getvalue())
        text = summary.read_text()
        self.assertIn('LocalCleanupRanker.swift', text)
        self.assertFalse(any(line.startswith(('::', 'runtime_required')) for line in text.splitlines()))
        for fragment in ('|`<', '<b>', 'name|'):
            self.assertNotIn(fragment, text)
        self.assertEqual(text.count('\\u{a}'), 2)

    def test_unavailable_comparison_falls_back_to_full(self):
        event = self.repo.root / '.git' / 'event.json'
        output = self.repo.root / '.git' / 'output'
        for payload in ('{}', 'null', '[]', '{"pull_request": null}', '{"pull_request": {"base": {}, "head": {}}}',
                        '{"pull_request": {"base": {"ref": "main", "sha": "' + 'b' * 40 + '"}, "head": {"sha": "' + 'c' * 40 + '"}}}'):
            event.write_text(payload)
            output.write_text('')
            with patch.dict(os.environ, {'GITHUB_EVENT_PATH': str(event), 'GITHUB_EVENT_NAME': 'pull_request', 'GITHUB_WORKFLOW': 'CI', 'GITHUB_OUTPUT': str(output)}), redirect_stdout(io.StringIO()):
                SELECT.main()
            self.assertEqual(output.read_text(), ''.join(f'{key}={FULL[key]}\n' for key in SELECT.KEYS))


class StaticSelectionTests(unittest.TestCase):
    def test_release_schedule_dispatch_and_missing_base_require_full(self):
        for event in ('push', 'merge_group', 'schedule', 'workflow_dispatch', 'workflow_call', 'unknown'):
            self.assertEqual(SELECT.select(event, {}, 'CI'), FULL)
        # Both release callers reuse validation and security; each must get the full suite.
        for workflow in ('Release', 'Publish release'):
            for event in ('pull_request', 'push', 'workflow_dispatch'):
                with self.subTest(workflow=workflow, event=event):
                    self.assertEqual(SELECT.select(event, {}, workflow), FULL)
        self.assertEqual(SELECT.select('pull_request', pull_request('0' * 40, 'a' * 40), 'CI'), FULL)

    def test_release_caller_names_match_the_release_workflows(self):
        for path, name in (('release.yml', 'Release'), ('publish-release.yml', 'Publish release')):
            workflow = POLICY.parse_workflow((ROOT / '.github/workflows' / path).read_text())
            self.assertEqual(workflow['name'], name)

    def test_ci_definitions_and_gate_scripts_run_everything(self):
        for path in ('.github/workflows/security.yml', 'scripts/ci/select-checks.py', 'scripts/ci/check-sarif.py',
                     'scripts/ci/tests/test_check_selection.py', 'scripts/ci/runtime-lock.json',
                     'scripts/ci/patches/whisper-security.patch', 'project.yml', '.github/dependabot.yml'):
            self.assertEqual(SELECT.tier(path), 'infrastructure', path)
        for path in ('runtime-helper/steno_whisper_runtime.cpp', 'runtime-helper/steno_prompt_verification.h',
                     'scripts/build-whisper-runtime-helper.sh'):
            self.assertEqual(SELECT.tier(path), 'native', path)
        for path in ('scripts/test-whisper-prompt-scoring.sh', 'research/benchmarks/manifest.json',
                     'StenoKit/Sources/StenoBenchmarkCore/BenchmarkRunner.swift', 'Steno/BundledWhisperRuntime.swift',
                     'Steno/StenoDistribution.entitlements', 'StenoKit/Tests/StenoKitTests/RetainedWhisperProcessIntegrationTests.swift'):
            self.assertEqual(SELECT.tier(path), 'runtime', path)
        for path in ('Steno/DictationController.swift', 'StenoKit/Sources/StenoKit/Services/HistoryStore.swift',
                     'StenoKit/Tests/StenoKitTests/SessionCoordinatorTests.swift', 'Design/Steno.icon/icon.json'):
            self.assertEqual(SELECT.tier(path), 'tests', path)

    def test_every_tracked_path_has_a_rule(self):
        tracked = subprocess.check_output(['git', '-C', str(ROOT), 'ls-files', '-z']).decode().split('\0')
        unknown = [path for path in tracked if path and SELECT.tier(path) == 'unknown']
        self.assertEqual(unknown, [], 'add a rule to select-checks.py for each new path')

    def test_exact_rules_name_tracked_files(self):
        # A renamed file must not silently fall back to its directory's cheaper rule.
        tracked = set(subprocess.check_output(['git', '-C', str(ROOT), 'ls-files', '-z']).decode().split('\0'))
        for name, patterns in SELECT.RULES.items():
            for pattern in patterns:
                if not pattern.endswith('/'):
                    self.assertIn(pattern, tracked, f'{name} rule names a missing file')

    def test_no_rule_is_listed_twice(self):
        folded = [SELECT.fold(pattern) for patterns in SELECT.RULES.values() for pattern in patterns]
        self.assertEqual(len(folded), len(set(folded)))
        self.assertEqual(set(SELECT.RULES) | {'docs', 'unknown'}, set(SELECT.EFFECTS))

    def test_listed_package_types_are_not_extended_from_unlisted_files(self):
        # StenoKit is one module: an extension anywhere in it can change what a
        # runtime file calls. Only the runtime job executes those files.
        tracked = [path for path in subprocess.check_output(['git', '-C', str(ROOT), 'ls-files', '-z', 'StenoKit']).decode().split('\0')
                   if path.endswith('.swift')]
        listed = [path for path in tracked if SELECT.tier(path) == 'runtime']
        declaration = re.compile(r'^(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|package|private|fileprivate|open|final|indirect|nonisolated)\s+)*'
                                 r'(?:class|struct|enum|protocol|actor|typealias)\s+([A-Za-z_]\w*)', re.M)
        extension = re.compile(r'^(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|package|private|fileprivate)\s+)*extension\s+([A-Za-z_]\w*)', re.M)
        types = {}
        for path in listed:
            for match in declaration.finditer((ROOT / path).read_text()):
                types.setdefault(match.group(1), path)
        self.assertIn('RuleBasedCleanupEngine', types)
        violations = [f'{path} extends {match.group(1)} from {types[match.group(1)]}'
                      for path in tracked if path not in listed
                      for match in extension.finditer((ROOT / path).read_text()) if match.group(1) in types]
        self.assertEqual(violations, [], 'move the extension into a listed file or list this file')

    def test_escaped_summary_text_cannot_form_markup_or_commands(self):
        text = SELECT.escaped('a|b`c\n::d<e>')
        for character in '|`\n:<>':
            self.assertNotIn(character, text)


# Runs a gate script once per environment in one shell, each in a subshell
# where `set -e` applies, and prints one exit status per line.
HARNESS = 'set +e\nwhile IFS= read -r assignments; do\n  ( eval "$assignments"; set -e; eval "$GATE_SCRIPT" ) >/dev/null 2>&1\n  echo "$?"\ndone\n'
RESULTS = ('success', 'failure', 'skipped', 'cancelled')
EVENTS = ('pull_request', 'push', 'workflow_dispatch', 'schedule', 'merge_group')


def gate_command(path):
    workflow = POLICY.parse_workflow((ROOT / '.github/workflows' / path).read_text())
    return workflow['jobs']['gate']['steps'][0]['run']


def gate_passes(command, cases):
    lines = ''.join('export ' + ' '.join(f'{key}={shlex.quote(value)}' for key, value in case.items()) + '\n' for case in cases)
    result = subprocess.run(['bash', '-c', HARNESS], input=lines, capture_output=True, text=True,
                            env={'PATH': os.environ['PATH'], 'GATE_SCRIPT': command}, check=True)
    statuses = result.stdout.split()
    assert len(statuses) == len(cases)
    return [status == '0' for status in statuses]


def possible_classifications():
    """Every output the classifier can produce for a pull request."""
    tiers = list(SELECT.EFFECTS)
    outputs = {tuple(SELECT.outputs_for(list(subset)).items())
               for size in range(1, len(tiers) + 1) for subset in itertools.combinations(tiers, size)}
    return [dict(output) for output in sorted(outputs)] + [dict(FULL)]


class GateTests(unittest.TestCase):
    def test_harness_matches_a_separate_shell(self):
        command = gate_command('validate.yml')
        cases = [dict(SCOPE=scope, RUNTIME_REQUIRED=flag, EVENT_NAME='pull_request', POLICY_RESULT='success',
                      MACOS_RESULT='success', RUNTIME_RESULT=runtime)
                 for scope, flag, runtime in itertools.product(('docs', 'full'), ('true', 'false'), ('success', 'skipped'))]
        separate = [subprocess.run(['bash', '-e', '-c', command], env={**os.environ, **case}, capture_output=True).returncode == 0
                    for case in cases]
        self.assertEqual(gate_passes(command, cases), separate)
        self.assertTrue(any(separate) and not all(separate))

    def test_ci_gate_matches_an_independent_oracle(self):
        allowed = {'pull_request': {('docs', 'false'), ('full', 'false'), ('full', 'true')}}
        cases, expected = [], []
        for scope, flag, event, policy, macos, runtime in itertools.product(
                ('docs', 'full', '', 'other'), ('true', 'false', '', 'other'), EVENTS, RESULTS, RESULTS, RESULTS):
            cases.append(dict(SCOPE=scope, RUNTIME_REQUIRED=flag, EVENT_NAME=event, POLICY_RESULT=policy,
                              MACOS_RESULT=macos, RUNTIME_RESULT=runtime))
            expected.append(policy == 'success' and (scope, flag) in allowed.get(event, {('full', 'true')})
                            and macos == {'docs': 'skipped', 'full': 'success'}[scope]
                            and runtime == {'true': 'success', 'false': 'skipped'}[flag])
        self.assertEqual(gate_passes(gate_command('validate.yml'), cases), expected)

    def test_named_failures(self):
        ci = gate_command('validate.yml')
        base = dict(SCOPE='full', RUNTIME_REQUIRED='true', EVENT_NAME='pull_request', POLICY_RESULT='success',
                    MACOS_RESULT='success', RUNTIME_RESULT='success')
        failing = [dict(base, RUNTIME_RESULT=result) for result in ('skipped', 'cancelled', 'failure')]
        failing += [dict(base, RUNTIME_REQUIRED='false', RUNTIME_RESULT='success'),
                    dict(base, EVENT_NAME='push', RUNTIME_REQUIRED='false', RUNTIME_RESULT='skipped'),
                    dict(base, SCOPE='docs', MACOS_RESULT='skipped')]
        self.assertEqual(gate_passes(ci, [base] + failing), [True] + [False] * len(failing))
    def test_security_gate_rejects_failed_classification_or_unexpected_skip(self):
        workflow = POLICY.parse_workflow((ROOT / '.github/workflows/security.yml').read_text())
        command = workflow['jobs']['gate']['steps'][0]['run']
        for scope, classification, native, review in itertools.product(('docs', 'full', ''), ('success', 'failure', 'skipped'), ('success', 'failure', 'skipped', 'cancelled'), ('success', 'failure', 'skipped')):
            env = dict(os.environ, SCOPE=scope, SCOPE_RESULT=classification, NATIVE_RESULT=native, REVIEW_SOURCES_RESULT=review, ACTIONS_RESULT='success', DEPENDENCY_RESULT='success', EVENT_NAME='pull_request')
            result = subprocess.run(['bash', '-e', '-c', command], env=env, capture_output=True)
            expected = classification == review == 'success' and ((scope == 'docs' and native == 'skipped') or (scope == 'full' and native == 'success'))
            self.assertEqual(result.returncode == 0, expected)

    def evaluate(self, condition, outputs, classifier, event):
        if condition is None:
            return True
        match = re.fullmatch(r"needs\.([A-Za-z0-9_-]+)\.outputs\.([a-z_]+) == '([a-z]+)'", condition)
        if match and match.group(1) == classifier:
            return outputs[match.group(2)] == match.group(3)
        if condition == "github.event_name == 'pull_request'":
            return event == 'pull_request'
        self.fail(f'unsupported job condition: {condition}')

    def test_job_conditions_agree_with_the_gates(self):
        # Every job runs exactly when its gate requires it, and any other result fails.
        for path, classifier in GATES.items():
            workflow = POLICY.parse_workflow((ROOT / '.github/workflows' / path).read_text())
            jobs = {name: job for name, job in workflow['jobs'].items() if name != 'gate'}
            step = workflow['jobs']['gate']['steps'][0]
            variables = {value[len('${{ '):-len(' }}')]: name for name, value in step['env'].items()}
            def environment(outputs, event, results):
                values = {'github.event_name': event, **{f'needs.{name}.result': result for name, result in results.items()},
                          **{f'needs.{classifier}.outputs.{key}': value for key, value in outputs.items()}}
                return {name: values[reference] for reference, name in variables.items()}
            cases, expected = [], []
            for event in EVENTS:
                for outputs in possible_classifications() if event == 'pull_request' else [FULL]:
                    results = {name: 'success' if self.evaluate(job.get('if'), outputs, classifier, event) else 'skipped'
                               for name, job in jobs.items()}
                    cases.append(environment(outputs, event, results))
                    expected.append(True)
                    for name, result in results.items():
                        for other in RESULTS:
                            if other != result:
                                cases.append(environment(outputs, event, {**results, name: other}))
                                expected.append(False)
            with self.subTest(workflow=path):
                self.assertEqual(gate_passes(step['run'], cases), expected)


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
        security = self.workflow('security.yml', [('needs: [changes, dependency-review, actions, review-sources, native]', 'needs: [changes, dependency-review, actions, review-sources]')])
        self.assertTrue(any('gate needs' in error for error in gate_wiring_errors(security, 'changes')))

    def test_result_variable_pointing_at_the_wrong_job_is_rejected(self):
        validate = self.workflow('validate.yml', [('MACOS_RESULT: ${{ needs.macos.result }}', 'MACOS_RESULT: ${{ needs.runtime.result }}')])
        self.assertTrue(any('macos result' in error for error in gate_wiring_errors(validate, 'policy')))
        security = self.workflow('security.yml', [('NATIVE_RESULT: ${{ needs.native.result }}', 'NATIVE_RESULT: ${{ needs.actions.result }}')])
        self.assertTrue(any('native result' in error for error in gate_wiring_errors(security, 'changes')))

    def test_job_conditions_outside_the_classifier_are_rejected(self):
        validate = self.workflow('validate.yml', [("    if: needs.policy.outputs.runtime_required == 'true'\n    name: Runtime",
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
