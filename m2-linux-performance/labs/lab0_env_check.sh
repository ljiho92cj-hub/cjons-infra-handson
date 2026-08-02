#!/usr/bin/env bash
# M2 호스트 환경을 검사하고 하나라도 실패하면 exit 1을 반환한다.
set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
M2_DIR="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd -P)"
IMAGE=cjons-m2-lab:1.0
FAIL=0

check() {
  desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "[PASS] $desc"
  else
    echo "[FAIL] $desc"
    FAIL=$((FAIL + 1))
  fi
}

echo '=== M2 Linux 성능·장애 실습 환경 점검 ==='
check 'docker CLI' command -v docker
check 'docker daemon' docker info
check "$IMAGE image" docker image inspect "$IMAGE"
check 'Linux tools in an offline container' docker run --rm --pull=never --network=none "$IMAGE" \
  bash -lc 'command -v vmstat sar pidstat iostat strace stress-ng jq curl lsof python3'

if [ "$FAIL" -ne 0 ]; then
  echo
  echo "[ACTION] 루트에서 bash 00-common/prefetch_assets.sh를 실행한 뒤 재시도하세요."
  echo "         수동 빌드: docker build -t $IMAGE \"$M2_DIR\""
  exit 1
fi

echo '[DONE] M2 환경 점검 통과'
