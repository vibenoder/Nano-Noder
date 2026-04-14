#!/bin/bash
# Exit on any error
set -e

# 1. Update and upgrade
echo "# Updating packages..."
sudo apt update -q 2>/dev/null || sudo apt update

# 2. Basic tools
sudo apt install -y -q build-essential curl git qrencode 2>/dev/null || sudo apt install -y build-essential curl git qrencode

echo "# Installing 7zip to extract Nano Node ledger snapshot later"
# 3. 7zip
sudo apt install -y -q p7zip-full 2>/dev/null || sudo apt install -y p7zip-full

echo "# Downloading latest scripts"
# 4. Download all scripts — always re-downloaded to pick up any updates
sudo curl -sSL https://raw.githubusercontent.com/vibenoder/Nano-Noder/refs/heads/main/dashboard.sh -o /usr/local/bin/dashboard.sh && sudo chmod +x /usr/local/bin/dashboard.sh
sudo curl -sSL https://raw.githubusercontent.com/vibenoder/Nano-Noder/refs/heads/main/update.sh -o /usr/local/bin/update.sh && sudo chmod +x /usr/local/bin/update.sh
sudo curl -sSL https://raw.githubusercontent.com/vibenoder/Nano-Noder/refs/heads/main/representative-setup.sh -o /usr/local/bin/representative-setup.sh && sudo chmod +x /usr/local/bin/representative-setup.sh
# sudo curl -sSL https://raw.githubusercontent.com/vibenoder/Nano-Noder/refs/heads/main/bandwidth-cap-config.sh -o /usr/local/bin/bandwidth-cap-config.sh && sudo chmod +x /usr/local/bin/bandwidth-cap-config.sh
# sudo curl -sSL https://raw.githubusercontent.com/vibenoder/Nano-Noder/refs/heads/main/ping.sh -o /usr/local/bin/ping.sh && sudo chmod +x /usr/local/bin/ping.sh

echo "# Creating folders"
# 5. Folders — mkdir -p and chown are safe to re-run
sudo mkdir -p /home/nano-data/Nano/
sudo chown -R $USER:$USER /home/nano-data/

# 6. Install performance tools — speedtest-cli and ioping
# Installing here ensures no sudo prompts for non-root users later
# Results cached to files — used by representative-setup.sh and ping tool
if ! command -v speedtest-cli &>/dev/null; then
  echo "# Installing speedtest-cli"
  sudo apt install -y -q speedtest-cli 2>/dev/null || true
else
  echo "# speedtest-cli already installed, skipping"
fi

if ! command -v ioping &>/dev/null; then
  echo "# Installing ioping (disk performance tool)"
  sudo apt install -y -q ioping 2>/dev/null || true
else
  echo "# ioping already installed, skipping"
fi

if ! command -v fio &>/dev/null; then
  echo "# Installing fio (disk benchmark tool)"
  sudo apt install -y -q fio 2>/dev/null || true
else
  echo "# fio already installed, skipping"
fi

# 6a. Bandwidth test — always runs and overwrites previous result
if command -v speedtest-cli &>/dev/null; then
  echo "# Checking your internet bandwidth (averaging 3 tests) — please wait..."
  DL_TOTAL=0
  UL_TOTAL=0
  for i in 1 2 3; do
    echo "# Speed test $i of 3..."
    SPEED_OUTPUT=$(speedtest-cli --simple 2>/dev/null)
    DL_RUN=$(echo "$SPEED_OUTPUT" | grep -oP 'Download:\s*\K[\d.]+' || echo "0")
    UL_RUN=$(echo "$SPEED_OUTPUT" | grep -oP 'Upload:\s*\K[\d.]+' || echo "0")
    DL_TOTAL=$(echo "scale=2; $DL_TOTAL + $DL_RUN" | bc)
    UL_TOTAL=$(echo "scale=2; $UL_TOTAL + $UL_RUN" | bc)
  done
  DL=$(echo "scale=2; $DL_TOTAL / 3" | bc)
  UL=$(echo "scale=2; $UL_TOTAL / 3" | bc)
  echo "${DL} ${UL}" > /home/nano-data/bandwidth_mbps.txt
  chmod 644 /home/nano-data/bandwidth_mbps.txt
  echo "# Bandwidth recorded (3-test average): ${DL} Mbps down / ${UL} Mbps up"
else
  echo "# speedtest-cli not available — skipping bandwidth test"
fi

