#!/bin/bash
# representative-setup.sh
# Automates the full setup of a Nano Representative account
# Safe to re-run — all steps check if already done before repeating

set -e

# ─── Colors ───────────────────────────────────────────────────────────────────
RED='\e[31m'
GREEN='\e[32m'
YELLOW='\033[93m'
CYAN='\e[1;96m'
BOLD='\e[1m'
NC='\e[0m'

# ─── File paths ───────────────────────────────────────────────────────────────
DATA_DIR="/home/nano-data"
WALLET_ID_FILE="$DATA_DIR/rep_wallet_id.txt"
REP_ADDRESS_FILE="$DATA_DIR/rep_address.txt"
# Note: We deliberately do NOT save the seed to a file. The seed is the master
# recovery key and is shown to the user exactly once in Step 4. Users must back
# it up themselves (QR code into password manager, or pen and paper).
CONFIG_NODE="$DATA_DIR/Nano/config-node.toml"
CONFIG_RPC="$DATA_DIR/Nano/config-rpc.toml"
RPC_URL="http://localhost:7076"

# ─── Helper: Send an RPC command to the node ──────────────────────────────────
rpc() {
  curl -s --max-time 10 -d "$1" "$RPC_URL"
}

# ─── Helper: Is the Docker container running? ─────────────────────────────────
is_node_running() {
  docker ps -q -f name=nano-node -f status=running | grep -q .
}

# ─── Helper: Is the RPC port accepting requests? ─────────────────────────────
is_rpc_ready() {
  local r
  r=$(curl -s --max-time 3 -d '{"action":"telemetry"}' "$RPC_URL" 2>/dev/null)
  echo "$r" | grep -q "block_count"
}

# ─── Helper: Wait until RPC is ready (up to 10 minutes) ──────────────────────
wait_for_rpc() {
  echo ""
  echo -e "${YELLOW}  Waiting for the node to come back online...${NC}"
  echo -e "${YELLOW}  The ledger takes time to load — please be patient (up to 10 minutes).${NC}"
  echo ""
  for i in $(seq 1 120); do
    if is_rpc_ready; then
      echo -e "${GREEN}  Node is online and ready!${NC}"
      return 0
    fi
    echo -n "."
    sleep 5
  done
  echo ""
  echo -e "${RED}  Node did not come back online within 10 minutes.${NC}"
  echo -e "${RED}  Please check its status by typing: dashboard${NC}"
  exit 1
}

# ─── Helper: Graceful stop, breathe, then start ───────────────────────────────
stop_and_start_node() {
  echo "  Stopping node gracefully..."
  sudo docker stop nano-node
  echo "  Waiting 60 seconds for the node to shut down cleanly..."
  sleep 60
  echo "  Starting node..."
  sudo docker start nano-node
}

# ─── Helper: Set a value in a TOML config file ────────────────────────────────
set_toml_value() {
  local file="$1"
  local key="$2"
  local value="$3"

  if grep -qE "^\s*#?\s*${key}\s*=" "$file" 2>/dev/null; then
    sudo sed -i -E "s|^\s*#?\s*${key}\s*=.*|${key} = ${value}|" "$file"
  else
    echo "${key} = ${value}" | sudo tee -a "$file" > /dev/null
  fi
}

# ─── Helper: Print a section header ───────────────────────────────────────────
print_step() {
  echo ""
  echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
  echo -e "${BOLD}  $1${NC}"
  echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
  echo ""
}

# ─── Helper: Print a spec check result ────────────────────────────────────────
print_check() {
  local label="$1"
  local result="$2"
  local passed="$3"   # "yes" or "no"
  if [ "$passed" = "yes" ]; then
    printf "  ${GREEN}✔${NC}  %-28s %s\n" "$label" "$result"
  else
    printf "  ${RED}✗${NC}  %-28s %s\n" "$label" "$result"
  fi
}

# ─── Helper: Gentle fail message and exit ─────────────────────────────────────
spec_fail() {
  echo ""
  echo -e "${YELLOW}  ──────────────────────────────────────────────────────────${NC}"
  echo -e "${YELLOW}  Your system does not meet the minimum specifications${NC}"
  echo -e "${YELLOW}  required to run a Nano Representative Node.${NC}"
  echo ""
  echo -e "  However, your node's contribution to the Nano network"
  echo -e "  as an observer node is much appreciated and actively"
  echo -e "  empowers decentralization. Thank you for running a node!"
  echo ""
  echo -e "  Visit \e[94mnanonoder.com\e[0m to learn more about hardware requirements."
  echo -e "${YELLOW}  ──────────────────────────────────────────────────────────${NC}"
  echo ""
  exit 0
}


# ─── Helper: Cleanly destroy existing wallet and reset saved files ────────────
do_reset() {
  print_step "Resetting previous representative setup"

  echo "  Temporarily enabling RPC control to destroy the old wallet..."
  set_toml_value "$CONFIG_RPC" "enable_control" "true"
  stop_and_start_node
  wait_for_rpc

  OLD_WALLET_ID=$(sudo cat "$WALLET_ID_FILE")
  echo "  Removing old wallet from node (ID: ${OLD_WALLET_ID:0:16}...)..."
  DESTROY_RESPONSE=$(rpc "{\"action\":\"wallet_destroy\",\"wallet\":\"$OLD_WALLET_ID\"}" 2>/dev/null)

  if echo "$DESTROY_RESPONSE" | grep -q '"destroyed": "1"'; then
    echo -e "${GREEN}  Old wallet destroyed cleanly.${NC}"
  else
    echo -e "${YELLOW}  Wallet destroy response: $DESTROY_RESPONSE${NC}"
    echo -e "${YELLOW}  Continuing anyway — the wallet may have already been removed.${NC}"
  fi

  sudo rm -f "$WALLET_ID_FILE" "$REP_ADDRESS_FILE"
  echo -e "${GREEN}  Saved files cleared.${NC}"

  set_toml_value "$CONFIG_RPC" "enable_control" "false"
  stop_and_start_node
  wait_for_rpc

  echo -e "${GREEN}  Reset complete! Starting fresh setup now...${NC}"
  sleep 2
}

