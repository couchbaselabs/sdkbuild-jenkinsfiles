#!/bin/bash
set -e -u

DEFAULT_BIN=/opt/python/cp38-cp38/bin
DEFAULT_PYTHON=$DEFAULT_BIN/python
DEFAULT_PIP=$DEFAULT_BIN/pip
# TODO:  update to 6.0.0 for Python 3.12 support
$DEFAULT_PYTHON -m pip install auditwheel==6.1.0
if [[ -n "${PYCBCC_LIMITED_API-}" ]]; then
    $DEFAULT_PYTHON -m pip install abi3audit
fi

#allowed_python_versions="cp37-cp37m", "cp38-cp38", "cp39-cp39", "cp310-cp310", "cp311-cp311", "cp312-cp312")
# 3.7 EOL 2023.06.30, keep in list just in case, but CI pipeline sets CPYTHON_VERSIONS
IFS=' ' read -r -a allowed_python_versions <<< $CPYTHON_VERSIONS

function in_allowed_python_versions {
    local e match="$1"
    shift
    for e; do [[ "$e" == "$match" ]] && return 0; done
    return 1
}

function get_python_version {
    local python_version=""
    case "$1" in
        "cp37-cp37m")
            python_version="3.7"
            ;;
        "cp38-cp38")
            python_version="3.8"
            ;;
        "cp39-cp39")
            python_version="3.9"
            ;;
        "cp310-cp310")
            python_version="3.10"
            ;;
        "cp311-cp311")
            python_version="3.11"
            ;;
        "cp312-cp312")
            python_version="3.12"
            ;;
    esac

    echo "$python_version"
}

function repair_wheel {
    wheel="$1"
    if ! auditwheel show "$wheel"; then
        echo "Skipping non-platform wheel $wheel"
    else
        $DEFAULT_PYTHON $AUDITWHEEL repair "$wheel" --plat "$WHEEL_PLATFORM" -w $PYTHON_SDK_WHEELHOUSE
    fi
}

function audit_abi3_wheel {
    wheel="$1"
    echo "Auditing $wheel for abi3 compliance..."
    report="abi3audit_report.json"
    # we expect abi3audit to have a non-zero exit code, so catch it in an if-statement
    if $DEFAULT_BIN/abi3audit --strict --report $wheel > $report ; then
        echo 'Finished parsing wheel.'
    else
        echo 'Finished parsing wheel.'
    fi
    
    if [ -s $report ]; then
        echo 'Parsing audit report...'
        $DEFAULT_PYTHON $CHECK_ABI3AUDIT $report "pycbcc"
        #cleanup
        rm "$report"
    else
        echo 'Audit report not created.'
        exit 1    
    fi
}

function reduce_wheel_size {
    cd $PYTHON_SDK_WHEELHOUSE
    for f in *.whl; do
        echo "found wheel=$f"
        if [[ $f == *"manylinux"* || $f == *"musllinux"* ]]; then
            echo "Reducing wheel size of $f"
            WHEEL_ROOT=$($DEFAULT_PYTHON $PARSE_WHEEL_NAME $f "couchbase_columnar")
            $DEFAULT_PYTHON -m wheel unpack $f
            mv $f $PYTHON_SDK_DEBUG_WHEELHOUSE
            echo "checking dir..."
            ls -alh
            cd $WHEEL_ROOT/couchbase_columnar/protocol
            cp pycbcc_core.so pycbcc_core.orig.so
            objcopy --only-keep-debug pycbcc_core.so pycbcc_core.debug.so
            objcopy --strip-debug --strip-unneeded pycbcc_core.so
            objcopy --add-gnu-debuglink=pycbcc_core.debug.so pycbcc_core.so
            echo "grep pycbcc.so sizes"
            ls -alh | grep pycbcc
            rm pycbcc_core.orig.so pycbcc_core.debug.so
            echo "grep pycbcc.so sizes (should only have reduced size)"
            ls -alh | grep pycbcc
            cd ../../..
            $DEFAULT_PYTHON -m wheel pack $WHEEL_ROOT
        else
          echo "Wheel $f is not tagged as manylinux or musllinux, removing."
          rm "$f"
        fi
    done
}

