#!/bin/bash
# © Copyright IBM Corporation 2019, 2020.
# LICENSE: Apache License, Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0)
#
# Instructions:
# Download build script: wget https://raw.githubusercontent.com/linux-on-ibm-z/scripts/master/Heketi/9.0.0/build_heketi.sh
# Execute build script: bash build_heketi.sh    (provide -h for help)

set -e -o pipefail

PACKAGE_NAME="heketi"
PACKAGE_VERSION="9.0.0"
GLIDE_VERSION="v0.13.1"
PATCH_URL="https://raw.githubusercontent.com/linux-on-ibm-z/scripts/master/Heketi/${PACKAGE_VERSION}/patch"

CURDIR="$(pwd)"
GO_DEFAULT="$HOME/go"

GO_INSTALL_URL="https://raw.githubusercontent.com/linux-on-ibm-z/scripts/master/Go/1.14/build_go.sh"


FORCE="false"
TESTS="false"
LOG_FILE="$CURDIR/logs/${PACKAGE_NAME}-${PACKAGE_VERSION}-$(date +"%F-%T").log"

trap cleanup 0 1 2 ERR

#Check if directory exists
if [ ! -d "$CURDIR/logs/" ]; then
   mkdir -p "$CURDIR/logs/"
fi

source "/etc/os-release"

function prepare() {
    if  command -v "sudo" > /dev/null ;
    then
        printf -- 'Sudo : Yes\n' >> "$LOG_FILE"
    else
        printf -- 'Sudo : No \n' >> "$LOG_FILE"
        printf -- 'You can install the same from installing sudo from repository using apt, yum or zypper based on your distro. \n';
    exit 1;
    fi;
   
    if [[ "$FORCE" == "true" ]] ;
    then
        printf -- 'Force attribute provided hence continuing with install without confirmation message\n' |& tee -a "$LOG_FILE"
    else
        # Ask user for prerequisite installation
        printf -- "\nAs part of the installation , dependencies would be installed/upgraded.\n";
        while true; do
		    read -r -p "Do you want to continue (y/n) ? :  " yn
		    case $yn in
  	 		    [Yy]* ) printf -- 'User responded with Yes. \n' >> "$LOG_FILE"; 
	                    break;;
    		    [Nn]* ) exit;;
    		    *) 	echo "Please provide confirmation to proceed.";;
	 	    esac
        done
    fi	
}


