"""Code scanning completion must not be confused with a clean severity gate."""

from copy import deepcopy
import importlib.util
import json
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


if __name__ == '__main__':
    unittest.main()
