#!/bin/bash
# installbacnet_smythe.sh
# BACnet server installer for 3 Smythe Road (Bayleys Property Services)
# 1x Milesight EM300-DI via ADFweb HD67F04 gateway
# Pulse count → BACnet AV 0
# Battery → BACnet AV 1
#
# Usage: sudo bash installbacnet_smythe.sh [--no-log] [--no-cron]
#
# Prerequisites: bacnet-stack source in /home/pi/sandbox/bacnet-stack/
#                mbpoll installed (custom build)
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
GW_IP=192.168.2.188
GW_PORT=502
GW_SLAVE=1
# EM300-DI D1 register map (position bytes starting at 10)
# Reg 6 = Temp, Reg 7 = Humid, Reg 8+9 = Pulse (float32 DCBA), Reg 10 = Battery
D1_PULSE_REG=8
D1_BATT_REG=10

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
echo " 3 Smythe Road - Bayleys Property Services"
echo "============================================"
echo " Gateway IP:     ${GW_IP}:${GW_PORT}"
echo " Max AV objects: ${MAX_AV}"
echo " Device ID:      ${DEVICE_ID}"
echo " Logging:        $([ $NOLOG = 1 ] && echo OFF || echo ON)"
echo " Cron:           $([ $NOCRON = 1 ] && echo OFF || echo ON)"
echo "============================================"

# ── step 1: compiler check ────────────────────────────────────────────────────
echo ""
echo "[1/8] Checking compiler..."
echo 'int main(){return 0;}' > /tmp/cc_test.c
if ! gcc /tmp/cc_test.c -o /tmp/cc_test 2>/dev/null; then
    CC1_DIR=$(find /usr/lib/gcc -name "cc1" -printf '%h\n' 2>/dev/null | head -1)
    [ -n "$CC1_DIR" ] && export PATH="${CC1_DIR}:${PATH}"
    gcc /tmp/cc_test.c -o /tmp/cc_test 2>/dev/null || { echo "ERROR: compiler broken" >&2; exit 1; }
fi
rm -f /tmp/cc_test.c /tmp/cc_test
echo "  compiler OK"

# ── step 2: compile bacserv ───────────────────────────────────────────────────
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
    echo "  patched av.c"
fi
make clean >/dev/null 2>&1
make BACNET_PORT=linux 2>&1 | tail -1
echo "  bacserv compiled"

# ── step 3: install scripts ───────────────────────────────────────────────────
echo ""
echo "[3/8] Installing scripts to ${INSTALL_DIR}..."
mkdir -p ${INSTALL_DIR}

cat > ${INSTALL_DIR}/bacnet-setup.sh << SETUPEOF
#!/bin/bash
BACNET_BIN=${BACNET_BIN}
DEVICE_ID=${DEVICE_ID}
echo "[bacnet] Setting up veth pair..."
ip link del veth0 2>/dev/null
ip link add veth0 type veth peer name veth1
ip addr add ${VETH0_IP}/${SUBNET} broadcast ${BROADCAST} dev veth0
ip addr add ${VETH1_IP}/${SUBNET} broadcast ${BROADCAST} dev veth1
ip link set veth0 up
ip link set veth1 up
echo "[bacnet] Starting bacserv \${DEVICE_ID} on veth0..."
BACNET_IFACE=veth0 \${BACNET_BIN}/bacserv \${DEVICE_ID} &
SERV_PID=\$!
sleep 2
echo "[bacnet] Setting object names..."
${INSTALL_DIR}/bacnet-name-objects.sh 2>/dev/null
wait \$SERV_PID
SETUPEOF

cat > ${INSTALL_DIR}/bacnet-read.sh << READEOF
#!/bin/bash
# Usage: bacnet-read.sh <object-type> <object-instance> [property]
BACNET_BIN=${BACNET_BIN}
DEVICE_ID=${DEVICE_ID}
OBJ_TYPE=\${1}; OBJ_INST=\${2}; PROPERTY=\${3:-present-value}
if [ -z "\$OBJ_TYPE" ] || [ -z "\$OBJ_INST" ]; then
  echo "Usage: \$0 <object-type> <object-instance> [property]" >&2; exit 1
