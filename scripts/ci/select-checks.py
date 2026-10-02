#!/usr/bin/env python3
"""Select the validation a pull request needs from its complete Git diff.

Only a pull request against main can skip a job. Every other event, every
unrecognized path and every classification failure selects full validation.
Path names never reach standard output or GITHUB_OUTPUT; the step summary shows
them only in an escaped form.
"""
import json
import os
from pathlib import Path, PurePosixPath
import re
import string
import subprocess
import unicodedata

ROOT_DOCS = {'README.md', 'CHANGELOG.md', 'QUICKSTART.md', 'CONTRIBUTING.md', 'SECURITY.md', 'CODE_OF_CONDUCT.md', 'THIRD_PARTY_NOTICES.md', 'LICENSE'}

KEYS = ('scope', 'runtime_required', 'swift_scan_required', 'cpp_scan_required')
FULL = {'scope': 'full', 'runtime_required': 'true', 'swift_scan_required': 'true', 'cpp_scan_required': 'true'}

# What each kind of path requires: (runtime job, Swift scan, C/C++ scan).
# The package and hosted tests run for every tier except an all-docs change.
EFFECTS = {
    'infrastructure': (True, True, True),
    'native': (True, False, True),
    'runtime': (True, False, False),
    'tests': (False, False, False),
    'docs': (False, False, False),
    'unknown': (True, True, True),
}