# 6b. Commit Latency — ioping 64k random write test (always runs and overwrites)
if command -v ioping &>/dev/null; then
  echo "# Checking block commit latency — please wait..."
  COMMIT_LATENCY=$(ioping -c 50 -s 64k -S 256M -W /home/nano-data 2>/dev/null | grep "min/avg/max" | awk -F'/' '{print $5}' || echo "0 ms")
  # Strip trailing ms if present, keep just the number
  COMMIT_LATENCY_VAL=$(echo "$COMMIT_LATENCY" | grep -oP '[\d.]+' | head -1 || echo "0")
  printf 'value=%s\nfield_name=Commit Latency\ndescription=Average block commit speed to disk under stress. Measures how responsive your node'\''s storage is when processing higher numbers of blocks in a single batch.\nsource=ioping 64k random write test (50 samples)\nunit=ms\n' "$COMMIT_LATENCY_VAL" > /home/nano-data/disk_commit_latency_ms.txt
  chmod 644 /home/nano-data/disk_commit_latency_ms.txt
  echo "# Commit Latency recorded: ${COMMIT_LATENCY_VAL} ms"
else
  echo "# ioping not available — skipping commit latency test"
fi

# 6c. Max Random Write Speed — fio burst test (always runs and overwrites)
if command -v fio &>/dev/null; then
  echo "# Checking max random write speed — please wait (30 seconds)..."
  MAX_WRITE_IOPS=$(fio --name=write_only_burst --ioengine=libaio --direct=1 \
    --rw=randwrite --bs=4k --iodepth=64 --size=1G --numjobs=4 \
    --runtime=30 --time_based --group_reporting --unlink=1 2>/dev/null \
    | grep -oP 'IOPS=\K[^,]+' | head -1 || echo "0")
  printf 'value=%s\nfield_name=Max Random Write Speed\ndescription=Your drive'\''s peak capacity to handle massive network spam and heavy load bursts.\nsource=fio burst test (4k block, iodepth 64, size 1G, 30 seconds)\nunit=IOPS\n' "$MAX_WRITE_IOPS" > /home/nano-data/disk_max_write_iops.txt
  chmod 644 /home/nano-data/disk_max_write_iops.txt
  echo "# Max Random Write Speed recorded: ${MAX_WRITE_IOPS} IOPS"
else
  echo "# fio not available — skipping max write speed test"
fi

# 6d. Sustained Write Speed — fio batch test (always runs and overwrites)
if command -v fio &>/dev/null; then
  echo "# Checking sustained write speed — please wait (30 seconds)..."
  SUSTAINED_IOPS=$(fio --name=nano_batch_sim --ioengine=libaio --direct=1 \
    --rw=randwrite --bs=4k --iodepth=16 --size=100M \
    --runtime=30 --time_based --group_reporting --unlink=1 2>/dev/null \
    | grep -oP 'IOPS=\K[^,]+' | head -1 || echo "0")
  printf 'value=%s\nfield_name=Sustained Write Speed\ndescription=Your drive'\''s efficiency at handling standard Nano block batches even under load.\nsource=fio batch test (4k block, iodepth 16, size 100M, 30 seconds)\nunit=IOPS\n' "$SUSTAINED_IOPS" > /home/nano-data/disk_sustained_write_iops.txt
  chmod 644 /home/nano-data/disk_sustained_write_iops.txt
  echo "# Sustained Write Speed recorded: ${SUSTAINED_IOPS} IOPS"
else
  echo "# fio not available — skipping sustained write speed test"
fi

# 7. aria2 — skip if already installed
if ! command -v aria2c &>/dev/null; then
  echo "# Installing aria2 download manager"
  sudo apt install -y -q aria2 2>/dev/null || sudo apt install -y aria2
else
  echo "# aria2 already installed, skipping"
fi

# 7.5. Stop node before touching ledger files (if needed)
# On re-runs where either flag is missing, the node may already be running.
# We must stop it before aria2 or 7z can touch data.ldb.
# On fresh installs there is no container yet — || true handles that silently.
if [ ! -f /home/nano-data/Nano/download_complete.flag ] || [ ! -f /home/nano-data/Nano/extraction_complete.flag ]; then
  if sudo docker ps -q -f name=nano-node -f status=running | grep -q . 2>/dev/null; then
    echo "# Stopping node to safely manage ledger files..."
    sudo docker stop nano-node || true
    echo "# Node stopped — it will restart automatically in step 13"
  fi
fi

# 8. Ledger Download — skip if download_complete.flag exists
if [ -f /home/nano-data/Nano/download_complete.flag ]; then
  echo "# Ledger snapshot already downloaded, skipping"
