#!/usr/bin/env bash
# 반드시 cjons-m2-lab:1.0 컨테이너 안에서만 실행한다.
# Usage: bash generate_load.sh {cpu|memory|oom|io|hang|stop}
set -euo pipefail

MODE="${1:-}"
HANG_PID_FILE=/tmp/cjons_hang.pid

require_stress_ng() {
  command -v stress-ng >/dev/null 2>&1 || {
    echo '[ERROR] stress-ng가 없습니다. cjons-m2-lab:1.0 이미지를 확인하세요.' >&2
    exit 3
  }
}

stop_hang() {
  if [ -r "$HANG_PID_FILE" ]; then
    pid="$(cat "$HANG_PID_FILE")"
    case "$pid" in
      ''|*[!0-9]*) ;;
      *)
        if kill -0 "$pid" 2>/dev/null; then
          kill "$pid" 2>/dev/null || true
          wait "$pid" 2>/dev/null || true
        fi
        ;;
    esac
    rm -f "$HANG_PID_FILE"
  fi
}

case "$MODE" in
  cpu)
    require_stress_ng
    workers="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
    [ "$workers" -gt 2 ] && workers=2
    echo "[CPU] ${workers} worker, 70%, 45초 후 자동 종료"
    exec stress-ng --cpu "$workers" --cpu-load 70 --timeout 45s \
      --metrics-brief
    ;;
  memory)
    require_stress_ng
    echo '[MEM] 128MiB 점유, 45초 후 자동 종료(OOM 없는 비교군)'
    exec stress-ng --vm 1 --vm-bytes 128M --vm-keep --timeout 45s \
      --metrics-brief
    ;;
  oom)
    require_stress_ng
    # 메모리 제한 가드 — 제한 없는 컨테이너(기준선 등)에서 실행하면 384MiB 할당이
    # 그냥 성공해 OOM 없이 «passed: 1»로 끝난다(조용한 성공).
    # 잘못된 위치라면 시작 전에 거부한다. lab2의 /labfs 가드와 같은 원칙이다.
    mem_max="$(cat /sys/fs/cgroup/memory.max 2>/dev/null \
      || cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null \
      || echo unknown)"
    case "$mem_max" in
      max|9223372036854771712)
        echo '[ERROR] 이 컨테이너에는 메모리 제한이 없습니다 — 384MiB 요청이 그냥 성공해 OOM이 나지 않습니다.' >&2
        echo '        exit로 실습 셸(root@cjons-lab-shell:/work#)까지 나간 뒤,' >&2
        echo '        labs/lab1_oom.md의 docker run(--memory=256m, cjons-m2-oom)으로 다시 들어오십시오.' >&2
        exit 4
        ;;
      unknown)
        echo '[WARN] cgroup 메모리 한도를 읽을 수 없어 제한 여부를 확인하지 못했습니다. 그대로 진행합니다.' >&2
        ;;
      *)
        if [ "$mem_max" -gt 536870912 ] 2>/dev/null; then
          echo "[WARN] 메모리 한도 ${mem_max}B(>512MiB) — 384MiB 요청으로는 OOM이 나지 않을 수 있습니다." >&2
        fi
        ;;
    esac
    echo '[OOM] 256MiB 제한 컨테이너에서 384MiB를 요청해 cgroup OOM 유발'
    exec stress-ng --vm 1 --vm-bytes 384M --vm-keep --oomable --timeout 45s \
      --metrics-brief
    ;;
  io)
    echo '[IO] 컨테이너 /tmp에 128MiB를 쓴 뒤 자동 삭제'
    trap 'rm -f /tmp/cjons_io_test.bin' EXIT INT TERM
    dd if=/dev/zero of=/tmp/cjons_io_test.bin bs=4M count=32 conv=fsync status=progress
    ;;
  hang)
    stop_hang
    sleep 45 &
    pid=$!
    printf '%s\n' "$pid" > "$HANG_PID_FILE"
    echo "[HANG] 안전한 S-state sleep PID=$pid (45초 후 자동 종료)"
    echo "       ps -o pid,stat,wchan:32,comm -p $pid"
    ;;
  stop)
    stop_hang
    echo '[HANG] 실습 프로세스를 정리했습니다.'
    ;;
  *)
    echo "Usage: $0 {cpu|memory|oom|io|hang|stop}" >&2
    exit 2
    ;;
esac
