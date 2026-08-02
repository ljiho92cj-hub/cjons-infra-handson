# M2. Linux 성능·장애 분석 — 핸즈온

모든 부하는 `cjons-m2-lab:1.0` 컨테이너 안에서만 실행합니다. Mac과 WSL2의 호스트 도구 차이를 없애고, 호스트 메모리·디스크를 채우지 않기 위한 실행 방식입니다.

## 0. 환경 확인

루트에서 사전 캐시를 완료한 뒤 M2 폴더에서 점검합니다.

```bash
source 00-common/lab_env.sh
cd m2-linux-performance
bash labs/lab0_env_check.sh
```

`FAIL`이 하나라도 있으면 스크립트는 exit 1로 종료합니다. 수동 빌드가 필요한 경우:

```bash
docker build -t cjons-m2-lab:1.0 .
```

> **아래 모든 `docker run -v`의 좌변은 «호스트의 실제 경로»여야 합니다.** 실습 컨테이너는 호스트 Docker를
> 조작하는 sibling container라, 컨테이너 안 경로(`$PWD` = `/work/...`)를 그대로 넘기면
> `mounts denied: The path ... is not shared from the host`으로 실패합니다.
> `$CJONS_MOUNT_ROOT`가 그 «호스트 기준 저장소 경로»를 담고 있으므로 이 모듈의 명령은 모두 이 변수를 씁니다.
> 값이 비어 있으면 저장소 루트에서 `source 00-common/lab_env.sh`를 먼저 실행하십시오.
> 호스트에서 직접 실행하는 경우에도 두 값이 같으므로 명령이 그대로 성립합니다.
> (`docker build`의 컨텍스트 `.`는 CLI가 읽어 데몬에 전송하므로 이 제약을 받지 않습니다.)

## 1. USE 기준선 스냅

> **실행 위치: 실습 셸** — 프롬프트가 `root@cjons-lab-shell:/work#` 인지 확인하십시오.
> 다른 컨테이너 안에서 실행하면 `bash: docker: command not found` 가 납니다(관찰 대상 컨테이너에는
> docker CLI가 없습니다). 그 경우 `exit` 로 실습 셸까지 빠져나온 뒤 다시 실행하십시오.

```bash
docker run --rm -it --name cjons-m2-baseline --hostname cjons-m2-baseline \
  --pull=never --network=none \
  -v "$CJONS_MOUNT_ROOT/m2-linux-performance:/lab" -w /lab cjons-m2-lab:1.0 bash
```

프롬프트가 `root@cjons-m2-baseline:/lab#` 으로 바뀌면 **그 안에서**:

```bash
bash collect_metrics.sh baseline
```

`collect_metrics.sh`는 약 15초 입문 스냅입니다. `vmstat`, `pidstat`, `iostat`, 프로세스 상태, `memory.events`를 baseline/after로 비교합니다.
스냅은 모듈 폴더의 `.lab/` 에 저장되어 **컨테이너를 나가도 호스트에 남습니다**(마지막 줄 `Saved:` 경로 확인).

> **`pidstat` 표가 헤더만 나오고 비어 있는 것이 정상입니다.**
> `pidstat`은 **CPU를 실제로 쓴 태스크만** 출력합니다. 유휴 컨테이너에는 그런 태스크가 없으니 표가 빕니다 —
> 도구가 고장난 게 아니라 **「이 순간 CPU를 쓰는 프로세스가 없다」는 관측 결과**이고, 그것이 기준선입니다.
>
> `after` 스냅에서도 비어 있을 수 있습니다. `generate_load.sh oom` 의 부하는 **1초 미만에 OOM으로 죽어**
> 스냅 시점에는 이미 사라져 있기 때문입니다(stress-ng 출력 예: `finished prematurely after just 0.70 secs`).
>
> **그래서 이 Lab에서 실제로 «달라지는» 값은 `memory.events` 입니다** — `max` · `oom` · `oom_kill`.
> baseline/after 비교의 핵심 증거는 그쪽이고, `vmstat`·`iostat`·`pidstat` 은 «평상시 무엇을 보는가»를
> 익히는 판독 연습입니다. **비어 있는 표를 «정상」으로 판정하는 것도 판독입니다.**

## 2. OOM — 256MiB 제한 대 384MiB 요청

`labs/lab1_oom.md`를 따릅니다. 성공 증거는 `dmesg`가 아니라 cgroup v2 `memory.events`의 `oom`/`oom_kill` 증가입니다.

