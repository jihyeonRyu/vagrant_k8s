#!/usr/bin/env bash
#
# teardown.sh - k3d GPU 클러스터 삭제
#
# 기존 k3s 클러스터는 영향받지 않습니다.
#
# 사용법: ./teardown.sh [CLUSTER_NAME]
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_NAME="${1:-gpu-cluster}"

echo "=========================================="
echo "k3d GPU 클러스터 삭제"
echo "=========================================="
echo "클러스터 이름: ${CLUSTER_NAME}"
echo ""

# k3d 확인
if ! command -v k3d &> /dev/null; then
    echo "Error: k3d가 설치되어 있지 않습니다."
    exit 1
fi

# 클러스터 존재 확인
if ! k3d cluster list 2>/dev/null | grep -q "^${CLUSTER_NAME} "; then
    echo "클러스터 '${CLUSTER_NAME}'가 존재하지 않습니다."
    echo ""
    echo "현재 존재하는 k3d 클러스터:"
    k3d cluster list 2>/dev/null || echo "  (없음)"
    exit 0
fi

# 삭제 확인
echo "클러스터 '${CLUSTER_NAME}'를 삭제하시겠습니까? [y/N]"
read -r response
if [[ ! "$response" =~ ^[Yy]$ ]]; then
    echo "취소되었습니다."
    exit 0
fi

# 클러스터 삭제
echo ""
echo "클러스터 삭제 중..."
k3d cluster delete "${CLUSTER_NAME}"

# 생성된 설정 파일 정리
if [[ -f "${SCRIPT_DIR}/k3d-config-generated.yaml" ]]; then
    rm -f "${SCRIPT_DIR}/k3d-config-generated.yaml"
    echo "설정 파일 정리 완료"
fi

# 기존 k3s context로 전환 시도
echo ""
if kubectl config get-contexts default &>/dev/null; then
    kubectl config use-context default
    echo "기존 k3s context (default)로 전환되었습니다."
fi

echo ""
echo "=========================================="
echo "클러스터 삭제 완료!"
echo "=========================================="
echo ""
echo "현재 context:"
kubectl config current-context 2>/dev/null || echo "  (없음)"
