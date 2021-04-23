#!/usr/bin/env bash
# Author:       Jonas
# version       1.0
# Date:         2021/4/21
# Description:  setup firewalld for k8s cluster

EXIT_SUCCESS=0
EXIT_FAILURE=1
ERR(){ echo -e "\033[31m\033[01m$1\033[0m"; }
WARN(){ echo -e "\033[33m\033[01m$1\033[0m"; }
MSG1(){ echo -e "\033[34m\033[01m$1\033[0m"; }
MSG2(){ echo -e "\033[32m\033[01m$1\033[0m"; }


# network cidr
K8S_FIREWALLD_ZONE="k8s"                # k8s firewalld zone name
INTERFACE=""                            # k8s node default interface        (NOT SET HERE)
DOCKER_CIDR=""                          # docker briget network subnet      (NOT SET HERE)
POD_CIDR="192.168.0.0/16"                # k8s pod network cidr
SERVICE_CIDR="172.20.0.0/16"            # k8s serivce cidr
GATEWAY=""                              # k8s node gateway                  (NOT SET HERE)
DNS=""                                  # k8s node dns, default is gateway


# k8s ip
K8S_MASTER_IP=(10.240.1.11          # qxis-k8s-master1
               10.240.1.12          # qxis-k8s-master2   
               10.240.1.13)         # qxis-k8s-master3
K8S_WORKER_IP=(10.240.1.21          # qxis-k8s-worker1
               10.240.1.22          # qxis-k8s-worker2
               10.240.1.23)         # qxis-k8s-worker3
K8S_IP=(${K8S_MASTER_IP[@]} ${K8S_WORKER_IP[@]})
ACCESS_SSH_IP=(10.240.0.101         # Jonas IP
               10.250.0.2
               10.240.0.4           # JumperServer IP
               10.240.0.3)          # LoadBalancer IP
ACCESS_K8S_IP=(10.240.0.101         # Jonas IP
              10.240.0.102)         # Jefflinux IP
LB_APISERVER=10.240.1.10
LB_INGRESS=10.240.1.20
CONTROL_PLANE_ENDPOINT="10.240.1.10:6443"


INSTALLED_CALICO="1"            # if installed calico, set here
INSTALLED_FLANNEL=""            # if installed flannel, set here
INSTALLED_INGRESS="1"           # if installed ingress, set here



function 0_prepare {
    # 1. not root exit
    [ $(id -u) -ne 0 ] && ERR "not root !" && exit $EXIT_FAILURE
    

    # 2. not centos or rhel exit
    [ $(uname) != "Linux" ] && ERR "not support !" && exit $EXIT_FAILURE
    source /etc/os-release
    [[ $ID != "centos" && $ID != "rhel" ]] && ERR "not support !" && exit $EXIT_FAILURE


    # 3. install firewalld & iproute
    command -v firewalld &> /dev/null
    if [[ $? != 0 ]]; then
        MSG1 "installing firewalld"
        yum install -y firewalld
        systemctl disable --now iptables
        systemctl mask iptable
        systemctl enable --now firewalld
    fi
    rpm -qi iproute &> /dev/null
    if [[ $? != 0 ]]; then yum install -y iproute; fi


    # 4. Get docker-ce bridge network subnet
    local docker_bridge_network_subnet
    if [ -z "${DOCKER_CIDR}" ]; then                # check if set DOCKER_CIDR
        rpm -qi docker-ce &> /dev/null              # check if install docker-ce
        if [ $? != 0 ]; then
            DOCKER_CIDR="172.17.0.0/16"             # if not install docker-ce, set the default DOCKER_CIDR value
        else                                        # if install docker-ce, get the DOCKER_CIDR value
            docker_bridge_network_subnet=$(docker network list | grep bridge | awk '{print $1}')
            docker_bridge_network_subnet=$(docker inspect ${bridge_network_subnet} | grep "Subnet" | awk -F':|,|' '{print $2}')
            docker_bridge_network_subnet=$(echo ${bridge_network_subnet} | tr -d '"')
            DOCKER_CIDR=${bridge_network_subnet}
        fi
    fi


    # 5. Get host default interface, gateway, dns
    INTERFACE=$(ip route show | grep '^default' | awk '{print $5}')
    GATEWAY=$(ip route show | grep '^default' | awk '{print $3}')
    if [ -z "${DNS}" ]; then
        DNS=${GATEWAY}
    fi
}




function 1_create_firewalld_zone_for_k8s {
    MSG1 "1. Create firewalld zone for k8s"

    # k8s firewalld zone default target is DROP
    systemctl enable --now firewalld
    firewall-cmd --delete-zone=${K8S_FIREWALLD_ZONE} --permanent
    firewall-cmd --new-zone="${K8S_FIREWALLD_ZONE}" --permanent
    firewall-cmd --reload
    firewall-cmd --set-default-zone="${K8S_FIREWALLD_ZONE}" --quiet
    firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --set-target=DROP --permanent
    firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --change-interface="${INTERFACE}" --quiet
    firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --change-interface="${INTERFACE}" --permanent --quiet
}



