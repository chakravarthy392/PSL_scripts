#!/bin/bash
# © Copyright IBM Corporation 2022
# LICENSE: Apache License, Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0)
#
# Instructions:
# Download build script: wget https://raw.githubusercontent.com/linux-on-ibm-z/scripts/master/Erlang/24.2.1/build_erlang.sh
# Execute build script: bash build_erlang.sh    (provide -h for help)

set -e -o pipefail

PACKAGE_NAME="erlang"
PACKAGE_VERSION="24.2.1"
CURDIR="$(pwd)"


TESTS="false"
FORCE="false"
LOG_FILE="$CURDIR/logs/${PACKAGE_NAME}-${PACKAGE_VERSION}-$(date +"%F-%T").log"
JAVA_PROVIDED="OpenJDK11"
BUILD_ENV="$HOME/setenv.sh"

trap cleanup 0 1 2 ERR

#Check if directory exists
if [ ! -d "$CURDIR/logs/" ]; then
    mkdir -p "$CURDIR/logs/"
fi

source "/etc/os-release"

function prepare() {
    if command -v "sudo" >/dev/null; then
        printf -- 'Sudo : Yes\n' >>"$LOG_FILE"
    else
        printf -- 'Sudo : No \n' >>"$LOG_FILE"
        printf -- 'You can install the same from installing sudo from repository using apt, yum or zypper based on your distro. \n'
        exit 1
    fi
    
    if [[ "$FORCE" == "true" ]]; then
        printf -- 'Force attribute provided hence continuing with install without confirmation message\n' |& tee -a "$LOG_FILE"
    else
        # Ask user for prerequisite installation
        printf -- "\nAs part of the installation , dependencies would be installed/upgraded.\n"
        while true; do
            read -r -p "Do you want to continue (y/n) ? :  " yn
            case $yn in
            [Yy]*)
                printf -- 'User responded with Yes. \n' >>"$LOG_FILE"
                break
                ;;
            [Nn]*) exit ;;
            *) echo "Please provide confirmation to proceed." ;;
            esac
        done
    fi

    if [[ "$JAVA_PROVIDED" != "IBM_Semeru_11" && "$JAVA_PROVIDED" != "Eclipse_Adoptium_Temurin_11" && "$JAVA_PROVIDED" != "OpenJDK11" ]];
    then
        printf --  "$JAVA_PROVIDED is not supported, Please use valid java from {IBM_Semeru_11, Eclipse_Adoptium_Temurin_11, OpenJDK11 } only." |& tee -a "$LOG_FILE"
        exit 1
    fi
}

function cleanup() {
    # Remove artifacts

    if [ -f "$CURDIR/otp_src_${PACKAGE_VERSION}.tar.gz" ]; then
        rm -rf "$CURDIR/otp_src_${PACKAGE_VERSION}.tar.gz"
    fi
    printf -- "Cleaned up the artifacts\n" >>"$LOG_FILE"
}

function configureAndInstall() {
    printf -- "Configuration and Installation started \n"

    echo "Java provided by user $JAVA_PROVIDED" >> "$LOG_FILE"

    if [[ "$JAVA_PROVIDED" == "IBM_Semeru_11" ]]; then
        # Install IBM_Semeru_11 (AdoptOpenJDK 11 With OpenJ9)
        sudo mkdir -p /opt/java

        cd "$SOURCE_ROOT"
        sudo wget https://github.com/ibmruntimes/semeru11-binaries/releases/download/jdk-11.0.13%2B8_openj9-0.29.0/ibm-semeru-open-jdk_s390x_linux_11.0.13_8_openj9-0.29.0.tar.gz
        sudo tar -C /opt/java -xzf ibm-semeru-open-jdk_s390x_linux_11.0.13_8_openj9-0.29.0.tar.gz --strip 1
        export JAVA_HOME=/opt/java

        printf -- 'export JAVA_HOME=/opt/java\n'  >> "$BUILD_ENV"
        printf -- 'IBM_Semeru_11 installed\n' >> "$LOG_FILE"
    elif [[ "$JAVA_PROVIDED" == "Eclipse_Adoptium_Temurin_11" ]]; then
        # Install Eclipse_Adoptium_Temurin_11 (AdoptOpenJDK 11 With Hotspot)
        sudo mkdir -p /opt/java

        cd "$SOURCE_ROOT"
        sudo wget https://github.com/adoptium/temurin11-binaries/releases/download/jdk-11.0.13%2B8/OpenJDK11U-jdk_s390x_linux_hotspot_11.0.13_8.tar.gz
        sudo tar -C /opt/java -xzf OpenJDK11U-jdk_s390x_linux_hotspot_11.0.13_8.tar.gz --strip 1
        export JAVA_HOME=/opt/java

        printf -- 'export JAVA_HOME=/opt/java\n'  >> "$BUILD_ENV"
        printf -- 'Eclipse_Adoptium_Temurin_11 installed\n' >> "$LOG_FILE"
    elif [[ "$JAVA_PROVIDED" == "OpenJDK11" ]]; then
        if [[ "$ID" == "rhel" ]]; then
            sudo yum install -y java-11-openjdk-devel   
            export JAVA_HOME=/usr/lib/jvm/java-11-openjdk     
            printf -- 'export JAVA_HOME=/usr/lib/jvm/java-11-openjdk\n'  >> "$BUILD_ENV"   
        elif [[ "$ID" == "sles" ]]; then
            sudo zypper install -y java-11-openjdk-devel
            export JAVA_HOME=/usr/lib64/jvm/java-11-openjdk
            printf -- 'export JAVA_HOME=/usr/lib64/jvm/java-11-openjdk\n'  >> "$BUILD_ENV"
        elif [[ "$ID" == "ubuntu" ]]; then
                sudo apt-get install -y openjdk-11-jdk
                export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-s390x
                printf -- 'export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-s390x\n'  >> "$BUILD_ENV"
        fi
    else
        printf --  '$JAVA_PROVIDED is not supported, Please use valid java from {IBM_Semeru_11, Eclipse_Adoptium_Temurin_11, OpenJDK11} only' >> "$LOG_FILE"
        exit 1
    fi

    export PATH=$JAVA_HOME/bin:$PATH
    printf -- 'export PATH=$JAVA_HOME/bin:$PATH\n'  >> "$BUILD_ENV"
    java -version
    
    # Download erlang
    cd "$CURDIR"
    wget "https://github.com/erlang/otp/releases/download/OTP-${PACKAGE_VERSION}/otp_src_${PACKAGE_VERSION}.tar.gz"
    tar zxf otp_src_${PACKAGE_VERSION}.tar.gz
    mv otp_src_${PACKAGE_VERSION} erlang
    sudo chmod -Rf 755 erlang
 
    printf -- "Download erlang success\n"


    # Build and install erlang
    cd "$CURDIR"/erlang
    export ERL_TOP=$(pwd)

    ./configure --prefix=/usr

    make
    sudo make install
    printf -- "Build and install erlang successfully\n" 

    # Run Test
    runTest

    # Cleanup
    cleanup


    # Verify erlang installation
    if command -v "erl" >/dev/null; then
        printf -- " %s Installation verified.\n" "$PACKAGE_NAME"
    else
        printf -- "Error while installing %s, exiting with 127 \n" "$PACKAGE_NAME"
        exit 127
    fi
}

