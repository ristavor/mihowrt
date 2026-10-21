set disable_quic 0
set dns_hijack 1
set lists_interval 24
has proxy-ips
proxy-ip 91.108.4.0/22
proxy-ip https://p.example/t.txt;443
has direct-ips
mode proxy-first
dns redir-host
