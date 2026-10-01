#!/usr/bin/env python3
"""Fail-closed release identity and output guards; no third-party dependencies."""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.error
import urllib.request

STABLE_VERSION = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
DISTRIBUTION_ENTITLEMENTS = 'Steno/StenoDistribution.entitlements'


def validate_identity(version, sha, dispatch_sha, ref, accepted):
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version):
        raise ValueError("Version must be a stable X.Y.Z version without a v prefix")
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("Source must be an exact lowercase 40-character commit SHA")
    if ref != "refs/heads/main" or dispatch_sha != sha:
        raise ValueError("Dispatch must run on main at the exact requested source SHA")
    if accepted != "true":
        raise ValueError("Manual acceptance of this exact source is required")


def validate_output(candidate, repo, home):
    raw = Path(candidate)
    if not raw.is_absolute():
        raise ValueError("Distribution output must be an absolute path")
    if raw.exists() or raw.is_symlink():
        raise ValueError("Distribution output must not already exist; outputs are never overwritten")
    result = raw.resolve()
    protected = [Path('/'), Path(repo).resolve(), Path(home).resolve(),
                 Path(repo).resolve() / 'build' / 'Steno.app']
    for path in protected:
        if result == path or result in path.parents:
            raise ValueError("Distribution output overlaps a protected root")
    if protected[-1] in result.parents:
        raise ValueError("Distribution output cannot be inside the local candidate")
    if len(result.parts) < 3:
        raise ValueError("Distribution output must have a dedicated parent directory")
    return str(result)


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def validate_source(repo, version, sha):
    if run('git', '-C', str(repo), 'rev-parse', 'HEAD') != sha:
        raise ValueError("Checkout does not match requested source SHA")
    tag = 'v' + version
    if run('git', '-C', str(repo), 'rev-parse', f'refs/tags/{tag}^{{commit}}') != sha:
        raise ValueError("Pre-existing version tag does not point to requested source")
    subprocess.run(['git', '-C', str(repo), 'merge-base', '--is-ancestor', sha,
                    'refs/remotes/origin/main'], check=True)
    versions = re.findall(r'^\s*MARKETING_VERSION:\s*[\"\']?([0-9.]+)[\"\']?\s*$',
                          (Path(repo) / 'project.yml').read_text(), re.M)
    if versions != [version]:
        raise ValueError("project.yml MARKETING_VERSION must match requested release")


def validate_remote(repository, version, sha):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError("Invalid repository identifier")
    commit = json.loads(run('gh', 'api', f'repos/{repository}/commits/v{version}'))
    if commit['sha'] != sha:
        raise ValueError("Remote release tag moved or no longer matches requested SHA")
    comparison = json.loads(run('gh', 'api', f'repos/{repository}/compare/main...{sha}'))
    if comparison['status'] not in ('behind', 'identical'):
        raise ValueError("Release commit is not on remote main")


def setting(text, key):
    return re.findall(rf'^\s*{key}:\s*[\"\']?([^\"\'\s#]+)[\"\']?\s*(?:#.*)?$', text, re.M)


def latest_release_tag(repository):
    """Read the latest published release; public data, so a token is optional."""
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError("Invalid repository identifier")
    request = urllib.request.Request(f'https://api.github.com/repos/{repository}/releases/latest',
                                     headers={'Accept': 'application/vnd.github+json'})
    token = os.environ.get('GH_TOKEN') or os.environ.get('GITHUB_TOKEN')
    if token:
        request.add_header('Authorization', f'Bearer {token}')
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)['tag_name']
    except (OSError, urllib.error.URLError, ValueError, KeyError) as error:
        raise ValueError(f"Could not read the latest release ({error}); pass --previous-tag") from error


def unreleased_entries(changelog):
    lines = changelog.splitlines()
    try:
        start = next(index for index, line in enumerate(lines) if re.fullmatch(r'## \[Unreleased\]\s*', line))
    except StopIteration:
        return []
    entries = []
    for line in lines[start + 1:]:
        if line.startswith('## '):
            break
        if line.strip() and not line.startswith('### '):
            entries.append(line.strip())
    return entries


