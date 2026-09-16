#!/usr/bin/env python3
"""Recover the reviewed 1.0 signing failure without changing its tested source."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys

REPOSITORY = 'Ankit-Cherian/steno'
SOURCE = 'd25fcdf9d625eea6ee31bd0b03c5994302e8065e'
VERSION = '1.0.0'
RUN = 35041760947
WORKFLOW = REPOSITORY + '/.github/workflows/recover-release.yml'
CONTROL = Path(__file__).resolve().parents[2]
# These immutable job IDs are from attempt 1, before either signing failure.
SUCCESS_JOBS = {
    'preflight': 104622947413,
    'validate / Workflow and release contracts': 104622974922,
    'validate / Package and hosted tests (macos-15)': 104622974961,
    'validate / Package and hosted tests (macos-26)': 104622974997,
    'validate / Runtime and distribution preview': 104622975022,
    'security / CodeQL (Actions)': 104622975179,
    'security / CodeQL (c-cpp)': 104622975201,
    'security / CodeQL (swift)': 104622975264,
    'security / Security Gate': 104627355116,
    'validate / CI Gate': 104633911911,
}
OTHER_JOBS = {
    'security / Dependency Review': (104622976246, 'skipped'),
    'sign': (104633948619, 'failure'),
    'publish': (104634748150, 'skipped'),
    'draft': (104634748271, 'skipped'),
}
# Reviewed failures ended during P12 import and the first codesign operation,
# respectively, before release-dmg.sh could reach its notarization submission.
FAILED_SIGN_LOGS = {
    104633948619: 'c7da55fd214a72acc065a9fee8a60c2aa9639f5be72da6e5f1493af432a13a70',
    104993063349: 'fcf22f74ac9c088e69a6c15f14c1059096426da25a9df99ca756ace1451ce220',
}
UNCHANGED_INPUTS = (
    'scripts/ci/tools.sh', 'scripts/ci/prepare-runtime.sh',
    'scripts/ci/runtime-lock.json', 'scripts/ci/prepare-patched-runtime.py',
    'scripts/ci/release-publish.py', 'scripts/ci/release-guard.py',
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def module(name):
    spec = importlib.util.spec_from_file_location(name, CONTROL / 'scripts/ci' / (name + '.py'))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def api(path):
    return json.loads(command('gh', 'api', 'repos/' + REPOSITORY + '/' + path))


def pages(path, key=None):
    values = json.loads(command('gh', 'api', '--paginate', '--slurp',
                                'repos/' + REPOSITORY + '/' + path))
    return [item for page in values for item in (page[key] if key else page)]


def validate_run(run):
    expected = {'id': RUN, 'head_sha': SOURCE, 'head_branch': 'main',
                'path': '.github/workflows/release.yml', 'event': 'workflow_dispatch',
                'status': 'completed', 'conclusion': 'failure', 'run_attempt': 2}
    require(all(run.get(k) == v for k, v in expected.items()),
            'Original release run changed or does not match reviewed recovery evidence')
    require(run.get('repository', {}).get('full_name') == REPOSITORY,
            'Original release repository mismatch')


def validate_jobs(jobs):
    expected = {name: (number, 'success') for name, number in SUCCESS_JOBS.items()}
    expected.update(OTHER_JOBS)
    require(len(jobs) == len(expected), 'Missing or duplicate original release jobs')
    require({job['name'] for job in jobs} == set(expected), 'Original release job set changed')
    for job in jobs:
        number, conclusion = expected[job['name']]
        require(job['id'] == number and job['run_id'] == RUN
                and job['head_sha'] == SOURCE and job['status'] == 'completed'
                and job['conclusion'] == conclusion,
                'Original release job identity or result mismatch')
    return {
        'repository': REPOSITORY, 'run_id': RUN, 'attempt': 1, 'source_sha': SOURCE,
        'workflow': '.github/workflows/release.yml',
        'successful_jobs': [{'id': number, 'name': name}
                            for name, number in sorted(SUCCESS_JOBS.items())],
    }


def validate_prior_signing(run, jobs, logs, artifacts):
    validate_run(run)
    receipt = validate_jobs(jobs)
    require(set(logs) == set(FAILED_SIGN_LOGS), 'Missing reviewed signing failure log')
    for number, digest in FAILED_SIGN_LOGS.items():
        require(hashlib.sha256(logs[number]).hexdigest() == digest,
                'Signing failure log differs from reviewed pre-submission evidence')
    require(b'SecKeychainItemImport: MAC verification failed' in logs[104633948619],
            'First signing failure stage changed')
    require(all(marker in logs[104993063349] for marker in [
        b'** BUILD SUCCEEDED **', b'==> sign bundled runtime',
        b'The specified item could not be found in the keychain.',
        b'Process completed with exit code 1.']), 'Second signing failure stage changed')
    require(not any(b'==> notarize DMG' in log for log in logs.values()),
            'A previous attempt reached notarization; inspect its submission')
    require(not any(a['name'].startswith(('notary-recovery-', 'signed-release-'))
                    for a in artifacts),
            'Prior notarization or signed artifact exists; inspect and recover it instead')
    return receipt


def capture_signing_logs():
    # Preserve the reviewed bytes for hashing, without rendering log content.
    help_text = command('gh', 'api', '--help')
    flags = ['--allow-escape-sequences'] if '--allow-escape-sequences' in help_text else []
    return {number: subprocess.check_output([
        'gh', 'api', *flags, f'repos/{REPOSITORY}/actions/jobs/{number}/logs'])
        for number in FAILED_SIGN_LOGS}


def validation_receipt():
    run = api(f'actions/runs/{RUN}')
    jobs = pages(f'actions/runs/{RUN}/attempts/1/jobs?per_page=100', 'jobs')
    artifacts = pages(f'actions/runs/{RUN}/artifacts?per_page=100', 'artifacts')
    logs = capture_signing_logs()
    return validate_prior_signing(run, jobs, logs, artifacts)


def validate_dispatch(env):
    sha = env.get('GITHUB_SHA', '')
    require(bool(re.fullmatch(r'[0-9a-f]{40}', sha)), 'Invalid workflow source SHA')
    require(env.get('GITHUB_REPOSITORY') == REPOSITORY
            and env.get('GITHUB_REF') == 'refs/heads/main'
            and env.get('GITHUB_EVENT_NAME') == 'workflow_dispatch'
            and env.get('GITHUB_WORKFLOW_REF') == WORKFLOW + '@refs/heads/main',
            'Recovery must use its reviewed main-branch workflow')
    require(env.get('RELEASE_SHA') == SOURCE and env.get('RELEASE_VERSION') == VERSION,
            'Recovery is limited to the original immutable 1.0 source')
    require(env.get('RECOVERY_AUTHORIZED') == 'true',
            'Release authorization with documented manual-coverage limits is required')
    require(env.get('GITHUB_RUN_ATTEMPT') == '1',
            'Recovery reruns require inspection of the earlier signing outcome')
    return sha


def verify_source():
    workflow_sha = validate_dispatch(os.environ)
    workspace = Path(os.environ['GITHUB_WORKSPACE']).resolve()
    source = Path(os.environ['STENO_RELEASE_SOURCE_ROOT'])
    require(source.is_absolute() and source.resolve() == workspace / 'Steno',
            'Release source must be the separate workspace/Steno checkout')
    require(CONTROL == workspace / 'control', 'Recovery control checkout is misplaced')
    for directory, sha in [(CONTROL, workflow_sha), (source, SOURCE)]:
        require(command('git', '-C', str(directory), 'rev-parse', 'HEAD') == sha,
                'Checkout identity mismatch')
        require(command('git', '-C', str(directory), 'rev-parse', '--show-toplevel')
                == str(directory), 'Checkout root mismatch')
        require(not command('git', '-C', str(directory), 'status', '--porcelain'),
                'Release checkouts must be clean')
    guard = module('release-guard')
    guard.validate_source(source, VERSION, SOURCE)
    guard.validate_remote(REPOSITORY, VERSION, SOURCE)
    require(api('commits/main')['sha'] == workflow_sha,
            'Main advanced after recovery dispatch; review the workflow source again')
    for path in UNCHANGED_INPUTS:
        require(command('git', '-C', str(CONTROL), 'rev-parse', SOURCE + ':' + path)
                == command('git', '-C', str(CONTROL), 'rev-parse', workflow_sha + ':' + path),
                'Recovery must retain the tested provisioning and publication guards')
    return workflow_sha


def require_no_release(releases):
    require(not any(r['tag_name'] == 'v' + VERSION for r in releases),
            'A release or draft already exists; inspect it rather than creating another')


def require_no_prior_recovery(runs, jobs_for_run, current_run):
    for run in runs:
        if run['id'] == current_run:
            continue
        for job in jobs_for_run(run['id']):
            if job['name'] == 'sign' and job.get('started_at') and job.get('conclusion') != 'skipped':
                raise ValueError('A prior recovery reached signing; inspect its outcome before another submission')


def preflight():
    verify_source()
    receipt = validation_receipt()
    require_no_prior_recovery(
        pages('actions/workflows/recover-release.yml/runs?per_page=100', 'workflow_runs'),
        lambda number: pages(f'actions/runs/{number}/jobs?filter=all&per_page=100', 'jobs'),
        int(os.environ['GITHUB_RUN_ID']))
    require_no_release(pages('releases?per_page=100'))
    destination = Path(os.environ.get('STENO_REUSED_VALIDATION_RECEIPT_JSON',
        str(Path(os.environ['RUNNER_TEMP']) / 'steno-reused-validation.json')))
    require(destination.is_absolute() and destination.parent.resolve()
            == Path(os.environ['RUNNER_TEMP']).resolve(), 'Invalid receipt destination')
    destination.write_text(json.dumps(receipt, indent=2) + '\n')
    print('Verified original source checks and both reviewed pre-notarization failures.')


def validate_manifest(manifest, workflow_sha, receipt, run_id):
    expected = {
        'workflow_source_sha': workflow_sha, 'producing_workflow': WORKFLOW,
        'validation_run': RUN, 'validation_attempt': 1, 'validation_receipt': receipt,
        'workflow_run': f'https://github.com/{REPOSITORY}/actions/runs/{run_id}',
    }
    require(all(manifest.get(k) == v for k, v in expected.items()),
            'Recovery manifest does not bind the exact source, workflow, and reused checks')


def verify_assets():
    workflow_sha = verify_source()
    receipt = validation_receipt()
    root = Path(os.environ.get('RELEASE_ASSETS',
        str(Path(os.environ['RUNNER_TEMP']) / 'steno-release-assets')))
    require(root.is_absolute() and not root.is_symlink(), 'Invalid release asset root')
    publisher = module('release-publish')
    assets = publisher.validate_assets(root, VERSION, SOURCE)
    manifest = json.loads((root / 'release-manifest.json').read_text())
    validate_manifest(manifest, workflow_sha, receipt, os.environ['GITHUB_RUN_ID'])
    # Attestations bind orchestration K. The separately attested manifest binds
    # the immutable app S and DMG digest; these identities must not be conflated.
    for filename in [f'Steno-{VERSION}.dmg', 'release-manifest.json']:
        subprocess.run(['gh', 'attestation', 'verify', str(root / filename),
                        '--repo', REPOSITORY, '--signer-workflow', WORKFLOW,
                        '--signer-digest', workflow_sha, '--source-ref', 'refs/heads/main',
                        '--source-digest', workflow_sha], check=True)
    return publisher, assets


def release_notes():
    document = (CONTROL / 'docs/release/signing-recovery.md').read_text()
    start, end = '<!-- release-notes:start -->', '<!-- release-notes:end -->'
    require(document.count(start) == document.count(end) == 1, 'Release notes markers missing')
    notes = document.split(start)[1].split(end)[0].strip()
    require(bool(notes) and '{{' not in notes, 'Release notes are incomplete')
    return notes


def draft():
    publisher, assets = verify_assets()
    require_no_release(pages('releases?per_page=100'))
    notes = release_notes()
    notes_path = Path(os.environ['RUNNER_TEMP']) / 'steno-reviewed-release-notes.md'
    notes_path.write_text(notes + '\n')
    subprocess.run(['gh', 'release', 'create', 'v' + VERSION, '--repo', REPOSITORY,
                    '--verify-tag', '--target', SOURCE, '--draft', '--title', 'Steno ' + VERSION,
                    '--notes-file', str(notes_path), *assets], check=True)
    result = api('releases/tags/v' + VERSION)
    release_id = str(result['id'])
    publisher.verify_remote_assets(result, assets, SOURCE, release_id)
    require(result['tag_name'] == 'v' + VERSION and result['body'].strip() == notes,
            'Draft identity or reviewed notes changed')
    with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
        stream.write('release_id=' + release_id + '\n')
    print('Verified draft: ' + result['html_url'])


def publish():
    publisher, assets = verify_assets()
    release_id = os.environ['RELEASE_ID']
    publisher.validate_release_request(REPOSITORY, VERSION, SOURCE, release_id)
    result = publisher.release_receipt(REPOSITORY, release_id)
    require(result.get('body', '').strip() == release_notes(),
            'Draft notes changed after review; publication stopped')
    publisher.publish_existing(REPOSITORY, VERSION, SOURCE, assets)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['preflight', 'verify-assets', 'draft', 'publish'])
    args = parser.parse_args()
    {'preflight': preflight, 'verify-assets': verify_assets,
     'draft': draft, 'publish': publish}[args.command]()


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f'Recovery stopped: {error}. Inspect existing outcomes before retrying.')
