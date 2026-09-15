#!/usr/bin/env python3
"""Fail CodeQL scans with high/critical findings or unusable scan evidence.

This checks generated SARIF locally, including existing and suppressed findings.
Uploading results remains useful for triage, but upload success does not satisfy
this gate. A missing expected analysis category also fails closed.
"""

import argparse
import json
import math
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


def inspect_sarif(document, category):
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
                    findings.append(f'{identifier}: security severity {severity:g} {finding_context(result, run)}')
            else:
                default = object_value(rule.get('defaultConfiguration', {}), 'defaultConfiguration')
                level = result.get('level', default.get('level', 'warning'))
                if level not in ('none', 'note', 'warning', 'error'):
                    raise ScanError(f'invalid result level for {identifier}')
                if level == 'error':
                    findings.append(f'{identifier}: error-level finding {finding_context(result, run)}')
    if not matched:
        raise ScanError(f'missing expected analysis category {category}')
    return findings


def check_directory(directory, category):
    paths = sorted(directory.glob('*.sarif'))
    if not paths:
        raise ScanError(f'no SARIF files found in {directory}')
    findings = []
    for path in paths:
        try:
            document = json.loads(path.read_text())
        except (OSError, ValueError) as error:
            raise ScanError(f'cannot read valid SARIF from {path.name}') from error
        findings.extend(inspect_sarif(document, category))
    return findings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', required=True, type=Path)
    parser.add_argument('--category', required=True)
    args = parser.parse_args()
    try:
        findings = check_directory(args.directory, args.category)
    except (ScanError, OSError) as error:
        print(f'Security gate failed: {error}', file=sys.stderr)
        return 1
    if findings:
        for finding in findings:
            print(f'Security gate blocked: {finding}', file=sys.stderr)
        return 1
    print(f'Security severity gate passed for {args.category}. Review lower-severity findings in code scanning.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
