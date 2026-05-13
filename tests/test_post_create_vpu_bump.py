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


from unittest.mock import MagicMock


def test_find_boot_volume_id_returns_id_from_first_attachment():
    fake_attachment = MagicMock(boot_volume_id="ocid1.bootvolume.oc1.eu-stockholm-1.fakebv")
    fake_response = MagicMock(data=[fake_attachment])

    compute_client = MagicMock()
    compute_client.list_boot_volume_attachments.return_value = fake_response

    result = p.find_boot_volume_id(
        compute_client,
        availability_domain="xxxx:EU-STOCKHOLM-1-AD-1",
        compartment_id="ocid1.tenancy.oc1..fake",
        instance_id="ocid1.instance.oc1.eu-stockholm-1.fakeinst",
    )

    assert result == "ocid1.bootvolume.oc1.eu-stockholm-1.fakebv"
    compute_client.list_boot_volume_attachments.assert_called_once_with(
        availability_domain="xxxx:EU-STOCKHOLM-1-AD-1",
        compartment_id="ocid1.tenancy.oc1..fake",
        instance_id="ocid1.instance.oc1.eu-stockholm-1.fakeinst",
    )


def test_find_boot_volume_id_raises_when_no_attachments():
    import pytest
    compute_client = MagicMock()
    compute_client.list_boot_volume_attachments.return_value = MagicMock(data=[])

    with pytest.raises(RuntimeError, match="No boot volume attachment"):
        p.find_boot_volume_id(
            compute_client,
            availability_domain="xxxx:EU-STOCKHOLM-1-AD-1",
            compartment_id="c",
            instance_id="i",
        )
