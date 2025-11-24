#!/usr/bin/env bash
set -euo pipefail

#############################################
# Ubuntu K8s Master 초기화 스크립트
# - kubeadm + containerd + Calico
# - 단일/멀티 노드 모두 고려
#
# 사용 예시:
#   MASTER_IP=192.168.0.10 bash master.sh
#   MASTER_IP=192.168.0.10 ALLOW_SCHEDULE_ON_MASTER=false bash master.sh
#############################################

# ===== [0] 기본 변수 =====
POD_CIDR="${POD_CIDR:-20.96.0.0/12}"    # Calico/Pod 네트워크 CIDR
MASTER_IP="${MASTER_IP:-}"              # 반드시 외부에서 넣어줘야 하는 값
MASTER_HOST="${MASTER_HOST:-k8s-master}"

# 마스터 노드에도 파드를 스케줄링할지 여부
# - 개발/단일 노드: true
# - 프로덕션/멀티 노드: false 추천
ALLOW_SCHEDULE_ON_MASTER="${ALLOW_SCHEDULE_ON_MASTER:-true}"

echo "==> [CONFIG] Master IP          : ${MASTER_IP:-<EMPTY>}"
echo "==> [CONFIG] Master Hostname    : ${MASTER_HOST}"
echo "==> [CONFIG] POD CIDR           : ${POD_CIDR}"
echo "==> [CONFIG] Schedule on Master : ${ALLOW_SCHEDULE_ON_MASTER}"

if [[ -z "${MASTER_IP}" ]]; then
  echo "ERROR: MASTER_IP 환경 변수가 비어 있습니다."
  echo "예) MASTER_IP=192.168.0.10 bash master.sh"
  exit 1
fi

# ===== [1] 호스트명 및 기본 세팅 =====
echo "==> 호스트명 설정: ${MASTER_HOST}"
sudo hostnamectl set-hostname "${MASTER_HOST}"

echo "==> 시간/타임존/필수 패키지 설치"
sudo timedatectl set-timezone Asia/Seoul || true

sudo apt-get update -y
sudo apt-get install -y \
  ca-certificates \
  curl \
  gnupg \
  lsb-release \
  software-properties-common

echo "==> 스왑 비활성화"
sudo swapoff -a
sudo sed -ri '/\sswap\s/s/^/#/' /etc/fstab

echo "==> UFW(있다면) 비활성화"
if systemctl is-enabled --quiet ufw; then
  sudo systemctl stop ufw || true
  sudo systemctl disable ufw || true
fi

echo "==> /etc/hosts에 마스터 IP/호스트 추가"
if ! grep -q "${MASTER_IP} ${MASTER_HOST}" /etc/hosts; then
  echo "${MASTER_IP} ${MASTER_HOST}" | sudo tee -a /etc/hosts
fi

# ===== [2] 커널 모듈 & sysctl =====
echo "==> 커널 모듈 (overlay, br_netfilter) 및 sysctl 설정"
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system

# ===== [3-A] containerd 설치 (없을 경우 자동 설치) =====
echo "==> containerd 설치 여부 확인"
if ! command -v containerd &>/dev/null; then
  echo "==> containerd가 없어 자동 설치 진행"

  sudo apt-get update -y

  # Docker 공식 레포 추가
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  # Ubuntu 버전 정보 로드
  . /etc/os-release

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

  sudo apt-get update -y
  sudo apt-get install -y containerd.io

  echo "==> containerd 설치 완료"
else
  echo "==> containerd 이미 설치됨"
fi

# ===== [3-B] containerd SystemdCgroup 설정 보정 =====
#  - Docker/Containerd가 이미 설치된 환경에서,
#    K8s에 맞게 SystemdCgroup을 true로 맞춰주는 역할
echo "==> containerd SystemdCgroup 설정 보정"
if [ ! -f /etc/containerd/config.toml ]; then
  echo "  -> /etc/containerd/config.toml 이 없어 기본 설정 생성"
  sudo mkdir -p /etc/containerd
  containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
fi

sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml || true

sudo systemctl daemon-reload
sudo systemctl enable --now containerd || true
sudo systemctl restart containerd || true

# ===== [4] Kubernetes repo & 설치 (v1.28) =====
echo "==> Kubernetes apt repo 추가 (pkgs.k8s.io / v1.28)"
sudo mkdir -p /etc/apt/keyrings

# 이전 키/리스트가 있다면 제거 (없어도 에러 무시)
sudo rm -f /etc/apt/sources.list.d/kubernetes*.list /etc/apt/keyrings/kubernetes-*.gpg || true

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

echo "==> kubelet / kubeadm / kubectl 설치"
sudo apt-get update -y
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

sudo systemctl enable --now kubelet

# ===== [5] kubeadm init =====
echo "==> kubeadm init 실행"
sudo kubeadm init \
  --pod-network-cidr="${POD_CIDR}" \
  --apiserver-advertise-address="${MASTER_IP}"

# ===== [6] admin kubeconfig 세팅 =====
echo "==> admin kubeconfig 세팅 (~/.kube/config)"
mkdir -p "$HOME/.kube"
sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u)":"$(id -g)" "$HOME/.kube/config"

# ===== [7] Calico 설치 (네 레포 사용) =====
echo "==> Calico CNI 설치"
kubectl apply -f https://raw.githubusercontent.com/jaewoo-rain/kubernetes/main/ground/k8s-1.27/calico-3.26.4/calico.yaml
kubectl apply -f https://raw.githubusercontent.com/jaewoo-rain/kubernetes/main/ground/k8s-1.27/calico-3.26.4/calico-custom.yaml

# ===== [8] Master 스케줄링 설정 (옵션) =====
if [[ "${ALLOW_SCHEDULE_ON_MASTER}" == "true" ]]; then
  echo "==> Master 노드에 워크로드 스케줄 허용 (taint 제거)"
  kubectl taint nodes "${MASTER_HOST}" node-role.kubernetes.io/control-plane- || true
else
  echo "==> Master 노드는 control-plane 전용으로 유지 (taint 제거 안함)"
fi

# ===== [9] 편의 기능 =====
echo "==> kubectl bash 자동완성 및 alias 설정"
if ! grep -q "__start_kubectl" ~/.bashrc 2>/dev/null; then
  {
    echo 'source <(kubectl completion bash)'
    echo 'alias k=kubectl'
    echo 'complete -o default -F __start_kubectl k'
  } >> ~/.bashrc
fi

echo "==> iproute2 설치 (tc 경고 제거용)"
sudo apt-get install -y iproute2

echo "✅ Ubuntu K8s Master 설치 완료!"
kubectl get nodes -o wide || true
