#!/usr/bin/env bash

# Copyright (C) 2021 Jingli Chen (Wine93), NetEase Inc.

# chunkserver
# ├── conf
# │   └── chunkserver.conf
# ├── logs
# │   └── chunkserver.pid
# ├── sbin
# │   ├── servicectl
# │   └── curvebs-chunkserver
# └── lib
#     └── chunkserver_lib.so

############################  GLOBAL VARIABLES
g_stor=""
g_prefix=""
g_only=""
g_project_name=""
g_etcd_version="v3.4.10"
g_util_dir="$(dirname $(realpath $0))"
g_curve_dir="$(dirname $g_util_dir)"
g_build_release=0

g_color_yellow=`printf '\033[33m'`
g_color_red=`printf '\033[31m'`
g_color_normal=`printf '\033[0m'`

############################  BASIC FUNCTIONS
msg() {
    printf '%b' "$1" >&2
}

success() {
    msg "$g_color_yellow[✔]$g_color_normal [$g_project_name] ${1}${2}"
}

die() {
    msg "$g_color_red[✘]$g_color_normal [$g_project_name] ${1}${2}"
    exit 1
}


############################ FUNCTIONS
usage () {
    cat << _EOC_
Usage:
    install.sh --stor=bs/fs --prefix=PREFIX --only=TARGET

Examples:
    install.sh --stor=bs --prefix=/usr/local/curvebs --only=*
    install.sh --stor=bs --prefix=/usr/local/curvebs --only=chunkserver
    install.sh --stor=fs --prefix=/usr/local/curvefs --only=metaserver
    install.sh --stor=bs --prefix=/usr/local/curvebs --only=etcd --etcd_version="v3.4.10"
_EOC_
}

get_options() {
    local long_opts="stor:,prefix:,only:,etcd_version:,help"
    local args=`getopt -o povh --long $long_opts -n "$0" -- "$@"`
    eval set -- "${args}"
    while true
    do
        case "$1" in
            -s|--stor)
                g_stor=$2
                shift 2
                ;;
            -p|--prefix)
                g_prefix=$2
                shift 2
                ;;
            -o|--only)
                g_only=$2
                shift 2
                ;;
            -v|--etcd_version)
                g_etcd_version=$2
                shift 2
                ;;
            -h|--help)
                usage
                exit 1
                ;;
            --)
                shift
                break
                ;;
            *)
                exit 1
                ;;
        esac
    done
}

get_build_mode() {
    grep "release" .BUILD_MODE > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        g_build_release=1
    fi
}

strip_debug_info() {
    if [ $g_build_release -eq 1 ]; then
        # binary file generated by bazel isn't writable by default
        chmod +w $1
        objcopy --only-keep-debug $1 $1.dbg-sym
        objcopy --strip-debug $1
        objcopy --add-gnu-debuglink=$1.dbg-sym $1
        chmod -w $1
    fi
}

create_project_dir() {
    mkdir -p $1/{conf,logs,sbin,lib,data}
    if [ $? -eq 0 ]; then
        success "create project directory $1 success\n"
    else
        die "create directory $1 failed\n"
    fi
}

copy_file() {
    cp -f "$1" "$2"
    if [ $? -eq 0 ]; then
        success "copy file $1 to $2 success\n"
    else
        die "copy file $1 to $2 failed\n"
    fi
}

list_bs_targets() {
    bazel query 'kind("cc_binary", //src/...)'
    bazel query 'kind("cc_binary", //tools/...)'
    bazel query 'kind("cc_binary", //nebd/src/...)'
    bazel query 'kind("cc_binary", //nbd/src/...)'
}

get_targets() {
    if [ "$g_stor" == "bs" ]; then
        list_bs_targets | grep -E "$g_only"
    elif [ "$g_stor" == "fs" ]; then
        bazel query 'kind("cc_binary", //curvefs/src/...)' | grep -E "$g_only"
    fi
}

gen_servicectl() {
    local src="$g_util_dir/servicectl.sh"
    local dst="$4/servicectl"
    sed -e "s|__PROJECT__|$1|g" \
        -e "s|__BIN_FILENAME__|$2|g" \
        -e "s|__START_ARGS__|$3|g" \
        $src > $dst \
    && chmod a+x $dst

    if [ $? -eq 0 ]; then
        success "generate servicectl success\n"
    else
        die "generate servicectl failed\n"
    fi
}

install_curvebs() {
    declare -A rename_binary
    rename_binary["chunkserver"]="curvebs-chunkserver"
    rename_binary["curvemds"]="curvebs-mds"
    rename_binary["snapshotcloneserver"]="curvebs-snapshotclone"
    rename_binary["curve_tool"]="curve_ops_tool"
    rename_binary["curvefsTool"]="curvebs-tool"

    for target in `get_targets`
    do
        # //src/tools:curve_tool
        # //src/mds/main:curvemds
        # //tools:curvefsTool
        # //nebd/src/part2:nebd-server
        # //nbd/src:curve-nbd
        local regex_target="//((src/)?([^:/]+)([^:]*)):(.+)"
        if [[ ! $target =~ $regex_target ]]; then
            die "unknown target: $target\n"
        fi

        local project_name="${BASH_REMATCH[3]}"  # ex: chunkserver
        if [ $project_name == "snapshotcloneserver" ]; then
            project_name="snapshotclone"
        fi
        g_project_name=$project_name
        local project_prefix="$g_prefix/$project_name"  # ex: /curvebs/chunkserver

        local project_bin_filename=${BASH_REMATCH[5]}  # ex: curvebs_chunkserver
        local bazel_dir="$g_curve_dir/bazel-bin"
        local binary="$bazel_dir/${BASH_REMATCH[1]}/$project_bin_filename"
        project_bin_filename=${rename_binary[$project_bin_filename]:-${project_bin_filename}}

        # The below actions:
        #   1) create project directory
        #   2) copy binary to project directory
        #   3) strip debug information
        create_project_dir $project_prefix
        copy_file "$binary" "$project_prefix/sbin/$project_bin_filename"
        strip_debug_info "$project_prefix/sbin/$project_bin_filename"

        success "install $project_name success\n"
    done
}


