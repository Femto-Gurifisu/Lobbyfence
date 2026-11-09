#!/bin/sh
# Unit checks for lobbyfence.awk. Run with BusyBox awk first in PATH.
AWKF="$(cd "$(dirname "$0")/.." && pwd)/files/usr/share/lobbyfence/lobbyfence.awk"
FAIL=0
t() { # name expected actual
	if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (expected '$2', got '$3')"; FAIL=1; fi
}
ra() { op="$1"; shift; awk -v op="$op" -f "$AWKF" "$@"; }

t "public filter" "8.8.8.8 1.1.1.1 2606:4700::1111" \
	"$(printf '8.8.8.8 10.1.2.3 192.168.0.1 100.64.1.1 1.1.1.1 172.20.0.1 224.0.0.1 2606:4700::1111 fe80::1 fd00::1 ::1 2001:db8::5 ff02::1 999.1.1.1 1.2.3 8.8.8.8\n' | ra public | tr '\n' ' ' | sed 's/ $//')"

t "addrs families" "4 192.168.1.5 4 10.0.0.0/8 6 fd00::/64 bad 1.2.3.4/33 bad hello" \
	"$(printf '192.168.1.5 10.0.0.0/8 fd00::/64 1.2.3.4/33 hello\n' | ra addrs | tr '\n' ' ' | sed 's/ $//')"
t "IPv6: eight groups at most, :: once, groups of 1-4 hex digits" "6 2001:db8::1|6 ::|6 ::ffff:1.2.3.4|6 1:2:3:4:5:6:7:8|bad 1:2:3:4:5:6:7:8:9|bad 12345::1|bad 2001:db8:::1|bad :::|bad 1::2::3|bad :1:2|bad 1:2:3:4:5:6:7|" \
	"$(echo '2001:db8::1 :: ::ffff:1.2.3.4 1:2:3:4:5:6:7:8 1:2:3:4:5:6:7:8:9 12345::1 2001:db8:::1 ::: 1::2::3 :1:2 1:2:3:4:5:6:7' | ra addrs | tr '\n' '|')"
t "a /0 (everything) is not an address to allow or block" "bad 0.0.0.0/0|bad ::/0|4 10.0.0.0/8|" "$(echo '0.0.0.0/0 ::/0 10.0.0.0/8' | ra addrs | tr '\n' '|')"
t "typed IPv4 with leading zeros is tidied (C libraries read it differently)" "4 192.168.1.5|4 10.0.0.0/8|" "$(echo '192.168.001.05 010.0.0.0/08' | ra addrs | tr '\n' '|')"
t "server addresses with leading zeros are not taken (imports, lists)" "45.10.0.1|" "$(echo '45.10.0.1 045.10.0.1' | ra public | tr '\n' '|')"

t "addrs recognises MAC addresses" "mac aa:bb:cc:dd:ee:ff 4 10.0.0.1 mac 01:02:03:0a:0b:0c" \
	"$(printf 'AA:BB:CC:DD:EE:FF 10.0.0.1 01-02-03-0A-0B-0C\n' | ra addrs | tr '\n' ' ' | sed 's/ $//')"

t "neigh picks the zone's MACs, skips link-local" "192.168.1.23 fd00::23 2a02:1:2::23" \
	"$(printf 'aa:bb:cc:dd:ee:01 192.168.1.23\nAA:BB:CC:DD:EE:01 fd00::23\naa:bb:cc:dd:ee:01 fe80::1\naa:bb:cc:dd:ee:02 192.168.1.40\naa:bb:cc:dd:ee:01 2a02:1:2::23\naa:bb:cc:dd:ee:01 192.168.1.23\n' | ra neigh -v macs='aa:bb:cc:dd:ee:01, aa:bb:cc:dd:ee:09' | tr '\n' ' ' | sed 's/ $//')"

t "harvest from nft output" "45.1.2.3 80.9.9.9 2a00:1450:4001::5" "$(ra harvest <<'EOF' | tr '\n' ' ' | sed 's/ $//'
table inet lobbyfence {
	set game_seen4 {
		type ipv4_addr
		size 65535
		flags dynamic,timeout
		timeout 15m
		elements = { 45.1.2.3 timeout 15m expires 14m58s, 10.0.0.1 timeout 15m expires 1m,
			     80.9.9.9 timeout 15m expires 3m2s }
	}
}
table inet lobbyfence {
	set game_seen6 {
		elements = { 2a00:1450:4001::5 timeout 15m expires 9m }
	}
}
EOF
)"

