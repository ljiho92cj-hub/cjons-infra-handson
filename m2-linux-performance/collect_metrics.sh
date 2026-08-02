#!/usr/bin/env bash
# USE Method 입문용 약 15초 스냅. 정밀 분석이 아닌 baseline/after 비교용이다.
# Usage: bash collect_metrics.sh [TAG]
set -euo pipefail

TAG="${1:-sample}"
case "$TAG" in
  ''|*[!A-Za-z0-9_-]*)
    echo '[ERROR] TAG는 영문·숫자·_·-만 사용하세요.' >&2
    exit 2
    ;;
esac
# v3.3: 스냅을 «호스트에 남는» 경로에 저장한다.
# 실습 컨테이너는 --rm 이라 /tmp 에 남긴 파일은 exit과 동시에 사라진다. 그러면
# baseline/after 두 스냅을 나중에 대조하거나 incident_report에 붙일 수 없다.
# 스크립트가 있는 디렉터리(= 호스트에서 bind mount된 모듈 폴더)의 .lab/ 에 남기고,
# 그 경로가 읽기전용이면(자동검증 경로 등) 종전대로 /tmp 로 되돌린다. .lab/ 은 .gitignore 대상이다.
_SNAP_NAME="cjons_metrics_${TAG}_$(date +%Y%m%d_%H%M%S).txt"
_SNAP_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)/.lab"
if mkdir -p "$_SNAP_DIR" 2>/dev/null && [ -w "$_SNAP_DIR" ]; then
  OUT="$_SNAP_DIR/$_SNAP_NAME"
else
  OUT="/tmp/$_SNAP_NAME"
fi

{
  echo '### date'; date -Is
  echo '### uptime'; uptime
  echo '### free (memory)'; free -h
  echo '### vmstat (r, si/so, wa)'; vmstat 1 4
  echo '### pidstat (process CPU)'; pidstat 1 2 2>/dev/null || echo '(pidstat unavailable)'
  echo '### iostat (disk %util, await)'; iostat -xz 1 2 2>/dev/null || echo '(iostat unavailable)'
  echo '### top processes by CPU'; ps -eo pid,ppid,stat,%cpu,%mem,comm --sort=-%cpu | awk 'NR <= 15'
  echo '### cgroup v2 memory.events (OOM primary evidence)'
  if [ -r /sys/fs/cgroup/memory.events ]; then
    cat /sys/fs/cgroup/memory.events
  else
    echo '(memory.events unavailable; cgroup version/mount를 확인하세요)'
  fi
  echo '### recent kernel messages (supplementary)'
  if dmesg >/tmp/cjons_dmesg.txt 2>/dev/null; then
    tail -30 /tmp/cjons_dmesg.txt
  else
    echo '(Docker Desktop/WSL2 컨테이너에서 dmesg는 권한상 보이지 않을 수 있음)'
  fi
  rm -f /tmp/cjons_dmesg.txt
} | tee "$OUT"

echo "Saved: $OUT"
