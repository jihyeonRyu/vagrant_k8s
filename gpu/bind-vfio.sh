#!/usr/bin/env bash
#
# bind-vfio.sh - GPU를 VFIO 드라이버에 바인딩
#
# 이 스크립트는 테스트 시작 전에 실행합니다.
# GPU가 VFIO에 바인딩되면 호스트에서 GPU를 사용할 수 없습니다.
#
# 사용법: sudo ./bind-vfio.sh
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
    echo "gpu-config.yaml 파일을 먼저 설정하세요."
    exit 1
fi

echo "=========================================="
echo "GPU를 VFIO 드라이버에 바인딩합니다"
echo "=========================================="

# VFIO 모듈 로드
echo "[1/4] VFIO 커널 모듈 로드 중..."
modprobe vfio
modprobe vfio_pci
modprobe vfio_iommu_type1

# IOMMU 활성화 확인
echo "[2/4] IOMMU 활성화 상태 확인 중..."
if ! dmesg | grep -q "IOMMU enabled"; then
    echo "Warning: IOMMU가 활성화되지 않은 것 같습니다."
    echo "GRUB에 intel_iommu=on (Intel) 또는 amd_iommu=on (AMD)를 추가하세요."
    echo "계속 진행하시겠습니까? [y/N]"
    read -r response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# GPU 디바이스 ID 추출 (yaml 파일에서)
echo "[3/4] GPU 디바이스 ID 추출 중..."
GPU_DEVICE_IDS=$(grep -A 10 "gpu_device_ids:" "$CONFIG_FILE" | grep '^\s*-' | sed 's/.*"\(.*\)".*/\1/' | head -10)

if [[ -z "$GPU_DEVICE_IDS" ]]; then
    echo "Error: gpu-config.yaml에서 GPU 디바이스 ID를 찾을 수 없습니다."
    exit 1
fi

echo "발견된 GPU 디바이스 ID:"
echo "$GPU_DEVICE_IDS"

# GPU PCI 주소 추출
echo ""
echo "[4/4] GPU를 VFIO에 바인딩 중..."

# yaml에서 PCI 주소 추출
PCI_ADDRESSES=$(grep -E "pci_address:|audio_address:" "$CONFIG_FILE" | sed 's/.*"\(.*\)".*/\1/')

for PCI_ADDR in $PCI_ADDRESSES; do
    # PCI 주소 형식 변환 (0000:41:00.0 -> 0000:41:00.0)
    DEVICE_PATH="/sys/bus/pci/devices/${PCI_ADDR}"
    
    if [[ ! -d "$DEVICE_PATH" ]]; then
        echo "  Skip: ${PCI_ADDR} (디바이스가 존재하지 않음)"
        continue
    fi
    
    # 현재 드라이버 확인
    CURRENT_DRIVER=$(basename "$(readlink -f "${DEVICE_PATH}/driver")" 2>/dev/null || echo "none")
    
    if [[ "$CURRENT_DRIVER" == "vfio-pci" ]]; then
        echo "  Skip: ${PCI_ADDR} (이미 VFIO에 바인딩됨)"
        continue
    fi
    
    echo "  바인딩 중: ${PCI_ADDR} (현재 드라이버: ${CURRENT_DRIVER})"
    
    # 기존 드라이버에서 언바인드
    if [[ "$CURRENT_DRIVER" != "none" ]]; then
        echo "${PCI_ADDR}" > "${DEVICE_PATH}/driver/unbind" 2>/dev/null || true
    fi
    
    # 벤더/디바이스 ID 가져오기
    VENDOR=$(cat "${DEVICE_PATH}/vendor" | sed 's/0x//')
    DEVICE=$(cat "${DEVICE_PATH}/device" | sed 's/0x//')
    
    # VFIO에 새 디바이스 ID 등록 및 바인딩
    echo "${VENDOR} ${DEVICE}" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null || true
    echo "${PCI_ADDR}" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true
    
    echo "    완료: ${PCI_ADDR} -> vfio-pci"
done

echo ""
echo "=========================================="
echo "GPU VFIO 바인딩 완료!"
echo "=========================================="
echo ""
echo "현재 VFIO에 바인딩된 디바이스:"
ls -la /sys/bus/pci/drivers/vfio-pci/ 2>/dev/null | grep -E "^l" | awk '{print $NF}' || echo "  (없음)"
echo ""
echo "이제 'vagrant up'으로 VM을 시작할 수 있습니다."
echo "테스트 완료 후 'sudo ./unbind-vfio.sh'로 GPU를 복원하세요."