# Each rule is an exact path or a directory prefix ending in '/'. The most
# specific rule decides a path: an exact path beats a prefix, and a longer
# prefix beats a shorter one. A path no rule covers is 'unknown'.
RULES = {
    # CI definitions, gate scripts and the generated project's source run
    # everything, including both compiled scans.
    'infrastructure': (
        '.github/workflows/',
        '.github/actions/',
        '.github/dependabot.yml',
        '.github/release.yml',
        'scripts/ci/',
        'project.yml',
    ),
    # Sources the C/C++ scan compiles. The patch and the pinned revision are
    # under scripts/ci/ and already run everything.
    'native': (
        'runtime-helper/',
        'scripts/build-whisper-runtime-helper.sh',
    ),
    # Code the runtime and distribution job executes: the native test drivers,
    # the retained-engine tests, the benchmark and its cleanup pipeline, and
    # what the preview bundles.
    'runtime': (
        'scripts/',
        'research/benchmarks/',
        'Steno/Steno.entitlements',
        'Steno/StenoDistribution.entitlements',
        'Steno/BundledWhisperRuntime.swift',
        'Steno/WhisperModelLibrary.swift',
        'Steno/Resources/',
        'Steno/Assets.xcassets/',
        'StenoKit/Package.swift',
        'StenoKit/Sources/StenoBenchmarkCLI/',
        'StenoKit/Sources/StenoBenchmarkCore/',
        'StenoKit/Sources/StenoKit/Resources/',
        'StenoKit/Sources/StenoKit/Protocols/Engines.swift',
        'StenoKit/Sources/StenoKit/Models/AppContext.swift',
        'StenoKit/Sources/StenoKit/Models/CleanupRanking.swift',
        'StenoKit/Sources/StenoKit/Models/LivePCM.swift',
        'StenoKit/Sources/StenoKit/Models/LiveTranscription.swift',
        'StenoKit/Sources/StenoKit/Models/Profiles.swift',
        'StenoKit/Sources/StenoKit/Models/StorageRecovery.swift',
        'StenoKit/Sources/StenoKit/Models/Transcripts.swift',
        'StenoKit/Sources/StenoKit/Models/WhisperCompatibility.swift',
        'StenoKit/Sources/StenoKit/Models/WhisperModelCatalog.swift',
        'StenoKit/Sources/StenoKit/Services/CanonicalWAVFrameStreamer.swift',
        'StenoKit/Sources/StenoKit/Services/CommonEnglishWords.swift',
        'StenoKit/Sources/StenoKit/Services/LexiconMatcher.swift',
        'StenoKit/Sources/StenoKit/Services/LexiconSafety.swift',
        'StenoKit/Sources/StenoKit/Services/LocalCleanupRanker.swift',
        'StenoKit/Sources/StenoKit/Services/PhraseMatchPlanner.swift',
        'StenoKit/Sources/StenoKit/Services/ProcessWhisperRuntimeSession.swift',
        'StenoKit/Sources/StenoKit/Services/RetainedWhisperTranscriptionEngine.swift',
        'StenoKit/Sources/StenoKit/Services/RuleBasedCleanupCandidateGenerator.swift',
        'StenoKit/Sources/StenoKit/Services/RuleBasedCleanupEngine.swift',
        'StenoKit/Sources/StenoKit/Services/StyleProfileService.swift',
        'StenoKit/Sources/StenoKit/Services/WhisperCLITranscriptionEngine.swift',
        'StenoKit/Sources/StenoKit/Services/WhisperCompatibilityService.swift',
        'StenoKit/Sources/StenoKit/Services/WhisperModelFileVerifier.swift',
        'StenoKit/Sources/StenoKit/Services/WhisperRuntimeConfiguration.swift',
        'StenoKit/Sources/StenoKit/Services/WhisperRuntimePathRepair.swift',
        'StenoKit/Sources/StenoKit/Services/WhisperSetupSelfTest.swift',
        'StenoKit/Sources/StenoKit/Services/WhisperTranscriptDecoder.swift',
        'StenoKit/Sources/StenoKit/Utilities/ProcessRunner.swift',
        'StenoKit/Sources/StenoKit/Utilities/StaleTemporaryFileSweep.swift',
        'StenoKit/Tests/StenoKitTests/RetainedWhisperProcessIntegrationTests.swift',
    ),
    # The package and hosted tests cover these.
    'tests': (
        'Steno/',
        'StenoTests/',
        'StenoKit/Sources/',
        'StenoKit/Tests/',
        'StenoKit/.gitignore',
        'StenoKit/README.md',
        'Design/',
        'assets/',
        '.github/ISSUE_TEMPLATE/',
        '.github/PULL_REQUEST_TEMPLATE.md',
        '.github/CODEOWNERS',
        '.gitignore',
        'SUPPORT.md',
        # The reviewed-findings record is data. The Security workflow's source
        # check holds it to the bound files on every pull request, and the
        # compiled C/C++ scan checks it again on main and before signing.
        'scripts/ci/reviewed-findings.json',
    ),
}
# A case or Unicode variant of a costly path keeps its cost; a variant of a
# cheap path falls through to a costlier rule or to 'unknown'.
FOLDED_TIERS = ('infrastructure', 'native', 'runtime')
COST = {'docs': 0, 'tests': 1, 'runtime': 2, 'native': 3, 'infrastructure': 4, 'unknown': 5}
REGULAR_MODES = {b'100644', b'100755'}
GIT_ENV = dict(os.environ, GIT_LITERAL_PATHSPECS='1')


def documentation_path(path):
    p = PurePosixPath(path)
    return (path in ROOT_DOCS or (path.startswith('docs/') and p.suffix in {'.md', '.png', '.jpg', '.jpeg', '.webp'})) and '..' not in p.parts


def fold(path):
    return unicodedata.normalize('NFD', path).casefold()


def tier(path):
    best = None
    for name, patterns in RULES.items():
        candidate = fold(path) if name in FOLDED_TIERS else path
        for pattern in patterns:
            rule = fold(pattern) if name in FOLDED_TIERS else pattern
            if pattern.endswith('/'):
                matched, specificity = candidate.startswith(rule), len(pattern)
            else:
                matched, specificity = candidate == rule, float('inf')
            if matched and (best is None or (specificity, COST[name]) > best[:2]):
                best = (specificity, COST[name], name)
    if best is not None:
        return best[2]
    return 'docs' if documentation_path(path) else 'unknown'


def outputs_for(tiers):
    if all(name == 'docs' for name in tiers):
        return {'scope': 'docs', 'runtime_required': 'false', 'swift_scan_required': 'false', 'cpp_scan_required': 'false'}
    runtime, swift, cpp = (any(EFFECTS[name][index] for name in tiers) for index in range(3))
    flag = {True: 'true', False: 'false'}
    return {'scope': 'full', 'runtime_required': flag[runtime], 'swift_scan_required': flag[swift], 'cpp_scan_required': flag[cpp]}


