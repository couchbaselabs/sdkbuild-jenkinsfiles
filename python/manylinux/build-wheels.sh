#!/bin/bash
set -e -u

/opt/python/cp38-cp38/bin/python -m pip install auditwheel
# export AUDITWHEEL=/tmp/auditwheel-pycbc
# export PLATFORM=manylinux2014_x86_64

#allowed_python_versions=("cp37-cp37m", "cp38-cp38", "cp39-cp39", "cp310-cp310")
#allowed_python_versions=("cp38-cp38")
IFS=' ' read -r -a allowed_python_versions <<< $PYTHON_VERSIONS

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

# Compile wheels
for PYBIN in /opt/python/*; do
    python_bin="${PYBIN##*/}"
    if in_allowed_python_versions "${python_bin}" "${allowed_python_versions[@]}" ; then
        python_version=$(get_python_version "${python_bin}")
        export PYCBC_PYTHON3_EXECUTABLE="/opt/python/${python_bin}/bin/python${python_version}"
        export PYCBC_PYTHON3_INCLUDE_DIR="/opt/python/${python_bin}/include/python${python_version}"
        "/opt/python/${python_bin}/bin/pip" wheel $PYTHON_SDK_WORKDIR --no-deps -w $PYTHON_SDK_WHEELHOUSE
    fi
done

# Bundle external shared libraries into the wheels
# we use a monkey patched version of auditwheel in order to not bundle
# OpenSSL libraries (see auditwheel-update)
for whl in $PYTHON_SDK_WHEELHOUSE/*.whl; do
    repair_wheel "$whl"
done