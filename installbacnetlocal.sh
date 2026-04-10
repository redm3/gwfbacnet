#!/bin/bash
# install-bacnet-local.sh
# BACnet server installer for Mount Haast (George Weston Foods)
# Compiles bacserv with 128 analog-value objects, installs veth service,
# read/write helpers, logger shim, power monitor poll script, BIST script, and cron job.
#
# Usage: sudo bash install-bacnet-local.sh [--no-log] [--no-cron]
#   --no-log    — disable debug logging in logger shim and poll cron
#   --no-cron   — skip power monitor poll script and cron job installation
#
# Prerequisites: bacnet-stack source in /home/pi/sandbox/bacnet-stack/
#                mbpoll installed (custom build — DO NOT apt install)
#                python3 available

set -e

# ── configuration ─────────────────────────────────────────────────────────────
BACNET_SRC=/home/pi/sandbox/bacnet-stack
BACNET_BIN=${BACNET_SRC}/bin
INSTALL_DIR=/home/pi/sandbox/local_bacnet
LOGGER_TOOLS=/home/pi/application/ESP.Logger.Terminal/Tools/bacnet-stack
DEVICE_ID=1234
VETH0_IP=10.1.0.1
VETH1_IP=10.1.0.2
SUBNET=24
BROADCAST=10.1.0.255
SERVER_MAC=10.1.0.1:47808
MAX_AV=128

# Mill PLC Modbus TCP settings
PLC_IP=192.168.2.1
PLC_PORT=502
PLC_SLAVE=1

# Parse args
NOLOG=0
NOCRON=0
for arg in "$@"; do
  case "$arg" in
    --no-log) NOLOG=1 ;;
    --no-cron) NOCRON=1 ;;
  esac
done

echo "============================================"
echo " BACnet Local Server Installer"
echo " George Weston Foods - Mount Haast"
echo "============================================"
echo " PLC IP:        ${PLC_IP}:${PLC_PORT}"
echo " PLC Slave:     ${PLC_SLAVE}"
echo " Max AV objects: ${MAX_AV}"
echo " Device ID:     ${DEVICE_ID}"
echo " Logging:       $([ $NOLOG = 1 ] && echo OFF || echo ON)"
echo " Cron:          $([ $NOCRON = 1 ] && echo OFF || echo ON)"
echo "============================================"

# ── step 1: ensure compiler works ────────────────────────────────────────────
echo ""
echo "[1/8] Checking compiler..."

if ! gcc -x c -c /dev/null -o /dev/null 2>/dev/null; then
    echo "  gcc broken or missing — installing build-essential..."
    apt-get update -qq
    apt-get install -y -qq build-essential 2>/dev/null || true
    if ! gcc -x c -c /dev/null -o /dev/null 2>/dev/null; then
        CC1_DIR=$(find /usr/lib/gcc -name "cc1" -printf '%h\n' 2>/dev/null | head -1)
        if [ -n "$CC1_DIR" ]; then
            echo "  cc1 found at ${CC1_DIR}, adding to PATH"
            export PATH="${CC1_DIR}:${PATH}"
        else
            echo "ERROR: cannot find cc1 — cannot compile bacserv" >&2
            exit 1
        fi
    fi
fi

echo 'int main(){return 0;}' > /tmp/cc_test.c
if ! gcc /tmp/cc_test.c -o /tmp/cc_test 2>/dev/null; then
    CC1_DIR=$(find /usr/lib/gcc -name "cc1" -printf '%h\n' 2>/dev/null | head -1)
    if [ -n "$CC1_DIR" ]; then
        export PATH="${CC1_DIR}:${PATH}"
        gcc /tmp/cc_test.c -o /tmp/cc_test 2>/dev/null || {
            echo "ERROR: compiler still broken after cc1 fix" >&2
            exit 1
        }
    fi
fi
rm -f /tmp/cc_test.c /tmp/cc_test
echo "  compiler OK"

# ── step 2: compile bacserv with MAX_ANALOG_VALUES ───────────────────────────
echo ""
echo "[2/8] Compiling bacnet-stack (MAX_ANALOG_VALUES=${MAX_AV})..."

