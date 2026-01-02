
#!/usr/bin/env bash
set -euo pipefail

# ===== [0] 기본 정보 =====
POD_CIDR="20.96.0.0/12"
MASTER_HOST="k8s-master"  # 원하면 변경

sudo hostnamectl set-hostname "${MASTER_HOST}"

# (선택) hostname 해석 안정화용: 로컬에서 k8s-master가 127.0.0.1로 해석되게
if ! grep -qE "^[[:space:]]*127\.0\.0\.1[[:space:]]+${MASTER_HOST}([[:space:]]|$)" /etc/hosts; then
  echo "127.0.0.1 ${MASTER_HOST}" | sudo tee -a /etc/hosts >/dev/null
fi

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

# # ===== [3] containerd 설치 (Docker repo 경유) =====
# echo "==> Docker repo 추가"
# sudo install -m 0755 -d /etc/apt/keyrings
# curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
#   | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
# echo \
#   "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
#   https://download.docker.com/linux/ubuntu $(. /etc/os-release; echo "$UBUNTU_CODENAME") stable" \
#   | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

# sudo apt-get update -y
# sudo apt-get install -y containerd.io=${CTR_VERSION}

# echo "==> containerd systemd cgroup 설정"
# sudo mkdir -p /etc/containerd
# containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
# sudo sed -i 's/ SystemdCgroup = false/ SystemdCgroup = true/' /etc/containerd/config.toml
# sudo systemctl daemon-reload
# sudo systemctl enable --now containerd

# containerd가 실제로 설치/동작 중인지 확인 (없으면 kubeadm이 실패함)
if ! command -v containerd >/dev/null 2>&1; then
  echo "ERROR: containerd가 설치되어 있지 않습니다."
  echo " - 해결1) containerd 설치 파트(주석) 해제해서 설치"
  echo " - 해결2) 수동 설치 후 다시 실행"
  exit 1
fi
sudo systemctl enable --now containerd || true
sudo systemctl is-active --quiet containerd || { echo "ERROR: containerd 서비스가 실행 중이 아닙니다"; exit 1; }


# ==(Docker가 이미 설치되어 있다면) cgroup 보정==
echo "==> containerd SystemdCgroup 보정"
if [ ! -f /etc/containerd/config.toml ]; then
  sudo mkdir -p /etc/containerd
  containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
fi
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml || true
sudo systemctl restart containerd
sudo systemctl is-active --quiet containerd || { echo "ERROR: containerd 재시작 후 비활성"; exit 1; }

# ===== [4] Kubernetes repo & 설치 (v1.28 권장) =====
echo "==> k8s apt repo 추가 (pkgs.k8s.io / v1.28)"
sudo mkdir -p /etc/apt/keyrings
# 이전 키/리스트 잔재 제거(있어도/없어도 OK)
sudo rm -f /etc/apt/sources.list.d/kubernetes*.list /etc/apt/keyrings/kubernetes-*.gpg || true

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /" \
| sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

sudo apt-get update -y
# 버전 핀 없이 레포 내 최신 설치
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

sudo systemctl enable --now kubelet

# ===== [5] kubeadm init =====
# 기존 클러스터 흔적 확인
sudo kubeadm reset -f || true
sudo rm -rf /etc/cni/net.d /var/lib/cni /var/lib/kubelet /var/lib/etcd || true
sudo systemctl restart containerd kubelet || true

echo "==> kubeadm init"
sudo kubeadm init \
  --pod-network-cidr="${POD_CIDR}"

echo "==> admin kubeconfig 세팅"
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown "$(id -u)":"$(id -g)" $HOME/.kube/config

# ===== [6] Calico 설치 (너의 레포 사용) =====
echo "==> Calico 설치"
kubectl create -f https://raw.githubusercontent.com/jaewoo-rain/kubernetes/main/ground/k8s-1.27/calico-3.26.4/calico.yaml
kubectl create -f https://raw.githubusercontent.com/jaewoo-rain/kubernetes/main/ground/k8s-1.27/calico-3.26.4/calico-custom.yaml

# ===== [7] master 스케줄 허용 (단일노드용) =====
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

# ===== [8] 품질/편의 =====
echo "==> bash 자동완성"
echo 'source <(kubectl completion bash)' >> ~/.bashrc
echo 'alias k=kubectl' >> ~/.bashrc
echo 'complete -o default -F __start_kubectl k' >> ~/.bashrc

echo "==> iproute2/tc (경고 제거용)"
sudo apt-get install -y iproute2

echo '======== [9-2] Dashboard 설치 ========'
kubectl create -f https://raw.githubusercontent.com/jaewoo-rain/kubernetes/main/ground/k8s-1.27/dashboard-2.7.0/dashboard.yaml

echo '======== [9-3] Metrics Server 설치 ========'
kubectl create -f https://raw.githubusercontent.com/jaewoo-rain/kubernetes/main/ground/k8s-1.27/metrics-server-0.6.3/metrics-server.yaml

echo "✅ Ubuntu 단일 노드 K8s 설치 완료!"
kubectl get nodes -o wide
