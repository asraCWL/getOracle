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