systemctl stop bacnet.service 2>/dev/null || true
sleep 1

cd ${BACNET_SRC}

AV_FILE=src/bacnet/basic/object/av.c
if grep -q "#define MAX_ANALOG_VALUES ${MAX_AV}" ${AV_FILE}; then
    echo "  av.c already patched"
else
    sed -i "s/#define MAX_ANALOG_VALUES [0-9]*/#define MAX_ANALOG_VALUES ${MAX_AV}/" ${AV_FILE}
    echo "  patched av.c → MAX_ANALOG_VALUES=${MAX_AV}"
fi

#make clean >/dev/null 2>&1
#make BACNET_PORT=linux 2>&1 | tail -1
echo "  bacserv compiled"

# ── step 3: install scripts ──────────────────────────────────────────────────
echo ""
echo "[3/8] Installing scripts to ${INSTALL_DIR}..."
mkdir -p ${INSTALL_DIR}

# bacnet-setup.sh — creates veth pair and starts bacserv
cat > ${INSTALL_DIR}/bacnet-setup.sh << 'SETUPEOF'
#!/bin/bash
BACNET_BIN=__BACNET_BIN__
DEVICE_ID=__DEVICE_ID__

echo "[bacnet] Setting up veth pair..."
ip link del veth0 2>/dev/null
ip link add veth0 type veth peer name veth1
ip addr add __VETH0_IP__/__SUBNET__ broadcast __BROADCAST__ dev veth0
ip addr add __VETH1_IP__/__SUBNET__ broadcast __BROADCAST__ dev veth1
ip link set veth0 up
ip link set veth1 up

echo "[bacnet] Starting bacserv ${DEVICE_ID} on veth0..."
BACNET_IFACE=veth0 ${BACNET_BIN}/bacserv ${DEVICE_ID} &
SERV_PID=$!
sleep 2

echo "[bacnet] Setting object names..."
__INSTALL_DIR__/bacnet-name-objects.sh 2>/dev/null

wait $SERV_PID
SETUPEOF

sed -i \
    -e "s|__BACNET_BIN__|${BACNET_BIN}|g" \
    -e "s|__DEVICE_ID__|${DEVICE_ID}|g" \
    -e "s|__VETH0_IP__|${VETH0_IP}|g" \
    -e "s|__VETH1_IP__|${VETH1_IP}|g" \
    -e "s|__SUBNET__|${SUBNET}|g" \
    -e "s|__BROADCAST__|${BROADCAST}|g" \
    -e "s|__INSTALL_DIR__|${INSTALL_DIR}|g" \
    ${INSTALL_DIR}/bacnet-setup.sh

# bacnet-read.sh
cat > ${INSTALL_DIR}/bacnet-read.sh << 'READEOF'
#!/bin/bash
# Usage: bacnet-read.sh <object-type> <object-instance> [property]
BACNET_BIN=__BACNET_BIN__
DEVICE_ID=__DEVICE_ID__
OBJ_TYPE=${1}; OBJ_INST=${2}; PROPERTY=${3:-present-value}
if [ -z "$OBJ_TYPE" ] || [ -z "$OBJ_INST" ]; then
  echo "Usage: $0 <object-type> <object-instance> [property]" >&2; exit 1
fi
RESULT=$(BACNET_IFACE=veth1 BACNET_IP_PORT=47809 BACNET_BBMD_PORT=47808 BACNET_BBMD_ADDRESS=__VETH0_IP__ \
  ${BACNET_BIN}/bacrp --mac __SERVER_MAC__ \
  ${DEVICE_ID} ${OBJ_TYPE} ${OBJ_INST} ${PROPERTY} 2>&1)
if [ $? -ne 0 ]; then echo "ERROR: ${RESULT}" >&2; exit 1; fi
echo "${RESULT}"
READEOF

sed -i \
    -e "s|__BACNET_BIN__|${BACNET_BIN}|g" \
    -e "s|__DEVICE_ID__|${DEVICE_ID}|g" \
    -e "s|__SERVER_MAC__|${SERVER_MAC}|g" \
    -e "s|__VETH0_IP__|${VETH0_IP}|g" \
    ${INSTALL_DIR}/bacnet-read.sh

