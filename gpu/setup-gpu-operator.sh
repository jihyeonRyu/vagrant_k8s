#!/usr/bin/env bash
#
# setup-gpu-operator.sh - NVIDIA GPU Operator 설치
#
# 이 스크립트는 Control Plane 노드에서 실행됩니다.
# GPU Operator는 K8s에서 GPU 리소스를 관리합니다.
#

set -e

echo "=========================================="
echo "NVIDIA GPU Operator 설치"
echo "=========================================="

# ============================================
# Helm 설치
# ============================================
echo "[1/4] Helm 설치..."

if ! command -v helm &> /dev/null; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
    echo "  Helm이 이미 설치되어 있습니다."
fi

helm version

# ============================================
# 노드 Ready 대기
# ============================================
echo "[2/4] 노드 Ready 상태 대기..."

# 최대 5분 대기
TIMEOUT=300
ELAPSED=0
while true; do
    READY_NODES=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo "0")
    TOTAL_NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    
    echo "  Ready 노드: ${READY_NODES}/${TOTAL_NODES}"
    
    if [[ "$READY_NODES" -gt 0 ]]; then
        break
    fi
    
    if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
        echo "Warning: 타임아웃. 일부 노드가 아직 Ready가 아닐 수 있습니다."
        break
    fi
    
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

# ============================================
# GPU Operator Helm 저장소 추가
# ============================================
echo "[3/4] GPU Operator Helm 저장소 추가..."

helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update

# ============================================
# GPU Operator 설치
# ============================================
echo "[4/4] GPU Operator 설치..."

# 네임스페이스 생성
kubectl create namespace gpu-operator 2>/dev/null || true

# GPU Operator 설치
# - driver.enabled=false: VM에 이미 드라이버가 설치됨
# - toolkit.enabled=false: VM에 이미 Container Toolkit이 설치됨
helm upgrade --install gpu-operator nvidia/gpu-operator \
    --namespace gpu-operator \
    --set driver.enabled=false \
    --set toolkit.enabled=false \
    --set devicePlugin.enabled=true \
    --set gfd.enabled=true \
    --set migManager.enabled=false \
    --set dcgmExporter.enabled=true \
    --wait \
    --timeout 10m

# ============================================
# NFS Subdir External Provisioner 설치
# ============================================
echo "[5/5] NFS StorageClass 설치..."

# NFS 서버는 호스트(물리 머신)에서 실행됨 (setup-host-nfs.sh)
# 호스트의 vagrant-libvirt 브릿지 IP = 192.168.122.1
HOST_NFS_IP="192.168.122.1"

helm repo add nfs-subdir https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner
helm repo update

helm upgrade --install nfs-provisioner nfs-subdir/nfs-subdir-external-provisioner \
    --set nfs.server=${HOST_NFS_IP} \
    --set nfs.path=/srv/nfs/k8s \
    --set storageClass.name=nfs \
    --set storageClass.defaultClass=false \
    --set storageClass.reclaimPolicy=Retain \
    --set image.repository=registry.k8s.io/sig-storage/nfs-subdir-external-provisioner \
    --set image.tag=v4.0.2 \
    --wait \
    --timeout 3m

echo "  NFS StorageClass 설치 완료"
kubectl get storageclass nfs

echo ""
echo "=========================================="
echo "GPU Operator + NFS StorageClass 설치 완료!"
echo "=========================================="
echo ""
echo "설치된 컴포넌트 확인:"
kubectl get pods -n gpu-operator
echo ""
echo "StorageClass 확인:"
kubectl get storageclass
echo ""
echo "GPU 노드 라벨 확인 (잠시 후 적용됨):"
echo "  kubectl get nodes -L nvidia.com/gpu.present"