cat > /tmp/lf_cache.$$ <<'EOF'
45.10.0.1 50.1109 8.6821 DE 100
80.20.0.1 40.7128 -74.0060 US 100
51.50.0.1 48.8566 2.3522 FR 100
99.30.0.1 - - -- 100
EOF
printf '45.10.0.1 5\n80.20.0.1 6\n51.50.0.1 7\n99.30.0.1 8\n1.2.3.4 9\n' > /tmp/lf_ips.$$
t "classify circle 800km around Frankfurt" "in out in unloc pending" \
	"$(ra classify -v circles='50.1109,8.6821,800' /tmp/lf_cache.$$ /tmp/lf_ips.$$ | awk '{printf "%s ", $2}' | sed 's/ $//')"
t "classify circle 400km (Paris is ~480km away)" "in out out unloc pending" \
	"$(ra classify -v circles='50.1109,8.6821,400' /tmp/lf_cache.$$ /tmp/lf_ips.$$ | awk '{printf "%s ", $2}' | sed 's/ $//')"
t "classify with country list" "out in out unloc pending" \
	"$(ra classify -v countries='us' /tmp/lf_cache.$$ /tmp/lf_ips.$$ | awk '{printf "%s ", $2}' | sed 's/ $//')"
t "classify without region = nothing is inside (blocked)" "out out out unloc pending" \
	"$(ra classify /tmp/lf_cache.$$ /tmp/lf_ips.$$ | awk '{printf "%s ", $2}' | sed 's/ $//')"
t "classify ignores malformed circles (so no region)" "out out out unloc pending" \
	"$(ra classify -v circles='abc 95,10,100 50,8 50,8,-1' /tmp/lf_cache.$$ /tmp/lf_ips.$$ | awk '{printf "%s ", $2}' | sed 's/ $//')"
t "classify across the antimeridian" "in" \
	"$(printf '5.5.5.5 64.8 179.9 RU 1\n' > /tmp/lf_c2.$$; printf '5.5.5.5 1\n' | ra classify -v circles='64.8,-179.9,50' /tmp/lf_c2.$$ - | awk '{print $2}')"

t "pending skips cached, retries stale failures" "1.2.3.4 99.30.0.1" \
	"$(ra pending -v now=700000 -v retry=604800 /tmp/lf_cache.$$ /tmp/lf_ips.$$ | sort | tr '\n' ' ' | sed 's/ $//')"
t "pending keeps fresh failures cached" "1.2.3.4" \
	"$(ra pending -v now=1000 -v retry=604800 /tmp/lf_cache.$$ /tmp/lf_ips.$$ | tr '\n' ' ' | sed 's/ $//')"

printf '1.1.1.1 100\n2.2.2.2 50\n' > /tmp/lf_old.$$
printf '2.2.2.2\n3.3.3.3\n' > /tmp/lf_new.$$
t "merge adds, touches and expires" "2.2.2.2 1000|3.3.3.3 1000|1 1 1 0" \
	"$(ra merge -v now=1000 -v expire=850 -v statf=/tmp/lf_st.$$ /tmp/lf_old.$$ /tmp/lf_new.$$ | tr '\n' '|')$(cat /tmp/lf_st.$$)"
: > /tmp/lf_empty.$$
t "merge into empty list" "2.2.2.2 5|3.3.3.3 5|2 0 0 0" \
	"$(ra merge -v now=5 -v statf=/tmp/lf_st.$$ /tmp/lf_empty.$$ /tmp/lf_new.$$ | tr '\n' '|')$(cat /tmp/lf_st.$$)"
# a zone keeps its zmax most recently seen servers (ties: in the order learned)
printf '1.0.0.1 100\n1.0.0.2 300\n1.0.0.3 200\n1.0.0.4 300\n1.0.0.5 50\n' > /tmp/lf_cap.$$
t "merge keeps the zmax servers seen last" "1.0.0.2 300|1.0.0.3 200|1.0.0.4 300|0 0 0 2" \
	"$(ra merge -v now=400 -v zmax=3 -v statf=/tmp/lf_st.$$ /tmp/lf_cap.$$ /tmp/lf_empty.$$ | tr '\n' '|')$(cat /tmp/lf_st.$$)"
