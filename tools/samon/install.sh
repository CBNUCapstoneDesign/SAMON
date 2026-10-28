#!/bin/bash
# install.sh — samon 제어 도구 설치 (인터넷 연결 없이 저장소 안의 파일만 복사한다)
#
#   sudo bash tools/samon/install.sh            설치
#   sudo bash tools/samon/install.sh -u         제거 (/etc/samon/samon.conf는 남긴다)
#
# 설치 위치
#   /usr/local/lib/samon/      samon, samonctl.py, samon_cli.py, samon_web.py, web/index.html
#   /usr/local/bin/samon       위 samon으로의 링크
#   /etc/samon/samon.conf      없을 때만 samon.conf.example을 복사
set -euo pipefail

SRC=$(cd "$(dirname "$0")" && pwd)
LIB=/usr/local/lib/samon
BIN=/usr/local/bin/samon
ETC=/etc/samon

die() { printf 'install.sh: %s\n' "$*" >&2; exit 2; }

[ "$(id -u)" = 0 ] || die "run as root: sudo bash $0"

if [ "${1:-}" = -u ]; then
	rm -f "$BIN"
	rm -rf "$LIB"
	echo "removed $BIN $LIB (kept $ETC)"
	exit 0
fi
[ $# -eq 0 ] || die "usage: sudo bash $0 [-u]"

command -v python3 >/dev/null || die "python3가 없다: sudo apt install python3"
python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' || die "python3 3.8 이상이 필요하다"
python3 -c 'import rich' 2>/dev/null || die "rich가 없다: sudo apt install python3-rich (인터넷이 없으면 .deb를 미리 받아 설치)"

install -d -m 755 "$LIB" "$LIB/web"
install -m 755 "$SRC/samon" "$LIB/samon"
install -m 644 "$SRC/samonctl.py" "$SRC/samon_cli.py" "$SRC/samon_web.py" "$LIB/"
install -m 644 "$SRC/web/index.html" "$LIB/web/index.html"
ln -sfn "$LIB/samon" "$BIN"

install -d -m 755 "$ETC"
[ -e "$ETC/samon.conf" ] || install -m 644 "$SRC/samon.conf.example" "$ETC/samon.conf"

echo "installed: $BIN -> $LIB/samon"
echo "  sudo samon            대화형 CLI"
echo "  sudo samon web        웹 (http://127.0.0.1:$(awk -F'= *' '/^port/{print $2; exit}' "$ETC/samon.conf" 2>/dev/null || echo 8765))"
