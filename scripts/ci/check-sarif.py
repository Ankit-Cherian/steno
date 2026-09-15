#!/usr/bin/env python3
"""Fail CodeQL scans with high/critical findings or unusable scan evidence.

This checks generated SARIF locally, including existing and suppressed findings.
Uploading results remains useful for triage, but upload success does not satisfy
this gate. A missing expected analysis category also fails closed.
"""

import argparse
import hashlib
import json
import math
import re
from pathlib import Path
import sys


class ScanError(ValueError):
    pass


def object_value(value, label):
    if not isinstance(value, dict):
        raise ScanError(f'{label} must be an object')
    return value


def array_value(value, label):
    if not isinstance(value, list):
        raise ScanError(f'{label} must be an array')
    return value


def finding_context(result, run):
    """Keep the generated result location visible even if upload filters it."""
    locations = []
    for location in result.get('locations', []):
        physical = location.get('physicalLocation', {})
        artifact = physical.get('artifactLocation', {})
        uri = artifact.get('uri')
        index = artifact.get('index')
        artifacts = run.get('artifacts', [])
        if uri is None and type(index) is int and 0 <= index < len(artifacts):
            uri = artifacts[index].get('location', {}).get('uri')
        region = physical.get('region', {})
        locations.append({'uri': uri, 'uriBaseId': artifact.get('uriBaseId'),
                          'line': region.get('startLine'), 'column': region.get('startColumn')})
    # Encode newlines/control characters so scanner text remains one log line.
    return json.dumps({'locations': locations, 'message': result.get('message', {})},
                      ensure_ascii=True, sort_keys=True)


# The launch and permission contracts underlying these local-file dispositions.
# A change to any of them requires a fresh review, even when a sink stays put.
REVIEW_CONTRACTS = (
    'runtime-helper/steno_whisper_runtime.cpp',
    'StenoKit/Sources/StenoKit/Services/ProcessWhisperRuntimeSession.swift',
    'StenoKit/Sources/StenoKit/Services/WhisperRuntimeConfiguration.swift',
    'StenoKit/Sources/StenoKit/Services/WhisperCLITranscriptionEngine.swift',
    'StenoKit/Sources/StenoKit/Utilities/ProcessRunner.swift',
    'StenoKit/Sources/StenoKit/Services/MacAudioCaptureService.swift',
    'StenoKit/Sources/StenoKit/Services/SessionCoordinator.swift',
    'Steno/DictationController.swift',
    'Steno/Steno.entitlements',
    'Steno/StenoDistribution.entitlements',
    'project.yml',
    'scripts/build-whisper-runtime-helper.sh',
    'scripts/release-dmg.sh',
    'scripts/ci/patches/whisper-security.patch',
)


def exact_keys(value, keys, label):
    value = object_value(value, label)
    if set(value) != set(keys):
        raise ScanError(f'{label} has missing or unknown fields')
    return value


def relative_source_path(value):
    # Do not decode URIs, collapse traversal, erase build identities, or glob.
    if (not isinstance(value, str) or not value or
            not re.fullmatch(r'[A-Za-z0-9_./-]+', value) or
            any(part in ('', '.', '..') for part in value.split('/'))):
        raise ScanError('reviewed source location must be an exact relative path')
    return value


def source_digest(root, relative):
    relative_source_path(relative)
    target = root
    for part in relative.split('/'):
        target = target / part
        if target.is_symlink():
            raise ScanError(f'reviewed source cannot traverse a symlink: {relative}')
    if not target.is_file():
        raise ScanError(f'reviewed source file is missing: {relative}')
    return hashlib.sha256(target.read_bytes()).hexdigest()


def artifact_uri(artifact, run):
    artifact = object_value(artifact, 'reviewed artifact')
    uri = artifact.get('uri')
    if 'index' in artifact:
        index = artifact['index']
        artifacts = array_value(run.get('artifacts', []), 'artifacts')
        if type(index) is not int or not 0 <= index < len(artifacts):
            raise ScanError('reviewed artifact index is invalid')
        indexed = object_value(object_value(artifacts[index], 'indexed artifact').get('location'), 'indexed artifact location')
        if uri is not None and uri != indexed.get('uri'):
            raise ScanError('reviewed artifact URI and index disagree')
        if ('uriBaseId' in artifact and 'uriBaseId' in indexed and
                artifact['uriBaseId'] != indexed['uriBaseId']):
            raise ScanError('reviewed artifact URI bases disagree')
        uri = indexed.get('uri')
        if indexed.get('uriBaseId') not in (None, '%SRCROOT%'):
            raise ScanError('reviewed artifact has an unsupported URI base')
    if artifact.get('uriBaseId') not in (None, '%SRCROOT%'):
        raise ScanError('reviewed artifact has an unsupported URI base')
    return uri