def validate_plan(repo, version, previous_tag, accept_entitlements_change=False, remote='origin',
                  today=None):
    """Check hand-edited release facts at HEAD before the permanent tag exists.

    Every value is read from the commit, not the working tree. Returns the
    passing checks (and notes) and the failing checks.
    """
    if not re.fullmatch(STABLE_VERSION, version):
        raise ValueError("Version must be a stable X.Y.Z version without a v prefix")
    if not re.fullmatch('v' + STABLE_VERSION, previous_tag):
        raise ValueError("Previous release tag must be a stable vX.Y.Z tag")
    git = lambda *args: run('git', '-C', str(repo), *args)
    head = git('rev-parse', 'HEAD')
    try:
        previous = git('rev-parse', '--verify', '--quiet', f'refs/tags/{previous_tag}^{{commit}}')
    except subprocess.CalledProcessError as error:
        raise ValueError(f"Previous release tag {previous_tag} is not available locally; fetch tags") from error
    show = lambda revision, path: subprocess.check_output(
        ['git', '-C', str(repo), 'show', f'{revision}:{path}'], text=True)
    project, previous_project = show(head, 'project.yml'), show(previous, 'project.yml')
    passed, errors = [], []

    def check(condition, success, failure):
        (passed if condition else errors).append(success if condition else failure)

    previous_version = tuple(map(int, previous_tag[1:].split('.')))
    check(tuple(map(int, version.split('.'))) > previous_version,
          f"{version} is newer than {previous_tag}", f"{version} does not advance beyond {previous_tag}")
    marketing = setting(project, 'MARKETING_VERSION')
    check(marketing == [version], f"MARKETING_VERSION is {version}",
          f"MARKETING_VERSION is {marketing}, expected [{version!r}]")
    builds, previous_builds = setting(project, 'CURRENT_PROJECT_VERSION'), setting(previous_project, 'CURRENT_PROJECT_VERSION')
    if len(builds) == len(previous_builds) == 1 and builds[0].isdigit() and previous_builds[0].isdigit():
        check(int(builds[0]) > int(previous_builds[0]),
              f"CURRENT_PROJECT_VERSION {builds[0]} is greater than {previous_tag}'s {previous_builds[0]}",
              f"CURRENT_PROJECT_VERSION {builds[0]} is not greater than {previous_tag}'s {previous_builds[0]}")
    else:
        errors.append(f"CURRENT_PROJECT_VERSION must be one integer, found {builds} (previously {previous_builds})")

    changelog = show(head, 'CHANGELOG.md')
    dates = re.findall(rf'^## \[{re.escape(version)}\] - (\d{{4}}-\d{{2}}-\d{{2}})\s*$', changelog, re.M)
    try:
        dated = len(dates) == 1 and datetime.date.fromisoformat(dates[0]) is not None
    except ValueError:
        dated = False
    check(dated, f"CHANGELOG.md has a dated {version} heading ({dates[0] if dates else ''})",
          f"CHANGELOG.md needs exactly one '## [{version}] - YYYY-MM-DD' heading")
    if dated and dates[0] != (today or datetime.datetime.now(datetime.timezone.utc).date()).isoformat():
        passed.append(f"note: the {version} heading is dated {dates[0]}, not today (UTC)")
    leftovers = unreleased_entries(changelog)
    check(not leftovers, "[Unreleased] has no leftover entries",
          f"[Unreleased] still has {len(leftovers)} entr{'y' if len(leftovers) == 1 else 'ies'}")

    tag = f'refs/tags/v{version}'
    try:
        local_tag = git('rev-parse', '--verify', '--quiet', f'{tag}^{{commit}}')
    except subprocess.CalledProcessError:
        local_tag = None
    remote_refs = dict(reversed(line.split('\t')) for line in
                       git('ls-remote', '--tags', remote, tag, f'{tag}^{{}}').splitlines() if line)
    remote_tag = remote_refs.get(f'{tag}^{{}}', remote_refs.get(tag))
    for where, target in (('local', local_tag), ('remote', remote_tag)):
        check(target in (None, head), f"v{version} {'is absent' if target is None else 'already points at HEAD'} ({where})",
              f"v{version} already exists ({where}) at {target}, not HEAD {head}")

    identifiers = setting(project, 'PRODUCT_BUNDLE_IDENTIFIER')
    previous_identifiers = setting(previous_project, 'PRODUCT_BUNDLE_IDENTIFIER')
    check(bool(identifiers) and identifiers == previous_identifiers,
          f"bundle identifiers are unchanged from {previous_tag}",
          f"bundle identifiers changed from {previous_identifiers} to {identifiers}; "
          "macOS ties microphone and accessibility permissions to the app's identity")

    entitlements_changed = show(head, DISTRIBUTION_ENTITLEMENTS) != show(previous, DISTRIBUTION_ENTITLEMENTS)
    if not entitlements_changed:
        passed.append(f"distribution entitlements are unchanged from {previous_tag}")
    elif accept_entitlements_change:
        passed.append(f"note: distribution entitlements changed from {previous_tag}; acknowledged")
    else:
        errors.append(f"distribution entitlements changed from {previous_tag}; "
                      "review the change and pass --accept-entitlements-change")
    return passed, errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    output = sub.add_parser('output')
    output.add_argument('path')
    output.add_argument('--repo', required=True)
    source = sub.add_parser('source')
    source.add_argument('--repo', default='.')
    source.add_argument('--remote', action='store_true')
    plan = sub.add_parser('plan', help='check release facts at HEAD before tagging; needs no credentials')
    plan.add_argument('version')
    plan.add_argument('--repo', default='.')
    plan.add_argument('--previous-tag', help='tag of the latest published release (default: read from GitHub)')
    plan.add_argument('--repository', default=os.environ.get('GITHUB_REPOSITORY') or 'Ankit-Cherian/steno')
    plan.add_argument('--accept-entitlements-change', action='store_true')
    args = parser.parse_args()
    if args.command == 'output':
        print(validate_output(args.path, args.repo, str(Path.home())))
        return
    if args.command == 'plan':
        previous_tag = args.previous_tag or latest_release_tag(args.repository)
        passed, errors = validate_plan(args.repo, args.version, previous_tag,
                                       args.accept_entitlements_change)
        for line in passed:
            print(line if line.startswith('note: ') else f'ok: {line}')
        for line in errors:
            print(f'FAIL: {line}')
        if errors:
            raise ValueError(f'{len(errors)} release plan check(s) failed for {args.version}')
        print(f'Release plan for {args.version} passed against {previous_tag}.')
        return
    version, sha = os.environ.get('RELEASE_VERSION', ''), os.environ.get('RELEASE_SHA', '')
    validate_identity(version, sha, os.environ.get('GITHUB_SHA', ''),
                      os.environ.get('GITHUB_REF', ''), os.environ.get('MANUAL_ACCEPTANCE', ''))
    validate_source(args.repo, version, sha)
    if args.remote:
        validate_remote(os.environ.get('GITHUB_REPOSITORY', ''), version, sha)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, subprocess.CalledProcessError, KeyError) as error:
        sys.exit(f'Release guard failed: {error}')
