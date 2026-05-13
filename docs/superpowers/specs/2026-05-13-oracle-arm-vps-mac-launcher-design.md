# Oracle Free Tier ARM VPS — macOS launcher design

**Date:** 2026-05-13
**Owner:** asamr@outlook.dk
**Working directory:** `/Users/asamr/OracleVPS/`
**Upstream project:** [mohankumarpaluru/oracle-freetier-instance-creation](https://github.com/mohankumarpaluru/oracle-freetier-instance-creation)
**OCI region:** `eu-stockholm-1` (Central Sweden, Stockholm — the tenancy's home region; Always Free resources can only be provisioned in the home region)
**Availability domain:** `<tenancy-prefix>:EU-STOCKHOLM-1-AD-1` (Stockholm is a single-AD region — no failover AD to try)

## Goal

Run the upstream Python retry loop on macOS as a fire-and-forget background job that hunts for Oracle Free Tier ARM capacity (`VM.Standard.A1.Flex`, 4 OCPU / 24 GB RAM) every 60 seconds. On success: provision the instance to the user's exact spec — 200 GB boot volume, 120 VPU performance, public IP, Ubuntu 24.04 — and stop.

## Two keys, two purposes (do not confuse)

| Key | Purpose | File location | Scope |
| --- | --- | --- | --- |
| **OCI API private key** (`.pem`) | Signs API requests so the script can call OCI's `LaunchInstance` endpoint. Generated and downloaded from cloud.oracle.com when the user created the API key. | `oracle-freetier-instance-creation/oci_api_private_key.pem` | Never leaves the Mac. Oracle only ever sees the matching public-key fingerprint registered against the user account. |
| **SSH keypair** (user already has one) | Public key gets installed into the new VM's `~ubuntu/.ssh/authorized_keys` at launch time so the user can SSH in. Private key is used locally by the `ssh` command. | Public: `oracle-freetier-instance-creation/ssh_public_key.pub`. Private: stays wherever the user keeps it (e.g. `~/.ssh/id_ed25519`). | The script reads only the public key. The private key is never read, copied, transmitted, or referenced by any part of this scaffolding. |

The script does **not** generate, save, copy, or upload either key. It reads the `.pem` file path from `oci_config.key_file` to sign requests, and reads the `.pub` path from `SSH_AUTHORIZED_KEYS_FILE` in `oci.env` to include the contents in the `LaunchInstance` payload. That is the entire surface area.

The upstream repo has a feature to auto-generate an SSH keypair when `SSH_AUTHORIZED_KEYS_FILE` doesn't exist — this is intentionally **unused** here since the user already has a pair.

## Target instance specification

| Field | Value |
| --- | --- |
| Shape | `VM.Standard.A1.Flex` |
| OCPU | 4 |
| Memory | 24 GB |
| OS image | Canonical Ubuntu 24.04 |
| Boot volume size | 200 GB |
| Boot volume performance | 120 VPU ("Higher Performance") |
| Public IP | Auto-assigned at creation |
| SSH key | User-provided public key |
| Display name | `oracle-arm-vps` (configurable) |

## Architectural approach

**Chosen approach:** Wrap the upstream repo with a thin macOS layer. Clone upstream unchanged into a subdirectory, add Mac-specific bootstrap (`setup_mac.sh`), a control script (`vps-ctl.sh`), a LaunchAgent plist, and a single post-creation Python helper for the VPU bump. Upstream code is never modified, so `git pull` stays clean.

**Rejected alternatives:**
- *Fork and modify upstream:* invasive, breaks easy upgrades, no upside.
- *Standalone rewrite:* wastes the entire reason for picking this repo.
- *Patch `main.py` to add VPU support:* unnecessary — OCI accepts boot-volume VPU changes as a live operation post-creation, so a follow-up call achieves the same result without touching upstream.

## Directory layout

```
/Users/asamr/OracleVPS/
├── oracle-freetier-instance-creation/   # git clone of upstream
│   ├── main.py                          # upstream entrypoint (unchanged)
│   ├── requirements.txt                 # upstream (unchanged)
│   ├── .venv/                           # python virtualenv (created by setup)
│   ├── oci.env                          # user config (gitignored — never commit)
│   ├── oci_config                       # OCI API config (gitignored)
│   ├── oci_api_private_key.pem          # downloaded from OCI (gitignored)
│   ├── ssh_public_key.pub               # user's existing pubkey (gitignored)
│   ├── INSTANCE_CREATED                 # written by upstream on success
│   └── launch_instance.log              # upstream log (rotated by upstream)
├── setup_mac.sh                         # one-time bootstrap
├── vps-ctl.sh                           # start | stop | status | logs | test
├── run_loop.sh                          # invoked by LaunchAgent; runs main then VPU bump
├── post_create_vpu_bump.py              # one-shot VPU=120 update after success
├── com.asamr.oraclevps.plist            # LaunchAgent template
├── logs/                                # LaunchAgent stdout/stderr
│   ├── stdout.log
│   └── stderr.log
└── docs/superpowers/specs/              # this spec lives here
```

## Components

### `setup_mac.sh` (one-time)

Idempotent. Run once after cloning this scaffolding to your Mac.

Responsibilities:
1. Verify `python3` is present; if not, print instructions to install via Homebrew (`brew install python@3.12`). Do not auto-install — defer to the user.
2. `git clone https://github.com/mohankumarpaluru/oracle-freetier-instance-creation.git` into `oracle-freetier-instance-creation/` if absent; otherwise `git pull`.
3. Create `.venv` inside the cloned directory: `python3 -m venv .venv`.
4. `.venv/bin/pip install --upgrade pip` then `.venv/bin/pip install -r requirements.txt`.
5. If `oci.env` does not exist in the cloned dir, write the template (see "Config templates" below) with the user's locked-in values pre-filled. Leave placeholder markers (`<FILL_IN_...>`) for OCI-side values.
6. If `oci_config` does not exist, write a template `oci_config` with placeholder lines for `user`, `tenancy`, `fingerprint`, `region`, `key_file`.
7. Print a clear next-steps checklist:
   - [ ] Drop your `.pem` into `oracle-freetier-instance-creation/oci_api_private_key.pem`
   - [ ] Drop your SSH public key into `oracle-freetier-instance-creation/ssh_public_key.pub`
   - [ ] Edit `oracle-freetier-instance-creation/oci_config` and fill the 5 fields
   - [ ] Edit `oracle-freetier-instance-creation/oci.env` and fill `OCT_FREE_AD`, `OCI_SUBNET_ID`, `compartment_id`
   - [ ] Then run: `./vps-ctl.sh test`

### `vps-ctl.sh` — control script

Subcommands:

| Command | Behavior |
| --- | --- |
| `test` | Activates the venv, runs `python main.py` in the **foreground** for ~150 seconds, then `Ctrl+C`. Prints "PASS" if it sees the script enter at least 2 retry cycles in `launch_instance.log`; "FAIL" otherwise. This is the smoke test that proves credentials/network/loop work before installing the LaunchAgent. |
| `start` | Copies `com.asamr.oraclevps.plist` into `~/Library/LaunchAgents/` (substituting absolute paths) and `launchctl load` it. Confirms with `launchctl list \| grep oraclevps`. |
| `stop` | `launchctl unload ~/Library/LaunchAgents/com.asamr.oraclevps.plist`. Does **not** delete the plist file. |
| `status` | Shows `launchctl list` row for the agent, presence of `INSTANCE_CREATED` file, last 5 lines of `launch_instance.log`, and (if created) the VPU bump result. |
| `logs` | `tail -f logs/stderr.log oracle-freetier-instance-creation/launch_instance.log` until `Ctrl+C`. |
| `uninstall` | `stop` + remove the plist from `~/Library/LaunchAgents/`. Does not delete config or credentials. |

Exit codes: 0 on success, non-zero on any failure. All subcommands print one line of human-readable status before exiting.

### `run_loop.sh` — invoked by LaunchAgent

```sh
#!/bin/zsh
SCAFFOLD_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$SCAFFOLD_ROOT/oracle-freetier-instance-creation"
.venv/bin/python main.py
status=$?
if [ -f INSTANCE_CREATED ]; then
  .venv/bin/python "$SCAFFOLD_ROOT/post_create_vpu_bump.py" \
    || echo "VPU bump failed; instance still created"
fi
exit $status
```

The venv lives inside the cloned upstream dir (`oracle-freetier-instance-creation/.venv/`), so we activate that interpreter for both `main.py` and the VPU bump script.

Rationale: a single LaunchAgent owns one process tree. When upstream exits 0 (success), the VPU bump runs once in the same shell context, then the wrapper exits 0, and `KeepAlive.SuccessfulExit=false` stops the agent from restarting it. If upstream crashes (non-zero exit), the VPU bump is skipped, the wrapper exits non-zero, and `KeepAlive` restarts the wrapper after a back-off.

### `post_create_vpu_bump.py`

Single-purpose script. Steps:
1. Parse `oracle-freetier-instance-creation/INSTANCE_CREATED` to extract the instance OCID.
2. Load the same `oci_config` the upstream uses.
3. Use OCI Python SDK `ComputeClient.list_boot_volume_attachments(compartment_id, instance_id=...)` to find the boot volume OCID.
4. `BlockstorageClient.update_boot_volume(boot_volume_id, UpdateBootVolumeDetails(vpus_per_gb=120))`.
5. Poll `get_boot_volume` until `vpus_per_gb == 120` (max ~60 s; this is a live online operation).
6. Write `VPU_BUMPED` file with the volume OCID and final VPU. Exit 0.
7. On any error: log to `logs/vpu_bump_error.log`, exit non-zero. The instance itself is unaffected.

Idempotent: if `VPU_BUMPED` already exists, exit 0 immediately without re-calling the API.

### LaunchAgent — `com.asamr.oraclevps.plist`

Key properties:
- `Label`: `com.asamr.oraclevps`
- `ProgramArguments`: `["/Users/asamr/OracleVPS/run_loop.sh"]`
- `WorkingDirectory`: `/Users/asamr/OracleVPS`
- `RunAtLoad`: `true` (kicks off at load time / login)
- `KeepAlive`: dict with `SuccessfulExit=false` (restart only on non-zero exit, i.e. crashes — NOT on the clean post-success exit)
- `ThrottleInterval`: `30` (minimum seconds between restarts, protects against tight crash loops)
- `StandardOutPath`: `/Users/asamr/OracleVPS/logs/stdout.log`
- `StandardErrorPath`: `/Users/asamr/OracleVPS/logs/stderr.log`

Installed at: `~/Library/LaunchAgents/com.asamr.oraclevps.plist`.

The plist template ships with `__OVPS_ROOT__` placeholders that `vps-ctl.sh start` substitutes with the actual absolute path. This is what lets the scaffold be moved to a different path without editing XML by hand.

## Config templates

### `oci.env` (written by `setup_mac.sh`)

```
OCI_CONFIG=./oci_config
OCT_FREE_AD=<FILL_IN_AVAILABILITY_DOMAIN>
SSH_AUTHORIZED_KEYS_FILE=./ssh_public_key.pub
OCI_COMPUTE_SHAPE=VM.Standard.A1.Flex
OCPUS=4
MEMORY_IN_GBS=24
OPERATING_SYSTEM=Canonical Ubuntu
OS_VERSION=24.04
DISPLAY_NAME=oracle-arm-vps
BOOT_VOLUME_SIZE=200
ASSIGN_PUBLIC_IP=true
REQUEST_WAIT_TIME_SECS=60
OCI_SUBNET_ID=<FILL_IN_SUBNET_OCID>
NOTIFY_EMAIL=False
```

### `oci_config` (written by `setup_mac.sh`)

```
[DEFAULT]
user=<FILL_IN_USER_OCID>
tenancy=<FILL_IN_TENANCY_OCID>
fingerprint=<FILL_IN_FINGERPRINT>
region=eu-stockholm-1
key_file=/Users/asamr/OracleVPS/oracle-freetier-instance-creation/oci_api_private_key.pem
```

The `region` value is pre-filled with `eu-stockholm-1` since the user's home region is Central Sweden, Stockholm. Always Free resources can only be provisioned in the home region, so this value is effectively fixed and not a placeholder.

### `.gitignore` (in `/Users/asamr/OracleVPS/`)

```
oracle-freetier-instance-creation/.venv/
oracle-freetier-instance-creation/oci.env
oracle-freetier-instance-creation/oci_config
oracle-freetier-instance-creation/oci_api_private_key.pem
oracle-freetier-instance-creation/ssh_public_key.pub
oracle-freetier-instance-creation/INSTANCE_CREATED
oracle-freetier-instance-creation/VPU_BUMPED
oracle-freetier-instance-creation/*.log
logs/
```

## OCI console setup (one-time, user-side)

Done by the user in cloud.oracle.com before running `./vps-ctl.sh test`:

1. **Create VCN with Internet Connectivity** — Networking → Virtual Cloud Networks → Start VCN Wizard → "Create VCN with Internet Connectivity" → accept defaults. Note the public subnet OCID it creates.
2. **Confirm API key fingerprint** — Profile → My Profile → API Keys. Match the fingerprint shown to the `.pem` file the user already has.
3. **Confirm region in top-right of console** — should read "Stockholm" / `eu-stockholm-1`. If a different region is selected, switch back to Stockholm before collecting OCIDs (subnets and ADs are region-scoped).
4. **Collect these values:**
   - **Tenancy OCID** (Profile → Tenancy)
   - **User OCID** (Profile → My Profile)
   - **Fingerprint** (Profile → API Keys — must match the `.pem`)
   - **Region** = `eu-stockholm-1` (already known — pre-filled in template)
   - **Compartment OCID** (typically root, same as tenancy OCID; the upstream script reads compartment from the tenancy field of `oci_config`, so this is informational only)
   - **Subnet OCID** (from step 1 — the public subnet in your new Stockholm VCN)
   - **Availability domain name** (Identity → Availability Domains; will be a single entry like `xxxx:EU-STOCKHOLM-1-AD-1` — Stockholm has only one AD)

## End-to-end flow

```
[User] Drop scaffolding files into /Users/asamr/OracleVPS/
[User] ./setup_mac.sh                                       # one-time
[User] Drop .pem and SSH .pub into oracle-freetier-instance-creation/
[User] Edit oci_config and oci.env (fill placeholders)
[User] ./vps-ctl.sh test                                    # ~150s smoke test
       └─> proves: venv works, OCI auth works, loop fires twice
[User] ./vps-ctl.sh start                                   # installs LaunchAgent
       └─> LaunchAgent runs run_loop.sh → main.py loops forever every 60s
       └─> if main.py crashes: LaunchAgent restarts after 30s throttle
       └─> on capacity available: main.py creates instance, writes
           INSTANCE_CREATED, exits 0
       └─> run_loop.sh sees INSTANCE_CREATED, runs post_create_vpu_bump.py
       └─> VPU bumped to 120, VPU_BUMPED file written, exit 0
       └─> LaunchAgent does NOT restart (SuccessfulExit=false)
[User] ./vps-ctl.sh status                                  # any time
       └─> shows running/stopped, INSTANCE_CREATED presence, last log lines
[User] After success: SSH into the new instance using the public IP
       printed in INSTANCE_CREATED
```

## Error handling

| Failure mode | Behavior |
| --- | --- |
| Missing `.pem` / `oci_config` / `oci.env` placeholders unfilled | `vps-ctl.sh test` fails fast with a clear "fix these files" message; never proceeds to install LaunchAgent. |
| OCI API rejects credentials (bad fingerprint, region, etc.) | Upstream writes `ERROR_IN_CONFIG.log`. `vps-ctl.sh test` detects this file, prints the contents, exits non-zero. |
| Upstream crashes mid-loop (network blip, etc.) | LaunchAgent restarts after `ThrottleInterval=30` s. Visible in `logs/stderr.log`. |
| VPU bump fails after successful creation | Instance is still created. `logs/vpu_bump_error.log` captured. User can re-run `python post_create_vpu_bump.py` manually after fixing the issue; idempotent guard via `VPU_BUMPED` file. |
| Mac sleeps | LaunchAgent pauses with the system. Resumes on wake. No data loss. |
| User wants to stop | `./vps-ctl.sh stop` unloads the agent. Re-runnable with `start` at any time. |

## Out of scope

- Instance configuration *after* SSH login (package installs, swap setup, firewall rules). Spec covers provisioning only.
- Discord/Telegram/Email notifications. User opted out.
- Reserving a permanent (vs. ephemeral) public IP. Ephemeral is fine for the initial cut.
- Multi-region or multi-AD failover. Stockholm is single-AD anyway, and Always Free is locked to the home region — so there's nothing to fail over to. If Stockholm never opens up, the only escape is to wait longer.
- Windows or Linux support for this scaffolding. macOS-only by design.

## Testing strategy

1. **Smoke test (`./vps-ctl.sh test`):** verifies venv, credentials, loop cadence in the foreground for ~150 seconds. No instance created (unless capacity happens to be available — which is the success case anyway).
2. **LaunchAgent smoke test:** after `start`, verify `launchctl list | grep oraclevps` shows the agent and `tail logs/stderr.log` shows a startup line.
3. **Crash-recovery test:** `kill -9` the running `python` process and confirm LaunchAgent restarts it within 60 s.
4. **Clean-exit test:** harder to fake without real capacity; covered by the design's `SuccessfulExit=false` semantic and verified visually if/when the real run succeeds.

## Success criteria

- `./setup_mac.sh` completes without errors on a fresh `/Users/asamr/OracleVPS/`.
- `./vps-ctl.sh test` prints PASS within ~150 seconds when credentials are valid.
- `./vps-ctl.sh start` returns success and `launchctl list` shows the agent.
- The LaunchAgent survives Mac reboot (auto-starts at login).
- When OCI capacity opens up, an ARM A1.Flex instance is created with: 4 OCPU, 24 GB RAM, 200 GB boot volume, public IP, user's SSH key — and within ~60 s post-creation, the boot volume's VPU is 120.
