## Схема

[drawio схема](topology.drawio)

## План IP-адресации

| prefix | description |
|---|---|
| 10.255.0.0/24 | loopback spine |
| 10.255.1.0/24 | loopback leaf |
| 10.0.1.0/24 | p2p /31 spine-1 > leaf |
| 10.0.2.0/24 | p2p /31 spine-2 > leaf |
| 172.20.20.0/24 | OOB management |
| 10.10.10.0/24 | both cliets network |
| 10.10.20.0/24 | both cliets network |
| 172.16.1.0/31 | border leaf-1 swp6.101 (VRF-CL1) <> bgw eth1.101 (INET-CL1) |
| 172.16.2.0/31 | border leaf-1 swp6.102 (VRF-CL2) <> bgw eth1.102 (INET-CL2) |
| 1.1.1.1/32 | внешний префикс CL1 на bgw |
| 2.2.2.2/32 | внешний префикс CL2 на bgw |
