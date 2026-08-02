# CJONS Infra 심화 핸즈온

리눅스 성능·장애 분석과 Kubernetes 운영을 **Docker 하나로** 실습하는 저장소입니다.
Windows·macOS·Linux 어디서든 같은 이미지(`cjons-lab:1.0`) 안에서 실행하므로 도구 버전 차이·CRLF·경로·권한 문제가 생기지 않습니다. **설치할 것은 Docker 하나뿐입니다.**

## 바로 시작하기

```bash
git clone https://github.com/cjonsinfra/cjons-infra-handson.git
cd cjons-infra-handson
bash lab/lab.sh verify          # Windows: .\lab\lab.cmd verify
```

`SUMMARY … FAIL=0` 이 나오면 준비 완료입니다. 최초 1회는 이미지 빌드에 3~5분 걸립니다.
실습을 «내 것»으로 남기려면 clone 대신 [fork](#0-1-이-저장소를-내-계정으로-fork)부터 하십시오.

---

## 0. 시작하기

### 0-1. 이 저장소를 내 계정으로 fork

1. GitHub에서 이 저장소 우측 상단 **Fork** 를 누릅니다.
2. 본인 계정에 복사된 저장소를 clone합니다.

```bash
git clone https://github.com/YOUR_ACCOUNT/cjons-infra-handson.git
cd cjons-infra-handson
```

> fork를 하면 실습 중 수정한 매니페스트·답안이 **본인 저장소에 그대로 남습니다.** 강의 후에도 계속 쓸 수 있고, 원본이 갱신되면 `git pull upstream main` 으로 받아올 수 있습니다.
>
> ```bash
> git remote add upstream https://github.com/cjonsinfra/cjons-infra-handson.git
> git fetch upstream && git merge upstream/main
> ```
>
> ※ `YOUR_ACCOUNT` 는 **수강생 본인의** GitHub 계정으로 바꿔 넣습니다. 원본(upstream) 저장소는 **https://github.com/cjonsinfra/cjons-infra-handson** 입니다.

### 0-2. 실습 컨테이너 진입

```bash
bash lab/lab.sh              # macOS · Linux · WSL2
```

```powershell
.\lab\lab.cmd                # Windows — 이쪽을 쓰십시오 (WSL 배포판 설치 불필요)
```

최초 1회는 이미지를 빌드하므로 3~5분 걸립니다. 이후에는 즉시 진입합니다.

> **Windows에서 `.\lab\lab.ps1` 이 아니라 `.\lab\lab.cmd` 를 쓰는 이유**
>
> Windows는 기본값(`Restricted`)에서 PowerShell 스크립트 실행을 막습니다. 그대로 `.\lab\lab.ps1`
> 을 실행하면 아래처럼 첫 줄에서 거부됩니다.
>
> ```
> .\lab\lab.ps1 : 이 시스템에서 스크립트를 실행할 수 없으므로 ... 파일을 로드할 수 없습니다.
> ```
>
> `lab.cmd` 는 **그 한 번의 실행에만** 정책을 우회하는 래퍼입니다. PC 설정을 바꾸지 않으므로
> 사내 보안 정책에 저촉되지 않고, 자료를 zip으로 받아 압축을 푼 경우에 붙는 차단 표시
> (Mark-of-the-Web)도 같이 우회합니다.
>
> `.ps1` 을 직접 쓰고 싶다면 현재 창에서만 한시적으로 허용하십시오(PC 설정 불변):
>
> ```powershell
> Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
> .\lab\lab.ps1
> ```

### 0-3. 준비 확인

컨테이너 안에서:

```bash
bash 00-common/check_env.sh host        # 환경 점검
bash 00-common/prefetch_assets.sh       # 이미지·매니페스트 캐시(온라인 1회)
bash 00-common/setup_cluster.sh         # kind 클러스터 생성
bash 00-common/verify_all.sh            # M1~M8 전 모듈 자동 검증
```

`SUMMARY ... FAIL=0` 이면 준비 완료입니다.

한 줄로 끝내려면 — **호스트에서** 실행합니다(컨테이너 안이 아닙니다).

```bash
bash lab/lab.sh verify       # macOS · Linux · WSL2 — 위 4단계를 순서대로 자동 실행
```

```powershell
.\lab\lab.cmd verify         # Windows — 같은 동작
```

### 0-4. 터미널을 하나 더 열려면 (M5·M6에서 필요)

M5 Lab 5-1과 M6은 **관찰 창(터미널 A)** 과 **조작 창(터미널 B)** 을 동시에 씁니다. 한쪽에서
`--watch`로 흘려보는 동안 다른 쪽에서 리소스를 적용해, 변화를 실시간으로 대조하는 구성입니다.

**터미널 A는 그대로 두고**, 호스트에서 **새 창**을 열어 진입 명령을 그대로 다시 실행하십시오.

```powershell
cd C:\path\to\cjons-infra-handson
.\lab\lab.cmd                # Windows
```
```bash
bash lab/lab.sh              # macOS · Linux
```

**이미 떠 있으면 기존 창을 죽이지 않고 셸을 하나 더 붙입니다.** 처음 여는 것과 같은 명령이라
따로 외울 것이 없습니다. 붙은 뒤 그 셸에서 아래 두 줄을 실행합니다.

```bash
source 00-common/lab_env.sh     # 셸마다 1회 — k 함수 활성화 + KUBECONFIG(실습 전용) export
cd m5-k8s-traffic               # 진행 중인 모듈로 이동
```

동등한 저수준 명령도 있습니다(위와 결과가 같습니다).

```bash
docker exec -it -w /work cjons-lab-shell bash
```

> `docker exec` 에는 **`--` 를 넣지 마십시오.** `kubectl exec pod -- cmd` 습관 때문에
> `docker exec -it cjons-lab-shell -- bash` 로 치기 쉬운데,
> `exec: "--": executable file not found in $PATH` 로 실패합니다.

### 0-5. 새 셸에서 자주 만나는 세 가지

| 증상 | 원인 · 조치 |
|---|---|
| `bash: k: command not found` 또는 `[HINT] 이 셸에서는 아직 k 가…` | `k` 는 함수라 **셸마다** 활성화해야 합니다 → `source 00-common/lab_env.sh` |
| `The connection to the server localhost:8080 was refused` (맨 `kubectl`) 또는 `no configuration has been provided` (`k8sgpt`) | 같은 원인입니다 — 그 셸에서 `source 00-common/lab_env.sh` 를 하지 않은 것. **하고 나면 `kubectl`·`k8sgpt` 도 그대로 동작합니다** |
| `error: the path "deployment.yaml" does not exist` | 새 셸은 `/work`에서 시작합니다 → `cd <모듈 폴더>` |
| `bash: $'\E[200~k': command not found` / 줄 끝에 `~` / 프롬프트에 글자가 겹쳐 보임(`…-hpak -n`, `loadgenen`, `--timeout=60s0s`) | 터미널의 **붙여넣기 표식**이 섞이거나 프롬프트가 겹쳐 그려진 것입니다. **셸이 뜨는 도중**이나 **`--watch`를 Ctrl-C 한 «직후»** 붙여넣으면 발생합니다. Enter를 한 번 쳐서 프롬프트가 자리를 잡은 뒤 다시 붙여넣으십시오. 겹쳐 «보이기만» 하고 명령은 정상 실행된 경우도 많으니 출력으로 확인하십시오 |

> **컨테이너를 완전히 새로 띄우고 싶다면** 열려 있는 셸을 모두 `exit` 하십시오(`--rm`이라 자동
> 삭제됩니다). 그래도 남아 있으면 호스트에서 `docker rm -f cjons-lab-shell`.
> **kind 클러스터는 별도 컨테이너라 실습 셸을 껐다 켜도 그대로 살아 있습니다.**

> **이미지를 다시 빌드했다면 반드시 컨테이너를 새로 띄우십시오.** `build` 는 이미지를 갱신할 뿐,
> **이미 떠 있는 컨테이너는 옛 이미지로 계속 돕니다.** 실행기가 이 상태를 감지하면
> `[WARN] 이 컨테이너는 «이전 이미지»로 떠 있습니다` 를 출력합니다. 그 경고가 보이면
> 모든 셸에서 `exit` → (남아 있으면) `docker rm -f cjons-lab-shell` → 다시 진입하십시오.

---

## 1. 왜 컨테이너인가 — 구조

```
 수강생 PC (Windows / macOS / Linux)
 └── Docker
     ├── 실습 컨테이너  cjons-lab:1.0      ← 여기서 모든 명령을 실행
     │     kubectl · kind · k8sgpt · python3 · pytest
     │     /var/run/docker.sock 을 공유받아 호스트 Docker를 조작
     │     /work 에 이 저장소가 마운트됨 (결과 파일은 PC에 그대로 남음)
     │
     └── kind 클러스터 (호스트 Docker 위의 형제 컨테이너들)
           cjons-lab-control-plane · cjons-lab-worker [· cjons-lab-worker2]
           ※ 노드 수는 프로필에 따라 std 3개 / low 2개 (§2 참조)
```

- **Docker-in-Docker가 아닙니다.** 실습 컨테이너는 호스트 Docker를 *조작*할 뿐이라 `--privileged`가 필요 없고, 메모리를 이중으로 쓰지 않습니다(4C/8GB PC 대응).
- 실습 컨테이너는 kind가 쓰는 `kind` 네트워크에 붙습니다. 그래서 `https://cjons-lab-control-plane:6443` 이름으로 API에 닿습니다.
- `.lab/` 결과 파일과 실습 중 수정한 코드는 **호스트에 그대로 남습니다**(bind mount).

### 왜 이 방식이 "동일 결과"를 보장하는가

| 기존 문제 | 컨테이너 방식에서 사라진 이유 |
|---|---|
| Windows에서 `.sh` 실행 불가 / CRLF 오염 | 모든 스크립트가 리눅스 컨테이너 안에서 실행됨 |
| WSL2 설치·`.wslconfig` 튜닝 필요 | Docker Desktop만 있으면 됨 |
| `kubectl`·`kind`·`k8sgpt` 버전이 PC마다 다름 | 이미지에 버전이 고정되어 있음 |
| macOS에 `sar`·`stress-ng`가 없음 | 실습 컨테이너가 Ubuntu 24.04 |
| 한글 파일명 NFD/NFC 불일치 | 컨테이너 파일시스템이 NFC로 일관 |

---

## 2. 실행 환경 요구사항

| 항목 | 최소 | 권장 |
|---|---|---|
| Docker | Docker Desktop 4.x 또는 Docker Engine 24+ | 최신 |
| CPU | 4 vCPU | 6 vCPU 이상 |
| 메모리(Docker 할당) | 4.5 GiB | 7 GiB 이상 |
| 디스크 여유 | 12 GB | 20 GB |

> Windows는 Docker Desktop 설치 시 **WSL2 백엔드**를 선택하십시오(설치 마법사 기본값). 별도 Ubuntu 배포판을 만들거나 `.wslconfig`를 손댈 필요는 없습니다. 메모리가 부족하면 Docker Desktop → Settings → Resources에서 조정합니다.

### 실습 프로필 — 내 PC 사양에 맞춰 자동 선택

| 프로필 | kind 노드 | 자동 선택 조건 |
|---|---|---|
| `std` | 3개 (control-plane 1 + worker 2) | 6 vCPU 이상 **그리고** 7GiB 이상 |
| `low` | 2개 (control-plane 1 + worker 1) | 그 미만 (예: 4 Core/8GB PC) |

`low`에서도 M1~M8 전 모듈이 성립합니다. 프로필은 자원을 보고 자동 판별하므로 보통 손댈 필요가 없고,
굳이 강제 지정하려면 다음과 같이 합니다.

```bash
CJONS_PROFILE=low bash lab/lab.sh        # macOS · Linux · WSL2
```

```powershell
$env:CJONS_PROFILE = "low"               # Windows — 변수를 먼저 설정한 뒤 실행
.\lab\lab.cmd
```

> PowerShell에는 `VAR=값 명령` 형태의 한 줄 문법이 없습니다. 위처럼 `$env:` 로 먼저 설정하십시오.
> 되돌리려면 `Remove-Item Env:\CJONS_PROFILE` 또는 창을 새로 엽니다.

---

## 3. 부록 — 호스트에서 직접 실행하려면 (예외 경로)

**표준 실습 경로는 §0의 컨테이너 방식입니다.** 컨테이너 없이 macOS·Linux·WSL2에서 직접 실행하는 경로도 부록으로 남겨 두지만, 도구를 직접 설치해야 하고 OS별 차이가 남으므로 **강의 중에는 사용하지 않습니다.** 사내 정책상 `docker.sock` 마운트가 불가한 경우 등 예외 상황에서만 강사 안내에 따라 사용하십시오.

<details>
<summary>호스트 직접 실행 절차 펼치기</summary>

필요 도구: Docker, `kubectl v1.35.5`, `kind v0.32.0`, `k8sgpt v0.4.36`, Python 3.9+
(컨테이너 방식에서는 이 도구들이 `cjons-lab:1.0` 이미지에 이미 내장돼 있어 **따로 설치하지 않습니다.**)

```bash
bash 00-common/check_env.sh host
bash 00-common/prefetch_assets.sh
bash 00-common/setup_cluster.sh
source 00-common/lab_env.sh
kubectl get nodes
```

- Windows에서는 **모든 명령을 WSL2 Ubuntu의 bash에서** 실행합니다. 이 경우에만 WSL2 배포판(Ubuntu 24.04) 구성이 필요합니다.
- WSL2에서는 저장소를 `/mnt/c/...`가 아니라 리눅스 홈(`~/cjons-infra-handson`)에 두어야 합니다. `/mnt/c` 경로는 I/O가 느리고 파일 권한이 달라 실습이 재현되지 않습니다.
- 저사양(4C·8GB) WSL2에서는 `~/.wslconfig`에 `memory=5GB`, `processors=4`를 두고 `CJONS_PROFILE=low`(kind 2노드)로 진행합니다.
- 도구 설치·검증 절차의 세부는 강사가 별도 안내합니다. 이 저장소만으로 진행할 때는 위 항목들과 `00-common/check_env.sh host`의 실패 항목을 기준으로 삼으십시오.

</details>

---

## 내 환경이 제대로 되었는지 한 번에 확인 (권장)

강의 전날, 아래 한 줄로 **M1~M8 전 실습이 내 PC에서 재현되는지** 자동 확인할 수 있습니다.

```bash
bash 00-common/verify_all.sh
```

- 소요: `std` 프로필 약 12~15분, `low` 프로필 약 18~25분
- 결과: 화면 요약 + `.lab/verify_report_<OS>_<프로필>.md` 리포트 파일
- `SUMMARY ... FAIL=0` 이면 준비 완료입니다.

```bash
bash 00-common/verify_all.sh --only M5 --only M8   # 특정 모듈만
bash 00-common/verify_all.sh --keep                # 리소스를 남겨 직접 관찰
bash 00-common/verify_all.sh --teardown            # 끝나고 클러스터까지 삭제
```

> 이 러너는 “코드가 이 환경에서 동작하는가”만 판정합니다. 학습은 각 모듈 README의 절차를 직접 밟아야 합니다.

## 화면이 달라 보일 때

**컨테이너 모드에서는 OS별 차이가 없습니다.** 아래 두 가지만 환경에 따라 달라지며, 모두 정상입니다.

| 항목 | 무엇이 다른가 |
|---|---|
| kind 노드 수 | Docker에 할당된 자원에 따라 3(std) 또는 2(low). 관찰 대상은 동일합니다. |
| M5 `conntrack -L` | 호스트 커널 구성에 따라 미조회될 수 있음 → **Plan B**(EndpointSlice 판독)로 자동 대체 |

호스트에서 직접 실행하는 경우(§3)에만 아래 차이가 남습니다.

| 항목 | macOS | Linux / WSL2 |
|---|---|---|
| `m1-os-review/check_self.sh` 를 호스트에서 직접 실행 | 안내 메시지 후 종료 | 그대로 정상 완주 |
| `systemctl`, `journalctl` | 없음 | 사용 가능 |
| M2 `dmesg`의 OOM 원문 | 제한적 | 호스트 커널 로그에서 확인 가능 |

`k`는 `.lab/cjons-lab.kubeconfig`와 `kind-cjons-lab` context만 사용합니다. `kubectl config set-context --current ...`를 실행하지 않으므로 개인·회사 클러스터의 현재 context를 바꾸지 않습니다.

> 오프라인 범위: 2단계를 같은 노트북에서 완료한 뒤에는 이미지 pull과 metrics-server 다운로드 없이 강의 실습을 진행할 수 있습니다. 새 노트북으로 캐시가 자동 복사되는 의미의 완전 오프라인 패키지는 아닙니다. M8의 AI 증거 판독은 동봉된 오프라인 증거로 진행할 수 있습니다.

## 모듈

| 폴더 | 모듈 | Day | 시수 |
|---|---|---|---|
| `m1-os-review/` | OS 운영 핵심 리뷰 | Day 1 | 30분 |
| `m2-linux-performance/` | Linux 성능·장애 분석 | Day 1 | 120분 |
| `m3-capacity-sizing/` | 용량산정 | Day 1 | 90분 |
| `m4-ha-design/` | 고가용성 설계 | Day 1 | 60분 |
| `m5-k8s-traffic/` | K8s 트래픽 경로 | Day 2 | 120분 |
| `m6-k8s-resources-hpa/` | K8s 리소스·HPA | Day 2 | 120분 |
| `m7-k8s-troubleshooting/` | K8s 장애 트러블슈팅 | Day 2 | 90분 |
| `m8-ai-ops/` | AI 인프라·운영 자동화 | Day 2 | 150분 |

## 성공 기준과 정리

실습의 목표는 명령 완주가 아니라 “무엇을 보고 어떻게 판단했는지”를 말하는 것입니다. 3분 이상 막히면 짝→강사 순으로 요청하세요.

아래 둘은 **택일**입니다. 한 블록에 같이 두지 않은 이유는 **둘 다 붙여넣으면 클러스터가 지워지기
때문**입니다. 원하는 쪽 «하나만» 실행하십시오.

**(A) 실습 리소스만 정리 — 클러스터는 남깁니다.** 모듈 사이에 쓰는 평상시 정리입니다.

```bash
bash 00-common/cleanup.sh
```

**(B) 클러스터까지 삭제 — 강의가 끝났을 때만.**

```bash
bash 00-common/cleanup.sh --delete-cluster
```

> **(B)를 실행하면 kind 노드가 사라집니다.** 다시 실습하려면 `bash 00-common/setup_cluster.sh` 로
> 재생성해야 하고 **3~5분**이 걸립니다. 모듈 중간에는 (A)만 쓰십시오.

## 예시답안에 대하여

이 저장소에는 **수강생이 실행할 코드·빈 템플릿·샘플 데이터만** 있습니다.
예시답안과 복구 런북은 강의 중에 배포됩니다.

