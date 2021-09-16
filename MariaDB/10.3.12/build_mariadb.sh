#!/bin/bash
# © Copyright IBM Corporation 2019.
# LICENSE: Apache License, Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0)
#
# Instructions:
# Download build script: wget https://raw.githubusercontent.com/linux-on-ibm-z/scripts/master/MariaDB/build_mariadb.sh
# Execute build script: bash build_mariadb.sh    (provide -h for help)

set -e -o pipefail

PACKAGE_NAME="mariadb"
PACKAGE_VERSION="10.3.12"
CURDIR="$(pwd)"
BUILD_DIR="/usr/local"
REPO_URL="https://raw.github.ibm.com/linux-on-ibm-z/scripts/master/MariaDB/10.3.12/patch"

MARIADB_CONN_VERSION="3.0.2"
TESTS="false"
FORCE="false"
LOG_FILE="$CURDIR/logs/${PACKAGE_NAME}-${PACKAGE_VERSION}-$(date +"%F-%T").log"

trap cleanup 0 1 2 ERR

#Check if directory exists
if [ ! -d "$CURDIR/logs/" ]; then
    mkdir -p "$CURDIR/logs/"
fi

# Need handling for RHEL 6.10 as it doesn't have os-release file
if [ -f "/etc/os-release" ]; then
    source "/etc/os-release"
else
    cat /etc/redhat-release >>"${LOG_FILE}"
    export ID="rhel"
    export VERSION_ID="6.x"
    export PRETTY_NAME="Red Hat Enterprise Linux 6.x"
fi

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
}

function cleanup() {
    # Remove artifacts

    if [ -f "$CURDIR/mariadb-${PACKAGE_VERSION}.tar.gz" ]; then
        rm -rf "$CURDIR/mariadb-${PACKAGE_VERSION}.tar.gz"
    fi

     if [ -f "$CURDIR/mariadb_com.h.diff" ]; then
        rm -rf "$CURDIR/mariadb_com.h.diff"
    fi


    

    #rm "$CURDIR"/mariadb_com.h.diff
    printf -- "Cleaned up the artifacts\n" >>"$LOG_FILE"
}

function configureAndInstall() {
    printf -- "Configuration and Installation started \n"

    # Download mariadb
    cd "$CURDIR"
    wget https://github.com/MariaDB/server/archive/mariadb-${PACKAGE_VERSION}.tar.gz
    tar xzf mariadb-${PACKAGE_VERSION}.tar.gz

    # remove if already exist
    if [ -d "mariadb-connector-c" ]; then
        rm -rf "mariadb-connector-c"
    fi

    # Get MariaDB Connector/C source into libmariadb folder
    git clone -b v${MARIADB_CONN_VERSION} git://github.com/MariaDB/mariadb-connector-c.git
    cd mariadb-connector-c
    cp -r "$CURDIR"/mariadb-connector-c/* "$CURDIR"/server-mariadb-${PACKAGE_VERSION}/libmariadb/

    # Add patch
	cd "${CURDIR}"
	curl -o mariadb_com.h.diff $REPO_URL/mariadb_com.h.diff
	patch "$CURDIR/server-mariadb-${PACKAGE_VERSION}/libmariadb/include/mariadb_com.h" mariadb_com.h.diff
    printf -- "Patch mariadb_com.h success\n" 

    # Build and install mariadb
    mv  "$CURDIR"/server-mariadb-${PACKAGE_VERSION} "$CURDIR"/mariadb
    rm -rf "$CURDIR"/server-mariadb-${PACKAGE_VERSION}
    sudo chmod -Rf 755 "$CURDIR"/mariadb
    sudo cp -Rf "$CURDIR"/mariadb "$BUILD_DIR"
    #Give permission
	sudo chown -R "$USER" "$BUILD_DIR/mariadb/"

    cd "$BUILD_DIR/mariadb/"
    BUILD/autorun.sh 
    ./configure 
    make 
    sudo make install 
    printf -- "Build mariadb success\n" 
   
   

    sudo useradd mysql || true
    sudo groupadd mysql || true

    cd /usr/local/mysql		
    sudo chmod -R o+rwx .

    sudo scripts/mysql_install_db --user=mysql
    sudo cp support-files/mysql.server /etc/init.d/mysql
    
    printf -- "Installation mariadb success\n" 
    # Run Test
    runTest

    # Verify mariadb installation
    if command -v "mysqladmin" >/dev/null; then
        printf -- " %s Installation verified.\n" "$PACKAGE_NAME"
    else
        printf -- "Error while installing %s, exiting with 127 \n" "$PACKAGE_NAME"
        exit 127
    fi
}

function runTest() {

    set +e
    if [[ "$TESTS" == "true" ]]; then
        printf -- 'Running tests \n\n' |& tee -a "$LOG_FILE"
        cd "$BUILD_DIR"/mariadb
        make test
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
    echo " build_mariadb.sh  [-d debug] [-y install-without-confirmation] [-t install and run tests]"
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
    printf -- '\n********************************************************************************************************\n'
    printf -- "\n*Getting Started * \n"
    printf -- "Running mariadb: \n"
    printf -- "sudo /usr/local/mysql/bin/mysqld_safe --user=mysql &  \n\n"
    printf -- "/usr/local/mysql/bin/mysqladmin version --user=mysql  \n\n"
    printf -- "You have successfully started mariadb.\n"
    printf -- '**********************************************************************************************************\n'
}

logDetails
prepare #Check Prequisites
DISTRO="$ID-$VERSION_ID"

case "$DISTRO" in
"ubuntu-16.04" | "ubuntu-18.04")
    printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
    printf -- "Installing dependencies... it may take some time.\n"
    sudo apt-get update
    sudo apt-get install -y build-essential hostname libncurses-dev git wget cmake gcc make tar libpcre3-dev bison scons libboost-dev libboost-program-options-dev openssl dh-autoreconf libssl-dev texinfo check patch curl |& tee -a "$LOG_FILE"
    configureAndInstall |& tee -a "$LOG_FILE"
    ;;
"rhel-6.x" | "rhel-7.4" | "rhel-7.5" | "rhel-7.6")
    printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
    printf -- "Installing dependencies... it may take some time.\n"
    sudo yum install -y git wget cmake gcc gcc-c++ make ncurses-devel bison hostname tar boost-devel check-devel openssl-devel perl-CPAN 'perl(Test::More)' python patch curl |& tee -a "$LOG_FILE"
    configureAndInstall |& tee -a "$LOG_FILE"
    ;;
"sles-12.3")
    printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
    printf -- "Installing dependencies... it may take some time.\n"
    sudo zypper install -y git wget tar cmake gcc gcc-c++ make ncurses-devel boost-devel check-devel libopenssl-devel bison scons glibc-locale gawk net-tools patch curl |& tee -a "$LOG_FILE"
    configureAndInstall |& tee -a "$LOG_FILE"
    ;;
"sles-15")
    printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
    printf -- "Installing dependencies... it may take some time.\n"
    sudo zypper install -y git wget tar cmake gcc gcc-c++ make ncurses-devel libboost*-devel check-devel libopenssl-devel bison glibc-locale gawk net-tools python patch curl |& tee -a "$LOG_FILE"
    configureAndInstall |& tee -a "$LOG_FILE"
    ;;
*)
    printf -- "%s not supported \n" "$DISTRO" |& tee -a "$LOG_FILE"
    exit 1
    ;;
esac

gettingStarted |& tee -a "$LOG_FILE"
