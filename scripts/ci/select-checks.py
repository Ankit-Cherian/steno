#!/usr/bin/env python3
"""Skip native checks only for a pull request with a complete, documentation-only Git diff."""
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess

ROOT_DOCS = {'README.md', 'CHANGELOG.md', 'QUICKSTART.md', 'CONTRIBUTING.md', 'SECURITY.md', 'CODE_OF_CONDUCT.md', 'THIRD_PARTY_NOTICES.md', 'LICENSE'}


def documentation_path(path):
    p = PurePosixPath(path)
    return (path in ROOT_DOCS or (path.startswith('docs/') and p.suffix in {'.md', '.png', '.jpg', '.jpeg', '.webp'})) and '..' not in p.parts


def select(event_name, event, workflow):
    # Only pull requests may skip checks. Every commit on main, merge groups,
    # dispatches, schedules and release callers receive the full suite, so a
    # documentation-only release commit is still fully tested.
    if workflow not in {'CI', 'Security'} or event_name != 'pull_request':
        return 'full'
    base = event['pull_request']['base']['sha']
    head = event['pull_request']['head']['sha']
    if any(not re.fullmatch(r'[0-9a-f]{40}', sha) or sha == '0' * 40 for sha in (base, head)):
        return 'full'
    base = subprocess.check_output(['git', 'merge-base', base, head], text=True).strip()
    # No API pagination or file limit; renames retain both source and destination.
    raw = subprocess.check_output(['git', 'diff', '--name-only', '--no-renames', '-z', base, head, '--'])
    paths = [p.decode('utf-8') for p in raw.split(b'\0') if p]
    if not paths or not all(documentation_path(p) for p in paths):
        return 'full'
    for revision in (base, head):
        records = subprocess.check_output(['git', 'ls-tree', '-r', '-z', revision, '--', *paths])
        if any(row.split(b' ', 1)[0] not in {b'100644', b'100755'} for row in records.split(b'\0') if row):
            return 'full'
    return 'docs'


def main():
    try:
        scope = select(os.environ['GITHUB_EVENT_NAME'], json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text()), os.environ['GITHUB_WORKFLOW'])
    except (KeyError, TypeError, ValueError, OSError, subprocess.CalledProcessError):
        scope = 'full'
        print('Change classification unavailable; requiring full validation.')
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write(f'scope={scope}\n')
    print(f'Validation scope: {scope}')


if __name__ == '__main__':
    main()
