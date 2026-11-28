#!/bin/sh
# ==============================================================================
# Zapret2-Manager: Combo Strategy Builder
# Port of PresetService.BuildComboArgs from Asterlike/zapret2UI
# ==============================================================================

[ -z "${Z2M_DIR:-}" ] && Z2M_DIR="$(cd "$(dirname "$0")/.." >/dev/null 2>&1 && pwd)"
[ -f "${Z2M_DIR}/core/config.sh" ] && . "${Z2M_DIR}/core/config.sh"

combo_blob_args() {
    local entry alias file src
    for entry in tls_google:tls_clienthello_www_google_com.bin tls_vk:tls_clienthello_vk_com.bin tls_sber:tls_clienthello_sberbank_ru.bin tls_gos:tls_clienthello_gosuslugi_ru.bin quic_generic:quic_initial_generic.bin; do
        alias="${entry%%:*}"; file="${entry#*:}"
        src="${ZAPRET2_FAKE_DIR}/${file}"
        [ -f "${src}" ] || src="${Z2M_DIR}/fake/${file}"
        [ -f "${src}" ] || return 1
        printf ' --blob=%s:@%s' "${alias}" "${src}"
    done
}

doh_fix_state_file() {
    echo "${ZAPRET2_DIR}/.z2m-doh-fix"
}

doh_fix_get_mode() {
    local f mode=""
    f=$(doh_fix_state_file)
    [ -f "${f}" ] && mode=$(tr -d '\r\n ' < "${f}" 2>/dev/null)
    case "${mode}" in
        auto|all) echo "${mode}" ;;
        *) echo "off" ;;
    esac
}

doh_fix_is_enabled() {
    [ "$(doh_fix_get_mode)" != "off" ]
}

# Extract active DoH hostnames configured in OpenWrt https-dns-proxy UCI.
combo_get_uci_doh_domains() {
    command -v uci >/dev/null 2>&1 || return 0
    uci show https-dns-proxy 2>/dev/null | LC_ALL=C awk '
        /\.(resolver_url|url_prefix)=/ {
            val = $0
            sub(/^[^=]*=/, "", val)
            gsub(/^[\x27"]|[\x27"]$/, "", val)
            sub(/^https?:\/\//, "", val)
            sub(/\/.*$/, "", val)
            sub(/:.*$/, "", val)
            if (val ~ /^[A-Za-z0-9.-]+$/ && index(val, ".") > 0 && !seen[val]++) {
                out = (out == "" ? val : out "," val)
            }
        }
        END { if (out != "") print out }
    '
}

# Resolve comma-separated DoH domains for the selected mode ("auto" or "all").
doh_fix_resolve_domains() {
    local mode="${1:-$(doh_fix_get_mode)}"
    local active
    active=$(combo_get_uci_doh_domains)
    case "${mode}" in
        all)
            if [ -n "${active}" ]; then
                printf '%s,%s\n' "${active}" "${DEFAULT_DOH_FIX_DOMAINS}" | LC_ALL=C awk -F, '
                    {
                        for (i = 1; i <= NF; i++) {
                            if ($i != "" && !seen[$i]++) {
                                out = (out == "" ? $i : out "," $i)
                            }
                        }
                    }
                    END { print out }
                '
            else
                echo "${DEFAULT_DOH_FIX_DOMAINS}"
            fi
            ;;
        auto)
            if [ -n "${active}" ]; then
                echo "${active}"
            else
                echo "${DEFAULT_DOH_FIX_DOMAINS}"
            fi
            ;;
        *)
            echo ""
            ;;
    esac
}

# Build the zapret2 TLS desync profile for DoH endpoints (port 443, SNI hostfakesplit).
doh_fix_build_profile() {
    local mode="${1:-$(doh_fix_get_mode)}"
    [ "${mode}" != "off" ] || return 0
    local domains fake_host="common.dot.dns.yandex.net"
    domains=$(doh_fix_resolve_domains "${mode}")
    [ -n "${domains}" ] || return 0
    case ",${domains}," in
        *,common.dot.dns.yandex.net,*) fake_host="gosuslugi.ru" ;;
    esac
    printf '%s' "--filter-tcp=443 --filter-l7=tls --hostlist-domains=${domains} --out-range=-d10 --payload=tls_client_hello --lua-desync=hostfakesplit:host=${fake_host}:midhost=midsld:badsum:tcp_ack=-66000"
}

# Idempotently insert, update, or remove the DoH fix profile in an existing NFQWS2_OPT string.
combo_patch_doh_opt() {
    local cur_opt="$1"
    local doh_profile="$2"
    Z2M_CUR_OPT="${cur_opt}" Z2M_DOH_PROFILE="${doh_profile}" LC_ALL=C awk '
        BEGIN {
            opt = ENVIRON["Z2M_CUR_OPT"]
            doh = ENVIRON["Z2M_DOH_PROFILE"]
            gsub(/^[ \t]+|[ \t]+$/, "", opt)
            if (opt == "") {
                if (doh != "") print "--ctrack-disable=0 --ipcache-lifetime=8400 --ipcache-hostname=1 " doh
                exit
            }

            # Separate global options before the first --filter-* from filter profiles.
            if (match(opt, /(^| )--filter-/)) {
                pos = RSTART
                if (substr(opt, pos, 1) == " ") {
                    prefix = substr(opt, 1, pos - 1)
                    rest = substr(opt, pos + 1)
                } else {
                    prefix = ""
                    rest = opt
                }
            } else {
                print opt (doh != "" ? " " doh : "")
                exit
            }

            # Split remaining profiles on " --new " and drop any existing DoH fix profile.
            n = 0
            while (length(rest) > 0) {
                idx = index(rest, " --new ")
                if (idx > 0) {
                    seg = substr(rest, 1, idx - 1)
                    rest = substr(rest, idx + 7)
                } else {
                    seg = rest
                    rest = ""
                }
                gsub(/^[ \t]+|[ \t]+$/, "", seg)
                if (seg == "") continue
                if (seg ~ /^--filter-tcp=443 --filter-l7=tls --hostlist-domains=/) continue
                segs[++n] = seg
            }

            if (doh != "") {
                ins = n + 1
                for (i = 1; i <= n; i++) {
                    if (segs[i] ~ /^--filter-tcp=443-65535/ || segs[i] ~ /--filter-l7=tls/) {
                        ins = i
                        break
                    }
                }
                for (i = n; i >= ins; i--) segs[i + 1] = segs[i]
                segs[ins] = doh
                n++
            }

            out = prefix
            for (i = 1; i <= n; i++) {
                if (i == 1) {
                    out = (out == "" ? segs[i] : out " " segs[i])
                } else {
                    out = out " --new " segs[i]
                }
            }
            print out
        }
    '
}

