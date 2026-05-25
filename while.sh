#!/bin/bash
hosts='
10.0.5.1 C-Spine01
10.0.5.2 C-Spine02
10.0.5.3 C-Spine03
10.0.5.4 C-Spine04
10.0.5.5 C-Spine05
10.0.5.6 C-Spine06
10.0.5.7 C-Spine07
10.0.5.8 C-Spine08
10.0.5.9 C-Spine09
10.0.5.10 C-Spine10
10.0.5.11 C-Spine11
10.0.5.12 C-Spine12
10.0.5.13 C-Spine13
10.0.5.14 C-Spine14
10.0.5.15 C-Spine15
10.0.5.16 C-Spine16
10.0.5.17 C-Spine17
10.0.5.18 C-Spine18
10.0.5.19 C-Spine19
10.0.5.20 C-Spine20
10.0.5.21 C-Spine21
10.0.5.22 C-Spine22
10.0.5.23 C-Spine23
10.0.5.24 C-Spine24
10.0.5.25 C-Spine25
10.0.5.26 C-Spine26
10.0.5.27 C-Spine27
10.0.5.28 C-Spine28
10.0.5.29 C-Spine29
10.0.5.30 C-Spine30
10.0.5.31 C-Spine31
10.0.5.32 C-Spine32
10.0.5.33 C-Spine33
10.0.5.34 C-Spine34
10.0.5.35 C-Spine35
10.0.5.36 C-Spine36
10.0.5.37 C-Spine37
10.0.5.38 C-Spine38
10.0.5.39 C-Spine39
10.0.5.40 C-Spine40
10.0.5.41 C-Spine41
10.0.5.42 C-Spine42
10.0.5.43 C-Spine43
10.0.5.44 C-Spine44
10.0.5.45 C-Spine45
10.0.5.46 C-Spine46
10.0.5.47 C-Spine47
10.0.5.48 C-Spine48
10.0.5.49 C-Spine49
10.0.5.50 C-Spine50
10.0.5.51 C-Spine51
10.0.5.52 C-Spine52
10.0.5.53 C-Spine53
10.0.5.54 C-Spine54
10.0.5.55 C-Spine55
10.0.5.56 C-Spine56
10.0.5.57 C-Spine57
10.0.5.58 C-Spine58
10.0.5.59 C-Spine59
10.0.5.60 C-Spine60
10.0.5.61 C-Spine61
10.0.5.62 C-Spine62
10.0.5.63 C-Spine63
10.0.5.64 C-Spine64
'
while read -r host hostname; do
[ -z "$host" ] && continue
echo "
conf t
alarm 
no container-feature snmp shutdown
no container-feature telemetry shutdown
snmp-server protocol enable
snmp-agent version v2c
snmp-agent community RO
zx1qaz@WSX
infrawaves@2026
no snmp-agent community
Switch@123
snmp-agent config vrf mgmt source-ip $host udp-port 161
snmp-agent enable
snmp-server version v2c
snmp-server host 10.226.16.4 vrf mgmt traps udp_port 9162
grpc dst-group venus vrf mgmt
 dst-addr 10.226.16.4 57003
exit
grpc publish PfcTxCounters dst-group venus
grpc publish PfcRxCounters dst-group venus
grpc publish EcnMarkedCounters dst-group venus
grpc publish QueueCounters dst-group venus
grpc subscription component
dst-group venus
path-target STATE_DB
path TEMPERATURE_INFO
path PSU_INFO
path FAN_INFO
exit
grpc subscription ddm
dst-group venus
path-target STATE_DB
path TRANSCEIVER_DOM_SENSOR
end
write force
" > $hostname.txt
done <<< "$hosts"
