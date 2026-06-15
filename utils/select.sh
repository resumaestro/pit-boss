#!/bin/sh

_show_cursor() { printf "\033[?25h"; }
_hide_cursor() { printf "\033[?25l"; }
_reset_styles() { printf "\033[0m"; }
_clear_line() { printf "\033[2K"; }
_go_col1() { printf "\033[1G"; }

_to_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

_move_to_row() {
    printf "\033[%s;1H" "$(( _block_start_row + $1 + 1 ))"
}

# Build a diff-key (plain text, no escapes) for a row — used only for change detection
_row_key() {
    _rk_idx=$1; _rk_lbl=$2; _rk_sel=$3; _rk_buf=$4
    printf '%s|%s|%s|%s' "$_rk_idx" "$_rk_lbl" "$_rk_sel" "$_rk_buf"
}

# Draw one option row directly to stdout
_draw_option_row() {
    _do_idx=$1
    _do_lbl=$2
    _do_sel=$3   # 1 or 0
    _do_buf=$4

    _do_str_len=$(printf '%s' "$_do_lbl" | wc -c | tr -d ' \t')
    eval "_do_hk_len=\"\$_hk_len_$_do_idx\""

    if [ "$_layout" = "vertical" ]; then
        if [ "$_do_sel" = "1" ] && [ -z "$_do_buf" ]; then
            # Selected + no filter: full reverse, keep hotkey decoration
            if [ "$_allow_hotkeys" = "parenthesis" ]; then
                _do_pre=$(printf '%s' "$_do_lbl" | cut -c1-"$_do_hk_len")
                _do_suf=$(printf '%s' "$_do_lbl" | cut -c$((_do_hk_len + 1))-"$_do_str_len")
                printf "\033[7m (%s)%s \033[0m" "$_do_pre" "$_do_suf"
            elif [ "$_allow_hotkeys" = "bold" ]; then
                _do_pre=$(printf '%s' "$_do_lbl" | cut -c1-"$_do_hk_len")
                _do_suf=$(printf '%s' "$_do_lbl" | cut -c$((_do_hk_len + 1))-"$_do_str_len")
                printf "\033[7m \033[1m%s\033[22m%s \033[0m" "$_do_pre" "$_do_suf"
            else
                printf "\033[7m %s \033[0m" "$_do_lbl"
            fi
        elif [ -n "$_do_buf" ]; then
            # Filtering: highlight matched prefix, dim remainder
            _do_buf_len=$(printf '%s' "$_do_buf" | wc -c | tr -d ' \t')
            _do_m=$(printf '%s' "$_do_lbl" | cut -c1-"$_do_buf_len")
            _do_r=$(printf '%s' "$_do_lbl" | cut -c$((_do_buf_len + 1))-"$_do_str_len")
            printf ' %s' "$_do_m"
            printf "\033[2m%s\033[0m" "$_do_r"
        elif [ "$_allow_hotkeys" = "parenthesis" ]; then
            _do_pre=$(printf '%s' "$_do_lbl" | cut -c1-"$_do_hk_len")
            _do_suf=$(printf '%s' "$_do_lbl" | cut -c$((_do_hk_len + 1))-"$_do_str_len")
            printf ' (%s)%s' "$_do_pre" "$_do_suf"
        elif [ "$_allow_hotkeys" = "bold" ]; then
            _do_pre=$(printf '%s' "$_do_lbl" | cut -c1-"$_do_hk_len")
            _do_suf=$(printf '%s' "$_do_lbl" | cut -c$((_do_hk_len + 1))-"$_do_str_len")
            printf " \033[1m%s\033[0m%s" "$_do_pre" "$_do_suf"
        else
            printf ' %s' "$_do_lbl"
        fi
    else
        # horizontal
        if [ "$_do_sel" = "1" ] && [ -z "$_do_buf" ]; then
            # Selected + no filter: full reverse, keep hotkey decoration
            if [ "$_allow_hotkeys" = "parenthesis" ]; then
                _do_pre=$(printf '%s' "$_do_lbl" | cut -c1-"$_do_hk_len")
                _do_suf=$(printf '%s' "$_do_lbl" | cut -c$((_do_hk_len + 1))-"$_do_str_len")
                printf "\033[7m[(%s)%s]\033[0m " "$_do_pre" "$_do_suf"
            elif [ "$_allow_hotkeys" = "bold" ]; then
                _do_pre=$(printf '%s' "$_do_lbl" | cut -c1-"$_do_hk_len")
                _do_suf=$(printf '%s' "$_do_lbl" | cut -c$((_do_hk_len + 1))-"$_do_str_len")
                printf "\033[7m[\033[1m%s\033[22m%s]\033[0m " "$_do_pre" "$_do_suf"
            else
                printf "\033[7m[%s]\033[0m " "$_do_lbl"
            fi
        elif [ -n "$_do_buf" ]; then
            _do_buf_len=$(printf '%s' "$_do_buf" | wc -c | tr -d ' \t')
            _do_m=$(printf '%s' "$_do_lbl" | cut -c1-"$_do_buf_len")
            _do_r=$(printf '%s' "$_do_lbl" | cut -c$((_do_buf_len + 1))-"$_do_str_len")
            printf '[%s' "$_do_m"
            printf "\033[2m%s\033[0m] " "$_do_r"
        elif [ "$_allow_hotkeys" = "parenthesis" ]; then
            _do_pre=$(printf '%s' "$_do_lbl" | cut -c1-"$_do_hk_len")
            _do_suf=$(printf '%s' "$_do_lbl" | cut -c$((_do_hk_len + 1))-"$_do_str_len")
            printf '[(%s)%s] ' "$_do_pre" "$_do_suf"
        elif [ "$_allow_hotkeys" = "bold" ]; then
            _do_pre=$(printf '%s' "$_do_lbl" | cut -c1-"$_do_hk_len")
            _do_suf=$(printf '%s' "$_do_lbl" | cut -c$((_do_hk_len + 1))-"$_do_str_len")
            printf "[\033[1m%s\033[0m%s] " "$_do_pre" "$_do_suf"
        else
            printf '[%s] ' "$_do_lbl"
        fi
    fi
}

