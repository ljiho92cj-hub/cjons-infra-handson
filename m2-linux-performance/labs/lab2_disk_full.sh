#!/usr/bin/env bash
# Usage: bash labs/lab2_disk_full.sh {capacity|deleted-open|inode}
# 반드시 --tmpfs /labfs:rw,size=16m,nr_inodes=200 컨테이너에서 실행한다.
set -euo pipefail

MODE="${1:-}"
LABFS=/labfs

if [ ! -d "$LABFS" ] || ! mountpoint -q "$LABFS"; then
  echo "[ERROR] $LABFS 전용 tmpfs가 없습니다. M2 README의 docker run 명령을 사용하세요." >&2
  exit 3
fi

cleanup_files() {
  rm -f "$LABFS/fill.bin" "$LABFS/deleted_but_open.bin"
  find "$LABFS" -maxdepth 1 -type f -name 'inode_*' -delete 2>/dev/null || true
}

cleanup_files
trap cleanup_files EXIT INT TERM

case "$MODE" in
  capacity)
    echo '[capacity] 16MiB tmpfs에 64MiB 쓰기 시도'
    df -h "$LABFS"
    dd if=/dev/zero of="$LABFS/fill.bin" bs=1M count=64 conv=fsync status=progress || true
    df -h "$LABFS"
    echo '[evidence] Use% 증가와 No space left on device를 확인하세요.'
    ;;
  deleted-open)
    echo '[deleted-open] 8MiB 파일을 fd 9로 열어 둔 채 삭제'
    dd if=/dev/zero of="$LABFS/deleted_but_open.bin" bs=1M count=8 conv=fsync status=none
    exec 9<>"$LABFS/deleted_but_open.bin"
    rm -f "$LABFS/deleted_but_open.bin"
    df -h "$LABFS"
    lsof -a -p "$$" +L1
    echo '[evidence] NAME의 (deleted), NLINK 0을 확인했으면 Enter를 누르세요.'
    read -r _
    exec 9>&-
    df -h "$LABFS"
    ;;
  inode)
    echo '[inode] 작은 파일을 inode 한계까지 생성'
    df -i "$LABFS"
    i=0
    while [ "$i" -lt 500 ]; do
      : > "$LABFS/inode_$i" 2>/dev/null || break
      i=$((i + 1))
    done
    echo "생성된 파일: $i"
    df -i "$LABFS"
    echo '[evidence] IUse% 증가와 inode 할당 실패를 확인하세요.'
    ;;
  *)
    echo "Usage: $0 {capacity|deleted-open|inode}" >&2
    exit 2
    ;;
esac
