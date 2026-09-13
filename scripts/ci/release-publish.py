#!/usr/bin/env python3
"""Prepare a draft or explicitly publish that same verified draft exactly once."""
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import sys


def validate_assets(root, version, sha):
    filename = f'Steno-{version}.dmg'
    expected = {filename, 'SHA256SUMS', 'release-manifest.json'}
    if {p.name for p in root.iterdir()} != expected or any(p.is_symlink() for p in root.iterdir()):
        raise ValueError('Release artifact must contain exactly the three expected regular files')
    if not all(p.is_file() for p in root.iterdir()):
        raise ValueError('Release artifact contains a non-file entry')
    manifest = json.loads((root / 'release-manifest.json').read_text())
    with (root / filename).open('rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    for key, value in {'version': version, 'source_sha': sha, 'tag': 'v' + version,
                       'asset': filename, 'sha256': digest, 'notarized': True,
                       'architecture': 'arm64', 'minimum_macos': '13.0'}.items():
        if manifest.get(key) != value:
            raise ValueError(f'Release manifest mismatch: {key}')
    if (root / 'SHA256SUMS').read_text() != f'{digest}  {filename}\n':
        raise ValueError('Release checksum file does not match the final DMG')
    return [str(root / name) for name in sorted(expected)]


def validate_release_request(repository, version, sha, release_id=None):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise ValueError('Invalid repository identifier')
    if not re.fullmatch(r'(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)', version):
        raise ValueError('Release version must be a stable X.Y.Z value')
    if not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise ValueError('Release source must be an exact commit SHA')
    if release_id is not None and not re.fullmatch(r'[1-9][0-9]{0,19}', release_id):
        raise ValueError('Release ID must be an exact positive numeric draft ID')


def release_receipt(repository, release_id):
    return json.loads(subprocess.check_output(['gh', 'api',
        f'repos/{repository}/releases/{release_id}'], text=True))


def download_existing(repository, version, sha, release_id, root):
    validate_release_request(repository, version, sha, release_id)
    receipt = release_receipt(repository, release_id)
    if (str(receipt['id']) != release_id or receipt['draft'] is not True
            or receipt.get('prerelease') is not False
            or receipt['tag_name'] != 'v' + version or receipt['target_commitish'] != sha):
        raise ValueError('Requested draft ID, version, and source do not match')
    expected = {f'Steno-{version}.dmg', 'SHA256SUMS', 'release-manifest.json'}
    remote_assets = receipt['assets']
    if len(remote_assets) != 3 or {asset['name'] for asset in remote_assets} != expected:
        raise ValueError('Draft contains unexpected or duplicate asset names')
    for asset in remote_assets:
        # Never use API-supplied URLs, paths, or archive extraction. The local
        # filenames come from the exact allowlist and downloads use numeric IDs.
        if type(asset['id']) is not int or asset['id'] <= 0:
            raise ValueError('Invalid remote asset ID')
        if asset.get('state') != 'uploaded' or not re.fullmatch(r'sha256:[0-9a-f]{64}', asset.get('digest') or ''):
            raise ValueError('Remote asset must have a completed upload and SHA256 digest')
        limit = 5 * 1024**3 if asset['name'].endswith('.dmg') else 64 * 1024
        if type(asset.get('size')) is not int or not 0 < asset['size'] <= limit:
            raise ValueError('Remote release asset size is invalid')
    if not root.is_absolute() or root.exists() or root.is_symlink():
        raise ValueError('Release download directory must be a fresh absolute path')
    if any(parent.is_symlink() for parent in root.parents):
        raise ValueError('Release download path must not traverse symbolic links')
    root.mkdir(parents=True, exist_ok=False)
    for asset in remote_assets:
        destination = root / asset['name']
        with destination.open('xb') as stream:
            subprocess.run(['gh', 'api', f"repos/{repository}/releases/assets/{asset['id']}",
                            '-H', 'Accept: application/octet-stream'], stdout=stream, check=True)
        if destination.stat().st_size != asset['size']:
            raise ValueError('Downloaded release asset size differs from GitHub receipt')
    assets = validate_assets(root, version, sha)
    verify_remote_assets(receipt, assets, sha, release_id)
    verify_remote_assets(release_receipt(repository, release_id), assets, sha, release_id)
    print('Downloaded and verified the exact draft assets; publication still requires approval.')


def verify_remote_assets(receipt, assets, sha, release_id, *, draft=True):
    if str(receipt['id']) != release_id or receipt['draft'] is not draft:
        raise ValueError('Expected the unpublished draft created by this workflow run')
    if receipt.get('prerelease') is not False:
        raise ValueError('Only a full release can become the default download')
    if receipt['target_commitish'] != sha:
        raise ValueError('Draft release target does not match accepted source')
    remote = {asset['name']: asset for asset in receipt['assets']}
    if len(receipt['assets']) != len(assets) or set(remote) != {Path(asset).name for asset in assets}:
        raise ValueError('Draft release asset list changed')
    for asset in assets:
        path = Path(asset)
        with path.open('rb') as stream:
            digest = 'sha256:' + hashlib.file_digest(stream, 'sha256').hexdigest()
        if remote[path.name].get('digest') != digest:
            raise ValueError('Remote asset checksum missing or different: ' + path.name)
        if remote[path.name].get('state') != 'uploaded':
            raise ValueError('Remote asset upload is incomplete')


