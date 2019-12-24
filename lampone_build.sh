#!/bin/bash

#
# This script assembles a Pi 3 or (WiP) Pi 4 UEFI build today,
# from forked versions of upstream UEFI.
#
# It will download all dependencies, including GCC, but is
# reasonably smart about it.
#
# Only tried in Ubuntu.
#
# Regular RPi4 build with PL011:
#  ./lampone_build.sh -d lampone-wip/ -p rpi4 -t DEBUG
#
# RPi4 build with miniUART:
#  ./lampone_build.sh -d lampone-wip/ -c ./config_with_miniUART -p rpi4 -t DEBUG
#
# RPi3 build (always with miniUART today):
#  ./lampone_build.sh -d lampone-wip/ -p rpi3 -t RELEASE
#
# For Ubuntu, outside of make, python3 and a local toolchain:
# $ apt-get update && apt-get install -y uuid-dev iasl
#

# Fail if a command fails
set -e

#
# Defaults.
#
CONFIG_FILE_NAME=$(dirname $(which "$0"))/config
BASEDIR=rpi_fw
TYPE=RELEASE
PLAT=rpi4
DO_BUILD="true"
DO_SYNC="true"

usage()
{
    echo
    echo Usage: $0  [-c config] [-d dir] [-p plat] [-s] [-t type]
    echo "-c config - config file to use (default ${CONFIG_FILE_NAME})"
    echo "-d dir    - workspace directory to use (default rpi_fw)"
    echo "-p plat   - rpi4 (default) or rpi3"
    echo "-s        - just synchronize/check-out, don't build"
    echo "-S        - just build, don't synchronize/check-out"
    echo "-t type   - DEBUG or RELEASE (default)"
    echo "-T prefix - tools prefix (default downloads Linaro tools)"
    echo
    exit
}

handle_opt()
{
    local OPTION=$1
    local OPTARG=$2

    case ${OPTION} in
        c)
            CONFIG_FILE_NAME=${OPTARG}
            ;;
        d)
            BASEDIR=${OPTARG}
            ;;
        p)
            if [[ ! x"${OPTARG}" = x"rpi3" ]] && [[ ! x"${OPTARG}" = x"rpi4" ]]; then
                usage
            fi

            PLAT=${OPTARG}
            ;;
        s)
            DO_BUILD="false"
            ;;
        S)
            DO_SYNC="false"
            ;;
        t)
            if [[ ! x"${OPTARG}" = x"DEBUG" ]] && [[ ! x"${OPTARG}" = x"RELEASE" ]]; then
                usage
            fi

            TYPE=${OPTARG}
            ;;
        T)
            TOOLS_PREFIX=${OPTARG}
            ;;
        *)
            usage
            ;;
    esac
}

error()
{
    echo
    echo error: $@ 1>&2
    echo
    exit
}

info()
{
    echo
    echo info: $@
    echo
}

sync_tools()
{
    if [ ! -d "gcc5" ]; then
        mkdir gcc5
        pushd gcc5
        wget https://releases.linaro.org/components/toolchain/binaries/7.2-2017.11/aarch64-linux-gnu/gcc-linaro-7.2.1-2017.11-x86_64_aarch64-linux-gnu.tar.xz
        tar -xf gcc-linaro-7.2.1-2017.11-x86_64_aarch64-linux-gnu.tar.xz
        popd
    fi

    TOOLS_PREFIX=${BASEDIR}/gcc5/gcc-linaro-7.2.1-2017.11-x86_64_aarch64-linux-gnu/bin/aarch64-linux-gnu-
}

sync_repo()
{
    local dir=$1
    local varname="${dir}"
    while [ "${varname%-*}" != "$varname" ]; do
        varname="${varname%%-*}_${varname#*-}"
    done

    local url="$(eval echo "\"\$$varname\"")"
    local branches="$(eval echo "\"\${${varname}_branches:-master}\"")"
    local commit="$(eval echo "\"\${${varname}_commit_id:-}\"")"
    local origin="${url#https://github.com/}"
    origin="${origin%%/*}"
    local commit_is_branch="false"
    local branch="${branches%% *}"

    if [ x"${PLAT}" = x"rpi3" ]; then
        branch="${branches##* }"
    fi

    if [ -z "${commit}" ]; then
        commit="remotes/${origin}/${branch}"
        commit_is_branch="true"
    fi

    if [ ! -d "${dir}" ]; then
        info ${dir}: checking out ${commit}
        git clone --recursive -o "${origin}" -b "${branch}" --single-branch "${url}" "${dir}"
        pushd "${dir}"
        git remote set-branches "${origin}" ${branches}

        if [ "${branches%% *}" != "${branches}" ]; then
            git fetch -n --multiple "${origin}"
        fi

        if  [[ x"${commit_is_branch}" = x"true" ]]; then
            git checkout "${branch}"
        else
            git checkout "${commit}"
        fi
    elif [[ x"${commit_is_branch}" = x"true" ]]; then
        info ${dir}: rebasing to ${commit}
        pushd "${dir}"

        if ! cur=`git remote get-url "$origin" 2>/dev/null`; then
            git remote add "${origin}" "${url}"
        elif [ "${cur}" != "${url}" ]; then
            error Repo URLs changed for "${dir}", use a workspace
        fi

       git remote set-branches "${origin}" ${branches}
       git fetch -n --multiple "${origin}"
       git checkout "${branch}"
       git pull --rebase --autostash
    else
        info ${dir}: ${commit} is not a branch, not rebasing
    fi

    popd
}

