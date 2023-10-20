#!/bin/bash
set -e -u

/opt/python/cp38-cp38/bin/python -m pip install auditwheel

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
        /opt/python/cp38-cp38/bin/python $AUDITWHEEL repair "$wheel" --plat "$WHEEL_PLATFORM" -w $PYTHON_SDK_WHEELHOUSE/dist
    fi
}

if [[ -n "${PYCBC_USE_OPENSSL-}" && "$PYCBC_USE_OPENSSL" = true && -n "${PYCBC_OPENSSL_VERSION-}" ]]; then
    OPENSSL_DIR=/usr/local/openssl
    LIB_CRYPTO=
    LIB_SSL=
    
    OPENSSL_BASE_URL=https://www.openssl.org/source/old
    if [[ "$PYCBC_OPENSSL_VERSION" == *"1.1.1"* ]]; then
        OPENSSL_BASE_URL="${OPENSSL_BASE_URL}/1.1.1"
        LIB_CRYPTO="${OPENSSL_DIR}/lib/libcrypto.so.1.1"
        LIB_SSL="${OPENSSL_DIR}/lib/libssl.so.1.1"
    elif [[ "$PYCBC_OPENSSL_VERSION" == *"3.0"* ]]; then
        OPENSSL_BASE_URL="${OPENSSL_BASE_URL}/3.0"
        LIB_CRYPTO="${OPENSSL_DIR}/lib/libcrypto.so.3"
        LIB_SSL="${OPENSSL_DIR}/lib/libssl.so.3"
    elif [[ "$PYCBC_OPENSSL_VERSION" == *"3.1"* ]]; then
        OPENSSL_BASE_URL="${OPENSSL_BASE_URL}/3.1"
        LIB_CRYPTO="${OPENSSL_DIR}/lib/libcrypto.so.3.1"
        LIB_SSL="${OPENSSL_DIR}/lib/libssl.so.3.1"
    else
        echo "Cannot install OpenSSL=${PYCBC_OPENSSL_VERSION}"
        exit 1
    fi

    if [[ ! -f "${LIB_CRYPTO}" || ! -f "${LIB_SSL}" ]]; then
        echo "Installing OpenSSL=${PYCBC_OPENSSL_VERSION}"
        cd /usr/src && \
            curl -L -o openssl-$PYCBC_OPENSSL_VERSION.tar.gz $OPENSSL_BASE_URL/openssl-$PYCBC_OPENSSL_VERSION.tar.gz && \
            tar -xvf openssl-$PYCBC_OPENSSL_VERSION.tar.gz && \
            mv openssl-$PYCBC_OPENSSL_VERSION openssl && \
            cd openssl && \
            ./config --prefix=$OPENSSL_DIR --openssldir=$OPENSSL_DIR shared zlib && \
            make -j4 && \
            make install_sw
    else
        echo "Found OpenSSL=${PYCBC_OPENSSL_VERSION}; libcrypto=${LIB_CRYPTO}, libssl=${LIB_SSL}"
    fi

    export PYCBC_OPENSSL_DIR=$OPENSSL_DIR
fi

# Compile wheels
for PYBIN in /opt/python/*; do
    python_bin="${PYBIN##*/}"
    if in_allowed_python_versions "${python_bin}" "${allowed_python_versions[@]}" ; then
        python_version=$(get_python_version "${python_bin}")
        export PYCBC_PYTHON3_EXECUTABLE="/opt/python/${python_bin}/bin/python${python_version}"
        if [ $python_version == '3.7' ]
        then
            export PYCBC_PYTHON3_INCLUDE_DIR="/opt/python/${python_bin}/include/python${python_version}m"
        else
            export PYCBC_PYTHON3_INCLUDE_DIR="/opt/python/${python_bin}/include/python${python_version}"
        fi
        if [[ -n "${PYCBC_VERBOSE_MAKEFILE-}" ]]; then
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
    repair_wheel "$whl"
done