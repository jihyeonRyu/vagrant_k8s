#!/usr/bin/env bash
#
# unbind-vfio.sh - GPU를 VFIO에서 분리하고 NVIDIA 드라이버로 복원
#
# 이 스크립트는 테스트 종료 후에 실행합니다.
# GPU가 nvidia 드라이버에 다시 바인딩되어 호스트에서 사용할 수 있습니다.
#
# 사용법: sudo ./unbind-vfio.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/gpu-config.yaml"

# Root 권한 확인
if [[ $EUID -ne 0 ]]; then
   echo "Error: 이 스크립트는 root 권한으로 실행해야 합니다."
   echo "Usage: sudo $0"
   exit 1
fi

# 설정 파일 확인
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: 설정 파일을 찾을 수 없습니다: $CONFIG_FILE"
    exit 1
fi

echo "=========================================="
echo "GPU를 NVIDIA 드라이버로 복원합니다"
echo "=========================================="

# VM이 실행 중인지 확인
echo "[1/3] VM 실행 상태 확인 중..."
if command -v virsh &> /dev/null; then
    RUNNING_VMS=$(virsh list --name 2>/dev/null | grep -E "gpu-" || true)
    if [[ -n "$RUNNING_VMS" ]]; then
        echo "Warning: 다음 VM이 아직 실행 중입니다:"
        echo "$RUNNING_VMS"
        echo ""
        echo "먼저 'vagrant destroy -f'로 VM을 종료하세요."
        echo "계속 진행하시겠습니까? [y/N]"
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
fi

# GPU PCI 주소 추출
echo "[2/3] GPU PCI 주소 추출 중..."
PCI_ADDRESSES=$(grep -E "pci_address:|audio_address:" "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')

echo "[3/3] GPU를 NVIDIA 드라이버로 복원 중..."

for PCI_ADDR in $PCI_ADDRESSES; do
    DEVICE_PATH="/sys/bus/pci/devices/${PCI_ADDR}"
    
    if [[ ! -d "$DEVICE_PATH" ]]; then
        echo "  Skip: ${PCI_ADDR} (디바이스가 존재하지 않음)"
        continue
    fi
    
    # 현재 드라이버 확인
    CURRENT_DRIVER=$(basename "$(readlink -f "${DEVICE_PATH}/driver")" 2>/dev/null || echo "none")
    
    if [[ "$CURRENT_DRIVER" == "nvidia" ]] || [[ "$CURRENT_DRIVER" == "snd_hda_intel" ]]; then
        echo "  Skip: ${PCI_ADDR} (이미 원래 드라이버에 바인딩됨: ${CURRENT_DRIVER})"
        continue
    fi
    
    echo "  언바인딩 중: ${PCI_ADDR} (현재 드라이버: ${CURRENT_DRIVER})"
    
    # VFIO에서 언바인드
    if [[ "$CURRENT_DRIVER" == "vfio-pci" ]]; then
        echo "${PCI_ADDR}" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
    fi
    
    # 디바이스 클래스 확인 (GPU vs Audio)
    DEVICE_CLASS=$(cat "${DEVICE_PATH}/class" 2>/dev/null || echo "")
    
    # 드라이버 재탐색 트리거
    echo "${PCI_ADDR}" > /sys/bus/pci/drivers_probe 2>/dev/null || true
    
    sleep 0.5
    
    # 새 드라이버 확인
    NEW_DRIVER=$(basename "$(readlink -f "${DEVICE_PATH}/driver")" 2>/dev/null || echo "none")
    echo "    완료: ${PCI_ADDR} -> ${NEW_DRIVER}"
done

echo ""
echo "=========================================="
echo "GPU 복원 완료!"
echo "=========================================="

# NVIDIA 드라이버 상태 확인
echo ""
echo "NVIDIA 드라이버 상태 확인:"
if command -v nvidia-smi &> /dev/null; then
    echo ""
    nvidia-smi --query-gpu=index,name,driver_version --format=csv 2>/dev/null || echo "  nvidia-smi 실행 실패 (드라이버 로딩 중일 수 있음)"
else
    echo "  nvidia-smi 명령을 찾을 수 없습니다."
fi

echo ""
echo "GPU가 호스트에서 다시 사용 가능합니다."
echo "문제가 있으면 'sudo modprobe nvidia' 또는 재부팅을 시도하세요."
