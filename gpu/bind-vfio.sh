#!/usr/bin/env bash
#
# bind-vfio.sh - GPU를 VFIO 드라이버에 바인딩
#
# 사용법: sudo ./bind-vfio.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# /vagrant (VM 내부) 또는 스크립트 디렉토리에서 설정 파일 찾기
if [[ -f "/vagrant/gpu-config.yaml" ]]; then
    CONFIG_FILE="/vagrant/gpu-config.yaml"
elif [[ -f "${SCRIPT_DIR}/gpu-config.yaml" ]]; then
    CONFIG_FILE="${SCRIPT_DIR}/gpu-config.yaml"
else
    CONFIG_FILE="/vagrant/gpu-config.yaml"  # 기본값
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
echo "GPU를 VFIO 드라이버에 바인딩합니다"
echo "=========================================="

# GPU PCI 주소 추출
PCI_ADDRESSES=$(grep -E "pci_address:" "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')
GPU_COUNT=$(echo "$PCI_ADDRESSES" | wc -l)

echo "설정된 GPU: ${GPU_COUNT}개"
echo "$PCI_ADDRESSES"
echo ""

# [1/6] GPU 사용 프로세스 확인
echo "[1/6] GPU 사용 프로세스 확인 중..."
GPU_PROCS=$(lsof /dev/nvidia* 2>/dev/null | grep -v "^COMMAND" || true)
if [[ -n "$GPU_PROCS" ]]; then
    echo "Error: GPU를 사용 중인 프로세스가 있습니다:"
    echo "$GPU_PROCS" | head -10
    echo ""
    echo "다음 명령으로 프로세스를 종료하세요:"
    echo "  sudo systemctl stop containerd nvidia-fabricmanager nvidia-persistenced"
    echo "  sudo lsof /dev/nvidia* 2>/dev/null | awk 'NR>1 {print \$2}' | sort -u | xargs -r sudo kill -9"
    exit 1
fi
echo "  ✓ GPU를 사용 중인 프로세스 없음"

# [2/6] NVIDIA 드라이버 모듈 언로드
echo "[2/6] NVIDIA 드라이버 모듈 언로드 중..."
for mod in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
    if lsmod | grep -q "^${mod}"; then
        echo "  언로드: ${mod}"
        rmmod ${mod} 2>/dev/null || true
    fi
done

# [3/6] 모든 GPU를 먼저 드라이버에서 해제
echo "[3/6] 모든 GPU 드라이버 해제 중..."
for PCI_ADDR in $PCI_ADDRESSES; do
    DEVICE_PATH="/sys/bus/pci/devices/${PCI_ADDR}"
    
    if [[ ! -d "$DEVICE_PATH" ]]; then
        echo "  Skip: ${PCI_ADDR} (디바이스가 존재하지 않음)"
        continue
    fi
    
    # driver_override 초기화
    echo "" > "${DEVICE_PATH}/driver_override" 2>/dev/null || true
    
    # 현재 드라이버에서 언바인드
    if [[ -e "${DEVICE_PATH}/driver/unbind" ]]; then
        echo "${PCI_ADDR}" > "${DEVICE_PATH}/driver/unbind" 2>/dev/null || true
        echo "  해제: ${PCI_ADDR}"
    else
        echo "  Skip: ${PCI_ADDR} (이미 언바인드됨)"
    fi
done
sleep 1

# [4/6] VFIO 모듈 로드
echo "[4/6] VFIO 커널 모듈 로드 중..."
modprobe vfio
modprobe vfio_pci
modprobe vfio_iommu_type1

# [5/6] IOMMU 확인
echo "[5/6] IOMMU 활성화 상태 확인 중..."
IOMMU_GROUPS=$(ls /sys/kernel/iommu_groups/ 2>/dev/null | wc -l)
if [[ "$IOMMU_GROUPS" -eq 0 ]]; then
    echo "Error: IOMMU 그룹이 없습니다!"
    echo "BIOS에서 VT-d를 활성화하고, 커널 파라미터에 intel_iommu=on을 추가하세요."
    exit 1
fi
echo "  ✓ IOMMU 그룹: ${IOMMU_GROUPS}개"

# [6/6] GPU를 VFIO에 바인딩
echo "[6/6] GPU를 VFIO에 바인딩 중..."

BIND_SUCCESS=0
BIND_FAIL=0

for PCI_ADDR in $PCI_ADDRESSES; do
    DEVICE_PATH="/sys/bus/pci/devices/${PCI_ADDR}"
    
    if [[ ! -d "$DEVICE_PATH" ]]; then
        echo "  ✗ Skip: ${PCI_ADDR} (디바이스가 존재하지 않음)"
        ((BIND_FAIL++))
        continue
    fi
    
    # 현재 드라이버 확인
    CURRENT_DRIVER=$(basename "$(readlink -f "${DEVICE_PATH}/driver")" 2>/dev/null || echo "none")
    
    if [[ "$CURRENT_DRIVER" == "vfio-pci" ]]; then
        echo "  ✓ Skip: ${PCI_ADDR} (이미 VFIO에 바인딩됨)"
        ((BIND_SUCCESS++))
        continue
    fi
    
    echo "  바인딩 중: ${PCI_ADDR}"
    
    # 혹시 바인딩되어 있으면 해제
    if [[ "$CURRENT_DRIVER" != "none" && -e "${DEVICE_PATH}/driver/unbind" ]]; then
        echo "${PCI_ADDR}" > "${DEVICE_PATH}/driver/unbind" 2>/dev/null || true
        sleep 0.3
    fi
    
    # driver_override로 vfio-pci 지정
    echo "vfio-pci" > "${DEVICE_PATH}/driver_override" 2>/dev/null || {
        echo "    ✗ driver_override 설정 실패"
        ((BIND_FAIL++))
        continue
    }
    
    # PCI 디바이스 재스캔 (선택적)
    echo 1 > /sys/bus/pci/rescan 2>/dev/null || true
    sleep 0.3
    
    # vfio-pci에 바인딩 시도
    echo "${PCI_ADDR}" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || {
        # 실패 시 probe 시도
        echo "${PCI_ADDR}" > /sys/bus/pci/drivers_probe 2>/dev/null || true
    }
    
    sleep 0.3
    
    # 바인딩 확인
    NEW_DRIVER=$(basename "$(readlink -f "${DEVICE_PATH}/driver")" 2>/dev/null || echo "none")
    
    if [[ "$NEW_DRIVER" == "vfio-pci" ]]; then
        echo "    ✓ 완료: ${PCI_ADDR} -> vfio-pci"
        ((BIND_SUCCESS++))
    else
        echo "    ✗ 실패: ${PCI_ADDR} (현재 드라이버: ${NEW_DRIVER})"
        # dmesg에서 에러 확인
        dmesg | tail -3 | grep -i "vfio\|${PCI_ADDR}" || true
        ((BIND_FAIL++))
    fi
done

echo ""
echo "=========================================="
if [[ $BIND_FAIL -eq 0 ]]; then
    echo "GPU VFIO 바인딩 완료! (${BIND_SUCCESS}/${GPU_COUNT}개 성공)"
else
    echo "GPU VFIO 바인딩 완료 (${BIND_SUCCESS}/${GPU_COUNT}개 성공, ${BIND_FAIL}개 실패)"
fi
echo "=========================================="
echo ""

echo "현재 드라이버 상태:"
for PCI_ADDR in $PCI_ADDRESSES; do
    DEVICE_PATH="/sys/bus/pci/devices/${PCI_ADDR}"
    DRIVER=$(basename "$(readlink -f "${DEVICE_PATH}/driver")" 2>/dev/null || echo "none")
    echo "  ${PCI_ADDR}: ${DRIVER}"
done
echo ""

if [[ $BIND_SUCCESS -gt 0 ]]; then
    echo "이제 'vagrant up'으로 VM을 시작할 수 있습니다."
    echo "테스트 완료 후 'sudo ./unbind-vfio.sh'로 GPU를 복원하세요."
fi

if [[ $BIND_FAIL -gt 0 ]]; then
    echo ""
    echo "일부 GPU 바인딩 실패. dmesg 확인:"
    echo "  sudo dmesg | grep -i vfio | tail -10"
fi
