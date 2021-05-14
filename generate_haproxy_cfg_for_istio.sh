#!/bin/sh -e

rm -f /root/haproxy-istio


cat << EOF > /root/haproxy-istio
# Istio CC NodePort Definitions for HAProxy
#
# Current Worker Node List
# h1 -> h1n1, h1n2, h1n3
# h2 -> h2n1, h2n2, h2n3, h2n4, h2n5
# h3 -> h3n1, h3n2, h3n3

EOF

for ports in 1:15021:32170 1:80:30380 1:443:30633 1:15012:32395 1:15443:30495 2:15021:32171 2:15443:31495 2:15012:31396 2:15017:31397
do
    id=`echo $ports|cut -d: -f1`
    port=`echo $ports|cut -d: -f2`
    nodePort=`echo $ports|cut -d: -f3`

    if [ $id = "1" ]; then
        istioComponent="istio-ingressgateway"
    elif [ $id = "2" ]; then
        istioComponent="istio-eastwestgateway"
    fi

cat << EOF >> /root/haproxy-istio
#### vip${id} ${istioComponent}
frontend h1-${istioComponent}-frontend-vip${id}-${port}
    bind h1-vip${id}.zz.zebrastack.com:${port}
    mode tcp
    option tcplog
    timeout client 10800s
    default_backend h1-${istioComponent}-backend-vip${id}-${port}-to-${nodePort}

backend h1-${istioComponent}-backend-vip${id}-${port}-to-${nodePort}
    mode tcp
    option log-health-checks
    log global
    balance roundrobin
    timeout server 10s
    timeout connect 10m
    server h1n1 h1n1.zz.zebrastack.com:${nodePort} check
    server h1n2 h1n2.zz.zebrastack.com:${nodePort} check
    server h1n3 h1n3.zz.zebrastack.com:${nodePort} check

frontend h2-${istioComponent}-frontend-vip${id}-${port}
    bind h2-vip${id}.zz.zebrastack.com:${port}
    mode tcp
    option tcplog
    timeout client 10800s
    default_backend h2-east-west-backend-vip${id}-${port}-to-${nodePort}

backend h2-${istioComponent}-backend-vip${id}-${port}-to-${nodePort}
    mode tcp
    option log-health-checks
    log global
    balance roundrobin
    timeout server 10s
    timeout connect 10m
    server h2n1 h2n1.zz.zebrastack.com:${nodePort} check
    server h2n2 h2n2.zz.zebrastack.com:${nodePort} check
    server h2n3 h2n3.zz.zebrastack.com:${nodePort} check
    server h2n4 h2n4.zz.zebrastack.com:${nodePort} check
    server h2n5 h2n5.zz.zebrastack.com:${nodePort} check

frontend h3-${istioComponent}-frontend-vip${id}-${port}
    bind h3-vip${id}.zz.zebrastack.com:${port}
    mode tcp
    option tcplog
    timeout client 10800s
    default_backend h3-east-west-backend-vip${id}-${port}-to-${nodePort}

backend h3-${istioComponent}-backend-vip${id}-${port}-to-${nodePort}
    mode tcp
    option log-health-checks
    log global
    balance roundrobin
    timeout server 10s
    timeout connect 10m
    server h3n1 h3n1.zz.zebrastack.com:${nodePort} check
    server h3n2 h3n2.zz.zebrastack.com:${nodePort} check
    server h3n3 h3n3.zz.zebrastack.com:${nodePort} check

EOF

done
