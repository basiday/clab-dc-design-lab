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