function 2_exposed_service_and_port_to_public_network {
    # Exposed service and port to public network
    MSG1 "2. Exposed service and port to public network" 


    MSG2 "allow dhcp"
    firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-service=dhcpv6-client
    firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-service=dhcpv6-client --permanent


    MSG2 "allow icmp"
    firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule protocol value=icmp accept"
    firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule protocol value=icmp accept" --permanent


    # vrrp is a rprotocol used by keepalived
    MSG2 "allow vrrp protocol"
    firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 protocol value='vrrp' accept"
    firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 protocol value='vrrp' accept" --permanent


    # Only the specificd ip can access ssh
    MSG2 "allow access ssh"
    for IP in ${ACCESS_SSH_IP[@]}; do
        firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} service name=ssh log prefix='SSH Access' level='notice' accept"
        firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} service name=ssh log prefix='SSH Access' level='notice' accept" --permanent
    done


    # Only the specificd ip can access k8s
    MSG2 "allow access k8s"
    local control_plane_endpoint_port=""
    old_ifs=$IFS
    IFS=":"
    temp_arr=($CONTROL_PLANE_ENDPOINT)
    IFS=$old_ifs
    control_plane_endpoint_port=${temp_arr[1]}
    for IP in ${ACCESS_K8S_IP[@]}; do
        firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=${control_plane_endpoint_port} protocol=tcp accept"
        firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=${control_plane_endpoint_port} protocol=tcp accept" --permanent
    done


    MSG2 "allow access k8s NodePort"
    firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 port port=30000-32767 protocol=tcp accept"
    firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 port port=30000-32767 protocol=tcp accept" --permanent


    MSG2 "allow access http"
    firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-service=http
    firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-service=http --permanent

    MSG2 "allow access https"
    firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-service=https
    firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-service=https --permanent
}



function 3_exposed_service_and_port_among_k8s_node {
    MSG1 "3. Setup Firewall for Kubernetes Service"

    MSG2 "Enabled masquerade for K8S"
    firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-masquerade
    firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-masquerade --permanent


    # allow docker briget network
    # allow pod network cidr
    # allow service cidr
    MSG2 "Enabled docker cidr, pod netwok cidr, service cidr firewall"
    firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 source address=${DOCKER_CIDR} accept"
    firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 source address=${POD_CIDR} accept"
    firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 source address=${SERVICE_CIDR} accept"
    firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 source address=${DOCKER_CIDR} accept" --permanent
    firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 source address=${POD_CIDR} accept" --permanent
    firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 source address=${SERVICE_CIDR} accept" --permanent


    # allow k8s all node access kube-apiserver
    MSG2 "Enabled kube-apiserver Firewall"
    for IP in ${K8S_IP[@]}; do
        firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=6443 protocol=tcp accept"
        firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=6443 protocol=tcp accept" --permanent
    done
    firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 source address=${LB_APISERVER} port port=6443 protocol=tcp accept"
    firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 source address=${LB_APISERVER} port port=6443 protocol=tcp accept" --permanent


    # allow k8s all node access kubelet
    MSG2 "Enabled kubelet Firewall"
    for IP in ${K8S_IP[@]}; do
        firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=10250 protocol=tcp accept"
        firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=10250 protocol=tcp accept" --permanent
    done


    # allow k8s all node access coredns
    MSG2 "Enabled coredns Firewall"
    for IP in ${K8S_IP[@]}; do
        firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=53 protocol=tcp accept"
        firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=53 protocol=udp accept"
        firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=9153 protocol=tcp accept"
        firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=53 protocol=tcp accept" --permanent
        firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=53 protocol=udp accept" --permanent
        firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=9153 protocol=tcp accept" --permanent
    done


    # allow k8s master node access etcd
    MSG2 "Enabled etcd Firewall"
    for IP in ${K8S_MASTER_IP[@]}; do
        firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=2379-2380 protocol=tcp accept"
        firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=2379-2380 protocol=tcp accept" --permanent
    done
}



function setup_firewalld_for_calico {
    # allow k8s all node access Calico network
    MSG1 "Setup Firewalld for Calico"
    for IP in ${K8S_IP[@]}; do
        firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=179 protocol=tcp accept"
        firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=179 protocol=tcp accept" --permanent
    done
}



function setup_firewalld_for_flannel {
    # allow k8s all node access Flannel network
    MSG1 "Setup Firewalld for Flannel"
    for IP in ${K8S_IP[@]}; do
        firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=8285 protocol=udp accept"
        firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=8472 protocol=udp accept"
        firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=8285 protocol=udp accept" --permanent
        firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=8472 protocol=udp accept" --permanent
    done
}



function setup_firewalld_for_ingress {
    # allow k8s all node accessk kubernetes/ingress-nginx
    MSG1 " Setup Firewall for ingress"
    for IP in ${K8S_IP[@]}; do
        firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=8443 protocol=tcp accept"
        firewall-cmd --zone="${K8S_FIREWALLD_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=8443 protocol=tcp accept" --permanent
    done
}



0_prepare
1_create_firewalld_zone_for_k8s
2_exposed_service_and_port_to_public_network
3_exposed_service_and_port_among_k8s_node
[ ${INSTALLED_CALICO} ] && setup_firewalld_for_calico
[ ${INSTALLED_FLANNEL} ] && setup_firewalld_for_flannel
[ ${INSTALLED_INGRESS} ] && setup_firewalld_for_ingress
