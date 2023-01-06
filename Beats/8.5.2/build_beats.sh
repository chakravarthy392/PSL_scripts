#!/bin/bash
# © Copyright IBM Corporation 2022.
# LICENSE: Apache License, Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0)
#
# Instructions:
# Download build script: wget https://raw.githubusercontent.com/linux-on-ibm-z/scripts/master/Beats/8.5.2/build_beats.sh
# Execute build script: bash build_beats.sh    (provide -h for help)
#

set -e  -o pipefail

PACKAGE_NAME="beats"
PACKAGE_VERSION="8.5.2"
PATCH_URL="https://raw.githubusercontent.com/linux-on-ibm-z/scripts/master/Beats/${PACKAGE_VERSION}/patch"
GO_VERSION="1.18.7"
PYTHON_VERSION="3.9.13"
OPENSSL_VERSION="1.1.1s"
RUST_VERSION="1.65.0"
CURDIR="$(pwd)"
USER="$(whoami)"

FORCE="false"
TESTS="false"
LOG_FILE="${CURDIR}/logs/${PACKAGE_NAME}-${PACKAGE_VERSION}-$(date +"%F-%T").log"
BUILD_ENV="${CURDIR}/setenv.sh"

trap cleanup 0 1 2 ERR

#Check if directory exists
if [ ! -d "$CURDIR/logs/" ]; then
   mkdir -p "$CURDIR/logs/"
fi

if [ -f "/etc/os-release" ]; then
        source "/etc/os-release"
fi

function error() { echo "Error: ${*}"; exit 1; }

function prepare() {
        if command -v "sudo" >/dev/null; then
                printf -- 'Sudo : Yes\n' >>"$LOG_FILE"
        else
                printf -- 'Sudo : No \n' >>"$LOG_FILE"
                printf -- 'Install sudo from repository using apt, yum or zypper based on your distro. \n'
                exit 1
        fi

        if [[ "$FORCE" == "true" ]]; then
                printf -- 'Force attribute provided hence continuing with install without confirmation message\n' |& tee -a "$LOG_FILE"
        else
                # Ask user for prerequisite installation
                printf -- "\nAs part of the installation, dependencies would be installed/upgraded. \n"
                while true; do
                        read -r -p "Do you want to continue (y/n) ? :  " yn
                        case $yn in
                        [Yy]*)
                                printf -- 'User responded with Yes. \n' >> "$LOG_FILE"
                                break
                                ;;
                        [Nn]*) exit ;;
                        *) echo "Please provide confirmation to proceed." ;;
                        esac
                done
        fi
}

function cleanup() {

    if [[ "${DISTRO}" == "rhel-7."* ]]; then
        printf -- "Reverting to system python and check if yum is working. \n"
        sudo ln -fs /usr/bin/python2 /usr/bin/python
        sudo yum info python
    fi
    # Remove artifacts
    printf -- "Cleaned up the artifacts\n" >> "$LOG_FILE"

}
function configureAndInstallPython() {
    if [[ "${DISTRO}" == "ubuntu-18.04" ]] \
        || [[ "${DISTRO}" == "ubuntu-22.04"* ]] \
        || [[ "${DISTRO}" == "rhel-7."* ]] \
        || [[ "${DISTRO}" == "sles-12.5" ]] \
        || [[ "${DISTRO}" == "sles-15.4" ]]; then
        printf -- 'Configuration and Installation of Python started\n'

        if [[ "${DISTRO}" == "rhel-7."* ]] || [[ "${DISTRO}" == "sles-12.5" ]]; then
            source "${BUILD_ENV}"
        fi
        cd $CURDIR

        #Install Python 3.x
        sudo rm -rf Python*
        wget https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tgz
        tar -xzf Python-${PYTHON_VERSION}.tgz
        cd Python-${PYTHON_VERSION}
        ./configure --prefix=/usr/local --exec-prefix=/usr/local
        make
        sudo make install
        export PATH=/usr/local/bin:$PATH
        if [[ "${DISTRO}" == "rhel-7."* ]]; then
            sudo ln -fs /usr/bin/python3 /usr/bin/python
        else
            sudo update-alternatives --install /usr/bin/python python /usr/local/bin/python3.9 10
        fi
        sudo update-alternatives --install /usr/bin/python3 python3 /usr/local/bin/python3.9 10
        sudo update-alternatives --display python3
    fi
    python3 -V
}

