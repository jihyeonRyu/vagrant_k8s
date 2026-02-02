#!/usr/bin/env bash
#
# common-gpu.sh - K8s 공통 설정 + NVIDIA 드라이버 + Container Toolkit
#
# 이 스크립트는 Control Plane과 Worker 노드 모두에서 실행됩니다.
#

set -e

# 버전 설정
K8S_VERSION="${K8S_VERSION:-1.32.1-1.1}"
NVIDIA_DRIVER_VERSION="${NVIDIA_DRIVER_VERSION:-550}"  # 서버용 안정 버전

echo "=========================================="
echo "GPU K8s 노드 공통 설정 시작"
echo "=========================================="
echo "K8s Version: ${K8S_VERSION}"
echo "NVIDIA Driver Version: ${NVIDIA_DRIVER_VERSION}"
echo ""

# ============================================
# 기본 패키지 설치
# ============================================
echo "[1/7] 기본 패키지 설치..."
apt-get update
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common \
    socat \
    wget

# ============================================
# containerd 설치
# ============================================
echo "[2/7] containerd 설치..."
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update
apt-get install -y containerd.io

# containerd 설정
mv /etc/containerd/config.toml /etc/containerd/config.toml.orig 2>/dev/null || true
containerd config default | tee /etc/containerd/config.toml > /dev/null
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

systemctl enable containerd
systemctl restart containerd

# ============================================
# CNI 플러그인 설치
# ============================================
echo "[3/7] CNI 플러그인 설치..."
ARCH=$(uname -m)
case "$ARCH" in
    x86_64) ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    armv7l) ARCH="arm" ;;
    *) echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

CNI_VERSION="v1.4.0"
wget -q "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-${ARCH}-${CNI_VERSION}.tgz"
mkdir -p /opt/cni/bin
tar Cxzf /opt/cni/bin "cni-plugins-linux-${ARCH}-${CNI_VERSION}.tgz"
rm -f "cni-plugins-linux-${ARCH}-${CNI_VERSION}.tgz"

# ============================================
# Kubernetes 설치
# ============================================
echo "[4/7] Kubernetes 설치..."
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION:0:4}/deb/Release.key" | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION:0:4}/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list

apt-get update
apt-get install -y \
    kubeadm="${K8S_VERSION}" \
    kubelet="${K8S_VERSION}" \
    kubectl="${K8S_VERSION}"
apt-mark hold kubelet kubeadm kubectl

# ============================================
# 커널 모듈 및 sysctl 설정
# ============================================
echo "[5/7] 커널 설정..."

# 필요한 모듈 로드
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# sysctl 설정
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

# ============================================
# NVIDIA 드라이버 설치 (Worker 노드용)
# ============================================
echo "[6/7] NVIDIA 드라이버 설치..."

# GPU 존재 여부 확인
if lspci | grep -qi nvidia; then
    echo "  NVIDIA GPU 발견됨. 드라이버 설치 중..."
    
    # NVIDIA 드라이버 저장소 추가
    add-apt-repository -y ppa:graphics-drivers/ppa
    apt-get update
    
    # 헤드리스 서버용 드라이버 설치 (X11 없이)
    apt-get install -y "nvidia-driver-${NVIDIA_DRIVER_VERSION}-server" \
                       "nvidia-utils-${NVIDIA_DRIVER_VERSION}-server"
    
    # nvidia-smi 확인 (드라이버 로드 전이라 실패할 수 있음)
    echo "  드라이버 설치 완료. (재부팅 후 nvidia-smi 사용 가능)"
else
    echo "  NVIDIA GPU가 감지되지 않음. 드라이버 설치 생략."
fi

# ============================================
# NVIDIA Container Toolkit 설치
# ============================================
echo "[7/7] NVIDIA Container Toolkit 설치..."

if lspci | grep -qi nvidia; then
    # NVIDIA Container Toolkit 저장소 추가
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
        gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
        tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    
    apt-get update
    apt-get install -y nvidia-container-toolkit
    
    # containerd에 NVIDIA 런타임 설정
    nvidia-ctk runtime configure --runtime=containerd
    
    # containerd 재시작
    systemctl restart containerd
    
    echo "  NVIDIA Container Toolkit 설치 완료."
else
    echo "  NVIDIA GPU가 없으므로 Container Toolkit 설치 생략."
fi

# ============================================
# 사용자 편의 설정
# ============================================
echo "alias k=kubectl" >> /home/vagrant/.bashrc
echo "export KUBECONFIG=/etc/kubernetes/admin.conf" >> /home/vagrant/.bashrc

echo ""
echo "=========================================="
echo "공통 설정 완료!"
echo "=========================================="
