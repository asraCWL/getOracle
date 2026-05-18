#!/usr/bin/env bash
# Runs ON the Oracle AMD micro VM after you've scp'd ~/OracleVPS to it.
# Idempotent: safe to re-run.

set -euo pipefail

SCAFFOLD_ROOT="/home/ubuntu/OracleVPS"
UPSTREAM_DIR="$SCAFFOLD_ROOT/oracle-freetier-instance-creation"

echo "[bootstrap] installing system deps"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  python3-venv python3-pip curl ca-certificates

echo "[bootstrap] fixing oci_config key_file path for VM"
sed -i \
  "s|^key_file=.*|key_file=$UPSTREAM_DIR/oci_api_private_key.pem|" \
  "$UPSTREAM_DIR/oci_config"

echo "[bootstrap] locking down secret files"
chmod 600 "$UPSTREAM_DIR/oci_api_private_key.pem" \
          "$UPSTREAM_DIR/oci_config" \
          "$UPSTREAM_DIR/oci.env"

echo "[bootstrap] creating venv + installing requirements"
if [ ! -d "$UPSTREAM_DIR/.venv" ]; then
  python3 -m venv "$UPSTREAM_DIR/.venv"
fi
"$UPSTREAM_DIR/.venv/bin/pip" install --quiet --upgrade pip
"$UPSTREAM_DIR/.venv/bin/pip" install --quiet -r "$UPSTREAM_DIR/requirements.txt"

echo "[bootstrap] making run_loop.sh executable"
chmod +x "$SCAFFOLD_ROOT/run_loop.sh"

echo "[bootstrap] installing systemd unit"
sudo tee /etc/systemd/system/oracle-vps-loop.service >/dev/null <<EOF
[Unit]
Description=Oracle ARM free-tier instance grabber
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=$SCAFFOLD_ROOT
ExecStart=$SCAFFOLD_ROOT/run_loop.sh
Restart=on-failure
RestartSec=60
StandardOutput=append:$SCAFFOLD_ROOT/loop.log
StandardError=append:$SCAFFOLD_ROOT/loop.log

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now oracle-vps-loop

echo
echo "[bootstrap] done. last 30 log lines:"
echo
sudo journalctl -u oracle-vps-loop -n 30 --no-pager || true
echo
echo "[bootstrap] follow live with: sudo journalctl -u oracle-vps-loop -f"
