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
K8S_MASTER_IP=(
10.240.3.11
10.240.3.12
10.240.3.13)
K8S_WORKER_IP=(
10.240.3.21
10.240.3.22
10.240.3.23)
K8S_IP=(${K8S_MASTER_IP[@]} ${K8S_WORKER_IP[@]})
CONTROL_PLANE_ENDPOINT="10.240.3.10:6443"
SERVICE_CIDR="10.250.0.0/16"            # k8s serivce cidr
POD_CIDR="172.18.0.0/16"                # k8s pod network cidr
DOCKER_CIDR=""                          # docker briget network subnet      (NOT SET HERE)

# whitelist ip
WHITELIST_IP=(
10.240.0.205                            # QA's win10 ip
10.240.0.206)                           # QA's ubuntu ip

# Allow access ssh service ip
ALLOW_SSH_IP=(
10.240.0.10                             # JumpServer's IP
10.240.0.101                            # Jonas's IP
10.240.0.110                            # Jefflinux's IP
10.240.0.205                            # QA's win10 ip
10.240.0.206                            # QA's ubuntu ip
10.240.3.1)                             # Loadbalancer's IP

# Allow manager k8s ip
ALLOW_K8S_IP=(
10.240.0.10                             # JumpServer's IP
10.240.0.101                            # Jonas's IP
10.240.0.110                            # Jefflinux's IP
10.240.0.205                            # QA's win10 ip
10.240.0.206                            # QA's ubuntu ip
10.240.3.1)                             # Loadbalancer's IP

ALLOW_ICMP_IP=""                        # allow ping k8s ip
ALLOW_NODEPORT_IP=""                    # allow access k8s NodePort ip
ALLOW_HTTPS_IP=""                       # allow access k8s http/https service ip
temp_array=(${K8S_IP[@]} ${ALLOW_SSH_IP[@]} ${ALLOW_K8S_IP[@]})
ALLOW_ICMP_IP=($(tr ' ' '\n' <<< "${temp_array[@]}" | sort -u | tr '\n' ' '))       # shell array deduplicate
ALLOW_NODEPORT_IP=(${ALLOW_ICMP_IP[@]})
ALLOW_HTTPS_IP=(${ALLOW_ICMP_IP[@]})


# network & firewalld
K8S_ACCEPT_ZONE="k8s-accept"            # k8s-accept zone, allow all package, (whitelist)
K8S_DROP_ZONE="k8s-drop"                # k8s-drop zone, drop all package
INTERFACE=""                            # k8s node default interface        (NOT SET HERE)
GATEWAY=""                              # k8s node gateway                  (NOT SET HERE)
DNS=""                                  # k8s node dns, default is gateway
K8S_NODE_OS=""


# kubernetes addon
INSTALLED_CALICO="1"                    # if installed calico, set here
INSTALLED_FLANNEL=""                    # if installed flannel, set here
INSTALLED_INGRESS=""                    # if installed ingress, set here
INSTALLED_CEPHCSI="1"



function 0_prepare {
    # 1. not root exit
    [ $(id -u) -ne 0 ] && ERR "not root !" && exit $EXIT_FAILURE
    

    # 2. not ubuntu,debian, centos,rhel, exit
    [ $(uname) != "Linux" ] && ERR "not support !" && exit $EXIT_FAILURE
    source /etc/os-release
    K8S_NODE_OS=$ID
    [[ $ID != "centos" && $ID != "rhel" && $ID != "ubuntu" && $ID != "debian" ]] && ERR "not support !" && exit $EXIT_FAILURE


    # 3. install firewalld & iproute
    if ! command -v firewalld &> /dev/null; then
        case ${K8S_NODE_OS} in
            "centos" | "rhel" )
                MSG2 "installing firewalld"
                yum install -y firewalld
                systemctl disable --now iptables
                systemctl mask iptables
                systemctl enable --now firewalld ;;
            "ubuntu")
                MSG2 "installing firewalld"
                apt-get update
                apt-get install -y firewalld
                systemctl enable --now firewalld
                ufw disable ;;
            "debian")
                MSG2 "installing firewalld"
                apt-get update
                apt-get install -y firewalld
                systemctl enable --now firewalld ;;
        esac
    fi
    if ! command -v ip &> /dev/null; then
        case ${K8S_NODE_OS} in
            "centos" | "rhel")
                MSG2 "installing iproute"
                yum install -y iproute ;;
            "debian" | "ubuntu")
                MSG2 "installing iproute2"
                apt-get update
                apt-get install -y iproute2 ;;
        esac
    fi


    # 4. Get docker-ce bridge network subnet
    local docker_bridge_network_subnet=""
    if [ -z "${DOCKER_CIDR}" ]; then                # check if set DOCKER_CIDR
        case "${K8S_NODE_OS}" in                    # check if install docker-ce
            "centos" | "rhel" )
                rpm -qi docker-ce &> /dev/null ;;
            "debian" | "ubuntu" )
                dpkg -l docker-ce &> /dev/null ;;
        esac
        if [ $? -ne 0 ]; then
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
    MSG2 "Allow dhcp"
    firewall-cmd --zone="${K8S_DROP_ZONE}" --add-service=dhcpv6-client
    firewall-cmd --zone="${K8S_DROP_ZONE}" --add-service=dhcpv6-client --permanent


    # Only the specificd ip can ping
    MSG2 "Allow icmp"
    for IP in "${ALLOW_ICMP_IP[@]}"; do
        firewall-cmd --zone="$K8S_DROP_ZONE" --add-rich-rule "rule family=ipv4 source address=${IP} protocol value=icmp accept"
        firewall-cmd --zone="$K8S_DROP_ZONE" --add-rich-rule "rule family=ipv4 source address=${IP} protocol value=icmp accept" --permanent
    done


    # vrrp is a protocol used by keepalived
    MSG2 "Allow vrrp protocol"
    firewall-cmd --zone="${K8S_DROP_ZONE}" --add-protocol=vrrp
    firewall-cmd --zone="${K8S_DROP_ZONE}" --add-protocol=vrrp --permanent


    # Only the specificd ip can access ssh
    MSG2 "Allow ssh login"
    for IP in "${ALLOW_SSH_IP[@]}"; do
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} service name=ssh log prefix='SSH Access' level='notice' accept"
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} service name=ssh log prefix='SSH Access' level='notice' accept" --permanent
    done


    # Only the specificd ip can access k8s
    MSG2 "Allow manage k8s"
    for IP in "${ALLOW_K8S_IP[@]}"; do
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=${CONTROL_PLANE_ENDPOINT_PORT} protocol=tcp accept"
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=${CONTROL_PLANE_ENDPOINT_PORT} protocol=tcp accept" --permanent
    done


    # Only specified ip can access k8s NodePort
    MSG2 "Allow access k8s NodePort"
    local NODEPORT_RAGE=""
    NODEPORT_RAGE="30000-32767"
    for IP in "${ALLOW_NODEPORT_IP[@]}"; do
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=${NODEPORT_RAGE} protocol=tcp accept"
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=${NODEPORT_RAGE} protocol=tcp accept" --permanent
    done


    # Only specified ip can access http/https service
    MSG2 "Allow http and https service"
    local HTTP_PORT=""
    local HTTPS_PORT=""
    HTTP_PORT=80
    HTTPS_PORT=443
    for IP in "${ALLOW_HTTPS_IP[@]}"; do
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=${HTTP_PORT} protocol=tcp accept"
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=${HTTP_PORT} protocol=tcp accept" --permanent
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=${HTTPS_PORT} protocol=tcp accept"
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=${HTTPS_PORT} protocol=tcp accept" --permanent
    done
}



