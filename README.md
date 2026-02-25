# Kubernetes Cluster Tools

Vagrant 기반 Kubernetes 클러스터 구성 도구입니다.

## 구성 옵션

| 디렉토리 | 방식 | GPU | 용도 |
|----------|------|-----|------|
| `/` (루트) | Vagrant + VirtualBox | ❌ | 일반 K8s 테스트용 |
| `/gpu` | Vagrant + libvirt + PCI Passthrough | ✅ | **GPU 멀티노드 클러스터 (프로덕션 유사)** |

---

## 기본 클러스터 (VirtualBox)

GPU 없이 Kubernetes를 테스트하기 위한 기본 구성입니다.

### 사전 요구사항

- [Vagrant](https://developer.hashicorp.com/vagrant/downloads)
- [VirtualBox](https://www.virtualbox.org/wiki/Downloads)

### 사용 방법

```bash
# 클러스터 생성
vagrant up

# Control Plane 접속
vagrant ssh kube-control-plane

# Worker 노드 접속
vagrant ssh kube-worker-1

# 클러스터 삭제
vagrant destroy -f
```

### 구성

- **Control Plane**: 1대 (192.168.56.10)
- **Worker**: 2대 (192.168.56.21, 192.168.56.22)
- **CNI**: Calico
- **K8s Version**: 1.32.x

---

## GPU 클러스터 (libvirt + PCI Passthrough) ⭐

물리 서버의 NVIDIA GPU를 VM에 PCI Passthrough 방식으로 할당하여 **실제 멀티노드 GPU 클러스터**를 구성합니다.

### 특징

- 각 Worker VM에 실제 GPU가 패스스루됨
- 프로덕션 환경과 유사한 멀티노드 GPU 클러스터
- GPU Operator로 K8s GPU 리소스 관리

### 사전 요구사항

**1. BIOS 설정** (관리자 권한 필요)

| 설정 | 용도 | 확인 방법 |
|------|------|----------|
| **VT-x** | VM 실행 | `ls /dev/kvm` 존재 여부 |
| **VT-d** (Intel) / **AMD-Vi** | GPU 패스스루 | `ls /sys/kernel/iommu_groups/ \| wc -l` > 0 |

**2. 커널 파라미터** (1회 설정, 재부팅 필요)

```bash
# /etc/default/grub 편집
sudo vim /etc/default/grub

# Intel CPU:
GRUB_CMDLINE_LINUX_DEFAULT="intel_iommu=on iommu=pt"

# AMD CPU:
GRUB_CMDLINE_LINUX_DEFAULT="amd_iommu=on iommu=pt"

# GRUB 업데이트 (시스템에 따라)
sudo update-grub                                      # Ubuntu/Debian
sudo grub2-mkconfig -o /boot/efi/EFI/redhat/grub.cfg  # RHEL (EFI)

sudo reboot
```

**3. 필수 소프트웨어**

```bash
# Ubuntu/Debian
sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients libvirt-dev
vagrant plugin install vagrant-libvirt

# RHEL/CentOS
sudo dnf install -y qemu-kvm libvirt virt-install
sudo systemctl enable --now libvirtd
vagrant plugin install vagrant-libvirt
```

### 사용 방법

```bash
cd gpu/

# 1. GPU PCI 주소 확인 및 설정
lspci -nn | grep -i nvidia
vim gpu-config.yaml

# 2. GPU 서비스 중지
sudo systemctl stop containerd nvidia-fabricmanager nvidia-persistenced

# 3. GPU를 VFIO에 바인딩
sudo ./bind-vfio.sh

# 4. 클러스터 생성
vagrant up

# 5. 클러스터 접속
vagrant ssh gpu-control-plane
kubectl get nodes

# 6. GPU 확인
kubectl describe node gpu-worker-1 | grep nvidia

# 7. 클러스터 삭제
vagrant destroy -f

# 8. GPU를 호스트로 복원
sudo ./unbind-vfio.sh
sudo systemctl start nvidia-fabricmanager nvidia-persistenced
```

## 파일 동기화
```bash
# on host
vagrant rsync

vagrant plugin install vagrant-rsync-back
vagrant rsync-back
```

자세한 내용은 [gpu/README.md](gpu/README.md)를 참조하세요.

---

## 파일 구조

```
vagrant_k8s/
├── Vagrantfile              # VirtualBox 기본 클러스터
├── common.sh                # K8s 공통 설정 스크립트
├── control-plane.sh         # Control Plane 초기화
├── worker.sh                # Worker 조인
├── setup.sh                 # 추가 설정
├── admin.conf               # kubeconfig (생성 후)
│
└── gpu/                     # GPU 클러스터 (libvirt + PCI Passthrough) ⭐
    ├── Vagrantfile          # libvirt + PCI passthrough 설정
    ├── gpu-config.yaml      # GPU PCI 주소 및 할당 설정
    ├── bind-vfio.sh         # GPU -> VFIO 바인딩 (테스트 전)
    ├── unbind-vfio.sh       # GPU -> nvidia 복원 (테스트 후)
    ├── common-gpu.sh        # K8s + NVIDIA 드라이버 + Container Toolkit
    ├── control-plane-gpu.sh # Control Plane 초기화
    ├── worker-gpu.sh        # Worker 클러스터 조인
    ├── setup-gpu-operator.sh# GPU Operator 설치
    └── README.md            # GPU 클러스터 상세 가이드
```

## 라이선스

MIT
