#!/bin/sh
# shellcheck disable=SC3043
# Catalog selection shares one transaction and one scoring policy in every mode.
[ -z "${Z2M_DIR:-}" ] && Z2M_DIR="$(cd "$(dirname "$0")/.." >/dev/null 2>&1 && pwd)"
. "${Z2M_DIR}/core/config.sh"
. "${Z2M_DIR}/core/tui.sh"
. "${Z2M_DIR}/core/probe.sh"
. "${Z2M_DIR}/core/zapret_service.sh"
. "${Z2M_DIR}/strategies/catalog.sh"

run_strategy_autoselect() {
    z2m_run_guarded catalog_autoselect "${ALL_PROBE_HOSTS}" "Автоподбор из каталога"
}

run_test_youtube_only() {
    z2m_run_guarded catalog_autoselect "${YOUTUBE_PROBE_HOSTS}" "Подбор для YouTube"
}

run_test_discord_only() {
    z2m_run_guarded catalog_autoselect "${DISCORD_PROBE_HOSTS}" "Подбор для Discord"
}

# Sum the two repeats, avoiding integer-average ties and false perfect results.
catalog_measure() {
    local first second
    first=$(probe_host_list "$1")
    sleep "${Z2M_PROBE_REPEAT_DELAY:-1}"
    second=$(probe_host_list "$1")
    printf '%s\n%s\n' "${first}" "${second}" | awk '
        { ok += $1; total += $2; score += $3; maximum += $4 }
        END { print ok, total, score, maximum }
    '
}

catalog_autoselect() {
    local hosts="$1" title="$2"
    tui_banner
    tui_header "${title}"
    if ! zapret_is_installed; then
        tui_error "Пакет zapret2 не установлен!"
        tui_pause
        return 1
    fi
    if ! probe_check_deps; then
        tui_error "Не найдены curl или wget — проверка доступа в интернет невозможна!"
        tui_pause
        return 1
    fi
    zapret_sync_fake_blobs || { tui_error "Не удалось синхронизировать файлы фейков!"; tui_pause; return 1; }
    zapret_sync_hostlists 0 || { tui_error "Не удалось синхронизировать списки хостов!"; tui_pause; return 1; }

    local baseline result base_ok base_total base_score base_fail
    tui_info "Проверка вашей текущей стратегии (2 повтора)..."
    baseline=$(catalog_measure "${hosts}")
    base_ok=$(echo "${baseline}" | awk '{print $1 + 0}')
    base_total=$(echo "${baseline}" | awk '{print $2 + 0}')
    base_score=$(echo "${baseline}" | awk '{print $3 + 0}')
    base_fail=$(echo "${baseline}" | awk '{print ($2 - $1) + 0}')
    tui_info "Текущая стратегия: доступно ${base_ok}/${base_total} (ошибок: ${base_fail})"
    tui_print_result_table_header

    local best_idx=0 best_score=-1 best_fail=999 best_ok=0 best_total=0 i=1
    local name opt ok total score maximum fail
    local res_file="${Z2M_TMP}/results.$$"
    : > "${res_file}" 2>/dev/null

    while [ "${i}" -le "${CATALOG_COUNT}" ]; do
        name=$(catalog_get_name "${i}")
        opt=$(catalog_get_opt "${i}")
        printf "\r\033[K%b[..] Тест: %s [%s/%s]%b" "${YELLOW}" "${name}" "${i}" "${CATALOG_COUNT}" "${NC}"
        if [ -z "${opt}" ] || ! zapret_set_opt "${opt}"; then
            printf "\r\033[K"
            tui_warn "${name}: не удалось применить; предыдущая конфигурация восстановлена."
            i=$((i + 1))
            continue
        fi
        result=$(catalog_measure "${hosts}")
        ok=$(echo "${result}" | awk '{print $1 + 0}')
        total=$(echo "${result}" | awk '{print $2 + 0}')
        score=$(echo "${result}" | awk '{print $3 + 0}')
        maximum=$(echo "${result}" | awk '{print $4 + 0}')
        fail=$((total - ok))
        printf "\r\033[K"
        tui_print_result_row "${name}" "${ok}" "${fail}" "${total}"
        printf "%s|%s|%s|%s|%s|%s\n" "${i}" "${name}" "${ok}" "${total}" "${score}" "${fail}" >> "${res_file}"
        if [ "${score}" -gt "${best_score}" ] || {
            [ "${score}" -eq "${best_score}" ] && [ "${fail}" -lt "${best_fail}" ];
        }; then
            best_idx="${i}"; best_score="${score}"; best_fail="${fail}"
            best_ok="${ok}"; best_total="${total}"
        fi
        if [ "${maximum}" -gt 0 ] && [ "${score}" -eq "${maximum}" ] && [ "${fail}" -eq 0 ]; then
            if [ "${Z2M_EARLY_EXIT:-0}" = "1" ] || [ "${Z2M_NONINTERACTIVE:-0}" = "1" ]; then
                tui_success "Найдена оптимальная стратегия (${name}) с результатом 100%!"
                break
            fi
        fi
        i=$((i + 1))
    done
    if [ "${best_score}" -le 0 ]; then
        rm -f "${res_file}" 2>/dev/null
        tui_error "Ни одна стратегия не прошла проверки. Возвращаем исходную конфигурацию."
        tui_pause
        return 1
    fi

    local best_name
    best_name=$(catalog_get_name "${best_idx}")
    echo ""
    tui_success "Лучший результат в каталоге: #${best_idx} «${best_name}» (${best_ok}/${best_total}, ошибок: ${best_fail})."

    # Equal results also retain the user's configuration by default.
    if [ "${best_score}" -lt "${base_score}" ] || {
        [ "${best_score}" -eq "${base_score}" ] && [ "${best_fail}" -ge "${base_fail}" ];
    }; then
        tui_warn "Ваша текущая стратегия уже даёт ${base_ok}/${base_total} (ошибок: ${base_fail}) — замена не даст улучшения."
        local answer
        answer=$(tui_prompt "Всё равно выбрать и применить стратегию из каталога? [y/N]" "N")
        case "${answer}" in
            y|Y|yes|YES) ;;
            *)
                rm -f "${res_file}" 2>/dev/null
                tui_info "Сохраняем текущую конфигурацию."
                tui_pause
                return 0
                ;;
        esac
    fi

    local chosen_idx="${best_idx}"
    if [ "${Z2M_NONINTERACTIVE:-0}" != "1" ] && [ -s "${res_file}" ]; then
        echo ""
        tui_header "Итоги тестирования и выбор стратегии"
        local r_idx r_name r_ok r_tot r_sc r_fl
        while IFS='|' read -r r_idx r_name r_ok r_tot r_sc r_fl; do
            if [ "${r_idx}" = "${best_idx}" ]; then
                printf "  %b%2s. %s [%s/%s доступно] <- Лучшая%b\n" \
                    "${GREEN}${BOLD}" "${r_idx}" "$(tui_pad "${r_name}" 42)" "${r_ok}" "${r_tot}" "${NC}"
            else
                printf "  %2s. %s [%s/%s доступно]\n" \
                    "${r_idx}" "$(tui_pad "${r_name}" 42)" "${r_ok}" "${r_tot}"
            fi
        done < "${res_file}"
        printf "   0. Отмена (оставить текущие настройки)\n\n"
        local user_pick
        user_pick=$(tui_prompt "Выберите номер стратегии для применения" "${best_idx}")
        case "${user_pick}" in
            0)
                rm -f "${res_file}" 2>/dev/null
                tui_info "Выбор отменен. Исходная конфигурация сохранена."
                tui_pause
                return 0
                ;;
            ''|*[!0-9]*)
                chosen_idx="${best_idx}"
                ;;
            *)
                if [ "${user_pick}" -ge 1 ] && [ "${user_pick}" -le "${CATALOG_COUNT}" ]; then
                    chosen_idx="${user_pick}"
                else
                    tui_warn "Неверный номер. Применяется рекомендованная стратегия (${best_idx})."
                    chosen_idx="${best_idx}"
                fi
                ;;
        esac
    fi
    rm -f "${res_file}" 2>/dev/null

    opt=$(catalog_get_opt "${chosen_idx}")
    zapret_set_opt "${opt}" || return 1
    z2m_transaction_commit
    tui_success "Применена стратегия: $(catalog_get_name "${chosen_idx}")"
    tui_info "Проверены TCP/TLS; голосовой UDP-трафик проверяйте в Discord."
    tui_pause
}