function cleanup() {
    # Remove artifacts
    rm -rf "~/$GOPATH/bin/glide-$GLIDE_VERSION-linux-s390x.tar.gz*"
    if [[ "$ID" == "rhel" ]]; then
        # Check if mercurial tar exists
	if [ -f $CURDIR/mercurial-5.1.tar.gz ]; then
	    sudo rm $CURDIR/mercurial-5.1.tar.gz
	fi       
    fi
    printf -- "Cleaned up the artifacts\n" >> "$LOG_FILE"
}
function configureAndInstallPython() {
	printf -- 'Configuration and Installation for Python started \n'

	#Install Python 2.7.16
	cd $CURDIR
	rm -rf Python*
	wget https://www.python.org/ftp/python/2.7.16/Python-2.7.16.tar.xz 	
	tar -xvf Python-2.7.16.tar.xz
	cd Python-2.7.16
	./configure --prefix=/usr/local --exec-prefix=/usr/local
	make
	sudo make install
	export PATH=/usr/local/bin:$PATH
	#Copying python headers required location
	sudo cp /usr/local/include/python2.7/* /usr/include/python2.7/
	
}

function configureAndInstall() {
    printf -- "Configuration and Installation started \n"
        #Install python for rhel distro
        if [[ "${DISTRO}" == "rhel-7.6" || "${DISTRO}" == "rhel-7.7" || "${DISTRO}" == "rhel-7.8" ]]; then
                cd $CURDIR
		configureAndInstallPython
                # mercurial install
                cd $CURDIR
                wget https://www.mercurial-scm.org/release/mercurial-5.1.tar.gz
                tar xvzf mercurial-5.1.tar.gz
                cd $CURDIR/mercurial-5.1
                make build
                sudo make install
                printf -- 'Installed python and mercurial on RHEL \n'
        elif [[ "$ID" == "sles" ]]; then
                cd $CURDIR
                printf -- "Installing Go... \n"
                wget  $GO_INSTALL_URL
                bash build_go.sh -y
                printf -- 'Installed go on SLES \n'
        else
        	export PATH=/usr/lib/go-1.10/bin:$PATH
        fi

	# Set GOPATH if not already set
	if [[ -z "${GOPATH}" ]]; then
		printf -- "Setting default value for GOPATH \n"

		#Check if go directory exists
		if [ ! -d "$HOME/go" ]; then
			mkdir "$HOME/go"
		fi
		
		export GOPATH="${GO_DEFAULT}"
		
        #Check if bin directory exists
		if [ ! -d "$GOPATH/bin" ]; then
			mkdir "$GOPATH/bin"
		fi
		export PATH=$PATH:$GOPATH/bin
	else
		printf -- "GOPATH already set : Value : %s \n" "$GOPATH" 
	fi
	printenv >>"$LOG_FILE"

    # Install glide
    cd "$GOPATH"/bin
    wget https://github.com/Masterminds/glide/releases/download/"$GLIDE_VERSION"/glide-"$GLIDE_VERSION"-linux-s390x.tar.gz
    tar -xzf glide-"$GLIDE_VERSION"-linux-s390x.tar.gz linux-s390x/glide --strip=1
    glide --version
    printf -- "Install glide success\n" >> "$LOG_FILE"
  
    # Build heketi
    if [ -d "$GOPATH/src/github.com/heketi" ]; then
    	echo "Heketi folder already exists, removing it to continue with the installation";
		rm -rf "$GOPATH/src/github.com/heketi"
	fi
    
    mkdir -p $GOPATH/src/github.com/heketi
    cd $GOPATH/src/github.com/heketi
    git clone -b v"${PACKAGE_VERSION}" https://github.com/heketi/heketi.git
    cd "$GOPATH/src/github.com/heketi/heketi"
    curl -o glide.lock.diff $PATCH_URL/glide.lock.diff 2>&1 | tee -a "$LOG_FILE"
    patch --ignore-whitespace glide.lock < glide.lock.diff
    make
    sudo make install
    printf -- "Build and install heketi success\n" >> "$LOG_FILE"
    
    # Create heketi lib directory
    #Check if lib directory exists
	if [ ! -d /var/lib/heketi ]; then
	    sudo mkdir -p /var/lib/heketi/
	fi

    cd $GOPATH/src/github.com/heketi/heketi/
    wget https://raw.githubusercontent.com/heketi/heketi/v8.0.0/etc/heketi.json
    echo "export PATH=$PATH" >> ~/.bashrc
    echo "export GOPATH=$GOPATH" >> ~/.bashrc

    # Run Tests
	runTest

    #cleanup
    cleanup

    #Verify heketi installation
    if command -v "$PACKAGE_NAME" > /dev/null; then 
        printf -- " %s Installation verified.\n" "$PACKAGE_NAME" 
    else
        printf -- "Error while installing %s, exiting with 127 \n" "$PACKAGE_NAME";
        exit 127;
    fi

}

function runTest() {
	set +e
	if [[ "$TESTS" == "true" ]]; then
		printf -- "TEST Flag is set, continue with running test \n"  >> "$LOG_FILE"
		
		if [[ "${DISTRO}" == "rhel-8.1" || "${DISTRO}" == "rhel-8.2" ]]; then
			cd "$GOPATH/src/github.com/heketi/heketi"
			make test 2>&1| tee -a test.log
			printf -- "Tests completed for RHEL 8.x \n"
			printf -- "NOTE: The "./tests/300-db-import-export.sh" test fails for RHEL 8.x on s390x and x86 as well. \n"
			count_of_failures=`grep "FAIL" test.log | wc -l`
			if [[ $count_of_failures == 1 ]]; then
				#Check if the failure that has occured is as expected.
				grep -E 'ERROR|./tests/300-db-import-export.sh' test.log
					if [[ $? != 0 ]]; then
						#Check if the above grep failed.Hence, new failures encountered
						printf -- "Unexpected Failures found \n"
						exit 1
					else
						exit 0
					fi
			fi
		else
			cd "$GOPATH/src/github.com/heketi/heketi"
			make test
			printf -- "Tests completed. \n" 
		fi
	fi
	set -e
}

function logDetails() {
    printf -- '**************************** SYSTEM DETAILS *************************************************************\n' >"$LOG_FILE"
    if [ -f "/etc/os-release" ]; then
        cat "/etc/os-release" >> "$LOG_FILE"
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
    echo " install.sh  [-d debug] [-y install-without-confirmation] [-t install and run tests]"
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
    printf -- "Running heketi: \n"
    printf -- "heketi  \n\n"

    printf -- "Run below command to use Heketi with config file\n"
    printf -- "source ~/.bashrc \n"
    printf -- "sudo heketi --config=\$GOPATH/src/github.com/heketi/heketi/heketi.json & \n"
    printf -- " Note: In case of error heketi: command not found use command as sudo env PATH=\$PATH heketi --config=\$GOPATH/src/github.com/heketi/heketi/heketi.json & \n"  
    printf -- "You have successfully started heketi.\n"
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
        sudo apt-get install -y git golang-1.10 make mercurial tar wget |& tee -a "$LOG_FILE"
        configureAndInstall |& tee -a "$LOG_FILE"
        ;;
	"ubuntu-20.04")
        printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
        printf -- "Installing dependencies... it may take some time.\n"
        sudo apt-get update
        sudo apt-get install -y git golang-1.14 make mercurial tar wget |& tee -a "$LOG_FILE"
	export PATH=/usr/lib/go-1.14/bin:$PATH
        configureAndInstall |& tee -a "$LOG_FILE"
		;;
    "rhel-7.6" | "rhel-7.7" | "rhel-7.8")
        printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
        printf -- "Installing dependencies... it may take some time.\n"
        sudo yum install -y git golang make tar wget patch python-docutils gcc gcc-c++ make wget tar bzip2-devel zlib-devel xz xz-devel readline-devel sqlite-devel tk-devel ncurses-devel gdbm-devel openssl-devel libdb-devel gdb bzip2 |& tee -a "$LOG_FILE"
        configureAndInstall |& tee -a "$LOG_FILE"
        ;;
    "rhel-8.1" | "rhel-8.2")
        printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
        printf -- "Installing dependencies... it may take some time.\n"
        sudo yum install -y git golang make tar wget patch python2 mercurial |& tee -a "$LOG_FILE"
	sudo ln -s /usr/bin/python2 /usr/bin/python
        configureAndInstall |& tee -a "$LOG_FILE"
	;;
    "sles-12.5")
        printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
        printf -- "Installing dependencies... it may take some time.\n"
        sudo zypper install -y gcc git gzip make python python-devel python-setuptools tar wget patch curl |& tee -a "$LOG_FILE"
        sudo easy_install pip |& tee -a "$LOG_FILE"
        sudo pip install mercurial |& tee -a "$LOG_FILE"
        configureAndInstall |& tee -a "$LOG_FILE"
        ;;
    "sles-15.1")
        printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
        printf -- "Installing dependencies... it may take some time.\n"
        sudo zypper install -y git gzip make mercurial python tar wget patch curl |& tee -a "$LOG_FILE"
        configureAndInstall |& tee -a "$LOG_FILE"
        ;;
    *)
        printf -- "%s not supported \n" "$DISTRO" |& tee -a "$LOG_FILE"
        exit 1
        ;;
esac

gettingStarted |& tee -a "$LOG_FILE"
