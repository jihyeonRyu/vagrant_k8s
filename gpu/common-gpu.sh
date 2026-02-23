#!/usr/bin/env bash
#
# common-gpu.sh - K8s 공통 설정 + NVIDIA 드라이버 + Container Toolkit
#
# 이 스크립트는 Control Plane과 Worker 노드 모두에서 실행됩니다.
#

set -e

# 버전 설정
K8S_VERSION="${K8S_VERSION:-1.34.3-1.1}"
NVIDIA_DRIVER_VERSION="${NVIDIA_DRIVER_VERSION:-550}"  # 서버용 안정 버전

echo "=========================================="
echo "GPU K8s 노드 공통 설정 시작"
echo "=========================================="
echo "K8s Version: ${K8S_VERSION}"
echo "NVIDIA Driver Version: ${NVIDIA_DRIVER_VERSION}"
echo ""

# ============================================
# 디스크 자동 확장 (LVM)
# ============================================
echo "[0/8] 디스크 확장 확인..."
# generic/ubuntu2204 box는 LVM 사용. machine_virtual_size로 디스크가 커져도
# 파티션/LVM이 자동 확장되지 않으므로 여기서 처리
apt-get install -y cloud-guest-utils 2>/dev/null || true

ROOT_DISK=$(lsblk -ndo NAME,TYPE | grep disk | head -1 | awk '{print $1}')
if [ -n "$ROOT_DISK" ]; then
    ROOT_PART=$(lsblk -nlo NAME,TYPE "/dev/${ROOT_DISK}" | grep part | tail -1 | awk '{print $1}')
    PART_NUM=$(echo "$ROOT_PART" | grep -oE '[0-9]+$')
    
    if [ -n "$PART_NUM" ]; then
        echo "  Disk: /dev/${ROOT_DISK}, Partition: /dev/${ROOT_PART} (#${PART_NUM})"
        # 파티션 확장
        growpart "/dev/${ROOT_DISK}" "${PART_NUM}" 2>/dev/null && echo "  Partition extended" || echo "  Partition already at max size"
        # PV 확장 (LVM)
        pvresize "/dev/${ROOT_PART}" 2>/dev/null && echo "  PV resized" || true
        # LV 확장
        lvextend -l +100%FREE /dev/mapper/ubuntu--vg-ubuntu--lv 2>/dev/null && echo "  LV extended" || true
        # 파일시스템 확장
        resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv 2>/dev/null && echo "  Filesystem resized" || true
    fi
fi

echo "  Disk usage:"
df -h / | tail -1
echo ""

# ============================================
# /etc/hosts 설정 (노드 간 통신)
# ============================================
echo "[1/8] /etc/hosts 설정..."
NETWORK_PREFIX="192.168.122"
cat >> /etc/hosts <<EOF
${NETWORK_PREFIX}.10  gpu-control-plane
${NETWORK_PREFIX}.21  gpu-worker-1
${NETWORK_PREFIX}.22  gpu-worker-2
EOF

# ============================================
# 기본 패키지 설치
# ============================================
echo "[2/8] 기본 패키지 설치..."
apt-get update
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    netcat-openbsd \
    nfs-common \
    software-properties-common \
    socat \
    wget

# ============================================
# containerd 설치
# ============================================
echo "[3/8] containerd 설치..."
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
echo "[4/8] CNI 플러그인 설치..."
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
echo "[5/8] Kubernetes 설치..."
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
echo "[6/8] 커널 설정..."

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
echo "[7/8] NVIDIA 드라이버 설치..."

# GPU 존재 여부 확인
if lspci | grep -qi nvidia; then
    echo "  NVIDIA GPU 발견됨. 드라이버 설치 중..."
    
    # NVIDIA 드라이버 저장소 추가
    add-apt-repository -y ppa:graphics-drivers/ppa
    apt-get update
    
    # 헤드리스 서버용 드라이버 설치 (X11 없이)
    apt-get install -y "nvidia-driver-${NVIDIA_DRIVER_VERSION}-server" \
                       "nvidia-utils-${NVIDIA_DRIVER_VERSION}-server"
    
    # 드라이버 모듈 로드
    modprobe nvidia 2>/dev/null || true
    modprobe nvidia_uvm 2>/dev/null || true
    
    # Persistence mode 활성화
    nvidia-smi -pm 1 2>/dev/null || true
    
    echo "  드라이버 설치 완료."
    echo ""
    echo "  ⚠️  참고: H100 SXM 등 NVSwitch 기반 GPU를 사용하는 경우"
    echo "     호스트(물리 머신)에서 Fabric Manager가 실행 중이어야 CUDA가 동작합니다."
    echo "     호스트에서: sudo systemctl start nvidia-fabricmanager"
else
    echo "  NVIDIA GPU가 감지되지 않음. 드라이버 설치 생략."
fi

# ============================================
# NVIDIA Container Toolkit 설치
# ============================================
echo "[8/8] NVIDIA Container Toolkit 설치..."

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
    
    # CDI (Container Device Interface) 설정 생성
    mkdir -p /etc/cdi
    
    # 부팅 시 CDI 설정 자동 생성 스크립트
    cat > /etc/systemd/system/nvidia-cdi-generate.service <<'EOFSERVICE'
[Unit]
Description=Generate NVIDIA CDI configuration
After=containerd.service
Wants=containerd.service

[Service]
Type=oneshot
# /dev/nvidia0 나타날 때까지 최대 60초 대기
ExecStartPre=/bin/bash -c 'for i in $(seq 1 60); do [ -e /dev/nvidia0 ] && exit 0; sleep 1; done; exit 1'
ExecStart=/usr/bin/nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
ExecStartPost=/bin/systemctl restart containerd
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOFSERVICE
    
    systemctl daemon-reload
    systemctl enable nvidia-cdi-generate.service
    
    # 현재 드라이버가 로드되어 있으면 바로 CDI 생성
    if nvidia-smi &>/dev/null; then
        echo "  NVIDIA 드라이버 로드됨. CDI 설정 생성..."
        nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
    else
        echo "  NVIDIA 드라이버가 아직 로드되지 않음."
        echo "  드라이버 모듈 로드 시도..."
        modprobe nvidia 2>/dev/null || true
        sleep 3
        if nvidia-smi &>/dev/null; then
            echo "  드라이버 로드 성공. CDI 설정 생성..."
            nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
        else
            echo "  ⚠️ 드라이버 로드 실패. 재부팅 후 자동 생성됩니다."
        fi
    fi
    
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
echo "export KUBECONFIG=\$HOME/.kube/config" >> /home/vagrant/.bashrc

echo ""
echo "=========================================="
echo "공통 설정 완료!"
echo "=========================================="