# Build full NFQWS2_OPT argument string from components:
# $1: discord_tls_desync
# $2: youtube_tls_desync
# $3: fallback_tls_desync (optional, defaults to discord_tls)
# $4: voice_desync (optional, defaults to Asterlike standard QUIC fake)
combo_build_args() {
    local discord_tls="$1"
    local youtube_tls="$2"
    local fallback_tls="${3:-$1}"
    local voice_desync="${4:---payload=discord_ip_discovery,stun --lua-desync=fake:blob=0x00000000000000000000000000000000:repeats=2}"

    local hostlist_discord="${ZAPRET2_IPSET_DIR}/zapret-hosts-discord.txt"
    local hostlist_youtube="${ZAPRET2_IPSET_DIR}/zapret-hosts-youtube.txt"
    local hostlist_exclude="${ZAPRET2_IPSET_DIR}/zapret-hosts-user-exclude.txt"

    # Filter arguments
    local filter_dc=""
    local filter_yt=""
    local filter_ex=""

    if [ -f "${hostlist_discord}" ]; then
        filter_dc="--hostlist=${hostlist_discord}"
    fi
    if [ -f "${hostlist_youtube}" ]; then
        filter_yt="--hostlist=${hostlist_youtube}"
    fi
    if [ -f "${hostlist_exclude}" ]; then
        filter_ex="--hostlist-exclude=${hostlist_exclude}"
    fi

    local blobs
    blobs=$(combo_blob_args) || return 1

    # Base options (no double quotes to prevent syntax corruption in /opt/zapret2/config)
    local opt="--ctrack-disable=0 --ipcache-lifetime=8400 --ipcache-hostname=1${blobs}"

    # HTTP must be profiled as well as intercepted; TLS-only rules ignore port 80.
    opt="${opt} --filter-tcp=80 --filter-l7=http ${filter_ex} --payload=http_req --lua-desync=fake:tcp_md5 --lua-desync=multisplit:pos=method+2"

    # Optional DoH TLS profile (runs before general/exclude TLS profiles)
    local doh_profile
    doh_profile=$(doh_fix_build_profile)
    [ -z "${doh_profile}" ] || opt="${opt} --new ${doh_profile}"

    # Profile 1: Discord TLS
    opt="${opt} --new --filter-tcp=443-65535 --filter-l7=tls ${filter_dc} --out-range=-d10 --payload=tls_client_hello ${discord_tls}"

    # Profile 2: YouTube TLS
    opt="${opt} --new --filter-tcp=443-65535 --filter-l7=tls ${filter_yt} --out-range=-d10 --payload=tls_client_hello ${youtube_tls}"

    # Profile 3: Catch-all Fallback TLS (excluding sensitive RU domains)
    opt="${opt} --new --filter-tcp=443-65535 --filter-l7=tls ${filter_ex} --out-range=-d10 --payload=tls_client_hello ${fallback_tls}"

    # Profile 4: QUIC YouTube
    opt="${opt} --new --filter-udp=443-65535 --filter-l7=quic ${filter_yt} --payload=quic_initial --lua-desync=fake:blob=quic_generic:repeats=11"

    # Profile 5: QUIC Discord (media/cdn HTTP/3)
    opt="${opt} --new --filter-udp=443-65535 --filter-l7=quic ${filter_dc} --payload=quic_initial --lua-desync=fake:blob=quic_generic:repeats=11"

    # Profile 6: QUIC Catch-all (excluding sensitive domains)
    opt="${opt} --new --filter-udp=443-65535 --filter-l7=quic ${filter_ex} --payload=quic_initial --lua-desync=fake:blob=quic_generic:repeats=6"

    # Profile 7: Discord Voice (STUN + RTP high UDP ports 50000-65535)
    opt="${opt} --new --filter-udp=19294-19344,50000-65535 --filter-l7=discord,stun ${voice_desync}"

    echo "${opt}"
}

# Build standalone test argument for probing a single candidate bundle on all traffic
# Used during Pass 1 of generation
combo_build_single_test_args() {
    local candidate_tls="$1"

    local blobs
    blobs=$(combo_blob_args) || return 1

    local opt="--ctrack-disable=0 --ipcache-lifetime=8400 --ipcache-hostname=1${blobs}"
    opt="${opt} --filter-tcp=80 --filter-l7=http --payload=http_req --lua-desync=fake:tcp_md5 --lua-desync=multisplit:pos=method+2"
    opt="${opt} --new --filter-tcp=443-65535 --filter-l7=tls --out-range=-d10 --payload=tls_client_hello ${candidate_tls}"
    opt="${opt} --new --filter-udp=443-65535 --filter-l7=quic --payload=quic_initial --lua-desync=fake:blob=quic_generic:repeats=6"

    echo "${opt}"
}
