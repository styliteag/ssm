"""Smoke test to verify scaffold and test harness work."""

import ssm


def test_version_present() -> None:
    assert ssm.__version__ == "0.1.0"