function packetbeatSupported() {
    [[ "${DISTRO}" == "ubuntu-18.04" ]] \
        || [[ "${DISTRO}" == "ubuntu-20.04" ]] \
        || [[ "${DISTRO}" =~ ^rhel-8 ]] \
        || [[ "${DISTRO}" =~ ^sles ]]
}

function heartbeatSupported() {
    [[ "${DISTRO}" == "ubuntu-18.04" ]] \
        || [[ "${DISTRO}" =~ ^rhel-8 ]] \
        || [[ "${DISTRO}" =~ ^sles ]]
}

function auditbeatSupported() {
    [[ "${DISTRO}" == "ubuntu-18.04" ]] \
        || [[ "${DISTRO}" == "ubuntu-20.04" ]] \
        || [[ "${DISTRO}" =~ ^rhel-8 ]] \
        || [[ "${DISTRO}" =~ ^sles ]]
}

function configureAndInstall() {
    printf -- 'Configuration and Installation started \n'

    cd $CURDIR

    if [[ "${DISTRO}" == "rhel-7."* ]] || [[ "${DISTRO}" == "sles-12.5" ]]; then
        source "${BUILD_ENV}"
    else
        #Installing pip
        wget --no-check-certificate https://bootstrap.pypa.io/get-pip.py
        sudo env PATH=$PATH python3 get-pip.py
        rm get-pip.py
    fi

    printf -- 'Installing Rust \n'
    wget -O rustup-init.sh https://sh.rustup.rs
    bash rustup-init.sh -y
    export PATH=$PATH:$HOME/.cargo/bin
    rustup toolchain install ${RUST_VERSION}
    rustup default ${RUST_VERSION}
    rustc --version | grep "${RUST_VERSION}"

    cd $CURDIR

    # Install go
    printf -- "Installing Go... \n"
    wget https://go.dev/dl/go${GO_VERSION}.linux-s390x.tar.gz
    chmod ugo+r go${GO_VERSION}.linux-s390x.tar.gz
    sudo tar -C /usr/local -xzf go${GO_VERSION}.linux-s390x.tar.gz
    export PATH=$PATH:/usr/local/go/bin

    if [[ "${ID}" != "ubuntu" ]]; then
        sudo ln -sf /usr/bin/gcc /usr/bin/s390x-linux-gnu-gcc
        printf -- 'Symlink done for gcc \n'
    fi
    go version

    # Set GOPATH if not already set
    if [[ -z "${GOPATH}" ]]; then
        printf -- "Setting default value for GOPATH \n"

        export GOPATH=$(go env GOPATH)
        mkdir -p $GOPATH
    else
        printf -- "GOPATH already set : Value : %s \n" "$GOPATH"
    fi

    # Checking permissions
    sudo setfacl -dm u::rwx,g::r,o::r $GOPATH
    cd $GOPATH
    touch test && ls -la test && rm test

    # Install beats
    printf -- "\nInstalling Beats..... \n"

    # Download Beats Source
    if [ ! -d "$GOPATH/src/github.com/elastic" ]; then
        mkdir -p $GOPATH/src/github.com/elastic
    fi
    cd $GOPATH/src/github.com/elastic
    sudo rm -rf beats
    git clone https://github.com/elastic/beats.git
    cd beats
    git checkout v$PACKAGE_VERSION
    curl -sSL ${PATCH_URL}/nan.patch | git apply - || error "NaN patch"
    curl -sSL ${PATCH_URL}/cpuinfo.patch | git apply - || error "cpuinfo patch"

    #Making directory to add .yml files
    if [ ! -d "/etc/beats/" ]; then
        sudo mkdir -p /etc/beats
    fi

    export PATH=$GOPATH/bin:$PATH
    export GRPC_PYTHON_BUILD_SYSTEM_OPENSSL=true
    export PYTHON_EXE=python3
    export PYTHON_ENV=/tmp/venv3

    # Not all OS are supported by each Beat, see support matrix: https://www.elastic.co/support/matrix#matrix_os

    #Building packetbeat and adding to /usr/bin
    if packetbeatSupported; then
        printf -- "Installing packetbeat \n" |& tee -a "$LOG_FILE"
        cd $GOPATH/src/github.com/elastic/beats/packetbeat
        make
        ./packetbeat version
        make update
        make fmt
        sudo cp "./packetbeat" /usr/bin/
        sudo cp "./packetbeat.yml" /etc/beats/
    fi

    #Building filebeat and adding to /usr/bin
    printf -- "Installing filebeat \n" |& tee -a "$LOG_FILE"
    cd $GOPATH/src/github.com/elastic/beats/filebeat
    make
    ./filebeat version
    make update
    make fmt
    sudo cp "./filebeat" /usr/bin/
    sudo cp "./filebeat.yml" /etc/beats/

    #Building metricbeat and adding to /usr/bin
    printf -- "Installing metricbeat \n" |& tee -a "$LOG_FILE"
    cd $GOPATH/src/github.com/elastic/beats/metricbeat
    mage build
    ./metricbeat version
    mage update
    mage fmt
    sudo cp "./metricbeat" /usr/bin/
    sudo cp "./metricbeat.yml" /etc/beats/

    #Building heartbeat and adding to /usr/bin
    if heartbeatSupported; then
        # Building heartbeat and adding to usr/bin
        printf -- "Installing heartbeat \n" |& tee -a "$LOG_FILE"
        cd $GOPATH/src/github.com/elastic/beats/heartbeat
        make
        ./heartbeat version
        make update
        make fmt
        sudo cp "./heartbeat" /usr/bin/
        sudo cp "./heartbeat.yml" /etc/beats/
    fi


    #Building auditbeat and adding to /usr/bin
    if auditbeatSupported; then
        printf -- "Installing auditbeat \n" |& tee -a "$LOG_FILE"
        cd $GOPATH/src/github.com/elastic/beats/auditbeat
        make
        ./auditbeat version
        make update
        make fmt
        sudo cp "./auditbeat" /usr/bin/
        sudo cp "./auditbeat.yml" /etc/beats/
    fi

    # Run Tests
    runTest

    printf -- "\n Installation of %s %s was successful \n\n" $PACKAGE_NAME $PACKAGE_VERSION
}

