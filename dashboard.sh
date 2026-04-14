#!/bin/bash

# nano-node-dashboard.sh
# A real-time monitoring script for your Nano Node

# Colors
MAGENTA='\e[1;96m'
RED='\e[31m'
YELLOW=$'\033[93m'
BLUE=$'\033[94m'
NC=$'\033[0m'
RESET='\e[0m'

# Yellow "Initializing..." placeholder for fields that need RPC
INIT="${YELLOW}Initializing...${NC}"

# Paths
REP_ADDRESS_FILE="/home/nano-data/rep_address.txt"
WALLET_ID_FILE="/home/nano-data/rep_wallet_id.txt"

is_node_running() {
  docker ps -q -f name=nano-node -f status=running | grep -q .
}

# Check if node RPC is ready by testing telemetry response
is_rpc_ready() {
  local response
  response=$(curl -s --max-time 3 -d '{"action":"telemetry"}' http://localhost:7076 2>/dev/null)
  echo "$response" | grep -q "block_count"
}

# Fetch highest block count from 6 public Nano endpoints (URLs are Base64 encoded)
get_network_block() {
  local encoded="aHR0cHM6Ly9ycGMubmFuby50bwpodHRwczovL3JhaW5zdG9ybS5jaXR5L2FwaQpodHRwczovL25vZGUuc29tZW5hbm8uY29tL3Byb3h5Cmh0dHBzOi8vYXBwLm5hdHJpdW0uaW8vYXBpCmh0dHBzOi8vbmFub3Nsby4xbmEubm8vcHJveHkKaHR0cHM6Ly9ibG9ja2xhdHRpY2UuaW8vYXBpL3JwYw=="
  local highest=0
  while IFS= read -r ep; do
    local count
    count=$(curl -sf --max-time 2 -X POST "$ep" \
      -H "Content-Type: application/json" \
      -d '{"action":"block_count"}' 2>/dev/null \
      | grep -oP '"count":\s*"\K\d+' | head -1)
    if [[ -n "$count" ]] && (( count > highest )); then
      highest=$count
    fi
  done < <(echo "$encoded" | base64 -d | shuf)
  echo "$highest"
}

# Check latest Nano Node version once per day
check_node_version() {
  local version_file="/home/nano-data/last_version_check.txt"
  local today
  today=$(date -u '+%Y-%m-%d')
  local stored_date=""
  local version_msg="Nano Node version up to date (checked daily)"

  if [ -f "$version_file" ]; then
    stored_date=$(awk 'NR==1' "$version_file")
    version_msg=$(awk 'NR==2' "$version_file")
  fi

  if [ "$stored_date" != "$today" ]; then
    local latest
    latest=$(curl -s --max-time 5 https://api.github.com/repos/nanocurrency/nano-node/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+')
    local current
    current=$(docker inspect nano-node --format '{{.Config.Image}}' 2>/dev/null | grep -oP 'V[\d.]+')

    if [ -n "$latest" ] && [ -n "$current" ]; then
      if [ "$current" = "$latest" ]; then
        version_msg="Nano Node version up to date (checked daily)"
      else
        version_msg="Node version $latest available — exit and type [\e[5;31mupdate\e[0m] to update node"
      fi
    fi
    printf '%s\n%s\n' "$today" "$version_msg" > "$version_file"
  fi

  echo "$version_msg"
}

# Fetch representative voting stats (from saved rep address file)
get_rep_stats() {
  # Defaults
  rep_address_display="-"
  voting_display="No"
  voting_weight_display="-"
  voting_weight_pct_display="-"

  [ -f "$REP_ADDRESS_FILE" ] || return
  local rep_addr
  rep_addr=$(cat "$REP_ADDRESS_FILE")
  [ -n "$rep_addr" ] || return

  rep_address_display="$rep_addr"

  # Get this rep's voting weight in raw units
  local weight_raw
  weight_raw=$(curl -s --max-time 3 \
    -d "{\"action\":\"account_weight\",\"account\":\"$rep_addr\"}" \
    http://localhost:7076 2>/dev/null | grep -oP '"weight":\s*"\K\d+')

  # Get total online voting weight for percentage calculation
  local online_raw
  online_raw=$(curl -s --max-time 3 \
    -d '{"action":"confirmation_quorum"}' \
    http://localhost:7076 2>/dev/null | grep -oP '"online_stake_total":\s*"\K\d+')

  # Check if voting is enabled in config
  local enable_voting
  enable_voting=$(grep -E "^\s*enable_voting\s*=" "/home/nano-data/Nano/config-node.toml" 2>/dev/null | grep -o 'true\|false' | head -1)

  # Convert and format using python3
  local stats
  stats=$(python3 -c "
weight = int('${weight_raw:-0}') if '${weight_raw}' else 0
online = int('${online_raw:-0}') if '${online_raw}' else 0
enable_voting = '${enable_voting}' == 'true'
nano = weight / 10**30
if nano >= 1000:
    nano_str = f'{nano:,.2f} XNO'
elif nano > 0:
    nano_str = f'{nano:.6f} XNO'
else:
    nano_str = '0 XNO'
if online > 0 and weight > 0:
    pct = weight / online * 100
    if pct >= 0.001:
        pct_str = f'{pct:.4f}%'
    else:
        pct_str = '<0.001%'
else:
    pct_str = '0%'
if not enable_voting:
    voting_status = 'OFF'
elif nano >= 1000:
    voting_status = 'ON'
else:
    voting_status = 'OFF (awaiting min. 1000 XNO delegation)'
print(f'{nano_str}|{pct_str}|{voting_status}')
" 2>/dev/null || echo "0 XNO|0%|OFF")

  voting_weight_display=$(echo "$stats" | cut -d'|' -f1)
  voting_weight_pct_display=$(echo "$stats" | cut -d'|' -f2)
  voting_display=$(echo "$stats" | cut -d'|' -f3)
}

show_offline_banner() {
  clear
  echo "======================================================================"
  echo "                     NANO NODE DASHBOARD"
  echo "======================================================================"
  echo " Last Updated: $(date '+%Y-%m-%d %H:%M:%S')    (Auto refresh in 30 seconds)"
  echo "----------------------------------------------------------------------"
  echo ""
  echo "                   *** NODE IS STOPPED ***"
  echo ""
  echo "----------------------------------------------------------------------"
  echo -e " [${RED}S${RESET}] Start Node        [${RED}CTRL+C${RESET}] Exit Dashboard"
  echo "======================================================================"
}

show_message() {
  local msg=$1
  clear
  echo "======================================================================"
  echo "                     NANO NODE DASHBOARD"
  echo "======================================================================"
  echo ""
  echo "  >>> $msg"
  echo ""
  echo "======================================================================"
}

run_dashboard() {
  clear

  # --- Gather all data first ---

  # CPU & RAM
  stats=$(docker stats nano-node --no-stream --format "{{.CPUPerc}}|{{.MemUsage}}")
  cpu_perc=$(echo "$stats" | cut -d'|' -f1 | tr -d '%')
  node_ram_raw=$(echo "$stats" | cut -d'|' -f2 | awk '{print $1}')
  node_ram=$(echo "$stats" | cut -d'|' -f2 | sed 's/GiB/ GB/g; s/MiB/ MB/g' | awk '{print $1, $2}')
  sys_total_ram=$(free -h | awk '/^Mem:/{print $2}' | sed 's/Gi/ GB/g; s/Mi/ MB/g')

  # CPU frequency & cores
  max_ghz=$(awk '/^cpu MHz/{print $4}' /proc/cpuinfo | sort -n | tail -1 | awk '{printf "%.2f GHz\n", $1/1000}')
  [ -z "$max_ghz" ] && max_ghz="N/A"
  physical_cores=$(lscpu -p | grep -v '^#' | sort -u -t, -k 2,4 | wc -l)
  total_threads=$(nproc)

  # LMDB
  lmdb_mem=$(docker exec nano-node top -bn1 | grep nano_no | head -1 | awk '{print $6}')

  # Power estimate
  power_and_cpu=$(python3 -c "
perc=$cpu_perc; cores=$physical_cores; threads=$total_threads; max_g='$max_ghz'; node_ram_raw='$node_ram_raw'; lmdb='$lmdb_mem'
# perc is already per-logical-core (100% = 1 logical core fully used)
core_usage = round(perc / 100, 2)
if lmdb and lmdb[-1].lower() == 'g':
    lmdb_gb = float(lmdb[:-1])
elif lmdb and lmdb[-1].lower() == 'm':
    lmdb_gb = float(lmdb[:-1]) / 1024
elif lmdb and lmdb[-1].lower() == 'k':
    lmdb_gb = float(lmdb[:-1]) / 1024 / 1024
elif lmdb:
    lmdb_gb = float(lmdb) / 1024 / 1024
else:
    lmdb_gb = 0
import re
node_match = re.match(r'([\d.]+)([a-zA-Z]+)', node_ram_raw)
if node_match:
    node_num = float(node_match.group(1))
    node_unit = node_match.group(2).lower()
    node_gb = node_num if 'g' in node_unit else node_num / 1024
else:
    node_gb = 1.0
cpu_w = core_usage * 5
ram_w = (node_gb * 1.5) + (lmdb_gb * 0.25)
io_w = 5
total_w = cpu_w + ram_w + io_w
if max_g not in ('N/A', ''):
    cpu_ghz = f'{perc/100 * float(max_g.split()[0]):.2f} GHz / {max_g}'
else:
    cpu_ghz = 'N/A'
print(f'{cpu_ghz}|{core_usage}|{lmdb_gb:.2f}|{total_w:.0f}')
")
  cpu_ghz=$(echo "$power_and_cpu" | cut -d'|' -f1)
  core_usage=$(echo "$power_and_cpu" | cut -d'|' -f2)
  lmdb_gb=$(echo "$power_and_cpu" | cut -d'|' -f3)
  power_w=$(echo "$power_and_cpu" | cut -d'|' -f4)

  # Internet
  IFACE=$(ip route get 1.1.1.1 | awk '{print $5}')
  read rx1 tx1 < <(awk -v iface="$IFACE" '$1 ~ iface {print $2,$10}' /proc/net/dev)
  sleep 1
  read rx2 tx2 < <(awk -v iface="$IFACE" '$1 ~ iface {print $2,$10}' /proc/net/dev)
  dl=$(echo "scale=2; ($rx2-$rx1)*8/1048576" | bc)
  ul=$(echo "scale=2; ($tx2-$tx1)*8/1048576" | bc)

  # Cumulative Uptime
  m=$(wc -l < /home/nano-data/uptime_minutes.txt)
  cumulative="$((m/1440))d $((m%1440/60))h $((m%60))m"

  # Network block count (external endpoints, always available)
  net_block=$(get_network_block)

  # Daily version check
  version_msg=$(check_node_version)

  # Representative stats (reads from /home/nano-data/rep_address.txt if set up)
  get_rep_stats

  # RPC-dependent fields
  if is_rpc_ready; then
    tel=$(curl -s -d '{"action":"telemetry"}' http://localhost:7076)
    node_block=$(echo "$tel" | grep -oP '"block_count":\s*"\K\d+')
    peer_count=$(echo "$tel" | grep -oP '"peer_count":\s*"\K\d+')
    v_maj=$(echo "$tel" | grep -oP '"major_version":\s*"\K\d+')
    v_min=$(echo "$tel" | grep -oP '"minor_version":\s*"\K\d+')
    v_pat=$(echo "$tel" | grep -oP '"patch_version":\s*"\K\d+')
    b_cap=$(echo "$tel" | grep -oP '"bandwidth_cap":\s*"\K\d+')
    node_id=$(echo "$tel" | grep -oP '"node_id":\s*"\K[^"]+')
    bw_cap="$((b_cap/1048576)) MB/s"
    node_version="V$v_maj.$v_min.$v_pat"

    # Sync calculation
    sync_line=$(python3 -c "
nb=$node_block if '$node_block' else 0
net=$net_block if '$net_block' else 0
if net == 0:
    print('N/A|N/A')
elif nb >= net:
    print('0|100%')
else:
    gap = net - nb
    pct = nb / net * 100
    pct_truncated = int(pct * 1000) / 1000
    print(f'{gap}|{pct_truncated:.3f}%')
")
    sync_pct=$(echo "$sync_line" | cut -d'|' -f2)

    sync_pct_display="$sync_pct"
    peer_count_display="$peer_count"
    bw_cap_display="$bw_cap"
    node_version_display="$node_version"
    node_id_display="$node_id"
  else
    # Node running but RPC not ready yet
    node_block=""
    sync_pct_display="$INIT"
    peer_count_display="$INIT"
    bw_cap_display="$INIT"
    node_version_display="$INIT"
    node_id_display="$INIT"
  fi

  # --- Render dashboard ---
  echo "======================================================================"
  echo "                     NANO NODE DASHBOARD"
  echo "======================================================================"
  echo " Last Updated: $(date '+%Y-%m-%d %H:%M:%S')    (Auto refresh in 30 seconds)"
  echo "----------------------------------------------------------------------"
  echo ""
  printf " %-22s %s\n"       "CPU Usage"          "$cpu_ghz"
  printf " %-22s %s\n"       "CPU Core Usage"     "$core_usage / $total_threads logical ($physical_cores physical)"
  printf " %-22s %s\n"       "Node RAM Usage"     "$node_ram / $sys_total_ram"
  printf " %-22s %-12s %s\n" "LMDB Memory Map"    "${lmdb_gb} GB"    "(Ledger mapped into RAM by LMDB)"
  printf " %-22s %-12s %s\n" "Power Est. (Watts)" "${power_w} Watts" "(Incl. LMDB Overhead and I/O)"
  printf " %-22s %s\n"       "Internet Usage"     "${dl} Mbps Down / ${ul} Mbps Up"
  echo ""
  printf " %-22s %s\n"       "Cumulative Uptime"  "$cumulative"
  if [[ -n "$node_block" ]]; then
    printf " %-22s ${BLUE}%-12s${NC} %s\n" "Block Count" "$node_block" "(Your Node's Block)"
  else
    printf " %-22s %b\n"     "Block Count"        "$INIT"
  fi
  printf " %-22s %-12s %s\n" "Nano Block"         "$net_block" "(Latest Nano Network's Block)"
  printf " %-22s %b\n"       "Sync %"             "$sync_pct_display"
  printf " %-22s %b\n"       "Peer Count"         "$peer_count_display"
  printf " %-22s %b\n"       "Bandwidth Cap"      "$bw_cap_display"
  echo ""
  printf " %-22s %b\n"       "Node Version:"      "$node_version_display"
  printf " %-22s %b\n"       "Node ID:"           "$node_id_display"
  printf " %-22s %b\n"       "Rep Address:"       "$rep_address_display"
  printf " %-22s %b\n"       "Voting:"            "$voting_display"
  printf " %-22s %b\n"       "Voting Weight:"     "$voting_weight_display"
  printf " %-22s %b\n"       "Voting Weight %:"   "$voting_weight_pct_display"
  echo ""
  echo "----------------------------------------------------------------------"
  echo -e " [${RED}X${RESET}] Stop Node   [${RED}S${RESET}] Start Node   [${RED}R${RESET}] Restart Node   [${RED}CTRL+C${RESET}] Exit"
  echo -e " $version_msg"
  echo " Exit dashboard and type the below commands if required"
  echo -e " Type \e[1;96mrep\e[0m to setup representative | Type \e[1;96mcap\e[0m to optimize bandwidth cap"
  echo -e " To check dashboard again (if stopped) just type \e[93mdashboard\e[0m"
  echo -e " For more info on your node visit  \e[94mnanonoder.com\e[0m"
  echo "======================================================================"
}

handle_keys() {
  local end=$((SECONDS + 30))
  while [ $SECONDS -lt $end ]; do
    if read -r -s -n1 -t1 key; then
      case "$key" in
        X|x)
          if is_node_running; then
            show_message "Stopping Nano Node..."
            sudo docker stop nano-node
            sleep 2
          fi
          return
          ;;
        S|s)
          if ! is_node_running; then
            show_message "Starting Nano Node... please wait"
            sudo docker start nano-node
            sleep 10
          fi
          return
          ;;
        R|r)
          show_message "Restarting Nano Node... please wait"
          sudo docker restart nano-node
          sleep 10
          return
          ;;
      esac
    fi
  done
}

# Main loop
while true; do
  if is_node_running; then
    run_dashboard
  else
    show_offline_banner
  fi
  handle_keys
done
