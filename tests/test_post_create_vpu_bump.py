"""Unit tests for post_create_vpu_bump.

OCI SDK is fully mocked — these tests never make network calls.
"""
import sys
from pathlib import Path

# Allow importing the script from the repo root
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import post_create_vpu_bump as p

FIXTURES = ROOT / "tests" / "fixtures"


def test_extract_instance_ocid_finds_ocid_in_sample():
    content = (FIXTURES / "instance_created_sample").read_text()
    ocid = p.extract_instance_ocid(content)
    assert ocid == (
        "ocid1.instance.oc1.eu-stockholm-1."
        "aaaaaaaaexamplefakeocidvalue1234567890abcdef"
    )


def test_extract_instance_ocid_raises_when_missing():
    import pytest
    with pytest.raises(ValueError, match="No instance OCID found"):
        p.extract_instance_ocid("no ocid in this text at all\n")