if [[ -n "${PYCBCC_USE_OPENSSL-}" && "$PYCBCC_USE_OPENSSL" = true && -n "${PYCBCC_OPENSSL_VERSION-}" ]]; then
    OPENSSL_DIR=/usr/local/openssl
    LIB_CRYPTO=
    LIB_SSL=
    
    OPENSSL_BASE_URL=https://www.openssl.org/source/old
    if [[ "$PYCBCC_OPENSSL_VERSION" == *"1.1.1"* ]]; then
        OPENSSL_BASE_URL="${OPENSSL_BASE_URL}/1.1.1"
        LIB_CRYPTO="${OPENSSL_DIR}/lib/libcrypto.so.1.1"
        LIB_SSL="${OPENSSL_DIR}/lib/libssl.so.1.1"
    elif [[ "$PYCBCC_OPENSSL_VERSION" == *"3.0"* ]]; then
        OPENSSL_BASE_URL="${OPENSSL_BASE_URL}/3.0"
        LIB_CRYPTO="${OPENSSL_DIR}/lib/libcrypto.so.3"
        LIB_SSL="${OPENSSL_DIR}/lib/libssl.so.3"
    elif [[ "$PYCBCC_OPENSSL_VERSION" == *"3.1"* ]]; then
        OPENSSL_BASE_URL="${OPENSSL_BASE_URL}/3.1"
        LIB_CRYPTO="${OPENSSL_DIR}/lib/libcrypto.so.3.1"
        LIB_SSL="${OPENSSL_DIR}/lib/libssl.so.3.1"
    else
        echo "Cannot install OpenSSL=${PYCBCC_OPENSSL_VERSION}"
        exit 1
    fi

    if [[ ! -f "${LIB_CRYPTO}" || ! -f "${LIB_SSL}" ]]; then
        echo "Installing OpenSSL=${PYCBCC_OPENSSL_VERSION}"
        if [ ! -d "/usr/src" ]; then
            mkdir /usr/src
        fi
        cd /usr/src && \
            curl -L -o openssl-$PYCBCC_OPENSSL_VERSION.tar.gz $OPENSSL_BASE_URL/openssl-$PYCBCC_OPENSSL_VERSION.tar.gz && \
            tar -xvf openssl-$PYCBCC_OPENSSL_VERSION.tar.gz && \
            mv openssl-$PYCBCC_OPENSSL_VERSION openssl && \
            cd openssl && \
            ./config --prefix=$OPENSSL_DIR --openssldir=$OPENSSL_DIR shared zlib && \
            make -j4 && \
            make install_sw
    else
        echo "Found OpenSSL=${PYCBCC_OPENSSL_VERSION}; libcrypto=${LIB_CRYPTO}, libssl=${LIB_SSL}"
    fi

    export PYCBCC_OPENSSL_DIR=$OPENSSL_DIR
fi

# Compile wheels
for PYBIN in /opt/python/*; do
    python_bin="${PYBIN##*/}"
    if in_allowed_python_versions "${python_bin}" "${allowed_python_versions[@]}" ; then
        python_version=$(get_python_version "${python_bin}")
        export PYCBCC_PYTHON3_EXECUTABLE="/opt/python/${python_bin}/bin/python${python_version}"
        if [ $python_version == '3.7' ]
        then
            export PYCBCC_PYTHON3_INCLUDE_DIR="/opt/python/${python_bin}/include/python${python_version}m"
        else
            export PYCBCC_PYTHON3_INCLUDE_DIR="/opt/python/${python_bin}/include/python${python_version}"
        fi
        if [[ -n "${PYCBCC_VERBOSE_MAKEFILE-}" ]]; then
            "/opt/python/${python_bin}/bin/pip" wheel $PYTHON_SDK_WORKDIR --no-deps -w $PYTHON_SDK_WHEELHOUSE -v -v -v
        else
            "/opt/python/${python_bin}/bin/pip" wheel $PYTHON_SDK_WORKDIR --no-deps -w $PYTHON_SDK_WHEELHOUSE
        fi
    fi
done

# Bundle external shared libraries into the wheels
# we use a monkey patched version of auditwheel in order to not bundle
# OpenSSL libraries (see auditwheel-update)
for whl in $PYTHON_SDK_WHEELHOUSE/*.whl; do
    if [[ -n "${PYCBCC_LIMITED_API-}" ]]; then
        audit_abi3_wheel "$whl"
    fi
    repair_wheel "$whl"
    reduce_wheel_size
done