> **종료 코드와 도구의 자기보고는 증거가 아닙니다.** `generate_load.sh oom`이 쓰는
> `stress-ng --oomable`은 «OOM으로 죽어도 정상»이라는 선언이라, 워커가 실제로 OOM Kill을
> 당해도 `passed: 1` · `failed: 0` · **종료 코드 0**으로 끝납니다(그래서 이 줄에 `|| true`를 붙입니다).
> 같은 실행의 `memory.events`에서는 `max`가 수십 회, `oom`·`oom_kill`이 1로 올라가 있습니다.
> **도구의 자기보고와 커널의 기록이 어긋나는 순간**을 보는 것이 이 랩의 핵심입니다 —
> `failed: 0`을 보고 "OOM이 안 났다"고 판단하면 사건 자체를 놓칩니다.

## 3. 디스크 풀 3종 — 16MiB tmpfs로 격리

> **실행 위치: 실습 셸** — 프롬프트가 `root@cjons-lab-shell:/work#` 인지 확인하십시오.
> 다른 컨테이너 안에서 실행하면 `bash: docker: command not found` 가 납니다(관찰 대상 컨테이너에는
> docker CLI가 없습니다). 그 경우 `exit` 로 실습 셸까지 빠져나온 뒤 다시 실행하십시오.

```bash
docker rm -f cjons-m2-disk 2>/dev/null || true
docker run --rm -it --name cjons-m2-disk --hostname cjons-m2-disk \
  --pull=never --network=none \
  --tmpfs /labfs:rw,size=16m,nr_inodes=200 \
  -v "$CJONS_MOUNT_ROOT/m2-linux-performance:/lab" -w /lab cjons-m2-lab:1.0 bash
```

프롬프트가 `root@cjons-m2-disk:/lab#` 으로 바뀌면 **그 안에서**:

```bash
bash labs/lab2_disk_full.sh capacity
bash labs/lab2_disk_full.sh deleted-open
bash labs/lab2_disk_full.sh inode
```

각 모드는 시작·종료 시 자신의 파일만 정리하므로 순서대로 재실행할 수 있습니다.

> `deleted-open` 모드는 증거를 보여준 뒤 **Enter 입력을 기다립니다**(`read -r _`).
> 터미널에서는 직접 누르면 되지만, 스크립트나 자동화로 비대화형 실행할 때는 stdin을 넣어야
> 합니다. 그러지 않으면 `set -e` 때문에 거기서 끊겨 **fd를 닫은 뒤의 `df`**(용량이 돌아오는
>
> ```bash
> printf '\n' | bash labs/lab2_disk_full.sh deleted-open
> ```

## 4. Hang 판독

`labs/lab3_hang.md`를 따릅니다. 실제 D-state는 만들지 않고 45초 S-state 대기를 진단한 뒤 `stop` 모드로 정리합니다.

## 막혔을 때

| 증상 | 원인 · 조치 |
|---|---|
| `bash: docker: command not found` | 관찰 대상 컨테이너 안에 들어와 있습니다. 이 모듈의 `docker run` 은 **실습 셸**(`root@cjons-lab-shell:/work#`)에서만 됩니다 — `exit` 후 다시 실행 |
| `[ERROR] 이 컨테이너에는 메모리 제한이 없습니다` | 제한 없는 컨테이너(기준선 등)에서 `generate_load.sh oom` 을 실행했습니다. 제한이 없으면 OOM이 나지 않아 «가짜 성공»이 되므로 스크립트가 거부합니다 — `exit` 후 `labs/lab1_oom.md` 의 `docker run`(`--memory=256m`)으로 재진입 |
| `-v` 좌변이 비어 `/m2-linux-performance:/lab` 로 들어감 | `$CJONS_MOUNT_ROOT` 미설정. 실습 셸에서 `source 00-common/lab_env.sh` 실행 |
| `invalid volume specification` · `mounts denied` | 위와 같은 원인이거나 호스트 경로 미확정. `source 00-common/lab_env.sh` 재실행 후 `[WARN]` 안내를 따르십시오 |
| `Unable to find image 'cjons-m2-lab:1.0'` | `--pull=never` 라서 로컬에 없으면 즉시 실패합니다. 실습 셸에서 `bash 00-common/prefetch_assets.sh` 실행 |

## 성공 기준

- 각 사건에서 원인 유형 1개와 근거 3개를 제시했다.
- OOM은 `memory.events`, 용량 풀은 `df -h`, inode 풀은 `df -i`, deleted-open은 `lsof +L1`로 구분했다.
- `incident_report_template.md`에 증상→가설→증거→조치→검증 순서를 남겼다.

전체 정리는 루트에서 `bash 00-common/cleanup.sh`를 실행합니다.
