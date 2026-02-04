#!/usr/bin/env bash
#
# unbind-vfio.sh - GPU를 VFIO에서 분리하고 NVIDIA 드라이버로 복원
#
# 사용법: sudo ./unbind-vfio.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# /vagrant (VM 내부) 또는 스크립트 디렉토리에서 설정 파일 찾기
if [[ -f "/vagrant/gpu-config.yaml" ]]; then
    CONFIG_FILE="/vagrant/gpu-config.yaml"
elif [[ -f "${SCRIPT_DIR}/gpu-config.yaml" ]]; then
    CONFIG_FILE="${SCRIPT_DIR}/gpu-config.yaml"
else
    CONFIG_FILE="${SCRIPT_DIR}/gpu-config.yaml"  # 기본값
fi

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

# GPU PCI 주소 추출
PCI_ADDRESSES=$(grep -E "pci_address:" "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')
GPU_COUNT=$(echo "$PCI_ADDRESSES" | wc -l)

echo "설정된 GPU: ${GPU_COUNT}개"
echo ""

# [1/4] VM 실행 상태 확인
echo "[1/4] VM 실행 상태 확인 중..."
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

# [2/4] 모든 GPU를 vfio-pci에서 해제
echo "[2/4] GPU를 VFIO에서 해제 중..."
for PCI_ADDR in $PCI_ADDRESSES; do
    DEVICE_PATH="/sys/bus/pci/devices/${PCI_ADDR}"
    
    if [[ ! -d "$DEVICE_PATH" ]]; then
        continue
    fi
    
    CURRENT_DRIVER=$(basename "$(readlink -f "${DEVICE_PATH}/driver")" 2>/dev/null || echo "none")
    
    if [[ "$CURRENT_DRIVER" == "vfio-pci" ]]; then
        echo "  해제: ${PCI_ADDR}"
        echo "${PCI_ADDR}" > /sys/bus/pci/drivers/vfio-pci/unbind 2>/dev/null || true
    fi
    
    # driver_override 초기화 (중요!)
    echo "" > "${DEVICE_PATH}/driver_override" 2>/dev/null || true
done
sleep 1

# [3/4] NVIDIA 드라이버 모듈 로드
echo "[3/4] NVIDIA 드라이버 모듈 로드 중..."
modprobe nvidia 2>/dev/null || true
modprobe nvidia_uvm 2>/dev/null || true
modprobe nvidia_modeset 2>/dev/null || true
modprobe nvidia_drm 2>/dev/null || true
sleep 1

# [4/4] GPU를 NVIDIA 드라이버에 바인딩
echo "[4/4] GPU를 NVIDIA 드라이버에 바인딩 중..."

RESTORE_SUCCESS=0
RESTORE_FAIL=0

for PCI_ADDR in $PCI_ADDRESSES; do
    DEVICE_PATH="/sys/bus/pci/devices/${PCI_ADDR}"
    
    if [[ ! -d "$DEVICE_PATH" ]]; then
        echo "  ✗ ${PCI_ADDR}: 디바이스가 존재하지 않음"
        ((RESTORE_FAIL++))
        continue
    fi
    
    CURRENT_DRIVER=$(basename "$(readlink -f "${DEVICE_PATH}/driver")" 2>/dev/null || echo "none")
    
    if [[ "$CURRENT_DRIVER" == "nvidia" ]]; then
        echo "  ✓ ${PCI_ADDR}: 이미 nvidia에 바인딩됨"
        ((RESTORE_SUCCESS++))
        continue
    fi
    
    echo "  바인딩 중: ${PCI_ADDR}"
    
    # 드라이버에서 해제
    if [[ "$CURRENT_DRIVER" != "none" && -e "${DEVICE_PATH}/driver/unbind" ]]; then
        echo "${PCI_ADDR}" > "${DEVICE_PATH}/driver/unbind" 2>/dev/null || true
        sleep 0.3
    fi
    
    # driver_override 초기화
    echo "" > "${DEVICE_PATH}/driver_override" 2>/dev/null || true
    
    # nvidia 드라이버에 바인딩 시도
    echo "${PCI_ADDR}" > /sys/bus/pci/drivers/nvidia/bind 2>/dev/null || {
        # 실패 시 drivers_probe로 재탐색
        echo "${PCI_ADDR}" > /sys/bus/pci/drivers_probe 2>/dev/null || true
    }
    
    sleep 0.5
    
    # 확인
    NEW_DRIVER=$(basename "$(readlink -f "${DEVICE_PATH}/driver")" 2>/dev/null || echo "none")
    
    if [[ "$NEW_DRIVER" == "nvidia" ]]; then
        echo "    ✓ 완료: ${PCI_ADDR} -> nvidia"
        ((RESTORE_SUCCESS++))
    else
        echo "    ✗ 실패: ${PCI_ADDR} (현재: ${NEW_DRIVER})"
        ((RESTORE_FAIL++))
    fi
done

echo ""
echo "=========================================="
echo "GPU 복원 완료! (${RESTORE_SUCCESS}/${GPU_COUNT}개 성공)"
echo "=========================================="

# NVIDIA 드라이버 상태 확인
echo ""
echo "NVIDIA 드라이버 상태 확인:"
sleep 1
if command -v nvidia-smi &> /dev/null; then
    nvidia-smi --query-gpu=index,name,driver_version --format=csv 2>/dev/null || {
        echo "  nvidia-smi 실행 실패"
        echo "  'sudo modprobe nvidia' 후 다시 시도하세요."
    }
else
    echo "  nvidia-smi 명령을 찾을 수 없습니다."
fi

echo ""
if [[ $RESTORE_FAIL -gt 0 ]]; then
    echo "일부 GPU 복원 실패. 재부팅을 권장합니다: sudo reboot"
else
    echo "GPU가 호스트에서 다시 사용 가능합니다."
    echo ""
    echo "NVIDIA 서비스 재시작:"
    echo "  sudo systemctl start nvidia-fabricmanager nvidia-persistenced"
fi