def git(*args):
    # Git's own messages can quote path names, so they are discarded too.
    return subprocess.check_output(['git', *args], env=GIT_ENV, stderr=subprocess.DEVNULL)


def select(event_name, event, workflow, details=None):
    # Only pull requests may skip checks. Every commit on main, merge groups,
    # dispatches, schedules and release callers receive the full suite.
    if workflow not in {'CI', 'Security'} or event_name != 'pull_request':
        return dict(FULL)
    pull_request = event['pull_request']
    # A pull request against another branch is compared with that branch, which
    # may hold unvalidated changes and may later be retargeted to main.
    if pull_request['base'].get('ref') != 'main':
        return dict(FULL)
    base = pull_request['base']['sha']
    head = pull_request['head']['sha']
    if any(not isinstance(sha, str) or not re.fullmatch(r'[0-9a-f]{40}', sha) or sha == '0' * 40 for sha in (base, head)):
        return dict(FULL)
    base = git('merge-base', base, head).decode('ascii').strip()
    # No API pagination or file limit; renames retain both source and destination.
    raw = git('diff', '--name-only', '--no-renames', '-z', base, head, '--')
    paths = [p.decode('utf-8') for p in raw.split(b'\0') if p]
    if not paths:
        return dict(FULL)
    # A symbolic link or submodule anywhere in the diff could stand for a path
    # other than its own name.
    seen = set()
    for revision in (base, head):
        for row in git('ls-tree', '-r', '-z', revision, '--', *paths).split(b'\0'):
            if not row:
                continue
            metadata, name = row.split(b'\t', 1)
            if metadata.split(b' ', 1)[0] not in REGULAR_MODES:
                return dict(FULL)
            seen.add(name.decode('utf-8'))
    if not set(paths) <= seen:
        return dict(FULL)
    # Hosted macOS volumes ignore case, so two names differing only by case or
    # Unicode normalization become one file at checkout.
    names = [name.decode('utf-8') for name in git('ls-tree', '-r', '-z', '--name-only', 'HEAD').split(b'\0') if name]
    if len({fold(name) for name in names}) != len(names):
        return dict(FULL)
    tiers = [tier(path) for path in paths]
    if details is not None:
        details.extend(zip(paths, tiers))
    return outputs_for(tiers)


SAFE = frozenset(string.ascii_letters + string.digits + '._-/+@ ')


def escaped(path):
    return ''.join(character if character in SAFE else f'\\u{{{ord(character):x}}}' for character in path)


def summary(outputs, details):
    lines = ['### Selected validation', '', '| Output | Value |', '| --- | --- |']
    lines += [f'| `{key}` | `{outputs[key]}` |' for key in KEYS]
    if details:
        lines += ['', '| Changed path | Requires |', '| --- | --- |']
        lines += [f'| `{escaped(path)}` | {name} |' for path, name in details[:500]]
        if len(details) > 500:
            lines.append(f'| {len(details) - 500} more paths | not listed |')
    return '\n'.join(lines) + '\n'


def main():
    details = []
    try:
        outputs = select(os.environ['GITHUB_EVENT_NAME'], json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text()), os.environ['GITHUB_WORKFLOW'], details)
        if set(outputs) != set(KEYS) or outputs['scope'] not in {'docs', 'full'} or any(outputs[key] not in {'true', 'false'} for key in KEYS[1:]):
            raise ValueError('classification outside its domain')
    except Exception:
        outputs, details = dict(FULL), []
        print('Change classification unavailable; requiring full validation.')
    summary_path = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary_path:
        try:
            with open(summary_path, 'a') as handle:
                handle.write(summary(outputs, details))
        except OSError:
            print('Step summary unavailable.')
    # Written last and only from fixed values; no path can add or replace a key.
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        for key in KEYS:
            output.write(f'{key}={outputs[key]}\n')
    print('Validation scope: ' + ', '.join(f'{key}={outputs[key]}' for key in KEYS))


if __name__ == '__main__':
    main()