# Only redraw a row if its key changed
_update_row() {
    _ur_row=$1
    _ur_key=$2
    eval "_ur_prev=\"\$_prev_key_$_ur_row\""
    if [ "$_ur_key" != "$_ur_prev" ]; then
        _move_to_row "$_ur_row"
        _clear_line
        shift 2
        "$@"
        eval "_prev_key_$_ur_row=\"\$_ur_key\""
    fi
}

interactive_select() {
    _prompt="$1"
    _is_vertical="${2:-false}"
    _is_horizontal="${3:-false}"
    _allow_hotkeys="${4:-parenthesis}"

    shift 4
    _total_opts=$#

    if [ "$_total_opts" -lt 1 ]; then
        echo "Error: At least one option must be provided." >&2
        return 1
    fi

    _i=0
    for _opt in "$@"; do
        eval "_label_$_i=\"\$_opt\""
        _i=$((_i + 1))
    done

    # Duplicate check + hotkey prefix length
    _i=0
    while [ "$_i" -lt "$_total_opts" ]; do
        eval "_l1=\"\$_label_$_i\""
        _lower1=$(_to_lower "$_l1")

        _j=$((_i + 1))
        while [ "$_j" -lt "$_total_opts" ]; do
            eval "_l2=\"\$_label_$_j\""
            if [ "$(_to_lower "$_l2")" = "$_lower1" ]; then
                echo "Error: Duplicate label detected ('$_l1')." >&2
                exit 1
            fi
            _j=$((_j + 1))
        done

        _prefix_len=1
        _is_unique=0
        _len_l1=$(printf '%s' "$_l1" | wc -c | tr -d ' \t')
        while [ "$_is_unique" -eq 0 ] && [ "$_prefix_len" -le "$_len_l1" ]; do
            _sub1=$(printf '%s' "$_lower1" | cut -c1-"$_prefix_len")
            _match_found=0
            _k=0
            while [ "$_k" -lt "$_total_opts" ]; do
                if [ "$_i" -ne "$_k" ]; then
                    eval "_lo=\"\$_label_$_k\""
                    _sub_o=$(printf '%s' "$(_to_lower "$_lo")" | cut -c1-"$_prefix_len")
                    if [ "$_sub1" = "$_sub_o" ]; then _match_found=1; break; fi
                fi
                _k=$((_k + 1))
            done
            if [ "$_match_found" -eq 0 ]; then _is_unique=1
            else _prefix_len=$((_prefix_len + 1)); fi
        done
        eval "_hk_len_$_i=\"\$_prefix_len\""
        _i=$((_i + 1))
    done

    # Layout
    _layout="horizontal"
    if [ "$_is_vertical" = "true" ] && [ "$_is_horizontal" = "true" ]; then
        [ "$_total_opts" -gt 3 ] && _layout="vertical"
    elif [ "$_is_vertical" = "true" ]; then
        _layout="vertical"
    elif [ "$_is_horizontal" = "true" ]; then
        _layout="horizontal"
    elif [ "$_total_opts" -gt 3 ]; then
        _layout="vertical"
    fi

    _old_stty=$(stty -g)
    _cleanup() {
        _show_cursor; _reset_styles
        [ -n "$_old_stty" ] && stty "$_old_stty"
    }
    trap '_cleanup; exit 130' INT
    trap _cleanup EXIT TERM
    _hide_cursor

    # Block height: prompt row + option rows (vertical) or 1 options row (horizontal)
    if [ "$_layout" = "vertical" ]; then
        _block_height=$((_total_opts + 1))
    else
        _block_height=2
    fi

    # Print newlines to reserve space, then query where cursor landed
    _p_i=0
    while [ "$_p_i" -lt "$_block_height" ]; do
        printf "\n"
        _p_i=$((_p_i + 1))
    done

    stty raw -echo
    printf "\033[6n" >/dev/tty
    _dsr=""
    while true; do
        _c=$(dd bs=1 count=1 2>/dev/null </dev/tty)
        _dsr="${_dsr}${_c}"
        case "$_dsr" in *R) break ;; esac
    done
    stty "$_old_stty"
    _dsr="${_dsr#*\[}"
    _cur_row="${_dsr%%;*}"
    # Cursor is now one past the reserved block
    _block_start_row=$((_cur_row - _block_height - 1))

    # Draw static prompt once
    _move_to_row 0
    _clear_line
    printf '%s' "$_prompt"

    _selected=0
    _input_buffer=""

    while true; do
        # Compute matches
        _total_matches=0
        _matched_index=-1
        _m=0
        while [ "$_m" -lt "$_total_opts" ]; do
            eval "_lbl=\"\$_label_$_m\""
            case "$(_to_lower "$_lbl")" in
                "$(_to_lower "$_input_buffer")"*)
                    _total_matches=$((_total_matches + 1))
                    _matched_index=$_m ;;
            esac
            _m=$((_m + 1))
        done

        # Exact match collapses to single
        if [ "$_total_matches" -gt 0 ] && [ -n "$_input_buffer" ]; then
            _e=0
            while [ "$_e" -lt "$_total_opts" ]; do
                eval "_lbl=\"\$_label_$_e\""
                if [ "$(_to_lower "$_lbl")" = "$(_to_lower "$_input_buffer")" ]; then
                    _selected=$_e; _total_matches=1; _matched_index=$_e; break
                fi
                _e=$((_e + 1))
            done
        fi

        # Keep _selected on a visible option
        if [ "$_total_matches" -gt 0 ] && [ -n "$_input_buffer" ]; then
            eval "_sl=\"\$_label_$_selected\""
            case "$(_to_lower "$_sl")" in
                "$(_to_lower "$_input_buffer")"*) ;;
                *) _selected=$_matched_index ;;
            esac
        fi

        # Render rows
        if [ "$_layout" = "vertical" ]; then
            _draw_row=1
            _idx=0
            while [ "$_idx" -lt "$_total_opts" ]; do
                eval "_lbl=\"\$_label_$_idx\""
                case "$(_to_lower "$_lbl")" in
                    "$(_to_lower "$_input_buffer")"*)
                        _is_sel=0; [ "$_selected" -eq "$_idx" ] && _is_sel=1
                        _key=$(_row_key "$_idx" "$_lbl" "$_is_sel" "$_input_buffer")
                        _update_row "$_draw_row" "$_key" \
                            _draw_option_row "$_idx" "$_lbl" "$_is_sel" "$_input_buffer"
                        ;;
                    *)
                        _update_row "$_draw_row" "hidden" _go_col1
                        ;;
                esac
                _draw_row=$((_draw_row + 1))
                _idx=$((_idx + 1))
            done
            if [ "$_total_matches" -eq 0 ]; then
                _update_row 1 "nomatch:$_input_buffer" \
                    printf "\033[31mNo matches: %s\033[0m" "$_input_buffer"
            fi
        else
            # Build a key from all visible options + selection + buffer
            _horiz_key="${_selected}|${_input_buffer}"
            eval "_hp=\"\$_prev_key_1\""
            if [ "$_horiz_key" != "$_hp" ]; then
                _move_to_row 1
                _clear_line
                if [ "$_total_matches" -eq 0 ]; then
                    printf "\033[31mNo matches: %s\033[0m" "$_input_buffer"
                else
                    _idx=0
                    while [ "$_idx" -lt "$_total_opts" ]; do
                        eval "_lbl=\"\$_label_$_idx\""
                        case "$(_to_lower "$_lbl")" in
                            "$(_to_lower "$_input_buffer")"*)
                                _is_sel=0; [ "$_selected" -eq "$_idx" ] && _is_sel=1
                                _draw_option_row "$_idx" "$_lbl" "$_is_sel" "$_input_buffer"
                                ;;
                        esac
                        _idx=$((_idx + 1))
                    done
                fi
                eval "_prev_key_1=\"\$_horiz_key\""
            fi
        fi

        # Read one keystroke
        stty raw -echo
        _char=$(dd bs=1 count=1 2>/dev/null)
        stty "$_old_stty"

        if [ "$_char" = "$(printf '\003')" ]; then
            PICKER_LABEL=""; break

        elif [ "$_char" = "$(printf '\033')" ]; then
            stty raw -echo min 0 time 1
            _b1=$(dd bs=1 count=1 2>/dev/null)
            _b2=$(dd bs=1 count=1 2>/dev/null)
            stty "$_old_stty"
            _next="${_b1}${_b2}"
            if [ -z "$_next" ]; then
                if [ -n "$_input_buffer" ]; then _input_buffer=""
                else PICKER_LABEL=""; break; fi
            elif [ "$_next" = "[C" ] || [ "$_next" = "[B" ]; then
                [ -z "$_input_buffer" ] && _selected=$(( (_selected + 1) % _total_opts ))
            elif [ "$_next" = "[D" ] || [ "$_next" = "[A" ]; then
                [ -z "$_input_buffer" ] && _selected=$(( (_selected - 1 + _total_opts) % _total_opts ))
            fi

        elif [ "$_char" = "$(printf '\r')" ] || [ "$_char" = "$(printf '\n')" ] || [ -z "$_char" ]; then
            if [ "$_total_matches" -gt 0 ]; then
                eval "PICKER_LABEL=\"\$_label_$_selected\""
                break
            fi

        elif [ "$_char" = "$(printf '\177')" ] || [ "$_char" = "$(printf '\b')" ]; then
            if [ -n "$_input_buffer" ]; then
                _cur_len=$(printf '%s' "$_input_buffer" | wc -c | tr -d ' \t')
                _input_buffer=$(printf '%s' "$_input_buffer" | cut -c1-$((_cur_len - 1)))
            fi

        else
            if [ "$_allow_hotkeys" != "false" ]; then
                _input_buffer="${_input_buffer}${_char}"

                _m_count=0; _last_match=-1; _exact_match=-1; _idx=0
                while [ "$_idx" -lt "$_total_opts" ]; do
                    eval "_lbl=\"\$_label_$_idx\""
                    _lbl_low=$(_to_lower "$_lbl")
                    _buf_low=$(_to_lower "$_input_buffer")
                    [ "$_lbl_low" = "$_buf_low" ] && _exact_match=$_idx
                    case "$_lbl_low" in
                        "$_buf_low"*) _m_count=$((_m_count + 1)); _last_match=$_idx ;;
                    esac
                    _idx=$((_idx + 1))
                done

                if [ "$_exact_match" -ne -1 ] && [ "$_m_count" -eq 1 ]; then
                    _selected=$_exact_match
                    eval "PICKER_LABEL=\"\$_label_$_selected\""
                    break
                elif [ "$_m_count" -eq 1 ]; then
                    _selected=$_last_match
                    eval "PICKER_LABEL=\"\$_label_$_selected\""
                    break
                fi
            fi
        fi
    done

    _move_to_row "$_block_height"
    printf "\n"
    _cleanup
    trap - EXIT INT TERM
}