t "merge: new servers count as seen now, the oldest go" "1.0.0.2 300|1.0.0.4 300|9.9.9.9 400|1 0 0 3" \
	"$(echo 9.9.9.9 | ra merge -v now=400 -v zmax=3 -v statf=/tmp/lf_st.$$ /tmp/lf_cap.$$ - | tr '\n' '|')$(cat /tmp/lf_st.$$)"
t "merge: all seen at once - the first zmax learned stay" "1.0.0.1 7|1.0.0.2 7|0 0 0 3" \
	"$(printf '1.0.0.1 7\n1.0.0.2 7\n1.0.0.3 7\n1.0.0.4 7\n1.0.0.5 7\n' | ra merge -v now=7 -v zmax=2 -v statf=/tmp/lf_st.$$ - /tmp/lf_empty.$$ | tr '\n' '|')$(cat /tmp/lf_st.$$)"
t "merge: at the limit nothing goes" "1.0.0.1 100|1.0.0.2 300|1.0.0.3 200|1.0.0.4 300|1.0.0.5 50|0 0 0 0" \
	"$(ra merge -v now=400 -v zmax=5 -v statf=/tmp/lf_st.$$ /tmp/lf_cap.$$ /tmp/lf_empty.$$ | tr '\n' '|')$(cat /tmp/lf_st.$$)"
seq 1 30000 | awk '{ printf "10.%d.%d.%d %d\n", int($1 / 65536), int($1 / 256) % 256, $1 % 256, 1700000000 + $1 }' > /tmp/lf_big.$$
t "merge: 30000 servers cut to 20000, the newest kept" "20000 1700010001 0 0 0 10000" \
	"$(ra merge -v now=1800000000 -v zmax=20000 -v statf=/tmp/lf_st.$$ /tmp/lf_big.$$ /tmp/lf_empty.$$ | awk 'NR == 1 || $2 < m { m = $2 } END { printf "%d %d ", NR, m }')$(cat /tmp/lf_st.$$)"
rm -f /tmp/lf_cap.$$ /tmp/lf_big.$$

t "geojson drops junk" '["8.8.8.8","2606:4700::1111"]' \
	"$(printf '8.8.8.8\n"bad\n10.0.0.1\n2606:4700::1111\n' | ra geojson)"

t "georesp parses ip-api batch output" "8.8.8.8 37.751 -97.822 US 42|1.1.1.1 - - -- 42|" \
	"$(printf '[{"status":"success","countryCode":"US","lat":37.751,"lon":-97.822,"query":"8.8.8.8"},{"status":"fail","message":"invalid query","query":"1.1.1.1"},{"status":"fail","message":"private range","query":"10.0.0.1"}]' | ra georesp -v now=42 | tr '\n' '|')"
t "georesp tolerates pretty-printed JSON" "8.8.4.4 1.5 -2 GB 1|" \
	"$(printf '[\n  {\n    "query" : "8.8.4.4",\n    "status" : "success",\n    "lat" : 1.5,\n    "lon" : -2,\n    "countryCode" : "GB"\n  }\n]\n' | ra georesp -v now=1 | tr '\n' '|')"
t "georesp ignores garbage" "" "$(echo '<html>rate limited</html>' | ra georesp -v now=1)"
t "georesp: a place off the globe counts as not located (the edges of the globe are fine)" "9.9.9.9 - - -- 5|8.8.8.8 -90 180 US 5|1.0.0.1 - - -- 5|" \
	"$(printf '[{"status":"success","countryCode":"US","lat":999.5,"lon":10,"query":"9.9.9.9"},{"status":"success","countryCode":"US","lat":-90,"lon":180,"query":"8.8.8.8"},{"status":"success","countryCode":"AU","lat":-33.9,"lon":-180.5,"query":"1.0.0.1"}]' | ra georesp -v now=5 | tr '\n' '|')"