def explicit_end_line(region):
    # SARIF 2.1.0 section 3.30.7: an omitted endLine equals startLine.
    # Preserve explicit values and every other field for exact identity checks.
    normalized = dict(object_value(region, 'region'))
    if 'endLine' not in normalized:
        normalized['endLine'] = normalized.get('startLine')
    return normalized


def reviewed_location(result, run):
    locations = array_value(result.get('locations'), 'reviewed locations')
    if len(locations) != 1:
        raise ScanError('reviewed finding must have exactly one primary location')
    physical = object_value(object_value(locations[0], 'location').get('physicalLocation'), 'physicalLocation')
    artifact = object_value(physical.get('artifactLocation'), 'artifactLocation')
    uri = artifact_uri(artifact, run)
    region = explicit_end_line(physical.get('region'))
    position = {key: region.get(key) for key in ('startLine', 'startColumn', 'endLine', 'endColumn')}
    if any(type(value) is not int or value < 1 for value in position.values()):
        raise ScanError('reviewed location must have a complete positive source range')
    return {'path': relative_source_path(uri), **position}


def canonical_flow(value, run, paths):
    # Artifact array indices are output bookkeeping, not source identity.
    # All explicit paths and source ranges in the actual trace remain bound.
    if isinstance(value, list):
        return [canonical_flow(item, run, paths) for item in value]
    if isinstance(value, dict):
        result = {}
        for key, child in value.items():
            if key == 'artifactLocation':
                artifact = object_value(child, 'trace artifact')
                uri = artifact_uri(artifact, run)
                if isinstance(uri, str) and uri.startswith('file:///'):
                    # Toolchain headers are trace identity only. Never open an
                    # absolute scanner-supplied path or claim its content was hashed.
                    if not re.fullmatch(r'file:///[A-Za-z0-9_./+-]+', uri) or '..' in uri.split('/'):
                        raise ScanError('reviewed trace has an invalid external source URI')
                else:
                    uri = relative_source_path(uri)
                    paths.add(uri)
                result[key] = {'uri': uri}
            elif key == 'physicalLocation':
                physical = canonical_flow(object_value(child, 'trace physical location'), run, paths)
                if 'region' in physical:
                    physical['region'] = explicit_end_line(physical['region'])
                result[key] = physical
            else:
                result[key] = canonical_flow(child, run, paths)
        return result
    return value


