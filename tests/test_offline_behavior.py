"""No credentials, GCP SDK, HTTP clients, real sleeps, or cloud resources."""
import datetime
import pathlib
import re
import subprocess
import unittest
from unittest.mock import patch

from workflow_runner import Runner, WorkflowFailure, read_workflow

ROOT = pathlib.Path(__file__).resolve().parents[1]
NOW = 1800000000
ENV = {'BACKUP_PARENT': 'projects/test/locations/us-central1',
       'SOURCE_INSTANCE': 'projects/test/locations/us-central1-b/instances/fs',
       'SOURCE_SHARE': 'data', 'RETENTION_DAYS': '14'}


def backup(name, age=15, **changes):
    return dict(name=name, sourceInstance=ENV['SOURCE_INSTANCE'],
                sourceFileShare=ENV['SOURCE_SHARE'], state='READY',
                createTime=datetime.datetime.fromtimestamp(NOW - age * 86400, datetime.timezone.utc).isoformat(),
                labels={'managed-by': 'opsrabbit-backup'}) | changes


class BackupTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.definition = read_workflow(ROOT / 'workflows/filestore-backup.yaml')

    def setUp(self):
        # Any accidental networking in the Python test process fails immediately.
        guard = patch('socket.socket', side_effect=AssertionError('Network forbidden'))
        guard.start()
        self.addCleanup(guard.stop)
        self.calls, self.deleted, self.pages, self.polls = [], [], [{}], []
        self.create_error = None
        self.delete_error = None
        self.pending_forever = False
        self.runner = Runner(self.definition, self.http, ENV, NOW)

    def http(self, method, args):
        self.calls.append((method, args))
        url = args['url']
        if method == 'http.post':
            if self.create_error:
                raise self.create_error
            return {'body': {'name': 'operations/create'}}
        if url.endswith('operations/create'):
            return {'body': {} if self.pending_forever else self.polls.pop(0) if self.polls else {'done': True}}
        if method == 'http.get' and url.endswith('/backups'):
            token = args['query']['pageToken']
            return {'body': self.pages[int(token or '0')]}
        if method == 'http.delete':
            if self.delete_error:
                raise self.delete_error
            self.deleted.append(url.rsplit('/', 1)[-1])
            return {'body': {'name': 'operations/delete'}}
        if url.endswith('operations/delete'):
            return {'body': {'done': True}}
        raise AssertionError(f'Unexpected HTTP operation: {method} {args}')

    def assert_no_cleanup(self):
        self.assertFalse(self.deleted)
        self.assertFalse(any(call == 'http.get' and args['url'].endswith('/backups') for call, args in self.calls))

    def test_create_failure_never_prunes(self):
        self.create_error = WorkflowFailure('permission denied')
        with self.assertRaisesRegex(WorkflowFailure, 'permission denied'):
            self.runner.run()
        self.assert_no_cleanup()

    def test_failed_backup_operation_never_prunes(self):
        self.polls = [{'done': True, 'error': {'message': 'backup failed'}}]
        with self.assertRaises(WorkflowFailure):
            self.runner.run()
        self.assert_no_cleanup()

    def test_timeout_never_prunes_or_sleeps_in_real_time(self):
        self.pending_forever = True
        with self.assertRaisesRegex(WorkflowFailure, 'one hour'):
            self.runner.run()
        self.assertEqual(sum(self.runner.sleeps), 3600)
        self.assert_no_cleanup()

    def test_paginated_cleanup_preserves_unrelated_and_recent_backups(self):
        self.pages = [
            {'backups': [backup('old-a'), backup('manual', labels={}),
                         backup('other-instance', sourceInstance='other')], 'nextPageToken': '1'},
            {'backups': [backup('old-b'), backup('other-share', sourceFileShare='other'),
                         backup('recent', age=1), backup('boundary', age=14),
                         backup('in-progress', state='CREATING')]},
        ]
        self.runner.run()
        self.assertEqual(self.deleted, ['old-a', 'old-b'])
        listed = [i for i, (method, args) in enumerate(self.calls) if method == 'http.get' and args['url'].endswith('/backups')]
        first_delete = next(i for i, (method, _) in enumerate(self.calls) if method == 'http.delete')
        self.assertEqual(len(listed), 2)
        self.assertLess(max(listed), first_delete, 'Collect all pages before mutating the listing')

    def test_pending_backup_waits_then_succeeds(self):
        self.polls = [{}, {'done': False}, {'done': True}]
        result = self.runner.run()
        self.assertEqual(self.runner.sleeps, [30, 30])
        self.assertEqual(result, ENV['BACKUP_PARENT'] + '/backups/scheduled-' + str(NOW))
        self.assertFalse(self.deleted)

    def test_empty_page_with_next_token_is_followed(self):
        self.pages = [{'nextPageToken': '1'}, {'backups': [backup('old')]}]
        self.runner.run()
        self.assertEqual(self.deleted, ['old'])

    def test_delete_failure_stops_cleanup(self):
        self.pages = [{'backups': [backup('old-a'), backup('old-b')]}]
        self.delete_error = WorkflowFailure('delete denied')
        with self.assertRaisesRegex(WorkflowFailure, 'delete denied'):
            self.runner.run()
        self.assertEqual(sum(method == 'http.delete' for method, _ in self.calls), 1)


class DependencyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # graph evaluates dependency structure, never plans/applies or refreshes.
        graph = subprocess.run(['terraform', 'graph', '-type=plan'], cwd=ROOT,
                               text=True, capture_output=True, check=True, timeout=30).stdout
        cls.edges = {}
        for source, target in re.findall(r'"(\[root\] [^"\n]+)" -> "(\[root\] [^"\n]+)"', graph):
            cls.edges.setdefault(source, set()).add(target)

    def depends_on(self, source, target):
        pending, seen = [f'[root] {source} (expand)'], set()
        while pending:
            node = pending.pop()
            if node == f'[root] {target} (expand)':
                return True
            if node not in seen:
                seen.add(node)
                pending.extend(self.edges.get(node, []))
        return False

    def test_bootstrap_resources_wait_for_api_enablement(self):
        for resource in ['google_compute_network.opsrabbit',
                         'google_compute_global_address.private_services_range',
                         'google_service_account.run_sa']:
            with self.subTest(resource=resource):
                self.assertTrue(self.depends_on(resource, 'google_project_service.required'))

    def test_service_waits_for_database_credentials_and_secret_permissions(self):
        for resource in ['google_sql_database.opsrabbit', 'google_sql_user.opsrabbit',
                         'google_secret_manager_secret_iam_member.run_sa_secret_accessor']:
            with self.subTest(resource=resource):
                self.assertTrue(self.depends_on('google_cloud_run_v2_service.opsrabbit', resource))
