#!/bin/bash
# TouchBridge PAM helpers — shared by install.sh, patch-pam.sh, and uninstall.sh.
#
# Preferred mechanism (macOS Sonoma 14+): write our hook into
# /etc/pam.d/sudo_local, Apple's sanctioned include for local sudo PAM changes.
# That file is unprotected and user-owned, so:
#   - we never edit the SIP-protected /etc/pam.d/sudo
#   - removing our hook is always possible (no lockout that needs Recovery Mode)
#   - a plain uninstall can't leave a dangling reference that bricks sudo
#
# Fallback (older macOS without the sudo_local include, e.g. Ventura): edit
# /etc/pam.d/sudo directly, with a backup and confirmation, as before.
#
# /etc/pam.d/screensaver has no *_local equivalent, so it is always edited
# directly.
#
# TB_PAM_DIR overrides the PAM directory (defaults to /etc/pam.d) — used only
# by the test harness; production callers leave it unset.

TB_PAM_DIR="${TB_PAM_DIR:-/etc/pam.d}"
TB_PAM_LINE="auth       sufficient     pam_touchbridge.so"

_tb_info()  { echo -e "\033[0;32m[INFO]\033[0m $1"; }
_tb_warn()  { echo -e "\033[1;33m[WARN]\033[0m $1"; }

# True when /etc/pam.d/sudo already includes sudo_local (macOS Sonoma 14+).
_tb_supports_sudo_local() {
    grep -qE '^[[:space:]]*auth[[:space:]]+include[[:space:]]+sudo_local' \
        "$TB_PAM_DIR/sudo" 2>/dev/null
}

# Directly edit a PAM file: back it up, optionally confirm, insert our line as
# the first auth line. Args: <file> <name> <prompt|"">
_tb_patch_pam_file() {
    local pam_file="$1" pam_name="$2" prompt="$3"
    local backup="${pam_file}.touchbridge-backup"

    if [ ! -f "$pam_file" ]; then
        _tb_warn "$pam_file does not exist — skipping."
        return 0
    fi
    if grep -q "pam_touchbridge" "$pam_file"; then
        _tb_info "$pam_name already enabled — skipping."
        return 0
    fi
    if [ ! -f "$backup" ]; then
        cp "$pam_file" "$backup"
        _tb_info "Backed up $pam_file to $backup"
    fi

    if [ "$prompt" = "prompt" ]; then
        echo ""
        echo "--- Proposed change to $pam_file ---"
        echo "Adding as first auth line:"
        echo "  $TB_PAM_LINE"
        echo ""
        echo "Current contents:"
        cat "$pam_file"
        echo "---"
        echo ""
        read -p "Apply this change to $pam_file? [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            _tb_warn "Skipped $pam_file."
            return 0
        fi
    fi

    local tmp inserted=0
    tmp=$(mktemp)
    while IFS= read -r line; do
        if [ $inserted -eq 0 ] && echo "$line" | grep -q "^auth"; then
            echo "$TB_PAM_LINE" >> "$tmp"
            inserted=1
        fi
        echo "$line" >> "$tmp"
    done < "$pam_file"
    [ $inserted -eq 0 ] && echo "$TB_PAM_LINE" >> "$tmp"
    cat "$tmp" > "$pam_file"
    rm -f "$tmp"
    _tb_info "Enabled $pam_name in $pam_file."
}

# Undo a direct edit: restore from backup, else strip our line.
_tb_restore_pam_file() {
    local pam_file="$1" pam_name="$2"
    local backup="${pam_file}.touchbridge-backup"

    if [ -f "$backup" ]; then
        cp "$backup" "$pam_file"
        rm -f "$backup"
        _tb_info "Restored $pam_file from backup."
    elif grep -q "pam_touchbridge" "$pam_file" 2>/dev/null; then
        local tmp
        tmp=$(mktemp)
        grep -v "pam_touchbridge" "$pam_file" > "$tmp" || true
        cat "$tmp" > "$pam_file"
        rm -f "$tmp"
        _tb_info "Removed TouchBridge line from $pam_file."
    else
        _tb_info "$pam_name not enabled — skipping."
    fi
}

# Enable the sudo hook. Arg: <prompt|""> (prompt only affects the direct-edit fallback).
tb_enable_sudo() {
    local prompt="${1:-}"
    local sudo_local="$TB_PAM_DIR/sudo_local"

    if _tb_supports_sudo_local; then
        if [ -f "$sudo_local" ] && grep -q "pam_touchbridge" "$sudo_local"; then
            _tb_info "sudo already enabled via sudo_local — skipping."
            return 0
        fi
        local tmp
        tmp=$(mktemp)
        printf '%s\n' "$TB_PAM_LINE" > "$tmp"
        [ -f "$sudo_local" ] && cat "$sudo_local" >> "$tmp"
        cat "$tmp" > "$sudo_local"
        rm -f "$tmp"
        chmod 644 "$sudo_local"
        _tb_info "Enabled sudo via $sudo_local (unprotected, safely removable)."
        return 0
    fi

    _tb_warn "This macOS has no sudo_local hook; editing $TB_PAM_DIR/sudo directly."
    _tb_patch_pam_file "$TB_PAM_DIR/sudo" "sudo" "$prompt"
}

# Enable the screensaver hook (always a direct edit).
tb_enable_screensaver() {
    _tb_patch_pam_file "$TB_PAM_DIR/screensaver" "screensaver" "${1:-}"
}

# Disable the sudo hook. Removes our sudo_local line (deleting the file if it
# then holds nothing meaningful) AND undoes any legacy direct edit.
tb_disable_sudo() {
    local sudo_local="$TB_PAM_DIR/sudo_local"
    if [ -f "$sudo_local" ] && grep -q "pam_touchbridge" "$sudo_local"; then
        local tmp
        tmp=$(mktemp)
        grep -v "pam_touchbridge" "$sudo_local" > "$tmp" || true
        if grep -qE '[^[:space:]]' "$tmp" 2>/dev/null; then
            cat "$tmp" > "$sudo_local"
            _tb_info "Removed TouchBridge line from $sudo_local (kept your other entries)."
        else
            rm -f "$sudo_local"
            _tb_info "Removed $sudo_local."
        fi
        rm -f "$tmp"
    fi
    _tb_restore_pam_file "$TB_PAM_DIR/sudo" "sudo"
}

# Disable the screensaver hook.
tb_disable_screensaver() {
    _tb_restore_pam_file "$TB_PAM_DIR/screensaver" "screensaver"
}
