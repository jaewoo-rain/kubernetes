#!/usr/bin/env bash
set -euo pipefail

# ===== [0] 기본 정보 =====
POD_CIDR="20.96.0.0/12"
MASTER_IP="$(hostname -I | awk '{print $1}')"   # 필요 시 고정 IP로 교체
MASTER_HOST="k8s-master"                        # 원하면 변경
K8S_VERSION="1.27.2-1.1"                        # Ubuntu용 패키지 버전 표기
CTR_VERSION="1.6.21-1"                          # containerd.io(deb) 버전

echo "==> Master IP: ${MASTER_IP}"
hostnamectl set-hostname "${MASTER_HOST}"

# ===== [1] 기본 세팅 =====
echo "==> 시간/타임존/필수 패키지"
sudo timedatectl set-timezone Asia/Seoul || true
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg lsb-release software-properties-common

echo "==> 스왑 비활성화"
sudo swapoff -a
sudo sed -ri '/\sswap\s/s/^/#/' /etc/fstab

echo "==> UFW(있다면) 비활성화"
if systemctl is-enabled --quiet ufw; then
  sudo systemctl stop ufw || true
  sudo systemctl disable ufw || true
fi

echo "==> /etc/hosts 추가"
if ! grep -q "${MASTER_IP} ${MASTER_HOST}" /etc/hosts; then
  echo "${MASTER_IP} ${MASTER_HOST}" | sudo tee -a /etc/hosts
fi

# ===== [2] 커널 모듈/네트워킹 =====
echo "==> 커널 모듈 및 sysctl"
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

# ===== [3] containerd 설치 (Docker repo 경유) =====
# echo "==> Docker repo 추가"
# sudo install -m 0755 -d /etc/apt/keyrings
# curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
#   | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
# echo \
#   "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
#   https://download.docker.com/linux/ubuntu $(. /etc/os-release; echo "$UBUNTU_CODENAME") stable" \
#   | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

# sudo apt-get update -y
# sudo apt-get install -y --allow-downgrades containerd.io=${CTR_VERSION}

# echo "==> containerd systemd cgroup 설정"
# sudo mkdir -p /etc/containerd
# containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
# sudo sed -i 's/ SystemdCgroup = false/ SystemdCgroup = true/' /etc/containerd/config.toml
# sudo systemctl daemon-reload
# sudo systemctl enable --now containerd

# ===== [4] Kubernetes 1.27 repo & 설치 =====
echo "==> k8s apt repo 추가 (pkgs.k8s.io)"
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.27/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-1-27.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-1-27.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.27/deb/ /" \
| sudo tee /etc/apt/sources.list.d/kubernetes-1-27.list >/dev/null

sudo apt-get update -y
sudo apt-get install -y kubelet=${K8S_VERSION} kubeadm=${K8S_VERSION} kubectl=${K8S_VERSION}
sudo apt-mark hold kubelet kubeadm kubectl

sudo systemctl enable --now kubelet

# ===== [5] kubeadm init =====
echo "==> kubeadm init"
sudo kubeadm init \
  --pod-network-cidr="${POD_CIDR}" \
  --apiserver-advertise-address "${MASTER_IP}"

echo "==> admin kubeconfig 세팅"
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown "$(id -u)":"$(id -g)" $HOME/.kube/config

# ===== [6] Calico 설치 (너의 레포 사용) =====
echo "==> Calico 설치"
kubectl apply -f https://raw.githubusercontent.com/jaewoo-rain/kubernetes/main/ground/k8s-1.27/calico-3.26.4/calico.yaml
kubectl apply -f https://raw.githubusercontent.com/jaewoo-rain/kubernetes/main/ground/k8s-1.27/calico-3.26.4/calico-custom.yaml

# ===== [7] master 스케줄 허용 (단일노드용) =====
kubectl taint nodes "${MASTER_HOST}" node-role.kubernetes.io/control-plane- || true

# ===== [8] 품질/편의 =====
echo "==> bash 자동완성"
echo 'source <(kubectl completion bash)' >> ~/.bashrc
echo 'alias k=kubectl' >> ~/.bashrc
echo 'complete -o default -F __start_kubectl k' >> ~/.bashrc

echo "==> iproute2/tc (경고 제거용)"
sudo apt-get install -y iproute2

echo "✅ Ubuntu 단일 노드 K8s 1.27 설치 완료!"
kubectl get nodes -o wide
