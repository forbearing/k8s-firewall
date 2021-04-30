#!/usr/bin/env bash
# Author:       Jonas
# version       1.0
# Date:         2021/4/21
# Description:  setup firewalld for k8s cluster

EXIT_SUCCESS=0
EXIT_FAILURE=1
ERR(){ echo -e "\033[31m\033[01m$1\033[0m"; }
MSG1(){ echo -e "\n\n\033[32m\033[01m$1\033[0m\n"; }
MSG2(){ echo -e "\n\033[33m\033[01m$1\033[0m"; }


# k8s ip
K8S_MASTER_IP=(10.230.11.11
               10.230.11.12
               10.230.11.13)
K8S_WORKER_IP=(10.230.11.21
               10.230.11.22
               10.230.11.23)
K8S_IP=(${K8S_MASTER_IP[@]} ${K8S_WORKER_IP[@]})
ALLOW_SSH_IP=(10.230.0.2
               10.230.0.1
               10.230.11.10
               10.230.0.3)
ALLOW_K8S_IP=(10.230.0.2
               10.230.0.1
               10.230.11.10
              10.230.0.3)
CONTROL_PLANE_ENDPOINT="10.230.11.10:8443"


# network cidr
K8S_ACCEPT_ZONE="k8s-accept"            # k8s-accept zone, allow all package
K8S_DROP_ZONE="k8s-drop"                # k8s-drop zone, drop all package
INTERFACE=""                            # k8s node default interface        (NOT SET HERE)
DOCKER_CIDR=""                          # docker briget network subnet      (NOT SET HERE)
POD_CIDR="192.168.0.0/16"               # k8s pod network cidr
SERVICE_CIDR="172.18.0.0/16"            # k8s serivce cidr
GATEWAY=""                              # k8s node gateway                  (NOT SET HERE)
DNS=""                                  # k8s node dns, default is gateway
K8S_NODE_OS=""



INSTALLED_CALICO="1"            # if installed calico, set here
INSTALLED_FLANNEL=""            # if installed flannel, set here
INSTALLED_INGRESS="1"           # if installed ingress, set here



function 0_prepare {
    # 1. not root exit
    [ $(id -u) -ne 0 ] && ERR "not root !" && exit $EXIT_FAILURE
    

    # 2. not ubuntu,debian, centos,rhel, exit
    [ $(uname) != "Linux" ] && ERR "not support !" && exit $EXIT_FAILURE
    source /etc/os-release
    K8S_NODE_OS=$ID
    [[ $ID != "centos" && $ID != "rhel" && $ID != "ubuntu" && $ID != "debian" ]] && ERR "not support !" && exit $EXIT_FAILURE


    # 3. install firewalld & iproute
    command -v firewalld &> /dev/null
    if [[ $? != 0 ]]; then
        case ${K8S_NODE_OS} in
            "centos" | "rhel" )
                MSG2 "installing firewalld"
                yum install -y firewalld
                systemctl disable --now iptables
                systemctl mask iptable
                systemctl enable --now firewalld
                ;;
            "ubuntu")
                MSG2 "installing firewalld"
                apt-get update
                apt-get install firewalld
                systemctl enable --now firewalld
                ufw disable
                ;;
            "debian")
                MSG2 "installing firewalld"
                apt-get update
                apt-get install firewalld
                systemctl enable --now firewalld
                ;;
        esac
    fi
    command -v ip &> /dev/null
    if [[ $? != 0 ]]; then
        case ${K8S_NODE_OS} in
            "centos" | "rhel")
                MSG2 "installing iproute"
                yum install -y iproute
                ;;
            "debian" | "ubuntu")
                MSG2 "installing iproute2"
                apt-get update
                apt-get install iproute2
                ;;
        esac
    fi


    # 4. Get docker-ce bridge network subnet
    local docker_bridge_network_subnet=""
    if [ -z "${DOCKER_CIDR}" ]; then                # check if set DOCKER_CIDR
        case "${K8S_NODE_OS}" in                    # check if install docker-ce
            "centos" | "rhel" )
                rpm -qi docker-ce &> /dev/null ;;
            "debian" | "ubuntu" )
                dpkg -l docker-ce ;;
        esac
        if [ $? != 0 ]; then
            DOCKER_CIDR="172.17.0.0/16"             # if not install docker-ce, set the default DOCKER_CIDR value
        else                                        # if install docker-ce, get the DOCKER_CIDR value
            docker_bridge_network_subnet=$(docker network list | grep bridge | awk '{print $1}')
            docker_bridge_network_subnet=$(docker inspect ${docker_bridge_network_subnet} | grep "Subnet" | awk -F':|,' '{print $2}')
            docker_bridge_network_subnet=$(echo ${docker_bridge_network_subnet} | tr -d '"')
            DOCKER_CIDR=${docker_bridge_network_subnet}
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

    # new two firewalld zone
    #   1. K8S_DROP_ZONE drop all
    #   2. K8S_ACCEPT_ZONE accept all
    #   3. Default zone is K8S_DROP_ZONE
    #   4. change interface to K8S_DROP_ZONE, so all incoming traffic matched by K8S_DROP_ZONE (DROP ALL)
    systemctl enable --now firewalld
    firewall-cmd --delete-zone=${K8S_DROP_ZONE} --permanent
    firewall-cmd --delete-zone=${K8S_ACCEPT_ZONE} --permanent
    firewall-cmd --reload

    firewall-cmd --new-zone="${K8S_DROP_ZONE}" --permanent
    firewall-cmd --new-zone="${K8S_ACCEPT_ZONE}" --permanent
    firewall-cmd --zone="${K8S_DROP_ZONE}" --set-target=DROP --permanent
    firewall-cmd --zone="${K8S_ACCEPT_ZONE}" --set-target=ACCEPT --permanent
    firewall-cmd --reload

    firewall-cmd --set-default-zone="${K8S_DROP_ZONE}"
    firewall-cmd --zone="${K8S_DROP_ZONE}" --change-interface="${INTERFACE}"
    firewall-cmd --zone="${K8S_DROP_ZONE}" --change-interface="${INTERFACE}" --permanent
    firewall-cmd --reload
}