t "elements output" "flush set inet lf z_in4|flush set inet lf z_in6|flush set inet lf z_out4|flush set inet lf z_out6|add element inet lf z_in4 { 1.1.1.1, 2.2.2.2 }|add element inet lf z_in6 { 2a00::1 }|add element inet lf z_out4 { 3.3.3.3 }|" \
	"$(printf '1.1.1.1 in\n2.2.2.2 in\n3.3.3.3 out\n4.4.4.4 pending\n2a00::1 in\n' | ra elements -v t=lf -v p=z | tr '\n' '|')"
t "elements chunks large sets" 3 \
	"$(i=0; while [ $i -lt 1000 ]; do echo "45.0.$((i / 250)).$((i % 250)) in"; i=$((i + 1)); done | ra elements -v t=lf -v p=z | grep -c 'add element')"

t "prune dedups and drops unreferenced" "45.10.0.1 9 9 DE 200|80.20.0.1 40.7128 -74.0060 US 100|" \
	"$(printf '45.10.0.1 9 9 DE 200\n' >> /tmp/lf_cache.$$; printf '45.10.0.1 1\n80.20.0.1 1\n' > /tmp/lf_r.$$; ra prune /tmp/lf_r.$$ /tmp/lf_cache.$$ | tr '\n' '|')"

# FreshTomato: the connection table (packets per server, IPv6 learning)
printf '192.168.1.100\n2a02:1:2::23\n' > /tmp/lf_dev.$$
cat > /tmp/lf_ct.$$ <<'EOF'
ipv4     2 udp      17 175 src=192.168.1.100 dst=45.10.0.1 sport=3074 dport=30000 packets=120 bytes=9000 src=45.10.0.1 dst=203.0.113.9 sport=30000 dport=3074 packets=118 bytes=9100 [ASSURED] mark=0 use=2
ipv4     2 udp      17 175 src=192.168.1.100 dst=45.10.0.1 sport=3075 dport=30001 packets=5 bytes=900 src=45.10.0.1 dst=203.0.113.9 sport=30001 dport=3075 packets=5 bytes=900 [ASSURED] mark=0 use=2
ipv4     2 udp      17 29 src=192.168.1.100 dst=8.8.8.8 sport=5353 dport=53 packets=1 bytes=60 src=8.8.8.8 dst=203.0.113.9 sport=53 dport=5353 packets=1 bytes=90 mark=0 use=2
ipv4     2 tcp      6 7440 ESTABLISHED src=192.168.1.100 dst=80.20.0.1 sport=50000 dport=443 packets=10 bytes=900 src=80.20.0.1 dst=203.0.113.9 sport=443 dport=50000 packets=12 bytes=9100 [ASSURED] mark=0 use=2
ipv4     2 udp      17 175 src=99.30.0.1 dst=203.0.113.9 sport=40000 dport=3074 src=192.168.1.100 dst=99.30.0.1 sport=3074 dport=40000 [ASSURED] mark=0 use=2
ipv6     10 udp      17 170 src=2a02:0001:0002:0000:0000:0000:0000:0023 dst=2600:0001:0000:0000:0000:0000:0000:0001 sport=3074 dport=3478 packets=40 bytes=4000 src=2600:0001:0000:0000:0000:0000:0000:0001 dst=2a02:0001:0002:0000:0000:0000:0000:0023 sport=3478 dport=3074 packets=41 bytes=4100 [ASSURED] mark=0 use=2
ipv4     2 udp      17 175 src=192.168.1.200 dst=61.0.0.1 sport=3074 dport=3074 packets=9 bytes=900 src=61.0.0.1 dst=203.0.113.9 sport=3074 dport=3074 packets=9 bytes=900 [ASSURED] mark=0 use=2
EOF
t "conntrack: packets the device sent per server (all traffic)" "45.10.0.1 125|8.8.8.8 1|80.20.0.1 10|99.30.0.1 -1|2600:1::1 40|" \
	"$(ra ct_packets -v devs=/tmp/lf_dev.$$ < /tmp/lf_ct.$$ | tr '\n' '|')"
t "conntrack: only the zone's game traffic (udp, device port 3074)" "45.10.0.1 120|99.30.0.1 -1|2600:1::1 40|" \
	"$(ra ct_packets -v devs=/tmp/lf_dev.$$ -v proto=udp -v lp=3074 < /tmp/lf_ct.$$ | tr '\n' '|')"
