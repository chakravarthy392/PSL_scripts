#!/bin/bash
# © Copyright IBM Corporation 2020.
# LICENSE: Apache License, Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0)
#
# Instructions:
# Download build script: wget https://raw.githubusercontent.com/linux-on-ibm-z/scripts/master/TensorflowServing/2.2.0/build_tensorflow_serving.sh
# Execute build script: bash build_tensorflow_serving.sh    (provide -h for help)
#

set -e  -o pipefail

PACKAGE_NAME="tensorflow-serving"
PACKAGE_VERSION="2.2.0"
SOURCE_ROOT="$(pwd)"
USER="$(whoami)"


FORCE="false"
TESTS="false"
LOG_FILE="${SOURCE_ROOT}/logs/${PACKAGE_NAME}-${PACKAGE_VERSION}-$(date +"%F-%T").log"

trap cleanup 0 1 2 ERR

#Check if directory exists
if [ ! -d "$SOURCE_ROOT/logs/" ]; then
   mkdir -p "$SOURCE_ROOT/logs/"
fi


if [ -f "/etc/os-release" ]; then
        source "/etc/os-release"
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
    # Remove artifacts
        rm -rf $SOURCE_ROOT/bazel/bazel-2.0.0-dist.zip

        printf -- "Cleaned up the artifacts\n" | tee -a "$LOG_FILE"

}
function configureAndInstall() {
        printf -- 'Configuration and Installation started \n'

        printf -- "Create symlink for python 3 only environment\n" |& tee -a "$LOG_FILE"
        sudo ln -sf /usr/bin/python3 /usr/bin/python || true


        #Install grpcio
        printf -- "\nInstalling grpcio. . . \n"
        export GRPC_PYTHON_BUILD_SYSTEM_OPENSSL=True
        sudo -E pip3 install grpcio |& tee -a "${LOG_FILE}"

        # Build Bazel
        printf -- '\nBuilding Bazel..... \n'
        cd $SOURCE_ROOT
        mkdir bazel && cd bazel
        wget https://github.com/bazelbuild/bazel/releases/download/2.0.0/bazel-2.0.0-dist.zip
        unzip bazel-2.0.0-dist.zip
        sudo chmod -R +w .

        #Adding fixes and patches to the files
        PATCH="https://raw.githubusercontent.com/linux-on-ibm-z/scripts/master/Tensorflow/2.2.0/patch"
        curl -sSL $PATCH/patch1.diff | patch -p1 || echo "Error: Patch Bazel conditions/BUILD file"
        curl -sSL $PATCH/patch2.diff | patch -Np0 --ignore-whitespace || echo "Error: Patch Bazel third_party/BUILD file"
        sed -i "152s/-classpath/-J-Xms1g -J-Xmx1g -classpath/" scripts/bootstrap/compile.sh

        cd $SOURCE_ROOT/bazel
        env EXTRA_BAZEL_ARGS="--host_javabase=@local_jdk//:jdk" bash ./compile.sh
        export PATH=$PATH:$SOURCE_ROOT/bazel/output/
        echo $PATH

        #Patch Bazel Tools
        cd $SOURCE_ROOT/bazel
        bazel --host_jvm_args="-Xms1024m" --host_jvm_args="-Xmx2048m" build --host_javabase="@local_jdk//:jdk" //:bazel-distfile


        JTOOLS=$SOURCE_ROOT/remote_java_tools_linux
        mkdir -p $JTOOLS && cd $JTOOLS
        unzip $SOURCE_ROOT/bazel/derived/distdir/java_tools_javac11_linux-v7.0.zip
        curl -sSL $PATCH/tools.diff | patch -p1 || echo "Error: Patch Bazel tools"

        # Build TensorFlow
        printf -- '\nDownload Tensorflow source code..... \n'
        cd $SOURCE_ROOT
        rm -rf tensorflow
        git clone https://github.com/linux-on-ibm-z/tensorflow.git
        cd tensorflow
        git checkout v2.2.0-s390x

        export PYTHON_BIN_PATH="/usr/bin/python3"

        yes "" | ./configure || true

        printf -- '\nBuilding Tensorflow..... \n'
        bazel --host_jvm_args="-Xms1024m" --host_jvm_args="-Xmx2048m" build //tensorflow/tools/pip_package:build_pip_package

        #Build and install TensorFlow wheel
        printf -- '\nBuilding and installing Tensorflow wheel..... \n'
        cd $SOURCE_ROOT/tensorflow
        bazel-bin/tensorflow/tools/pip_package/build_pip_package $SOURCE_ROOT/tensorflow_wheel
        sudo pip3 install $SOURCE_ROOT/tensorflow_wheel/tensorflow-2.2.0-cp*-linux_s390x.whl

	#Install Boringssl
        cd $SOURCE_ROOT
        rm -rf boringssl
        wget https://github.com/google/boringssl/archive/7f634429a04abc48e2eb041c81c5235816c96514.tar.gz
        tar -zxvf 7f634429a04abc48e2eb041c81c5235816c96514.tar.gz
        mv boringssl-7f634429a04abc48e2eb041c81c5235816c96514/ boringssl/
        cd boringssl/
        sed -i '/set(ARCH "ppc64le")/a \elseif (${CMAKE_SYSTEM_PROCESSOR} STREQUAL "s390x")\n\ set(ARCH "s390x")' src/CMakeLists.txt
        sed -i '/OPENSSL_PNACL/a \#elif defined(__s390x__)\n\#define OPENSSL_64_BIT' src/include/openssl/base.h


        #Build Tensorflow serving
        printf -- '\nDownload Tensorflow serving source code..... \n'
        cd $SOURCE_ROOT
        rm -rf serving
        git clone https://github.com/tensorflow/serving
        cd serving
        git checkout 2.2.0

        #Apply Patches
	export PATCH_URL="https://raw.githubusercontent.com/linux-on-ibm-z/scripts/master/TensorflowServing/2.2.0/patch"
        printf -- '\nPatching Tensorflow Serving..... \n'
        wget -O tfs_patch.diff $PATCH_URL/tfs_patch.diff
	sed -i "s?source_root?$SOURCE_ROOT?" tfs_patch.diff
	git apply tfs_patch.diff
	cd $SOURCE_ROOT/tensorflow
	wget -O tf_patch.diff $PATCH_URL/tf_patch.diff
	git apply tf_patch.diff

        printf -- '\nBuilding Tensorflow Serving..... \n'
        cd $SOURCE_ROOT/serving
        bazel --host_jvm_args="-Xms1024m" --host_jvm_args="-Xmx2048m" build --color=yes --curses=yes  --local_resources 5000,1.0,1.0 --host_javabase="@local_jdk//:jdk" --verbose_failures --output_filter=DONT_MATCH_ANYTHING -c opt tensorflow_serving/model_servers:tensorflow_model_server

        bazel --host_jvm_args="-Xms1024m" --host_jvm_args="-Xmx2048m" build  --verbose_failures //tensorflow_serving/tools/pip_package:build_pip_package
        bazel-bin/tensorflow_serving/tools/pip_package/build_pip_package $SOURCE_ROOT/tfs
	
	if [[ "$DISTRO" == "ubuntu-18.04" ]]; then
	printf -- '\nInside Ubuntu 18.04..... \n'
	sudo pip3 install --upgrade cython && sudo pip3 uninstall -y enum34
	fi
	
        sudo pip3 --no-cache-dir install --upgrade  $SOURCE_ROOT/tfs/tensorflow_serving_api-*.whl

        sudo cp $SOURCE_ROOT/serving/bazel-bin/tensorflow_serving/model_servers/tensorflow_model_server /usr/local/bin

        #Creating tflite.model
		printf -- '\nCreating and replacing default model.tflite..... \n'
	    sudo rm -rf /tmp/saved_model_half_plus_two*
	    sudo python $SOURCE_ROOT/serving/tensorflow_serving/servables/tensorflow/testdata/saved_model_half_plus_two.py
        sudo cp /tmp/saved_model_half_plus_two_tflite/model.tflite $SOURCE_ROOT/serving/tensorflow_serving/servables/tensorflow/testdata/saved_model_half_plus_two_tflite/00000123/
  
        # Run Tests
        runTest

        #Cleanup
        cleanup

        printf -- "\n Installation of %s %s was successful \n\n" $PACKAGE_NAME $PACKAGE_VERSION
}

