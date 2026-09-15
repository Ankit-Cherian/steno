#!/usr/bin/env python3
"""Enforce Steno's small, reviewable workflow format and security invariants.

This is intentionally a restricted YAML reader, not a general YAML implementation
or a replacement for actionlint/CodeQL. Unsupported structural syntax fails closed:
block maps/sequences and scalar flow lists are supported; aliases, tags, duplicate
keys, flow maps (except {}), and multiline quoted scalars are not. Keep workflow
structure explicit so security checks cannot silently miss YAML indirection.
"""

import argparse
import json
from pathlib import Path
import re
import sys


class PolicyError(ValueError):
    pass


def uncomment(text):
    quote = None
    escaped = False
    for index, char in enumerate(text):
        if escaped:
            escaped = False
        elif quote == '"' and char == '\\':
            escaped = True
        elif char in "\"'":
            if quote == char:
                quote = None
            elif quote is None:
                quote = char
        elif char == '#' and quote is None and (index == 0 or text[index - 1].isspace()):
            return text[:index].rstrip()
    if quote:
        raise PolicyError("multiline or unclosed quoted scalar is unsupported")
    return text.rstrip()


def scalar(text):
    text = text.strip()
    if not text:
        return None
    if text == '{}':
        return {}
    if text[0] == '"':
        try:
            value = json.loads(text)
        except ValueError as error:
            raise PolicyError(f"unsupported quoted scalar: {text}") from error
        if not isinstance(value, str):
            raise PolicyError("quoted scalar must be a string")
        return value
    if text[0] == "'":
        if not text.endswith("'"):
            raise PolicyError("unclosed quoted scalar")
        return text[1:-1].replace("''", "'")
    if text[0] == '[':
        if not text.endswith(']'):
            raise PolicyError("multiline flow lists are unsupported")
        # Flow lists are limited to simple scalars, with no embedded comma.
        items = [scalar(item) for item in text[1:-1].split(',') if item.strip()]
        if any(not isinstance(item, str) for item in items):
            raise PolicyError("flow lists must contain scalar strings")
        return items
    if text[0] in '*&!{>|' or text.startswith(('---', '...', '%')):
        raise PolicyError(f"unsupported YAML indirection or structure: {text}")
    return text


def parse_workflow(source):
    """Read explicit workflow structure, preserving block scalar bodies as text."""
    tokens = []
    lines = source.splitlines()
    index = 0
    while index < len(lines):
        raw = lines[index]
        number = index + 1
        index += 1
        if not raw.strip() or raw.lstrip().startswith('#'):
            continue
        if '\t' in raw[:len(raw) - len(raw.lstrip())]:
            raise PolicyError(f"line {number}: tab indentation is unsupported")
        indent = len(raw) - len(raw.lstrip(' '))
        text = uncomment(raw.strip())
        block = re.search(r':\s*([|>][+-]?)$', text)
        body = None
        if block:
            body_lines = []
            while index < len(lines):
                following = lines[index]
                depth = len(following) - len(following.lstrip(' '))
                if following.strip() and depth <= indent:
                    break
                body_lines.append(following)
                index += 1
            body = '\n'.join(body_lines)
            text = text[:block.start()] + ':'
        if text.startswith('- '):
            tokens.append((indent, '-', number, None))
            text = text[2:].strip()
            indent += 2
        tokens.append((indent, text, number, body))

    position = 0

    def read(depth):
        nonlocal position
        sequence = tokens[position][1] == '-'
        result = [] if sequence else {}
        while position < len(tokens) and tokens[position][0] == depth:
            _, text, number, body = tokens[position]
            position += 1
            if sequence:
                if text != '-':
                    raise PolicyError(f"line {number}: mixed sequence and map")
                if position >= len(tokens) or tokens[position][0] <= depth:
                    raise PolicyError(f"line {number}: empty sequence item")
                next_text = tokens[position][1]
                if not re.match(r"(?:[A-Za-z0-9_-]+|'[A-Za-z0-9_-]+'|\"[A-Za-z0-9_-]+\"):", next_text):
                    result.append(scalar(next_text))
                    position += 1
                else:
                    result.append(read(tokens[position][0]))
                continue
            match = re.fullmatch(r"([A-Za-z0-9_-]+|'[A-Za-z0-9_-]+'|\"[A-Za-z0-9_-]+\"):\s*(.*)", text)
            if not match:
                raise PolicyError(f"line {number}: expected an explicit mapping key")
            key = scalar(match.group(1))
            if key in result:
                raise PolicyError(f"line {number}: duplicate key {key}")
            value = body if body is not None else scalar(match.group(2))
            if position < len(tokens) and tokens[position][0] > depth:
                if value is not None:
                    raise PolicyError(f"line {number}: scalar has unexpected nested structure")
                value = read(tokens[position][0])
            result[key] = value
        return result

    if not tokens or tokens[0][0] != 0:
        raise PolicyError("workflow must start with a top-level mapping")
    result = read(0)
    if position != len(tokens) or not isinstance(result, dict):
        raise PolicyError("unsupported indentation or trailing structure")
    return result


