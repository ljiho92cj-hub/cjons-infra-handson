#!/usr/bin/env bash
# 강의 전, 인터넷이 되는 환경에서 단 한 번 실행한다.
set -euo pipefail

COMMON_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
# shellcheck disable=SC1091
. "$COMMON_DIR/lab_env.sh"

command -v docker >/dev/null 2>&1 || { echo '[ERROR] docker CLI가 없습니다.' >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo '[ERROR] Docker Desktop/daemon을 먼저 실행하세요.' >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo '[ERROR] curl이 없습니다.' >&2; exit 1; }

mkdir -p "$CJONS_LAB_STATE"

printf '[1/3] Pull pinned images\n'
for image in "$CJONS_NODE_IMAGE" "$CJONS_NGINX_IMAGE" "$CJONS_BUSYBOX_IMAGE" "$CJONS_ETCD_IMAGE"; do
  docker pull "$image"
done

printf '[2/3] Build M2 image\n'
docker build --pull -t "$CJONS_M2_IMAGE" "$CJONS_LAB_ROOT/m2-linux-performance"

printf '[3/3] Download and verify metrics-server manifest\n'
curl --fail --location --retry 3 --output "$CJONS_METRICS_MANIFEST.part" "$CJONS_METRICS_MANIFEST_URL"
if command -v sha256sum >/dev/null 2>&1; then
  actual_hash="$(sha256sum "$CJONS_METRICS_MANIFEST.part" | awk '{print $1}')"
else
  actual_hash="$(shasum -a 256 "$CJONS_METRICS_MANIFEST.part" | awk '{print $1}')"
fi
if [ "$actual_hash" != "$CJONS_METRICS_MANIFEST_SHA256" ]; then
  echo "[ERROR] metrics-server checksum mismatch: $actual_hash" >&2
  exit 1
fi
mv "$CJONS_METRICS_MANIFEST.part" "$CJONS_METRICS_MANIFEST"

echo '[DONE] 사전 자산 준비 완료. 이제 check_env.sh assets를 실행하세요.'