t "conntrack: server port range" "45.10.0.1 125|" \
	"$(ra ct_packets -v devs=/tmp/lf_dev.$$ -v proto=udp -v rp='30000-30010 40500' < /tmp/lf_ct.$$ | tr '\n' '|')"
t "conntrack: either-side port" "45.10.0.1 120|99.30.0.1 -1|2600:1::1 40|" \
	"$(ra ct_packets -v devs=/tmp/lf_dev.$$ -v proto=both -v pp=3074 < /tmp/lf_ct.$$ | tr '\n' '|')"
t "conntrack: IPv6 only, addresses written short" "2600:1::1 40|" \
	"$(ra ct_packets -v devs=/tmp/lf_dev.$$ -v family=6 < /tmp/lf_ct.$$ | tr '\n' '|')"
t "conntrack: ports the device uses, covered by the zone's ports or not" "udp/30000 1 120 1|udp/30001 1 5 1|udp/53 1 1 0|tcp/443 1 10 0|udp/40000 1 -1 0|udp/3478 1 40 0|" \
	"$(ra ct_ports -v devs=/tmp/lf_dev.$$ -v rp='30000-30010' < /tmp/lf_ct.$$ | tr '\n' '|')"
t "conntrack: ports, one protocol" "udp/30000 1 120 1|udp/30001 1 5 1|udp/53 1 1 1|udp/40000 1 -1 1|udp/3478 1 40 1|" \
	"$(ra ct_ports -v devs=/tmp/lf_dev.$$ -v proto=udp < /tmp/lf_ct.$$ | tr '\n' '|')"
# Ports seen: what each connection sent since the pass before (first pass: all of it)
rm -f /tmp/lf_cl.$$; : > /tmp/lf_cn.$$
t "conntrack: first pass - each connection's packets so far" "udp/30000 1 120 1 120|udp/40000 1 -1 1 -1|udp/3478 1 40 1 40|" \
	"$(ra ct_ports -v devs=/tmp/lf_dev.$$ -v proto=udp -v ctlast=/tmp/lf_cl.$$ -v ctnext=/tmp/lf_cn.$$ < /tmp/lf_ct.$$ | grep -v -e udp/30001 -e udp/53 | tr '\n' '|')"
t "...and their counts kept for the next pass" "4" "$(wc -l < /tmp/lf_cn.$$ | tr -d ' ')"
mv /tmp/lf_cn.$$ /tmp/lf_cl.$$; : > /tmp/lf_cn.$$
sed 's/packets=120 /packets=170 /; s/packets=40 /packets=40 /' /tmp/lf_ct.$$ > /tmp/lf_ct2.$$
t "conntrack: next pass - only what was sent since (a still connection adds nothing)" "udp/30000 1 170 1 50|udp/3478 1 40 1 0|" \
	"$(ra ct_ports -v devs=/tmp/lf_dev.$$ -v proto=udp -v ctlast=/tmp/lf_cl.$$ -v ctnext=/tmp/lf_cn.$$ < /tmp/lf_ct2.$$ | grep -e udp/30000 -e udp/3478 | tr '\n' '|')"
sed 's/packets=170 /packets=20 /' /tmp/lf_ct2.$$ > /tmp/lf_ct3.$$; mv /tmp/lf_cn.$$ /tmp/lf_cl.$$
t "conntrack: a connection that started over counts from 0" "udp/30000 1 20 1 20|" \
	"$(ra ct_ports -v devs=/tmp/lf_dev.$$ -v proto=udp -v ctlast=/tmp/lf_cl.$$ -v ctnext=/dev/null < /tmp/lf_ct3.$$ | grep udp/30000 | tr '\n' '|')"
rm -f /tmp/lf_cl.$$ /tmp/lf_cn.$$ /tmp/lf_ct2.$$ /tmp/lf_ct3.$$
t "ipset ages: unknown packet count is -1" "45.10.0.1 3 120|80.20.0.1 13 -1|" \
	"$(printf '45.10.0.1 120\n' > /tmp/lf_pk.$$; printf 'Name: lf_game_now4\nType: hash:ip\nMembers:\n45.10.0.1 timeout 12\n80.20.0.1 timeout 2\n' | ra ipset_ages -v window=15 -v pk=/tmp/lf_pk.$$ | tr '\n' '|')"

