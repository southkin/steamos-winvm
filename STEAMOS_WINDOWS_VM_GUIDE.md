# SteamOS에서 Distrobox 기반 Windows VM 준비

이 구성은 SteamOS 호스트를 최대한 건드리지 않고, `distrobox` 안에 Ubuntu + Quickemu 실행 환경을 만든 뒤 Windows 10/11 VM을 실행하는 방식입니다. Windows용 보안 프로그램이 필요한 웹사이트는 Wine이나 Linux 컨테이너에서 실패하는 경우가 많아서, 실제 Windows 게스트를 쓰는 쪽이 현실적입니다.

## 빠른 실행

```bash
cd /path/to/steamos-winvm
chmod +x ./setup-winvm-distrobox.sh
./setup-winvm-distrobox.sh all
./setup-winvm-distrobox.sh run
```

기본값은 Windows 11, 한국어 미디어 요청, 4 CPU, 4 GiB RAM, 80 GiB 디스크, SDL 화면 출력입니다. 바꾸려면 실행 앞에 환경변수를 붙입니다.

```bash
WINDOWS_VERSION=10 DISK_SIZE=100G ./setup-winvm-distrobox.sh all
DISPLAY_BACKEND=spice ./setup-winvm-distrobox.sh run
```

## 자동화되는 부분

- `distrobox` 컨테이너 생성
- 컨테이너 내부에 Quickemu/QEMU/OVMF/swtpm/VirtIO 관련 패키지 설치
- `quickget windows 10` 또는 `quickget windows 11`로 Windows ISO와 VM 설정 생성
- SteamOS 앱 런처용 `.desktop` 파일 생성
- 반복 실행용 `run`, 스냅샷용 `snapshot-create`, `snapshot-apply` 명령 제공

## 자동화하기 어려운 부분

- Windows 설치 과정의 라이선스, Microsoft 계정, 지역/키보드 설정
- 웹사이트별 보안 프로그램 설치와 재부팅
- 공동인증서, 스마트카드, USB 보안토큰 같은 장치 연결
- `/dev/kvm` 권한, 펌웨어 가상화 옵션, SteamOS 업데이트 후 호스트 권한 문제
- 보안 프로그램이 VM/KVM 환경 자체를 차단하는 경우

보안 프로그램이 VM을 막는 경우에는 스크립트로 우회하지 않습니다. 그 경우에는 실제 Windows 장치, 외장 SSD에 Windows 설치, 또는 해당 사이트의 모바일/공식 대체 인증 경로가 더 안정적입니다.

## 실행 명령

```bash
./setup-winvm-distrobox.sh check
./setup-winvm-distrobox.sh setup
./setup-winvm-distrobox.sh create
./setup-winvm-distrobox.sh run
```

`all`은 `setup`, `create`, `desktop`을 한 번에 수행합니다. Windows 설치 화면이 뜬 뒤에는 일반 PC처럼 설치를 끝내면 됩니다.

## apt-get 이 없다고 나올 때

이 스크립트는 Ubuntu 기반 `distrobox`를 전제로 합니다. 그런데 같은 이름의 기존 컨테이너가 이미 있으면 그 컨테이너를 재사용하므로, 예전에 Arch/Fedora 기반으로 만든 `steamos-winvm`이 남아 있으면 `apt-get`이 없다고 나올 수 있습니다.

확인:

```bash
distrobox enter steamos-winvm -- cat /etc/os-release
```

복구:

```bash
./setup-winvm-distrobox.sh recreate
./setup-winvm-distrobox.sh setup
```

또는 수동으로 지운 뒤 다시 실행해도 됩니다.

```bash
distrobox rm steamos-winvm
./setup-winvm-distrobox.sh all
```

## sudo 가 no new privileges 에 막힐 때

SteamOS의 rootless `distrobox`에서는 컨테이너 내부 `sudo`가 아래처럼 막힐 수 있습니다.

```text
sudo: The "no new privileges" flag is set
```

이 스크립트는 이제 기본적으로 rootful `distrobox` 모드로 동작합니다. 이미 rootless `steamos-winvm`을 한 번 만든 상태라면 아래처럼 다시 만드는 게 맞습니다.

```bash
./setup-winvm-distrobox.sh recreate
./setup-winvm-distrobox.sh all
```

rootful 모드에서는 `distrobox`가 sudo 비밀번호를 물을 수 있습니다. SteamOS에서 sudo 비밀번호가 아직 없으면 먼저 설정해야 할 수 있습니다.

```bash
passwd
```

## 권한 점검

KVM 가속이 없으면 Windows VM은 실사용이 어려울 정도로 느릴 수 있습니다.

```bash
ls -l /dev/kvm
groups
```

`/dev/kvm` 권한이 없으면 SteamOS 데스크톱 모드 터미널에서 아래를 실행한 뒤 로그아웃/재부팅합니다.

```bash
sudo usermod -aG kvm "$USER"
reboot
```

`sudo` 비밀번호가 없다면 먼저 `passwd`로 현재 사용자 비밀번호를 설정해야 할 수 있습니다.

## 보안 프로그램용 권장 흐름

1. Windows 설치와 Windows Update를 끝냅니다.
2. 브라우저를 설치하거나 Edge를 업데이트합니다.
3. 보안 프로그램을 깔기 전 깨끗한 스냅샷을 만듭니다.

```bash
./setup-winvm-distrobox.sh snapshot-create clean-install
```

사이트 사용 후 상태가 지저분해지면 Windows를 종료하고 스냅샷으로 되돌립니다.

```bash
./setup-winvm-distrobox.sh snapshot-apply clean-install
```

## USB, 인증서, 클립보드

기본 `DISPLAY_BACKEND=sdl`은 Windows 10/11에서 Quickemu가 권장하는 안정적인 표시 방식입니다. 클립보드 공유나 SPICE USB 리다이렉션이 필요하면 다음처럼 실행해 볼 수 있습니다.

```bash
DISPLAY_BACKEND=spice ./setup-winvm-distrobox.sh run
```

다만 Quickemu 문서에는 Windows 10/11 게스트에서 SPICE 표시 방식이 멈춤을 일으킬 수 있다는 알려진 문제가 있습니다. USB 보안토큰이 꼭 필요하다면 SPICE로 시도하되, 멈춤이 있으면 SDL로 되돌리는 편이 낫습니다.

## 왜 Wine/Distrobox만으로는 부족한가

`distrobox`는 Linux 컨테이너입니다. Windows 커널 드라이버, 서비스, 브라우저 보안 모듈, 가상 키보드/인증서 모듈을 Windows처럼 실행하지 못합니다. Wine은 일부 Windows 앱에는 유용하지만, 금융/공공기관 보안 모듈처럼 드라이버와 브라우저 후킹을 쓰는 프로그램은 설치 자체가 안 되거나 설치되어도 사이트 검증을 통과하지 못할 가능성이 큽니다.

## 참고 문서

- Distrobox 공식 문서: https://distrobox.it/
- Distrobox `create` 옵션: https://distrobox.it/usage/distrobox-create/
- Quickemu 설치 문서: https://github.com/quickemu-project/quickemu/wiki/01-Installation
- Quickemu Windows VM 문서: https://github.com/quickemu-project/quickemu/wiki/04-Create-Windows-virtual-machines
- Quickemu 고급 설정: https://github.com/quickemu-project/quickemu/wiki/05-Advanced-quickemu-configuration