function installOpenssl(){
      printf -- 'Configuration and Installation of OpenSSL started\n'
      cd $CURDIR
      wget --no-check-certificate https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz
      tar -xzf openssl-${OPENSSL_VERSION}.tar.gz
      cd openssl-${OPENSSL_VERSION}
      ./config --prefix=/usr/local --openssldir=/usr/local
      make
      sudo make install
      sudo ldconfig /usr/local/lib64
      export PATH=/usr/local/bin:$PATH
      export LDFLAGS="-L/usr/local/lib/ -L/usr/local/lib64/"
      export LD_LIBRARY_PATH="/usr/local/lib/:/usr/local/lib64/"
      export CPPFLAGS="-I/usr/local/include/ -I/usr/local/include/openssl"

      printf -- 'export PATH="/usr/local/bin:${PATH}"\n'  >> "${BUILD_ENV}"
      printf -- "export LDFLAGS=\"$LDFLAGS\"\n" >> "${BUILD_ENV}"
      printf -- "export LD_LIBRARY_PATH=\"$LD_LIBRARY_PATH\"\n" >> "${BUILD_ENV}"
      printf -- "export CPPFLAGS=\"$CPPFLAGS\"\n" >> "${BUILD_ENV}"
}

function runTest() {
    set +e

    if [[ "$TESTS" == "true" ]]; then
        printf -- "TEST Flag is set , Continue with running test \n"

        #FILEBEAT
        printf -- "\nTesting Filebeat\n"
        cd $GOPATH/src/github.com/elastic/beats/filebeat
        make unit
        make system-tests
        printf -- "\nTesting Filebeat completed successfully\n"

        #PACKETBEAT
        if packetbeatSupported; then
            printf -- "\nTesting Packetbeat\n"
            cd $GOPATH/src/github.com/elastic/beats/packetbeat
            make unit
            make system-tests
            printf -- "\nTesting Packetbeat completed successfully\n"
        fi

        #METRICBEAT
        printf -- "\nTesting Metricbeat\n"
        cd $GOPATH/src/github.com/elastic/beats/metricbeat
        mage test
        printf -- "\nTesting Metricbeat completed successfully\n"

        if heartbeatSupported; then
            #HEARTBEAT
            printf -- "\nTesting Heartbeat\n"
            cd $GOPATH/src/github.com/elastic/beats/heartbeat
            make unit
            make system-tests
            printf -- "\nTesting Heartbeat completed successfully\n"
        fi

        if auditbeatSupported; then
            #AUDIBEAT
            printf -- "\nTesting Auditbeat\n"
            cd $GOPATH/src/github.com/elastic/beats/auditbeat
            make unit
            make system-tests
            printf -- "\nTesting Auditbeat completed successfully\n"
        fi

        printf -- "Tests completed. \n"
    fi

    set -e
}