else
  if [ -f /home/nano-data/Nano/Nano_Snapshot.7z ]; then
    echo -e "\e[31m# WARNING: Previous ledger download was incomplete — likely due to SSH disconnection\e[0m"
    echo "# Please stay connected until both download AND extraction complete"
    echo "# This may take 15-30+ minutes depending on your connection and CPU speed"
    echo "# Starting fresh download in 30 seconds..."
    sleep 30
    rm -f /home/nano-data/Nano/Nano_Snapshot.7z
  fi
  echo "# Downloading the latest snapshot of the Nano Node ledger"
  echo "# This saves 90+ hours of bootstrapping and 4TB of Write IO"
  echo "# Please stay connected until download completes"
  echo "# This may take several minutes depending on your internet speed"
  aria2c -x 16 -s 16 -o Nano_Snapshot.7z -d /home/nano-data/Nano/ $(curl -s https://s3.us-east-2.amazonaws.com/repo.nano.org/snapshots/latest)
  touch /home/nano-data/Nano/download_complete.flag
  echo "# Download Complete"
fi

# 9. Extraction — skip if extraction_complete.flag exists
if [ -f /home/nano-data/Nano/extraction_complete.flag ]; then
  echo "# Ledger already extracted, skipping"
else
  if [ -f /home/nano-data/Nano/data.ldb ]; then
    echo -e "\e[31m# WARNING: Previous ledger extraction was incomplete — likely due to SSH disconnection\e[0m"
    echo "# Starting fresh extraction in 30 seconds..."
    sleep 30
    rm -f /home/nano-data/Nano/data.ldb
  fi
  echo "# Extracting the ledger snapshot"
  echo "# Please stay connected until extraction completes"
  echo "# This may take several minutes depending on your CPU speed"
  7z x /home/nano-data/Nano/Nano_Snapshot.7z -o/home/nano-data/Nano/ -y
  touch /home/nano-data/Nano/extraction_complete.flag
  echo "# Ledger extracted into /home/nano-data/Nano"
fi

# 10. Node Config — skip if exists to preserve custom settings made by rep.sh or bandwidth.sh
if [ -f /home/nano-data/Nano/config-node.toml ]; then
  echo "# config-node.toml already exists, skipping to preserve custom settings"
else
  echo "# Downloading config-node.toml"
  curl -sL https://raw.githubusercontent.com/vibenoder/Nano-Noder/refs/heads/main/config-node.toml -o /home/nano-data/Nano/config-node.toml
fi

# 11. RPC Config — skip if exists to preserve custom settings made by rep.sh or bandwidth.sh
if [ -f /home/nano-data/Nano/config-rpc.toml ]; then
  echo "# config-rpc.toml already exists, skipping to preserve custom settings"
else
  echo "# Downloading config-rpc.toml"
  curl -sL https://raw.githubusercontent.com/vibenoder/Nano-Noder/refs/heads/main/config-rpc.toml -o /home/nano-data/Nano/config-rpc.toml
fi

# 12. Docker install — skip if already installed
if ! command -v docker &>/dev/null; then
  echo "# Installing Docker"
  sudo apt update
  sudo apt install -y docker.io
  echo "# Starting Docker"
  sudo service docker start
  sudo usermod -aG docker $USER
else
  echo "# Docker already installed, skipping"
  # Start docker if stopped — || true prevents set -e from killing script if already running
  sudo service docker start || true
fi

# 12.5. Force Docker to use IPv4 — prevents IPv6 connectivity failures on servers
# without full IPv6 routing to Docker Hub. Only writes config if not already set.
if [ ! -f /etc/docker/daemon.json ]; then
  echo "# Configuring Docker to prefer IPv4 for reliable image pulls..."
  echo '{"ipv6": false}' | sudo tee /etc/docker/daemon.json > /dev/null
  sudo service docker restart || true
  sleep 5
  echo "# Docker IPv4 configuration applied"
fi

# 13. Nano Node — version auto-detection and re-run protection
echo "# Checking latest Nano Node version..."
LATEST_VERSION=$(curl -s https://api.github.com/repos/nanocurrency/nano-node/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+')
echo "# Latest Nano Node version available: $LATEST_VERSION"

# Track whether the node was actually started/updated (used for sleep decision below)
NODE_JUST_STARTED=false

CONTAINER_EXISTS=$(sudo docker ps -a -q -f name=nano-node)

if [ -n "$CONTAINER_EXISTS" ]; then
  # Container exists — check its current version
  CURRENT_VERSION=$(sudo docker inspect nano-node --format '{{.Config.Image}}' | grep -oP 'V[\d.]+')
  echo "# Currently installed Nano Node version: $CURRENT_VERSION"

  if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
    # Same version — just make sure it's running
    CONTAINER_RUNNING=$(sudo docker ps -q -f name=nano-node -f status=running)
    if [ -n "$CONTAINER_RUNNING" ]; then
      echo "# Nano Node is already running on the latest version ($CURRENT_VERSION), skipping"
    else
      echo "# Nano Node container exists but is stopped — starting it"
      sudo docker start nano-node
      NODE_JUST_STARTED=true
    fi
  else
    # Newer version available — update
    echo "# Newer version available ($LATEST_VERSION) — updating Nano Node..."
    sudo docker stop nano-node || true
    sudo docker rm nano-node
    sudo docker pull nanocurrency/nano:$LATEST_VERSION
    sudo docker run --restart=unless-stopped -d \
      -p 7075:7075 \
      -p 127.0.0.1:7076:7076 \
      -p 127.0.0.1:7078:7078 \
      -v /home/nano-data:/root \
      --name nano-node nanocurrency/nano:$LATEST_VERSION
    echo "# Nano Node updated to $LATEST_VERSION"
    NODE_JUST_STARTED=true
  fi
else
  # Fresh install — run the container
  echo "# No existing container found — installing Nano Node $LATEST_VERSION"
  sudo docker run --restart=unless-stopped -d \
    -p 7075:7075 \
    -p 127.0.0.1:7076:7076 \
    -p 127.0.0.1:7078:7078 \
    -v /home/nano-data:/root \
    --name nano-node nanocurrency/nano:$LATEST_VERSION
  NODE_JUST_STARTED=true
fi

# Only wait if the node was just started or updated — skip on re-runs where nothing changed
if [ "$NODE_JUST_STARTED" = true ]; then
  echo "# Node initializing, please wait..."
  sleep 45
fi

echo "# Adding a cron job + odometer to be able to check the node's Cumulative Uptime whenever you want"

# 14. Odometer Setup — touch and chmod are safe to re-run
sudo chmod 777 /home/nano-data/
sudo touch /home/nano-data/uptime_minutes.txt
sudo chmod 777 /home/nano-data/uptime_minutes.txt

# Crontab — skip if entry already exists
if sudo crontab -l 2>/dev/null | grep -q "uptime_minutes.txt"; then
  echo "# Cron job already exists, skipping"
else
  (sudo crontab -l 2>/dev/null || true; echo "* * * * * /usr/bin/docker ps -q -f name=nano-node -f status=running | grep -q . && echo \"1\" >> /home/nano-data/uptime_minutes.txt") | sudo crontab -
  echo "# Odometer is now active and will record every minute the node is running"
fi

if [ "$NODE_JUST_STARTED" = true ]; then
  sleep 15
fi

echo "# Node setup complete"
echo "# Your Nano Node is running with almost 98% sync because we already downloaded the latest snapshot of the ledger"
echo "# You have saved nearly 90+ hours of bootstrapping time and 4TB of Write IO data by using Fast Sync technique"

echo "# ------------------------------------------------------------"
echo " "
echo "# Setup is complete!"
echo -e "# To see a live dashboard of your node, just type: \e[93mdashboard\e[0m"
echo " "
echo "# From the dashboard you can also access:"
echo -e "#   \e[1;96mrep\e[0m     Set up your representative account"
echo -e "#   \e[1;96mcap\e[0m     Optimise your node's bandwidth cap"
echo " "
echo "# ------------------------------------------------------------"


# 15. Wrapper — 'dashboard' launches dashboard.sh
sudo rm -f /usr/local/bin/dashboard
printf '#!/bin/bash\nsudo chmod +x /usr/local/bin/dashboard.sh\nexec /usr/local/bin/dashboard.sh\n' | sudo tee /usr/local/bin/dashboard > /dev/null
sudo chmod +x /usr/local/bin/dashboard

# 16. Wrapper — 'update' re-runs Nano-Node.sh to update the node
sudo rm -f /usr/local/bin/update
printf '#!/bin/bash\nsudo chmod +x /usr/local/bin/update.sh\nexec /usr/local/bin/update.sh\n' | sudo tee /usr/local/bin/update > /dev/null
sudo chmod +x /usr/local/bin/update

# 17. Wrapper — 'rep' launches representative-setup.sh
sudo rm -f /usr/local/bin/rep
printf '#!/bin/bash\nsudo chmod +x /usr/local/bin/representative-setup.sh\nexec /usr/local/bin/representative-setup.sh\n' | sudo tee /usr/local/bin/rep > /dev/null
sudo chmod +x /usr/local/bin/rep

# 18. Wrapper — 'cap' launches bandwidth-cap-config.sh (uncomment when script is ready)
# sudo rm -f /usr/local/bin/cap
# printf '#!/bin/bash\nsudo chmod +x /usr/local/bin/bandwidth-cap-config.sh\nexec /usr/local/bin/bandwidth-cap-config.sh\n' | sudo tee /usr/local/bin/cap > /dev/null
# sudo chmod +x /usr/local/bin/cap

# 19. Wrapper — 'ping' launches ping.sh (uncomment when script is ready)
# sudo rm -f /usr/local/bin/ping
# printf '#!/bin/bash\nsudo chmod +x /usr/local/bin/ping.sh\nexec /usr/local/bin/ping.sh\n' | sudo tee /usr/local/bin/ping > /dev/null
# sudo chmod +x /usr/local/bin/ping

# 20. Refresh group
newgrp docker
