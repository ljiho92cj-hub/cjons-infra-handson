#!/usr/bin/env bash
# M1. OS 운영 핵심 리뷰 — OS 점검 셀프체크
# 목적: 프로세스 상태 / 파일 권한·UID / systemd·journalctl 세 축을 스스로 점검한다.
# 사용법: bash check_self.sh
#
# 주의: 이 스크립트는 시스템을 변경하지 않는다(read-only 점검). sudo 없이 실행 가능한 항목 위주.
#       일부 명령(dmesg, journalctl)은 환경/권한에 따라 결과가 비어 있거나 접근이 제한될 수 있다 — 정상 상황이다.

set -u

if [ "$(uname -s)" != Linux ]; then
  echo '[ERROR] 이 실습은 Linux 프로세스/커널 판독용입니다.' >&2
  echo '        macOS에서는 README의 cjons-m2-lab:1.0 컨테이너 명령으로 실행하세요.' >&2
  exit 1
fi

section() {
  printf '\n=== %s ===\n' "$1"
}

echo "M1 OS 운영 핵심 리뷰 — 셀프체크 시작 ($(date))"

# ---------------------------------------------------------------------------
# 1. 프로세스 상태: D-state / 좀비 / PID 1 / OOM 이력
# ---------------------------------------------------------------------------
section "1-1. 프로세스 STAT 컬럼 전체 보기 (상위 20개)"
ps -eo pid,ppid,stat,cmd 2>/dev/null | awk 'NR <= 20'

section "1-2. D 상태(uninterruptible sleep) 프로세스 찾기"
if ps -eo pid,stat,cmd 2>/dev/null | awk '$2 ~ /D/ {print}' | grep -q .; then
  ps -eo pid,stat,cmd 2>/dev/null | awk '$2 ~ /D/ {print}'
else
  echo "(현재 D 상태 프로세스 없음 — 정상)"
fi

section "1-3. 좀비(Z) 프로세스 찾기"
if ps -eo pid,ppid,stat,cmd 2>/dev/null | awk '$3 ~ /Z/ {print}' | grep -q .; then
  ps -eo pid,ppid,stat,cmd 2>/dev/null | awk '$3 ~ /Z/ {print}'
else
  echo "(현재 좀비 프로세스 없음 — 정상)"
fi

section "1-4. PID 1 확인"
ps -p 1 -o pid,ppid,cmd 2>/dev/null || echo "(PID 1 조회 불가 — 컨테이너/제한 환경일 수 있음)"

section "1-5. OOM 이력 확인 (dmesg / 커널 로그)"
if command -v dmesg >/dev/null 2>&1; then
  dmesg 2>/dev/null | grep -i -E "out of memory|killed process" | tail -10
  echo "(위 결과가 비어 있으면 최근 OOM 이력 없음 또는 dmesg 접근 권한 부족)"
else
  echo "(dmesg 명령을 찾을 수 없음 — macOS 등 비-Linux 환경일 수 있음)"
fi

# ---------------------------------------------------------------------------
# 2. 파일 권한 / UID
# ---------------------------------------------------------------------------
section "2-1. 현재 사용자 UID/GID 확인"
id

section "2-2. umask 값 확인"
umask

section "2-3. 실습 작업 경로와 /tmp 권한(숫자 UID/GID 포함)"
ls -ldn . /tmp 2>/dev/null

section "2-4. 특수 비트(setuid/setgid/sticky) 탐색 예시 (/usr/bin, 실패해도 정상)"
find /usr/bin -perm -4000 -type f 2>/dev/null | awk 'NR <= 5'
echo "(권한 부족으로 결과가 없거나 에러가 나면 정상 — /tmp 등 본인 소유 디렉터리로 바꿔 재시도해도 됨)"

# ---------------------------------------------------------------------------
# 3. systemd / journalctl
# ---------------------------------------------------------------------------
section "3-1. systemctl 존재 여부 및 failed 유닛 확인"
if command -v systemctl >/dev/null 2>&1; then
  systemctl --failed 2>/dev/null || echo "(systemctl --failed 조회 불가)"
else
  echo "(systemctl 명령을 찾을 수 없음 — macOS, 컨테이너, WSL 등 systemd 미사용 환경일 수 있음)"
fi

section "3-2. journalctl 최근 로그 3줄 (예시 서비스가 없으면 전체 최근 로그)"
if command -v journalctl >/dev/null 2>&1; then
  journalctl -n 3 --no-pager 2>/dev/null || echo "(journalctl 접근 권한 부족 — sudo 필요할 수 있음)"
else
  echo "(journalctl 명령을 찾을 수 없음)"
fi

echo
echo "셀프체크 완료. 결과를 그대로 복붙하지 말고, observation_checklist.md에 '무엇을 보고 무엇을 판단했는지' 기록하세요."