function logDetails() {
        printf -- '**************************** SYSTEM DETAILS *************************************************************\n' >"$LOG_FILE"
        if [ -f "/etc/os-release" ]; then
                cat "/etc/os-release" >>"$LOG_FILE"
        fi

        cat /proc/version >>"$LOG_FILE"
        printf -- '*********************************************************************************************************\n' >>"$LOG_FILE"

        printf -- "Detected %s \n" "$PRETTY_NAME"
        printf -- "Request details : PACKAGE NAME= %s , VERSION= %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" |& tee -a "$LOG_FILE"
}

# Print the usage message
function printHelp() {
        echo
        echo "Usage: "
        echo "  bash build_beats.sh  [-d debug] [-y install-without-confirmation] [-t install-with-tests]"
        echo
}

while getopts "h?dyt" opt; do
        case "$opt" in
        h | \?)
                printHelp
                exit 0
                ;;
        d)
                set -x
                ;;
        y)
                FORCE="true"
                ;;
        t)
                TESTS="true"
                ;;
        esac
done

function gettingStarted() {
        printf -- '\n***********************************************************************************************\n'
        printf -- "Getting Started: \n"
        printf -- "To run a particular beat , run the following command : \n"
        printf -- '   sudo <beat_name> -e -c /etc/beats/<beat_name>.yml -d "publish"  \n'
        printf -- '    Example: sudo packetbeat -e -c /etc/beats/packetbeat.yml -d "publish"  \n\n'
        printf -- '\nFor more information visit https://www.elastic.co/guide/en/beats/libbeat/8.4/getting-started.html \n'
        printf -- '*************************************************************************************************\n'
        printf -- '\n'
}

###############################################################################################################

logDetails
prepare #Check Prequisites

DISTRO="$ID-$VERSION_ID"
case "$DISTRO" in
"ubuntu-18.04" | "ubuntu-22.04")
        printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
        printf -- "Installing dependencies... it may take some time.\n"
        sudo apt-get update
        sudo DEBIAN_FRONTEND=noninteractive TZ=America/Toronto apt-get install -y git curl make wget tar gcc g++ libcap-dev libpcap0.8-dev openssl libssh-dev acl rsync tzdata patch fdclone libsystemd-dev libjpeg-dev libffi-dev |& tee -a "${LOG_FILE}"
        #Installing Python 3.9.x
        sudo apt-get install -y gcc g++ libbz2-dev libdb-dev libffi-dev libgdbm-dev liblzma-dev libncurses-dev libreadline-dev libsqlite3-dev libssl-dev make tar tk-dev uuid-dev wget xz-utils zlib1g-dev |& tee -a "${LOG_FILE}"
        configureAndInstallPython |& tee -a "${LOG_FILE}"
        configureAndInstall |& tee -a "${LOG_FILE}"
        ;;

"ubuntu-20.04")
        printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
        printf -- "Installing dependencies... it may take some time.\n"
        sudo apt-get update
        sudo DEBIAN_FRONTEND=noninteractive TZ=America/Toronto apt-get install -y git curl make wget tar gcc g++ libcap-dev libpcap0.8-dev openssl libssh-dev acl rsync tzdata patch fdclone libsystemd-dev libjpeg-dev libffi-dev libpython3-dev python3.9 python3.9-dev python3.9-venv python3.9-distutils python3-lib2to3 python3-testresources |& tee -a "${LOG_FILE}"
        sudo update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.9 10
        sudo update-alternatives --set python3 /usr/bin/python3.9
        sudo update-alternatives --display python3
        python3 -V
        configureAndInstall |& tee -a "${LOG_FILE}"
        ;;

