# Lab 1. cgroup OOM 판독 (25분)

메모리 제한은 컨테이너에만 적용됩니다. Docker Desktop·WSL2에서 `dmesg`는 보이지 않을 수 있으므로 cgroup v2의 `memory.events` 변화를 1차 증거로 사용합니다.

## 진행

저장소 루트에서 실행합니다.

> **실행 위치: 실습 셸** — 프롬프트가 `root@cjons-lab-shell:/work#` 인지 확인하십시오.
> 다른 컨테이너 안에서 실행하면 `bash: docker: command not found` 가 납니다(관찰 대상 컨테이너에는
> docker CLI가 없습니다). 그 경우 `exit` 로 실습 셸까지 빠져나온 뒤 다시 실행하십시오.

```bash
docker rm -f cjons-m2-oom 2>/dev/null || true
docker run --rm -it --name cjons-m2-oom --hostname cjons-m2-oom \
  --pull=never --network=none --memory=256m --memory-swap=256m \
  --cpus=2 --pids-limit=256 --cap-drop=ALL \
  -v "$CJONS_MOUNT_ROOT/m2-linux-performance:/lab" -w /lab cjons-m2-lab:1.0 bash
```

> `$CJONS_MOUNT_ROOT`(호스트 기준 저장소 경로)가 비어 있으면 저장소 루트에서 `source 00-common/lab_env.sh`를 먼저 실행하십시오. `-v`의 좌변에 컨테이너 안 경로(`$PWD` = `/work/...`)를 넘기면 `mounts denied`로 실패합니다.

프롬프트가 `root@cjons-m2-oom:/lab#` 으로 바뀝니다. **이제부터는 그 안에서** 실행합니다.

> `generate_load.sh oom`은 시작 전에 이 컨테이너의 cgroup 메모리 한도를 확인해 **제한이 없으면
> `[ERROR]`로 거부합니다.** 제한 없는 컨테이너(예: 기준선 `cjons-m2-baseline`)에서는 384MiB 할당이
> 그냥 성공해 «OOM이 안 난 실행»이 조용히 만들어지기 때문입니다(제한 없는 컨테이너에서 흔히 빠지는 함정입니다).
> 이 `[ERROR]`가 보이면 지금 있는 곳이 잘못된 컨테이너라는 뜻입니다 — `exit` 후 위 `docker run`으로 다시 들어오십시오.

```bash
cat /sys/fs/cgroup/memory.events | tee /tmp/memory-events.before
bash collect_metrics.sh baseline
bash generate_load.sh oom || true
cat /sys/fs/cgroup/memory.events | tee /tmp/memory-events.after
diff -u /tmp/memory-events.before /tmp/memory-events.after || true
bash collect_metrics.sh after
```

`oom` 또는 `oom_kill`이 1 이상 증가하면 성공입니다. `dmesg -T | tail -30`은 보조 증거로만 실행하고, 권한 거부는 실습 실패로 보지 않습니다.

## 성공 기준

- 제한은 256MiB, 부하 요청은 384MiB임을 설명했다.
- `memory.events` 전·후 차이로 OOM을 입증했다.
- 호스트가 아닌 컨테이너 cgroup의 제한 사건임을 구분했다.
