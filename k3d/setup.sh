#!/usr/bin/env bash
#
# setup.sh - k3d GPU 멀티노드 클러스터 생성
#
# 각 Worker(agent) 노드에 다른 GPU를 할당하여 프로덕션 유사 환경을 구성합니다.
# 기존 k3s 클러스터와 충돌 없이 공존합니다.
#
# 사용법: ./setup.sh [WORKER_COUNT] [GPU_PER_WORKER]
#   예: ./setup.sh 2 4    # 2개 Worker, 각 4 GPU
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-gpu-cluster}"
WORKER_COUNT="${1:-2}"
GPU_PER_WORKER="${2:-4}"

echo "=========================================="
echo "k3d GPU 멀티노드 클러스터 생성"
echo "=========================================="
echo "클러스터 이름: ${CLUSTER_NAME}"
echo "Worker(agent) 수: ${WORKER_COUNT}"
echo "Worker당 GPU: ${GPU_PER_WORKER}"
echo ""

# ============================================
# 사전 요구사항 확인
# ============================================
echo "[1/6] 사전 요구사항 확인..."

# Docker 확인
if ! command -v docker &> /dev/null; then
    echo "Error: Docker가 설치되어 있지 않습니다."
    exit 1
fi
echo "  ✓ Docker: $(docker --version | cut -d' ' -f3 | tr -d ',')"

# k3d 확인
if ! command -v k3d &> /dev/null; then
    echo "Error: k3d가 설치되어 있지 않습니다."
    echo ""
    echo "설치 방법:"
    echo "  curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash"
    exit 1
fi
echo "  ✓ k3d: $(k3d version | head -1 | awk '{print $3}')"

# kubectl 확인
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl이 설치되어 있지 않습니다."
    exit 1
fi
echo "  ✓ kubectl 설치됨"

# NVIDIA 드라이버 확인
if ! command -v nvidia-smi &> /dev/null; then
    echo "Error: NVIDIA 드라이버가 설치되어 있지 않습니다."
    exit 1
fi
echo "  ✓ NVIDIA Driver: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"

# GPU 수 확인
TOTAL_GPUS=$(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)
REQUIRED_GPUS=$((WORKER_COUNT * GPU_PER_WORKER))
echo "  ✓ 총 GPU: ${TOTAL_GPUS}개"

if [[ "$REQUIRED_GPUS" -gt "$TOTAL_GPUS" ]]; then
    echo "Error: GPU가 부족합니다. 필요: ${REQUIRED_GPUS}, 보유: ${TOTAL_GPUS}"
    exit 1
fi

# NVIDIA Container Toolkit 확인
if ! docker run --rm --gpus all nvcr.io/nvidia/pytorch:24.07-py3 nvidia-smi &> /dev/null; then
    echo "Error: Docker에서 GPU를 사용할 수 없습니다."
    echo "NVIDIA Container Toolkit을 설치하세요."
    exit 1
fi
echo "  ✓ NVIDIA Container Toolkit: 작동 확인"

# ============================================
# 기존 클러스터 확인
# ============================================
echo ""
echo "[2/6] 기존 클러스터 확인..."

if k3d cluster list 2>/dev/null | grep -q "^${CLUSTER_NAME} "; then
    echo "Warning: 클러스터 '${CLUSTER_NAME}'가 이미 존재합니다."
    echo "삭제하고 다시 생성하시겠습니까? [y/N]"
    read -r response
    if [[ "$response" =~ ^[Yy]$ ]]; then
        k3d cluster delete "${CLUSTER_NAME}"
    else
        echo "취소되었습니다."
        exit 0
    fi
fi

# ============================================
# k3d 설정 파일 동적 생성
# ============================================
echo ""
echo "[3/6] k3d 설정 생성 중..."

CONFIG_FILE="${SCRIPT_DIR}/k3d-config-generated.yaml"

cat > "$CONFIG_FILE" << EOF
# 자동 생성된 k3d 설정 파일
apiVersion: k3d.io/v1alpha5
kind: Simple
metadata:
  name: ${CLUSTER_NAME}

servers: 1

agents: ${WORKER_COUNT}

image: rancher/k3s:v1.29.0-k3s1

# API 포트 (기존 k3s와 충돌 방지)
kubeAPI:
  hostPort: "6550"

# 포트 매핑
ports: []

# 볼륨 마운트
volumes: []

# k3s 옵션
options:
  k3s:
    extraArgs:
      - arg: --disable=traefik
        nodeFilters:
          - server:*
EOF

echo "  설정 파일 생성: ${CONFIG_FILE}"

