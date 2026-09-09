#!/usr/bin/env python3
"""Fail-closed release identity and output guards; no third-party dependencies."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys


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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    output = sub.add_parser('output')
    output.add_argument('path')
    output.add_argument('--repo', required=True)
    source = sub.add_parser('source')
    source.add_argument('--repo', default='.')
    source.add_argument('--remote', action='store_true')
    args = parser.parse_args()
    if args.command == 'output':
        print(validate_output(args.path, args.repo, str(Path.home())))
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
