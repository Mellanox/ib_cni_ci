#!/bin/bash

export WORKSPACE=${WORKSPACE:-/tmp/k8s_$$}
export LOGDIR=$WORKSPACE/logs
export ARTIFACTS=$WORKSPACE/artifacts

export GOROOT=${GOROOT:-/usr/local/go}
export GOPATH=${WORKSPACE}
export PATH=/usr/local/go/bin/:$GOPATH/src/k8s.io/kubernetes/third_party/etcd:$PATH

export CNI_BIN_DIR=${CNI_BIN_DIR:-/opt/cni/bin/}
export CNI_CONF_DIR=${CNI_CONF_DIR:-/etc/cni/net.d/}
export ALLOW_PRIVILEGED=${ALLOW_PRIVILEGED:-true}
export NET_PLUGIN=${NET_PLUGIN:-cni}
export TIMEOUT=${TIMEOUT:-300}
export POLL_INTERVAL=${POLL_INTERVAL:-10}
export NETWORK=${NETWORK:-'192.168'}

export KUBECONFIG=${KUBECONFIG:-/var/run/kubernetes/admin.kubeconfig}
export POD_NAME=test-hca-pod
pushd $WORKSPACE


function pod_create {
    ib_pod=$ARTIFACTS/pod.yaml
    cat  > $ib_pod <<EOF
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

    kubectl get pods
    kubectl delete -f $ib_pod 2>&1|tee > /dev/null
    sleep ${POLL_INTERVAL}
    kubectl create -f $ib_pod

    kubectl delete -f $ARTIFACTS/${POD_NAME}.yaml
    wget https://raw.githubusercontent.com/Mellanox/k8s-rdma-shared-dev-plugin/master/example/${POD_NAME}.yaml -O $ARTIFACTS/${POD_NAME}.yaml
    kubectl create -f $ARTIFACTS/${POD_NAME}.yaml


    pod_status=$(kubectl get pods | grep mofed-test-pod |awk  '{print $3}')
    let stop=$(date '+%s')+$TIMEOUT
    d=$(date '+%s')
    while [ $d -lt $stop ]; do
        echo "Waiting for pod to became Running"
        pod_status=$(kubectl get pods | grep mofed-test-pod |awk  '{print $3}')
        if [ "$pod_status" == "Running" ]; then
            return 0
        elif [ "$pod_status" == "UnexpectedAdmissionError" ]; then
            kubectl delete -f $ib_pod
            sleep ${POLL_INTERVAL}
            kubectl create -f $ib_pod
        fi
        kubectl get pods | grep mofed-test-pod
        kubectl describe pod mofed-test-pod
        sleep ${POLL_INTERVAL}
        d=$(date '+%s')
    done
    echo "Error ${POD_NAME} is not up"
    return 1
}


function test_pod {
    kubectl exec -i mofed-test-pod -- ip a
    kubectl exec -i mofed-test-pod -- ip addr show eth0
    echo "Checking eth0 for address network $NETWORK"
    kubectl exec -i mofed-test-pod -- ip addr show eth0|grep "$NETWORK"
    status=$?
    if [ $status -ne 0 ]; then
        echo "Failed to find $NETWORK in eth0 address inside the pod"
    else
        echo "Passed to find $NETWORK in eth0 address inside the pod"
    fi
    return $status
}


pod_create
test_pod
status=$?
echo "All logs $LOGDIR"
echo "All confs $ARTIFACTS"
echo "To stop K8S run # WORKSPACE=${WORKSPACE} ./ib_cni_stop.sh"
exit $status