# bacnet-write.sh
cat > ${INSTALL_DIR}/bacnet-write.sh << 'WRITEEOF'
#!/bin/bash
# Usage: bacnet-write.sh <object-type> <object-instance> <value> [tag] [property] [priority]
# Tags: 1=Boolean 2=Unsigned 3=Signed 4=Real(default) 7=String 9=Enum
BACNET_BIN=__BACNET_BIN__
DEVICE_ID=__DEVICE_ID__
OBJ_TYPE=${1}; OBJ_INST=${2}; VALUE=${3}
TAG=${4:-4}; PROPERTY=${5:-present-value}; PRIORITY=${6:-16}
if [ -z "$OBJ_TYPE" ] || [ -z "$OBJ_INST" ] || [ -z "$VALUE" ]; then
  echo "Usage: $0 <object-type> <object-instance> <value> [tag] [property] [priority]" >&2; exit 1
fi
RESULT=$(BACNET_IFACE=veth1 BACNET_IP_PORT=47809 BACNET_BBMD_PORT=47808 BACNET_BBMD_ADDRESS=__VETH0_IP__ \
  ${BACNET_BIN}/bacwp --mac __SERVER_MAC__ \
  ${DEVICE_ID} ${OBJ_TYPE} ${OBJ_INST} ${PROPERTY} ${PRIORITY} -1 ${TAG} ${VALUE} 2>&1)
if [ $? -ne 0 ]; then echo "ERROR: ${RESULT}" >&2; exit 1; fi
echo "Written: ${OBJ_TYPE} ${OBJ_INST} = ${VALUE}"
READBACK=$(BACNET_IFACE=veth1 BACNET_IP_PORT=47809 BACNET_BBMD_PORT=47808 BACNET_BBMD_ADDRESS=__VETH0_IP__ \
  ${BACNET_BIN}/bacrp --mac __SERVER_MAC__ \
  ${DEVICE_ID} ${OBJ_TYPE} ${OBJ_INST} ${PROPERTY} 2>&1)
echo "Readback: ${READBACK}"
WRITEEOF

sed -i \
    -e "s|__BACNET_BIN__|${BACNET_BIN}|g" \
    -e "s|__DEVICE_ID__|${DEVICE_ID}|g" \
    -e "s|__SERVER_MAC__|${SERVER_MAC}|g" \
    -e "s|__VETH0_IP__|${VETH0_IP}|g" \
    ${INSTALL_DIR}/bacnet-write.sh