function runTest() {
        set +e
        if [[ "$TESTS" == "true" ]]; then
                printf -- "TEST Flag is set , Continue with running test \n"

                if [[ "$DISTRO" == "ubuntu-16.04" ]]; then
                        printf -- "Upgrade setuptools to resolve test failures with an error '_NamespacePath' object has no attribute 'sort' \n" |& tee -a "$LOG_FILE"
                        sudo pip3 install --upgrade setuptools
                fi
                cd $SOURCE_ROOT/serving
                bazel --host_jvm_args="-Xms1024m" --host_jvm_args="-Xmx2048m" test --host_javabase="@local_jdk//:jdk" --test_tag_filters=-gpu,-benchmark-test -k --build_tests_only --test_output=errors --verbose_failures -c opt tensorflow_serving/...
                printf -- "Tests completed. \n"

        fi
        set -e
}

function logDetails() {
        printf -- '**************************** SYSTEM DETAILS *************************************************************\n' >>"$LOG_FILE"
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
        echo "  bash build_tensorflow_serving.sh  [-d debug] [-y install-without-confirmation] [-t install-with-tests]"
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
        printf -- "To verify, run TensorFlow Serving from command Line : \n"
        printf -- "  $ cd $SOURCE_ROOT  \n"
        printf -- "  $ export TESTDATA=$SOURCE_ROOT/serving/tensorflow_serving/servables/tensorflow/testdata  \n"
        printf -- "  $ tensorflow_model_server --rest_api_port=8501 --model_name=half_plus_two --model_base_path=$TESTDATA/saved_model_half_plus_two_cpu &  \n"
        printf -- "  $ curl -d '{"instances": [1.0, 2.0, 5.0]}'     -X POST http://localhost:8501/v1/models/half_plus_two:predict\n"
        printf -- "Output should look like:\n"
        printf -- "  $ predictions: [2.5, 3.0, 4.5]\n"
        printf -- 'Make sure JAVA_HOME is set and bazel binary is in your path in case of test case execution.'
        printf -- '*************************************************************************************************\n'
        printf -- '\n'
}

