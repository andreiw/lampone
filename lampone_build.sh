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
# For Ubuntu, outside of make, python3 and a local toolchain:
# $ apt-get update && apt-get install -y uuid-dev iasl
#
usage()
{
    echo
    echo Usage: $0 [-d dir] [-p plat] [-t type]
    echo "-d dir  - workspace directory to use (default rpi_fw)"    
    echo "-p plat - rpi4 (default) or rpi3"
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

    if [[ x"${TFA_PLAT}" = x"rpi3" ]]; then
        DTB_BASE=0x10000
        BL33_BASE=0x30000
        TARGETS="fip all"
        TARGET_SRC="${PWD}/build/${PLAT}/release/bl1.bin ${PWD}/build/${PLAT}/release/fip.bin"
    else
        DTB_BASE=0x20000
        BL33_BASE=0x30000
        TARGETS="all"
        TARGET_SRC="${PWD}/build/${PLAT}/release/bl31.bin"
    fi

    make PLAT=${TFA_PLAT} PRELOADED_BL33_BASE=${BL33_BASE} RPI3_PRELOADED_DTB_BASE=${DTB_BASE} SUPPORT_VFP=1 RPI3_USE_UEFI_MAP=1 DEBUG=0 V=1 ${TARGETS}

    if [[ $? -ne 0 ]]; then
        echo TF-A build failed
        exit
    fi
    echo
    echo TF-A artifacts are ${TARGET_SRC}
    cp ${TARGET_SRC} ${BASEDIR}/edk2-non-osi/Platform/RaspberryPi/${UEFI_PLAT}/TrustedFirmware
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
        git checkout remotes/origin/pi4_dev2

    else
        git checkout master
    fi
    popd

    pushd edk2-non-osi
    if [[ ! x"${PLAT}" = x"rpi3" ]]; then
        git checkout remotes/origin/pi4_dev1
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
    NUM_CPUS=$((`getconf _NPROCESSORS_ONLN` + 2))

    build -n ${NUM_CPUS} -a AARCH64 -t GCC5 -b ${TYPE} -p edk2-platforms/Platform/RaspberryPi/${UEFI_PLAT}/${UEFI_PLAT}.dsc --pcd gEfiMdeModulePkgTokenSpaceGuid.PcdFirmwareVersionString=L"Lampone ${BUILD_COMMIT} on ${BUILD_DATE}"
    if [[ $? -ne 0 ]]; then
        error UEFI build failed
    fi
    echo
    echo Finished building ${BASEDIR}/Build/${UEFI_PLAT}/${TYPE}_GCC5/FV/RPI_EFI.fd
    echo
}

#
# Defaults.
#
BASEDIR=rpi_fw
TYPE=RELEASE
PLAT=rpi4

while getopts d:p:t: OPTION; do
    case ${OPTION} in
        d)
            BASEDIR=${OPTARG}
            ;;
        p)
            if [[ ! x"${OPTARG}" = x"rpi3" ]] && [[ ! x"${OPTARG}" = x"rpi4" ]]; then
                usage
            fi
                      
            PLAT=${OPTARG}
            ;;
        t)
            if [[ ! x"${OPTARG}" = x"DEBUG" ]] && [[ ! x"${OPTARG}" = x"RELEASE" ]]; then
                usage
            fi
                      
            TYPE=${OPTARG}
            ;;
        *)
            usage
            ;;
    esac
done
shift $((OPTIND - 1))

BASEDIR=${PWD}/${BASEDIR}
if [ ! -d "${BASEDIR}" ]; then
    echo Creating ${BASEDIR}
    mkdir ${BASEDIR}
fi

echo Workspace is ${BASEDIR}
echo Building ${TYPE} for ${PLAT}
cd ${BASEDIR}

if [[ x"${PLAT}" = x"rpi3" ]]; then
    UEFI_PLAT=RPi3
    TFA_PLAT=rpi3
else
    UEFI_PLAT=RPi4
    TFA_PLAT=rpi4
fi

if [ ! -d "gcc5" ]; then
    mkdir gcc5
    pushd gcc5
    wget https://releases.linaro.org/components/toolchain/binaries/7.2-2017.11/aarch64-linux-gnu/gcc-linaro-7.2.1-2017.11-x86_64_aarch64-linux-gnu.tar.xz
    tar -xf gcc-linaro-7.2.1-2017.11-x86_64_aarch64-linux-gnu.tar.xz
    popd
fi
export GCC5_AARCH64_PREFIX=${BASEDIR}/gcc5/gcc-linaro-7.2.1-2017.11-x86_64_aarch64-linux-gnu/bin/aarch64-linux-gnu-

if [ ! -d "edk2" ]; then
    git clone https://github.com/ardbiesheuvel/edk2 edk2
    pushd edk2
    #
    # Known good SHA/branch for platforms/non-osi forks below.
    #
    git checkout remotes/origin/rpi4
    git submodule update --init
    popd
fi

if [ ! -d "edk2-platforms" ]; then
    git clone https://github.com/pftf/edk2-platforms edk2-platforms
fi

if [ ! -d "edk2-non-osi" ]; then
    git clone https://github.com/pftf/edk2-non-osi edk2-non-osi
fi

if [ ! -d "tf-a" ]; then
    git clone https://github.com/ARM-software/arm-trusted-firmware tf-a
fi

build_tfa
prep_edk2
build_edk2

exit
