#!/usr/bin/env python3
"""Offline lock test; pins independently resolved from official GitHub tags."""
from pathlib import Path
import re, unittest

class PagesWorkflowTests(unittest.TestCase):
    def test_official_actions_use_reviewed_immutable_commits(self):
        source = (Path(__file__).resolve().parents[2]/'.github/workflows/petal-pages.yml').read_text()
        expected = {
            'actions/checkout': ('11d5960a326750d5838078e36cf38b85af677262', 'v4'),
            'actions/configure-pages': ('983d7736d9b0ae728b81ab479565c72886d7745b', 'v5'),
            'actions/upload-pages-artifact': ('56afc609e74202658d3ffba0e8f6dda462b719fa', 'v3'),
            'actions/deploy-pages': ('d6db90164ac5ed86f2b6aed7e0febac5b3c0c03e', 'v4'),
        }
        actual = re.findall(r'uses:\s*([^@\s]+)@([^\s]+)', source)
        self.assertEqual(dict(actual), {name: pin for name,(pin,tag) in expected.items()})
        self.assertEqual(len(actual), 4)
        for name,(pin,tag) in expected.items():
            self.assertIn(f'{name}@{pin} # {tag}; official tag resolved 2026-09-24', source)
        self.assertNotRegex(source, r'(?m)^\s*(?:-\s*)?run:')
        self.assertIn('path: site', source)
        self.assertIn("if: github.ref == 'refs/heads/main'", source)

if __name__ == '__main__': unittest.main()
