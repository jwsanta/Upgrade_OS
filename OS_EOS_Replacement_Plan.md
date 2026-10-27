# OS EOS 대응 OS 교체 표준 방안 (Rocky Linux / Windows Server)

| 항목 | 내용 |
|---|---|
| 문서 버전 | v0.3 (초안) |
| 작성일 | 2026-10-27 |
| 사실 정보 확인일 | 2026-10-27 (EOS 일정, OS 버전별 변경 사항, ESU, KB5020276 등) |
| 대상 환경 | Nutanix AHV 기반 VM / Rocky Linux, Windows Server (실제 대상 서버·버전은 "1. 대상 조사" 단계에서 확정) |
| 관련 자료 | `Get-PreUpgradeInventory.ps1` (Windows 사전 인벤토리 추출, 18개 항목) – 본 문서는 스크립트의 **출력 형식(파일명·열 이름)만 참조**하며, 수집 결과 값은 사용하지 않음 |

## 목차

1. [배경 및 목적](#1-배경-및-목적)
2. [핵심 원칙](#2-핵심-원칙)
3. [원안 검토 및 보완 사항](#3-원안-검토-및-보완-사항)
4. [공통 전체 흐름](#4-공통-전체-흐름)
5. [Linux (Rocky Linux) 교체 절차](#5-linux-rocky-linux-교체-절차)
6. [Windows Server 교체 절차](#6-windows-server-교체-절차)
7. [추가 제안 (더 좋은 방안)](#7-추가-제안-더-좋은-방안)
8. [리스크 및 대응](#8-리스크-및-대응)
9. [전환 당일 Runbook](#9-전환-당일-runbook)
10. [롤백 기준 및 절차](#10-롤백-기준-및-절차)
11. [부록](#11-부록)

---

## 1. 배경 및 목적

- OS EOS(End of Support)는 주기적으로 도래하며, 서버 수가 많을수록 **매년 어떤 서버든 교체 대상이 발생**함
- 목표: 아래 3가지를 만족하는 **반복 가능한 표준 절차** 수립
  1. **설치 작업 최소화** – 소프트웨어 재설치 없이 또는 스크립트만으로 복구
  2. **전환 시간 최소화** – 사전 준비를 최대한 끝내고 전환 당일은 "붙이고 켜기"만 수행
  3. **즉시 롤백 가능** – 원본 서버는 무변경 상태로 보존
- 본 문서의 "OS 업그레이드"는 in-place 업그레이드가 아니라 **신규 OS VM 구축 후 서비스 전환(Rebuild & Swap)** 을 의미함

### 1.1 EOS 일정 (2026-10 기준)

| OS | 일반 지원 종료 | 보안 지원 종료(EOS) | 비고 |
|---|---|---|---|
| Rocky Linux 8 | 2024-05-31 | 2029-05-31 | |
| Rocky Linux 9 | 2027-05-31 | 2032-05-31 | |
| Rocky Linux 10 | 2030-05-31 | 2035-05-31 | **x86-64-v3 CPU 필요** |
| Windows Server 2016 | 2022-01-11 | **2027-01-12** | 약 2.5개월 남음 (보유 서버가 있으면 최우선 대상) |
| Windows Server 2019 | 2024-01-09 | 2029-01-09 | |
| Windows Server 2022 | 2026-10-13 | 2031-10-14 | 일반 지원 종료됨 (보안 업데이트는 지속) |
| Windows Server 2025 | 2029-11-13 | 2034-11-14 | |

> - 2026-10-27 기준 확인 (endoflife.date, 벤더 공지). 일정이 바뀔 수 있으므로 계획 수립 시 벤더 Lifecycle 페이지 재확인
> - 최신 minor 버전: Rocky 9.8, Rocky 10.2 (2026-05 출시). **Rocky는 최신 minor만 지원**하므로 템플릿은 항상 최신 minor로 유지
> - **Windows Server 2016은 유료 ESU(Extended Security Updates)로 보안 업데이트 연장 가능** – Azure Arc 기반으로 온프레미스 서버도 대상이며, 최대 3년(2030-01-12까지)
>   - EOS 전 교체가 어려운 서버의 **한시적 방안**으로만 활용 (비용이 해마다 늘어남)
>   - 가격, 라이선스 자격, 온프레미스(Nutanix) 적용 조건은 Microsoft 또는 리셀러에 확인

**목표 OS 선정 원칙**

- 벤더 지원(Support Matrix)이 허용하는 범위에서 **가능한 최신 major 버전**으로 교체 → 교체 주기 최대화
  - 예: 2016 → 2019 전환 시 2년 남짓 후 다시 교체 필요 / 2016 → 2025 전환 시 약 8년 사용 가능
- 최신 버전을 벤더가 지원하지 않으면 **S/W 버전업을 같이 할지, OS를 한 단계 낮출지**를 서버별로 결정

---

## 2. 핵심 원칙

| # | 원칙 | 설명 |
|---|---|---|
| 1 | **OS와 S/W·데이터 분리** | OS 디스크는 "언제든 버릴 수 있는 것", App/Data 디스크는 "계속 이어 쓰는 것" |
| 2 | **In-place 대신 신규 구축 후 전환** | 원본 서버를 변경하지 않음 → 롤백 = 원본 재기동 |
| 3 | **디스크는 '이동'이 아니라 '클론'** | Nutanix 클론은 메타데이터 복제(Redirect-on-Write)라 빠름. 원본 디스크를 그대로 보존 (상세: 부록 E) |
| 4 | **OS에 남는 설정은 사람이 아니라 코드로 재현** | 계정(UID/GID)·환경변수·서비스·cron·커널 파라미터 등을 manifest + 스크립트로 관리 |
| 5 | **리허설은 격리망에서** | 클론 서버가 운영 DB·외부 시스템에 붙어 배치·발송이 실행되는 사고 방지 |
| 6 | **템플릿은 서비스 유형별 + 버전 관리** | 예: `rocky10-was-2026.10`, `ws2025-std-iis-2026.10` |

---

## 3. 원안 검토 및 보완 사항

| 원안 내용 | 평가 | 보완 필요 사항 |
|---|---|---|
| (Linux) rpm으로 설치하지 않고 tarball 배치 | 적합. OS 독립성 확보의 핵심 | JDK, Python 등 **런타임도 LV에 포함**. 단, 보안/모니터링/백업 에이전트처럼 rpm이 필수인 S/W는 템플릿에 포함 |
| (Linux) 독립 VG/LV, 특정 파일시스템 | 적합 | VG는 반드시 **OS 디스크와 다른 vDisk**에 구성. VG 이름 표준화(`vg_app` 등). Rocky 9 이상은 **LVM devices file 등록 절차** 필요 |
| (Linux) 마운트 + 계정 + 환경변수 생성으로 기동 | 적합 | **UID/GID 고정 대장** 필요. 환경변수 외에 systemd unit, cron, sysctl, limits, SELinux, 방화벽, sudoers 등 **OS 디스크에 남는 설정**의 원본을 LV에 두고 스크립트로 재적용 |
| (Linux) 일부 라이브러리 문제 발생 가능 | 맞음. 단, major 버전 간 변화가 큼 | 8→9: OpenSSL 3.0, SHA-1 정책 / 9→10: x86-64-v3 CPU. **전환 전 ldd 전수 점검**, compat 패키지를 템플릿에 포함 |
| (Linux) Nutanix 템플릿 + LV 부착 | 적합 | 디스크 "이동"이 아닌 **"클론" 부착** → 원본 보존, 즉시 롤백. 리허설은 격리망 |
| (Linux) User·환경변수 동일 전제 | **가장 큰 리스크 지점** | 사람이 맞추지 않고 **manifest + 스크립트(→ Ansible)** 로 자동화 |
| (Linux) 기존 서버 | 언급 없음 | 현재 서버 대부분이 분리 구조가 아님 → **1회차 전환(현행 → 표준 구조)** 절차가 별도로 필요 (5.2 참고) |
| (Windows) 템플릿 생성 또는 설치 | 적합 | Sysprep, VirtIO/NGT, .NET 3.5 등 기능 설치 소스, CD-ROM 드라이브 문자 변경, 템플릿 버전 관리 |
| (Windows) 설치 목록 → MSI silent 스크립트 | 방향 적합 | **MSI에 한정하지 않음** (EXE도 대부분 silent 가능). 설치본 저장소, 버전 고정, 해시 검증, 종료코드 + 설치 결과 검증, 라이선스 재발급 절차 |
| (Windows) 설치 후 스크립트로 설치 | 적합하나 부족 | 설치만으로는 서비스 재개 불가 → **설정 이관 단계**(서비스 계정, 예약 작업, ODBC, 인증서, IIS, 레지스트리 등) 추가. 데이터는 **D: 분리 디스크 클론**으로 이관 |
| (공통) | 누락 | 전환·롤백 절차, 리허설, IP·hostname·도메인 처리, 검증 기준, 원본 보존 기간, 사후 작업(모니터링·백업·CMDB) |

---

## 4. 공통 전체 흐름

| 단계 | 내용 | 산출물 | 시점 |
|---|---|---|---|
| 0. 표준화 | 디스크 구조, UID/GID 대장, 템플릿, 스크립트, 설치본 저장소 | 표준 문서, 템플릿, 스크립트 | 최초 1회 (이후 유지보수) |
| 1. 대상 조사 | 인벤토리 수집, 벤더 지원 확인, 서버 유형 분류 | 인벤토리, S/W 카탈로그 | D-30 |
| 2. 호환성 검증 | 테스트 VM에서 기동 및 라이브러리/설치 검증 | 검증 결과, 조치 목록 | D-21 |
| 3. 신규 VM 준비 | 템플릿 배포, 공통 설정, (Windows) S/W 설치 | 신규 VM | D-14 |
| 4. 리허설 | 클론 디스크 + 격리망에서 전체 절차 수행, 소요 시간 측정 | 리허설 결과, Runbook 확정 | D-7 |
| 5. 전환 | 원본 중지 → 디스크 클론 → 부착 → 기동 → 검증 | 전환 결과 | D-Day |
| 6. 안정화 | 원본 VM 보존 (전원 OFF), 모니터링 | | D+1 ~ D+14 |
| 7. 종료 | 원본 삭제, CMDB·문서 갱신, 회고 | 완료 보고 | D+14 이후 |

```
[원본 VM : 구 OS]                              [신규 VM : 신규 OS 템플릿]
 disk0  OS            ── 보존 (전원 OFF, 롤백용)   disk0  OS (템플릿)
 disk1  App (/app, D:) ─────── clone ────────▶     disk1' App  → /app 또는 D:
 disk2  Data (/data)   ─────── clone ────────▶     disk2' Data → /data
```

---

## 5. Linux (Rocky Linux) 교체 절차

### 5.1 표준 구조 (최초 1회 정비)

#### 5.1.1 디스크 / LVM 표준

| vDisk | LVM VG | LV | 마운트 | 용도 |
|---|---|---|---|---|
| disk0 | 템플릿 기본 (예: `rl`) | root, swap 등 | `/` | **OS 전용** (버리는 영역) |
| disk1 | `vg_app` | `lv_app` | `/app` | 바이너리, 라이브러리, 런타임, 설정, 환경변수, unit 원본 |
| disk2 | `vg_data` | `lv_data` | `/data` | 데이터 |
| disk3 (선택) | `vg_log` | `lv_log` | `/applog` | 로그 (용량·백업 정책이 다를 때) |

- **VG는 vDisk 단위로 분리** – OS 디스크와 같은 디스크에 VG가 섞이면 디스크 단위 클론/부착이 불가능
- VG 이름은 전사 표준으로 고정하고, **템플릿의 OS VG 이름과 절대 겹치지 않게** 함
- 파일시스템: XFS 권장, fstab에는 `nofail` 옵션 사용 (디스크 누락 시 부팅이 emergency mode로 빠지는 것 방지)

#### 5.1.2 `/app` 디렉터리 표준

```
/app
├── <product>/              # tarball 전개 (bin, lib, conf)
├── runtime/jdk-17/         # JDK, Python 등 런타임도 LV에 포함 → OS 버전 영향 제거
├── home/<account>/         # 서비스 계정 홈 (.bash_profile, .ssh 유지)
├── env/<svc>.env           # 환경변수 원본 (KEY=VALUE)
├── systemd/<svc>.service   # systemd unit 원본
├── cron/<account>.cron     # crontab 원본
├── os/                     # sysctl, limits, sudoers, profile.d 원본
└── manifest/
    ├── server.conf         # 서버 명세 (계정, UID/GID, 서비스, 포트, SELinux)
    ├── post-attach.sh      # 신규 OS에서 실행하는 재적용 스크립트 (부록 B)
    └── inventory/<날짜>/   # 원본 서버 인벤토리 (신규 서버에서 바로 비교 가능)
```

**핵심: OS 디스크에는 원본을 두지 않음. OS에는 `/app`에 있는 원본을 복사·등록만 함**

- 환경변수는 원본 파일 하나로 systemd와 로그인 셸 모두 사용

  ```bash
  # /etc/profile.d/app.sh (post-attach.sh가 생성)
  set -a; . /app/env/tomcat.env; set +a
  ```

  ```ini
  # /app/systemd/tomcat.service
  [Unit]
  Description=Tomcat
  After=network-online.target
  Wants=network-online.target
  RequiresMountsFor=/app /data      # /app 미마운트 시 서비스가 기동되지 않도록 보장

  [Service]
  Type=forking
  User=wasadm
  Group=wasgrp
  EnvironmentFile=/app/env/tomcat.env   # KEY=VALUE 형식만 사용 (셸 명령 치환 불가)
  ExecStart=/app/tomcat/bin/startup.sh
  ExecStop=/app/tomcat/bin/shutdown.sh
  LimitNOFILE=65536                     # systemd 서비스는 limits.conf가 적용되지 않음

  [Install]
  WantedBy=multi-user.target
  ```

- unit 파일은 `systemctl link` 대신 **`/etc/systemd/system`에 복사** (부팅 초기에 `/app`이 마운트되기 전 unit을 읽지 못하는 문제 방지)

#### 5.1.3 계정 표준 (UID/GID 대장)

- LV 위의 파일은 **계정 이름이 아니라 UID/GID 숫자**로 소유자가 기록됨
- 신규 OS에서 UID가 다르면 → 권한 오류. 더 위험한 경우 **다른 계정이 해당 파일의 소유자가 됨(보안 사고)**
- 대책
  - 서비스 계정 UID/GID를 **전사 대장으로 고정** (예: 서비스 계정 2000~2999 대역)
  - 기본 대역(1000번)은 템플릿 생성 시 자동 생성되는 계정과 겹치므로 사용 금지
  - 계정 생성은 항상 `useradd -u <UID> -g <GID>` 형태로 스크립트에서만 수행

#### 5.1.4 OS 템플릿 (서비스 유형별)

| 구분 | 포함 내용 |
|---|---|
| 공통 | 최신 패치, 보안 하드닝(사내 기준), NTP/DNS, 보안·모니터링·백업 에이전트, NGT(Nutanix Guest Tools), cloud-init, `policycoreutils-python-utils`(semanage) |
| 유형별 공통 라이브러리 | 예: WAS 유형 – `compat-openssl11`(Rocky 9 한정, Rocky 10에는 없음), `libxcrypt-compat`, `ncurses-compat-libs`, `libnsl`, fontconfig 등 (ldd 점검 결과와 목표 OS 저장소의 제공 여부로 확정) |
| 템플릿 봉인(seal) | `/etc/machine-id` 비우기, SSH 호스트 키 삭제, `cloud-init clean`, 로그·이력 정리 → **machine-id, SSH 호스트 키 중복 방지** |
| 버전 관리 | `rocky10-was-2026.10` 형식, 월 1회(또는 분기) 패치 반영 후 신규 버전 생성. 새 minor가 나오면 템플릿도 새 minor로 갱신 |

> Rocky 10은 OS 전체가 **x86-64-v3 명령어(AVX2, BMI2, FMA 등)** 를 사용하도록 빌드되어, 해당 명령어가 VM에 노출되지 않으면 설치·부팅 자체가 불가함 (`Fatal glibc error: CPU does not support x86-64-v3`)
> - 대상: Intel Haswell(Xeon E5 v3, 2014) 이후, AMD Zen(EPYC 7001, 2017) 이후. Xeon E5 v2(Ivy Bridge) 이하는 불가
> - 미지원 시 Rocky 10 VM은 부팅되지 않으므로, **같은 클러스터의 기존 VM에서 사전 확인** (운영·DR 클러스터 모두)
>   - Rocky 9: `/lib64/ld-linux-x86-64.so.2 --help | grep x86-64-v3` → `supported` 표시 확인
>   - Rocky 8: `/proc/cpuinfo`에 `avx avx2 bmi1 bmi2 fma f16c abm movbe xsave` 플래그가 모두 있는지 확인
> - 세대가 섞인 클러스터는 라이브 마이그레이션 호환을 위해 VM에 낮은 세대 기준 CPU 기능만 노출될 수 있으므로, 호스트 CPU가 아니라 **VM 안에서** 확인

### 5.2 단계별 절차

> **1회차 vs 2회차 이후**
> - **1회차 (현행 → 표준 구조)**: 기존 서버는 S/W가 OS 디스크(`/opt`, `/home` 등)에 섞여 있으므로, 신규 VM에 App/Data 디스크를 새로 만들고 `rsync`로 복사함. 이 회차에서 표준 구조로 정비함
> - **2회차 이후 (표준 구조 → 신규 OS)**: App/Data 디스크 **클론 부착**만으로 전환

**Step 1. 인벤토리 수집 (원본 서버)**

- 부록 A의 명령으로 계정, cron, 서비스, 포트, 마운트, OS 설정, rpm 목록, SELinux 사용자 정의 정책 등을 수집
- 결과는 `/app/manifest/inventory/<날짜>/`에 저장 → 디스크와 함께 신규 서버로 넘어가므로 비교가 쉬움

**Step 2. 호환성 검증 (테스트 VM)**

1. 벤더 Support Matrix에서 목표 OS 지원 여부 확인 (상용 S/W는 "기동된다"와 "지원된다"가 다름)
2. 신규 템플릿으로 테스트 VM 생성 → App 디스크 클론 부착 (격리망)
3. 라이브러리 의존성 전수 점검

   ```bash
   find /app -xdev -type f \( -perm -u+x -o -name '*.so*' \) -print0 |
     xargs -0 -I{} sh -c 'ldd "{}" 2>/dev/null | grep "not found" | sed "s|^|{}: |"' | sort -u
   dnf provides '*/libssl.so.1.1'   # 누락 라이브러리를 제공하는 패키지 확인
   ```

4. 조치 방법 결정: **템플릿에 compat 패키지 추가** vs **라이브러리를 LV에 동봉(LD_LIBRARY_PATH/RPATH)** vs **S/W 버전업**
5. 기동 테스트, 로그 확인, 암호 정책(SHA-1, TLS) 영향 확인

**Step 3. manifest / 스크립트 준비**

- `/app/manifest/server.conf`, `post-attach.sh` 작성 (부록 B)
- 원본 서버의 UID/GID가 표준 대장과 다르면 **이 단계에서 정리** (1회차에 한 번만 수행)

**Step 4. 신규 VM 생성**

- 서비스 유형별 템플릿에서 클론 → cloud-init으로 **임시 hostname/IP** 지정
- 에이전트 상태, 시간 동기, DNS 확인

**Step 5. 리허설 (격리망)**

- 원본 App/Data 디스크를 **클론하여** 신규 VM에 부착 (원본 서비스 무중단 상태에서 가능)
- **운영 연동 차단 필수**: 별도 VLAN 또는 방화벽으로 운영 DB·외부 API·메일/SMS 게이트웨이 접속 차단, 배치(cron) 비활성 상태로 시작
- Step 6의 절차를 그대로 수행하며 **소요 시간 측정**, 검증 항목 확정
- 리허설 후 리허설용 클론 디스크는 분리·삭제

**Step 6. 전환 (D-Day)**

```bash
# ── 원본 VM ──────────────────────────────
systemctl stop <서비스>          # 애플리케이션 정상 종료 (데이터 flush)
# Nutanix 스냅샷 생성 → VM 종료 → NIC 연결 해제, 자동 기동 해제

# ── Nutanix (CVM, 예시: AOS 버전별 명령 확인 필요, Prism UI로도 가능) ──
acli vm.get <원본VM> | grep vmdisk_uuid                  # App/Data 디스크 UUID 확인
acli vm.disk_create <신규VM> clone_from_vmdisk=<vmdisk_uuid> bus=scsi

# ── 신규 VM ──────────────────────────────
lsblk -f                                  # 새 디스크 확인
vgimportdevices vg_app vg_data            # Rocky 9 이상: LVM devices file 등록 (미등록 시 VG가 보이지 않음)
vgchange -ay vg_app vg_data
mkdir -p /app /data
cat >> /etc/fstab <<'EOF'
/dev/mapper/vg_app-lv_app    /app   xfs  defaults,nofail  0 0
/dev/mapper/vg_data-lv_data  /data  xfs  defaults,nofail  0 0
EOF
systemctl daemon-reload && mount -a && df -h /app /data

/app/manifest/post-attach.sh              # 계정, OS 설정, SELinux, 방화벽, cron, 서비스 재적용

# IP/hostname 전환 (원본 VM이 꺼진 것을 확인한 후)
hostnamectl set-hostname <운영 hostname>
nmcli con mod <연결명> ipv4.addresses <운영IP>/<prefix> ipv4.gateway <GW> ipv4.method manual
nmcli con up <연결명>
arping -U -c 3 -I <NIC> <운영IP>          # 스위치 ARP 캐시 갱신 (통신 지연 시)
```

- 검증: 프로세스·포트, 애플리케이션 로그, 헬스체크 URL, DB·외부 연동, 배치 1회 수동 실행, 모니터링 수신, 백업 1회
- 재부팅 테스트 1회 (fstab, 서비스 자동 기동 확인)

**Step 7. 안정화 / 종료**

- 원본 VM은 **전원 OFF + NIC 연결 해제** 상태로 보존 (예: 14일)
- 기간 경과 후 원본 VM과 스냅샷 삭제, CMDB·구성 문서 갱신

**1회차 전환 시 데이터 복사 (참고)**

```bash
# 신규 VM에 vg_app/vg_data를 새로 구성한 뒤, 원본 → 신규로 사전 동기화 (서비스 운영 중)
rsync -aHAXS --numeric-ids /opt/myapp/ newvm:/app/myapp/
# 전환 당일: 서비스 중지 후 증분 동기화 (변경분만 복사되어 빠름)
rsync -aHAXS --numeric-ids --delete /opt/myapp/ newvm:/app/myapp/
```

- 경로가 바뀌면(`/opt/myapp` → `/app/myapp`) 설정 파일 내 절대 경로 수정 필요 → 최초 1회만 발생하도록 이때 표준 경로로 정비
- 원본 UID가 표준과 다르면 복사 후 `chown -R` 으로 정리

### 5.3 Rocky major 버전별 호환성 점검 포인트

| 구분 | Rocky 8 → 9 | Rocky 9 → 10 |
|---|---|---|
| CPU | x86-64-v2 필요 | **x86-64-v3 필요** (구형 CPU 확인) |
| OpenSSL | 1.1.1 → **3.0** (`libssl.so.1.1` 없음, `compat-openssl11`로 임시 대응 가능) | 3.x, **`compat-openssl11` 제거됨** (RHEL 10 기준) → OpenSSL 1.1에 의존하는 S/W는 라이브러리 LV 동봉 또는 S/W 버전업 필요. Rocky 10에서 `dnf provides 'libssl.so.1.1*'`로 최종 확인 |
| 암호 정책 | DEFAULT 정책에서 **SHA-1 서명 비활성** → 구형 인증서·연동 실패 가능 | 추가 강화 여부 재확인 |
| Python | 3.6 → 3.9 (Python 2 없음) | 3.12 |
| 네트워크 설정 | ifcfg 비권장, NetworkManager keyfile 기본 | **ifcfg 미지원** → keyfile만 사용 |
| LVM | **devices file 기본 사용** → 외부 디스크 VG 등록 필요 | 동일 |
| 기타 | cgroup v2 기본, root SSH 비밀번호 로그인 기본 차단 | 커널 6.12, glibc 2.39 |

---

## 6. Windows Server 교체 절차

### 6.1 표준 구조

| 구분 | 표준 |
|---|---|
| 디스크 | C: OS + 프로그램(재설치 영역) / **D: 데이터·설정·로그 (별도 vDisk, 클론 대상)** |
| 드라이브 문자 | 템플릿에서 CD-ROM을 `Z:`로 변경 → 데이터 디스크가 항상 `D:`가 되도록 함 |
| 서비스 계정 | **도메인 계정 또는 gMSA** 사용 (로컬 계정은 서버마다 SID가 달라 D: 권한(ACL)이 깨짐) |
| 설치본 저장소 | `\\<파일서버>\SWRepo\<벤더>\<제품>\<버전>\` – 설치 파일, silent 명령, 해시, 라이선스, 설정 이관 방법을 함께 보관. **구버전 설치본도 영구 보관** |
| S/W 카탈로그 | 서버별 설치 목록 + 설치 형식 + silent 명령 + 신규 OS 지원 버전 + 라이선스 방식 (부록 D) |

> Windows는 레지스트리·서비스·COM 등록 때문에 Linux처럼 "디스크만 붙이면 실행"되는 구조가 어려움
> → **프로그램은 스크립트로 재설치, 데이터/설정은 D: 디스크 클론으로 이관**하는 혼합 방식이 현실적

### 6.2 단계별 절차

**Step 1. 인벤토리 수집 (원본 서버)**

- `Get-PreUpgradeInventory.ps1` 실행 → 01~18 항목 CSV 및 원본 설정 파일 추출

  ```powershell
  powershell.exe -ExecutionPolicy Bypass -File .\Get-PreUpgradeInventory.ps1 -OutputRoot D:\Inventory
  ```

- 결과를 D: 또는 공유 폴더에 보관 (신규 서버에서 바로 참조)

**Step 2. S/W 카탈로그 작성 및 벤더 확인**

- `02_Software.csv`의 `InstallerType` 열(MSI / EXE-InnoSetup / EXE-NSIS / EXE-InstallShield / EXE-WiXBurn 등)을 기준으로 silent 명령 확정
- 서버별로 확인할 항목
  - 신규 OS에서 지원되는 버전 (현재 버전이 미지원이면 **버전업 = 애플리케이션 변경**이므로 별도 검증 필요)
  - 라이선스 방식 (hostname / MAC / HW ID / 온라인 활성화 횟수 제한) 및 재발급 절차
  - 설정 이관 방법 (벤더 export 기능 유무)
  - silent 설치 불가 S/W → 예외 목록으로 분리 (7.1의 W2 유형)

**Step 3. 설치본 준비 및 silent 검증 (테스트 VM)**

- 설치본 저장소에 등록 + SHA256 해시 기록
- 테스트 VM에서 `install-all.ps1`(부록 C)로 **처음부터 끝까지 무인 설치가 되는지** 검증
- 종료 코드만 믿지 않고 **설치 결과(파일/서비스/레지스트리)로 재확인**

**Step 4. 템플릿 준비 (최초 1회 + 정기 갱신)**

| 항목 | 내용 |
|---|---|
| 기본 | 최신 누적 업데이트, Nutanix VirtIO 드라이버 + NGT, 보안 하드닝(사내 기준), 공통 에이전트 |
| 기능 설치 소스 | .NET Framework 3.5 등은 설치 미디어의 `sources\sxs`가 필요 → 템플릿에 미리 설치하거나 소스 경로 확보 |
| Sysprep | `sysprep /generalize /oobe /shutdown /unattend:<파일>` – **SID 중복 방지**. Sysprep 없이 VM을 복제하지 않음 |
| 무인 응답 파일 | Nutanix Guest Customization(unattend.xml)로 hostname, IP, 관리자 비밀번호, 도메인 가입 자동화 |
| 버전 관리 | `ws2025-std-2026.10` 형식, 템플릿 원본은 스냅샷으로 관리 (Sysprep 반복 실행 지양) |

**Step 5. 신규 VM 생성**

- 템플릿 배포 → **임시 hostname/IP**로 생성
- hostname에 종속되는 S/W(설치 시 hostname을 기록하는 제품, hostname 기반 라이선스)가 있으면 → **최종 hostname으로 생성하되 도메인 미가입 + DNS 등록 비활성** 상태에서 설치 진행

**Step 6. 역할/기능 설치**

```powershell
$want  = (Import-Csv .\04_Features.csv).Name
$avail = (Get-WindowsFeature).Name
$want | Where-Object { $_ -notin $avail } | ForEach-Object { Write-Warning "신규 OS에 없는 기능: $_" }
Install-WindowsFeature -Name ($want | Where-Object { $_ -in $avail }) -Source '<설치미디어>:\sources\sxs'
```

- SMB1 등 제거·비권장 기능은 설치 목록에서 제외

**Step 7. S/W 무인 설치**

- `install-all.ps1` + `catalog.json` (부록 C) – 설치 순서: 런타임(VC++, .NET) → 미들웨어 → 애플리케이션 → 패치
- 재부팅 필요 코드(3010) 발생 시 재부팅 후 다음 단계 진행

**Step 8. 설정 이관**

| 항목 | 인벤토리 결과 | 신규 서버 적용 방법 | 주의 |
|---|---|---|---|
| 환경변수 | `07_Environment*.csv` | `[Environment]::SetEnvironmentVariable(이름, 값, 'Machine')` | PATH는 신규 OS 기본값에 **앱 경로만 추가** (전체 덮어쓰기 금지) |
| 서비스 | `05_Services.csv` | 시작 유형, 실행 계정, 복구 옵션 재설정 (`sc.exe config`, `sc.exe failure`) | 서비스 계정 비밀번호 필요 |
| 예약 작업 | `06` XML | `Register-ScheduledTask -Xml (Get-Content <xml> -Raw) -TaskName <이름> -User <계정> -Password <비번>` | 실행 계정 비밀번호 재입력 |
| ODBC | `11_ODBC_*.csv` | 드라이버 설치 후 `Add-OdbcDsn` | 32/64비트 DSN 구분 |
| 인증서 | `10_Certificates.csv` | 원본에서 PFX export → `Import-PfxCertificate` | **개인키 export 불가 인증서는 재발급** |
| 방화벽 | `09_Firewall_Rules.csv` | 앱 관련 규칙만 `New-NetFirewallRule` | 정책 전체 import 금지 |
| 공유 폴더 | `12_Shares*.csv` | `New-SmbShare` + 공유 권한 | |
| 로컬 계정/그룹 | `13_Local*.csv` | 재생성 (비밀번호 재설정) | SID가 바뀌므로 ACL 재적용 필요 |
| NTFS 권한 | `16_DataDriveAcl.csv` | 계정 **이름 기준**으로 `icacls` 재적용 | 로컬 계정 SID 문제 |
| IIS | `17_IIS` | 앱 설치 후 Web Deploy 또는 설정 이관 | 인증서 바인딩, 앱 풀 계정 |
| hosts / 프록시 / 고정 경로 | `08_Network_*` | 파일 및 명령으로 적용 | |
| 보안 정책 | `14_SecurityPolicy` | 원칙적으로 GPO 및 신규 OS 표준 하드닝 적용, 앱에 필요한 항목만 반영 | `secedit` 전체 적용 금지 |
| 레지스트리 | `18_Registry` | 벤더 키 중 **필요한 항목만 선별** import | 버전 차이로 충돌 가능 |

**Step 9. 리허설 (격리망)**

- 원본 D: 디스크 클론을 신규 VM에 부착 → 서비스 기동 → 기능 검증 (운영 연동 차단)
- 소요 시간 측정, Runbook 확정

**Step 10. 전환 (D-Day)**

```powershell
# 1) 원본: 서비스 중지 → Nutanix 스냅샷 → VM 종료 → NIC 연결 해제
# 2) Nutanix: 원본 D: 디스크 클론 → 신규 VM 부착
# 3) 신규 VM: 디스크 온라인 및 드라이브 문자 확인
Get-Disk | Where-Object IsOffline | Set-Disk -IsOffline $false
Get-Disk | Where-Object IsReadOnly | Set-Disk -IsReadOnly $false
Get-Volume                                    # D: 확인, 다르면 Set-Partition -NewDriveLetter D
# 4) hostname/도메인 처리 → IP 변경 → 재부팅
# 5) 서비스 기동 → 검증
```

- **동일 hostname으로 도메인 재가입 시 주의**
  - 원본이 꺼진 후 진행. 기존 컴퓨터 계정의 **그룹 멤버십, SPN, 위임 설정을 사전 기록**
  - 2022-10 보안 업데이트(KB5020276) 이후 **기존 컴퓨터 계정 재사용이 제한**됨 → 계정을 만든 사용자 또는 도메인 관리자로 가입, 또는 GPO("Domain controller: Allow computer account re-use during domain join")로 허용 계정 지정 (이 GPO를 쓰려면 모든 DC와 멤버 서버에 2023-03-14 이후 업데이트가 설치되어 있어야 함)

**Step 11. 안정화 / 종료** – Linux와 동일 (원본 보존 후 삭제)

### 6.3 Windows Server 2025 전환 시 확인 사항

- **모든 outbound SMB 연결에 서명 기본 요구, NTLMv1 제거** 등 보안 기본값 강화 → 구형 NAS, 장비, 레거시 시스템과의 파일 공유·인증 연동을 리허설에서 확인
- 구버전 S/W 설치 프로그램이 신규 OS 버전을 인식하지 못해 설치를 거부하는 경우 → 벤더 패치/버전업 필요
- 32비트 전용 구형 S/W, 16비트 구성 요소는 실행 불가

---

## 7. 추가 제안 (더 좋은 방안)

### 7.1 서버 유형 분류 후 유형별 절차 적용

모든 서버에 같은 방식을 적용하면 예외 처리 비용이 커짐. **유형별로 표준 절차를 나누는 것**이 반복 업무에 유리함

| 유형 | 특징 | 전환 방식 |
|---|---|---|
| **L1** | tarball / 독립 경로 S/W (WEB, WAS, 자체 개발 데몬) | 디스크 클론 + `post-attach.sh` (**표준**) |
| **L2** | rpm 설치가 필수인 상용 S/W, 커널 모듈 사용 S/W | 템플릿 또는 스크립트 재설치 + Data 디스크 클론 |
| **L3** | DB (Oracle, MySQL, PostgreSQL 등) | **복제 기반 전환** (7.5) 또는 디스크 클론 + 벤더 절차 (Oracle은 OS 변경 시 relink 필요) |
| **W1** | silent 설치 가능 S/W | 템플릿 + 스크립트 설치 + D: 클론 (**표준**) |
| **W2** | silent 불가 / HW 종속 라이선스 | 예외 절차: repackaging, 벤더 작업, 또는 in-place 업그레이드 (7.6) |
| **W3** | MS 역할 서버 (MSSQL, AD, 파일 서버) | MS 공식 마이그레이션: MSSQL AlwaysOn/로그 전달, AD는 신규 DC 추가 후 기존 DC 강등, 파일 서버는 **Storage Migration Service**(이름·IP 인계 지원) |

### 7.2 전제 조건(계정·환경변수)의 코드화 → Ansible 단계적 도입

- 원안의 "User 및 환경변수를 기존과 동일하게 맞춘다"는 전제를 **사람의 작업이 아닌 코드**로 만드는 것이 이 방안의 성패를 좌우함
- 1단계 (즉시): `server.conf` + `post-attach.sh`(Linux), `catalog.json` + `install-all.ps1`(Windows)를 **Git으로 관리**
- 2단계 (중기): **Ansible**로 통합 – Linux(SSH), Windows(WinRM) 모두 지원. 같은 플레이북을 여러 번 실행해도 결과가 같고(멱등성), 변경 이력이 남음
- 효과: 서버 1대를 교체하든 100대를 교체하든 동일한 품질. 담당자가 바뀌어도 절차 유지

### 7.3 런타임 동봉 (OS 라이브러리 의존 최소화)

- JDK, Python, Node.js 등 런타임은 OS 패키지 대신 **LV에 동봉** → OS가 바뀌어도 런타임은 그대로
- Python 가상환경(venv)은 OS의 Python 경로를 참조하므로, **OS Python 기반 venv는 OS 교체 시 깨짐** → LV에 Python 자체를 포함
- OpenSSL 등 핵심 라이브러리 의존이 큰 S/W는 벤더가 제공하는 "번들 라이브러리 포함" 배포판 우선 사용

### 7.4 컨테이너 (Podman) – 중장기 검토

- 애플리케이션과 필요한 라이브러리를 **이미지로 묶어** 호스트 OS와 완전히 분리 → OS 교체 시 Podman만 있으면 기동
- Rocky Linux에 Podman 기본 제공, systemd 연동(Quadlet) 지원 → 별도 오케스트레이션 없이 단일 서버에서 사용 가능
- 적용 대상: 자체 개발 애플리케이션, 컨테이너를 공식 지원하는 미들웨어
- 제약: 상용 S/W의 컨테이너 지원 여부·라이선스, 운영 인력 역량, 이미지 관리 체계 필요

### 7.5 DB 서버는 복제 기반 전환

- DB는 디스크를 붙이는 방식보다 **신규 서버에 복제(Replica/Standby)를 구성한 뒤 전환(Switchover)** 하는 방식이 다운타임이 짧고 안전함
- 예: MySQL/PostgreSQL 복제, Oracle Data Guard, MSSQL AlwaysOn·로그 전달
- 전환 전까지 원본은 계속 운영되므로, 검증이 충분히 끝난 뒤 전환 가능

### 7.6 In-place 업그레이드 (예외 적용)

- 재설치가 매우 어려운 Windows 서버(W2 유형)는 **Nutanix 스냅샷으로 보호한 상태의 in-place 업그레이드**도 현실적인 선택지
  - 사전 호환성 점검: `setup.exe /auto upgrade /compat scanonly`
  - 제약: 지원 업그레이드 경로(버전 단계 수), 에디션·언어 동일, Server Core ↔ 데스크톱 경험 변경 불가
  - 단점: 이전 OS의 잔존물·누적 문제가 그대로 승계됨, 소요 시간 예측이 어려움
- Linux in-place(Leapp 기반 ELevate 등)는 커뮤니티 도구이므로 **운영 서버에는 비권장**

### 7.7 Nutanix 기능 활용

| 기능 | 활용 |
|---|---|
| vDisk 클론 | 전환·리허설 시 원본 보존 (메타데이터 복제라 빠름, 부록 E 참고) |
| Nutanix Volume Group | App/Data 디스크를 VM 수명과 분리하여 관리, VM 간 부착·분리가 쉬움 (LVM VG와 이름이 같으므로 문서상 구분 필요) |
| VM 스냅샷 / Protection Domain | 전환 직전 원본 보호 |
| Prism Central VM Template | 템플릿 버전 관리 |
| Guest Customization | Linux cloud-init / Windows unattend.xml로 hostname, IP 자동 설정 |
| NCM Self-Service (구 Calm) | 라이선스 보유 시 "템플릿 배포 → 디스크 클론 → 스크립트 실행" 전 과정을 Blueprint로 자동화 |

### 7.8 방식 비교

| 항목 | A. 신규 구축 + 디스크 클론 (**권장 기본**) | B. In-place 업그레이드 | C. 컨테이너 | D. 복제 기반 전환 |
|---|---|---|---|---|
| 전환 시간 | 짧음 (수십 분 ~ 1시간) | 김 (1~3시간), 예측 어려움 | 매우 짧음 | 매우 짧음 |
| 롤백 | 원본 재기동 (즉시) | 스냅샷 복구 | 이전 호스트에서 재기동 | 역방향 전환 |
| OS 상태 | 깨끗함 | 잔존물 승계 | 호스트 최소 구성 | 깨끗함 |
| 최초 준비 비용 | 중 (표준화 필요) | 낮음 | 높음 (이미지화) | 중 |
| 반복 시 비용 | **낮음** | 매번 동일 | **매우 낮음** | 중 |
| 적용 대상 | 대부분 (L1, L2, W1) | W2 예외 | 자체 개발 앱 | DB (L3, W3) |

---

## 8. 리스크 및 대응

> 영향/가능성: 상·중·하

### 8.1 공통

| # | 리스크 | 영향 | 가능성 | 대응 |
|---|---|---|---|---|
| C1 | 벤더가 목표 OS를 지원하지 않음 (기술 지원 거부, 라이선스 위반) | 상 | 중 | 사전 Support Matrix 확인. 미지원 시 S/W 버전업 병행 또는 목표 OS 조정 |
| C2 | 문서화되지 않은 설정·수작업 누락 | 상 | 상 | 인벤토리 스크립트, 원본/신규 설정 비교(diff), 리허설 필수 |
| C3 | 리허설용 클론 서버가 운영 시스템에 연동 (배치 실행, 메일·SMS 발송, 운영 DB 쓰기, IP 충돌) | 상 | 중 | 격리망, 서비스·cron 자동 기동 해제 상태로 부착, 운영 IP 사용 금지 |
| C4 | 원본·신규 서버 동시 기동 (IP 충돌, 배치 중복 실행) | 상 | 하 | 원본 전원 OFF + **NIC 연결 해제** + 자동 기동 해제 |
| C5 | 롤백 불가 시점 이후 장애 (신규 서버에 운영 데이터가 기록된 후) | 상 | 하 | Go/No-go 판단 전 트랜잭션 개방 금지, 데이터 역이관 절차 사전 정의 |
| C6 | IP / hostname / MAC 기반 라이선스 무효화 | 중 | 중 | 벤더 사전 협의. 필요 시 신규 VM NIC에 원본과 동일한 MAC 지정 (원본 종료 후) |
| C7 | 모니터링·백업·보안 에이전트 미등록 또는 중복 등록 | 중 | 중 | 사후 체크리스트, 원본 등록 정보 정리 |
| C8 | 강화된 암호·보안 기본값으로 외부 연동 실패 (TLS, SHA-1, SMB 서명) | 중 | 중 | 리허설에서 연동 테스트. 예외 정책은 한시적으로만 적용 |
| C9 | 템플릿 노후화 (패치 누락 상태로 배포) | 중 | 중 | 정기 템플릿 갱신 + 버전명 관리 |
| C10 | IP 전환 후 통신 지연 (스위치 ARP 캐시) | 하 | 중 | Gratuitous ARP 전송, 또는 동일 MAC 사용 |
| C11 | 원본 보존 + 클론으로 스토리지 사용량 증가 | 하 | 중 | 보존 기간 준수 후 삭제, 용량 사전 확인 |
| C12 | 담당자 의존, 절차 미숙 | 중 | 중 | Runbook 표준화, 파일럿 서버로 시작 후 확대 |
| C13 | EOS 전 교체 미완료 → 보안 패치 중단 | 상 | 중 | EOS 일정 기준 우선순위화. Windows Server 2016은 ESU로 한시 연장 검토 (1.1 참고) |

### 8.2 Linux

| # | 리스크 | 영향 | 가능성 | 대응 |
|---|---|---|---|---|
| L1 | 라이브러리 비호환 (OpenSSL 3, glibc 등). Rocky 10은 `compat-openssl11`이 없어 OpenSSL 1.1 의존 S/W는 임시 대응 불가 | 상 | 중 | ldd 전수 점검, compat 패키지 템플릿 반영(Rocky 9), 런타임·라이브러리 LV 동봉, S/W 버전업 |
| L2 | UID/GID 불일치 → 권한 오류, **다른 계정이 파일 소유 (보안 사고)** | 상 | 중 | UID/GID 대장, `find /app /data -nouser -o -nogroup` 점검 (post-attach.sh에 포함) |
| L3 | SELinux 컨텍스트 미적용 → 서비스 기동 실패 (`status=203/EXEC`), `/app/home` SSH 키 로그인 실패 | 중 | 상 | `semanage fcontext` 규칙을 스크립트로 재적용 (규칙은 OS 영역에 저장되므로 매번 필요) |
| L4 | Rocky 9 이상 LVM devices file로 부착한 VG가 인식되지 않음 | 중 | 상 | `vgimportdevices` 절차를 Runbook에 포함 |
| L5 | VG 이름 충돌, PV UUID 중복 (같은 VM에 원본·클론 디스크 동시 부착) | 중 | 하 | VG 명명 표준, 중복 시 `vgimportclone` |
| L6 | fstab 오류로 부팅 실패 (emergency mode) | 중 | 중 | `nofail` 옵션, `mount -a` 검증 후 재부팅 테스트 |
| L7 | 신규 OS에서 만든 XFS를 구 OS에서 마운트 불가 (롤백 시) | 중 | 하 | 클론 방식은 원본 디스크가 그대로이므로 영향 없음. 신규 디스크를 구 OS에 붙여야 하는 경우만 주의 |
| L8 | Rocky 10의 x86-64-v3 CPU 요구 사항 미충족 → 설치·부팅 불가, 구형 호스트로 마이그레이션·DR 전환 불가 | 상 | 하 | 운영·DR 클러스터 모두 VM에 노출되는 CPU 기능 사전 확인 (5.1.4 참고) |
| L9 | OS Python 기반 venv·스크립트 오류 | 중 | 중 | Python을 LV에 동봉 |
| L10 | Rocky 9 이상 root SSH 비밀번호 로그인 기본 차단 → 점검·배포 도구 실패 | 하 | 중 | 키 기반 인증 또는 sudo 계정으로 전환 |
| L11 | 템플릿 machine-id·SSH 호스트 키 중복 | 중 | 중 | 템플릿 봉인 절차 |
| L12 | rpm으로 설치된 숨은 의존 패키지 누락 (예전에 수동으로 `yum install`한 라이브러리) | 중 | 중 | 원본 `rpm -qa`와 템플릿 비교, ldd 점검 |

### 8.3 Windows

| # | 리스크 | 영향 | 가능성 | 대응 |
|---|---|---|---|---|
| W1 | EXE silent 설치 미지원 | 중 | 중 | repackaging(MSIX Packaging Tool 등), 벤더 문의, 예외 절차(수동 또는 in-place) |
| W2 | 설치본 미보유, 현재 버전이 신규 OS 미지원 → 강제 버전업 | 상 | 중 | 설치본 저장소 영구 보관, 사전 벤더 확인, 버전업 시 애플리케이션 검증 별도 수행 |
| W3 | 라이선스 재활성화 실패 (HW ID, 활성화 횟수 제한) | 상 | 중 | 벤더 사전 협의, 원본 라이선스 반납 절차 확인 |
| W4 | 로컬 계정 SID 변경 → D: NTFS 권한 무효 | 중 | 상 | 도메인 계정·그룹 사용, 이름 기준 ACL 재적용 스크립트 |
| W5 | 인증서 개인키 export 불가 | 중 | 중 | 사전 확인 후 재발급 일정 확보 |
| W6 | 동일 hostname 도메인 재가입 실패 (KB5020276), 그룹·SPN·위임 누락 | 중 | 중 | 가입 권한·절차 사전 정의, 기존 컴퓨터 계정 속성 기록 |
| W7 | 레지스트리·사용자 프로필(HKCU) 설정 누락 | 중 | 중 | 인벤토리 18번 항목 검토, 벤더 export 기능 활용 |
| W8 | 원본 설정 무분별 import로 신규 OS 보안 기준 훼손 (방화벽 전체, 보안 정책, 레지스트리) | 중 | 중 | 앱 관련 항목만 선별 적용 |
| W9 | Sysprep 미실행 복제로 SID 중복, Sysprep 실패 | 중 | 하 | 템플릿 절차 표준화 |
| W10 | 재부팅 대기 상태로 다음 설치 실패 | 하 | 중 | 3010/1641 처리, 단계별 재부팅 |
| W11 | 보안 기본값 강화(SMB 서명, NTLMv1 제거)로 구형 장비 연동 실패 | 중 | 중 | 리허설에서 파일 공유·인증 연동 확인 |
| W12 | 데이터 디스크 오프라인 / 드라이브 문자 변경 → 앱 경로 오류 | 중 | 중 | 템플릿 CD-ROM 문자 변경, 전환 Runbook에 온라인·문자 확인 포함 |

---

## 9. 전환 당일 Runbook

**사전 (D-14 ~ D-1)**

- [ ] 인벤토리 최신화 (전환 1주 이내)
- [ ] 리허설 완료, 소요 시간 확인, 검증 항목 확정
- [ ] 변경 승인, 관련 부서·연동 시스템 담당자 공지
- [ ] 벤더 지원 일정, 라이선스 재발급 준비
- [ ] 신규 VM 최종 상태 점검 (패치, 에이전트, 스크립트 최신 버전)
- [ ] 롤백 절차 및 Go/No-go 판단자·판단 시각 확정

**당일**

1. [ ] 서비스 중지 공지, 연동 시스템 차단 또는 대기
2. [ ] 원본 애플리케이션 정상 중지 (데이터 flush 확인)
3. [ ] 원본 VM Nutanix 스냅샷 (+ 필요 시 애플리케이션 백업, DB dump)
4. [ ] 원본 VM 종료 → **NIC 연결 해제, 자동 기동 해제**
5. [ ] App/Data 디스크 클론 → 신규 VM 부착
6. [ ] (Linux) `vgimportdevices` → `vgchange -ay` → 마운트 → `post-attach.sh`
       (Windows) 디스크 온라인 → 드라이브 문자 확인 → 설정 스크립트
7. [ ] hostname / IP 전환 (Windows는 도메인 처리)
8. [ ] 서비스 기동 → 검증 (프로세스·포트, 로그, 헬스체크, 연동, 배치, 사용자 테스트)
9. [ ] 재부팅 테스트 (자동 기동, 마운트 확인)
10. [ ] **Go/No-go 판단** → Go: 연동 재개 / No-go: 10장 롤백
11. [ ] 모니터링·백업·보안 에이전트 정상 확인

**사후**

- [ ] 안정화 기간 모니터링 (예: 14일)
- [ ] 원본 VM·스냅샷 삭제
- [ ] CMDB, 구성 문서, IP 관리 대장 갱신
- [ ] 회고: 소요 시간, 이슈, 표준·스크립트 개선 사항 반영

---

## 10. 롤백 기준 및 절차

**롤백 기준 (예시 – 서비스별 확정)**

- 핵심 기능 검증 실패 후 원인 미해결 상태로 **정해진 시간(예: 60분)** 경과
- 데이터 정합성 이상 발견
- 전환 시작 후 서비스 재개 목표 시간 초과 예상

**롤백 절차**

1. 신규 VM 서비스 중지 → VM 종료 → NIC 연결 해제
2. 원본 VM NIC 연결 → 기동 (원본 디스크는 클론 방식이므로 **변경 없음**)
3. 서비스 기동 및 검증
4. (Windows, 신규 서버가 같은 이름으로 도메인 가입한 경우) 원본의 보안 채널이 깨졌을 수 있음 → `Test-ComputerSecureChannel -Repair -Credential <도메인관리자>`

**롤백 불가 지점**

- 신규 서버에서 운영 트랜잭션이 발생한 이후 원본으로 돌아가면 **그 사이 데이터가 유실**됨
- → Go 판단 전에는 운영 트랜잭션을 열지 않음. Go 이후 롤백이 필요하면 **데이터 역이관 절차**를 따름 (서비스별 사전 정의)

---

## 11. 부록

### 부록 A. Linux 인벤토리 수집 명령 (원본 서버)

> Windows의 `Get-PreUpgradeInventory.ps1`에 대응하는 Linux용 스크립트 작성 권장

```bash
OUT=/app/manifest/inventory/$(date +%Y%m%d); mkdir -p "$OUT"   # 1회차는 /root 등 임시 경로 사용

# 계정/그룹 (UID 1000 이상)
awk -F: '$3>=1000 && $3<65534' /etc/passwd > "$OUT/passwd.txt"
awk -F: '$3>=1000 && $3<65534' /etc/group  > "$OUT/group.txt"

# 사용자별 crontab, 시스템 cron
for u in $(cut -d: -f1 /etc/passwd); do crontab -l -u "$u" 2>/dev/null | sed "s/^/$u: /"; done > "$OUT/crontab.txt"
ls -l /etc/cron.d /etc/cron.daily /etc/cron.weekly /etc/cron.monthly > "$OUT/cron_dirs.txt"

# 서비스 / 포트
systemctl list-unit-files --type=service --state=enabled > "$OUT/services_enabled.txt"
ls -l /etc/systemd/system/*.service /etc/init.d/ 2>/dev/null  > "$OUT/custom_units.txt"
ss -lntup > "$OUT/listen_ports.txt"

# 디스크 / LVM / 마운트
{ lsblk -f; pvs; vgs; lvs; cat /etc/fstab; } > "$OUT/storage.txt" 2>&1

# OS 영역에 남는 설정
tar czf "$OUT/etc_custom.tgz" /etc/profile.d /etc/sysctl.d /etc/security/limits.d \
    /etc/sudoers.d /etc/logrotate.d /etc/hosts /etc/chrony.conf /etc/resolv.conf \
    /etc/pki/ca-trust/source/anchors /etc/ssh/sshd_config 2>/dev/null
sysctl -a 2>/dev/null > "$OUT/sysctl_all.txt"
firewall-cmd --list-all-zones > "$OUT/firewall.txt" 2>&1
{ getenforce; semanage fcontext -l -C; semanage port -l -C; } > "$OUT/selinux_custom.txt" 2>&1
update-crypto-policies --show > "$OUT/crypto_policy.txt" 2>&1

# 설치 패키지 (템플릿과 비교용)
rpm -qa --qf '%{NAME}\n' | sort > "$OUT/rpm_list.txt"
```

### 부록 B. `post-attach.sh` 예시 (신규 OS에서 실행)

```bash
# /app/manifest/server.conf
GROUP_LIST=("wasgrp:2001")
USER_LIST=("wasadm:2001:wasgrp:/app/home/wasadm")   # 이름:UID:그룹:홈
SERVICE_LIST=("tomcat")
FW_PORTS=("8080/tcp" "8443/tcp")
SEL_FCONTEXT=("bin_t:/app/tomcat/bin(/.*)?")         # 타입:경로정규식
```

```bash
#!/bin/bash
# /app/manifest/post-attach.sh : 신규 OS에 App/Data 디스크 마운트 후 실행
set -euo pipefail
source /app/manifest/server.conf

# 1) 그룹/계정 – UID/GID 고정
for e in "${GROUP_LIST[@]}"; do
  IFS=: read -r name gid <<<"$e"
  getent group "$name" >/dev/null || groupadd -g "$gid" "$name"
done
for e in "${USER_LIST[@]}"; do
  IFS=: read -r name uid grp home <<<"$e"
  id "$name" &>/dev/null || useradd -u "$uid" -g "$grp" -d "$home" -M -s /bin/bash "$name"
done

# 2) 소유자 불일치 파일 점검 – 하나라도 있으면 중단
orphan=$(find /app /data -xdev \( -nouser -o -nogroup \) -print -quit)
[[ -z "$orphan" ]] || { echo "소유자 불일치 파일 존재: $orphan" >&2; exit 1; }

# 3) OS 설정 – 원본은 /app/os, OS에는 복사만
install -m 0644 /app/os/sysctl.conf /etc/sysctl.d/90-app.conf && sysctl --system >/dev/null
install -m 0644 /app/os/limits.conf /etc/security/limits.d/90-app.conf
install -m 0644 /app/os/profile.sh  /etc/profile.d/app.sh
if [[ -f /app/os/sudoers ]]; then
  install -m 0440 /app/os/sudoers /etc/sudoers.d/app && visudo -cf /etc/sudoers.d/app
fi

# 4) SELinux – 규칙은 OS 영역에 저장되므로 매번 재적용
semanage fcontext -a -e /home /app/home 2>/dev/null || true   # 홈 디렉터리 컨텍스트 (SSH 키 로그인)
for e in "${SEL_FCONTEXT[@]}"; do
  type=${e%%:*}; path=${e#*:}
  semanage fcontext -a -t "$type" "$path" 2>/dev/null || semanage fcontext -m -t "$type" "$path"
done
restorecon -R /app

# 5) 방화벽
for p in "${FW_PORTS[@]}"; do firewall-cmd -q --permanent --add-port="$p"; done
firewall-cmd -q --reload

# 6) cron – 파일명이 계정명
for f in /app/cron/*.cron; do
  [[ -e "$f" ]] && crontab -u "$(basename "$f" .cron)" "$f"
done

# 7) systemd – unit 복사 후 등록
for s in "${SERVICE_LIST[@]}"; do
  install -m 0644 "/app/systemd/$s.service" "/etc/systemd/system/$s.service"
done
systemctl daemon-reload
for s in "${SERVICE_LIST[@]}"; do systemctl enable --now "$s"; done
```

> 리허설 시에는 7)의 `--now`를 빼고, 6)의 cron 등록을 생략하여 자동 실행을 막음

### 부록 C. Windows `install-all.ps1` + `catalog.json` 예시

```json
[
  { "Name": "VCRedist-x64", "File": "Microsoft\\VCRedist\\14.40\\VC_redist.x64.exe",
    "Args": "/install /quiet /norestart", "Sha256": "<해시>",
    "Detect": "C:\\Windows\\System32\\vcruntime140.dll" },
  { "Name": "AppA", "File": "VendorA\\AppA\\5.2\\AppA.msi",
    "Args": "INSTALLDIR=\"C:\\Apps\\AppA\"", "Sha256": "<해시>",
    "Detect": "C:\\Apps\\AppA\\AppA.exe" },
  { "Name": "AppB", "File": "VendorB\\AppB\\3.1\\AppB_setup.exe",
    "Args": "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART", "Sha256": "<해시>",
    "Detect": "C:\\Program Files\\AppB\\AppB.exe" }
]
```

```powershell
# install-all.ps1 : catalog.json 순서대로 설치, 해시·종료 코드·설치 결과 확인
param(
    [string]$Repo    = '\\<파일서버>\SWRepo',
    [string]$Catalog = (Join-Path $PSScriptRoot 'catalog.json')
)
$ErrorActionPreference = 'Stop'
$logDir = 'C:\InstallLogs'
New-Item -ItemType Directory -Force $logDir | Out-Null

foreach ($i in (Get-Content $Catalog -Raw -Encoding UTF8 | ConvertFrom-Json)) {
    $file = Join-Path $Repo $i.File
    if ((Get-FileHash $file -Algorithm SHA256).Hash -ne $i.Sha256) { throw "$($i.Name): 해시 불일치" }

    if ($file -like '*.msi') {
        $exe = 'msiexec.exe'
        $arg = "/i `"$file`" /qn /norestart /l*v `"$logDir\$($i.Name).log`" $($i.Args)"
    } else {
        $exe = $file
        $arg = $i.Args
    }
    $p = Start-Process $exe -ArgumentList $arg -Wait -PassThru
    if ($p.ExitCode -notin 0, 3010, 1641) { throw "$($i.Name): 설치 실패 (ExitCode $($p.ExitCode))" }

    # 종료 코드만 믿지 않고 설치 결과 재확인
    if ($i.Detect -and -not (Test-Path $i.Detect)) { throw "$($i.Name): 설치 확인 실패 ($($i.Detect))" }
    Write-Host "[OK] $($i.Name) (ExitCode $($p.ExitCode))"
}
```

**설치 프레임워크별 silent 옵션 참고**

| 설치 형식 (`InstallerType`) | Silent 옵션 |
|---|---|
| MSI | `msiexec /i <파일> /qn /norestart /l*v <로그>` |
| EXE-InnoSetup | `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /LOG="<로그>"` |
| EXE-NSIS | `/S /D=<설치경로>` (`/D`는 맨 마지막, 따옴표 없음) |
| EXE-InstallShield (Basic MSI) | `/s /v"/qn REBOOT=ReallySuppress"` |
| EXE-InstallShield (InstallScript) | 녹화 `/r /f1"<iss>"` → 재생 `/s /f1"<iss>"` |
| EXE-WiXBurn | `/quiet /norestart /log <로그>` |

### 부록 D. S/W 카탈로그 양식 (서버별)

> 아래 행은 작성 방법을 보여주기 위한 **가상의 예시**이며 실제 서버 정보가 아님

| 서버 | S/W | 현재 버전 | 설치 형식 | Silent 명령 | 신규 OS 지원 버전 | 라이선스 방식 | 설정 이관 방법 | 검증 방법 | 유형 | 담당 |
|---|---|---|---|---|---|---|---|---|---|---|
| ap-web01 | AppA | 5.1 | MSI | `/qn INSTALLDIR=...` | 5.2 이상 | hostname | 벤더 export | 헬스체크 URL | W1 | |
| ap-web01 | AppB | 3.1 | EXE-InnoSetup | `/VERYSILENT ...` | 3.1 | 없음 | D: 클론 | 서비스 기동 | W1 | |
| ap-was01 | Tomcat | 9.0.x | tarball | – | – | – | 디스크 클론 | 헬스체크 URL | L1 | |

### 부록 E. 디스크 '이동' 대신 '클론'을 사용하는 이유

> 2장 핵심 원칙 3번의 상세 설명

#### E.1 개념

```
[이동]  디스크는 1개뿐
 원본 VM  ── disk1 분리(detach) ──▶  신규 VM에 부착
 (원본 VM에는 디스크가 없어짐)

[클론]  디스크가 2개가 됨
 원본 VM  disk1 (그대로 유지, 전원 OFF로 보존)
            └─ clone ──▶ disk1' → 신규 VM에 부착
```

- **이동**: 디스크가 원본 VM에서 신규 VM으로 옮겨감. 신규 VM에서 일어난 모든 변경이 그 디스크에 바로 기록됨
- **클론**: 신규 VM은 복제본으로 작업함. 원본 VM은 전환 직전 상태의 디스크를 그대로 가지고 있음

#### E.2 클론이 빠른 이유 – 메타데이터 복제와 Redirect-on-Write

Nutanix는 가상 디스크(vDisk)를 두 부분으로 나누어 관리함

- **데이터 블록(extent)**: 실제 데이터 조각
- **블록 맵(메타데이터)**: "이 디스크의 n번째 영역은 물리적으로 어느 블록에 있다"는 주소록

| 시점 | 동작 |
|---|---|
| 클론 생성 | 데이터 블록은 복사하지 않고 **블록 맵(주소록)만 새로 만듦**. 두 디스크가 같은 물리 블록을 함께 가리킴. 디스크 크기와 상관없이 수 초 안에 끝나고, 생성 직후 추가 용량은 거의 없음 |
| 클론 이후 쓰기 | **Redirect-on-Write**: 함께 쓰는 블록을 덮어쓰지 않고 새 위치에 기록한 뒤, 데이터를 쓴 디스크의 블록 맵만 새 위치로 변경 |

```
클론 직후
 원본 디스크 블록 맵 : [A][B][C][D]
 클론 디스크 블록 맵 : [A][B][C][D]    ← 같은 물리 블록을 가리킴 (복사 없음)

신규 VM이 클론 디스크의 B 영역을 수정
 원본 디스크 블록 맵 : [A][B][C][D]    ← 변화 없음
 클론 디스크 블록 맵 : [A][B'][C][D]   ← B'만 새 위치에 기록, 주소만 변경
```

→ 신규 VM에서 무엇을 하든 **원본 디스크가 보는 데이터는 바뀌지 않음**

- **Copy-on-Write와의 차이**
  - Copy-on-Write(LVM 스냅샷 등): 기존 블록을 다른 곳에 먼저 복사한 뒤 덮어씀. 쓰기 1회당 읽기 1회 + 쓰기 2회가 발생
  - Redirect-on-Write: 새 위치에 한 번만 씀. 클론을 쓰는 동안에도 성능 부담이 작음
- **원본과 클론은 서로 독립된 디스크**
  - 나중에 원본 VM을 삭제해도 클론은 영향받지 않음
  - 함께 쓰던 블록은 그 블록을 가리키는 디스크가 하나라도 남아 있으면 유지됨. 어느 디스크도 가리키지 않으면 백그라운드 작업이 공간을 회수함
  - VMware linked clone처럼 부모 디스크를 계속 남겨 둘 필요가 없음

#### E.3 원본 보존이 중요한 이유

이동 방식에서는 서비스를 기동하기 전에도 디스크가 바뀔 수 있음

| 디스크가 바뀌는 상황 | 예 |
|---|---|
| 재적용 스크립트 | `restorecon -R`가 SELinux 라벨을 파일의 확장 속성에 기록, 소유자 정리용 `chown` 실행 |
| 애플리케이션 첫 기동 | 데이터·스키마 자동 마이그레이션, 캐시·인덱스 재생성, 로그 기록 |
| 신규 OS의 파일시스템 처리 | 마운트 시 저널 재적용, 점검·복구(`xfs_repair`) 실행 |
| 작업자 실수 | 잘못된 경로에서 `rm`, 다른 디스크에 `mkfs` 실행 |

- 이동 방식의 롤백: 이미 바뀐 디스크를 원본 VM에 다시 붙임 → 원본 상태가 보장되지 않고, 디스크 분리·부착 작업도 다시 필요함
- 클론 방식의 롤백: 원본 디스크가 그대로 남아 있음 → **신규 VM 종료 + 원본 VM 기동**으로 끝남

| 항목 | 이동 | 클론 |
|---|---|---|
| 전환 작업 시간 | 분리·부착 (빠름) | 클론 생성·부착 (빠름, 거의 같음) |
| 롤백 방법 | 디스크를 다시 떼어 원본에 부착 | 원본 VM 전원 ON |
| 롤백 후 원본 상태 | **보장 안 됨** (신규 OS에서 바뀐 내용이 남음) | **전환 직전 상태 그대로** |
| 리허설 | 원본 서비스를 멈춰야 가능 | 운영 중에도 클론으로 **반복 가능** |
| 추가 용량 | 없음 | 바뀐 블록만큼만 증가 |

#### E.4 용량 영향

- 클론 직후에는 거의 0이고, 이후 **바뀐 블록만큼만** 증가함
- 예: 500GB 디스크를 14일 보존하는 동안 30GB가 바뀌면 논리적으로 약 30GB 추가. 실제 물리 사용량은 복제 계수만큼 곱해짐 (RF2이면 2배)
- 보존 기간이 끝나 원본 VM을 삭제하면 원본만 가리키던 블록이 회수됨

#### E.5 주의 사항

1. **클론은 백업이 아님** – 원본과 같은 물리 블록을 함께 쓰므로 스토리지 장애 시 함께 영향받음. 전환 전 백업은 별도로 수행
2. **본 전환은 원본 VM 종료 후 클론** – 운영 중에 만든 클론은 전원을 갑자기 끈 시점의 상태(crash-consistent)와 같음. 리허설에는 사용 가능하나, 본 전환은 서비스 정상 종료 → VM 종료 후 클론해야 데이터 정합성이 보장됨
3. **원본과 클론 VM 동시 기동 금지** – 내용이 완전히 같으므로 IP·hostname 충돌, 배치 중복 실행 발생
4. **원본 디스크와 클론 디스크를 같은 VM에 함께 부착 금지**
   - Linux: PV UUID와 VG 이름이 같아 LVM 충돌 (꼭 필요하면 `vgimportclone` 사용)
   - Windows: 디스크 서명이 겹쳐 한쪽 디스크가 오프라인으로 바뀜
   - 서로 다른 VM에 부착하면 문제없음
5. 본 부록의 설명은 **원본과 같은 스토리지 컨테이너에 클론을 만드는 경우** 기준. 다른 컨테이너에 만들 때의 동작은 사용 중인 AOS 버전 문서로 확인

#### E.6 작업 순서 (Nutanix)

1. 원본 서비스 정상 중지
2. 원본 VM 스냅샷 (선택, 추가 안전장치)
3. 원본 VM 종료 → NIC 연결 해제
4. 신규 VM에 원본 디스크를 원본으로 하는 클론 디스크 추가
   - Prism: VM 수정 → 디스크 추가 → 기존 vDisk에서 클론 (메뉴 이름은 Prism 버전별로 다를 수 있음)
   - acli: `vm.disk_create <신규VM> clone_from_vmdisk=<원본 vmdisk UUID>`
5. 신규 VM에서 디스크 인식 → 마운트 → 서비스 기동 (5.2 Step 6, 6.2 Step 10 참고)

#### 참고 자료

- [Nutanix.dev – AOS snapshots (redirect-on-write)](https://www.nutanix.dev/?p=64957)
- [Nutanix Community – snapshot/clone 삭제 시 extent 회수](https://next.nutanix.com/how-it-works-22/snapshot-creation-32662)
- [Study guide – ROW Snapshots and Zero-Byte Clones](https://open-exam-prep.com/study-guides/nutanix-nca/ch-05-storage-optimization/snapshots-clones-row) (비공식 자료)
