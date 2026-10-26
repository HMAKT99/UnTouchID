#!/bin/bash
# Shared PAM management. Preserve unrelated entries and historical backups.
# TB_PAM_DIR is only used by filesystem-fixture tests, never by the PAM module.
TB_PAM_DIR="${TB_PAM_DIR:-/etc/pam.d}"
TB_PAM_MODULE="/Library/Security/TouchBridge/pam_touchbridge.so"
TB_TRUST_TOOL="/Library/Security/TouchBridge/touchbridge-trust"
TB_PAM_LINE="auth       sufficient     $TB_PAM_MODULE"
_tb_info() { printf '[INFO] %s\n' "$1"; }
_tb_warn() { printf '[WARN] %s\n' "$1" >&2; }
_tb_has_hook() {
    awk '$1 == "auth" && $3 ~ /(^|\/)pam_touchbridge\.so$/ {found=1} END {exit !found}' "$1" 2>/dev/null
}
_tb_verify_install() {
    [ -x "$TB_TRUST_TOOL" ] || { _tb_warn "Install the protected trust tool first."; return 1; }
    "$TB_TRUST_TOOL" check "$TB_TRUST_TOOL" file && "$TB_TRUST_TOOL" check "$TB_PAM_MODULE" file
}
_tb_safe_file() {
    [ ! -L "$1" ] || { _tb_warn "Refusing symlink: $1"; return 1; }
    [ ! -e "$1" ] || [ -f "$1" ] || { _tb_warn "Not a regular file: $1"; return 1; }
}
_tb_backup() {
    local backup="$1.touchbridge-backup"
    _tb_safe_file "$backup" || return 1
    if [ -f "$1" ] && [ ! -e "$backup" ]; then cp -p "$1" "$backup"; fi
}
_tb_replace_file() {
    local file="$1" source="$2" stage
    _tb_safe_file "$file" || return 1
    stage=$(mktemp "${file}.touchbridge-tmp.XXXXXX") || return 1
    if [ -f "$file" ]; then
        if ! cp -p "$file" "$stage"; then rm -f "$stage"; return 1; fi
    else
        chmod 644 "$stage"
    fi
    if ! cat "$source" > "$stage"; then rm -f "$stage"; return 1; fi
    if ! mv -f "$stage" "$file"; then rm -f "$stage"; return 1; fi
}
_tb_strip_hook() {
    local file="$1" tmp
    _tb_safe_file "$file" || return 1
    [ -f "$file" ] || return 0
    if _tb_has_hook "$file"; then
        _tb_backup "$file" || return 1
        tmp=$(mktemp) || return 1
        awk '!($1 == "auth" && $3 ~ /(^|\/)pam_touchbridge\.so$/)' "$file" > "$tmp"
        if ! _tb_replace_file "$file" "$tmp"; then rm -f "$tmp"; return 1; fi
        rm -f "$tmp"
    fi
}
_tb_supports_sudo_local() {
    grep -qE '^[[:space:]]*auth[[:space:]]+include[[:space:]]+sudo_local' "$TB_PAM_DIR/sudo" 2>/dev/null
}
_tb_patch_pam_file() {
    local file="$1" name="$2" prompt="${3:-}" tmp
    _tb_verify_install || return 1
    _tb_safe_file "$file" || return 1
    if [ ! -f "$file" ]; then _tb_warn "$file does not exist; skipped."; return 0; fi
    if [ "$prompt" = prompt ]; then
        printf 'Add %s to %s? [y/N] ' "$TB_PAM_MODULE" "$file"
        read -r answer
        case "$answer" in y|Y|yes|YES) ;; *) return 0 ;; esac
    fi
    _tb_backup "$file" || return 1
    _tb_strip_hook "$file" || return 1
    tmp=$(mktemp) || return 1
    awk -v hook="$TB_PAM_LINE" '!done && $1 == "auth" {print hook;done=1} {print} END {if(!done)print hook}' "$file" > "$tmp"
    if ! _tb_replace_file "$file" "$tmp"; then rm -f "$tmp"; return 1; fi
    rm -f "$tmp"
    _tb_info "Enabled $name using the protected absolute module path."
}
# Remove hooks before migration, replacement or deletion. Never restore an old
# backup over newer PAM changes; backups remain available for manual recovery.
tb_disable_sudo() {
    _tb_strip_hook "$TB_PAM_DIR/sudo_local" || return 1
    _tb_strip_hook "$TB_PAM_DIR/sudo" || return 1
}
tb_disable_screensaver() { _tb_strip_hook "$TB_PAM_DIR/screensaver"; }
tb_enable_sudo() {
    if _tb_supports_sudo_local; then
        local file="$TB_PAM_DIR/sudo_local" tmp
        _tb_verify_install || return 1
        _tb_safe_file "$file" || return 1
        _tb_backup "$file" || return 1
        _tb_strip_hook "$file" || return 1
        # Remove a legacy direct hook before installing sudo_local.
        _tb_strip_hook "$TB_PAM_DIR/sudo" || return 1
        tmp=$(mktemp) || return 1
        printf '%s\n' "$TB_PAM_LINE" > "$tmp"
        [ ! -f "$file" ] || cat "$file" >> "$tmp"
        if ! _tb_replace_file "$file" "$tmp"; then rm -f "$tmp"; return 1; fi
        rm -f "$tmp";chmod 644 "$file"
        if [ "$(id -u)" -eq 0 ]; then chown root:wheel "$file"; fi
        _tb_info "Enabled sudo_local with the protected module."
    else
        _tb_patch_pam_file "$TB_PAM_DIR/sudo" sudo "${1:-}"
    fi
}
tb_enable_screensaver() { _tb_patch_pam_file "$TB_PAM_DIR/screensaver" screensaver "${1:-}"; }
