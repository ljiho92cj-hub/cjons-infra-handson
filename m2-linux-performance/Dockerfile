# cjons-m2-lab — M2 Linux 성능·장애 실습용 컨테이너 이미지
# 빌드: docker build -t cjons-m2-lab:1.0 .
FROM ubuntu:24.04

# 한글 출력이 깨지지 않도록 UTF-8 로케일을 고정합니다.
# 이 이미지는 LANG 이 비어 있어(POSIX) 슬라이드의 한글 주석을 붙여넣으면
# 로케일이 POSIX 이면 한글 주석·출력이 `\354\240\225\353\263\270` 처럼 8진 이스케이프로 표시된다.
# 실습 셸 이미지(cjons-lab)에는 이미 C.UTF-8 이 있었는데 이 이미지만 빠져 있었다.
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    stress-ng \
    sysstat \
    strace \
    lsof \
    psmisc \
    procps \
    python3-minimal \
    iproute2 \
    util-linux \
    coreutils \
    curl \
    jq \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /lab
CMD ["/bin/bash"]
