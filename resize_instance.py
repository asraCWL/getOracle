"""Resize the oracle-arm-vps A1.Flex instance (OCPU/memory).

Reuses the same API-key auth as post_create_vpu_bump.py (oci_config).
Subcommands:
  status            read-only: print current shape_config + lifecycle
  apply             update shape_config to TARGET (OCI reboots to apply)
  reboot            issue a SOFTRESET (virt-layer reboot) if needed
Default (no arg) == status (dry-run, never mutates).
"""
from __future__ import annotations

import sys
import oci

CONFIG_FILE = "/Users/asamr/oraclevps/oracle-freetier-instance-creation/oci_config"
INSTANCE_OCID = (
    "ocid1.instance.oc1.eu-stockholm-1."
    "anqxeljrphuxs2qcq3psn2vi56sk7s7poqbffkoxe7bqgq6lr5vehnnuwtra"
)
TARGET_OCPUS = 2.0
TARGET_MEM_GB = 12.0


def _client():
    config = oci.config.from_file(CONFIG_FILE)
    oci.config.validate_config(config)
    return oci.core.ComputeClient(config)


def _show(inst, header="Instance"):
    sc = inst.shape_config
    print(f"{header}: {inst.display_name}")
    print(f"  shape     : {inst.shape}")
    print(f"  lifecycle : {inst.lifecycle_state}")
    print(f"  ocpus     : {sc.ocpus}")
    print(f"  memory_gb : {sc.memory_in_gbs}")


def main() -> int:
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    compute = _client()
    inst = compute.get_instance(INSTANCE_OCID).data
    _show(inst, "CURRENT")

    if cmd == "status":
        print(f"\n[dry-run] target = {TARGET_OCPUS} OCPU / {TARGET_MEM_GB} GB. "
              "Run with 'apply' to resize (this reboots the box).")
        return 0

    if cmd == "apply":
        if inst.lifecycle_state != "RUNNING":
            print(f"Refusing: not RUNNING (state={inst.lifecycle_state})", file=sys.stderr)
            return 2
        if float(inst.shape_config.ocpus) == TARGET_OCPUS and \
           float(inst.shape_config.memory_in_gbs) == TARGET_MEM_GB:
            print("\nAlready at target shape; nothing to do.")
            return 0
        print(f"\nApplying resize -> {TARGET_OCPUS} OCPU / {TARGET_MEM_GB} GB ...")
        details = oci.core.models.UpdateInstanceDetails(
            shape_config=oci.core.models.UpdateInstanceShapeConfigDetails(
                ocpus=TARGET_OCPUS, memory_in_gbs=TARGET_MEM_GB))
        resp = compute.update_instance(INSTANCE_OCID, details)
        print("Update accepted.")
        _show(resp.data, "RETURNED")
        return 0

    if cmd == "wait":
        import time
        deadline = time.time() + 240
        last = None
        while time.time() < deadline:
            cur = compute.get_instance(INSTANCE_OCID).data
            state = cur.lifecycle_state
            if state != last:
                print(f"  {state}  ocpus={cur.shape_config.ocpus} "
                      f"mem={cur.shape_config.memory_in_gbs}", flush=True)
                last = state
            if state == "RUNNING":
                print("\nBack up.")
                _show(cur, "FINAL")
                return 0
            time.sleep(10)
        print("\nTimed out waiting for RUNNING.", file=sys.stderr)
        return 3

    if cmd == "reboot":
        print("\nIssuing SOFTRESET (virt-layer reboot to apply shape change) ...")
        compute.instance_action(INSTANCE_OCID, "SOFTRESET")
        print("SOFTRESET requested.")
        return 0

    print(f"unknown command: {cmd}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