function 2_exposed_service_and_port_to_public_network {
    # Exposed service and port to public network
    MSG1 "2. Exposed service and port to public network" 

    local CONTROL_PLANE_ENDPOINT_IP=""
    local CONTROL_PLANE_ENDPOINT_PORT=""
    local OLD_IFS
    OLD_IFS=${IFS}
    IFS=":"
    temp_arr=($CONTROL_PLANE_ENDPOINT)
    IFS=${OLD_IFS}
    CONTROL_PLANE_ENDPOINT_IP=${temp_arr[0]}
    CONTROL_PLANE_ENDPOINT_PORT=${temp_arr[1]}


    # DHCP requests port: 67/udp Outbound, 68/udp Inbound
    MSG2 "allow dhcp"
    firewall-cmd --zone="${K8S_DROP_ZONE}" --add-service=dhcpv6-client
    firewall-cmd --zone="${K8S_DROP_ZONE}" --add-service=dhcpv6-client --permanent


    # Only the specificd ip can ping
    MSG2 "allow icmp"
    local ALLOW_ICMP_IP=""
    temp_array=(${K8S_IP[@]} ${ALLOW_SSH_IP[@]} ${ALLOW_K8S_IP[@]})
    ALLOW_ICMP_IP=($(tr ' ' '\n' <<< "${temp_array[@]}" | sort -u | tr '\n' ' '))       # shell array deduplicate
    for IP in "${ALLOW_ICMP_IP[@]}"; do
        firewall-cmd --zone="$K8S_DROP_ZONE" --add-rich-rule "rule family=ipv4 source address=${IP} protocol value=icmp accept"
        firewall-cmd --zone="$K8S_DROP_ZONE" --add-rich-rule "rule family=ipv4 source address=${IP} protocol value=icmp accept" --permanent
    done


    # vrrp is a protocol used by keepalived
    MSG2 "allow vrrp protocol"
    firewall-cmd --zone="${K8S_DROP_ZONE}" --add-protocol=vrrp
    firewall-cmd --zone="${K8S_DROP_ZONE}" --add-protocol=vrrp --permanent


    # Only the specificd ip can access ssh
    MSG2 "allow access ssh"
    for IP in "${ALLOW_SSH_IP[@]}"; do
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} service name=ssh log prefix='SSH Access' level='notice' accept"
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} service name=ssh log prefix='SSH Access' level='notice' accept" --permanent
    done


    # Only the specificd ip can access k8s
    MSG2 "allow access k8s"
    for IP in "${ALLOW_K8S_IP[@]}"; do
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=${CONTROL_PLANE_ENDPOINT_PORT} protocol=tcp accept"
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=${CONTROL_PLANE_ENDPOINT_PORT} protocol=tcp accept" --permanent
    done


    # Only loadbalancer ip can access k8s NodePort
    MSG2 "allow access k8s NodePort"
    firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 port port=30000-32767 protocol=tcp accept"
    firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 port port=30000-32767 protocol=tcp accept" --permanent


    MSG2 "allow access http and https"
    firewall-cmd --zone="${K8S_DROP_ZONE}" --add-service=http
    firewall-cmd --zone="${K8S_DROP_ZONE}" --add-service=http --permanent
    firewall-cmd --zone="${K8S_DROP_ZONE}" --add-service=https
    firewall-cmd --zone="${K8S_DROP_ZONE}" --add-service=https --permanent
}



