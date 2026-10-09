#!/usr/bin/env bash
# ClickHouse server, bound to loopback only, sized for a 6 vCPU / 12 GB box.
set -Eeuo pipefail
source "${TOOLKIT_ROOT:?TOOLKIT_ROOT not set}/lib/common.sh"
set -a; source "$TOOLKIT_ROOT/env"; set +a

CH_DB="${CH_DB:-market}"
CH_MEM_RATIO="${CH_MEM_RATIO:-0.5}"
# Absolute cap in bytes; wins over the ratio. For a shared host with lots of RAM.
CH_MAX_MEMORY="${CH_MAX_MEMORY:-}"
CREDS=/root/.clickhouse-credentials

section "ClickHouse repository"
ARCH="$(dpkg --print-architecture)"
add_apt_repo clickhouse \
  "https://packages.clickhouse.com/rpm/lts/repodata/repomd.xml.key" \
  "deb [signed-by=/usr/share/keyrings/clickhouse.gpg arch=${ARCH}] https://packages.clickhouse.com/deb stable main"

section "Packages"
# noninteractive keeps the postinst from prompting for a default password;
# we set it ourselves below, in a file we control.
apt_install clickhouse-common-static clickhouse-server clickhouse-client

section "Credentials"
# Generate once and remember. Re-running provisioning must not rotate the
# password out from under whatever is already writing to the database.
if [[ -n "${CH_PASSWORD:-}" ]]; then
  password="$CH_PASSWORD"
  log "using CH_PASSWORD from .env"
elif [[ -f "$CREDS" ]]; then
  # shellcheck disable=SC1090
  password="$(grep -E '^CH_PASSWORD=' "$CREDS" | cut -d= -f2-)"
  skip "reusing the password stored in $CREDS"
else
  password="$(gen_password)"
  ok "generated a new password for user 'default'"
fi
[[ -n "$password" ]] || die "empty ClickHouse password"
pw_hash="$(printf '%s' "$password" | sha256sum | cut -d' ' -f1)"

write_file "$CREDS" 0600 <<EOF
# Managed by vps-provision. ClickHouse listens on 127.0.0.1 only.
CH_HOST=127.0.0.1
CH_HTTP_PORT=8123
CH_NATIVE_PORT=9000
CH_USER=default
CH_PASSWORD=$password
CH_DB=$CH_DB
EOF

section "Server configuration"
if [[ -n "$CH_MAX_MEMORY" ]]; then
  mem_xml="<max_server_memory_usage>${CH_MAX_MEMORY}</max_server_memory_usage>"
  mark_cache=268435456
else
  mem_xml="<max_server_memory_usage_to_ram_ratio>${CH_MEM_RATIO}</max_server_memory_usage_to_ram_ratio>"
  mark_cache=1073741824
fi
write_file /etc/clickhouse-server/config.d/10-vps.xml 0644 <<EOF
<?xml version="1.0"?>
<!-- Managed by vps-provision. -->
<clickhouse>
    <!-- Loopback only. Reach it from the laptop with:
         ssh -L 8123:127.0.0.1:8123 -L 9000:127.0.0.1:9000 <host>
         replace="replace" wipes any listen_host inherited from config.xml
         instead of adding a second address next to it. -->
    <listen_host replace="replace">127.0.0.1</listen_host>

    <!-- Server-side default for now(), toDate() and string literals; the host
         clock may be in a local zone, exchange data is UTC. -->
    <timezone>UTC</timezone>

    <!-- Memory. On 12 GB, ${CH_MEM_RATIO} leaves headroom for the ingest
         processes, Netdata and the page cache, which ClickHouse leans on
         heavily for reads. -->
    ${mem_xml}
    <mark_cache_size>${mark_cache}</mark_cache_size>
    <uncompressed_cache_size>0</uncompressed_cache_size>

    <!-- A single-writer ingest box does not need the default 100/4096. -->
    <max_concurrent_queries>30</max_concurrent_queries>
    <max_connections>256</max_connections>

    <logger>
        <level>information</level>
        <size>100M</size>
        <count>5</count>
    </logger>

    <!-- System tables are the classic way a small disk fills up silently.
         Two weeks of query history is plenty for debugging ingest. -->
    <query_log><ttl>event_date + INTERVAL 14 DAY DELETE</ttl></query_log>
    <query_thread_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></query_thread_log>
    <part_log><ttl>event_date + INTERVAL 14 DAY DELETE</ttl></part_log>
    <trace_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></trace_log>
    <metric_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></metric_log>
    <asynchronous_metric_log><ttl>event_date + INTERVAL 7 DAY DELETE</ttl></asynchronous_metric_log>
</clickhouse>
EOF
config_changed=$FILE_CHANGED

write_file /etc/clickhouse-server/users.d/10-default-user.xml 0600 <<EOF
<?xml version="1.0"?>
<!-- Managed by vps-provision. -->
<clickhouse>
    <users>
        <default>
            <!-- The shipped users.xml declares an empty <password>. ClickHouse
                 refuses to start with both password and password_sha256_hex,
                 so remove the inherited one explicitly. -->
            <password remove="remove"/>
            <password_sha256_hex>${pw_hash}</password_sha256_hex>
            <networks replace="replace">
                <ip>127.0.0.1</ip>
                <ip>::1</ip>
            </networks>
            <profile>default</profile>
            <quota>default</quota>
            <access_management>1</access_management>
        </default>
    </users>
</clickhouse>
EOF
chown clickhouse:clickhouse /etc/clickhouse-server/users.d/10-default-user.xml
(( FILE_CHANGED )) && config_changed=1

section "Service"
svc_enable_start clickhouse-server
if (( config_changed )); then
  svc_restart clickhouse-server
fi
wait_port 8123 60 || die "ClickHouse is not answering on 8123 (journalctl -u clickhouse-server -n 80)"
ok "HTTP interface up on 127.0.0.1:8123"

section "Database"
# Must happen BEFORE the client config below is written: that config pins
# <database>${CH_DB}</database>, and clickhouse-client refuses to connect to a
# database that does not exist yet. --database default keeps this query
# independent of whatever a previous run left in ~/.clickhouse-client.
clickhouse-client --user default --password "$password" --database default \
  --query "CREATE DATABASE IF NOT EXISTS \`${CH_DB}\`" \
  || die "CREATE DATABASE failed - see the ClickHouse error above"
ok "database ready: $CH_DB"

section "Client configuration"
# Lets `clickhouse-client` and `chc` just work, without the password on the
# command line where it would land in shell history and in `ps`.
install_client_config() {
  local user="$1" home
  home="$(getent passwd "$user" | cut -d: -f6)" || return 0
  [[ -d "$home" ]] || return 0
  install -d -m 0700 -o "$user" -g "$(id -gn "$user")" "$home/.clickhouse-client"
  write_file "$home/.clickhouse-client/config.xml" 0600 <<EOF2
<config>
    <user>default</user>
    <password>${password}</password>
    <database>${CH_DB}</database>
</config>
EOF2
  chown "$user:$(id -gn "$user")" "$home/.clickhouse-client/config.xml"
}
install_client_config root
[[ -n "${VPS_USER:-}" ]] && id -u "$VPS_USER" >/dev/null 2>&1 && install_client_config "$VPS_USER"

version="$(clickhouse-client --user default --password "$password" --query 'SELECT version()')"
ok "ClickHouse $version | credentials in $CREDS"
