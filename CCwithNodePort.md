# Istio Version 1.9 Cross Cluster with Node Port Setup
We will build a cluster which is using NodePort for Ingress and East West Gateway. We are utilising [Ha Proxy](http://www.haproxy.org) TCP Load Balancer for layer 4 routing. You could use the [generate_haproxy_cfg_for_istio.sh script](https://github.com/ozhankaraman/IstioCC/blob/main/generate_haproxy_cfg_for_istio.sh) in this repo to generate required config for HaProxy.

We will use the cluster below to demonstrate NodePort setup for Cross Cluster Communication.

Cluster | Node | Region | Zone
-- | --| -- | --
H1 | h1n1 | region1 | zone1
H1 | h1n2 | region1 | zone2
H1 | h1n3 | region1 | zone2
-- | -- | -- | -- 
H2 | h2n1 | region2 | zone1
H2 | h2n2 | region2 | zone2
H2 | h2n3 | region2 | zone3
H2 | h2n4 | region4 | zone4
H2 | h2n5 | region4 | zone5
-- | --| -- | --
H3 | h3n1 | region3 | zone1
H3 | h3n2 | region3 | zone2
H3 | h3n3 | region3 | zone2

VIP definitions for HA Proxy Load Balancer are below:

Cluster | Type | VIP
-- | -- | --
H1 | Ingress | h1-vip1.zz.zebrastack.com (192.168.98.158)
H1 | East West GW | h1-vip2.zz.zebrastack.com (192.168.98.150)
H2 | Ingress | h2-vip1.zz.zebrastack.com (192.168.98.159)
H2 | East West GW | h2-vip2.zz.zebrastack.com (192.168.98.151)
H3 | Ingress | h3-vip1.zz.zebrastack.com (192.168.98.160)
H3 | East West GW | h3-vip2.zz.zebrastack.com (192.168.98.152)

# We follow the below steps to build up a 3 node CC Cluster
1. Deploy simple Kubernetes 1.20.4 cluster with Node Port Load Balancer Setup. My whole cluster(nodes and Ha Proxy LB) is working over Linux KVM VM's and each node is a separate vm. 
1. Label Nodes with Specific Region and Zone (if you do not have these)
1. Generate Common CA for all clusters and generate TLS secret for Istiod
1. Deploy Istio Operator
1. Deploy Istiod
1. Deploy East-West Ingress GW to handle CC Communication
1. Expose Services on Clusters for Endpoint Discovery
1. Deploy Remote Secret for Endpoint Discovery on Clusters

## Label Nodes with Specific Region and Zone 
``` bash
kubectl --context=h1-admin label nodes h1n1 --overwrite topology.kubernetes.io/region=region1
kubectl --context=h1-admin label nodes h1n1 --overwrite topology.kubernetes.io/zone=zone1
kubectl --context=h1-admin label nodes h1n2 --overwrite topology.kubernetes.io/region=region1
kubectl --context=h1-admin label nodes h1n2 --overwrite topology.kubernetes.io/zone=zone2
kubectl --context=h1-admin label nodes h1n3 --overwrite topology.kubernetes.io/region=region1
kubectl --context=h1-admin label nodes h1n3 --overwrite topology.kubernetes.io/zone=zone3

kubectl --context=h2-admin label nodes h2n1 --overwrite topology.kubernetes.io/region=region2
kubectl --context=h2-admin label nodes h2n1 --overwrite topology.kubernetes.io/zone=zone1
kubectl --context=h2-admin label nodes h2n2 --overwrite topology.kubernetes.io/region=region2
kubectl --context=h2-admin label nodes h2n2 --overwrite topology.kubernetes.io/zone=zone2
kubectl --context=h2-admin label nodes h2n3 --overwrite topology.kubernetes.io/region=region2
kubectl --context=h2-admin label nodes h2n3 --overwrite topology.kubernetes.io/zone=zone3
kubectl --context=h2-admin label nodes h2n4 --overwrite topology.kubernetes.io/region=region4
kubectl --context=h2-admin label nodes h2n4 --overwrite topology.kubernetes.io/zone=zone4
kubectl --context=h2-admin label nodes h2n5 --overwrite topology.kubernetes.io/region=region4
kubectl --context=h2-admin label nodes h2n5 --overwrite topology.kubernetes.io/zone=zone5

kubectl --context=h3-admin label nodes h3n1 --overwrite topology.kubernetes.io/region=region3
kubectl --context=h3-admin label nodes h3n1 --overwrite topology.kubernetes.io/zone=zone1
kubectl --context=h3-admin label nodes h3n2 --overwrite topology.kubernetes.io/region=region3
kubectl --context=h3-admin label nodes h3n2 --overwrite topology.kubernetes.io/zone=zone2
kubectl --context=h3-admin label nodes h3n3 --overwrite topology.kubernetes.io/region=region3
kubectl --context=h3-admin label nodes h3n3 --overwrite topology.kubernetes.io/zone=zone3
```

## Generate Common CA for all clusters and generate tls secret for Istiod
``` bash
# Below command is for macosx https://github.com/istio/istio/releases/tag/1.9.0
wget https://github.com/istio/istio/releases/download/1.9.1/istio-1.9.1-osx.tar.gz && \
  tar zxf istio-1.9.1-osx.tar.gz && rm -rf istio-1.9.1-osx.tar.gz
mkdir istio-certs
mkdir istio-certs/h1 istio-certs/h2 istio-certs/h3

cd istio-certs

make -f ../istio-1.9.1/tools/certs/Makefile.selfsigned.mk root-ca
make -f ../istio-1.9.1/tools/certs/Makefile.selfsigned.mk h1-cacerts
make -f ../istio-1.9.1/tools/certs/Makefile.selfsigned.mk h2-cacerts
make -f ../istio-1.9.1/tools/certs/Makefile.selfsigned.mk h3-cacerts

cd ..

# Generate tls secret for each cluster
# c1
kubectl --context=h1-admin create namespace istio-system
kubectl --context=h1-admin create secret generic cacerts -n istio-system \
      --from-file=istio-certs/h1/ca-cert.pem \
      --from-file=istio-certs/h1/ca-key.pem \
      --from-file=istio-certs/h1/root-cert.pem \
      --from-file=istio-certs/h1/cert-chain.pem

# c2
kubectl --context=h2-admin create namespace istio-system
kubectl --context=h2-admin create secret generic cacerts -n istio-system \
      --from-file=istio-certs/h2/ca-cert.pem \
      --from-file=istio-certs/h2/ca-key.pem \
      --from-file=istio-certs/h2/root-cert.pem \
      --from-file=istio-certs/h2/cert-chain.pem

# c3
kubectl --context=h3-admin create namespace istio-system
kubectl --context=h3-admin create secret generic cacerts -n istio-system \
      --from-file=istio-certs/h3/ca-cert.pem \
      --from-file=istio-certs/h3/ca-key.pem \
      --from-file=istio-certs/h3/root-cert.pem \
      --from-file=istio-certs/h3/cert-chain.pem
```

## Deploy Istio Operator
``` bash
./istio-1.9.1/bin/istioctl --context=h1-admin --hub=gcr.io/istio-release --tag=1.9.1 operator init
./istio-1.9.1/bin/istioctl --context=h2-admin --hub=gcr.io/istio-release --tag=1.9.1 operator init
./istio-1.9.1/bin/istioctl --context=h3-admin --hub=gcr.io/istio-release --tag=1.9.1 operator init
```

## Deploy Istiod
``` bash
# h1
cat << EOF | kubectl --context h1-admin apply -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: istiocontrolplane-default
  namespace: istio-system
spec:
  hub: gcr.io/istio-release
  tag: 1.9.1
  # revision: 1-9-0-1
  components:
    ingressGateways:
      - name: istio-ingressgateway
        enabled: true
        k8s:
          resources:
            requests:
              cpu: 200m
          service:
            ports:
              - name: status-port
                nodePort: 32170
                port: 15021
                protocol: TCP
                targetPort: 15021
              - name: http2
                nodePort: 30380
                port: 80
                protocol: TCP
                targetPort: 8080
              - name: https
                nodePort: 30633
                port: 443
                protocol: TCP
                targetPort: 8443
              - name: tcp-istiod
                nodePort: 32395
                port: 15012
                protocol: TCP
                targetPort: 15012
              - name: tls
                nodePort: 30495
                port: 15443
                protocol: TCP
                targetPort: 15443
            type: NodePort

  values:
    global:
      meshID: mesh1
      multiCluster:
        clusterName: cluster1
      network: network1
      meshNetworks:
        network1:
          endpoints:
          - fromRegistry: cluster1
          gateways:
          # Istio does not accept fqdn, so it must be IP address of the LB VIP
          - address: 192.168.98.150
            port: 15443
        network2:
          endpoints:
          - fromRegistry: cluster2
          gateways:
          - address: 192.168.98.151
            port: 15443
        network3:
          endpoints:
          - fromRegistry: cluster3
          gateways:
          - address: 192.168.98.152
            port: 15443

  meshConfig:
    defaultConfig:
      proxyMetadata:
        ISTIO_META_DNS_CAPTURE: "true"
        ISTIO_META_DNS_AUTO_ALLOCATE: "true"
EOF

# h2
cat << EOF | kubectl --context h2-admin apply -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: istiocontrolplane-default
  namespace: istio-system
spec:
  hub: gcr.io/istio-release
  tag: 1.9.1
  # revision: 1-9-0-1
  components:
    ingressGateways:
      - name: istio-ingressgateway
        enabled: true
        k8s:
          resources:
            requests:
              cpu: 200m
          service:
            ports:
              - name: status-port
                nodePort: 32170
                port: 15021
                protocol: TCP
                targetPort: 15021
              - name: http2
                nodePort: 30380
                port: 80
                protocol: TCP
                targetPort: 8080
              - name: https
                nodePort: 30633
                port: 443
                protocol: TCP
                targetPort: 8443
              - name: tcp-istiod
                nodePort: 32395
                port: 15012
                protocol: TCP
                targetPort: 15012
              - name: tls
                nodePort: 30495
                port: 15443
                protocol: TCP
                targetPort: 15443
            type: NodePort

  values:
    global:
      meshID: mesh1
      multiCluster:
        clusterName: cluster2
      network: network2      
      meshNetworks:
        network1:
          endpoints:
          - fromRegistry: cluster1
          gateways:
          # Istio does not accept fqdn, so it must be IP address of the LB VIP
          - address: 192.168.98.150
            port: 15443
        network2:
          endpoints:
          - fromRegistry: cluster2
          gateways:
          - address: 192.168.98.151
            port: 15443
        network3:
          endpoints:
          - fromRegistry: cluster3
          gateways:
          - address: 192.168.98.152
            port: 15443

  meshConfig:
    defaultConfig:
      proxyMetadata:
        ISTIO_META_DNS_CAPTURE: "true"
        ISTIO_META_DNS_AUTO_ALLOCATE: "true"
EOF

# h3
cat << EOF | kubectl --context h3-admin apply -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: istiocontrolplane-default
  namespace: istio-system
spec:
  hub: gcr.io/istio-release
  tag: 1.9.1
  # revision: 1-9-0-1
  components:
    ingressGateways:
      - name: istio-ingressgateway
        enabled: true
        k8s:
          resources:
            requests:
              cpu: 200m
          service:
            ports:
              - name: status-port
                nodePort: 32170
                port: 15021
                protocol: TCP
                targetPort: 15021
              - name: http2
                nodePort: 30380
                port: 80
                protocol: TCP
                targetPort: 8080
              - name: https
                nodePort: 30633
                port: 443
                protocol: TCP
                targetPort: 8443
              - name: tcp-istiod
                nodePort: 32395
                port: 15012
                protocol: TCP
                targetPort: 15012
              - name: tls
                nodePort: 30495
                port: 15443
                protocol: TCP
                targetPort: 15443
            type: NodePort

  values:
    global:
      meshID: mesh1
      multiCluster:
        clusterName: cluster3
      network: network3
      meshNetworks:
        network1:
          endpoints:
          - fromRegistry: cluster1
          gateways:
          # Istio does not accept fqdn, so it must be IP address of the LB VIP
          - address: 192.168.98.150
            port: 15443
        network2:
          endpoints:
          - fromRegistry: cluster2
          gateways:
          - address: 192.168.98.151
            port: 15443
        network3:
          endpoints:
          - fromRegistry: cluster3
          gateways:
          - address: 192.168.98.152
            port: 15443

  meshConfig:
    defaultConfig:
      proxyMetadata:
        ISTIO_META_DNS_CAPTURE: "true"
        ISTIO_META_DNS_AUTO_ALLOCATE: "true"
EOF
```

## Deploy East-West Ingress GW 
``` bash
# h1
cat << EOF | ./istio-1.9.1/bin/istioctl --context=h1-admin install -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: eastwest
spec:
  # revision: ""
  hub: gcr.io/istio-release
  tag: 1.9.1
  profile: empty
  components:
    ingressGateways:
      - name: istio-eastwestgateway
        label:
          istio: eastwestgateway
          app: istio-eastwestgateway
          topology.istio.io/network: network1
        enabled: true
        k8s:
          env:
            # sni-dnat adds the clusters required for AUTO_PASSTHROUGH mode
            - name: ISTIO_META_ROUTER_MODE
              value: "sni-dnat"
            # traffic through this gateway should be routed inside the network
            - name: ISTIO_META_REQUESTED_NETWORK_VIEW
              value: network1
          service:
            ports:
              - name: status-port
                nodePort: 32171
                port: 15021
                targetPort: 15021
              - name: tls
                nodePort: 31495
                port: 15443
                targetPort: 15443
              - name: tls-istiod
                nodePort: 31396
                port: 15012
                targetPort: 15012
              - name: tls-webhook
                nodePort: 31397
                port: 15017
                targetPort: 15017
            type: NodePort
  values:
    global:
      meshID: mesh1
      network: network1
      multiCluster:
        clusterName: cluster1
EOF

# h2
cat << EOF | ./istio-1.9.1/bin/istioctl --context=h2-admin install -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: eastwest
spec:
  # revision: ""
  hub: gcr.io/istio-release
  tag: 1.9.1
  profile: empty
  components:
    ingressGateways:
      - name: istio-eastwestgateway
        label:
          istio: eastwestgateway
          app: istio-eastwestgateway
          topology.istio.io/network: network2
        enabled: true
        k8s:
          env:
            # sni-dnat adds the clusters required for AUTO_PASSTHROUGH mode
            - name: ISTIO_META_ROUTER_MODE
              value: "sni-dnat"
            # traffic through this gateway should be routed inside the network
            - name: ISTIO_META_REQUESTED_NETWORK_VIEW
              value: network2
          service:
            ports:
              - name: status-port
                nodePort: 32171
                port: 15021
                targetPort: 15021
              - name: tls
                nodePort: 31495
                port: 15443
                targetPort: 15443
              - name: tls-istiod
                nodePort: 31396
                port: 15012
                targetPort: 15012
              - name: tls-webhook
                nodePort: 31397
                port: 15017
                targetPort: 15017
            type: NodePort
  values:
    global:
      meshID: mesh1
      network: network2
      multiCluster:
        clusterName: cluster2
EOF

# h3
cat << EOF | ./istio-1.9.1/bin/istioctl --context=h3-admin install -y -f -
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: eastwest
spec:
  # revision: ""
  hub: gcr.io/istio-release
  tag: 1.9.1
  profile: empty
  components:
    ingressGateways:
      - name: istio-eastwestgateway
        label:
          istio: eastwestgateway
          app: istio-eastwestgateway
          topology.istio.io/network: network3
        enabled: true
        k8s:
          env:
            # sni-dnat adds the clusters required for AUTO_PASSTHROUGH mode
            - name: ISTIO_META_ROUTER_MODE
              value: "sni-dnat"
            # traffic through this gateway should be routed inside the network
            - name: ISTIO_META_REQUESTED_NETWORK_VIEW
              value: network3
          service:
            ports:
              - name: status-port
                nodePort: 32171
                port: 15021
                targetPort: 15021
              - name: tls
                nodePort: 31495
                port: 15443
                targetPort: 15443
              - name: tls-istiod
                nodePort: 31396
                port: 15012
                targetPort: 15012
              - name: tls-webhook
                nodePort: 31397
                port: 15017
                targetPort: 15017
            type: NodePort
  values:
    global:
      meshID: mesh1
      network: network3
      multiCluster:
        clusterName: cluster3
EOF
```

## Expose Services on Clusters
```
kubectl --context=h1-admin apply -n istio-system -f ./istio-1.9.1/samples/multicluster/expose-services.yaml
kubectl --context=h2-admin apply -n istio-system -f ./istio-1.9.1/samples/multicluster/expose-services.yaml
kubectl --context=h3-admin apply -n istio-system -f ./istio-1.9.1/samples/multicluster/expose-services.yaml
```

## Deploy Remote Secret for Endpoint Discovery on Clusters
``` bash
# Deploy Remote Secret on h1 that provides >>Access to>> h2, h3 API Servers  || h1 >> h2, h3
./istio-1.9.1/bin/istioctl x create-remote-secret --context=h2-admin --name=cluster2 | kubectl apply -f - --context=h1-admin
./istio-1.9.1/bin/istioctl x create-remote-secret --context=h3-admin --name=cluster3 | kubectl apply -f - --context=h1-admin

# Deploy Remote Secret on h2 that provides >>Access to>> h1, h3 API Servers  || h2 >> h1, h3
./istio-1.9.1/bin/istioctl x create-remote-secret --context=h1-admin --name=cluster1 | kubectl apply -f - --context=h2-admin
./istio-1.9.1/bin/istioctl x create-remote-secret --context=h3-admin --name=cluster3 | kubectl apply -f - --context=h2-admin

# Deploy Remote Secret on h3 that provides >>Access to>> h2, h3 API Servers  || h3 >> h1, h2
./istio-1.9.1/bin/istioctl x create-remote-secret --context=h1-admin --name=cluster1 | kubectl apply -f - --context=h3-admin
./istio-1.9.1/bin/istioctl x create-remote-secret --context=h2-admin --name=cluster2 | kubectl apply -f - --context=h3-admin
```

## Deploy Sample Pods for our tests
Deploy helloworld2 and sleep pods and services on all regions and zones. With help of these pods we could apply regional cross cluster scenarios on three clusters
``` bash
kubectl --context=h1-admin apply -f ./helloworld2-ns.yaml
kubectl --context=h2-admin apply -f ./helloworld2-ns.yaml
kubectl --context=h3-admin apply -f ./helloworld2-ns.yaml

cat ./helloworld2-c1.yaml | sed -e 's/c1/h1/g' | kubectl --context=h1-admin apply -f -
cat ./helloworld2-c2.yaml | sed -e 's/c2/h2/g' | kubectl --context=h2-admin apply -f -
cat ./helloworld2-c3.yaml | sed -e 's/c3/h3/g' | kubectl --context=h3-admin apply -f -

kubectl --context=h1-admin apply -n sample -f sleep-ns.yaml
kubectl --context=h2-admin apply -n sample -f sleep-ns.yaml
kubectl --context=h3-admin apply -n sample -f sleep-ns.yaml

kubectl --context=h1-admin apply -n sample -f sleep.yaml
kubectl --context=h2-admin apply -n sample -f sleep.yaml
kubectl --context=h3-admin apply -n sample -f sleep.yaml
```

# Check Cross Cluster Communication
Here we send a request from sleepz2 pod(C1 Cluster, Region1, Zone2, Sample NS) to helloworld2 service
and we got replies from the pods in 3 Clusters, so we could say Yes Cross Cluster communication is working

``` bash
for count in `seq 1 10`; do
    kubectl exec --context=h1-admin -n sample -c sleep sleepz2 -- curl -sS helloworld2.sample:5000/hello
done

Hello version: h1z1, instance: helloworld2-h1z1-b89ffc768-2q2br
Hello version: h1z2, instance: helloworld2-h1z2-6c95dfd98d-5q5fl
Hello version: h2z3, instance: helloworld2-h2z3-5d68fd9849-t2lk2
Hello version: h2z3, instance: helloworld2-h2z3-5d68fd9849-t2lk2
Hello version: h3z2, instance: helloworld2-h3z2-7f7578b4bb-9npff
Hello version: h3z3, instance: helloworld2-h3z3-5cb64c45b9-szxbb
Hello version: h1z3, instance: helloworld2-h1z3-7df4d6c9db-b4bhf
Hello version: h1z1, instance: helloworld2-h1z1-b89ffc768-2q2br
Hello version: h1z3, instance: helloworld2-h1z3-7df4d6c9db-b4bhf
Hello version: h1z2, instance: helloworld2-h1z2-6c95dfd98d-5q5fl
```

You could whole complete Cross Cluster Scenarios from [this link](https://github.com/ozhankaraman/IstioCC#cross-cluster-scenarios)