function 3_exposed_service_and_port_among_k8s_node {
    MSG1 "3. Setup Firewall for Kubernetes Service"

    local CONTROL_PLANE_ENDPOINT_IP=""
    local CONTROL_PLANE_ENDPOINT_PORT=""
    local OLD_IFS
    local my_ipaddress=""
    OLD_IFS=${IFS}
    IFS=":"
    temp_arr=($CONTROL_PLANE_ENDPOINT)
    IFS=${OLD_IFS}
    CONTROL_PLANE_ENDPOINT_IP=${temp_arr[0]}
    CONTROL_PLANE_ENDPOINT_PORT=${temp_arr[1]}
    my_ipaddress=$(ip addr show dev ${INTERFACE} | grep '\binet' | awk '{print $2}' | awk -F'\/' '{print $1}')       # get k8s node ip


    MSG2 "Enabled masquerade for K8S"
    firewall-cmd --zone="${K8S_ACCEPT_ZONE}" --add-masquerade
    firewall-cmd --zone="${K8S_ACCEPT_ZONE}" --add-masquerade --permanent


    # allow docker briget network
    # allow pod network cidr
    # allow service cidr
    MSG2 "Enabled docker cidr, pod netwok cidr, service cidr firewall"
    firewall-cmd --zone="${K8S_ACCEPT_ZONE}" --zone=trusted --add-source=${DOCKER_CIDR}
    firewall-cmd --zone="${K8S_ACCEPT_ZONE}" --zone=trusted --add-source=${POD_CIDR}
    firewall-cmd --zone="${K8S_ACCEPT_ZONE}" --zone=trusted --add-source=${SERVICE_CIDR}
    firewall-cmd --zone="${K8S_ACCEPT_ZONE}" --zone=trusted --add-source=${DOCKER_CIDR} --permanent 
    firewall-cmd --zone="${K8S_ACCEPT_ZONE}" --zone=trusted --add-source=${POD_CIDR} --permanent
    firewall-cmd --zone="${K8S_ACCEPT_ZONE}" --zone=trusted --add-source=${SERVICE_CIDR} --permanent


    # allow k8s all node access kube-apiserver
    if [[ "${K8S_MASTER_IP[*]}" =~ ${my_ipaddress} ]]; then                    # k8s master run
        MSG2 "Enabled kube-apiserver Firewall"
        for IP in "${K8S_IP[@]}"; do
            firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=6443 protocol=tcp accept"
            firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=6443 protocol=tcp accept" --permanent
        done
        # allow k8s all node access control plane endpoint port
        for IP in "${K8S_IP[@]}"; do
            firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=${CONTROL_PLANE_ENDPOINT_PORT} protocol=tcp accept"
            firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=${CONTROL_PLANE_ENDPOINT_PORT} protocol=tcp accept" --permanent
        done
    fi


    # allow k8s all node access kube-controller-manager
    if [[ "${K8S_MASTER_IP[*]}" =~ ${my_ipaddress} ]]; then
        MSG2 "Enable kube-controller-manager Firewall"
        for IP in "${K8S_IP[@]}"; do
            firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=10257 protocol=tcp accept"
            firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=10257 protocol=tcp accept" --permanent
        done
    fi


    # allow k8s all node access kube-scheduler-manager
    if [[ "${K8S_MASTER_IP[*]}" =~ ${my_ipaddress} ]]; then
    MSG2 "Enable kube-scheduler Firewall"
    for IP in "${K8S_IP[@]}"; do
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=10259 protocol=tcp accept"
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=10259 protocol=tcp accept" --permanent
    done
    fi


    # allow k8s all node access kubelet
    MSG2 "Enabled kubelet Firewall"
    for IP in "${K8S_IP[@]}"; do
        #firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=10248 protocol=tcp accept"
        #firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=10248 protocol=tcp accept" --permanent
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=10250 protocol=tcp accept"
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=10255 protocol=tcp accept"
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=10250 protocol=tcp accept" --permanent
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=10255 protocol=tcp accept" --permanent
    done


    # allow k8s all node access kube-proxy
    MSG2 "Enabled kube-proxy Firewall"
    for IP in "${K8S_IP[@]}"; do
        #firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=10249 protocol=tcp accept"
        #firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=10249 protocol=tcp accept" --permanent
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=10256 protocol=tcp accept"
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=10256 protocol=tcp accept" --permanent
    done


    # allow k8s all node access etcd
    if [[ "${K8S_MASTER_IP[*]}" =~ ${my_ipaddress} ]]; then
        MSG2 "Enabled etcd Firewall"
        for IP in "${K8S_IP[@]}"; do
            firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=2379-2380 protocol=tcp accept"
            firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=2379-2380 protocol=tcp accept" --permanent
        done
    fi


    # allow k8s all node access coredns
    MSG2 "Enabled coredns Firewall"
    for IP in "${K8S_IP[@]}"; do
        #firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=9153 protocol=tcp accept"
        #firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=9153 protocol=tcp accept" --permanent
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=53 protocol=tcp accept"
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=53 protocol=tcp accept" --permanent
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=53 protocol=udp accept"
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=53 protocol=udp accept" --permanent
    done
}



