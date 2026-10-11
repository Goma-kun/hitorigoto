#!/bin/sh
# 中継サーバーの合言葉を ~/.config/nishira/hitorigoto_relay_app_key から読み、
# ios/App/RelaySecret.swift（gitignore 済み）を作る。ビルドの前に一度走らせる。
set -e
cd "$(dirname "$0")/.."
SRC="${HITORIGOTO_RELAY_APP_KEY_FILE:-$HOME/.config/nishira/hitorigoto_relay_app_key}"
if [ ! -f "$SRC" ]; then echo "合言葉のファイルがありません: $SRC" >&2; exit 1; fi
KEY=$(tr -d '\n\r' < "$SRC")
cat > App/RelaySecret.swift <<SWIFT
// gen_relay_secret.sh が作るファイル。手で編集しない・コミットしない（.gitignore 済み）
enum RelaySecret {
    static let appKey = "$KEY"
}
SWIFT
echo "App/RelaySecret.swift を書きました"