fi
RESULT=\$(BACNET_IFACE=veth1 BACNET_IP_PORT=47809 BACNET_BBMD_PORT=47808 BACNET_BBMD_ADDRESS=${VETH0_IP} \
  \${BACNET_BIN}/bacrp --mac ${SERVER_MAC} \
  \${DEVICE_ID} \${OBJ_TYPE} \${OBJ_INST} \${PROPERTY} 2>&1)
if [ \$? -ne 0 ]; then echo "ERROR: \${RESULT}" >&2; exit 1; fi
echo "\${RESULT}"
READEOF

cat > ${INSTALL_DIR}/bacnet-write.sh << WRITEEOF
#!/bin/bash
# Usage: bacnet-write.sh <object-type> <object-instance> <value> [tag] [property] [priority]
BACNET_BIN=${BACNET_BIN}
DEVICE_ID=${DEVICE_ID}
OBJ_TYPE=\${1}; OBJ_INST=\${2}; VALUE=\${3}
TAG=\${4:-4}; PROPERTY=\${5:-present-value}; PRIORITY=\${6:-16}
if [ -z "\$OBJ_TYPE" ] || [ -z "\$OBJ_INST" ] || [ -z "\$VALUE" ]; then
  echo "Usage: \$0 <object-type> <object-instance> <value> [tag] [property] [priority]" >&2; exit 1
fi
RESULT=\$(BACNET_IFACE=veth1 BACNET_IP_PORT=47809 BACNET_BBMD_PORT=47808 BACNET_BBMD_ADDRESS=${VETH0_IP} \
  \${BACNET_BIN}/bacwp --mac ${SERVER_MAC} \
  \${DEVICE_ID} \${OBJ_TYPE} \${OBJ_INST} \${PROPERTY} \${PRIORITY} -1 \${TAG} \${VALUE} 2>&1)
if [ \$? -ne 0 ]; then echo "ERROR: \${RESULT}" >&2; exit 1; fi
echo "Written: \${OBJ_TYPE} \${OBJ_INST} = \${VALUE}"
READBACK=\$(BACNET_IFACE=veth1 BACNET_IP_PORT=47809 BACNET_BBMD_PORT=47808 BACNET_BBMD_ADDRESS=${VETH0_IP} \
  \${BACNET_BIN}/bacrp --mac ${SERVER_MAC} \
  \${DEVICE_ID} \${OBJ_TYPE} \${OBJ_INST} \${PROPERTY} 2>&1)
echo "Readback: \${READBACK}"
WRITEEOF

