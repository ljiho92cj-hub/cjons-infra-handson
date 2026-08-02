# CJONS 실습 컨테이너 실행기 (Windows PowerShell)
#
#   .\lab\lab.ps1              → 실습 셸 진입
#   .\lab\lab.ps1 build        → 이미지 빌드(최초 1회)
#   .\lab\lab.ps1 verify       → 전 모듈 자동검증 1회 실행
#
# Windows 수강생은 WSL2 배포판을 따로 구성할 필요가 없습니다.
# Docker Desktop(WSL2 백엔드)만 설치되어 있으면 이 스크립트 하나로 리눅스 실습 환경이 뜹니다.
# 모든 .sh 스크립트는 컨테이너 안(리눅스)에서 실행되므로 CRLF·경로·권한 문제가 발생하지 않습니다.
#
# 이 파일은 반드시 UTF-8 BOM + CRLF 로 저장하십시오.
#   BOM이 없으면 Windows PowerShell 5.1이 이 파일을 ANSI(한국어 Windows = CP949)로 읽어
#   아래 한글 메시지가 전부 깨져서 출력됩니다.

param(
    [Parameter(Position = 0)]
    [string]$Command = "shell",

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = "Stop"

$Image         = if ($env:CJONS_LAB_IMAGE) { $env:CJONS_LAB_IMAGE } else { "cjons-lab:1.0" }
$Network       = "kind"
$ContainerName = "cjons-lab-shell"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = (Resolve-Path (Join-Path $ScriptDir "..")).Path

function Die($msg) { Write-Host "[ERROR] $msg" -ForegroundColor Red; exit 1 }
function Info($msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Warn($msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }

# ─────────────────────────────────────────────────────────────────────────────
# docker 존재 확인 규칙 — 이 방식을 되돌리지 마십시오.
#
# Windows PowerShell은 네이티브 명령(docker)의 stderr를 「리다이렉션할 때만」
# NativeCommandError ErrorRecord로 감쌉니다. 여기에 $ErrorActionPreference="Stop"이
# 겹치면 그 ErrorRecord가 「종료성 오류」가 되어 스크립트가 그 자리에서 중단됩니다.
# 게다가 예외는 파이프라인 프로세서가 던지므로 `*> $null` 리다이렉션 「밖」에서
# 콘솔로 보고됩니다. 즉 $null로 버렸는데도 화면에 뜨고, 스크립트는 죽습니다.
#
#   실제 증상 (Windows 11 + PowerShell 5.1)
#     docker : Error response from daemon: network kind not found
#     위치 C:\...\lab\lab.ps1:59 문자:5
#     +     docker network inspect $Network *> $null
#   「없으면 만든다」로 진행해야 할 자리에서 스크립트가 종료되어, 재실행해도 같은 자리에 멈춤.
#
# 그래서 존재 확인은 stderr를 내지 않는 조회 명령(`docker images -q`,
# `docker network ls --format`, `docker ps -a --format`)으로만 합니다.
# 부득이 stderr가 나는 명령을 조용히 돌려야 하면 Invoke-DockerQuiet로 감싸십시오.
# `docker ... *> $null` 패턴은 이 파일에서 금지합니다.
# ─────────────────────────────────────────────────────────────────────────────
function Invoke-DockerQuiet([string[]]$DockerArgs) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & docker @DockerArgs 2>&1 | Out-Null
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Die "docker CLI가 없습니다. Docker Desktop을 설치하십시오. (https://docs.docker.com/desktop/install/windows-install/)"
}
if ((Invoke-DockerQuiet @("info")) -ne 0) {
    Die "Docker 데몬이 응답하지 않습니다. Docker Desktop을 실행한 뒤 다시 시도하십시오."
}

# Docker Desktop for Windows는 named pipe를 쓰지만, 컨테이너에 넘길 때는
# //var/run/docker.sock 경로를 그대로 사용한다(Desktop이 리눅스 VM 내부 소켓으로 중계).
$SockMount = "//var/run/docker.sock:/var/run/docker.sock"

function Build-Image {
    Info "이미지 빌드: $Image"
    docker build -t $Image $ScriptDir
    if ($LASTEXITCODE -ne 0) { Die "이미지 빌드 실패" }
    Info "빌드 완료."
    # 이미 떠 있는 컨테이너는 «빌드 전» 이미지로 계속 돕니다. 새 내용은 반영되지 않습니다.
    $live = @(& docker ps --format '{{.Names}}')
    if ($live -contains $ContainerName) {
        Warn "실습 컨테이너가 실행 중입니다 — 방금 빌드한 내용은 그 컨테이너에 반영되지 않습니다."
        Warn "반영하려면: 모든 실습 셸에서 exit → (남아 있으면) docker rm -f $ContainerName → 다시 진입"
    }
}

function Ensure-Image {
    # `docker images -q <태그>` 는 이미지가 없어도 stderr 없이 exit 0 + 빈 출력을 준다.
    $existing = & docker images -q $Image
    if (-not $existing) {
        Info "이미지가 없어 자동 빌드합니다: $Image"
        Build-Image
        return
    }
    # ── 태그가 같아도 «내용»이 구본일 수 있다 ─────────────────────────────────
    # Dockerfile 에 도구를 추가해도 「태그가 있으면 건너뛴다」로 두면 옛 이미지가
    # 계속 재사용된다. 태그는 내용을 보증하지 않으므로 «도구의 실재»로 판정한다.
    & docker run --rm --entrypoint sh $Image `
        -c 'command -v stress-ng >/dev/null 2>&1 && command -v etcdctl >/dev/null 2>&1' 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Warn "$Image 에 실습 도구(stress-ng·etcdctl)가 없습니다 — 자동 재빌드합니다."
        Build-Image
    }
}

function Ensure-Network {
    # 전체 네트워크 이름을 받아 정확히 대조한다. 매칭이 없어도 stderr가 나지 않는다.
    $names = @(& docker network ls --format '{{.Name}}')
    if ($names -notcontains $Network) {
        Info "docker 네트워크 생성: $Network"
        & docker network create $Network | Out-Null
        if ($LASTEXITCODE -ne 0) { Die "docker 네트워크 생성 실패: $Network" }
    }
}

function Run-Container([string[]]$InnerArgs) {
    Ensure-Image
    Ensure-Network

    # ── 이미 떠 있으면 «죽이지 말고» 셸을 하나 더 붙인다 ───────────────────
    # M5 Lab 5-1(관찰 창 A + 조작 창 B)·M6은 두 셸을 «동시에» 요구한다.
    # 예전처럼 무조건 `docker rm -f` 하면, 두 번째 창을 열려고 이 스크립트를 다시 돌린
    # 수강생이 첫 번째 창(관찰 중이던 --watch)을 통째로 날려 실습이 성립하지 않는다.
    $live = @(& docker ps --format '{{.Names}}')
    if ($live -contains $ContainerName) {
        Info "실습 컨테이너가 이미 실행 중입니다 — 기존 창을 그대로 두고 새 셸을 붙입니다."
        Info "이 셸에서도 'source 00-common/lab_env.sh' 를 한 번 실행해야 kubectl 이 실습 클러스터를 가리킵니다."

        # 「실행 중이면 붙인다」의 사각지대 —
        # 이미지를 새로 빌드해도 이미 떠 있는 컨테이너는 «옛 이미지»로 계속 돈다.
        # NOTE: 여기에 `2>$null` 을 붙이지 마십시오 — 위 주석의 금지 패턴 그대로입니다.
        # 두 대상 모두 방금 존재를 확인했으므로 리다이렉션 없이도 stderr가 나지 않습니다.
        $runImg = (& docker inspect -f '{{.Image}}' $ContainerName)
        $tagImg = (& docker inspect -f '{{.Id}}' $Image)
        if ($runImg -and $tagImg -and ($runImg -ne $tagImg)) {
            Warn "이 컨테이너는 «이전 이미지»로 떠 있습니다 — 새로 빌드한 내용이 반영되지 않은 상태입니다."
            Warn "반영하려면: 모든 실습 셸에서 exit → (남아 있으면) docker rm -f $ContainerName → 다시 진입"
        }
        $execArgs = @("exec", "-it", "-w", "/work", $ContainerName) + $InnerArgs
        & docker @execArgs
        exit $LASTEXITCODE
    }

    # 죽어 있는 잔여 컨테이너만 정리한다. 「존재할 때만」 지운다 —
    # 없는 컨테이너에 rm -f 를 걸면 docker가 stderr를 내고, 위 주석의 함정에 다시 걸린다.
    $stale = @(& docker ps -a --format '{{.Names}}')
    if ($stale -contains $ContainerName) {
        & docker rm -f $ContainerName | Out-Null
    }

    $dockerArgs = @(
        "run", "-it", "--rm",
        "--name", $ContainerName,
        "--hostname", "cjons-lab-shell",
        "--network", $Network,
        # dmesg(SYSLOG)·tcpdump/ss(NET_ADMIN,NET_RAW) 허용. --privileged 는 쓰지 않는다.
        "--cap-add", "SYSLOG",
        "--cap-add", "NET_ADMIN",
        "--cap-add", "NET_RAW",
        "-v", $SockMount,
        "-v", "${RepoRoot}:/work",
        "-w", "/work",
        "-e", "CJONS_IN_CONTAINER=1",
        "-e", "CJONS_HOST_REPO=$RepoRoot",
        # 컨테이너 안 lab_env.sh 가 「윈도우 경로 → 데몬 경로」 프로브에 이 이미지를 쓴다.
        "-e", "CJONS_LAB_IMAGE=$Image"
    )
    if ($env:CJONS_PROFILE) { $dockerArgs += @("-e", "CJONS_PROFILE=$($env:CJONS_PROFILE)") }
    $dockerArgs += $Image
    $dockerArgs += $InnerArgs

    & docker @dockerArgs
    exit $LASTEXITCODE
}

switch ($Command) {
    "build"  { Build-Image }
    "verify" {
        Info "컨테이너 안에서 전 모듈 자동검증을 실행합니다."
        Run-Container @("bash", "-lc", "bash 00-common/check_env.sh host && bash 00-common/prefetch_assets.sh && bash 00-common/setup_cluster.sh && bash 00-common/verify_all.sh")
    }
    "shell"  { Run-Container @("bash") }
    default  {
        if ($Rest) { Run-Container (@($Command) + $Rest) } else { Run-Container @($Command) }
    }
}