def reviewed_identity(identifier, severity, result, run):
    location = reviewed_location(result, run)
    paths = {location['path']}
    flows = array_value(result.get('codeFlows'), 'reviewed codeFlows')
    if not flows:
        raise ScanError('reviewed finding requires its actual source-to-sink trace')
    identity = {
        'rule': identifier, 'severity': severity, 'location': location,
        'message': object_value(result.get('message'), 'reviewed message'),
        'codeFlows': canonical_flow(flows, run, paths),
    }
    digest = hashlib.sha256(json.dumps(identity, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode()).hexdigest()
    return location, digest, paths


def duplicate_checked_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ScanError(f'duplicate JSON field: {key}')
        value[key] = item
    return value


def apply_dispositions(records, receipt, root, reviewed):
    exact_keys(receipt, ('schema_version', 'category', 'status', 'reviewed_commit', 'findings'), 'disposition receipt')
    if (type(receipt['schema_version']) is not int or receipt['schema_version'] != 1 or
            receipt['category'] != '/language:c-cpp' or receipt['status'] != 'accepted' or
            not isinstance(receipt['reviewed_commit'], str) or
            not re.fullmatch(r'[0-9a-f]{40}', receipt['reviewed_commit'])):
        raise ScanError('disposition receipt is not an accepted, versioned C++ review')
    entries = array_value(receipt['findings'], 'reviewed findings')
    if not 1 <= len(entries) <= 4:
        raise ScanError('disposition receipt must contain one to four individual findings')
    pending = {}
    for entry in entries:
        exact_keys(entry, ('id', 'classification', 'rule', 'location', 'identity_sha256', 'source_sha256', 'rationale', 'reassess_when'), 'reviewed finding')
        for field in ('id', 'rationale', 'reassess_when'):
            if not isinstance(entry[field], str) or not entry[field].strip():
                raise ScanError(f'reviewed finding requires {field}')
        if entry['classification'] != 'not_actionable_in_supported_deployment':
            raise ScanError('reviewed finding requires a supported-deployment technical classification')
        if entry['rule'] != 'cpp/path-injection':
            raise ScanError('only individually reviewed local file findings are supported')
        location = exact_keys(entry['location'], ('path', 'startLine', 'startColumn', 'endLine', 'endColumn'), 'reviewed source range')
        relative_source_path(location['path'])
        if any(type(location[field]) is not int or location[field] < 1 for field in ('startLine', 'startColumn', 'endLine', 'endColumn')):
            raise ScanError('reviewed source range must contain positive integers')
        digest = entry['identity_sha256']
        if not isinstance(digest, str) or not re.fullmatch(r'[0-9a-f]{64}', digest) or digest in pending:
            raise ScanError('reviewed identities must be valid and unique')
        if any(other['id'] == entry['id'] or other['location'] == location for other in pending.values()):
            raise ScanError('reviewed IDs and locations must be unique')
        sources = object_value(entry['source_sha256'], 'reviewed source hashes')
        if not set(REVIEW_CONTRACTS).union({location['path']}) <= set(sources):
            raise ScanError('reviewed source hashes omit a source or launch contract')
        for path, expected in sources.items():
            if not isinstance(expected, str) or not re.fullmatch(r'[0-9a-f]{64}', expected):
                raise ScanError('reviewed source hash must be a SHA-256 digest')
            if source_digest(root, path) != expected:
                raise ScanError(f'reviewed source changed; reassessment required: {path}')
        pending[digest] = entry
    blocked = []
    consumed = set()
    for identifier, severity, result, run, text in records:
        if identifier != 'cpp/path-injection':
            blocked.append(text)
            continue
        location, digest, paths = reviewed_identity(identifier, severity, result, run)
        entry = pending.get(digest)
        if entry is None:
            blocked.append(text)
            continue
        if digest in consumed:
            raise ScanError('multiple findings match one reviewed disposition')
        if entry['location'] != location or not paths <= set(entry['source_sha256']):
            raise ScanError('reviewed finding omits a traced source or mismatches its location')
        consumed.add(digest)
        reviewed.append('Security gate reviewed disposition: ' + json.dumps({
            'id': entry['id'], 'classification': entry['classification'],
            'finding': text, 'rationale': entry['rationale'],
            'reassess_when': entry['reassess_when'], 'identity_sha256': digest,
        }, ensure_ascii=True, sort_keys=True))
    if consumed != set(pending):
        raise ScanError('reviewed finding absent or changed; reassessment required')
    return blocked


def inspect_sarif(document, category, records=None):
    document = object_value(document, 'SARIF document')
    if document.get('version') != '2.1.0':
        raise ScanError('expected SARIF version 2.1.0')
    runs = array_value(document.get('runs'), 'runs')
    if not runs:
        raise ScanError('SARIF contains no analysis runs')
    findings = []
    matched = False
    for run in runs:
        run = object_value(run, 'run')
        tool = object_value(run.get('tool'), 'tool')
        driver = object_value(tool.get('driver'), 'driver')
        if driver.get('name') not in ('CodeQL', 'CodeQL command-line toolchain'):
            raise ScanError('expected CodeQL scan evidence')
        automation = object_value(run.get('automationDetails'), 'automationDetails')
        identifier = automation.get('id')
        if not isinstance(identifier, str) or not (identifier == category or identifier.startswith(category + '/')):
            raise ScanError(f'analysis category does not match {category}: {identifier}')
        matched = True
        for invocation in array_value(run.get('invocations', []), 'invocations'):
            invocation = object_value(invocation, 'invocation')
            if invocation.get('executionSuccessful') is not True:
                raise ScanError('CodeQL reported an unsuccessful invocation')
            for notification in invocation.get('toolExecutionNotifications', []):
                if object_value(notification, 'notification').get('level') == 'error':
                    raise ScanError('CodeQL reported an execution error')
        extensions = array_value(tool.get('extensions', []), 'tool.extensions')
        components = [driver] + extensions
        rule_maps = []
        for component in components:
            component = object_value(component, 'tool component')
            rule_map = {}
            for rule in array_value(component.get('rules', []), 'component.rules'):
                rule = object_value(rule, 'rule')
                identifier = rule.get('id')
                if not isinstance(identifier, str) or not identifier or identifier in rule_map:
                    raise ScanError('rule IDs must be nonempty and unique within a component')
                rule_map[identifier] = rule
            rule_maps.append(rule_map)
        if not any(rule_maps):
            raise ScanError('CodeQL evidence contains no query rules')
        results = array_value(run.get('results'), 'results')
        for result in results:
            result = object_value(result, 'result')
            descriptor = object_value(result.get('rule', {}), 'result.rule')
            component_ref = object_value(descriptor.get('toolComponent', {}), 'rule.toolComponent')
            component_index = 0
            if component_ref:
                extension_index = component_ref.get('index')
                if type(extension_index) is not int or extension_index < 0 or extension_index >= len(extensions):
                    raise ScanError('result refers to an invalid tool extension')
                component_index = extension_index + 1
                for field in ('name', 'guid'):
                    if field in component_ref and component_ref[field] != components[component_index].get(field):
                        raise ScanError('tool extension identity and index disagree')
            rules = components[component_index].get('rules', [])
            rule_map = rule_maps[component_index]
            identifier = descriptor.get('id', result.get('ruleId'))
            if 'id' in descriptor and 'ruleId' in result and descriptor['id'] != result['ruleId']:
                raise ScanError('result rule identities disagree')
            rule = rule_map.get(identifier) if isinstance(identifier, str) else None
            index = descriptor.get('index', result.get('ruleIndex'))
            if index is not None:
                if type(index) is not int or index < 0 or index >= len(rules):
                    raise ScanError('result refers to an invalid rule index')
                indexed = rules[index]
                if identifier is not None and indexed['id'] != identifier:
                    raise ScanError('result rule ID and index disagree')
                rule = indexed
                identifier = rule['id']
            if rule is None:
                raise ScanError('result has no resolvable rule')
            properties = object_value(rule.get('properties', {}), 'rule.properties')
            security = properties.get('security-severity')
            tags = array_value(properties.get('tags', []), 'rule tags')
            if security is None and 'security' in tags:
                raise ScanError(f'security rule {identifier} has no security severity')
            if security is not None:
                try:
                    severity = float(security)
                except (TypeError, ValueError) as error:
                    raise ScanError(f'invalid severity for {identifier}') from error
                if isinstance(security, bool) or not math.isfinite(severity) or not 0 <= severity <= 10:
                    raise ScanError(f'invalid severity for {identifier}')
                if severity >= 7:
                    text = f'{identifier}: security severity {severity:g} {finding_context(result, run)}'
                    findings.append(text)
                    if records is not None:
                        records.append((identifier, severity, result, run, text))
            else:
                default = object_value(rule.get('defaultConfiguration', {}), 'defaultConfiguration')
                level = result.get('level', default.get('level', 'warning'))
                if level not in ('none', 'note', 'warning', 'error'):
                    raise ScanError(f'invalid result level for {identifier}')
                if level == 'error':
                    text = f'{identifier}: error-level finding {finding_context(result, run)}'
                    findings.append(text)
                    if records is not None:
                        records.append((identifier, None, result, run, text))
    if not matched:
        raise ScanError(f'missing expected analysis category {category}')
    return findings


def check_directory(directory, category, dispositions=None, source_root=None, reviewed=None):
    paths = sorted(directory.glob('*.sarif'))
    if not paths:
        raise ScanError(f'no SARIF files found in {directory}')
    findings = []
    records = []
    for path in paths:
        try:
            document = json.loads(path.read_text(), object_pairs_hook=duplicate_checked_object)
        except (OSError, ValueError) as error:
            raise ScanError(f'cannot read valid SARIF from {path.name}') from error
        findings.extend(inspect_sarif(document, category, records))
    if dispositions is not None:
        if category != '/language:c-cpp' or source_root is None or reviewed is None:
            raise ScanError('dispositions require C++ category, source root, and visible review output')
        try:
            receipt = json.loads(dispositions.read_text(), object_pairs_hook=duplicate_checked_object)
        except (OSError, ValueError) as error:
            raise ScanError('cannot read valid disposition receipt') from error
        return apply_dispositions(records, receipt, source_root.resolve(), reviewed)
    return findings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', required=True, type=Path)
    parser.add_argument('--category', required=True)
    parser.add_argument('--reviewed-dispositions', type=Path)
    parser.add_argument('--source-root', type=Path)
    args = parser.parse_args()
    reviewed = []
    try:
        findings = check_directory(args.directory, args.category, args.reviewed_dispositions, args.source_root, reviewed)
    except (ScanError, OSError) as error:
        print(f'Security gate failed: {error}', file=sys.stderr)
        return 1
    for disposition in reviewed:
        print(disposition)
    if findings:
        for finding in findings:
            print(f'Security gate blocked: {finding}', file=sys.stderr)
        return 1
    if reviewed:
        print(f'Security severity gate passed for {args.category} with {len(reviewed)} individually reviewed dispositions shown above.')
    else:
        print(f'Security severity gate passed for {args.category}. Review lower-severity findings in code scanning.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
