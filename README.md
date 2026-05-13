# Oracle Free Tier ARM VPS launcher (macOS)

A macOS scaffolding around [mohankumarpaluru/oracle-freetier-instance-creation](https://github.com/mohankumarpaluru/oracle-freetier-instance-creation) that hunts for Oracle Free Tier ARM capacity (`VM.Standard.A1.Flex`, 4 OCPU / 24 GB / 200 GB boot / 120 VPU / public IP / Ubuntu 24.04) in `eu-stockholm-1` and stops when one is provisioned.

## Quick start

```sh
# One-time bootstrap (clones upstream, creates venv, installs deps)
./setup_mac.sh

# Drop these two files into oracle-freetier-instance-creation/
#   - oci_api_private_key.pem  (OCI API private key downloaded from cloud.oracle.com)
#   - ssh_public_key.pub       (your SSH public key — for logging into the new VM)

# Fill in placeholders in:
#   - oracle-freetier-instance-creation/oci_config
#   - oracle-freetier-instance-creation/oci.env

# Smoke-test the loop (~150s in the foreground)
./vps-ctl.sh test

# If test PASSES, install the LaunchAgent for real (runs at login, auto-restarts)
./vps-ctl.sh start

# Check status any time
./vps-ctl.sh status

# Tail logs
./vps-ctl.sh logs

# Stop hunting (does NOT delete the plist)
./vps-ctl.sh stop

# Fully uninstall (removes plist; preserves configs and credentials)
./vps-ctl.sh uninstall
```

## What success looks like

When OCI capacity opens up:

1. Upstream `main.py` creates the instance, writes `INSTANCE_CREATED`, exits 0
2. `run_loop.sh` runs `post_create_vpu_bump.py`, which sets the boot volume to 120 VPU
3. LaunchAgent does NOT restart (clean exit suppresses auto-restart)
4. `./vps-ctl.sh status` shows `PRESENT: INSTANCE_CREATED` and `PRESENT: VPU_BUMPED`
5. SSH into the instance using the public IP printed in `INSTANCE_CREATED` and your SSH private key

## Design

See [docs/superpowers/specs/2026-05-13-oracle-arm-vps-mac-launcher-design.md](docs/superpowers/specs/2026-05-13-oracle-arm-vps-mac-launcher-design.md).

## Run tests

```sh
# Shell syntax
./tests/test_shell_scripts.sh

# Python unit tests
oracle-freetier-instance-creation/.venv/bin/python -m pytest tests/ -v
```
