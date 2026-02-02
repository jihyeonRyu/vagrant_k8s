#!/usr/bin/env bash
#
# teardown.sh - Kind GPU 클러스터 삭제
#
# 사용법: ./teardown.sh [CLUSTER_NAME]
#

set -e

CLUSTER_NAME="${1:-gpu-cluster}"

echo "=========================================="
echo "Kind GPU 클러스터 삭제"
echo "=========================================="
echo "클러스터 이름: ${CLUSTER_NAME}"
echo ""

# 클러스터 존재 확인
if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    echo "클러스터 '${CLUSTER_NAME}'가 존재하지 않습니다."
    echo ""
    echo "현재 존재하는 클러스터:"
    kind get clusters 2>/dev/null || echo "  (없음)"
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
kind delete cluster --name "${CLUSTER_NAME}"

# 생성된 설정 파일 정리
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/kind-config-generated.yaml" ]]; then
    rm -f "${SCRIPT_DIR}/kind-config-generated.yaml"
    echo "설정 파일 정리 완료"
fi

echo ""
echo "=========================================="
echo "클러스터 삭제 완료!"
echo "=========================================="