# learned data read back from flash: damaged lines left out (a location line
# without numbers used to mark its server "outside" for good)
printf '1.2.3.4 51.5 -0.1 GB 1700000000\n5.6.7.8\ngarbage line\n9.9.9.9 abc def XX 1\n\n8.8.4.4 - - -- 1700000001\n8.8.8.8 37.4 -122.1 us 5\n1.1.1.1 95 10 AU 7\n2606:4700::1111 -33.8 151.2 AU x\n' > /tmp/lf_gc.$$
t "clean cache: damaged location lines dropped" "1.2.3.4 51.5 -0.1 GB 1700000000|8.8.4.4 - - -- 1700000001|8.8.8.8 37.4 -122.1 -- 5|2606:4700::1111 -33.8 151.2 AU 99|" \
	"$(ra clean_cache -v now=99 -v statf=/tmp/lf_st.$$ /tmp/lf_gc.$$ | tr '\n' '|')"
t "clean cache: damaged lines counted" "4" "$(cat /tmp/lf_st.$$)"
printf '1.2.3.4 1700000000\n5.6.7.8\nzzz\n9.9.9.9 x y\n10.0.0.1 5\n1.2.3.4 7\n2606:4700::1111 8\n' > /tmp/lf_ip.$$
t "clean server list: bad / private / duplicate addresses dropped, garbled times -> now" "1.2.3.4 1700000000|5.6.7.8 99|9.9.9.9 99|2606:4700::1111 8|" \
	"$(ra clean_ips -v now=99 -v statf=/tmp/lf_st.$$ /tmp/lf_ip.$$ | tr '\n' '|')"
t "clean server list: damaged lines counted" "3" "$(cat /tmp/lf_st.$$)"
t "debug report: MAC addresses partly hidden, same device same number, IPv6 untouched" \
	"dev 70:9e:29:**:**:01 and 70:9e:29:**:**:01, 00:11:22:**:**:02|v6 2001:db8:aa:bb:cc:dd:ee:ff stays|" \
	"$(printf 'dev 70:9E:29:AB:CD:EF and 70:9e:29:ab:cd:ef, 00:11:22:33:44:55\nv6 2001:db8:aa:bb:cc:dd:ee:ff stays\n' | ra maskmac | tr '\n' '|')"
t "debug report: credentials in addresses hidden (a paid service's key)" \
	"o 'https://pro.ip-api.com/batch?key=(hidden)&fields=x'|u ?apikey=(hidden)&token=(hidden)|monkey=banana|Password=(hidden) x|" \
	"$(printf "o 'https://pro.ip-api.com/batch?key=SeCr3t&fields=x'\nu ?apikey=AAA&token=BBB\nmonkey=banana\nPassword=hunter2 x\n" | ra maskmac | tr '\n' '|')"
t "debug report: cut at the size limit" "... (the report was cut here: longer than 2000 bytes)" \
	"$(i=0; while [ $i -lt 300 ]; do echo "line $i of the log"; i=$((i + 1)); done | ra maskmac -v max=2000 | tail -n 1)"

# ---- shared server files (export / import-servers)
printf '8.8.8.8 37.75 -97.82 US 100\n1.1.1.1 - - -- 100\n9.9.9.9 47.1 8.5 CH 100\n' > /tmp/lf_gc.$$
printf 'fortnite Fortnite EU\nfortnite Second zone\napex Apex\n' > /tmp/lf_gn.$$
printf 'fortnite 8.8.8.8 500\nfortnite 1.1.1.1 500\napex 9.9.9.9 600\nfortnite 8.8.8.8 500\n' > /tmp/lf_gp.$$
printf '4.4.4.4 10 20 FR 50 cod\n8.8.8.8 37.75 -97.82 US 50 fortnite\n' > /tmp/lf_gs.$$
t "export: located servers by game (first zone's name), unlocated left out, imported ones kept with their game" \
	"lobbyfence-servers 1|game fortnite Fortnite EU|8.8.8.8 37.75 -97.82 US 500|game apex Apex|9.9.9.9 47.1 8.5 CH 600|game cod|4.4.4.4 10 20 FR 50 imported|" \
	"$(ra export /tmp/lf_gc.$$ /tmp/lf_gn.$$ /tmp/lf_gp.$$ /tmp/lf_gs.$$ | grep -v '^#' | tr '\n' '|')"