run_test_current_strategy() {
    tui_banner
    tui_header "Проверка текущей стратегии"
    zapret_is_running || tui_warn "Служба zapret2 остановлена."
    tui_info "Параметры: $(zapret_get_opt)"
    if ! probe_check_deps; then
        tui_error "Не найдены curl или wget — проверка доступа в интернет невозможна!"
        tui_pause
        return 1
    fi
    tui_info "Опрос контрольных доменов (HTTP и TLS 1.2)..."
    printf '%s %s %s %s\n' "$(tui_pad "Хост" 28)" "$(tui_pad "Категория" 20)" "$(tui_pad "HTTP Доступ" 12)" "TLS 1.2"
    printf '%b-------------------------------------------------------------------------%b\n' "${DGRAY}" "${NC}"
    local http_map tls_map h http_res tls_res http_str tls_str
    http_map=$(probe_hosts_map "${DIAGNOSTIC_HOSTS}")
    tls_map=$(probe_hosts_map "${DIAGNOSTIC_HOSTS}" "${Z2M_PROBE_TIMEOUT:-2}" tls12)
    for h in ${DIAGNOSTIC_HOSTS}; do
        http_res=$(echo "${http_map}" | awk -v h="${h}" '$1 == h { print $2 }')
        tls_res=$(echo "${tls_map}" | awk -v h="${h}" '$1 == h { print $2 }')
        if [ "${http_res}" = "1" ]; then
            http_str="${GREEN}$(tui_pad "OK" 12)${NC}"
        else
            http_str="${RED}$(tui_pad "Блок" 12)${NC}"
        fi
        if [ "${tls_res}" = "1" ]; then
            tls_str="${GREEN}OK${NC}"
        else
            tls_str="${RED}Сбой${NC}"
        fi
        printf '%s %s %b %b\n' "$(tui_pad "${h}" 28)" "$(tui_pad "$(probe_get_host_category "${h}")" 20)" "${http_str}" "${tls_str}"
    done
    tui_pause
}