function runTest() {

    set +e
    if [[ "$TESTS" == "true" ]]; then
        source $HOME/setenv.sh
        printf -- "Environment PATH : %s \n" "$PATH"
        printf -- 'Running tests \n\n' |& tee -a "$LOG_FILE"
        cd "$CURDIR"/erlang
        make release_tests
        cd release/tests/test_server
        printf -- 'Running smoke tests \n\n' 
        $ERL_TOP/bin/erl -s ts install -s ts smoke_test batch -s init stop
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
    echo "bash build_erlang.sh  [-d debug] [-y install-without-confirmation] [-t install and run tests] [-j Java to use from {IBM_Semeru_11, Eclipse_Adoptium_Temurin_11, OpenJDK11}]"
    echo "       default: If no -j specified, OpenJDK will be installed"
    echo
}

while getopts "h?dytj:" opt; do
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
    j)
        JAVA_PROVIDED="$OPTARG"
    esac
done

function gettingStarted() {
    printf -- '\n********************************************************************************************************\n'
    printf -- "\n*Getting Started * \n"
    printf -- "Running erlang: \n"
    printf -- "erl  \n"
    printf -- "You have successfully started erlang.\n"
    printf -- '**********************************************************************************************************\n'
}

logDetails
prepare # Check Prerequisites
DISTRO="$ID-$VERSION_ID"

case "$DISTRO" in
"ubuntu-18.04" | "ubuntu-20.04" | "ubuntu-21.10")
    printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
    printf -- "Installing dependencies... it may take some time.\n"
    sudo apt-get update
    sudo apt-get install -y curl autoconf fop flex gawk gcc g++ gzip libncurses-dev libssl-dev libxml2-utils make tar unixodbc-dev wget xsltproc |& tee -a "$LOG_FILE"
    configureAndInstall |& tee -a "$LOG_FILE"
    ;;
"rhel-7.8" | "rhel-7.9" | "rhel-8.2" | "rhel-8.4" | "rhel-8.5")
    printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
    printf -- "Installing dependencies... it may take some time.\n"
    sudo yum install -y autoconf flex gawk gcc gcc-c++ gzip libxml2-devel libxslt ncurses-devel openssl-devel make tar unixODBC-devel wget |& tee -a "$LOG_FILE"
    configureAndInstall |& tee -a "$LOG_FILE"
    ;;
"sles-12.5")
    printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
    printf -- "Installing dependencies... it may take some time.\n"
    sudo zypper install -y autoconf flex gawk gcc gcc-c++ gzip libopenssl-devel libxml2-devel libxslt-tools ncurses-devel make tar unixODBC-devel wget xmlgraphics-fop |& tee -a "$LOG_FILE"
    configureAndInstall |& tee -a "$LOG_FILE"
    ;;
"sles-15.3")
    printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
    printf -- "Installing dependencies... it may take some time.\n"
    sudo zypper install -y autoconf flex gawk gcc gcc-c++ gzip libopenssl-1_1-devel libxml2-devel libxslt-tools ncurses-devel make tar unixODBC-devel wget |& tee -a "$LOG_FILE"
    configureAndInstall |& tee -a "$LOG_FILE"
    ;;
*)
    printf -- "%s not supported \n" "$DISTRO" |& tee -a "$LOG_FILE"
    exit 1
    ;;
esac

gettingStarted |& tee -a "$LOG_FILE"