build_tfa()
{
    info Building TFA
    #
    # DEBUG=1 builds are currently too large, so always build TF-A as release.
    #
    pushd tf-a
    export CROSS_COMPILE=${TOOLS_PREFIX}

    if [[ x"${TFA_PLAT}" = x"rpi3" ]]; then
        local DTB_BASE=0x10000
        local BL33_BASE=0x30000
        local TARGETS="fip all"
        local TARGET_SRC="${PWD}/build/${PLAT}/release/bl1.bin ${PWD}/build/${PLAT}/release/fip.bin"
    else
        local DTB_BASE=0x20000
        local BL33_BASE=0x30000
        local TARGETS="all"
        local TARGET_SRC="${PWD}/build/${PLAT}/release/bl31.bin"
    fi
    local EXTRA_FLAGS="$(eval echo "\"\${${PLAT}_tfa_extra_flags}\"")"

    make PLAT=${TFA_PLAT} PRELOADED_BL33_BASE=${BL33_BASE} RPI3_PRELOADED_DTB_BASE=${DTB_BASE} SUPPORT_VFP=1 RPI3_USE_UEFI_MAP=1 DEBUG=0 V=1 ${EXTRA_FLAGS} ${TARGETS}

    if [[ $? -ne 0 ]]; then
        echo TF-A build failed
        exit
    fi
    echo
    echo TF-A artifacts are ${TARGET_SRC}
    export TFA_ARTIFACT=${TARGET_SRC}
    echo
    popd
}

prep_edk2()
{
    info Preping EDK2
    export GCC5_AARCH64_PREFIX=${TOOLS_PREFIX}
    export WORKSPACE=${PWD}
    export PACKAGES_PATH=${PWD}/edk2:${PWD}/edk2-platforms:${PWD}/edk2-non-osi
    #
    # Avoid mysterious Python errors building BaseTools.
    #
    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8
    make -C edk2/BaseTools
    if [[ $? -ne 0 ]]; then
        error BaseTools build failed
    fi

    source edk2/edksetup.sh
}

build_edk2()
{
    info Building EDK2
    pushd edk2-platforms
    local BUILD_COMMIT=`git rev-parse --short HEAD`
    popd
    local BUILD_DATE=`date +%m/%d/%Y`
    local NUM_CPUS=$((`getconf _NPROCESSORS_ONLN` + 2))
    local EXTRA_FLAGS="$(eval echo "\"\${${PLAT}_edk2_extra_flags}\"")"

    if [[ x"${PLAT}" = x"rpi3" ]]; then
        cp ${TFA_ARTIFACT} ${BASEDIR}/edk2-non-osi/Platform/RaspberryPi/${UEFI_PLAT}/TrustedFirmware
    else
        EXTRA_FLAGS+=" -D TFA_BUILD_ARTIFACT=${TFA_ARTIFACT}"
    fi

    build -n ${NUM_CPUS} -a AARCH64 -t GCC5 -b ${TYPE} -p edk2-platforms/Platform/RaspberryPi/${UEFI_PLAT}/${UEFI_PLAT}.dsc --pcd gEfiMdeModulePkgTokenSpaceGuid.PcdFirmwareVersionString=L"Lampone ${BUILD_COMMIT} on ${BUILD_DATE}" ${EXTRA_FLAGS}
    if [[ $? -ne 0 ]]; then
        error UEFI build failed
    fi
    echo
    echo Finished building ${BASEDIR}/Build/${UEFI_PLAT}/${TYPE}_GCC5/FV/RPI_EFI.fd
    echo
}

while getopts c:d:p:sSt:T: OPTION; do
    handle_opt ${OPTION} ${OPTARG}
done
shift $((OPTIND - 1))

echo Config is ${CONFIG_FILE_NAME}
echo Workspace is ${BASEDIR}
echo Building ${TYPE} for ${PLAT}

#
# Load configuration
#
if [ ! -f "${CONFIG_FILE_NAME}" ]; then
    error Missing configuration file ${CONFIG_FILE_NAME}
else
    . ${CONFIG_FILE_NAME}
fi

BASEDIR=${PWD}/${BASEDIR}
if [ ! -d "${BASEDIR}" ]; then
    echo Creating ${BASEDIR}
    mkdir ${BASEDIR}
    DO_SYNC="true"
fi
cd ${BASEDIR}

if [[ x"${DO_SYNC}" = x"true" ]]; then
    if [ x"${TOOLS_PREFIX}" = x"" ]; then
        sync_tools
    fi
    info Tools are ${TOOLS_PREFIX}

    for dir in ${repositories}; do
        sync_repo $dir
    done
else
    info Not syncing as requested
fi

if [[ x"${PLAT}" = x"rpi3" ]]; then
    UEFI_PLAT=RPi3
    TFA_PLAT=rpi3
else
    UEFI_PLAT=RPi4
    TFA_PLAT=rpi4
fi

if [[ x"${DO_BUILD}" = x"true" ]]; then
    build_tfa
    prep_edk2
    build_edk2
else
    info Not building as requested
fi

exit
