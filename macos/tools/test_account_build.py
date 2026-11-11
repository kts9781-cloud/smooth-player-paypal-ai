import json
from pathlib import Path
import tempfile
import unittest

from build_app import account_configuration


class AccountBuildTests(unittest.TestCase):
    def config(self, settings, allow_test=True, environ=None):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'account.json'
            path.write_text(json.dumps(settings))
            return account_configuration(path, allow_test, environ or {})

    def test_test_server_requires_explicit_test_build(self):
        settings = {'origin': 'https://accounts.example.test', 'publicKey': 'public-only', 'environment': 'test'}
        with self.assertRaises(ValueError):
            self.config(settings, allow_test=False)
        self.assertEqual(self.config(settings), settings)

    def test_production_config_cannot_be_mislabeled_as_test(self):
        with self.assertRaises(ValueError):
            self.config({'origin': 'https://accounts.example.test', 'publicKey': 'public-only', 'environment': 'production'})

    def test_credentials_paths_and_insecure_remote_origins_are_rejected(self):
        for origin in ['http://accounts.example.test', 'https://user:password@accounts.example.test',
                       'https://accounts.example.test/v1', 'https://accounts.example.test?key=value']:
            with self.subTest(origin=origin), self.assertRaises(ValueError):
                self.config({'origin': origin, 'publicKey': 'public-only', 'environment': 'test'})

    def test_loopback_http_requires_test_mode(self):
        settings = {'origin': 'http://127.0.0.1:8874', 'publicKey': 'public-only', 'environment': 'test'}
        self.assertEqual(self.config(settings)['origin'], settings['origin'])
        settings['environment'] = 'production'
        with self.assertRaises(ValueError):
            self.config(settings, allow_test=False)

    def test_missing_key_and_ambiguous_environment_are_rejected(self):
        settings = {'origin': 'https://accounts.example.test', 'publicKey': '', 'environment': 'test'}
        with self.assertRaises(ValueError): self.config(settings)
        settings['publicKey'] = 'public-only'
        with self.assertRaises(ValueError):
            self.config(settings, environ={'SMOOTHPLAYER_ACCOUNT_URL': 'https://different.example.test'})

    def test_unconfigured_internal_build_remains_explicitly_unconfigured(self):
        self.assertIsNone(account_configuration(None, False, {}))
        with self.assertRaises(ValueError):
            account_configuration(None, True, {'SMOOTHPLAYER_ACCOUNT_URL': 'https://accounts.example.test'})


if __name__ == '__main__':
    unittest.main()
