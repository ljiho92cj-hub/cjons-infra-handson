# Lab 3. Hang 진단 — S-state와 D-state (25분)

이 Lab은 호스트에 부작용을 남길 수 있는 진짜 D-state를 만들지 않고, 45초 sleep의 S-state를 `ps`와 `strace`로 관찰합니다.

저장소 루트에서 별도 컨테이너를 실행합니다. `SYS_PTRACE`와 seccomp 설정은 그 컨테이너에만 적용됩니다.

> **실행 위치: 실습 셸** — 프롬프트가 `root@cjons-lab-shell:/work#` 인지 확인하십시오.
> 다른 컨테이너 안에서 실행하면 `bash: docker: command not found` 가 납니다(관찰 대상 컨테이너에는
> docker CLI가 없습니다). 그 경우 `exit` 로 실습 셸까지 빠져나온 뒤 다시 실행하십시오.

```bash
docker rm -f cjons-m2-hang 2>/dev/null || true
docker run --rm -it --name cjons-m2-hang --hostname cjons-m2-hang \
  --pull=never --network=none \
  --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
  -v "$CJONS_MOUNT_ROOT/m2-linux-performance:/lab" -w /lab cjons-m2-lab:1.0 bash
```

> `$CJONS_MOUNT_ROOT`(호스트 기준 저장소 경로)가 비어 있으면 저장소 루트에서 `source 00-common/lab_env.sh`를 먼저 실행하십시오. `-v`의 좌변에 컨테이너 안 경로(`$PWD` = `/work/...`)를 넘기면 `mounts denied`로 실패합니다.

프롬프트가 `root@cjons-m2-hang:/lab#` 으로 바뀝니다. **이제부터는 그 안에서** 실행합니다.

```bash
bash generate_load.sh hang
HANG_PID="$(cat /tmp/cjons_hang.pid)"
ps -o pid,stat,wchan:32,comm -p "$HANG_PID"
timeout 5s strace -p "$HANG_PID" -T
bash generate_load.sh stop
```

| 상태 | 의미 | 이 랩의 행동 |
|---|---|---|
| S | 시그널로 깨울 수 있는 대기 | `strace` syscall과 `wchan` 확인 |
| D | 커널의 I/O 완료 대기 | 재현하지 않고 `wchan`, `iostat -xz` 순으로 판독 |
| Z | 부모가 `wait()`하지 않은 종료 프로세스 | PPID와 부모 로직 확인 |

성공 기준은 STAT을 먼저 보고, S에서만 안전하게 `strace`하며, D에서는 `wchan`을 먼저 본다는 순서를 설명하는 것입니다.