function 3_exposed_service_and_port_among_k8s_node {
    MSG1 "3. Exposed service and port among k8s node"

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
    my_ipaddress=$(ip addr show dev ${INTERFACE} | grep '\binet' | sed -n '1,1p' |awk '{print $2}' | awk -F'/' '{print $1}')       # get k8s node ip
    echo "my ip is ${my_ipaddress}"


    MSG2 "Enabled masquerade for k8s"
    firewall-cmd --zone="${K8S_ACCEPT_ZONE}" --add-masquerade
    firewall-cmd --zone="${K8S_ACCEPT_ZONE}" --add-masquerade --permanent


    # allow docker briget network
    # allow pod network cidr
    # allow service cidr
    MSG2 "Enabled docker cidr, pod netwok cidr, service cidr Firewall"
    firewall-cmd --zone="${K8S_ACCEPT_ZONE}" --add-source=${DOCKER_CIDR}
    firewall-cmd --zone="${K8S_ACCEPT_ZONE}" --add-source=${POD_CIDR}
    firewall-cmd --zone="${K8S_ACCEPT_ZONE}" --add-source=${SERVICE_CIDR}
    firewall-cmd --zone="${K8S_ACCEPT_ZONE}" --add-source=${DOCKER_CIDR} --permanent 
    firewall-cmd --zone="${K8S_ACCEPT_ZONE}" --add-source=${POD_CIDR} --permanent
    firewall-cmd --zone="${K8S_ACCEPT_ZONE}" --add-source=${SERVICE_CIDR} --permanent


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


    # allow k8s all node access kube-scheduler
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



function 4_add_whitelist_ip {
    for IP in "${WHITELIST_IP}"; do
        firewall-cmd --zone=${K8S_ACCEPT_ZONE} --add-source ${IP}
        firewall-cmd --zone=${K8S_ACCEPT_ZONE} --add-source ${IP} --permanent
    done
}



function setup_firewall_for_calico {
    # allow k8s all node access calico network
    MSG2 "Enabled Calico Firewall"
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

function setup_firewall_for_flannel {
    # allow k8s all node access Flannel network
    MSG2 "Enabled Flannel Firewall"
    for IP in "${K8S_IP[@]}"; do
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=8285 protocol=udp accept"
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=8472 protocol=udp accept"
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=8285 protocol=udp accept" --permanent
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=8472 protocol=udp accept" --permanent
    done
}

function setup_firewall_for_ingress {
    # allow k8s all node accessk kubernetes/ingress-nginx
    MSG2 "Enabled Ingress Firewall"
    for IP in "${K8S_IP[@]}"; do
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=8443 protocol=tcp accept"
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=8443 protocol=tcp accept" --permanent
    done
}

function setup_firewall_for_ceph {
    MSG2 "Enabled Ceph Firewall"
    for IP in "${K8S_IP[@]}"; do
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=8680 protocol=tcp accept"
        firewall-cmd --zone="${K8S_DROP_ZONE}" --add-rich-rule "rule family=ipv4 source address=${IP} port port=8680 protocol=tcp accept" --permanent
    done
}



0_prepare
1_create_firewalld_zone_for_k8s
2_exposed_service_and_port_to_public_network
3_exposed_service_and_port_among_k8s_node
4_add_whitelist_ip
[ ${INSTALLED_CALICO} ] && setup_firewall_for_calico
[ ${INSTALLED_FLANNEL} ] && setup_firewall_for_flannel
[ ${INSTALLED_INGRESS} ] && setup_firewall_for_ingress
[ ${INSTALLED_CEPHCSI} ] && setup_firewall_for_ceph
systemctl restart firewalld
systemctl restart docker
