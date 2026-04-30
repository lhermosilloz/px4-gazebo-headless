#!/bin/bash

function show_help {
    echo ""
    echo "Usage: ${0} [-h | -n COUNT | -v VEHICLE | -w WORLD] [HOST_API | HOST_QGC HOST_API]"
    echo ""
    echo "Run a headless px4-gazebo simulation in a docker container. The"
    echo "available vehicles and worlds are the ones available in PX4"
    echo "(i.e. when running e.g. \`make px4_sitl gz_x500\`)"
    echo ""
    echo "  -h         Show this help"
    echo "  -n COUNT   Number of vehicles to spawn (default: 1)"
    echo "  -v VEHICLE Set the vehicle (default: gz_x500)"
    echo "  -w WORLD   Set the world (default: default)"
    echo ""
    echo "  <HOST_API> is the host or IP to which PX4 will send MAVLink on UDP port 14540"
    echo "  <HOST_QGC> is the host or IP to which PX4 will send MAVLink on UDP port 14550"
    echo ""
    echo "With multiple vehicles (-n N), MAVLink ports are offset per instance:"
    echo "  Instance 0: API=14540  QGC=14550"
    echo "  Instance 1: API=14541  QGC=14551"
    echo "  Instance i: API=14540+i  QGC=14550+i"
    echo ""
    echo "By default, MAVLink is sent to the host."
}

function get_ip {
    output=$(getent hosts "$1" | head -1 | awk '{print $1}')
    if [ -z $output ];
    then
        # No output, assume IP
        echo $1
    else
        # Got IP, use it
        echo $output
    fi
}

OPTIND=1 # Reset in case getopts has been used previously in the shell.

vehicle=gz_x500
world=default
num_vehicles=1

while getopts "h?n:v:w:" opt; do
    case "$opt" in
    h|\?)
        show_help
        exit 0
        ;;
    n)  num_vehicles=$OPTARG
        ;;
    v)  vehicle=$OPTARG
        ;;
    w)  world=$OPTARG
        ;;
    esac
done

shift $((OPTIND-1))

if [ "$#" -eq 1 ]; then
    IP_QGC=$(get_ip "$1")
elif [ "$#" -eq 2 ]; then
    IP_API=$(get_ip "$1")
    IP_QGC=$(get_ip "$2")
elif [ "$#" -gt 2 ]; then
    show_help
    exit 1;
fi

Xvfb :99 -screen 0 1600x1200x24+32 &
${SITL_RTSP_PROXY}/build/sitl_rtsp_proxy &

# Patch px4-rc.mavlink with target IPs once. Port numbers ($udp_gcs_port_local
# and $udp_offboard_port_local) are variables inside PX4's startup scripts and
# are automatically offset by the instance ID, so this single patch covers all
# instances correctly.
source ${WORKSPACE_DIR}/edit_rcS.bash ${IP_API} ${IP_QGC} || exit 1

# Kill all background PX4 children when the container stops.
trap 'kill $(jobs -p) 2>/dev/null; wait' EXIT INT TERM

for i in $(seq 0 $((num_vehicles - 1))); do
    instance_dir="/tmp/px4_instance_${i}"
    mkdir -p "${instance_dir}"

    cmd=(
        env
        HEADLESS=1
        PX4_SIM_MODEL=${vehicle}
        PX4_GZ_WORLD=${world}
        PX4_GZ_MODEL_NAME=${vehicle}_${i}
        ${FIRMWARE_DIR}/build/bin/px4
        -i ${i}
    )

    if [ "$i" -lt "$((num_vehicles - 1))" ]; then
        (cd "${instance_dir}" && "${cmd[@]}") &
        # Give instance 0 enough time to start the gz server before the next
        # instance tries to connect and spawn its model.
        sleep 5
    else
        # Last instance runs in the foreground to keep the container alive.
        (cd "${instance_dir}" && "${cmd[@]}")
    fi
done
