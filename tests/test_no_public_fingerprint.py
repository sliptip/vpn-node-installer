"""Regression checks: public Nginx endpoints must not identify VPN software."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PublicNginxFingerprintTests(unittest.TestCase):
    def test_no_unauthenticated_version_endpoint(self):
        installer = (ROOT / "install.sh").read_text(encoding="utf-8")
        nginx_template = installer.split("write_final_nginx(){", 1)[1].split("EOF_NGINX", 1)[1].split("EOF_NGINX", 1)[0]
        self.assertNotIn("location = /version", nginx_template)
        self.assertNotIn('installer":"vpn-node-installer', nginx_template)
        self.assertIn("location = /health", nginx_template)
        self.assertIn("location ^~ $panel", nginx_template)
        self.assertIn("auth_basic \"Restricted\"", nginx_template)


if __name__ == "__main__":
    unittest.main()
