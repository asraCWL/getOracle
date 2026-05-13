"""Bump the freshly-created instance's boot volume to 120 VPU.

Designed to be invoked by run_loop.sh after upstream main.py exits 0 and
INSTANCE_CREATED is written. Idempotent: writes VPU_BUMPED on success and
short-circuits if that file already exists.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

UPSTREAM_DIR = Path(__file__).resolve().parent / "oracle-freetier-instance-creation"
INSTANCE_CREATED_FILE = UPSTREAM_DIR / "INSTANCE_CREATED"
VPU_BUMPED_FILE = UPSTREAM_DIR / "VPU_BUMPED"
OCI_CONFIG_FILE = UPSTREAM_DIR / "oci_config"
TARGET_VPU = 120

INSTANCE_OCID_PATTERN = re.compile(r"ocid1\.instance\.oc1\.[A-Za-z0-9_.\-]+")


def extract_instance_ocid(content: str) -> str:
    match = INSTANCE_OCID_PATTERN.search(content)
    if not match:
        raise ValueError("No instance OCID found in INSTANCE_CREATED content")
    return match.group(0)


def find_boot_volume_id(
    compute_client,
    availability_domain: str,
    compartment_id: str,
    instance_id: str,
) -> str:
    response = compute_client.list_boot_volume_attachments(
        availability_domain=availability_domain,
        compartment_id=compartment_id,
        instance_id=instance_id,
    )
    if not response.data:
        raise RuntimeError(
            f"No boot volume attachment found for instance {instance_id}"
        )
    return response.data[0].boot_volume_id


def bump_vpu(blockstorage_client, boot_volume_id: str) -> int:
    from oci.core.models import UpdateBootVolumeDetails

    response = blockstorage_client.update_boot_volume(
        boot_volume_id=boot_volume_id,
        update_boot_volume_details=UpdateBootVolumeDetails(vpus_per_gb=TARGET_VPU),
    )
    return response.data.vpus_per_gb


def main() -> int:
    if VPU_BUMPED_FILE.exists():
        print(f"VPU_BUMPED already exists at {VPU_BUMPED_FILE}; nothing to do")
        return 0
    if not INSTANCE_CREATED_FILE.exists():
        print(f"INSTANCE_CREATED not found at {INSTANCE_CREATED_FILE}", file=sys.stderr)
        return 1

    import oci
    config = oci.config.from_file(str(OCI_CONFIG_FILE))
    oci.config.validate_config(config)

    instance_ocid = extract_instance_ocid(INSTANCE_CREATED_FILE.read_text())

    compute_client = oci.core.ComputeClient(config)
    instance = compute_client.get_instance(instance_ocid).data

    boot_volume_id = find_boot_volume_id(
        compute_client,
        availability_domain=instance.availability_domain,
        compartment_id=instance.compartment_id,
        instance_id=instance_ocid,
    )

    blockstorage_client = oci.core.BlockstorageClient(config)
    final_vpu = bump_vpu(blockstorage_client, boot_volume_id)

    VPU_BUMPED_FILE.write_text(
        f"boot_volume_id: {boot_volume_id}\nvpus_per_gb: {final_vpu}\n"
    )
    print(f"VPU bumped to {final_vpu} on {boot_volume_id}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
