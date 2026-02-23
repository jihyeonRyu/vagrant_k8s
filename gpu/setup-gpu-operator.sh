#!/usr/bin/env bash
#
# setup-gpu-operator.sh - Monitoring + NVIDIA GPU Operator 설치
#
# 이 스크립트는 Control Plane 노드에서 실행됩니다.
# 1. kube-prometheus-stack (Prometheus + Grafana) 설치
# 2. GPU Operator 설치 (DCGM ServiceMonitor 포함)
#

set -e

echo "=========================================="
echo "Monitoring + NVIDIA GPU Operator 설치"
echo "=========================================="

# ============================================
# Helm 설치
# ============================================
echo "[1/7] Helm 설치..."

if ! command -v helm &> /dev/null; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
    echo "  Helm이 이미 설치되어 있습니다."
fi

helm version

# ============================================
# 노드 Ready 대기
# ============================================
echo "[2/7] 노드 Ready 상태 대기..."

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
# ingress-nginx 설치 (K8s on-prem only)
# ============================================
echo "[3/7] ingress-nginx 설치..."

if kubectl get ns ingress-nginx >/dev/null 2>&1; then
    echo "  ingress-nginx가 이미 설치되어 있습니다. 건너뜁니다."
else
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx \
        --create-namespace \
        --set controller.service.type=NodePort \
        --wait \
        --timeout 5m
    echo "  ✅ ingress-nginx 설치 완료"
fi

# ============================================
# kube-prometheus-stack 설치 (Prometheus + Grafana)
# - GPU Operator보다 먼저 설치해야 ServiceMonitor CRD가 존재함
# - DCGM Exporter ServiceMonitor가 정상 생성되려면 필수
# ============================================
echo "[4/7] kube-prometheus-stack 설치..."

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update

if helm list -n monitoring -q 2>/dev/null | grep -q prometheus; then
    echo "  kube-prometheus-stack이 이미 설치되어 있습니다. 건너뜁니다."
else
    helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --create-namespace \
        --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
        --set-json 'prometheus.prometheusSpec.podMonitorNamespaceSelector={}' \
        --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
        --set-json 'prometheus.prometheusSpec.serviceMonitorNamespaceSelector={}' \
        --set-json 'prometheus.prometheusSpec.probeNamespaceSelector={}' \
        --set grafana.adminPassword=admin \
        --set alertmanager.enabled=false \
        --wait \
        --timeout 10m

    echo "  ✅ kube-prometheus-stack 설치 완료"
fi

# ServiceMonitor CRD 확인
kubectl get crd servicemonitors.monitoring.coreos.com > /dev/null 2>&1 && \
    echo "  ✅ ServiceMonitor CRD 확인됨" || \
    echo "  ⚠️  ServiceMonitor CRD를 찾을 수 없습니다"

# ============================================
# GPU Operator Helm 저장소 추가
# ============================================
echo "[5/7] GPU Operator Helm 저장소 추가..."

helm repo add nvidia https://helm.ngc.nvidia.com/nvidia --force-update
helm repo update

# ============================================
# GPU Operator 설치
# - driver.enabled=false: VM에 이미 드라이버가 설치됨
# - toolkit.enabled=false: VM에 이미 Container Toolkit이 설치됨
# - dcgmExporter.serviceMonitor.enabled=true: Prometheus 연동
# ============================================
echo "[6/7] GPU Operator 설치..."

kubectl create namespace gpu-operator 2>/dev/null || true

helm upgrade --install gpu-operator nvidia/gpu-operator \
    --namespace gpu-operator \
    --set driver.enabled=false \
    --set toolkit.enabled=false \
    --set devicePlugin.enabled=true \
    --set gfd.enabled=true \
    --set migManager.enabled=true \
    --set dcgmExporter.enabled=true \
    --set dcgmExporter.serviceMonitor.enabled=true \
    --set dcgmExporter.serviceMonitor.interval=15s \
    --wait \
    --timeout 10m

# ============================================
# NFS Subdir External Provisioner 설치
# ============================================
echo "[7/7] NFS StorageClass 설치..."

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
echo "Infra Stack 설치 완료!"
echo "=========================================="
echo ""
echo "Monitoring:"
kubectl get pods -n monitoring --no-headers 2>/dev/null | head -5
echo ""
echo "GPU Operator:"
kubectl get pods -n gpu-operator --no-headers 2>/dev/null | head -5
echo ""
echo "StorageClass:"
kubectl get storageclass --no-headers
echo ""
NODEPORT=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || echo "N/A")
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo "<node-ip>")
echo "Ingress: http://${NODE_IP}:${NODEPORT}"
echo "Grafana: http://${NODE_IP}:${NODEPORT}/grafana (admin/admin)"

