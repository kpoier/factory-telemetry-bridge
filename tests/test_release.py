"""Release protocol tests use fake responses and never contact the Portal."""
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
sys.path.insert(0, str(SCRIPTS))
import build
import publish


class FakeClient:
    def __init__(self, replies):
        self.replies = iter(replies)
        self.calls = []

    def request(self, url, data=None, headers=None, missing_ok=False):
        self.calls.append((url, data, headers or {}, missing_ok))
        reply = next(self.replies)
        if isinstance(reply, Exception):
            raise reply
        return reply


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'mod').mkdir()
        (self.root / 'docs').mkdir()
        self.info = {'name': 'factory-telemetry-bridge', 'version': '0.6.0',
                     'title': 'Telemetry', 'author': 'Tester', 'description': 'Telemetry export',
                     'factorio_version': '2.1', 'dependencies': ['base >= 2.1.23']}
        for name in build.MOD_FILES:
            (self.root / 'mod' / name).write_text('-- Lua\n')
        self.write_info()
        (self.root / 'mod/changelog.txt').write_text('---------------------------------------------------------------------------------------------------\nVersion: 0.6.0\n  Changes:\n    - Release.\n')
        (self.root / 'LICENSE').write_text('Explicit test license\n')
        (self.root / 'README.md').write_text('Public documentation\n')
        (self.root / 'docs/PORTAL.md').write_text('Portal description\n')
        (self.root / 'portal-license.txt').write_text('default_mit\n')
        self.filename, self.data = build.archive_bytes(self.root, 'v0.6.0')
        self.archive = self.root / self.filename
        self.archive.write_bytes(self.data)
        self.digest = hashlib.sha1(self.data).hexdigest()

    def write_info(self):
        (self.root / 'mod/info.json').write_text(json.dumps(self.info))

    def existing(self, version='0.5.100', digest='old'):
        return {'name': self.info['name'], 'releases': [{'version': version, 'sha1': digest}]}

    def run_publish(self, client, mode='first', **kwargs):
        return publish.publish(mode, kwargs.pop('tag', 'v0.6.0'), self.archive,
                               'https://github.com/kpoier/factory-telemetry-bridge',
                               root=self.root, client=client, api_key='test-secret', **kwargs)

    def test_archive_reproducible_and_allowlisted(self):
        (self.root / 'mod/server-settings.json').write_text('{"password": "private"}')
        (self.root / '.env').write_text('SECRET=private')
        self.assertEqual(build.archive_bytes(self.root)[1], self.data)
        with zipfile.ZipFile(io.BytesIO(self.data)) as archive:
            self.assertTrue(all(name.startswith('factory-telemetry-bridge_0.6.0/') for name in archive.namelist()))
            self.assertFalse(any('server-settings' in name or '.env' in name for name in archive.namelist()))

    def test_metadata_tag_and_changelog_validation(self):
        with self.assertRaises(ValueError):
            build.archive_bytes(self.root, 'v0.7.0')
        self.info['version'] = '0.6.0-rc1'
        self.write_info()
        with self.assertRaises(ValueError):
            build.archive_bytes(self.root)
        self.info['version'] = '0.6.1'
        self.write_info()
        with self.assertRaises(ValueError):
            build.archive_bytes(self.root)

    def test_secret_and_symlink_rejected(self):
        path = self.root / 'mod/control.lua'
        path.write_text('-----BEGIN PRIVATE KEY-----')
        with self.assertRaises(ValueError):
            build.archive_bytes(self.root)
        path.unlink()
        path.symlink_to(self.root / 'README.md')
        with self.assertRaises(ValueError):
            build.archive_bytes(self.root)

    def test_first_publish_metadata_and_secret_boundaries(self):
        client = FakeClient([None, {'upload_url': 'https://uploads.factorio.com/signed?token=capability'}, {'success': True}])
        self.assertIn('Published', self.run_publish(client))
        self.assertTrue(client.calls[1][0].endswith('/init_publish'))
        self.assertEqual(client.calls[1][2]['Authorization'], 'Bearer test-secret')
        self.assertNotIn('Authorization', client.calls[2][2])
        for value in (b'Portal description', b'utilities', b'default_mit', b'name="source_url"', b'name="file"', self.data):
            self.assertIn(value, client.calls[2][1])
        self.assertNotIn(b'test-secret', client.calls[2][1])

    def test_update_endpoint_and_no_first_metadata(self):
        client = FakeClient([self.existing(), {'upload_url': 'https://uploads.factorio.com/signed'}, {'success': True}])
        self.run_publish(client, 'update')
        self.assertTrue(client.calls[1][0].endswith('/releases/init_upload'))
        self.assertNotIn(b'name="license"', client.calls[2][1])

    def test_existing_identical_skips_without_mutations(self):
        client = FakeClient([self.existing('0.6.0', self.digest)])
        self.assertIn('skipped', self.run_publish(client, 'update'))
        self.assertEqual(len(client.calls), 1)

    def test_mismatched_hash_modes_and_nonforward_version_fail(self):
        cases = [(self.existing('0.6.0'), 'update'), (None, 'update'),
                 (self.existing(), 'first'), (self.existing('0.7.0'), 'update')]
        for existing, mode in cases:
            with self.subTest(mode=mode, existing=existing):
                client = FakeClient([existing])
                with self.assertRaises(publish.PublishError):
                    self.run_publish(client, mode)
                self.assertEqual(len(client.calls), 1)

    def test_first_missing_license_fails_before_post(self):
        (self.root / 'portal-license.txt').unlink()
        client = FakeClient([None])
        with self.assertRaises(OSError):
            self.run_publish(client)
        self.assertEqual(len(client.calls), 1)

    def test_pending_license_blocks_publication_before_network(self):
        (self.root / 'LICENSE').write_text('License selection pending\n')
        client = FakeClient([])
        with self.assertRaisesRegex(publish.PublishError, 'rights and license'):
            self.run_publish(client)
        self.assertEqual(client.calls, [])

    def test_archive_tampering_fails_before_network(self):
        self.archive.write_bytes(b'changed')
        client = FakeClient([])
        with self.assertRaises(publish.PublishError):
            self.run_publish(client)
        self.assertEqual(client.calls, [])

    def test_unsafe_upload_urls_fail_before_upload(self):
        for url in ('http://uploads.factorio.com/x', 'https://user:pass@host/x',
                    'file:///etc/passwd', 'https://host:bad/x', 'https:///missing', 'https://host/x#fragment'):
            client = FakeClient([None, {'upload_url': url}])
            with self.subTest(url=url), self.assertRaises(publish.PublishError):
                self.run_publish(client)
            self.assertEqual(len(client.calls), 2)

    def test_upload_requires_boolean_success(self):
        for result in ({}, {'success': 'true'}, {'success': False}):
            client = FakeClient([None, {'upload_url': 'https://uploads.factorio.com/x'}, result])
            with self.assertRaises(publish.PublishError):
                self.run_publish(client)

    def test_ambiguous_upload_readback_without_reposting(self):
        client = FakeClient([None, {'upload_url': 'https://uploads.factorio.com/x'},
                             publish.PublishError('lost response'), self.existing('0.6.0', self.digest)])
        self.assertIn('confirmed', self.run_publish(client))
        self.assertEqual(sum(call[1] is not None for call in client.calls), 2)
        client = FakeClient([None, {'upload_url': 'https://uploads.factorio.com/x'},
                             publish.PublishError('lost response'), None])
        with self.assertRaisesRegex(publish.PublishError, 'uncertain'):
            self.run_publish(client)

    def test_redirect_handler_refuses_redirect(self):
        with self.assertRaises(publish.PublishError):
            publish.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://elsewhere/x')

    def test_lookup_network_failure_never_means_missing_mod(self):
        client = FakeClient([publish.PublishError('unavailable')])
        with self.assertRaises(publish.PublishError):
            self.run_publish(client)
        self.assertEqual(len(client.calls), 1)


if __name__ == '__main__':
    unittest.main()
