show_package_menu() {
    printf '分享外掛範例\n---\n套件版本：%s\n' "$SPLITSWAN_PLUGIN_VERSION"
    printf '資源內容：'
    cat "$SPLITSWAN_PLUGIN_ROOT/resources/message.txt"
    printf '\n'
}