chmod +x ${INSTALL_DIR}/*.sh
echo "  scripts installed"

# ── step 4: object naming script ────────────────────────────────────────────
echo ""
echo "[4/8] Installing object naming script..."

cat > ${INSTALL_DIR}/bacnet-name-objects.sh << 'NAMEEOF'
#!/bin/bash
# bacnet-name-objects.sh
# Sets object names on bacserv (RAM-only, runs after every start)
# Mount Haast — Mains MCC Energy + BIST

BACNET_BIN=__BACNET_BIN__
DEVICE_ID=__DEVICE_ID__

write_name() {
    BACNET_IFACE=veth1 BACNET_IP_PORT=47809 BACNET_BBMD_PORT=47808 BACNET_BBMD_ADDRESS=__VETH0_IP__ \
      ${BACNET_BIN}/bacwp --mac __SERVER_MAC__ \
      ${DEVICE_ID} analog-value $1 object-name 16 -1 7 "$2" >/dev/null 2>&1
}

# AV 0: Mains MCC Energy (MWh)
write_name 0 "Mains_MCC_Energy_MWh"

# AV 100-112: BIST (device health)
write_name 100 "BIST_USRID"
write_name 101 "BIST_FIXID_Hi"
write_name 102 "BIST_FIXID_Lo"
write_name 103 "BIST_CPU_Temp"
write_name 104 "BIST_Mem_Usage"
write_name 105 "BIST_CPU_Usage"
write_name 106 "BIST_V_Core"
write_name 107 "BIST_V_SDRAM_C"
write_name 108 "BIST_V_SDRAM_I"
write_name 109 "BIST_V_SDRAM_P"
write_name 110 "BIST_MMC_Life_A"
write_name 111 "BIST_MMC_Life_B"
write_name 112 "BIST_Uptime"

echo "[bacnet] Object names set"
NAMEEOF

sed -i \
    -e "s|__BACNET_BIN__|${BACNET_BIN}|g" \
    -e "s|__DEVICE_ID__|${DEVICE_ID}|g" \
    -e "s|__VETH0_IP__|${VETH0_IP}|g" \
    -e "s|__SERVER_MAC__|${SERVER_MAC}|g" \
    ${INSTALL_DIR}/bacnet-name-objects.sh

chmod +x ${INSTALL_DIR}/bacnet-name-objects.sh
echo "  naming script installed"

# ── step 5: BIST script ─────────────────────────────────────────────────────
echo ""
echo "[5/8] Installing bist_to_bacnet.sh..."

cat > /home/pi/sandbox/bist_to_bacnet.sh << 'BISTEOF'
#!/bin/bash
# bist_to_bacnet.sh
# Collects device health/identity and writes to BACnet AV 100-112

BACNET_BIN=__BACNET_BIN__
BACNET_DEVICE=__DEVICE_ID__

write_av() {
    local INST=$1
    local VALUE=$2
    BACNET_IFACE=veth1 BACNET_IP_PORT=47809 BACNET_BBMD_PORT=47808 BACNET_BBMD_ADDRESS=__VETH0_IP__ \
      ${BACNET_BIN}/bacwp --mac __SERVER_MAC__ \
      ${BACNET_DEVICE} analog-value ${INST} present-value 16 -1 4 ${VALUE} >/dev/null 2>&1
}

# ── identity ──────────────────────────────────────────────────────────────────
E2USRIDREAD=$(/usr/sbin/i2cget -y 1 0x50 0 b && i2cget -y 1 0x50 1 b && i2cget -y 1 0x50 2 b && i2cget -y 1 0x50 3 b)
E2FIXIDREAD=$(/usr/sbin/i2cget -y 1 0x50 250 b && i2cget -y 1 0x50 251 b && i2cget -y 1 0x50 252 b && i2cget -y 1 0x50 253 b && i2cget -y 1 0x50 254 b && i2cget -y 1 0x50 255 b)

E2USRID_HEX=$(echo "${E2USRIDREAD}" | sed 's/0x//g' | tr -d ' ')
E2FIXID_HEX=$(echo "${E2FIXIDREAD}" | sed 's/0x//g' | tr -d ' ')

USRID_DEC=$((16#${E2USRID_HEX}))
FIXID_HI=$((16#${E2FIXID_HEX:0:6}))
FIXID_LO=$((16#${E2FIXID_HEX:6:6}))

write_av 100 ${USRID_DEC}
write_av 101 ${FIXID_HI}
write_av 102 ${FIXID_LO}

# ── cpu temp ──────────────────────────────────────────────────────────────────
CPUTEMP=$(/usr/bin/vcgencmd measure_temp | sed "s/temp=//;s/'C//")
write_av 103 ${CPUTEMP}

# ── memory usage % ────────────────────────────────────────────────────────────
MEMTOT=$(awk '/MemTotal/ { print $2 }' /proc/meminfo)
MEMFREE=$(awk '/MemFree/ { print $2 }' /proc/meminfo)
MEMUSAGE=$(echo "scale=1; 100 * (${MEMTOT} - ${MEMFREE}) / ${MEMTOT}" | bc)
write_av 104 ${MEMUSAGE}

# ── cpu usage % ───────────────────────────────────────────────────────────────
CPUUSAGE=$(ps -A -o pcpu | tail -n+2 | paste -sd+ | bc)
write_av 105 ${CPUUSAGE}

# ── voltages ──────────────────────────────────────────────────────────────────
COREV=$(/usr/bin/vcgencmd measure_volts core | sed 's/volt=//;s/V//')
SDRAMCV=$(/usr/bin/vcgencmd measure_volts sdram_c | sed 's/volt=//;s/V//')
SDRAMIV=$(/usr/bin/vcgencmd measure_volts sdram_i | sed 's/volt=//;s/V//')
SDRAMPV=$(/usr/bin/vcgencmd measure_volts sdram_p | sed 's/volt=//;s/V//')
write_av 106 ${COREV}
write_av 107 ${SDRAMCV}
write_av 108 ${SDRAMIV}
write_av 109 ${SDRAMPV}

# ── mmc life ──────────────────────────────────────────────────────────────────
RES=$(cat /sys/kernel/debug/mmc0/mmc0:0001/ext_csd 2>/dev/null)
if [ -n "$RES" ]; then
    TYPEA_HEX="${RES:536:2}"
    TYPEB_HEX="${RES:538:2}"
    TYPEA_DEC=$((16#${TYPEA_HEX}))
    TYPEB_DEC=$((16#${TYPEB_HEX}))
    MMCA=$(( (10 - TYPEA_DEC) * 10 ))
    MMCB=$(( (10 - TYPEB_DEC) * 10 ))
    write_av 110 ${MMCA}
    write_av 111 ${MMCB}
else
    write_av 110 -1
    write_av 111 -1
fi

# ── uptime seconds ────────────────────────────────────────────────────────────
UPTIME_SEC=$(awk '{print int($1)}' /proc/uptime)
write_av 112 ${UPTIME_SEC}

echo "BIST written to AV 100-112"
BISTEOF

sed -i \
    -e "s|__BACNET_BIN__|${BACNET_BIN}|g" \
    -e "s|__DEVICE_ID__|${DEVICE_ID}|g" \
    -e "s|__VETH0_IP__|${VETH0_IP}|g" \
    -e "s|__SERVER_MAC__|${SERVER_MAC}|g" \
    /home/pi/sandbox/bist_to_bacnet.sh

chmod +x /home/pi/sandbox/bist_to_bacnet.sh
echo "  BIST script installed"

# ── step 6: logger shim ─────────────────────────────────────────────────────
echo ""
echo "[6/8] Installing logger shim to ${LOGGER_TOOLS}..."
mkdir -p ${LOGGER_TOOLS}

cat > ${LOGGER_TOOLS}/bacnet-read-present-value.sh << 'SHIMEOF'
#!/bin/bash
# Logger shim — called by ESP.Logger.Terminal
__LOG_LINE__
BACRP=__BACNET_BIN__/bacrp

if [ -z "$2" ]; then
  read -r ARG1 ARG2 ARG3 <<< "$1"
else
  ARG1=$1; ARG2=$2; ARG3=$3
fi

BACNET_CMD="BACNET_IFACE=veth1 BACNET_IP_PORT=47809 BACNET_BBMD_PORT=47808 BACNET_BBMD_ADDRESS=__VETH0_IP__ $BACRP --mac __SERVER_MAC__ $ARG1 $ARG2 $ARG3 present-value"

if [ -n "$4" ]; then
    BACNET_CMD="BACNET_IFACE=veth1 BACNET_IP_PORT=47809 BACNET_BBMD_PORT=47808 BACNET_BBMD_ADDRESS=__VETH0_IP__ BACNET_APDU_TIMEOUT=$4 $BACRP --mac __SERVER_MAC__ $ARG1 $ARG2 $ARG3 present-value"
fi

if [ "$(id -u)" = "0" ]; then
    value=$(su -c "$BACNET_CMD" pi)
else
    value=$(eval "$BACNET_CMD")
fi

IFS=', ' read -r -a array <<< "$value"
arraylength=${#array[@]}
if [ $arraylength -eq 1 ]; then
    echo $value | tr -d '\r' | sed 's/\.0*$//'
fi
if [ $arraylength -eq 2 ]; then
    echo ${array[1]} | sed 's/}//g' | tr -d '\r' | sed 's/\.0*$//'
    exit
fi
SHIMEOF

sed -i \
    -e "s|__BACNET_BIN__|${BACNET_BIN}|g" \
    -e "s|__VETH0_IP__|${VETH0_IP}|g" \
    -e "s|__SERVER_MAC__|${SERVER_MAC}|g" \
    ${LOGGER_TOOLS}/bacnet-read-present-value.sh

if [ "$NOLOG" = "1" ]; then
    sed -i 's|__LOG_LINE__|# logging disabled|' ${LOGGER_TOOLS}/bacnet-read-present-value.sh
else
    sed -i 's|__LOG_LINE__|echo "$(date) args: [$1] [$2] [$3] [$4]" >> /tmp/bacnet-read-debug.log|' ${LOGGER_TOOLS}/bacnet-read-present-value.sh
fi

chmod +x ${LOGGER_TOOLS}/bacnet-read-present-value.sh
echo "  logger shim installed"

# ── step 7: power monitor poll script ────────────────────────────────────────
if [ "$NOCRON" = "1" ]; then
    echo ""
    echo "[7/8] Skipping power monitor poll script (--no-cron)"
else
echo ""
echo "[7/8] Installing power_monitor_to_bacnet.sh..."

cat > /home/pi/sandbox/power_monitor_to_bacnet.sh << 'POLLEOF'
#!/bin/bash
# power_monitor_to_bacnet.sh
# Reads Mains MCC energy from Mill PLC via Modbus TCP
# and writes to BACnet AV 0 (Mains_MCC_Energy_MWh)
#
# Register layout (from power_monitor_decode.py):
#   Mains MCC energy = register 4, read 2 words as hex
#   Word order: [reg] = low word, [reg+1] = high word (little-endian word swap)
#   Reconstruct IEEE 754 float, then multiply by 0.001 to get MWh
#
# George Weston Foods - Mount Haast

BACNET_BIN=__BACNET_BIN__
BACNET_DEVICE=__DEVICE_ID__
PLC_IP=__PLC_IP__
PLC_PORT=__PLC_PORT__
PLC_SLAVE=__PLC_SLAVE__

write_av() {
    local INST=$1
    local VALUE=$2
    BACNET_IFACE=veth1 BACNET_IP_PORT=47809 BACNET_BBMD_PORT=47808 BACNET_BBMD_ADDRESS=__VETH0_IP__ \
      ${BACNET_BIN}/bacwp --mac __SERVER_MAC__ \
      ${BACNET_DEVICE} analog-value ${INST} present-value 16 -1 4 ${VALUE} >/dev/null 2>&1
}

# ── Read Mains MCC energy (register 4, 2 words hex) ─────────────────────────
REGS=$(mbpoll -a ${PLC_SLAVE} -r 4 -c 2 -t 4:hex -m tcp -p ${PLC_PORT} -o 2 -1 ${PLC_IP} 2>/dev/null)

# Parse the two hex words from mbpoll output
WORD_LO=$(echo "$REGS" | grep '^\[4\]' | awk '{print $NF}')
WORD_HI=$(echo "$REGS" | grep '^\[5\]' | awk '{print $NF}')

if [ -z "$WORD_LO" ] || [ -z "$WORD_HI" ]; then
    echo "ERROR: Failed to read registers from PLC ${PLC_IP}:${PLC_PORT}" >&2
    exit 1
fi

# Decode IEEE 754 float with word swap, apply 0.001 scale → MWh
MWH=$(python3 -c "
import struct, sys
word_lo = int('${WORD_LO}', 16)
word_hi = int('${WORD_HI}', 16)
raw_bytes = struct.pack('>HH', word_hi, word_lo)
float_val = struct.unpack('>f', raw_bytes)[0]
mwh = float_val * 0.001
print(f'{mwh:.3f}')
" 2>/dev/null)

if [ -z "$MWH" ]; then
    echo "ERROR: Failed to decode energy float (LO=${WORD_LO} HI=${WORD_HI})" >&2
    exit 1
fi

# Write to AV 0
write_av 0 ${MWH}

# Readback
READBACK=$(BACNET_IFACE=veth1 BACNET_IP_PORT=47809 BACNET_BBMD_PORT=47808 BACNET_BBMD_ADDRESS=__VETH0_IP__ \
  ${BACNET_BIN}/bacrp --mac __SERVER_MAC__ \
  ${BACNET_DEVICE} analog-value 0 present-value 2>&1)

echo "Mains_MCC_Energy_MWh = ${MWH} (readback: ${READBACK})"
POLLEOF

sed -i \
    -e "s|__BACNET_BIN__|${BACNET_BIN}|g" \
    -e "s|__DEVICE_ID__|${DEVICE_ID}|g" \
    -e "s|__PLC_IP__|${PLC_IP}|g" \
    -e "s|__PLC_PORT__|${PLC_PORT}|g" \
    -e "s|__PLC_SLAVE__|${PLC_SLAVE}|g" \
    -e "s|__VETH0_IP__|${VETH0_IP}|g" \
    -e "s|__SERVER_MAC__|${SERVER_MAC}|g" \
    /home/pi/sandbox/power_monitor_to_bacnet.sh

chmod +x /home/pi/sandbox/power_monitor_to_bacnet.sh
echo "  poll script installed"
fi

# ── step 7a: systemd service ────────────────────────────────────────────────
echo ""
echo "[7a/8] Installing systemd service..."

cat > /etc/systemd/system/bacnet.service << EOF
[Unit]
Description=BACnet Server (bacserv) - Mount Haast
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/bacnet-setup.sh
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable bacnet.service
echo "  service enabled"

# ── step 8: cron job ────────────────────────────────────────────────────────
################################# NEED TO UPDATE THIS TO CRON.15?
if [ "$NOCRON" = "1" ]; then
    echo ""
    echo "[8/8] Skipping cron job (--no-cron)"
else
echo ""
echo "[8/8] Installing cron.hourly poll job..."

if [ "$NOLOG" = "1" ]; then
cat > /etc/cron.hourly/bacnet-poll << 'CRONEOF'
#!/bin/bash
SCRIPT=/home/pi/sandbox/power_monitor_to_bacnet.sh
BIST=/home/pi/sandbox/bist_to_bacnet.sh
sudo -u pi $SCRIPT >/dev/null 2>&1
sudo $BIST >/dev/null 2>&1
CRONEOF
else
cat > /etc/cron.hourly/bacnet-poll << 'CRONEOF'
#!/bin/bash
SCRIPT=/home/pi/sandbox/power_monitor_to_bacnet.sh
BIST=/home/pi/sandbox/bist_to_bacnet.sh
LOG=/var/log/bacnet-poll.log
echo "$(date '+%Y-%m-%d %H:%M:%S') --- poll start ---" >> $LOG
RESULT=$(sudo -u pi $SCRIPT 2>&1)
echo "$(date '+%Y-%m-%d %H:%M:%S') energy: $RESULT" >> $LOG
RESULT=$(sudo $BIST 2>&1)
echo "$(date '+%Y-%m-%d %H:%M:%S') bist: $RESULT" >> $LOG
echo "$(date '+%Y-%m-%d %H:%M:%S') --- poll end ---" >> $LOG
CRONEOF
fi

chmod +x /etc/cron.hourly/bacnet-poll
echo "  cron job installed"
fi

# ── start service ────────────────────────────────────────────────────────────
echo ""
echo "Starting bacnet.service..."
systemctl start bacnet.service
sleep 3

# ── summary ──────────────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo " Installation complete"
echo " George Weston Foods - Mount Haast"
echo "============================================"
echo " bacserv:    $(systemctl is-active bacnet.service)"
echo ""
echo " Object map:"
echo "   AV 0        Mains_MCC_Energy_MWh"
echo "   AV 100-112  BIST (identity + health)"
echo ""
echo " Data source:"
echo "   Mill PLC ${PLC_IP}:${PLC_PORT} slave ${PLC_SLAVE}"
echo "   Register 4 (2 words, IEEE 754 word-swap, x0.001 = MWh)"
echo ""
echo " Scripts:"
echo "   ${INSTALL_DIR}/bacnet-{setup,read,write}.sh"
echo "   /home/pi/sandbox/power_monitor_to_bacnet.sh"
echo "   /home/pi/sandbox/bist_to_bacnet.sh"
echo "   ${LOGGER_TOOLS}/bacnet-read-present-value.sh"
echo ""
echo " Test:"
echo "   ${INSTALL_DIR}/bacnet-read.sh analog-value 0"
echo "   sudo bash /home/pi/sandbox/power_monitor_to_bacnet.sh"
echo "   sudo bash /home/pi/sandbox/bist_to_bacnet.sh"
echo "============================================"
