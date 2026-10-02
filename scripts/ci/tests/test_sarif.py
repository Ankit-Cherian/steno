"""Code scanning completion must not be confused with a clean severity gate."""

from copy import deepcopy
import hashlib
import importlib.util
import json
import subprocess
import sys
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location('sarif_gate', Path(__file__).parents[1] / 'check-sarif.py')
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)
CATEGORY = '/language:swift'
DOCUMENT = {
    'version': '2.1.0',
    'runs': [{
        'automationDetails': {'id': CATEGORY + '/'},
        'tool': {'driver': {'name': 'CodeQL', 'rules': [
            {'id': 'swift/test-rule', 'properties': {'security-severity': '8.1', 'tags': ['security']}}
        ]}},
        'invocations': [{'executionSuccessful': True}],
        'results': [],
    }],
}


class SarifGateTests(unittest.TestCase):
    def setUp(self):
        self.document = deepcopy(DOCUMENT)
        self.run = self.document['runs'][0]
        self.rule = self.run['tool']['driver']['rules'][0]

    def finding(self, **extra):
        self.run['results'].append({'ruleId': 'swift/test-rule', 'ruleIndex': 0, **extra})

    def test_clean_completed_scan_passes(self):
        self.assertEqual(GATE.inspect_sarif(self.document, CATEGORY), [])

    def test_high_critical_and_suppressed_findings_block(self):
        for severity in ('7.0', '8.9', '9.0', '10'):
            self.rule['properties']['security-severity'] = severity
            self.run['results'] = []
            self.finding(suppressions=[{'kind': 'external', 'status': 'accepted'}], baselineState='unchanged')
            self.assertEqual(len(GATE.inspect_sarif(self.document, CATEGORY)), 1)

    def test_blocking_output_preserves_location_and_escapes_scanner_text(self):
        self.finding(
            locations=[{'physicalLocation': {
                'artifactLocation': {'uri': 'vendor/runtime.cpp'},
                'region': {'startLine': 42, 'startColumn': 9},
            }}],
            message={'text': 'Allocation failed\nsecond line'},
        )
        finding, = GATE.inspect_sarif(self.document, CATEGORY)
        context = json.loads(finding[finding.index('{'):])
        self.assertEqual(context['locations'][0]['uri'], 'vendor/runtime.cpp')
        self.assertEqual(context['locations'][0]['line'], 42)
        self.assertEqual(context['locations'][0]['column'], 9)
        self.assertEqual(context['message']['text'], 'Allocation failed\nsecond line')
        self.assertNotIn('\n', finding)

    def test_blocking_output_resolves_indexed_artifact_location(self):
        self.run['artifacts'] = [{'location': {'uri': 'vendor/indexed.cpp'}}]
        self.finding(locations=[{'physicalLocation': {
            'artifactLocation': {'index': 0}, 'region': {'startLine': 7},
        }}])
        finding, = GATE.inspect_sarif(self.document, CATEGORY)
        self.assertIn('vendor/indexed.cpp', finding)

    def test_medium_finding_remains_available_without_blocking(self):
        self.rule['properties']['security-severity'] = '6.9'
        self.finding()
        self.assertEqual(GATE.inspect_sarif(self.document, CATEGORY), [])

    def test_current_codeql_pack_grouped_output_is_resolved(self):
        self.run['tool']['driver'] = {'name': 'CodeQL command-line toolchain'}
        self.run['tool']['extensions'] = [{'name': 'codeql/swift-queries', 'rules': [self.rule]}]
        self.run['results'] = [{'rule': {'id': 'swift/test-rule', 'index': 0, 'toolComponent': {'index': 0, 'name': 'codeql/swift-queries'}}}]
        self.assertEqual(len(GATE.inspect_sarif(self.document, CATEGORY)), 1)
        self.run['results'][0]['rule']['toolComponent']['index'] = 1
        with self.assertRaises(GATE.ScanError):
            GATE.inspect_sarif(self.document, CATEGORY)

    def test_empty_rule_coverage_cannot_claim_clean_scan(self):
        self.run['tool']['driver']['rules'] = []
        with self.assertRaises(GATE.ScanError):
            GATE.inspect_sarif(self.document, CATEGORY)

    def test_nonsecurity_error_blocks(self):
        self.rule['properties'] = {}
        self.finding(level='error')
        self.assertTrue(GATE.inspect_sarif(self.document, CATEGORY))

    def test_missing_or_wrong_tool_category_results_fail(self):
        invalid = [
            {}, {'version': '2.1.0', 'runs': []},
            {**self.document, 'version': '1.0.0'},
        ]
        for document in invalid:
            with self.assertRaises(GATE.ScanError):
                GATE.inspect_sarif(document, CATEGORY)
        for field, replacement in [('results', None), ('automationDetails', {}), ('tool', {'driver': {'name': 'Other', 'rules': []}})]:
            document = deepcopy(DOCUMENT)
            document['runs'][0][field] = replacement
            with self.assertRaises(GATE.ScanError):
                GATE.inspect_sarif(document, CATEGORY)
        with self.assertRaises(GATE.ScanError):
            GATE.inspect_sarif(self.document, '/language:actions')

    def test_rule_index_and_identity_must_resolve(self):
        for result in ({'ruleId': 'unknown'}, {'ruleIndex': 9}, {'ruleIndex': -1}, {'ruleIndex': True}, {'ruleId': 'unknown', 'ruleIndex': 0}):
            self.run['results'] = [result]
            with self.subTest(result=result), self.assertRaises(GATE.ScanError):
                GATE.inspect_sarif(self.document, CATEGORY)

    def test_invalid_or_missing_security_severity_fails(self):
        self.finding()
        for severity in ('NaN', 'Infinity', 'invalid', -1, 11, True, None):
            self.rule['properties']['security-severity'] = severity
            with self.subTest(severity=severity), self.assertRaises(GATE.ScanError):
                GATE.inspect_sarif(self.document, CATEGORY)

    def test_incomplete_invocation_fails(self):
        for invocation in ({}, {'executionSuccessful': False}, {'executionSuccessful': True, 'toolExecutionNotifications': [{'level': 'error'}]}):
            self.run['invocations'] = [invocation]
            with self.assertRaises(GATE.ScanError):
                GATE.inspect_sarif(self.document, CATEGORY)

    def test_missing_or_malformed_file_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(GATE.ScanError):
                GATE.check_directory(root, CATEGORY)
            path = root / 'swift.sarif'
            path.write_text('{broken')
            with self.assertRaises(GATE.ScanError):
                GATE.check_directory(root, CATEGORY)
            path.write_text(json.dumps(DOCUMENT))
            self.assertEqual(GATE.check_directory(root, CATEGORY), [])


class ReviewedDispositionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.path = 'runtime-helper/steno_whisper_runtime.cpp'
        for relative in GATE.REVIEW_CONTRACTS:
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('reviewed source contract\n')
        self.document = deepcopy(DOCUMENT)
        self.run = self.document['runs'][0]
        self.run['automationDetails']['id'] = '/language:c-cpp/'
        self.run['tool']['driver']['rules'][0]['id'] = 'cpp/path-injection'
        self.run['tool']['driver']['rules'][0]['properties']['security-severity'] = '7.5'
        self.location = {'physicalLocation': {
            'artifactLocation': {'uri': self.path, 'uriBaseId': '%SRCROOT%'},
            'region': {'startLine': 3, 'startColumn': 4, 'endLine': 3, 'endColumn': 9},
        }}
        self.result = {'ruleId': 'cpp/path-injection', 'ruleIndex': 0,
            'locations': [deepcopy(self.location)], 'message': {'text': 'Local caller file read'},
            'codeFlows': [{'threadFlows': [{'locations': [{'location': deepcopy(self.location)}]}]}]}
        self.run['results'] = [self.result]
        location, identity, paths = GATE.reviewed_identity('cpp/path-injection', 7.5, self.result, self.run)
        self.entry = {'id': 'local-model', 'classification': 'not_actionable_in_supported_deployment',
            'rule': 'cpp/path-injection', 'location': location,
            'identity_sha256': identity,
            'source_sha256': {path: GATE.source_digest(self.root, path) for path in GATE.REVIEW_CONTRACTS},
            'rationale': 'The caller selects its own local model through its inherited pipe.',
            'reassess_when': 'Source, privilege, invocation, and transport changes require review.'}
        self.receipt = {'schema_version': 1, 'category': '/language:c-cpp', 'status': 'accepted',
            'reviewed_commit': 'a' * 40, 'findings': [self.entry]}

    def apply(self):
        records = []
        GATE.inspect_sarif(self.document, '/language:c-cpp', records)
        reviewed = []
        blocked = GATE.apply_dispositions(records, self.receipt, self.root, reviewed)
        return blocked, reviewed

    def test_exact_review_is_visible_without_modifying_scanner_result(self):
        before = deepcopy(self.document)
        blocked, reviewed = self.apply()
        self.assertEqual(blocked, [])
        self.assertEqual(len(reviewed), 1)
        self.assertIn('security severity 7.5', reviewed[0])
        self.assertIn('rationale', reviewed[0])
        self.assertEqual(self.document, before)

    def test_implicit_same_line_end_preserves_exact_review_identity(self):
        original = deepcopy(self.document)
        for omit_primary, omit_trace in ((True, False), (False, True), (True, True)):
            with self.subTest(primary=omit_primary, trace=omit_trace):
                self.document = deepcopy(original)
                self.run = self.document['runs'][0]
                self.result = self.run['results'][0]
                if omit_primary:
                    del self.result['locations'][0]['physicalLocation']['region']['endLine']
                if omit_trace:
                    del self.result['codeFlows'][0]['threadFlows'][0]['locations'][0]['location']['physicalLocation']['region']['endLine']
                before = deepcopy(self.document)
                blocked, reviewed = self.apply()
                self.assertEqual(blocked, [])
                self.assertEqual(len(reviewed), 1)
                self.assertEqual(self.document, before)

    def test_explicit_invalid_or_changed_end_line_cannot_match(self):
        primary = self.result['locations'][0]['physicalLocation']['region']
        trace = self.result['codeFlows'][0]['threadFlows'][0]['locations'][0]['location']['physicalLocation']['region']
        for region in (primary, trace):
            for value in (None, False, 0, -1, '3', 4):
                with self.subTest(region='primary' if region is primary else 'trace', value=value):
                    region['endLine'] = value
                    with self.assertRaises(GATE.ScanError):
                        self.apply()
                    region['endLine'] = 3

    def test_missing_nondefault_primary_coordinates_still_fail(self):
        region = self.result['locations'][0]['physicalLocation']['region']
        for key in ('startLine', 'startColumn', 'endColumn'):
            with self.subTest(key=key):
                value = region.pop(key)
                with self.assertRaises(GATE.ScanError):
                    self.apply()
                region[key] = value

    def test_proposed_or_malformed_receipt_does_not_authorize_findings(self):
        for field, value in (('status', 'proposed'), ('schema_version', True),
                             ('category', '/language:swift'), ('reviewed_commit', 'main'),
                             ('findings', []), ('unexpected', True)):
            with self.subTest(field=field):
                original = deepcopy(self.receipt)
                self.receipt[field] = value
                with self.assertRaises(GATE.ScanError):
                    self.apply()
                self.receipt = original
                self.entry = self.receipt['findings'][0]

    def test_changed_source_or_launch_contract_requires_reassessment(self):
        for relative in GATE.REVIEW_CONTRACTS:
            with self.subTest(path=relative):
                target = self.root / relative
                original = target.read_bytes()
                target.write_bytes(original + b'changed trust boundary')
                with self.assertRaises(GATE.ScanError):
                    self.apply()
                target.write_bytes(original)

    def test_omitted_contract_missing_file_and_symlink_fail(self):
        relative = GATE.REVIEW_CONTRACTS[1]
        digest = self.entry['source_sha256'].pop(relative)
        with self.assertRaises(GATE.ScanError):
            self.apply()
        self.entry['source_sha256'][relative] = digest
        target = self.root / relative
        contents = target.read_bytes()
        target.unlink()
        with self.assertRaises(GATE.ScanError):
            self.apply()
        other = self.root / 'same-bytes.swift'
        other.write_bytes(contents)
        target.symlink_to(other)
        with self.assertRaises(GATE.ScanError):
            self.apply()

    def test_path_aliases_and_non_source_bases_cannot_match(self):
        artifact = self.result['locations'][0]['physicalLocation']['artifactLocation']
        for path in ('../runtime.cpp', '/tmp/runtime.cpp', './' + self.path,
                     'runtime-helper//steno_whisper_runtime.cpp',
                     'runtime-helper/%2e%2e/steno_whisper_runtime.cpp',
                     'runtime-helper/../runtime-helper/steno_whisper_runtime.cpp'):
            with self.subTest(path=path):
                artifact['uri'] = path
                with self.assertRaises(GATE.ScanError):
                    self.apply()
        artifact['uri'] = self.path
        artifact['uriBaseId'] = 'REMOTE'
        with self.assertRaises(GATE.ScanError):
            self.apply()

    def test_changed_rule_severity_location_message_or_trace_does_not_match(self):
        original = deepcopy(self.document)
        mutations = [
            lambda: self.run['tool']['driver']['rules'][0]['properties'].update({'security-severity': '8.0'}),
            lambda: self.result['locations'][0]['physicalLocation']['region'].update({'startLine': 4}),
            lambda: self.result['message'].update({'text': 'Remote caller file read'}),
            lambda: self.result['codeFlows'][0]['threadFlows'][0]['locations'][0]['location'].update({'message': {'text': 'New input flow'}}),
            lambda: self.run['tool']['driver']['rules'][0].update({'id': 'cpp/other-rule'}),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(mutation=index):
                mutate()
                with self.assertRaises(GATE.ScanError):
                    self.apply()
                self.document = deepcopy(original)
                self.run = self.document['runs'][0]
                self.result = self.run['results'][0]

    def test_duplicate_receipts_duplicate_findings_and_absent_findings_fail(self):
        self.receipt['findings'].append(deepcopy(self.entry))
        with self.assertRaises(GATE.ScanError):
            self.apply()
        self.receipt['findings'].pop()
        self.run['results'].append(deepcopy(self.result))
        with self.assertRaises(GATE.ScanError):
            self.apply()
        self.run['results'] = []
        with self.assertRaises(GATE.ScanError):
            self.apply()

    def test_additional_unreviewed_findings_still_block(self):
        extra = deepcopy(self.result)
        extra['message']['text'] = 'An additional caller controls a path'
        self.run['results'].append(extra)
        blocked, reviewed = self.apply()
        self.assertEqual(len(blocked), 1)
        self.assertEqual(len(reviewed), 1)
        self.assertIn('additional caller', blocked[0])

    def test_sarif_suppression_has_no_authority(self):
        self.result['suppressions'] = [{'kind': 'external', 'status': 'accepted'}]
        self.result['message']['text'] = 'Unreviewed suppressed result'
        with self.assertRaises(GATE.ScanError):
            self.apply()
        self.assertEqual(len(GATE.inspect_sarif(self.document, '/language:c-cpp')), 1)

    def test_multiple_locations_missing_trace_and_invalid_range_fail(self):
        self.result['locations'].append(deepcopy(self.location))
        with self.assertRaises(GATE.ScanError):
            self.apply()
        self.result['locations'].pop()
        self.result['locations'][0]['physicalLocation']['region']['startLine'] = True
        with self.assertRaises(GATE.ScanError):
            self.apply()
        self.result['locations'][0]['physicalLocation']['region']['startLine'] = 3
        self.result['codeFlows'] = []
        with self.assertRaises(GATE.ScanError):
            self.apply()

    def test_indexed_artifact_matches_only_the_same_resolved_path(self):
        self.run['artifacts'] = [{'location': {'uri': self.path}}]
        self.result['locations'][0]['physicalLocation']['artifactLocation'] = {'index': 0}
        self.assertEqual(self.apply()[0], [])
        self.run['artifacts'][0]['location']['uri'] = 'other.cpp'
        with self.assertRaises(GATE.ScanError):
            self.apply()

    def test_artifact_uri_and_index_disagreement_fails_closed(self):
        self.run['artifacts'] = [{'location': {'uri': 'other.cpp'}}]
        self.result['locations'][0]['physicalLocation']['artifactLocation']['index'] = 0
        with self.assertRaises(GATE.ScanError):
            self.apply()
        del self.result['locations'][0]['physicalLocation']['artifactLocation']['index']
        self.result['codeFlows'][0]['threadFlows'][0]['locations'][0]['location']['physicalLocation']['artifactLocation']['index'] = 0
        with self.assertRaises(GATE.ScanError):
            self.apply()

    def test_exact_toolchain_uri_is_bound_but_never_opened(self):
        artifact = self.result['codeFlows'][0]['threadFlows'][0]['locations'][0]['location']['physicalLocation']['artifactLocation']
        artifact['uri'] = 'file:///Applications/Xcode_26.3.app/SDK/usr/include/string'
        _, identity, paths = GATE.reviewed_identity('cpp/path-injection', 7.5, self.result, self.run)
        self.assertNotIn(artifact['uri'], paths)
        self.entry['identity_sha256'] = identity
        self.assertEqual(self.apply()[0], [])
        artifact['uri'] = artifact['uri'].replace('26.3', '26.4')
        with self.assertRaises(GATE.ScanError):
            self.apply()

    def test_receipt_hashes_and_rationales_cannot_be_omitted_or_extended(self):
        for field, value in (('identity_sha256', '0' * 64), ('identity_sha256', '*'),
                             ('rationale', ''), ('reassess_when', ''), ('rule', 'cpp/other'),
                             ('classification', 'accepted_risk'),
                             ('unexpected', True)):
            with self.subTest(field=field, value=value):
                original = deepcopy(self.entry)
                self.entry[field] = value
                with self.assertRaises(GATE.ScanError):
                    self.apply()
                self.entry.clear()
                self.entry.update(original)

    def test_missing_classification_cannot_authorize_a_disposition(self):
        del self.entry['classification']
        with self.assertRaises(GATE.ScanError):
            self.apply()

    def test_traced_repo_source_must_be_content_bound(self):
        artifact = self.result['codeFlows'][0]['threadFlows'][0]['locations'][0]['location']['physicalLocation']['artifactLocation']
        artifact['uri'] = 'another-source.cpp'
        _, identity, _ = GATE.reviewed_identity('cpp/path-injection', 7.5, self.result, self.run)
        self.entry['identity_sha256'] = identity
        with self.assertRaises(GATE.ScanError):
            self.apply()

    def test_cli_requires_exact_receipt_and_still_blocks_an_extra_high_finding(self):
        self.run['results'] = []
        entries = []
        for number in range(4):
            result = deepcopy(self.result)
            result['message']['text'] += f' {number}'
            result['locations'][0]['physicalLocation']['region']['startLine'] += number
            result['locations'][0]['physicalLocation']['region']['endLine'] += number
            location, identity, _ = GATE.reviewed_identity('cpp/path-injection', 7.5, result, self.run)
            entry = deepcopy(self.entry)
            entry.update({'id': f'local-file-{number}', 'location': location, 'identity_sha256': identity})
            entries.append(entry)
            self.run['results'].append(result)
        self.receipt['findings'] = entries
        scan = self.root / 'scan'
        scan.mkdir()
        sarif = scan / 'cpp.sarif'
        sarif.write_text(json.dumps(self.document))
        receipt = self.root / 'receipt.json'
        receipt.write_text(json.dumps(self.receipt))
        command = [sys.executable, SPEC.origin, '--directory', str(scan), '--category', '/language:c-cpp']
        denied = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(denied.returncode, 1)
        self.assertEqual(denied.stderr.count('Security gate blocked:'), 4)
        command += ['--reviewed-dispositions', str(receipt), '--source-root', str(self.root)]
        accepted = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertEqual(accepted.stdout.count('Security gate reviewed disposition:'), 4)
        self.assertEqual(accepted.stdout.count('not_actionable_in_supported_deployment'), 4)
        self.run['tool']['driver']['rules'].append({
            'id': 'cpp/uncontrolled-process-operation',
            'properties': {'security-severity': '8.2', 'tags': ['security']},
        })
        self.run['results'].append({'ruleId': 'cpp/uncontrolled-process-operation', 'ruleIndex': 1,
                                   'message': {'text': 'Unreviewed library loading'}})
        sarif.write_text(json.dumps(self.document))
        denied = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(denied.returncode, 1)
        self.assertEqual(denied.stdout.count('Security gate reviewed disposition:'), 4)
        self.assertIn('cpp/uncontrolled-process-operation: security severity 8.2', denied.stderr)

    def test_duplicate_json_fields_fail_for_receipt_and_sarif(self):
        scan_dir = self.root / 'scan'
        scan_dir.mkdir()
        sarif = scan_dir / 'codeql.sarif'
        sarif.write_text(json.dumps(self.document))
        receipt_path = self.root / 'review.json'
        text = json.dumps(self.receipt)
        receipt_path.write_text(text[:-1] + ', "status": "accepted"}')
        with self.assertRaises(GATE.ScanError):
            GATE.check_directory(scan_dir, '/language:c-cpp', receipt_path, self.root, [])
        sarif.write_text('{"version":"2.1.0", "version":"2.1.0", "runs":[]}')
        with self.assertRaises(GATE.ScanError):
            GATE.check_directory(scan_dir, '/language:c-cpp')



class ReviewedSourceCheckTests(unittest.TestCase):
    """The pull-request check of the receipt's bound sources, without scan output."""

    REVISION = '7' * 40

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        subprocess.run(['git', 'init', '-q', str(self.root)], check=True)
        for relative in GATE.REVIEW_CONTRACTS:
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(f'reviewed source contract {relative}\n')
        subprocess.run(['git', '-C', str(self.root), 'add', '.'], check=True)
        self.patch = GATE.source_digest(self.root, GATE.PATCH)
        self.generated = f'vendor/whisper.cpp/build-steno/patched-source/{self.REVISION}-{self.patch}/source/examples/cli/cli.cpp'
        sources = {path: GATE.source_digest(self.root, path) for path in GATE.REVIEW_CONTRACTS}
        sources[self.generated] = hashlib.sha256(b'generated upstream source\n').hexdigest()
        self.entry = {'id': 'cli-response-file', 'classification': 'not_actionable_in_supported_deployment',
            'rule': 'cpp/path-injection',
            'location': {'path': self.generated, 'startLine': 3, 'startColumn': 4, 'endLine': 3, 'endColumn': 9},
            'identity_sha256': 'e' * 64, 'source_sha256': sources,
            'rationale': 'The caller selects its own response file.',
            'reassess_when': 'Source, privilege, invocation, and transport changes require review.'}
        self.receipt = {'schema_version': 1, 'category': '/language:c-cpp', 'status': 'accepted',
            'reviewed_commit': 'a' * 40, 'findings': [self.entry]}
        self.receipt_path = self.root / 'receipt.json'
        self.lock_path = self.root / 'lock.json'
        self.lock_path.write_text(json.dumps({'schema_version': 1, 'whisper': {'revision': self.REVISION}}))

    def check(self):
        self.receipt_path.write_text(json.dumps(self.receipt))
        return GATE.check_reviewed_sources(self.receipt_path, self.root, self.lock_path)

    def assert_fails(self, fragment='reassessment required'):
        with self.assertRaises(GATE.ScanError) as raised:
            self.check()
        self.assertIn(fragment, str(raised.exception))

    def test_the_repository_record_matches_its_bound_sources(self):
        root = Path(__file__).resolve().parents[3]
        count = GATE.check_reviewed_sources(root / 'scripts/ci/reviewed-findings.json', root,
                                            root / 'scripts/ci/runtime-lock.json')
        self.assertEqual(count, 4)

    def test_unchanged_sources_and_absent_generated_source_pass(self):
        self.assertEqual(self.check(), 1)

    def test_any_changed_byte_of_a_bound_file_fails(self):
        for relative in GATE.REVIEW_CONTRACTS:
            with self.subTest(path=relative):
                target = self.root / relative
                original = target.read_bytes()
                target.write_bytes(original[:-1] + bytes([original[-1] ^ 1]))
                self.assert_fails(relative)
                target.write_bytes(original)
        self.assertEqual(self.check(), 1)

    def test_missing_bound_file_or_omitted_contract_fails(self):
        target = self.root / GATE.REVIEW_CONTRACTS[2]
        contents = target.read_bytes()
        target.unlink()
        self.assert_fails('missing')
        target.write_bytes(contents)
        del self.entry['source_sha256'][GATE.REVIEW_CONTRACTS[0]]
        self.assert_fails('omit a source or launch contract')

    def test_generated_source_must_name_the_pinned_revision_and_current_patch(self):
        self.lock_path.write_text(json.dumps({'whisper': {'revision': '8' * 40}}))
        self.assert_fails(self.generated)
        self.lock_path.write_text(json.dumps({'whisper': {'revision': self.REVISION}}))
        patch = self.root / GATE.PATCH
        patch.write_text('another correction\n')
        self.assert_fails()
        # A re-recorded patch hash cannot stand in for the patch the directory names.
        self.entry['source_sha256'][GATE.PATCH] = GATE.source_digest(self.root, GATE.PATCH)
        self.assert_fails(self.generated)

    def test_existing_generated_source_is_hashed(self):
        target = self.root / self.generated
        target.parent.mkdir(parents=True)
        target.write_bytes(b'generated upstream source\n')
        self.assertEqual(self.check(), 1)
        target.write_bytes(b'different generated source\n')
        self.assert_fails(self.generated)

    def test_tracked_or_linked_generated_source_fails(self):
        target = self.root / self.generated
        target.parent.mkdir(parents=True)
        target.write_bytes(b'generated upstream source\n')
        subprocess.run(['git', '-C', str(self.root), 'add', '-f', self.generated], check=True)
        target.unlink()
        self.assert_fails('must not be tracked')
        subprocess.run(['git', '-C', str(self.root), 'rm', '-q', '--cached', self.generated], check=True)
        (self.root / 'vendor/whisper.cpp/build-steno').rename(self.root / 'elsewhere')
        (self.root / 'vendor/whisper.cpp/build-steno').symlink_to(self.root / 'elsewhere')
        self.assert_fails('symlink')

    def test_generated_source_is_never_inferred_without_a_lock(self):
        # Full mode, after a scan, always hashes the generated file itself.
        with self.assertRaises(GATE.ScanError):
            GATE.validate_receipt_sources(self.receipt, self.root)
        for lock in ('{}', '{"whisper": {"revision": "main"}}', '[]', '{broken'):
            with self.subTest(lock=lock):
                self.lock_path.write_text(lock)
                with self.assertRaises(GATE.ScanError):
                    self.check()

    def test_malformed_receipt_fails(self):
        for field, value in (('status', 'proposed'), ('schema_version', True), ('category', '/language:swift'),
                             ('reviewed_commit', 'main'), ('findings', []), ('unexpected', True)):
            with self.subTest(field=field):
                original = deepcopy(self.receipt)
                self.receipt[field] = value
                with self.assertRaises(GATE.ScanError):
                    self.check()
                self.receipt = original
        self.receipt['findings'].append(deepcopy(self.entry))
        with self.assertRaises(GATE.ScanError):
            self.check()

    def test_both_modes_report_the_same_changed_source(self):
        relative = GATE.REVIEW_CONTRACTS[5]
        (self.root / relative).write_text('changed\n')
        messages = []
        for check in (self.check, lambda: GATE.apply_dispositions([], self.receipt, self.root, [])):
            with self.assertRaises(GATE.ScanError) as raised:
                check()
            messages.append(str(raised.exception))
        self.assertEqual(messages, [f'reviewed source changed; reassessment required: {relative}'] * 2)

    def test_cli_mode_and_its_arguments(self):
        self.receipt_path.write_text(json.dumps(self.receipt))
        command = [sys.executable, SPEC.origin, '--check-reviewed-sources', str(self.receipt_path),
                   '--source-root', str(self.root), '--runtime-lock', str(self.lock_path)]
        passed = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(passed.returncode, 0, passed.stderr)
        (self.root / GATE.REVIEW_CONTRACTS[0]).write_text('changed\n')
        failed = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(failed.returncode, 1)
        self.assertIn('reassessment required: ' + GATE.REVIEW_CONTRACTS[0], failed.stderr)
        for extra in (['--category', '/language:c-cpp'], ['--directory', '.'], ['--reviewed-dispositions', 'x']):
            with self.subTest(extra=extra):
                self.assertEqual(subprocess.run(command + extra, capture_output=True).returncode, 2)
        self.assertEqual(subprocess.run(command[:-2], capture_output=True).returncode, 2)
        scan = [sys.executable, SPEC.origin, '--directory', '.', '--category', '/language:c-cpp',
                '--runtime-lock', str(self.lock_path)]
        self.assertEqual(subprocess.run(scan, capture_output=True).returncode, 2)


if __name__ == '__main__':
    unittest.main()
