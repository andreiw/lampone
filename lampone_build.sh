#!/bin/bash

#
# This script assembles a Pi 3 or (hacky) Pi 4 UEFI build today,
# from forked versions of upstream UEFI (edk2-platforms) and
# TF-A. It will download all dependencies, including GCC, but is
# reasonably smart about it.
#
# Only tried in Ubuntu.
#
# Ex.:
#  ./lampone_build.sh -d lampone-wip/ -p rpi4 -t DEBUG
#  ./lampone_build.sh -d lampone-wip/ -p rpi3 -t RELEASE
#
usage()
{
    echo
    echo Usage: $0 [-d dir] [-p plat] [-t type]
    echo "-d dir  - workspace directory to use (default rpi_fw)"    
    echo "-p plat - rpi3 (default) or rpi4"
    echo "-t type - DEBUG or RELEASE (default)"
    echo
    exit
}

error()
{
    echo
    echo $0 error: $@
    echo
    exit
}

build_tfa()
{
    #
    # DEBUG=1 builds are currently too large, so always build TF-A as release.
    #
    pushd tf-a
    export CROSS_COMPILE=${BASEDIR}/gcc5/gcc-linaro-7.2.1-2017.11-x86_64_aarch64-linux-gnu/bin/aarch64-linux-gnu-
    make PLAT=${PLAT} PRELOADED_BL33_BASE=0x30000 RPI3_PRELOADED_DTB_BASE=0x10000 SUPPORT_VFP=1 RPI3_USE_UEFI_MAP=1 DEBUG=0 V=1 fip all
    if [[ $? -ne 0 ]]; then
        echo TF-A build failed
        exit
    fi
    export TFA_BUILD_DIR=${PWD}/build/$PLAT/release
    echo
    echo TF-A artifacts are under ${TFA_BUILD_DIR}
    echo
    popd
}

prep_edk2()
{
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

    pushd edk2-platforms
    if [[ ! x"${PLAT}" = x"rpi3" ]]; then
        git checkout pi4-hack
    else
        git checkout master
    fi
    popd
}

build_edk2()
{
    pushd edk2-platforms
    BUILD_COMMIT=`git rev-parse --short HEAD`
    popd
    BUILD_DATE=`date +%m/%d/%Y`
    COMMON_OPTS="-DTFA_BUILD_DIR=${TFA_BUILD_DIR}"
    NUM_CPUS=$((`getconf _NPROCESSORS_ONLN` + 2))
    build -n $NUM_CPUS -a AARCH64 -t GCC5 -b ${TYPE} -p edk2-platforms/Platform/RaspberryPi/RPi3/RPi3.dsc ${COMMON_OPTS}  --pcd gEfiMdeModulePkgTokenSpaceGuid.PcdFirmwareVersionString=L"Lampone ${BUILD_COMMIT} on ${BUILD_DATE}"
    if [[ $? -ne 0 ]]; then
        error UEFI build failed
    fi
    echo
    echo Finished building ${BASEDIR}/Build/RPi3/${TYPE}_GCC5/FV/RPI_EFI.fd
    echo
}

#
# Defaults.
#
export BASEDIR=rpi_fw
export TYPE=RELEASE
export PLAT=rpi3

while getopts d:p:t: OPTION; do
    case $OPTION in
        d)
            export BASEDIR=${OPTARG}
            ;;
        p)
            if [[ ! x"$OPTARG" = x"rpi3" ]] && [[ ! x"$OPTARG" = x"rpi4" ]]; then
                usage
            fi
                      
            export PLAT=${OPTARG}
            ;;
        t)
            if [[ ! x"$OPTARG" = x"DEBUG" ]] && [[ ! x"$OPTARG" = x"RELEASE" ]]; then
                usage
            fi
                      
            export TYPE=${OPTARG}
            ;;
        *)
            usage
            ;;
    esac
done
shift $((OPTIND - 1))

export BASEDIR=${PWD}/${BASEDIR}
if [ ! -d "${BASEDIR}" ]; then
    echo Creating ${BASEDIR}
    mkdir ${BASEDIR}
fi

echo Workspace is ${BASEDIR}
echo Building ${TYPE} for ${PLAT}
cd ${BASEDIR}

if [ ! -d "gcc5" ]; then
    mkdir gcc5
    pushd gcc5
    wget https://releases.linaro.org/components/toolchain/binaries/7.2-2017.11/aarch64-linux-gnu/gcc-linaro-7.2.1-2017.11-x86_64_aarch64-linux-gnu.tar.xz
    tar -xf gcc-linaro-7.2.1-2017.11-x86_64_aarch64-linux-gnu.tar.xz
    popd
fi
export GCC5_AARCH64_PREFIX=${BASEDIR}/gcc5/gcc-linaro-7.2.1-2017.11-x86_64_aarch64-linux-gnu/bin/aarch64-linux-gnu-

if [ ! -d "edk2" ]; then
    git clone https://github.com/tianocore/edk2.git edk2
    pushd edk2
    #
    # Known good SHA for platforms/non-osi forks below.
    #
    git checkout b0c15fb128c518b9acd8611a2deea213e9e55193
    git submodule update --init
    popd
fi

if [ ! -d "edk2-platforms" ]; then
    git clone https://github.com/andreiw/lampone-edk2-platforms edk2-platforms
fi

if [ ! -d "edk2-non-osi" ]; then
    git clone https://github.com/andreiw/lampone-edk2-non-osi edk2-non-osi
fi

if [ ! -d "tf-a" ]; then
    git clone https://github.com/andreiw/lampone-tf-a tf-a
fi

build_tfa
prep_edk2
build_edk2

exit