function setup_firewalld_for_calico {
    # allow k8s all node access calico network
    MSG2 "Setup Firewalld for Calico"
    for IP in "${K8S_IP[@]}"; do
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=179 protocol=tcp accept"
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=179 protocol=tcp accept" --permanent
    done

    # calico use IP in IP or VXLAN overlay networking
    # reference: https://docs.projectcalico.org/getting-started/kubernetes/requirements

    # Calico networking with IP-in-IP enabled (default)
    firewall-cmd --zone="${K8S_DROP_ZONE}" --add-protocol=ipip
    firewall-cmd --zone="${K8S_DROP_ZONE}" --add-protocol=ipip --permanent
    # Calico networking with VXLAN enabled
    #firewall-cmd --zone="${K8S_DROP_ZONE}" --addd-port=4789/udp
    #firewall-cmd --zone="${K8S_DROP_ZONE}" --addd-port=4789/udp --permanent
    # Calico networking with Typha enabled
    #firewall-cmd --zone="${K8S_DROP_ZONE}" --add-port=5473/tcp
    #firewall-cmd --zone="${K8S_DROP_ZONE}" --add-port=5473/tcp --permanent

}



function setup_firewalld_for_flannel {
    # allow k8s all node access Flannel network
    MSG2 "Setup Firewalld for Flannel"
    for IP in "${K8S_IP[@]}"; do
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=8285 protocol=udp accept"
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=8472 protocol=udp accept"
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=8285 protocol=udp accept" --permanent
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=8472 protocol=udp accept" --permanent
    done
}



function setup_firewalld_for_ingress {
    # allow k8s all node accessk kubernetes/ingress-nginx
    MSG2 " Setup Firewall for ingress"
    for IP in "${K8S_IP[@]}"; do
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=8443 protocol=tcp accept"
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=8443 protocol=tcp accept" --permanent
    done
}



0_prepare
1_create_firewalld_zone_for_k8s
2_exposed_service_and_port_to_public_network
3_exposed_service_and_port_among_k8s_node
[ ${INSTALLED_CALICO} ] && setup_firewalld_for_calico
[ ${INSTALLED_FLANNEL} ] && setup_firewalld_for_flannel
[ ${INSTALLED_INGRESS} ] && setup_firewalld_for_ingress
systemctl restart firewalld
systemctl restart docker