# ============================================
# k3d 클러스터 생성
# ============================================
echo ""
echo "[4/6] k3d 클러스터 생성 중..."

# 클러스터 생성
k3d cluster create "${CLUSTER_NAME}" --config "$CONFIG_FILE"

# GPU 지원을 위해 노드 컨테이너 업데이트
echo "  GPU 접근 설정 중..."
for container in $(docker ps --filter "name=k3d-${CLUSTER_NAME}" --format "{{.Names}}"); do
    # 컨테이너 ID 가져오기
    echo "    ${container}: GPU 디바이스 확인..."
done

# kubeconfig 가져오기
k3d kubeconfig merge "${CLUSTER_NAME}" --kubeconfig-switch-context

echo "  클러스터 생성 완료"

# ============================================
# Worker 노드에 GPU 격리 설정
# ============================================
echo ""
echo "[5/6] Worker 노드에 GPU 격리 설정 중..."

# 노드 목록 가져오기
sleep 3  # 노드가 준비될 때까지 대기

GPU_INDEX=0
for ((i=0; i<WORKER_COUNT; i++)); do
    CONTAINER_NAME="k3d-${CLUSTER_NAME}-agent-${i}"
    
    # GPU 인덱스 목록 생성 (쉼표 버전: 환경변수용)
    START_GPU=$GPU_INDEX
    END_GPU=$((GPU_INDEX + GPU_PER_WORKER - 1))
    GPU_LIST=""
    GPU_LABEL=""  # 라벨용 (쉼표 대신 하이픈)
    for ((g=START_GPU; g<=END_GPU; g++)); do
        if [[ -n "$GPU_LIST" ]]; then
            GPU_LIST="${GPU_LIST},"
            GPU_LABEL="${GPU_LABEL}-"
        fi
        GPU_LIST="${GPU_LIST}${g}"
        GPU_LABEL="${GPU_LABEL}${g}"
    done
    
    echo "  Agent ${i} (${CONTAINER_NAME}): GPU ${GPU_LIST} 설정..."
    
    # 컨테이너에 GPU 환경변수 설정 (sh 사용)
    docker exec "${CONTAINER_NAME}" sh -c "
        echo 'NVIDIA_VISIBLE_DEVICES=${GPU_LIST}' >> /etc/environment
        echo 'NVIDIA_DRIVER_CAPABILITIES=compute,utility' >> /etc/environment
    " 2>/dev/null || echo "    Warning: 환경변수 설정 실패 (무시 가능)"
    
    # 노드에 라벨 추가 (쉼표 대신 하이픈 사용)
    NODE_NAME=$(kubectl get nodes --no-headers | grep "agent-${i}" | awk '{print $1}')
    if [[ -n "$NODE_NAME" ]]; then
        kubectl label node "$NODE_NAME" gpu-worker="$((i+1))" gpu-ids="${GPU_LABEL}" --overwrite
        echo "    라벨 추가: gpu-worker=$((i+1)), gpu-ids=${GPU_LABEL}"
    fi
    
    GPU_INDEX=$((GPU_INDEX + GPU_PER_WORKER))
done

# ============================================
# NVIDIA Device Plugin 설치
# ============================================
echo ""
echo "[6/6] NVIDIA Device Plugin 설치 중..."

kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.14.5/nvidia-device-plugin.yml

echo ""
echo "Device Plugin이 Ready 상태가 될 때까지 대기 중..."
sleep 5

kubectl wait --for=condition=ready pod -l name=nvidia-device-plugin-ds -n kube-system --timeout=120s 2>/dev/null || true

# ============================================
# 완료
# ============================================
echo ""
echo "=========================================="
echo "k3d GPU 클러스터 생성 완료!"
echo "=========================================="
echo ""
echo "클러스터 정보:"
kubectl get nodes -o wide
echo ""
echo "GPU 노드 라벨:"
kubectl get nodes -L gpu-worker,gpu-ids
echo ""
echo "현재 context:"
kubectl config current-context
echo ""
echo "기존 k3s로 전환하려면:"
echo "  kubectl config use-context default"
echo ""
echo "k3d 클러스터로 전환하려면:"
echo "  kubectl config use-context k3d-${CLUSTER_NAME}"
echo ""
echo "GPU 테스트:"
echo "  kubectl run gpu-test --rm -it --restart=Never \\"
echo "    --image=nvidia/cuda:12.0-base \\"
echo "    --limits=nvidia.com/gpu=1 \\"
echo "    -- nvidia-smi"
echo ""
echo "클러스터 삭제:"
echo "  ./teardown.sh"