###############################################################################################################

logDetails
prepare #Check Prequisites

DISTRO="$ID-$VERSION_ID"
case "$DISTRO" in
"ubuntu-20.04" )
        printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
        printf -- "Installing dependencies... it may take some time.\n"
        sudo apt-get update
    sudo apt-get install sudo vim wget curl libhdf5-dev python3-dev python3-pip pkg-config unzip openjdk-11-jdk zip libssl-dev git python3-numpy libblas-dev  liblapack-dev python3-scipy gfortran swig cython3 automake libtool -y |& tee -a "${LOG_FILE}"
        sudo ldconfig
        sudo pip3 install --no-cache-dir numpy==1.16.2 future wheel backports.weakref portpicker futures enum34 keras_preprocessing keras_applications h5py tensorflow_estimator setuptools pybind11 |& tee -a "${LOG_FILE}"
        export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-s390x/
        export PATH=$JAVA_HOME/bin:$PATH
        configureAndInstall |& tee -a "${LOG_FILE}"
        ;;

"ubuntu-18.04" )
        printf -- "Installing %s %s for %s \n" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$DISTRO" |& tee -a "$LOG_FILE"
        printf -- "Installing dependencies... it may take some time.\n"
        sudo apt-get update
    sudo apt-get install sudo vim wget curl libhdf5-dev python3-dev python3-pip pkg-config unzip openjdk-11-jdk zip libssl-dev git python3-numpy libblas-dev  liblapack-dev python3-scipy gfortran swig cython3 automake libtool -y |& tee -a "${LOG_FILE}"
        sudo ldconfig
        sudo pip3 install --no-cache-dir numpy==1.16.2 future wheel backports.weakref portpicker futures enum34 keras_preprocessing keras_applications  h5py==2.10.0  tensorflow_estimator setuptools pybind11 |& tee -a "${LOG_FILE}"
        export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-s390x/
        export PATH=$JAVA_HOME/bin:$PATH
        configureAndInstall |& tee -a "${LOG_FILE}"
        ;;

*)
        printf -- "%s not supported \n" "$DISTRO" |& tee -a "$LOG_FILE"
        exit 1
        ;;
esac

gettingStarted |& tee -a "${LOG_FILE}"

