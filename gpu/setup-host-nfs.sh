#!/usr/bin/env bash
#
# setup-host-nfs.sh - 호스트(물리 머신)에서 NFS 서버 설정
#
# vagrant up 전에 호스트에서 한 번만 실행하면 됩니다.
# VM들이 이 NFS를 모델 캐시 공유 스토리지로 사용합니다.
#
# 사용법:
#   sudo ./setup-host-nfs.sh
#

set -e

NFS_PATH="/srv/nfs/k8s"
NETWORK="192.168.122.0/24"

echo "=========================================="
echo "호스트 NFS 서버 설정"
echo "=========================================="
echo "NFS Export: ${NFS_PATH}"
echo "Network:    ${NETWORK}"
echo ""

# Root 권한 확인
if [[ $EUID -ne 0 ]]; then
    echo "Error: root 권한이 필요합니다. sudo로 실행하세요."
    exit 1
fi

# ============================================
# NFS 서버 설치
# ============================================
echo "[1/4] NFS 서버 설치..."

# RHEL/CentOS/Rocky
if command -v yum &>/dev/null || command -v dnf &>/dev/null; then
    yum install -y nfs-utils 2>/dev/null || dnf install -y nfs-utils
# Ubuntu/Debian
elif command -v apt-get &>/dev/null; then
    apt-get install -y nfs-kernel-server nfs-common
else
    echo "Error: 지원하지 않는 OS입니다."
    exit 1
fi

# ============================================
# NFS Export 디렉토리 생성
# ============================================
echo "[2/4] NFS export 디렉토리 생성..."

mkdir -p "${NFS_PATH}"
chmod 777 "${NFS_PATH}"

# ============================================
# /etc/exports 설정
# ============================================
echo "[3/4] /etc/exports 설정..."

if grep -q "${NFS_PATH}" /etc/exports 2>/dev/null; then
    echo "  이미 설정되어 있습니다. 스킵."
else
    echo "${NFS_PATH} ${NETWORK}(rw,sync,no_subtree_check,no_root_squash)" >> /etc/exports
    echo "  Export 추가 완료."
fi

exportfs -ra

# ============================================
# NFS 서버 시작
# ============================================
echo "[4/4] NFS 서버 시작..."

systemctl enable nfs-server 2>/dev/null || systemctl enable nfs-kernel-server 2>/dev/null || true
systemctl start nfs-server 2>/dev/null || systemctl start nfs-kernel-server 2>/dev/null || true

# 방화벽 설정 (firewalld가 있는 경우)
if command -v firewall-cmd &>/dev/null; then
    echo "  방화벽 설정..."
    firewall-cmd --permanent --add-service=nfs 2>/dev/null || true
    firewall-cmd --permanent --add-service=rpc-bind 2>/dev/null || true
    firewall-cmd --permanent --add-service=mountd 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
fi

echo ""
echo "=========================================="
echo "NFS 서버 설정 완료!"
echo "=========================================="
echo ""
echo "Export 확인:"
exportfs -v
echo ""
echo "디스크 여유:"
df -h "${NFS_PATH}"
echo ""
echo "다음 단계:"
echo "  1. vagrant up    # VM 생성/시작"
echo "  2. VM에서 자동으로 NFS provisioner가 이 서버에 연결됩니다."
echo ""
echo "참고: H100 SXM GPU 사용 시 Fabric Manager도 필요합니다:"
echo "  sudo systemctl start nvidia-fabricmanager"
