#!/bin/bash -x

export WORKSPACE=${WORKSPACE:-/tmp/k8s_$$}
export LOGDIR=$WORKSPACE/logs
export ARTIFACTS=$WORKSPACE/artifacts
export TIMEOUT=${TIMEOUT:-300}
export POLL_INTERVAL=${POLL_INTERVAL:-10}

# can be <latest_stable|master|vA.B.C>
export KUBERNETES_VERSION=${KUBERNETES_VERSION:-latest_stable}
export KUBERNETES_BRANCH=${KUBERNETES_BRANCH:-master}

export MULTUS_CNI_REPO=${MULTUS_CNI_REPO:-https://github.com/intel/multus-cni}
export MULTUS_CNI_BRANCH=${MULTUS_CNI_BRANCH:-master}
# ex MULTUS_CNI_PR=345 will checkout https://github.com/intel/multus-cni/pull/345
export MULTUS_CNI_PR=${MULTUS_CNI_PR:-''}

export PLUGINS_REPO=${PLUGINS_REPO:-https://github.com/containernetworking/plugins.git}
export PLUGINS_BRANCH=${PLUGINS_BRANCH:-master}
export PLUGINS_BRANCH_PR=${PLUGINS_BRANCH_PR:-''}

export GOPATH=${WORKSPACE}
export PATH=/usr/local/go/bin/:$GOPATH/src/k8s.io/kubernetes/third_party/etcd:$PATH

export CNI_BIN_DIR=${CNI_BIN_DIR:-/opt/cni/bin/}
export CNI_CONF_DIR=${CNI_CONF_DIR:-/etc/cni/net.d/}
export ALLOW_PRIVILEGED=${ALLOW_PRIVILEGED:-true}
export NET_PLUGIN=${NET_PLUGIN:-cni}

export KUBE_ENABLE_CLUSTER_DNS=${KUBE_ENABLE_CLUSTER_DNS:-false}
export API_HOST=$(hostname).$(hostname -y)
export API_HOST_IP=$(hostname -I | awk '{print $1}')
export KUBECONFIG=${KUBECONFIG:-/var/run/kubernetes/admin.kubeconfig}

export IPOIB_CNI_BRANCH=${IPOIB_CNI_BRANCH:-master}
export K8S_RDMA_SHARED_DEV_PLUGIN=${K8S_RDMA_SHARED_DEV_PLUGIN:-master}

# generate random network
N=$((1 + RANDOM % 128))
export NETWORK=${NETWORK:-"192.168.$N"}

echo "Working in $WORKSPACE"
mkdir -p $WORKSPACE
mkdir -p $LOGDIR
mkdir -p $ARTIFACTS

cd $WORKSPACE

echo "Get CPU architechture"
export ARCH="amd64"
if [[ $(uname -a) == *"ppc"* ]]; then
   export ARCH="ppc64"
fi

function configure_multus {
    echo "Configure Multus"

    curl https://raw.githubusercontent.com/intel/multus-cni/${MULTUS_CNI_BRANCH}/images/multus-daemonset.yml -o $ARTIFACTS/multus-daemonset.yml
    /usr/local/bin/kubectl create -f $ARTIFACTS/multus-daemonset.yml

    /usr/local/bin/kubectl -n kube-system get ds
    rc=$?
    let stop=$(date '+%s')+$TIMEOUT
    d=$(date '+%s')
    while [ $d -lt $stop ]; do
       echo "Wait until multus is ready"
       ready=$(/usr/local/bin/kubectl -n kube-system get ds |grep kube-multus-ds-${ARCH}|awk '{print $4}')
       rc=$?
       /usr/local/bin/kubectl -n kube-system get ds
       d=$(date '+%s')
       sleep $POLL_INTERVAL
       if [ $ready -eq 1 ]; then
           echo "System is ready"
           break
      fi
    done
    if [ $d -gt $stop ]; then
        /usr/local/bin/kubectl -n kube-system get ds
        echo "kube-multus-ds-${ARCH} is not ready in $TIMEOUT sec"
        exit 1
    fi

    multus_config=$CNI_CONF_DIR/99-multus.conf
    cat > $multus_config <<EOF
    {
        "cniVersion": "0.3.0",
        "name": "macvlan-network",
        "type": "macvlan",
        "mode": "bridge",
          "ipam": {
                "type": "host-local",
                "subnet": "${NETWORK}.0/24",
                "rangeStart": "${NETWORK}.100",
                "rangeEnd": "${NETWORK}.216",
                "routes": [{"dst": "0.0.0.0/0"}],
                "gateway": "${NETWORK}.1"
            }
        }
EOF
    cp $multus_config $ARTIFACTS
    return $?
}


function download_and_build {
    status=0

    [ -d $CNI_CONF_DIR ] && rm -rf $CNI_CONF_DIR && mkdir -p $CNI_CONF_DIR
    [ -d $CNI_BIN_DIR ] && rm -rf $CNI_BIN_DIR && mkdir -p $CNI_BIN_DIR

    echo "Download $MULTUS_CNI_REPO"
    rm -rf $WORKSPACE/multus-cni
    git clone $MULTUS_CNI_REPO $WORKSPACE/multus-cni
    cd $WORKSPACE/multus-cni
    # Check if part of Pull Request and
    if test ${MULTUS_CNI_PR}; then
        git fetch --tags --progress $MULTUS_CNI_REPO +refs/pull/*:refs/remotes/origin/pr/*
        git pull origin pull/${MULTUS_CNI_PR}/head
    elif test $MULTUS_CNI_BRANCH; then
        git checkout $MULTUS_CNI_BRANCH
    fi
    git log -p -1 > $ARTIFACTS/multus-cni-git.txt
    cd -

    echo "Download $PLUGINS_REPO"
    rm -rf $WORKSPACE/plugins
    git clone $PLUGINS_REPO $WORKSPACE/plugins
    pushd $WORKSPACE/plugins
    if test ${PLUGINS_PR}; then
        git fetch --tags --progress ${PLUGINS_REPO} +refs/pull/*:refs/remotes/origin/pr/*
        git pull origin pull/${PLUGINS_PR}/head
    elif test $PLUGINS_BRANCH; then
        git checkout $PLUGINS_BRANCH
    fi
    git log -p -1 > $ARTIFACTS/plugins-git.txt
    bash ./build_linux.sh
    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Failed to build $PLUGINS_REPO $PLUGINS_BRANCH"
        exit $status
    fi

    \cp bin/* $CNI_BIN_DIR/
    popd

    echo "Download and install /usr/local/bin/kubectl"
    rm -f ./kubectl /usr/local/bin/kubectl
    if [ ${KUBERNETES_VERSION} == 'latest_stable' ]; then
        export KUBERNETES_VERSION=$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)
        curl https://storage.googleapis.com/kubernetes-release/release/${KUBERNETES_VERSION}/bin/linux/${ARCH}/kubectl -o /usr/local/bin/kubectl
    elif [ ${KUBERNETES_VERSION} == 'master' ]; then
        git clone -b ${KUBERNETES_BRANCH} --single-branch --depth=1  https://github.com/kubernetes/kubernetes
        cd kubernetes/
        git show --summary
        make
        mv ./_output/local/go/bin/kubectl /usr/local/bin/kubectl
    else
        curl https://storage.googleapis.com/kubernetes-release/release/${KUBERNETES_VERSION}/bin/linux/${ARCH}/kubectl -o /usr/local/bin/kubectl
    fi
    chmod +x /usr/local/bin/kubectl
    /usr/local/bin/kubectl version

    echo "Download K8S"
    rm -rf $GOPATH/src/k8s.io/kubernetes
    go get -d k8s.io/kubernetes
    cd $GOPATH/src/k8s.io/kubernetes
    git checkout $KUBERNETES_BRANCH
    git log -p -1 > $ARTIFACTS/kubernetes.txt
    make
    let status=status+$?
    if [ "$status" != 0 ]; then
        echo "Failed to build K8S $KUBERNETES_BRANCH"
        exit $status
    fi

    go get -u github.com/tools/godep
    go get -u github.com/cloudflare/cfssl/cmd/...

    return 0
}


function run_k8s {
    $GOPATH/src/k8s.io/kubernetes/hack/install-etcd.sh
    screen -S multus_kube -d -m bash -x $GOPATH/src/k8s.io/kubernetes/hack/local-up-cluster.sh
    /usr/local/bin/kubectl get pods
    rc=$?
    let stop=$(date '+%s')+$TIMEOUT
    d=$(date '+%s')
    while [ $d -lt $stop ]; do
       echo "Wait until K8S is up"
       /usr/local/bin/kubectl get pods
       rc=$?
       d=$(date '+%s')
       sleep $POLL_INTERVAL
       if [ $rc -eq 0 ]; then
           echo "K8S is up and running"
           return 0
      fi
    done
    echo "K8S failed to run in $TIMEOUT sec"
    exit 1
}


download_and_build
run_k8s
configure_multus

curl https://raw.githubusercontent.com/Mellanox/k8s-rdma-shared-dev-plugin/${K8S_RDMA_SHARED_DEV_PLUGIN}/images/k8s-rdma-shared-dev-plugin-config-map.yaml -o $ARTIFACTS/k8s-rdma-shared-dev-plugin-config-map.yaml
/usr/local/bin/kubectl create -f $ARTIFACTS/k8s-rdma-shared-dev-plugin-config-map.yaml
curl https://raw.githubusercontent.com/Mellanox/k8s-rdma-shared-dev-plugin/${K8S_RDMA_SHARED_DEV_PLUGIN}/images/k8s-rdma-shared-dev-plugin-ds.yaml -o $ARTIFACTS/k8s-rdma-shared-dev-plugin-ds.yaml
/usr/local/bin/kubectl create -f $ARTIFACTS/k8s-rdma-shared-dev-plugin-ds.yaml
curl https://raw.githubusercontent.com/Mellanox/ipoib-cni/${IPOIB_CNI_BRANCH}/images/ipoib-cni-daemonset.yaml -o $ARTIFACTS/ipoib-cni-daemonset.yaml
/usr/local/bin/kubectl create -f $ARTIFACTS/ipoib-cni-daemonset.yaml
cat  > $ARTIFACTS/pod.yaml <<EOF
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: ipoib-network
  annotations:
    k8s.v1.cni.cncf.io/resourceName: rdma/hca_shared_devices_a
spec:
  config: '{
  "cniVersion": "0.3.1",
  "type": "ipoib",
  "name": "mynet",
  "master": "ib0",
  "ipam": {
    "type": "host-local",
    "subnet": "192.168.3.0/24",
    "routes": [{
      "dst": "0.0.0.0/0"
    }],
      "gateway": "192.168.3.1"
  }
}'
EOF
/usr/local/bin/kubectl create -f $ARTIFACTS/pod.yaml
status=$?

echo "All code in $WORKSPACE"
echo "All logs $LOGDIR"
echo "All confs $ARTIFACTS"

echo "Setup is up and running. Run following to start tests:"
echo "# export KUBECONFIG=${KUBECONFIG}"
echo "# WORKSPACE=$WORKSPACE NETWORK=$NETWORK ./ib_cni_test.sh"

exit $status