def require_newer_stable_release(repository, version):
    pages = json.loads(subprocess.check_output(['gh', 'api', '--paginate', '--slurp',
        f'repos/{repository}/releases?per_page=100'], text=True))
    requested = tuple(map(int, version.split('.')))
    for page in pages:
        for release in page:
            if release['draft'] is True or release['prerelease'] is True:
                continue
            if release['draft'] is not False or release['prerelease'] is not False or not release.get('published_at'):
                raise ValueError('Published release state is incomplete; inspect it before promotion')
            match = re.fullmatch(r'v((?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))', release['tag_name'])
            if not match:
                raise ValueError('Published release has an unrecognized stable version; reconcile it before promotion')
            if requested <= tuple(map(int, match[1].split('.'))):
                raise ValueError('Default download must advance beyond every published stable version')


def publish_existing(repository, version, sha, assets):
    release_id = os.environ.get('RELEASE_ID', '')
    validate_release_request(repository, version, sha, release_id)
    receipt = release_receipt(repository, release_id)
    if receipt['tag_name'] != 'v' + version:
        raise ValueError('Draft version tag changed')
    verify_remote_assets(receipt, assets, sha, release_id)
    require_newer_stable_release(repository, version)
    # Exactly one publication attempt. A failed/ambiguous response requires
    # inspecting the release, never an automatic retry.
    subprocess.run(['gh', 'api', '--method', 'PATCH',
                    f'repos/{repository}/releases/{release_id}',
                    '-F', 'draft=false', '-F', 'prerelease=false',
                    '-f', 'make_latest=true'], check=True, stdout=subprocess.DEVNULL)
    result = json.loads(subprocess.check_output(['gh', 'api',
        f'repos/{repository}/releases/{release_id}'], text=True))
    if result['draft'] or not result.get('published_at') or result['tag_name'] != 'v' + version:
        raise ValueError('Publication outcome is unknown; inspect release state before any retry')
    verify_remote_assets(result, assets, sha, release_id, draft=False)
    latest = json.loads(subprocess.check_output(['gh', 'api',
        f'repos/{repository}/releases/latest'], text=True))
    if latest['tag_name'] != 'v' + version or not latest.get('published_at'):
        raise ValueError('Latest release verification failed after publication; inspect state before any retry')
    verify_remote_assets(latest, assets, sha, release_id, draft=False)
    print('Published release: ' + result['html_url'])


def main():
    version, sha = os.environ['RELEASE_VERSION'], os.environ['RELEASE_SHA']
    root = Path(os.environ['RELEASE_ASSETS'])
    repository = os.environ['GITHUB_REPOSITORY']
    validate_release_request(repository, version, sha)
    if '--download' in sys.argv[1:]:
        download_existing(repository, version, sha, os.environ.get('RELEASE_ID', ''), root)
        return
    assets = validate_assets(root, version, sha)
    if '--publish' in sys.argv[1:]:
        publish_existing(repository, version, sha, assets)
        return
    # A read failure is never treated as evidence that no release exists.
    pages = subprocess.check_output(['gh', 'api', '--paginate', '--slurp',
                                    f'repos/{repository}/releases?per_page=100'], text=True)
    if any(r['tag_name'] == 'v' + version for page in json.loads(pages) for r in page):
        raise ValueError('A release or draft already exists for this tag; refusing to overwrite it')
    subprocess.run(['gh', 'release', 'create', 'v' + version, '--repo', repository,
                    '--verify-tag', '--target', sha, '--draft', '--title', 'Steno ' + version,
                    '--notes', 'Signed and notarized Apple silicon build. Release notes and final publication require maintainer review.',
                    *assets], check=True)
    receipt = json.loads(subprocess.check_output(['gh', 'api',
        f'repos/{repository}/releases/tags/v{version}'], text=True))
    if not receipt['draft'] or {a['name'] for a in receipt['assets']} != {Path(p).name for p in assets}:
        raise ValueError('Draft creation outcome is unexpected; inspect the existing release before any retry')
    verify_remote_assets(receipt, assets, sha, str(receipt['id']))
    if output := os.environ.get('GITHUB_OUTPUT'):
        with open(output, 'a') as stream:
            stream.write(f"release_id={receipt['id']}\n")
    print('Draft release prepared: ' + receipt['html_url'])
    print(f"Draft ID: {receipt['id']}. Use the Publish release workflow to promote this draft later.")


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit(f'Release operation failed: {error}. Do not retry without inspecting existing release state.')