install_curvefs() {
    for target in `get_targets`
    do
        local regex_target="//(curvefs/src/([^:]+)):(.+)"
        if [[ ! $target =~ $regex_target ]]; then
            die "unknown target: $target\n"
        fi

        local project_name="${BASH_REMATCH[2]}"  # ex: metaserver
        g_project_name=$project_name
        local project_prefix="$g_prefix/$project_name"  # ex: /usr/local/curvefs/metaserver

        local project_bin_filename=${BASH_REMATCH[3]}  # ex: curvefs_metaserver
        local bazel_dir="$g_curve_dir/bazel-bin"
        local binary="$bazel_dir/${BASH_REMATCH[1]}/$project_bin_filename"

        # The below actions:
        #   1) create project directory
        #   2) copy binary to project directory
        #   3) generate servicectl script into project directory.
        create_project_dir $project_prefix
        copy_file "$binary" "$project_prefix/sbin"
        strip_debug_info "$project_prefix/sbin/$project_bin_filename"
        gen_servicectl \
            $project_name \
            $project_bin_filename \
            '--confPath=$g_conf_file' \
            "$project_prefix/sbin"

        success "install $project_name success\n"
    done
}

install_playground() {
    for role in {"etcd","mds","chunkserver"}; do
        for ((i=0;i<3;i++)); do
            mkdir -p "${g_prefix}"/playground/"${role}""${i}"/{conf,data,logs}
        done
    done
}

download_etcd() {
    local now=`date +"%s%6N"`
    local nos_url="https://curve-build.nos-eastchina1.126.net"
    local src="${nos_url}/etcd-${g_etcd_version}-linux-amd64.tar.gz"
    local tmpfile="/tmp/$now-etcd-${g_etcd_version}-linux-amd64.tar.gz"
    local dst="$1"

    msg "download etcd: $src to $dst\n"

    # download etcd tarball and decompress to dst directory
    mkdir -p $dst &&
        curl -L $src -o $tmpfile &&
        tar -zxvf $tmpfile -C $dst --strip-components=1 >/dev/null 2>&1

    local ret=$?
    rm -rf $tmpfile
    if [ $ret -ne 0 ]; then
        die "download etcd-$g_etcd_version failed\n"
    else
        success "download etcd-$g_etcd_version success\n"
    fi
}

install_etcd() {
    local project_name="etcd"
    g_project_name=$project_name

    # The below actions:
    #   1) download etcd tarball from github
    #   2) create project directory
    #   3) copy binary to project directory
    #   4) generate servicectl script into project directory.
    local now=`date +"%s%6N"`
    local dst="/tmp/$now/etcd-$g_etcd_version"
    download_etcd $dst
    local project_prefix="$g_prefix/etcd"
    create_project_dir $project_prefix
    copy_file "$dst/etcd" "$project_prefix/sbin"
    copy_file "$dst/etcdctl" "$project_prefix/sbin"
    gen_servicectl \
        $project_name \
        "etcd" \
        '--config-file=$g_project_prefix/conf/etcd.conf' \
        "$project_prefix/sbin"

    rm -rf "$dst"
    success "install $project_name success\n"
}

install_monitor() {
    local project_name="monitor"
    g_project_name=$project_name

    local project_prefix="$g_prefix/monitor"
    if [ "$g_stor" == "bs" ]; then
        local dst="monitor"
    else
        local dst="curvefs/monitor"
    fi
    mkdir -p $project_prefix
    mkdir -p "$project_prefix/prometheus"
    mkdir -p "$project_prefix/data"
    copy_file "$dst/target_json.py" "$project_prefix"
    copy_file "$dst/target.ini" "$project_prefix"

    success "install $project_name success\n"
}

install_tools-v2() {
    local project_name="tools-v2"
    g_project_name=$project_name
    project_prefix="$g_prefix/tools-v2"
    mkdir -p $project_prefix/sbin
    mkdir -p $project_prefix/conf
    copy_file "$project_name/sbin/curve" "$project_prefix/sbin"
    copy_file "$project_name/pkg/config/curve.yaml" "$g_prefix/conf"
}

main() {
    get_options "$@"
    get_build_mode

    if [[ -n "$g_stor" && "$g_stor" != "bs" && "$g_stor" != "fs" ]]; then
        die "stor option must be either bs or fs\n"
    fi

    if [[ $g_prefix == "" || $g_only == "" ]]; then
        die "prefix option and only option must not be empty\n"
    elif [ "$g_only" == "etcd" ]; then
        install_etcd
    elif [ "$g_only" == "monitor" ]; then
        install_monitor
    elif [ "$g_stor" == "bs" ]; then
        install_curvebs
        install_playground
    else
        install_curvefs
    fi
    install_tools-v2
}

############################  MAIN()
main "$@"
