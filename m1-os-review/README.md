# M1. OS 운영 핵심 리뷰 — Linux 셀프체크

`check_self.sh`는 Linux의 `ps STAT`, PID 1, OOM 이력, UID/GID·umask, systemd/journal을 읽는 10~15분 분량의 **선택 과제**입니다(쉬는시간·강의 후 자율 실습용). 개인 홈 폴더의 파일명은 조회하지 않습니다.

## Mac·Windows 공통 경로

Mac 호스트의 BSD `ps`는 Linux 옵션/상태 표시와 다르므로 직접 실행하지 않습니다. Mac과 Windows 수강생 모두 사전 빌드한 같은 Linux 이미지로 프로세스/권한 구간을 검산합니다.

```bash
# 저장소 루트에서 사전 점검
source 00-common/lab_env.sh
bash 00-common/check_env.sh assets

# M1 폴더를 읽기 전용으로 mount
docker run --rm -it --hostname cjons-m1-lab --pull=never --network=none \
  --read-only --tmpfs /tmp:rw,size=16m \
  -v "$CJONS_MOUNT_ROOT/m1-os-review:/lab:ro" -w /lab \
  cjons-m2-lab:1.0 bash check_self.sh
```

> `docker run -v`의 좌변은 **호스트의 실제 경로**여야 합니다. 실습 컨테이너는 호스트 Docker를 조작하는
> sibling container라, 컨테이너 안 경로(`/work/...`)를 그대로 넘기면
> `mounts denied: The path ... is not shared from the host`으로 실패합니다.
> `$CJONS_MOUNT_ROOT`가 그 «호스트 기준 저장소 경로»를 담고 있습니다.
> 값이 비어 있으면 저장소 루트에서 `source 00-common/lab_env.sh`를 먼저 실행하십시오.
> 호스트에서 직접 실행하는 경우에도 같은 명령이 그대로 성립합니다(두 값이 같습니다).

컨테이너에는 systemd가 없을 수 있으므로 해당 구간의 `사용 불가`는 정상 관찰입니다.

### 곁들여 보기 — 같은 스크립트, 다른 PID 1

위 표준 경로로 한 번 돌린 뒤, **실습 셸에서도** 한 번 돌려 §1-1·§1-4를 비교하십시오.

```bash
cd m1-os-review && bash check_self.sh     # 실습 셸에서 — 대조용
```

| | 격리 컨테이너 (표준 경로) | 실습 셸에서 실행 |
|---|---|---|
| **PID 1** | `bash check_self.sh` — 내가 실행한 명령이 곧 1번 | `bash` — 실습 셸 자신 |
| 보이는 프로세스 | 3개 안팎, 자기 자신뿐 | 실습 셸이 띄운 것들까지 함께 |
| `/tmp` | `--tmpfs` 로 붙인 별도 파일시스템 | 컨테이너 이미지의 `/tmp` |

같은 커널 위에서 도는데 **«1번 프로세스»가 다릅니다.** PID 1은 시스템의 속성이 아니라
**네임스페이스의 속성**이라는 것이 이 모듈의 핵심이고, 컨테이너 장애 조사에서
「PID 1이 죽으면 컨테이너가 끝난다」로 곧장 이어집니다.

### 부록 — 호스트에서 직접 실행하는 경우 (선택)

리눅스 호스트나 WSL2 Ubuntu **자체**의 systemd/journal까지 관찰하려면 그 터미널에서 추가로 실행할 수 있습니다. 표준 경로가 아닌 **예외 경로**이며, 실습 진행에 필수는 아닙니다.

> **실행 위치: 호스트 터미널** — 컨테이너 «밖»입니다.
> 실습 셸(`root@cjons-lab-shell:/work#`) 안에서 실행하면 **이 부록의 목적을 달성하지 못합니다.**
> 실습 셸도 컨테이너라 systemd·journal이 없어 §3-1·3-2가 똑같이 「사용 불가」로 나옵니다.
> **오류 없이 «성공한 것처럼» 끝나므로** 특히 주의하십시오 — 위 「곁들여 보기」와 혼동하지 마십시오.

```bash
# 호스트 터미널(컨테이너 밖)에서 — 저장소 루트에서든 m1-os-review 안에서든 동작합니다
[ -f check_self.sh ] || cd m1-os-review
bash check_self.sh
```

systemd를 활성화하지 않은 WSL2에서는 컨테이너와 같은 `사용 불가` 결과가 나올 수 있습니다.
**Windows PowerShell에서는 이 부록을 쓸 수 없습니다**(`.sh` 는 bash가 필요합니다). Windows 수강생은
표준 경로와 위 「곁들여 보기」로 충분하며, systemd 구간은 강사 시연으로 대체합니다.

## 관찰 순서

1. `STAT` 컬럼에서 S/D/Z를 구분하고 PID 1을 확인합니다.
2. OOM 로그의 유무와 접근 권한을 구분합니다.
3. 현재 사용자의 UID/GID, umask, 실습 경로·`/tmp` 권한을 읽습니다.
4. systemd 환경에서 failed unit과 최근 journal 3줄을 연결합니다.

결과 전체를 붙이지 말고 `observation_checklist.md`에 “무엇을 봤고 무엇을 판단했는지”를 한 문장으로 남깁니다. 실제 회사 서버에서는 보안 정책과 실행 승인을 먼저 확인합니다.