chmod +x ${INSTALL_DIR}/*.sh
echo "  scripts installed"

# ── step 4: object naming script ──────────────────────────────────────────────
echo ""
echo "[4/8] Installing object naming script..."

cat > ${INSTALL_DIR}/bacnet-name-objects.sh << NAMEEOF
#!/bin/bash
BACNET_BIN=${BACNET_BIN}
DEVICE_ID=${DEVICE_ID}
write_name() {
    BACNET_IFACE=veth1 BACNET_IP_PORT=47809 BACNET_BBMD_PORT=47808 BACNET_BBMD_ADDRESS=${VETH0_IP} \
      \${BACNET_BIN}/bacwp --mac ${SERVER_MAC} \
      \${DEVICE_ID} analog-value \$1 object-name 16 -1 7 "\$2" >/dev/null 2>&1
}
write_name 0 "D1_Pulse_Count"
write_name 1 "D1_Battery_Pct"
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

chmod +x ${INSTALL_DIR}/bacnet-name-objects.sh
echo "  naming script installed"

# ── step 5: BIST script ───────────────────────────────────────────────────────
echo ""
echo "[5/8] Installing bist_to_bacnet.sh..."

cat > /home/pi/sandbox/bist_to_bacnet.sh << BISTEOF
#!/bin/bash
BACNET_BIN=${BACNET_BIN}
BACNET_DEVICE=${DEVICE_ID}
write_av() {
    local INST=\$1
    local VALUE=\$2
    BACNET_IFACE=veth1 BACNET_IP_PORT=47809 BACNET_BBMD_PORT=47808 BACNET_BBMD_ADDRESS=${VETH0_IP} \
      \${BACNET_BIN}/bacwp --mac ${SERVER_MAC} \
      \${BACNET_DEVICE} analog-value \${INST} present-value 16 -1 4 \${VALUE} >/dev/null 2>&1
}
E2USRIDREAD=\$(/usr/sbin/i2cget -y 1 0x50 0 b && i2cget -y 1 0x50 1 b && i2cget -y 1 0x50 2 b && i2cget -y 1 0x50 3 b)
E2FIXIDREAD=\$(/usr/sbin/i2cget -y 1 0x50 250 b && i2cget -y 1 0x50 251 b && i2cget -y 1 0x50 252 b && i2cget -y 1 0x50 253 b && i2cget -y 1 0x50 254 b && i2cget -y 1 0x50 255 b)
E2USRID_HEX=\$(echo "\${E2USRIDREAD}" | sed 's/0x//g' | tr -d ' ')
E2FIXID_HEX=\$(echo "\${E2FIXIDREAD}" | sed 's/0x//g' | tr -d ' ')
USRID_DEC=\$((16#\${E2USRID_HEX}))
FIXID_HI=\$((16#\${E2FIXID_HEX:0:6}))
FIXID_LO=\$((16#\${E2FIXID_HEX:6:6}))
write_av 100 \${USRID_DEC}
write_av 101 \${FIXID_HI}
write_av 102 \${FIXID_LO}
CPUTEMP=\$(/usr/bin/vcgencmd measure_temp | sed "s/temp=//;s/'C//")
write_av 103 \${CPUTEMP}
MEMTOT=\$(awk '/MemTotal/ { print \$2 }' /proc/meminfo)
MEMFREE=\$(awk '/MemFree/ { print \$2 }' /proc/meminfo)
MEMUSAGE=\$(echo "scale=1; 100 * (\${MEMTOT} - \${MEMFREE}) / \${MEMTOT}" | bc)
write_av 104 \${MEMUSAGE}
CPUUSAGE=\$(ps -A -o pcpu | tail -n+2 | paste -sd+ | bc)
write_av 105 \${CPUUSAGE}
COREV=\$(/usr/bin/vcgencmd measure_volts core | sed 's/volt=//;s/V//')
SDRAMCV=\$(/usr/bin/vcgencmd measure_volts sdram_c | sed 's/volt=//;s/V//')
SDRAMIV=\$(/usr/bin/vcgencmd measure_volts sdram_i | sed 's/volt=//;s/V//')
SDRAMPV=\$(/usr/bin/vcgencmd measure_volts sdram_p | sed 's/volt=//;s/V//')
write_av 106 \${COREV}
write_av 107 \${SDRAMCV}
write_av 108 \${SDRAMIV}
write_av 109 \${SDRAMPV}
RES=\$(cat /sys/kernel/debug/mmc0/mmc0:0001/ext_csd 2>/dev/null)
if [ -n "\$RES" ]; then
    TYPEA_HEX="\${RES:536:2}"
    TYPEB_HEX="\${RES:538:2}"
    TYPEA_DEC=\$((16#\${TYPEA_HEX}))
    TYPEB_DEC=\$((16#\${TYPEB_HEX}))
    MMCA=\$(( (10 - TYPEA_DEC) * 10 ))
    MMCB=\$(( (10 - TYPEB_DEC) * 10 ))
    write_av 110 \${MMCA}
    write_av 111 \${MMCB}
else
    write_av 110 -1
    write_av 111 -1
fi
UPTIME_SEC=\$(awk '{print int(\$1)}' /proc/uptime)
write_av 112 \${UPTIME_SEC}
echo "BIST written to AV 100-112"
BISTEOF

chmod +x /home/pi/sandbox/bist_to_bacnet.sh
echo "  BIST script installed"

# ── step 6: logger shim ───────────────────────────────────────────────────────
echo ""
echo "[6/8] Installing logger shim to ${LOGGER_TOOLS}..."
mkdir -p ${LOGGER_TOOLS}

cat > ${LOGGER_TOOLS}/bacnet-read-present-value.sh << SHIMEOF
#!/bin/bash
# Logger shim — called by ESP.Logger.Terminal
BACRP=${BACNET_BIN}/bacrp
if [ -z "\$2" ]; then
  read -r ARG1 ARG2 ARG3 <<< "\$1"
else
  ARG1=\$1; ARG2=\$2; ARG3=\$3
fi
BACNET_CMD="BACNET_IFACE=veth1 BACNET_IP_PORT=47809 BACNET_BBMD_PORT=47808 BACNET_BBMD_ADDRESS=${VETH0_IP} \$BACRP --mac ${SERVER_MAC} \$ARG1 \$ARG2 \$ARG3 present-value"
if [ -n "\$4" ]; then
    BACNET_CMD="BACNET_IFACE=veth1 BACNET_IP_PORT=47809 BACNET_BBMD_PORT=47808 BACNET_BBMD_ADDRESS=${VETH0_IP} BACNET_APDU_TIMEOUT=\$4 \$BACRP --mac ${SERVER_MAC} \$ARG1 \$ARG2 \$ARG3 present-value"
fi
if [ "\$(id -u)" = "0" ]; then
    value=\$(su -c "\$BACNET_CMD" pi)
else
    value=\$(eval "\$BACNET_CMD")
fi
IFS=', ' read -r -a array <<< "\$value"
arraylength=\${#array[@]}
if [ \$arraylength -eq 1 ]; then
    echo \$value | tr -d '\r' | sed 's/\.0*\$//'
fi
if [ \$arraylength -eq 2 ]; then
    echo \${array[1]} | sed 's/}//g' | tr -d '\r' | sed 's/\.0*\$//'
    exit
fi
SHIMEOF

if [ "$NOLOG" = "1" ]; then
    sed -i '2a # logging disabled' ${LOGGER_TOOLS}/bacnet-read-present-value.sh
else
    sed -i '2a echo "$(date) args: [$1] [$2] [$3] [$4]" >> /tmp/bacnet-read-debug.log' ${LOGGER_TOOLS}/bacnet-read-present-value.sh
fi

chmod +x ${LOGGER_TOOLS}/bacnet-read-present-value.sh
echo "  logger shim installed"

# ── step 7: EM300-DI poll script ──────────────────────────────────────────────
if [ "$NOCRON" = "1" ]; then
    echo ""
    echo "[7/8] Skipping poll script (--no-cron)"
else
echo ""
echo "[7/8] Installing em300di_to_bacnet.sh..."

cat > /home/pi/sandbox/em300di_to_bacnet.sh << POLLEOF
#!/bin/bash
# em300di_to_bacnet.sh
# Reads Milesight EM300-DI pulse count and battery via Modbus TCP
# Decodes pulse as DCBA float32, writes to BACnet AV 0 and AV 1
# 3 Smythe Road — Bayleys Property Services
BACNET_BIN=${BACNET_BIN}
BACNET_DEVICE=${DEVICE_ID}
GW=${GW_IP}
PORT=${GW_PORT}
SLAVE=${GW_SLAVE}
PULSE_REG=${D1_PULSE_REG}
BATT_REG=${D1_BATT_REG}
write_av() {
    local INST=\$1
    local VALUE=\$2
    BACNET_IFACE=veth1 BACNET_IP_PORT=47809 BACNET_BBMD_PORT=47808 BACNET_BBMD_ADDRESS=${VETH0_IP} \
      \${BACNET_BIN}/bacwp --mac ${SERVER_MAC} \
      \${BACNET_DEVICE} analog-value \${INST} present-value 16 -1 4 \${VALUE} >/dev/null 2>&1
}
# Read pulse registers (2 x 16-bit hex)
REGS=\$(mbpoll -a \${SLAVE} -r \${PULSE_REG} -c 2 -t 3:hex -m tcp \${GW} -p \${PORT} -1 2>/dev/null)
R1=\$(echo "\$REGS" | grep "^\[\${PULSE_REG}\]" | awk '{print \$2}')
R2=\$(echo "\$REGS" | grep "^\[\$((PULSE_REG+1))\]" | awk '{print \$2}')
if [ -z "\$R1" ]; then
    echo "ERROR: Cannot reach gateway \${GW}:\${PORT}" >&2
    exit 1
fi
# Decode DCBA float32 (little-endian word swap)
PULSE=\$(python3 -c "
import struct
r1 = int('\${R1}', 16)
r2 = int('\${R2}', 16)
b = bytes([(r1>>8)&0xFF, r1&0xFF, (r2>>8)&0xFF, r2&0xFF])
val = struct.unpack('<f', b)[0]
print(f'{val:.0f}')
" 2>/dev/null)
if [ -z "\$PULSE" ]; then
    echo "ERROR: Failed to decode pulse float (R1=\${R1} R2=\${R2})" >&2
    exit 1
fi
# Write pulse to AV 0
write_av 0 \${PULSE}
# Read battery (single reg, high byte = %)
BREG=\$(mbpoll -a \${SLAVE} -r \${BATT_REG} -c 1 -t 3:hex -m tcp \${GW} -p \${PORT} -1 2>/dev/null)
BRAW=\$(echo "\$BREG" | grep "^\[\${BATT_REG}\]" | awk '{print \$2}')
if [ -n "\$BRAW" ]; then
    BATTERY=\$(python3 -c "print((int('\${BRAW}',16) >> 8) & 0xFF)")
    write_av 1 \${BATTERY}
fi
# Readback
READBACK=\$(BACNET_IFACE=veth1 BACNET_IP_PORT=47809 BACNET_BBMD_PORT=47808 BACNET_BBMD_ADDRESS=${VETH0_IP} \
  \${BACNET_BIN}/bacrp --mac ${SERVER_MAC} \
  \${BACNET_DEVICE} analog-value 0 present-value 2>&1)
echo "D1 Pulse=\${PULSE} Battery=\${BATTERY:-?} (readback: \${READBACK})"
POLLEOF

chmod +x /home/pi/sandbox/em300di_to_bacnet.sh
echo "  poll script installed"
fi

# ── step 7a: systemd service ──────────────────────────────────────────────────
echo ""
echo "[7a/8] Installing systemd service..."

cat > /etc/systemd/system/bacnet.service << EOF
[Unit]
Description=BACnet Server (bacserv) - 3 Smythe Road
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

# ── step 8: cron job ──────────────────────────────────────────────────────────
if [ "$NOCRON" = "1" ]; then
    echo ""
    echo "[8/8] Skipping cron job (--no-cron)"
else
echo ""
echo "[8/8] Installing 15-minute cron poll job..."
rm -f /etc/cron.hourly/bacnet-poll

if [ "$NOLOG" = "1" ]; then
cat > /home/pi/sandbox/bacnet-poll-cron.sh << CRONEOF
#!/bin/bash
SCRIPT=/home/pi/sandbox/em300di_to_bacnet.sh
BIST=/home/pi/sandbox/bist_to_bacnet.sh
sudo -u pi \$SCRIPT >/dev/null 2>&1
sudo \$BIST >/dev/null 2>&1
CRONEOF
else
cat > /home/pi/sandbox/bacnet-poll-cron.sh << CRONEOF
#!/bin/bash
SCRIPT=/home/pi/sandbox/em300di_to_bacnet.sh
BIST=/home/pi/sandbox/bist_to_bacnet.sh
LOG=/var/log/bacnet-poll.log
echo "\$(date '+%Y-%m-%d %H:%M:%S') --- poll start ---" >> \$LOG
RESULT=\$(sudo -u pi \$SCRIPT 2>&1)
echo "\$(date '+%Y-%m-%d %H:%M:%S') em300di: \$RESULT" >> \$LOG
RESULT=\$(sudo \$BIST 2>&1)
echo "\$(date '+%Y-%m-%d %H:%M:%S') bist: \$RESULT" >> \$LOG
echo "\$(date '+%Y-%m-%d %H:%M:%S') --- poll end ---" >> \$LOG
CRONEOF
fi

chmod +x /home/pi/sandbox/bacnet-poll-cron.sh
CRONLINE="*/15 * * * * /home/pi/sandbox/bacnet-poll-cron.sh"
( crontab -l 2>/dev/null | grep -v bacnet-poll-cron ; echo "$CRONLINE" ) | crontab -
echo "  15-minute cron job installed"
fi

# ── start service ─────────────────────────────────────────────────────────────
echo ""
echo "Starting bacnet.service..."
systemctl start bacnet.service
sleep 3

# ── summary ───────────────────────────────────────────────────────────────────
echo ""
echo "============================================"
echo " Installation complete"
echo " 3 Smythe Road - Bayleys Property Services"
echo "============================================"
echo " bacserv: $(systemctl is-active bacnet.service)"
echo ""
echo " Object map:"
echo "   AV 0        D1_Pulse_Count"
echo "   AV 1        D1_Battery_Pct"
echo "   AV 100-112  BIST"
echo ""
echo " Gateway: ${GW_IP}:${GW_PORT} slave ${GW_SLAVE}"
echo " Poll: every 15 minutes (root crontab)"
echo ""
echo " Test:"
echo "   ${INSTALL_DIR}/bacnet-read.sh analog-value 0"
echo "   sudo bash /home/pi/sandbox/em300di_to_bacnet.sh"
echo "============================================"