t "export: says what the file is (comments for whoever opens it)" "yes" \
	"$(ra export -v when=today /tmp/lf_gc.$$ /tmp/lf_gn.$$ /tmp/lf_gp.$$ /tmp/lf_gs.$$ | grep -q '^# exported today' && echo yes)"
t "shared_in: checked line by line - private, off-globe, broken and future-dated entries" \
	"8.8.8.8 37.75 -97.82 US 500 fortnite|9.9.9.9 47.1 8.5 CH 1000 other|1.0.0.1 -33.9 151.2 AU 1000 other|3 2 0" \
	"$(printf '# comment\r\nlobbyfence-servers 1\r\ngame fortnite Fortnite\n8.8.8.8 37.75 -97.82 US 500\n10.0.0.1 1 1 US 5\ngame Bad-Id!\n9.9.9.9 47.1 8.5 CH 99999999999\n4.4.4.4 95 1 FR 5\n1.0.0.1 -33.9 151.2 AU x\n' | ra shared_in -v now=1000 -v maxn=50 -v statf=/tmp/lf_st.$$ | tr '\n' '|')$(cat /tmp/lf_st.$$)"
t "shared_in: not a servers file -> nothing, and says so" "|-1 0 0" \
	"$(printf '<html>not it</html>\n8.8.8.8 1 1 US 1\n' | ra shared_in -v now=1000 -v maxn=50 -v statf=/tmp/lf_st.$$ | tr '\n' '|')|$(cat /tmp/lf_st.$$)"
t "shared_in: at most maxn servers" "2 0 1" \
	"$(printf 'lobbyfence-servers 1\n8.8.8.8 1 1 US 1\n8.8.4.4 1 1 US 1\n1.1.1.1 1 1 US 1\n' | ra shared_in -v now=1000 -v maxn=2 -v statf=/tmp/lf_st.$$ >/dev/null; cat /tmp/lf_st.$$)"
printf '8.8.8.8 1 1 US 10 fortnite\n' > /tmp/lf_m1.$$
printf '8.8.8.8 2 2 US 20 fortnite\n8.8.8.8 3 3 US 5 apex\n' > /tmp/lf_m2.$$
t "shared_merge: one line per game and address, the newest wins, counts the new ones" \
	"8.8.8.8 2 2 US 20 fortnite|8.8.8.8 3 3 US 5 apex|1" \
	"$(ra shared_merge -v statf=/tmp/lf_st.$$ /tmp/lf_m1.$$ /tmp/lf_m2.$$ | tr '\n' '|')$(cat /tmp/lf_st.$$)"
printf '45.10.0.1 51 0 GB 100 apex own\n' > /tmp/lf_o1.$$; printf '45.10.0.1 51 0 GB 200 apex\n80.1.1.1 1 1 US 50 apex own\n' > /tmp/lf_o2.$$
t "shared_merge: found by this router stays marked, even when an import is newer" "45.10.0.1 51 0 GB 200 apex own|80.1.1.1 1 1 US 50 apex own|1" \
	"$(ra shared_merge -v statf=/tmp/lf_st.$$ /tmp/lf_o1.$$ /tmp/lf_o2.$$ | tr '\n' '|')$(cat /tmp/lf_st.$$)"
t "export: kept servers found by this router are not marked imported" "lobbyfence-servers 1|game apex|45.10.0.1 51 0 GB 100|" \
	"$(: > /tmp/lf_e0.$$; ra export /tmp/lf_e0.$$ /tmp/lf_e0.$$ /tmp/lf_e0.$$ /tmp/lf_o1.$$ | grep -v '^#' | tr '\n' '|')"
rm -f /tmp/lf_o1.$$ /tmp/lf_o2.$$ /tmp/lf_e0.$$
printf 'udp/10200 1 500 100 100 1\nudp/27019 2 8 100 100 1\nbad line\n' > /tmp/lf_pt.$$
printf 'udp/10200 1 900 1\nudp/10600 1 4000 0\nudp/443 3 99 0\ntcp/80 1 5 0\n' > /tmp/lf_pn.$$
t "ports_merge: peaks kept, new ports added, web / DNS ports never counted" "udp/10200 1 900 100 200 2 500|udp/27019 2 8 100 100 1 8|udp/10600 1 4000 200 200 1 0|" \
	"$(ra ports_merge -v now=200 /tmp/lf_pt.$$ /tmp/lf_pn.$$ | tr '\n' '|')"