PINNED_ACTION = re.compile(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-fA-F]{40}')
ALLOWED_EVENTS = {'push', 'pull_request', 'merge_group', 'schedule', 'workflow_dispatch', 'workflow_call'}


def check_workflow(source):
    try:
        workflow = parse_workflow(source)
    except PolicyError as error:
        return [str(error)]
    errors = []
    events = workflow.get('on')
    if isinstance(events, str):
        events = [events]
    if not isinstance(events, (dict, list)) or not events:
        errors.append('on must explicitly declare allowed workflow events')
        events = []
    for event in events:
        if event not in ALLOWED_EVENTS:
            errors.append(f'forbidden workflow trigger: {event}')
    permissions = workflow.get('permissions')
    if not isinstance(permissions, dict):
        errors.append('workflow must declare explicit least-privilege permissions')
    elif any(value != 'read' for value in permissions.values()):
        errors.append('workflow-level permissions must be read-only; elevate individual jobs')

    def action(value, location):
        if not isinstance(value, str):
            errors.append(f'{location}: uses must be a scalar')
        elif value.startswith('./'):
            if '..' in value.split('/') or '${{' in value:
                errors.append(f'{location}: unsafe local action path')
        elif not PINNED_ACTION.fullmatch(value):
            errors.append(f'{location}: remote actions/workflows must use a full commit SHA')

    jobs = workflow.get('jobs')
    if not isinstance(jobs, dict) or not jobs:
        return errors + ['workflow must contain explicit jobs']
    for name, job in jobs.items():
        if not isinstance(job, dict):
            errors.append(f'{name}: job must be an explicit mapping')
            continue
        grant = job.get('permissions', {})
        if not isinstance(grant, dict) or any(value not in ('read', 'write', 'none') for value in grant.values()):
            errors.append(f'{name}: permissions must be an explicit scope map')
        if 'uses' in job:
            action(job['uses'], name)
            continue
        timeout = job.get('timeout-minutes', '')
        if not isinstance(timeout, str) or not re.fullmatch(r'[1-9][0-9]*', timeout) or int(timeout) > 120:
            errors.append(f'{name}: explicit timeout-minutes between 1 and 120 is required')
        runner = job.get('runs-on', '')
        runners = [runner]
        matrix_runner = re.fullmatch(r'\$\{\{\s*matrix\.([A-Za-z0-9_-]+)\s*\}\}', runner) if isinstance(runner, str) else None
        if matrix_runner:
            strategy = job.get('strategy', {})
            matrix = strategy.get('matrix', {}) if isinstance(strategy, dict) else {}
            runners = matrix.get(matrix_runner.group(1), []) if isinstance(matrix, dict) else []
            if 'include' in matrix:
                errors.append(f'{name}: runner matrices must use explicit scalar lists, without include overrides')
        if not isinstance(runners, list) or not runners or any(value not in ('ubuntu-24.04', 'macos-15', 'macos-15-intel', 'macos-26') for value in runners):
            errors.append(f'{name}: use an explicit approved GitHub-hosted runner')
        steps = job.get('steps')
        if not isinstance(steps, list):
            errors.append(f'{name}: explicit steps are required')
            continue
        for index, step in enumerate(steps):
            location = f'{name} step {index + 1}'
            if not isinstance(step, dict):
                errors.append(f'{location}: step must be a mapping')
                continue
            if 'uses' in step:
                action(step['uses'], location)
                reference = step['uses'].split('@', 1)[0].lower() if isinstance(step['uses'], str) else ''
                if reference in ('github/codeql-action/init', 'github/codeql-action/analyze'):
                    environment = {}
                    for scope in (workflow, job, step):
                        values = scope.get('env', {})
                        if not isinstance(values, dict):
                            errors.append(f'{location}: CodeQL env must be an explicit mapping')
                        else:
                            environment.update(values)
                    if environment.get('CODEQL_ACTION_DIFF_INFORMED_QUERIES') != 'false':
                        errors.append(f'{location}: CodeQL must set CODEQL_ACTION_DIFF_INFORMED_QUERIES to literal false for full-source analysis')
                if isinstance(step['uses'], str) and step['uses'].lower().startswith('actions/checkout@'):
                    settings = step.get('with', {})
                    if not isinstance(settings, dict) or settings.get('persist-credentials') != 'false':
                        errors.append(f'{location}: checkout must set persist-credentials: false')
            run = step.get('run', '')
            if isinstance(run, str) and re.search(r'\$\{\{[^}]*github\.event\.', run):
                errors.append(f'{location}: pass event data through env, never interpolate it into shell source')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('paths', nargs='*', type=Path)
    args = parser.parse_args()
    paths = args.paths or sorted(Path('.github/workflows').glob('*.y*ml'))
    if not paths:
        print('No workflow files found.', file=sys.stderr)
        return 1
    count = 0
    for path in paths:
        for error in check_workflow(path.read_text()):
            print(f'{path}: {error}', file=sys.stderr)
            count += 1
    if count:
        return 1
    print(f'Workflow policy passed for {len(paths)} files.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