"rhel-7.8" | "rhel-7.9")
        printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
        printf -- "Installing dependencies... it may take some time.\n"
        sudo yum install -y git curl make wget tar devtoolset-7-gcc-c++ devtoolset-7-gcc libpcap libpcap-devel which acl zlib-devel patch systemd-devel libjpeg-devel |& tee -a "${LOG_FILE}"
        source /opt/rh/devtoolset-7/enable
        sudo ln -f -s /opt/rh/devtoolset-7/root/usr/bin/s390x-redhat-linux-gcc /opt/rh/devtoolset-7/root/usr/bin/s390x-linux-gnu-gcc
        sudo ln -f -s /opt/rh/devtoolset-7/root/usr/bin/s390x-redhat-linux-c++ /opt/rh/devtoolset-7/root/usr/bin/s390x-linux-gnu-c++
        sudo ln -f -s /opt/rh/devtoolset-7/root/usr/bin/s390x-redhat-linux-g++ /opt/rh/devtoolset-7/root/usr/bin/s390x-linux-gnu-g++
        #Installing Python 3.9.x
        sudo yum install -y bzip2-devel gcc gcc-c++ gdbm-devel libdb-devel libffi-devel libuuid-devel make ncurses-devel readline-devel sqlite-devel tar tk-devel wget xz xz-devel zlib-devel |& tee -a "${LOG_FILE}"
        # Install openssl
        installOpenssl |& tee -a "${LOG_FILE}"
        configureAndInstallPython |& tee -a "${LOG_FILE}"
        configureAndInstall |& tee -a "${LOG_FILE}"
        ;;

"rhel-8.4" | "rhel-8.6" | "rhel-8.7")
        printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
        printf -- "Installing dependencies... it may take some time.\n"
        sudo yum install -y git curl make wget tar gcc gcc-c++ libpcap-devel openssl openssl-devel which acl zlib-devel patch systemd-devel libjpeg-devel python39 python39-devel |& tee -a "${LOG_FILE}"
        sudo update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.9 10
        sudo update-alternatives --set python3 /usr/bin/python3.9
        sudo update-alternatives --display python3
        python3 -V
        configureAndInstall |& tee -a "${LOG_FILE}"
        ;;

"sles-12.5")
        printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
        printf -- "Installing dependencies... it may take some time.\n"
        sudo zypper install -y git curl gawk make wget tar gcc7 gcc7-c++ libpcap1 libpcap-devel libffi48-devel acl patch libsystemd0 systemd-devel libjpeg62-devel |& tee -a "${LOG_FILE}"
        sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-7 100
        sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-7 100
        sudo update-alternatives --install /usr/bin/cpp cpp /usr/bin/cpp-7 100
        sudo ln -f -s /usr/bin/gcc /usr/bin/cc
        sudo ln -f -s /usr/bin/g++ /usr/bin/c++
        #Installing Python 3.9.x
        sudo zypper install -y gawk gdbm-devel libbz2-devel libdb-4_8-devel libffi48-devel libuuid-devel make ncurses-devel readline-devel sqlite3-devel tar tk-devel wget xz-devel zlib-devel gzip |& tee -a "${LOG_FILE}"
        gcc -v
        # Install openssl
        installOpenssl |& tee -a "${LOG_FILE}"
        configureAndInstallPython |& tee -a "${LOG_FILE}"
        configureAndInstall |& tee -a "${LOG_FILE}"
        ;;

"sles-15.3")
        printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
        printf -- "Installing dependencies... it may take some time.\n"
        sudo zypper install -y git curl gawk make wget tar gcc gcc-c++ libpcap libpcap-devel acl patch libsystemd0 systemd-devel libjpeg62-devel openssl libopenssl-devel zlib-devel python39 python39-devel gzip |& tee -a "${LOG_FILE}"
        sudo update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.9 10
        sudo update-alternatives --set python3 /usr/bin/python3.9
        sudo update-alternatives --display python3
        python3 -V
        configureAndInstall |& tee -a "${LOG_FILE}"
        ;;

"sles-15.4")
        printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
        printf -- "Installing dependencies... it may take some time.\n"
        sudo zypper install -y git curl gawk make wget tar gcc gcc-c++ libpcap libpcap-devel acl patch libsystemd0 systemd-devel libjpeg62-devel openssl libopenssl-devel zlib-devel gzip |& tee -a "${LOG_FILE}"
        sudo zypper install -y gdbm-devel libbz2-devel libdb-4_8-devel libffi-devel libnsl-devel libuuid-devel make ncurses-devel readline-devel sqlite3-devel tar tk wget xz-devel timezone |& tee -a "${LOG_FILE}"
        configureAndInstallPython |& tee -a "${LOG_FILE}"
        python3 -V
        configureAndInstall |& tee -a "${LOG_FILE}"
        ;;

esac

gettingStarted |& tee -a "${LOG_FILE}"