t "ports_merge: unused for 30 days -> forgotten" "udp/10600 1 4000 2592100 2592100 1 0|" \
	"$(ra ports_merge -v now=2592100 /tmp/lf_pt.$$ /tmp/lf_pn.$$ | grep -v 10200 | tr '\n' '|')"
t "ports_show: covered by the zone's ports or not, then the total (a line from before totals: its peak)" "udp/10200 1 500 100 100 1 1 500|udp/27019 2 8 100 100 1 0 8|" \
	"$(ra ports_show -v rp='10000-10999' /tmp/lf_pt.$$ | tr '\n' '|')"
t "clean_ports: damaged lines left out and counted" "udp/10200 1 500 100 100 1 500|udp/27019 2 8 100 100 1 8|1" \
	"$(ra clean_ports -v statf=/tmp/lf_st.$$ /tmp/lf_pt.$$ | tr '\n' '|')$(cat /tmp/lf_st.$$)"
# totals: what each pass added (5th field from ct_ports) is added up; the peak stays the most in one pass
printf 'udp/10200 1 900 100 200 2 1500\n' > /tmp/lf_pt.$$
printf 'udp/10200 1 700 1 650\nudp/10600 2 30 0 30\nudp/27019 1 -1 0 -1\n' > /tmp/lf_pn.$$
t "ports_merge: the total grows by what was sent since the pass before" "udp/10200 1 900 100 300 3 2150|udp/10600 2 30 300 300 1 30|udp/27019 1 0 300 300 1 0|" \
	"$(ra ports_merge -v now=300 /tmp/lf_pt.$$ /tmp/lf_pn.$$ | tr '\n' '|')"
rm -f /tmp/lf_pt.$$ /tmp/lf_pn.$$
t "shared_hit: the waiting addresses found among the imported locations, as cache lines" "8.8.8.8 2 2 US 20|" \
	"$(printf '8.8.8.8\n7.7.7.7\n' > /tmp/lf_w.$$; printf '8.8.8.8 2 2 US 20 fortnite\n8.8.8.8 3 3 US 5 apex\n1.1.1.1 1 1 AU 1 cod\n' | ra shared_hit /tmp/lf_w.$$ - | tr '\n' '|')"

# ---- the game servers LobbyFence comes with (servers.txt): read like an import
SRV="$(dirname "$AWKF")/servers.txt"
n_srv="$(grep -c '^[0-9]' "$SRV")"
ra shared_in -v now=9999999999 -v maxn=20000 -v statf=/tmp/lf_st.$$ "$SRV" > /tmp/lf_bi.$$
t "servers.txt: a servers file, every server line taken (none damaged or over the limit)" "$n_srv 0 0" "$(cat /tmp/lf_st.$$)"
t "servers.txt: filed under the Apex Legends, Call of Duty and Fortnite presets" "apex cod fortnite" \
	"$(awk '{ print $6 }' /tmp/lf_bi.$$ | sort -u | tr '\n' ' ' | sed 's/ $//')"
t "servers.txt: each address once per game" "" "$(awk '{ print $6, $1 }' /tmp/lf_bi.$$ | sort | uniq -d)"
printf '13.113.128.68\n45.32.7.134\n7.7.7.7\n' > /tmp/lf_w.$$
printf '13.113.128.68 1 1 JP 5 apex own\n' > /tmp/lf_sc.$$
t "shared_hit: the router's own / imported locations first, then the ones LobbyFence comes with" \
	"13.113.128.68 1 1 JP 5|45.32.7.134 40.4993 -74.399 US 1794182174|" \
	"$(ra shared_hit /tmp/lf_w.$$ /tmp/lf_sc.$$ /tmp/lf_bi.$$ | tr '\n' '|')"

rm -f /tmp/lf_*.$$
[ "$FAIL" = 0 ] && echo "ALL UNIT TESTS PASSED"
exit $FAIL