# Check if a rep account already exists and is activated on the Nano network
if [ -f "$REP_ADDRESS_FILE" ]; then
  EXISTING_REP=$(cat "$REP_ADDRESS_FILE")

  # Verify against the actual Nano network — not just the local file
  EXISTING_INFO=$(curl -s --max-time 5 \
    -d "{\"action\":\"account_info\",\"account\":\"$EXISTING_REP\"}" \
    "$RPC_URL" 2>/dev/null)

  EXISTING_IS_OPEN=$(echo "$EXISTING_INFO" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print('yes' if 'balance' in d and 'error' not in d else 'no')
except:
    print('no')
" 2>/dev/null || echo "no")

  if [ "$EXISTING_IS_OPEN" = "yes" ]; then
    clear
    echo ""
    echo "======================================================================"
    echo -e "${GREEN}  REPRESENTATIVE ACCOUNT ALREADY ACTIVE${NC}"
    echo "======================================================================"
    echo ""
    echo "  Your representative account is already set up and active on the"
    echo "  Nano network."
    echo ""
    echo -e "  Rep Address: ${CYAN}${EXISTING_REP}${NC}"
    echo ""
    echo -e "  Type ${YELLOW}dashboard${NC} to monitor your node and voting stats."
    echo ""
    echo "======================================================================"
    echo ""
    echo -e "${RED}  ⚠  WARNING — If you continue, your existing wallet and rep${NC}"
    echo -e "${RED}  account will be permanently deleted and a fresh setup will${NC}"
    echo -e "${RED}  begin. Your current rep address will stop voting forever.${NC}"
    echo ""
    echo "  However, it is safe to remove if you have a negligible amount of XNO in it."
    echo "  Just make sure you change the representative address of your Nano accounts"
    echo "  in external wallets like nault.cc after you set up a new rep address."
    echo "  Your funds in external wallets are always safe even if a representative is deleted."
    echo ""
    echo -n "  Are you sure you want to start a completely fresh setup? [y/N]: "
    read -r DO_RESET
    echo ""

    if [[ ! "$DO_RESET" =~ ^[Yy]$ ]]; then
      echo " Exiting — your existing rep account is untouched."
      echo ""
      exit 0
    fi

    do_reset
  else
    # File exists but account not open on network — resume setup
    echo -e "${GREEN}  Resuming existing setup...${NC}"
    sleep 1
  fi
fi


# ══════════════════════════════════════════════════════════════════════════════
#  WELCOME SCREEN
# ══════════════════════════════════════════════════════════════════════════════

clear
echo ""
echo "============================================================================"
echo "        NANO NODER — REPRESENTATIVE ACCOUNT SETUP"
echo "============================================================================"
echo " "
echo " A Representative Node actively participates in Nano's consensus,"
echo " helping to confirm transactions and secure the network."
echo ""
echo " Running a Nano Rep Node is a long term commitment and responsibility"
echo " Before continuing, please make sure you understand the following:"
echo ""
echo -e "  ${BOLD}1. Hardware requirements${NC}"
echo    "     Your system must meet minimum specs to run a Representative Node."
echo    "     This tool will run tests to ensure your system specs qualify"
echo ""
echo -e "  ${BOLD}2. A small Nano deposit is required${NC}"
echo    "     You will need to send at least 0.00001 XNO to your new"
echo    "     representative address to activate it on the network."
echo ""
echo -e "  ${BOLD}3. Delegation is required to start voting${NC}"
echo    "     Your node needs at least 1000 XNO delegated to it (by you or others)"
echo    "     Only then it can participate in consensus and cast votes."
echo "  "
echo -e "  ${BOLD}4. Delegation is Not sending XNO${NC}"
echo    "     Delegation is just pointing your voting power to a representative address"
echo    "     from official Nano wallets (eg. nault.cc) while your XNO stays with you"
echo ""
echo "============================================================================"
echo ""
echo -n " Are you ready to continue? [y/N]: "
read -r USER_READY
echo ""

if [[ ! "$USER_READY" =~ ^[Yy]$ ]]; then
  echo " No problem — come back when you are ready."
  echo -e " Visit \e[94mnanonoder.com\e[0m to learn more."
  echo -e " To run the dashboard again just type ${YELLOW}dashboard${NC}"
  echo ""
  exit 0
fi


# ══════════════════════════════════════════════════════════════════════════════
#  SYSTEM SPEC CHECKS
# ══════════════════════════════════════════════════════════════════════════════

print_step "Checking system specifications"

echo "  Verifying your hardware meets the minimum requirements"
echo "  to run a Nano Representative Node..."
echo ""

SPECS_PASSED=true

# ── Internet Speed ────────────────────────────────────────────────────────────
if [ -f /home/nano-data/bandwidth_mbps.txt ]; then
  # Use cached result from Nano-Node.sh setup
  DOWNLOAD_MBPS=$(awk '{print $1}' /home/nano-data/bandwidth_mbps.txt)
  UPLOAD_MBPS=$(awk '{print $2}' /home/nano-data/bandwidth_mbps.txt)
elif command -v speedtest-cli &>/dev/null; then
  # No cached result — run fresh test
  echo "  Running internet speed test (this takes about 15 seconds)..."
  SPEED_OUTPUT=$(speedtest-cli --simple 2>/dev/null)
  DOWNLOAD_MBPS=$(echo "$SPEED_OUTPUT" | grep -oP 'Download:\s*\K[\d.]+' || echo "0")
  UPLOAD_MBPS=$(echo "$SPEED_OUTPUT"   | grep -oP 'Upload:\s*\K[\d.]+'   || echo "0")
else
  echo "  speedtest-cli not available — skipping speed check"
  DOWNLOAD_MBPS="0"
  UPLOAD_MBPS="0"
fi

# Compare as integers (strip decimals for comparison)
DL_INT=$(echo "$DOWNLOAD_MBPS" | awk '{printf "%d", $1}')
UL_INT=$(echo "$UPLOAD_MBPS"   | awk '{printf "%d", $1}')

if [ "$DL_INT" -ge 100 ] && [ "$UL_INT" -ge 250 ]; then
  print_check "Internet Speed" "${DOWNLOAD_MBPS} Mbps down / ${UPLOAD_MBPS} Mbps up" "yes"
else
  print_check "Internet Speed" "${DOWNLOAD_MBPS} Mbps down / ${UPLOAD_MBPS} Mbps up  (need 100↓ / 250↑ Mbps)" "no"
  SPECS_PASSED=false
fi

# ── RAM ───────────────────────────────────────────────────────────────────────
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
TOTAL_RAM_GB=$(echo "scale=1; $TOTAL_RAM_MB / 1024" | bc)
RAM_INT=$(echo "$TOTAL_RAM_MB" | awk '{printf "%d", $1}')

if [ "$RAM_INT" -ge 12288 ]; then
  print_check "RAM" "${TOTAL_RAM_GB} GB" "yes"
else
  print_check "RAM" "${TOTAL_RAM_GB} GB  (minimum 12 GB required)" "no"
  SPECS_PASSED=false
fi

# ── Disk Space ────────────────────────────────────────────────────────────────
# Check total disk size of the partition that will hold the data
TOTAL_DISK_GB=$(df -BG "${DATA_DIR}" 2>/dev/null | awk 'NR==2{gsub("G","",$2); print $2}')
[ -z "$TOTAL_DISK_GB" ] && TOTAL_DISK_GB=$(df -BG / | awk 'NR==2{gsub("G","",$2); print $2}')

if [ "$TOTAL_DISK_GB" -ge 300 ] 2>/dev/null; then
  print_check "Total Disk Space" "${TOTAL_DISK_GB} GB" "yes"
else
  print_check "Total Disk Space" "${TOTAL_DISK_GB} GB  (minimum 300 GB required)" "no"
  SPECS_PASSED=false
fi

# ── Disk Type ─────────────────────────────────────────────────────────────────
RAW_DEVICE=$(df "${DATA_DIR}" 2>/dev/null | tail -1 | awk '{print $1}')
[ -z "$RAW_DEVICE" ] && RAW_DEVICE=$(df / | tail -1 | awk '{print $1}')

# Strip /dev/ prefix, then strip partition suffix (e.g. sda1→sda, nvme0n1p1→nvme0n1)
BASE_DEV=$(echo "$RAW_DEVICE" | sed 's|/dev/||' | sed 's/p\?[0-9]*$//')

# Detect virtualisation — VPS disk type cannot be reliably determined
IS_VIRTUAL=$(systemd-detect-virt 2>/dev/null || echo "none")

if ls /dev/nvme* &>/dev/null 2>&1; then
  # NVMe devices present — definitively NVMe regardless of VPS or bare metal
  DISK_TYPE="NVMe"
  print_check "Disk Type" "NVMe" "yes"
elif [ "$IS_VIRTUAL" != "none" ]; then
  # VPS/VDS — virtual disk, cannot determine underlying type, assume SSD-backed
  print_check "Disk Type" "Virtual disk (VPS/VDS — assuming SSD-backed)" "yes"
elif [ -f "/sys/block/${BASE_DEV}/queue/rotational" ]; then
  # Bare metal — rotational flag is reliable here
  ROTATIONAL=$(cat "/sys/block/${BASE_DEV}/queue/rotational" 2>/dev/null)
  if [ "$ROTATIONAL" = "0" ]; then
    print_check "Disk Type" "SSD" "yes"
  else
    print_check "Disk Type" "HDD  (SSD or NVMe required)" "no"
    SPECS_PASSED=false
  fi
else
  # Cannot determine — pass with a note rather than blocking the user
  print_check "Disk Type" "Unknown — could not detect disk type" "yes"
fi

# ── Max Random Write Speed (disk type classification) ────────────────────────
if [ -f /home/nano-data/disk_max_write_iops.txt ]; then
  MAX_WRITE_VAL=$(grep '^value=' /home/nano-data/disk_max_write_iops.txt | cut -d'=' -f2)
elif command -v fio &>/dev/null; then
  echo "  Running max write speed test (30 seconds)..."
  MAX_WRITE_VAL=$(fio --name=write_only_burst --ioengine=libaio --direct=1 \
    --rw=randwrite --bs=4k --iodepth=64 --size=1G --numjobs=4 \
    --runtime=30 --time_based --group_reporting 2>/dev/null \
    | grep -oP 'IOPS=\K[^,]+' | head -1 || echo "0")
else
  print_check "Max Random Write Speed" "Skipped (fio unavailable)" "yes"
  MAX_WRITE_VAL="skip"
fi

if [ "$MAX_WRITE_VAL" != "skip" ]; then
  # Strip k suffix and convert to integer for comparison
  MAX_WRITE_NUM=$(echo "$MAX_WRITE_VAL" | grep -oP '[\d.]+' | head -1 || echo "0")
  MAX_WRITE_HAS_K=$(echo "$MAX_WRITE_VAL" | grep -c 'k' || true)
  if [ "$MAX_WRITE_HAS_K" -ge 1 ]; then
    MAX_WRITE_INT=$(echo "scale=0; $MAX_WRITE_NUM * 1000 / 1" | bc 2>/dev/null || echo "0")
  else
    MAX_WRITE_INT=$(echo "$MAX_WRITE_NUM" | awk '{printf "%d", $1}')
  fi

  if [ "$MAX_WRITE_INT" -ge 150000 ] 2>/dev/null; then
    print_check "Max Random Write Speed" "${MAX_WRITE_VAL} IOPS  (NVMe — excellent)" "yes"
  elif [ "$MAX_WRITE_INT" -ge 10000 ] 2>/dev/null; then
    print_check "Max Random Write Speed" "${MAX_WRITE_VAL} IOPS  (SSD — good)" "yes"
  else
    print_check "Max Random Write Speed" "${MAX_WRITE_VAL} IOPS  (HDD detected — SSD or NVMe required)" "no"
    SPECS_PASSED=false
  fi
fi

# ── Block Commit Latency ──────────────────────────────────────────────────────
if [ -f /home/nano-data/disk_commit_latency_ms.txt ]; then
  COMMIT_LAT=$(grep '^value=' /home/nano-data/disk_commit_latency_ms.txt | cut -d'=' -f2)
elif command -v ioping &>/dev/null; then
  echo "  Running block commit latency test (about 30 seconds)..."
  COMMIT_LAT=$(ioping -c 50 -s 64k -S 256M -W /home/nano-data 2>/dev/null | grep "min/avg/max" | awk -F'/' '{print $5}' | grep -oP '[\d.]+' | head -1 || echo "0")
else
  print_check "Block Commit Latency" "Skipped (ioping unavailable)" "yes"
  COMMIT_LAT="skip"
fi

if [ "$COMMIT_LAT" != "skip" ]; then
  COMMIT_LAT_INT=$(echo "$COMMIT_LAT" | awk '{printf "%d", $1}')
  if [ "$COMMIT_LAT_INT" -lt 2 ] 2>/dev/null; then
    print_check "Block Commit Latency" "${COMMIT_LAT} ms  (excellent — node will stay in sync even under load)" "yes"
  elif [ "$COMMIT_LAT_INT" -lt 10 ] 2>/dev/null; then
    print_check "Block Commit Latency" "${COMMIT_LAT} ms  (good — occasional out of sync)" "yes"
  elif [ "$COMMIT_LAT_INT" -lt 18 ] 2>/dev/null; then
    print_check "Block Commit Latency" "${COMMIT_LAT} ms  (slow — monitor and restart node weekly)" "yes"
  else
    print_check "Block Commit Latency" "${COMMIT_LAT} ms  (too slow — node will fall behind in voting)" "no"
    SPECS_PASSED=false
  fi
fi

# ── CPU Cores ─────────────────────────────────────────────────────────────────
CPU_CORES=$(lscpu -p | grep -v '^#' | sort -u -t, -k 2,4 | wc -l)
CPU_THREADS=$(nproc)

if [ "$CPU_CORES" -ge 4 ]; then
  print_check "CPU Cores" "${CPU_CORES} physical / ${CPU_THREADS} logical" "yes"
else
  print_check "CPU Cores" "${CPU_CORES} physical / ${CPU_THREADS} logical  (minimum 4 physical required)" "no"
  SPECS_PASSED=false
fi

# ── Result ────────────────────────────────────────────────────────────────────
echo ""

if [ "$SPECS_PASSED" = false ]; then
  spec_fail
fi

echo -e "${GREEN}  ──────────────────────────────────────────────────────────${NC}"
echo -e "${GREEN}  Congratulations! Your system meets all the requirements${NC}"
echo -e "${GREEN}  to run a Nano Representative Node.${NC}"
echo -e "${GREEN}  ──────────────────────────────────────────────────────────${NC}"
echo ""
echo -n "  Press ENTER to continue with setup: "
read -r


# ══════════════════════════════════════════════════════════════════════════════
#  MAIN SETUP
# ══════════════════════════════════════════════════════════════════════════════

clear
echo ""
echo "======================================================================"
echo "        NANO NODER — REPRESENTATIVE ACCOUNT SETUP"
echo "======================================================================"
echo ""
echo " This script will:"
echo "   1. Enable voting on your node"
echo "   2. Create a secure representative wallet"
echo "   3. Display your seed once — you must back it up before continuing"
echo "   4. Create your representative address and activate it (tiny Nano deposit required)"
echo "   5. Verify this node is voting for itself"
echo "   6. Revert RPC control back to default (control off)"
echo ""
echo "======================================================================"
echo ""
echo -n " Press ENTER to begin: "
read -r
echo ""
print_step "Pre-check: Verifying your node is running"

if ! is_node_running; then
  echo -e "${RED}  Your Nano Node is not running.${NC}"
  echo -e "${RED}  Please start it first by typing: dashboard${NC}"
  exit 1
fi

if ! is_rpc_ready; then
  echo -e "${YELLOW}  Node is running but RPC is not ready yet. Waiting...${NC}"
  wait_for_rpc
fi

echo -e "${GREEN}  Node is running and ready!${NC}"

# ─── Step 1: Enable voting and RPC control in config files ───────────────────
print_step "Step 1 of 9 — Enabling voting in your node configuration"

# Check if config changes are actually needed before restarting the node
NEEDS_RESTART=false

if ! grep -qE "^\s*enable_voting\s*=\s*true" "$CONFIG_NODE" 2>/dev/null; then
  echo "  Turning on 'enable_voting' in config-node.toml..."
  set_toml_value "$CONFIG_NODE" "enable_voting" "true"
  NEEDS_RESTART=true
fi

if ! grep -qE "^\s*enable\s*=\s*true" "$CONFIG_NODE" 2>/dev/null; then
  echo "  Making sure RPC is enabled in config-node.toml..."
  set_toml_value "$CONFIG_NODE" "enable" "true"
  NEEDS_RESTART=true
fi

if ! grep -qE "^\s*enable_control\s*=\s*true" "$CONFIG_RPC" 2>/dev/null; then
  echo "  Temporarily enabling RPC control (needed to create the wallet)..."
  set_toml_value "$CONFIG_RPC" "enable_control" "true"
  NEEDS_RESTART=true
fi

if [ "$NEEDS_RESTART" = true ]; then
  echo -e "${GREEN}  Configuration updated!${NC}"
else
  echo -e "${GREEN}  Configuration already up to date — skipping.${NC}"
fi

# ─── Step 2: Stop, breathe, start — apply config changes ─────────────────────
print_step "Step 2 of 9 — Restarting node to apply new settings"

if [ "$NEEDS_RESTART" = true ]; then
  stop_and_start_node
  wait_for_rpc
else
  echo -e "${GREEN}  No config changes made — node restart not needed.${NC}"
fi

# ─── Step 3: Create (or load) the representative wallet ──────────────────────
print_step "Step 3 of 9 — Setting up your representative wallet"

WALLET_ALREADY_EXISTED=false

if [ -f "$WALLET_ID_FILE" ]; then
  WALLET_ID=$(sudo cat "$WALLET_ID_FILE")
  WALLET_ALREADY_EXISTED=true
  echo -e "${GREEN}  Wallet already exists — skipping creation.${NC}"
  echo -e "  Wallet ID: ${CYAN}${WALLET_ID:0:16}...${NC}"
else
  echo "  Creating a new secure wallet..."
  WALLET_RESPONSE=$(rpc '{"action":"wallet_create"}')
  WALLET_ID=$(echo "$WALLET_RESPONSE" | grep -oP '"wallet":\s*"\K[^"]+')

  if [ -z "$WALLET_ID" ]; then
    echo -e "${RED}  Failed to create wallet. Raw response: $WALLET_RESPONSE${NC}"
    echo -e "${RED}  Please make sure the node is fully synced and try again.${NC}"
    exit 1
  fi

  echo "$WALLET_ID" | sudo tee "$WALLET_ID_FILE" > /dev/null
  sudo chmod 600 "$WALLET_ID_FILE"
  echo -e "${GREEN}  Wallet created successfully!${NC}"
  echo ""
  sleep 5
  echo -e "${YELLOW}  ⚠  Your seed is about to be displayed on screen.${NC}"
  echo -e "${YELLOW}  ⚠  It will only be shown ONCE and is never saved anywhere.${NC}"
  echo ""
  echo "  Please make sure:"
  echo "    • Nobody else can see your screen"
  echo "    • Your password manager (on your phone or PC) is ready"
  echo ""
  echo -n "  Press ENTER when you are ready: "
  read -r
fi

# ─── Step 4: Display the seed for one-time backup ────────────────────────────
print_step "Step 4 of 9 — Backing up your seed (master recovery key)"

if [ "$WALLET_ALREADY_EXISTED" = true ]; then
  echo -e "${GREEN}  Wallet already existed — seed was already shown on first run.${NC}"
  echo -e "${YELLOW}  If you need to recover your seed, use the testing reset option${NC}"
  echo -e "${YELLOW}  to start fresh, or contact support.${NC}"
else

echo -e "${YELLOW}  What is a seed?${NC}"
echo "  Your seed is a 64-character code that is the MASTER KEY to your"
echo "  representative account. Think of it like your password — but if"
echo "  you lose it, it cannot be recovered by anyone. Ever."
echo ""
echo -e "  ${RED}⚠  This is the ONLY time your seed will be shown. ⚠${NC}"
echo -e "  ${RED}⚠  Nano Noder does NOT save your seed anywhere. ⚠${NC}"
echo ""
echo "  Before continuing, please have ONE of these ready:"
echo "    • Your phone or PC with a password manager app installed"
echo -e "      (${CYAN}Bitwarden${NC}, ${CYAN}Proton Pass${NC}, ${CYAN}KeePassXC${NC}, etc.)"
echo "    • A pen and paper"
echo ""
echo -n "  Press ENTER when you are ready to view your seed: "
read -r
echo ""

# Extract the seed from the node via the wallet_decrypt_unsafe CLI command.
# This is the ONLY way to retrieve a seed from the node wallet — it is NOT
# returned by any RPC call. See: https://docs.nano.org/integration-guides/key-management/#backing-up-seed
SEED=$(sudo docker exec nano-node nano_node --wallet_decrypt_unsafe --wallet "$WALLET_ID" 2>/dev/null \
  | grep -oP 'Seed:\s*\K[0-9A-Fa-f]+' || true)

if [ -z "$SEED" ]; then
  echo -e "${RED}  Could not retrieve seed from the node.${NC}"
  echo -e "${RED}  This can happen if the wallet was just created — please wait 10 seconds and re-run.${NC}"
  exit 1
fi

clear
echo ""
echo "============================================================================"
echo -e "         ${BOLD}YOUR SEED — BACK IT UP NOW${NC}"
echo "============================================================================"
echo ""
echo -e "  ${RED}This is shown only ONCE. Nano Noder tool does NOT save it anywhere.${NC}"
echo -e "  ${RED}This is to ensure maximum security and promote self custody awareness.${NC}"
echo -e "  ${RED}If you lose this seed, you will not be able to re-use this rep account on a different server.${NC}"
echo ""
echo "  Your 64-character seed (select the whole seed, then right click copy):"
echo ""
echo -e "  ${YELLOW}${SEED}${NC}"
echo ""
echo "  Same seed as a QR code (scan with your phone):"
echo ""

# Render the QR code in the terminal. qrencode -t ANSI256 outputs a compact
# colored QR using ANSI escape codes that scan reliably from a phone camera.
# -s 1 sets the module size to 1 (smallest) to keep it compact on screen.
# Installed by Nano-Node.sh step 2 alongside the other basic tools.
if command -v qrencode &>/dev/null; then
  qrencode -t ANSI256 -m 1 -s 1 "$SEED"
else
  echo -e "  ${YELLOW}(QR code not available — qrencode is not installed.${NC}"
  echo -e "  ${YELLOW} Use the 64-character text above instead.)${NC}"
fi

echo ""
echo "  ────────────────────────────────────────────────────────────────"
echo -e "  ${BOLD}HOW TO BACK THIS UP — pick at least one:${NC}"
echo "  ────────────────────────────────────────────────────────────────"
echo ""
echo -e "  ${BOLD}Option 1 — Password manager app on your phone (recommended)${NC}"
echo "    1. Open Bitwarden, Proton Pass, or similar"
echo "    2. Create a new 'Secure Note' or 'Login' entry"
echo "    3. Tap the camera/QR scan icon in the app"
echo "    4. Scan the QR code shown above"
echo "    5. Save with a clear name like 'Nano Noder Rep Seed'"
echo ""
echo -e "  ${BOLD}Option 2 — Write it down on paper${NC}"
echo "    Copy the 64-character code above onto paper."
echo "    Store it somewhere only you can access (safe, locked drawer, etc.)"
echo ""
echo -e "  ${BOLD}Option 3 — Not recommended but OK${NC}"
echo "    Select the full SEED (64 characters) and right click to copy."
echo "    Then on your Windows or Mac PC, create a text file in a USB folder."
echo "    Paste the SEED there (encrypt the file into a .rar or .zip file)."
echo "    Permanently store the USB stick offline (reconnect to PC only when required)."
echo ""
echo "  ────────────────────────────────────────────────────────────────"
echo ""
echo -e "  Once your seed is safely backed up, type the phrase below"
echo "  and press ENTER to continue:"
echo ""
echo -e "    ${CYAN}I have backed up my seed${NC}"
echo ""

# Loop until the user types the exact confirmation phrase (case-insensitive).
# This forces them to read the prompt and prevents reflexive Enter-mashing.
while true; do
  echo -n "  > "
  read -r CONFIRM_PHRASE
  # Lowercase the input for case-insensitive comparison
  CONFIRM_LOWER=$(echo "$CONFIRM_PHRASE" | tr '[:upper:]' '[:lower:]')
  if [ "$CONFIRM_LOWER" = "i have backed up my seed" ]; then
    break
  fi
  echo -e "  ${YELLOW}That phrase did not match. Please type exactly:${NC}"
  echo -e "  ${CYAN}I have backed up my seed${NC}"
  echo ""
done

# Wipe the seed from this script's memory immediately after use.
# Then clear the screen so the seed is not left in the terminal scrollback.
SEED=""
unset SEED
clear

echo ""
echo -e "${GREEN}  Seed backup confirmed! Continuing with setup...${NC}"
echo ""
sleep 1

fi # end of seed display block (skipped if wallet already existed)

# ─── Step 5: Create (or load) the representative account ─────────────────────
print_step "Step 5 of 9 — Creating your representative account address"

if [ -f "$REP_ADDRESS_FILE" ]; then
  REP_ADDRESS=$(cat "$REP_ADDRESS_FILE")
  echo -e "${GREEN}  Representative account already exists — skipping creation.${NC}"
else
  echo "  Generating your representative account from the wallet..."
  ACCOUNT_RESPONSE=$(rpc "{\"action\":\"account_create\",\"wallet\":\"$WALLET_ID\"}")
  REP_ADDRESS=$(echo "$ACCOUNT_RESPONSE" | grep -oP '"account":\s*"\K[^"]+')

  if [ -z "$REP_ADDRESS" ]; then
    echo -e "${RED}  Failed to create account. Raw response: $ACCOUNT_RESPONSE${NC}"
    exit 1
  fi

  echo "$REP_ADDRESS" | tee "$REP_ADDRESS_FILE" > /dev/null
  chmod 644 "$REP_ADDRESS_FILE"
  echo -e "${GREEN}  Representative account created!${NC}"
fi

echo ""
echo -e "  Your representative address is:"
echo ""
echo -e "  ${CYAN}${REP_ADDRESS}${NC}"
echo ""

# ─── Set wallet's default representative BEFORE the account is opened ───────
# This is critical: when Step 6 opens the account via search_receivable, the
# resulting open block bakes in whatever the wallet's default representative
# is at that moment. By setting it here (before opening), the open block
# itself records this node as its own representative — no extra change block
# needed afterwards. See Nano docs: wallet_representative_set sets the default
# only for NEW accounts; once an account is opened, only a change block can
# update its rep.
echo "  Setting your wallet's default representative to your new rep address..."
echo "  (This makes sure the account opens with your node as its own rep)"

WRS_RESPONSE=$(rpc "{\"action\":\"wallet_representative_set\",\"wallet\":\"$WALLET_ID\",\"representative\":\"$REP_ADDRESS\"}" 2>/dev/null)
WRS_OK=$(echo "$WRS_RESPONSE" | grep -oP '"set":\s*"\K[^"]+' || true)

if [ "$WRS_OK" = "1" ]; then
  echo -e "${GREEN}  Wallet default representative set!${NC}"
else
  echo -e "${YELLOW}  Could not confirm default rep was set. Raw response: $WRS_RESPONSE${NC}"
  echo -e "${YELLOW}  Continuing anyway — Step 7 will verify and fix if needed.${NC}"
fi

# ─── Step 6: Wait for the account to be funded (opened) ──────────────────────
print_step "Step 6 of 9 — Activating your representative account"

ACCOUNT_INFO=$(rpc "{\"action\":\"account_info\",\"account\":\"$REP_ADDRESS\"}" 2>/dev/null)
ACCOUNT_IS_OPEN=$(echo "$ACCOUNT_INFO" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print('yes' if 'balance' in d and 'error' not in d else 'no')
except:
    print('no')
" 2>/dev/null || echo "no")

if [ "$ACCOUNT_IS_OPEN" = "yes" ]; then
  echo -e "${GREEN}  Account is already active on the Nano network — skipping funding step.${NC}"
else
  echo "  A Nano account does not officially exist on the network until it"
  echo "  receives its very first transaction — even a tiny amount."
  echo ""
  echo -e "  ${BOLD}Please send at least 0.00001 XNO (Nano) to this address:${NC}"
  echo ""
  echo -e "  ${GREEN}${REP_ADDRESS}${NC}"
  echo ""
  echo "  You can use any Nano wallet app (Natrium, Nault, Cake Wallet, etc.)"
  echo "  to send the funds. Once sent, this script will detect it automatically."
  echo ""
  echo -e "  ${YELLOW}Checking for incoming funds every 10 seconds...${NC}"
  echo -e "  (Press ${RED}CTRL+C${NC} to cancel and come back later)"
  echo ""

  ATTEMPTS=0
  while true; do
    # First check if account is already open (catches cases where funds were
    # received between iterations or by a previous run)
    LIVE_INFO=$(rpc "{\"action\":\"account_info\",\"account\":\"$REP_ADDRESS\"}" 2>/dev/null)
    ALREADY_OPEN=$(echo "$LIVE_INFO" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print('yes' if 'balance' in d and 'error' not in d else 'no')
except:
    print('no')
" 2>/dev/null || echo "no")

    if [ "$ALREADY_OPEN" = "yes" ]; then
      echo ""
      echo -e "${GREEN}  Account is now active on the Nano network!${NC}"
      break
    fi

    RECV=$(rpc "{\"action\":\"receivable\",\"account\":\"$REP_ADDRESS\",\"count\":\"1\"}" 2>/dev/null)

    HAS_FUNDS=$(echo "$RECV" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    blocks = d.get('blocks', '')
    print('yes' if isinstance(blocks, dict) and len(blocks) > 0 else 'no')
except:
    print('no')
" 2>/dev/null || echo "no")

    if [ "$HAS_FUNDS" = "no" ]; then
      RECV=$(rpc "{\"action\":\"pending\",\"account\":\"$REP_ADDRESS\",\"count\":\"1\"}" 2>/dev/null)
      HAS_FUNDS=$(echo "$RECV" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    blocks = d.get('blocks', '')
    print('yes' if isinstance(blocks, dict) and len(blocks) > 0 else 'no')
except:
    print('no')
" 2>/dev/null || echo "no")
    fi

    if [ "$HAS_FUNDS" = "yes" ]; then
      echo ""
      echo -e "${GREEN}  Funds detected! Processing...${NC}"
      break
    fi

    ATTEMPTS=$((ATTEMPTS + 1))
    echo -ne "  Waiting... ($((ATTEMPTS * 10))s elapsed)\r"
    sleep 10
  done

  echo "  Collecting funds and opening your account on the ledger..."

  SR_RESPONSE=$(rpc "{\"action\":\"search_receivable\",\"wallet\":\"$WALLET_ID\"}" 2>/dev/null)
  if echo "$SR_RESPONSE" | grep -q '"error"'; then
    rpc "{\"action\":\"search_pending\",\"wallet\":\"$WALLET_ID\"}" > /dev/null 2>&1 || true
  fi

  sleep 5

  ACCOUNT_INFO=$(rpc "{\"action\":\"account_info\",\"account\":\"$REP_ADDRESS\"}" 2>/dev/null)
  ACCOUNT_IS_OPEN=$(echo "$ACCOUNT_INFO" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print('yes' if 'balance' in d and 'error' not in d else 'no')
except:
    print('no')
" 2>/dev/null || echo "no")

  if [ "$ACCOUNT_IS_OPEN" = "no" ]; then
    BLOCK_HASH=$(echo "$RECV" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    blocks = d.get('blocks', {})
    if isinstance(blocks, dict) and blocks:
        print(list(blocks.keys())[0])
except:
    pass
" 2>/dev/null || true)

    if [ -n "$BLOCK_HASH" ]; then
      rpc "{\"action\":\"receive\",\"wallet\":\"$WALLET_ID\",\"account\":\"$REP_ADDRESS\",\"block\":\"$BLOCK_HASH\"}" > /dev/null 2>&1 || true
      sleep 3
    fi
  fi

  echo -e "${GREEN}  Account is now active on the Nano network!${NC}"
fi

# ─── Step 7: Verify the account is voting for itself ─────────────────────────
print_step "Step 7 of 9 — Verifying this node is voting for itself"

echo "  Reading back the representative on your now-active account..."
echo "  (This confirms Step 5b's wallet_representative_set actually took effect)"
echo ""

CURRENT_REP_RESPONSE=$(rpc "{\"action\":\"account_representative\",\"account\":\"$REP_ADDRESS\"}" 2>/dev/null)
CURRENT_REP=$(echo "$CURRENT_REP_RESPONSE" | grep -oP '"representative":\s*"\K[^"]+' || true)

if [ "$CURRENT_REP" = "$REP_ADDRESS" ]; then
  echo -e "${GREEN}  Verified! Your node's account is voting for itself.${NC}"
  echo "  This node will cast its voting weight using its own representative."
else
  echo -e "${YELLOW}  The account is currently delegating to a different rep:${NC}"
  echo -e "${YELLOW}  $CURRENT_REP${NC}"
  echo "  Publishing a change block to fix this..."

  CHANGE_RESPONSE=$(rpc "{\"action\":\"account_representative_set\",\"wallet\":\"$WALLET_ID\",\"account\":\"$REP_ADDRESS\",\"representative\":\"$REP_ADDRESS\"}" 2>/dev/null)
  CHANGE_BLOCK=$(echo "$CHANGE_RESPONSE" | grep -oP '"block":\s*"\K[^"]+' || true)

  if [ -n "$CHANGE_BLOCK" ]; then
    echo -e "${GREEN}  Change block published. Waiting a few seconds for it to confirm...${NC}"
    sleep 5

    # Re-verify
    CURRENT_REP_RESPONSE=$(rpc "{\"action\":\"account_representative\",\"account\":\"$REP_ADDRESS\"}" 2>/dev/null)
    CURRENT_REP=$(echo "$CURRENT_REP_RESPONSE" | grep -oP '"representative":\s*"\K[^"]+' || true)

    if [ "$CURRENT_REP" = "$REP_ADDRESS" ]; then
      echo -e "${GREEN}  Verified! Your node is now voting for itself.${NC}"
    else
      echo -e "${YELLOW}  Change block sent but rep still shows: $CURRENT_REP${NC}"
      echo -e "${YELLOW}  This is not critical — the change may take more time to confirm.${NC}"
    fi
  else
    echo -e "${YELLOW}  Change response: $CHANGE_RESPONSE${NC}"
    echo -e "${YELLOW}  This is not critical — voting is still enabled. Continuing...${NC}"
  fi
fi

# ─── Step 8: Disable enable_control for security ─────────────────────────────
print_step "Step 8 of 9 — Reverting RPC control to default (off) for maximum security"

echo "  Disabling RPC control access (it was only needed to create the wallet)..."
set_toml_value "$CONFIG_RPC" "enable_control" "false"
echo -e "${GREEN}  Done! Your node is now secured.${NC}"

# ─── Step 9: Stop, breathe, start — apply security settings ──────────────────
print_step "Step 9 of 9 — Restarting node to apply security settings"

stop_and_start_node
wait_for_rpc

# ─── Done! ────────────────────────────────────────────────────────────────────
clear
echo ""
echo "======================================================================"
echo -e "${GREEN}       NANO NODER — REPRESENTATIVE SETUP COMPLETE!${NC}"
echo "======================================================================"
echo ""
echo " Your representative address (share this publicly):"
echo ""
echo -e " ${CYAN}${REP_ADDRESS}${NC}"
echo ""
echo -e "${YELLOW} Reminder: your seed was shown in Step 4 and is NOT saved on this server.${NC}"
echo -e "${YELLOW} If you did not back it up, you cannot recover it. Please double-check${NC}"
echo -e "${YELLOW} that your password manager or paper backup is in a safe place.${NC}"
echo ""
echo "----------------------------------------------------------------------"
echo -e "${YELLOW} NEXT STEP — Getting voting weight delegated to your node${NC}"
echo ""
echo " If you have 1000 XNO, delegate it to your own representative."
echo " If not, delegate whatever you have or can — every bit counts."
echo ""
echo " Let your node's health stats do the rest. Active uptime and strong"
echo " system specs automatically encourage the Nano community to delegate"
echo " their voting weight to your representative node."
echo ""
echo -e "${CYAN} Remember, delegation is NOT sending Nano to this rep address."
echo -e " Delegation is only appointing a representative to vote on your behalf"
echo ""
echo -e " Steps:"
echo -e " 1. Go to your external wallet (nault.cc) and Go to Representatives (settings)"
echo -e " 2. In \"Accounts to Change\" field, select your wallet that has XNO balance"
echo -e " 3. Enter the representative address and click on \"Update Representative\"${NC}"
echo ""
echo " Keep your server and node up and running at all times."
echo " Check your node status regularly via the dashboard and make sure"
echo " block counts are increasing. Cumulative Uptime and Active Uptime %"
echo " are the most important factors to keep growing."
echo ""
echo -e " To see how your node compares to others installed by Nano Noder tool,"
echo -e " visit  \e[94mnanonoder.com\e[0m"
echo "----------------------------------------------------------------------"
echo ""
echo -e " Type ${YELLOW}dashboard${NC} to monitor your node and see your voting stats."
echo ""
echo "======================================================================"
