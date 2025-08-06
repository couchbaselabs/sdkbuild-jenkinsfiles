#! /bin/bash

set -e -u

PROJECT_ROOT="$(
    cd "$(dirname "$0"/..)" >/dev/null 2>&1
    pwd -P
)"

CI_SCRIPTS_PATH="$PROJECT_ROOT/ci_scripts"
PROJECT_PREFIX=""

function log_message {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $1"
}

function display_info {
    echo "Workflow Run ID=$GITHUB_RUN_ID"
    echo "Workflow Event=$GITHUB_EVENT_NAME"
    echo "is_release=${CBCI_IS_RELEASE:-}"
    echo "SHA=${CBCI_SHA:-}"
    echo "version=${CBCI_VERSION:-}"
    echo "cxx_change=${CBCI_CXX_CHANGE:-}"
    echo "build_config=${CBCI_CONFIG:-}"
    echo "use_uv=${CBCI_USE_UV:-}"
    echo "PROJECT_TYPE=$CBCI_PROJECT_TYPE"
    echo "DEFAULT_PYTHON=$CBCI_DEFAULT_PYTHON"
    echo "SUPPORTED_PYTHON_VERSIONS=$CBCI_SUPPORTED_PYTHON_VERSIONS"
    echo "SUPPORTED_X86_64_PLATFORMS=$CBCI_SUPPORTED_X86_64_PLATFORMS"
    echo "DEFAULT_LINUX_X86_64_PLATFORM=$CBCI_DEFAULT_LINUX_X86_64_PLATFORM"
    echo "DEFAULT_LINUX_ARM64_PLATFORM=$CBCI_DEFAULT_LINUX_ARM64_PLATFORM"
    echo "DEFAULT_MACOS_X86_64_PLATFORM=$CBCI_DEFAULT_MACOS_X86_64_PLATFORM"
    echo "DEFAULT_MACOS_ARM64_PLATFORM=$CBCI_DEFAULT_MACOS_ARM64_PLATFORM"
    echo "DEFAULT_WINDOWS_PLATFORM=$CBCI_DEFAULT_WINDOWS_PLATFORM"
    echo "DEFAULT_LINUX_CONTAINER=$CBCI_DEFAULT_LINUX_CONTAINER"
    echo "DEFAULT_ALPINE_CONTAINER=$CBCI_DEFAULT_ALPINE_CONTAINER"
}

function validate_sha {
    sha="${CBCI_SHA:-}"
    if [ -z "$sha" ]; then
        echo "Must provide SHA"
        exit 1
    fi
    if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
        echo "Invalid SHA: $sha"
        exit 1
    fi
}

function validate_version {
    version="${CBCI_VERSION:-}"
    if [ -z "$version" ]; then
        echo "Must provide version"
        exit 1
    fi
    if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc|dev|post)[0-9]+)?$ ]]; then
        echo "Invalid version: $version"
        exit 1
    fi
}

function validate_pycbc_input {
    workflow_type="${1:-}"
    set_project_prefix
    if [ "$workflow_type" == "build_wheels" ] || [ "$workflow_type" == "publish" ]; then
        echo "workflow_type: ${workflow_type}, params: $@"
        is_release="${CBCI_IS_RELEASE:-}"
        if [[ ! -z "$is_release" && "$is_release" == "true" ]]; then
            validate_sha
            validate_version
        fi
    elif [ "$workflow_type" == "tests" ]; then
        echo "workflow_type: ${workflow_type}, params: $@"
    else
        echo "Invalid workflow type: $workflow_type"
        exit 1
    fi
}

function validate_pycbcc_input {
    workflow_type="${1:-}"
    set_project_prefix
    if [ "$workflow_type" == "build_wheels" ] || [ "$workflow_type" == "publish" ]; then
        echo "workflow_type: ${workflow_type}, params: $@"
        is_release="${CBCI_IS_RELEASE:-}"
        if [[ ! -z "$is_release" && "$is_release" == "true" ]]; then
            validate_sha
            validate_version
        fi
    elif [ "$workflow_type" == "tests" ]; then
        echo "workflow_type: ${workflow_type}, params: $@"
    else
        echo "Invalid workflow type: $workflow_type"
        exit 1
    fi
}

function validate_pycbac_input {
    workflow_type="${1:-}"
    set_project_prefix
    if [ "$workflow_type" == "tests" ] || [ "$workflow_type" == "publish" ]; then
        echo "workflow_type: ${workflow_type}, params: $@"
        is_release="${CBCI_IS_RELEASE:-}"
        if [[ ! -z "$is_release" && "$is_release" == "true" ]]; then
            validate_sha
            validate_version
        fi
    elif [ "$workflow_type" == "verify_release" ]; then
        echo "workflow_type: ${workflow_type}, params: $@"
        validate_version
        validate_sha
        packaging_index="${CBCI_PACKAGING_INDEX:-}"
        if [ -z "$packaging_index" ]; then
            echo "Must provide a packaging index."
            exit 1
        fi
        if [ "$packaging_index" != "PYPI" ] && [ "$packaging_index" != "TEST_PYPI" ]; then
            echo "Packing index must be either PYPI or TEST_PYPI. Provided: $packaging_index"
            exit 1
        fi
    else
        echo "Invalid workflow type: $workflow_type"
        exit 1
    fi
}

function validate_input {
    workflow_type="${1:-}"
    set_project_prefix
    if [ "$PROJECT_PREFIX" == "PYCBC" ]; then
        validate_pycbc_input "$workflow_type"
    elif [ "$PROJECT_PREFIX" == "PYCBCC" ]; then
        validate_pycbcc_input "$workflow_type"
    elif [ "$PROJECT_PREFIX" == "PYCBAC" ]; then
        validate_pycbac_input "$workflow_type"
    else
        echo "Invalid project prefix: $PROJECT_PREFIX"
        exit 1
    fi
}

function set_project_prefix {
    if [ ! -z "$PROJECT_PREFIX" ]; then
        return
    fi
    project_type="${CBCI_PROJECT_TYPE:-}"
    if [[ "$project_type" == "OPERATIONAL" || "$project_type" == "PYCBC" ]]; then
        PROJECT_PREFIX="PYCBC"
    elif [[ "$project_type" == "COLUMNAR" || "$project_type" == "PYCBCC" ]]; then
        PROJECT_PREFIX="PYCBCC"
    elif [[ "$project_type" == "ANALYTICS" || "$project_type" == "PYCBAC" ]]; then
        PROJECT_PREFIX="PYCBAC"
    else
        echo "Invalid project type: $project_type"
        exit 1
    fi
}

function set_client_version {
    set_project_prefix
    version_script=""
    if [ "$PROJECT_PREFIX" == "PYCBC" ]; then
        if [ ! -f "couchbase_version.py" ]; then
            echo "Missing expected files.  Confirm checkout has completed successfully."
            exit 1
        fi
        version_script="couchbase_version.py"
    elif [ "$PROJECT_PREFIX" == "PYCBCC" ]; then
        if [ ! -f "couchbase_columnar_version.py" ]; then
            echo "Missing expected files.  Confirm checkout has completed successfully."
            exit 1
        fi
        version_script="couchbase_columnar_version.py"
    elif [ "$PROJECT_PREFIX" == "PYCBAC" ]; then
        if [ ! -f "couchbase_analytics_version.py" ]; then
            echo "Missing expected files.  Confirm checkout has completed successfully."
            exit 1
        fi
        python -m pip install tomli tomli-w
        version_script="couchbase_analytics_version.py"
    else
        echo "Invalid project prefix: $PROJECT_PREFIX"
        exit 1
    fi
    version="${CBCI_VERSION:-}"
    if ! [ -z "$version" ]; then
        echo "Setting client version git tag to $version"
        git config user.name "Couchbase SDK Team"
        git config user.email "sdk_dev@couchbase.com"
        git tag -a $version -m "Release of client version $version"
        git tag --sort=-version:refname | head -n 10
    fi

    if [ "$PROJECT_PREFIX" == "PYCBAC" ]; then
        python $version_script --mode make --update-pyproject
        python -m pip uninstall -y tomli tomli-w
    else
        python $version_script --mode make
    fi
}

function setup_and_execute_linting {
    set_project_prefix
    if [ ! -z "${CBCI_USE_UV:-}" ]; then
        uv sync --locked --no-group sphinx
    else
        python -m pip install --upgrade pip setuptools wheel
        if [ "$PROJECT_PREFIX" == "PYCBAC" ]; then
            echo "Running pip install for dev requirements."
            python -m pip install -r requirements-dev.txt
        fi
        echo "Running pip install for requirements."
        python -m pip install -r requirements.txt
        python -m pip install pre-commit
    fi
    # install dev dependencies first and then set the client version.
    # Required for the EA client as it will update the pyproject.toml file via tomli/tomli-w
    set_client_version
    pre-commit run --all-files
}

function parse_build_config {
    config_stage="${1:-}"
    python_exe="${2:-python3}"
    build_config="${CBCI_CONFIG:-}"
    echo "Parsing build config: $build_config for stage: $config_stage"

    parse_cmd=""
    if [ "$config_stage" == "sdist" ]; then
        parse_cmd="parse_sdist_config"
    elif [ "$config_stage" == "wheel" ]; then
        parse_cmd="parse_wheel_config"
    else
        echo "Invalid config stage: $config_stage"
        exit 1
    fi
    if [ -z "$parse_cmd" ]; then
        echo "Unable to set parse command."
        exit 1
    fi
    exit_code=0
    config_str=$($python_exe "$CI_SCRIPTS_PATH/pygha.py" "$parse_cmd" "CBCI_CONFIG") || exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "config_str=$config_str"
        echo "Failed to parse build config."
        exit 1
    fi
    export $(echo $config_str)
    # export $(echo "$config_str" | jq -r '. | to_entries[] | join("=")')

    env_vars=$(env | grep $PROJECT_PREFIX)
    echo "Environment variables:"
    echo "$env_vars"
}

function build_sdist {
    echo "PROJECT_ROOT=$PROJECT_ROOT"
    set_project_prefix

    echo "Installing basic build dependencies."
    python -m pip install --upgrade pip setuptools wheel

    parse_build_config "sdist"

    cd $PROJECT_ROOT

    if [ "$PROJECT_PREFIX" != "PYCBAC" ]; then
        echo "Building C++ core CPM Cache."
        python setup.py configure_ext
        rm -rf ./build
    fi

    set_client_version
    echo "Building source distribution."
    python setup.py sdist
    cd dist
    echo "ls -alh $PROJECT_ROOT/dist"
    ls -alh
}

function get_sdist_name {
    sdist_dir="$PROJECT_ROOT/dist"
    if [ ! -d "$sdist_dir" ]; then
        echo "sdist_dir does not exist."
        exit 1
    fi
    cd dist
    sdist_name=$(find . -name '*.tar.gz' | cut -c 3- | rev | cut -c 8- | rev)
    echo "$sdist_name"
}

function get_stage_matrices {
    exit_code=0
    stage_matrices=$(python "$CI_SCRIPTS_PATH/pygha.py" "get_stage_matrices" "CBCI_CONFIG") || exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "stage_matrices=$stage_matrices"
        echo "Failed to generate stage matrices."
        exit 1
    fi
    echo "$stage_matrices"
}

function handle_cxx_change {
    cxx_change="${CBCI_CXX_CHANGE:-}"
    if [[ ! -z "$cxx_change" && "$GITHUB_EVENT_NAME" == "workflow_dispatch" ]]; then
        if [[ "$cxx_change" == "PR_*" ]]; then
            pr=$(echo "$cxx_change" | cut -d'_' -f 2)
            echo "Attempting to checkout C++ core PR#$pr."
            cd deps/couchbase-cxx-client
            git fetch origin pull/$pr/head:tmp
            git checkout tmp
            git log --oneline -n 10
        elif [[ "$cxx_change" == "BR_*" ]]; then
            branch=$(echo "$cxx_change" | cut -d'_' -f 2)
            echo "Attempting to checkout C++ core branch."
            cd deps/couchbase-cxx-client
            git fetch origin
            git --no-pager branch -r
            git checkout $branch
            git log --oneline -n 10
        elif [[ "$cxx_change" == "CP_*" ]]; then
            echo "Attempting to cherry-pick C++ core SHA."
        else
            echo "No CXX change detected."
        fi
    fi
}

function extract_sdist {
    sdist_name="$1"
    echo "Extracting sdist: $sdist_name"
    ls -alh
    tar -xvzf $sdist_name.tar.gz
    cp -r $sdist_name/. .
    rm -rf $sdist_name
}

function build_openssl {
    openssl_version="$1"
    openssl_dir="$2"
    LIB_CRYPTO=
    LIB_SSL=

    OPENSSL_BASE_URL=https://www.openssl.org/source/old
    if [[ "$openssl_version" == *"1.1.1"* ]]; then
        OPENSSL_BASE_URL="${OPENSSL_BASE_URL}/1.1.1"
        LIB_CRYPTO="${openssl_dir}/lib/libcrypto.so.1.1"
        LIB_SSL="${openssl_dir}/lib/libssl.so.1.1"
    elif [[ "$openssl_version" == *"3.0"* ]]; then
        OPENSSL_BASE_URL="${OPENSSL_BASE_URL}/3.0"
        LIB_CRYPTO="${openssl_dir}/lib/libcrypto.so.3"
        LIB_SSL="${openssl_dir}/lib/libssl.so.3"
    elif [[ "$openssl_version" == *"3.1"* ]]; then
        OPENSSL_BASE_URL="${OPENSSL_BASE_URL}/3.1"
        LIB_CRYPTO="${openssl_dir}/lib/libcrypto.so.3.1"
        LIB_SSL="${openssl_dir}/lib/libssl.so.3.1"
    else
        echo "Cannot install OpenSSL=${openssl_version}"
        exit 1
    fi

    if [[ ! -f "${LIB_CRYPTO}" || ! -f "${LIB_SSL}" ]]; then
        echo "Installing OpenSSL=${openssl_version}"
        if [ ! -d "/usr/src" ]; then
            mkdir /usr/src
        fi
        cd /usr/src &&
            curl -L -o openssl-$openssl_version.tar.gz $OPENSSL_BASE_URL/openssl-$openssl_version.tar.gz &&
            tar -xvf openssl-$openssl_version.tar.gz &&
            mv openssl-$openssl_version openssl &&
            cd openssl &&
            ./config --prefix=$openssl_dir --openssldir=$openssl_dir shared zlib &&
            make -j4 &&
            make install_sw
    else
        echo "Found OpenSSL=${openssl_version}; libcrypto=${LIB_CRYPTO}, libssl=${LIB_SSL}"
    fi
}

function in_allowed_python_versions {
    local e match="$1"
    shift
    for e; do [[ "$e" == "$match" ]] && return 0; done
    return 1
}

function get_cpython_version {
    local cpython_version=""
    case "$1" in
    "3.7")
        python_version="cp37-cp37m"
        ;;
    "3.8")
        python_version="cp38-cp38"
        ;;
    "3.9")
        python_version="cp39-cp39"
        ;;
    "3.10")
        python_version="cp310-cp310"
        ;;
    "3.11")
        python_version="cp311-cp311"
        ;;
    "3.12")
        python_version="cp312-cp312"
        ;;
    "3.13")
        python_version="cp313-cp313"
        ;;
    esac

    echo "$python_version"
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
    "cp313-cp313")
        python_version="3.13"
        ;;
    esac

    echo "$python_version"
}

function repair_wheel {
    default_python="$1"
    wheel="$2"
    if ! auditwheel show "$wheel"; then
        echo "Skipping non-platform wheel $wheel"
    else
        $default_python $AUDITWHEEL repair "$wheel" --plat "$WHEEL_PLATFORM" -w $PYTHON_SDK_WHEELHOUSE
    fi
}

function audit_abi3_wheel {
    python_bin="$1"
    default_python="$2"
    wheel="$3"
    echo "Auditing $wheel for abi3 compliance..."
    report="abi3audit_report.json"
    # we expect abi3audit to have a non-zero exit code, so catch it in an if-statement
    if $python_bin/abi3audit --strict --report $wheel >$report; then
        echo 'Finished parsing wheel.'
    else
        echo 'Finished parsing wheel.'
    fi

    if [ -s $report ]; then
        echo 'Parsing audit report...'
        $default_python $CHECK_ABI3AUDIT $report "pycbc"
        #cleanup
        rm "$report"
    else
        echo 'Audit report not created.'
        exit 1
    fi
}

function reduce_linux_wheel_size {

    if [ ! -d "$PYTHON_SDK_DEBUG_WHEELHOUSE" ]; then
        mkdir -p $PYTHON_SDK_DEBUG_WHEELHOUSE
    fi

    default_python="$1"
    cd $PYTHON_SDK_WHEELHOUSE
    if [ "$PROJECT_PREFIX" == "PYCBC" ]; then
        project_root="couchbase"
        lib_path=$project_root
        lib_name="pycbc_core"
    else
        project_root="couchbase_columnar"
        lib_path="$project_root/protocol"
        lib_name="pycbcc_core"
    fi
    for f in *.whl; do
        echo "found wheel=$f"
        if [[ $f == *"manylinux"* || $f == *"musllinux"* ]]; then
            echo "Reducing wheel size of $f"
            wheel_root=$($default_python "$CI_SCRIPTS_PATH/pygha.py" "parse_wheel_name" $f "$project_root")
            $default_python -m wheel unpack $f
            mv $f $PYTHON_SDK_DEBUG_WHEELHOUSE
            echo "checking dir..."
            ls -alh
            cd "$wheel_root/$lib_path"
            cp $lib_name.so $lib_name.orig.so
            objcopy --only-keep-debug $lib_name.so $lib_name.debug.so
            objcopy --strip-debug --strip-unneeded $lib_name.so
            objcopy --add-gnu-debuglink=$lib_name.debug.so $lib_name.so
            echo "grep $lib_name.so sizes"
            ls -alh | grep ${PROJECT_PREFIX,,}
            rm $lib_name.orig.so $lib_name.debug.so
            echo "grep $lib_name.so sizes (should only have reduced size)"
            ls -alh | grep ${PROJECT_PREFIX,,}
            cd ../..
            $default_python -m wheel pack $wheel_root
        else
            echo "Wheel $f is not tagged as manylinux or musllinux, removing."
            rm "$f"
        fi
    done
}

function reduce_macos_wheel_size {
    wheel_name="$1"
    wheel_path="$2"
    wheel_debug_path="$3"
    if [ "$PROJECT_PREFIX" == "PYCBC" ]; then
        project_root="couchbase"
        lib_path=$project_root
        lib_name="pycbc_core"
    else
        project_root="couchbase_columnar"
        lib_path="$project_root/protocol"
        lib_name="pycbcc_core"
    fi
    wheel_root=$(python "$CI_SCRIPTS_PATH/pygha.py" "parse_wheel_name" $wheel_name "$project_root")
    cd $wheel_path
    python -m wheel unpack $wheel_name
    echo "$wheel_path contents:"
    ls -alh
    mv $wheel_name $wheel_debug_path
    echo "Moving to $wheel_root/$lib_path"
    cd "$wheel_root/$lib_path"
    echo "$wheel_root/$lib_path contents:"
    ls -alh
    echo "Copying $lib_name.so to $lib_name.orig.so"
    cp $lib_name.so $lib_name.orig.so
    echo "Stripping $lib_name.so"
    xcrun strip -Sx $lib_name.so
    echo "grep $lib_name output:"
    ls -alh | grep $lib_name
    rm $lib_name.orig.so
    cd $wheel_path
    python -m wheel pack $wheel_root
    echo "$wheel_path contents:"
    ls -alh
}

function setup_linux_build_env {
    python_bin="$1"
    python_version="$2"
    if [ "$PROJECT_PREFIX" == "PYCBC" ]; then
        export PYCBC_PYTHON3_EXECUTABLE="/opt/python/${python_bin}/bin/python${python_version}"
        if [ $python_version == '3.7' ]; then
            export PYCBC_PYTHON3_INCLUDE_DIR="/opt/python/${python_bin}/include/python${python_version}m"
        else
            export PYCBC_PYTHON3_INCLUDE_DIR="/opt/python/${python_bin}/include/python${python_version}"
        fi
    else
        export PYCBCC_PYTHON3_EXECUTABLE="/opt/python/${python_bin}/bin/python${python_version}"
        if [ $python_version == '3.7' ]; then
            export PYCBCC_PYTHON3_INCLUDE_DIR="/opt/python/${python_bin}/include/python${python_version}m"
        else
            export PYCBCC_PYTHON3_INCLUDE_DIR="/opt/python/${python_bin}/include/python${python_version}"
        fi
    fi
}

function build_linux_wheels {
    default_bin=/opt/python/cp39-cp39/bin
    default_python=$default_bin/python
    default_pip=$default_bin/pip
    $default_python -m pip install auditwheel==6.1.0
    if [[ -n "${USE_LIMITED_API-}" ]]; then
        $default_python -m pip install abi3audit
    fi

    # allowed_python_versions=["cp37-cp37m",
    #                          "cp38-cp38",
    #                          "cp39-cp39",
    #                          "cp310-cp310",
    #                          "cp311-cp311",
    #                          "cp312-cp312",
    #                          "cp313-cp313"]
    # 3.7 EOL 2023.06.30, keep in list just in case, but CI pipeline sets CPYTHON_VERSIONS
    # 3.8 EOL 2024.10.07, keep in list just in case, but CI pipeline sets CPYTHON_VERSIONS

    if [ -z "$PYTHON_VERSIONS" ]; then
        echo "PYTHON_VERSIONS is not set."
        exit 1
    fi

    cpython_versions=()
    for version in $PYTHON_VERSIONS; do
        cpython_versions+=$(get_cpython_version "${version}")
    done

    $default_pip list

    parse_build_config "wheel" $default_python

    if [ "$PROJECT_PREFIX" == "PYCBC" ]; then
        if [[ -n "${PYCBC_USE_OPENSSL-}" && "$PYCBC_USE_OPENSSL" = true && -n "${PYCBC_OPENSSL_VERSION-}" ]]; then
            openssl_dir=/usr/local/openssl
            build_openssl "$PYCBC_OPENSSL_VERSION" "$openssl_dir"
            export PYCBC_OPENSSL_DIR=$openssl_dir
        fi
    else
        if [[ -n "${PYCBCC_USE_OPENSSL-}" && "$PYCBCC_USE_OPENSSL" = true && -n "${PYCBCC_OPENSSL_VERSION-}" ]]; then
            openssl_dir=/usr/local/openssl
            build_openssl "$PYCBCC_OPENSSL_VERSION" "$openssl_dir"
            export PYCBC_OPENSSL_DIR=$openssl_dir
        fi
    fi

    # Compile wheels
    for PYBIN in /opt/python/*; do
        python_bin="${PYBIN##*/}"
        if in_allowed_python_versions "${python_bin}" "${cpython_versions[@]}"; then
            python_version=$(get_python_version "${python_bin}")
            setup_linux_build_env "${python_bin}" "${python_version}"
            if [[ -n "${PYCBC_VERBOSE_MAKEFILE-}" || -n "${PYCBCC_VERBOSE_MAKEFILE-}" ]]; then
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
        if [[ -n "${PYCBC_LIMITED_API-}" || -n "${PYCBCC_LIMITED_API-}" ]]; then
            audit_abi3_wheel "$whl"
        fi
        repair_wheel "$default_python" "$whl"
        reduce_linux_wheel_size "$default_python"
    done
}

function build_macos_wheels {
    arch="$1"

    python -m pip install --upgrade pip setuptools wheel

    parse_build_config "wheel"

    wheel_path="$PROJECT_ROOT/wheelhouse/dist"
    wheel_debug_path="$PROJECT_ROOT/wheelhouse/dist_debug"
    if [ ! -d "$wheel_path" ]; then
        mkdir -p "$wheel_path"
    fi
    if [ ! -d "$wheel_debug_path" ]; then
        mkdir "$wheel_debug_path"
    fi

    if [[ -n "${PYCBC_VERBOSE_MAKEFILE-}" || -n "${PYCBCC_VERBOSE_MAKEFILE-}" ]]; then
        python -m pip wheel . --no-deps -w "$wheel_path" -v -v -v
    else
        python -m pip wheel . --no-deps -w "$wheel_path"
    fi
    cd $wheel_path
    wheel_name=$(find . -name '*.whl' | cut -c 3-)
    echo "wheel_name=$wheel_name"
    reduce_macos_wheel_size "$wheel_name" "$wheel_path" "$wheel_debug_path"

    # python -m pip install delocate
    # cd $wheel_path
    # delocate-wheel --require-archs $arch -v $wheel_name
}

function build_analytics_wheel {
    cd $PROJECT_ROOT
    if [ ! -z "${CBCI_USE_UV:-}" ]; then
        uv build
    else
        python -m pip install --upgrade pip setuptools wheel
        python -m pip wheel . --no-deps -w dist
        rm -rf build
        egg_info_dir=$(find . -name '*.egg-info' | cut -c 3-)
        if [ ! -z "${egg_info_dir}" ]; then
            rm -rf $egg_info_dir
        fi
    fi
}

function build_wheels {
    arch="${1:-}"
    echo "PROJECT_ROOT=$PROJECT_ROOT"
    set_project_prefix

    if [ "$PROJECT_PREFIX" == "PYCBAC" ]; then
        build_analytics_wheel
        return
    fi

    if [ -z "${SDIST_NAME-}" ]; then
        echo "SDIST_NAME is not set."
        exit 1
    fi

    extract_sdist "$SDIST_NAME"

    if [[ "$OSTYPE" == "linux-gnu" || "$OSTYPE" == "linux-musl" ]]; then
        build_linux_wheels
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        build_macos_wheels $arch
    else
        echo "Cannot build wheel for unsupported OS: $OSTYPE"
        exit 1
    fi
}

function save_shared_obj {
    set_project_prefix
    wheel_path="$1"
    output_path="$2"
    if [[ "$OSTYPE" != "linux-gnu" ]]; then
        echo "Cannot save shared object on unexpected OS.  Expected linux OS, got: $OSTYPE"
        exit 1
    fi

    if [ "$PROJECT_PREFIX" == "PYCBC" ]; then
        project_root="couchbase"
        lib_path=$project_root
        lib_name="pycbc_core"
    else
        project_root="couchbase_columnar"
        lib_path="$project_root/protocol"
        lib_name="pycbcc_core"
    fi

    full_wheel_path="$PROJECT_ROOT/$wheel_path"
    full_output_path="$PROJECT_ROOT/$output_path"

    cd $full_wheel_path
    wheel_name=$(find . -name '*.whl' | cut -c 3-)

    # if running w/in the manylinux container, we need to set the python executable path
    # this should be only for local testing
    default_python=/opt/python/cp39-cp39/bin/python
    $default_python -m pip install wheel
    wheel_root=$($default_python "$CI_SCRIPTS_PATH/pygha.py" "parse_wheel_name" $wheel_name "$project_root")
    $default_python -m wheel unpack $wheel_name
    # if running outside the manylinux container, we can use the python
    # python -m pip install wheel
    # wheel_root=$(python "$CI_SCRIPTS_PATH/pygha.py" "parse_wheel_name" $wheel_name "$project_root")
    # python -m wheel unpack $wheel_name
    echo "$full_wheel_path contents:"
    ls -alh
    echo "Moving to $wheel_root/$lib_path"
    cd "$wheel_root/$lib_path"
    echo "$wheel_root/$lib_path contents:"
    ls -alh

    if [ ! -d "$full_output_path" ]; then
        mkdir -p "$full_output_path"
    fi

    echo "Copying $lib_name.so to $output_path"
    cp $lib_name.so $full_output_path/$lib_name.so
    echo "Confirming $output_path contents:"
    ls -alh $full_output_path
}

function build_test_config_ini {
    echo "PROJECT_ROOT=$PROJECT_ROOT"
    set_project_prefix
    test_path="$PROJECT_ROOT/$1"

    exit_code=0
    output_msg=$(python "$CI_SCRIPTS_PATH/pygha.py" "build_test_ini" "$test_path") || exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "output_msg=$output_msg"
        echo "Failed to build test_config.ini."
        exit 1
    fi
}

function build_test_setup {
    arch="${1:-}"
    echo "PROJECT_ROOT=$PROJECT_ROOT"
    set_project_prefix
    test_path=$PROJECT_ROOT

    if [ "$PROJECT_PREFIX" == "PYCBC" ]; then
        mkdir pycbc_test
        mkdir -p pycbc_test/acb/tests
        mkdir -p pycbc_test/cb/tests
        mkdir -p pycbc_test/txcb/tests
        mkdir -p pycbc_test/tests
        cp -r acouchbase/tests/*.py pycbc_test/acb/tests
        cp -r couchbase/tests/*.py pycbc_test/cb/tests
        cp -r txcouchbase/tests/*.py pycbc_test/txcb/tests
        cp -r tests/** pycbc_test/tests
        touch pycbc_test/acb/__init__.py
        touch pycbc_test/cb/__init__.py
        touch pycbc_test/txcb/__init__.py
        # TODO:  need to test, as couchbase is a subset of acouchbase and txcouchbase
        sed "s/couchbase\/tests/cb\/tests/g; s/== 'couchbase'/== 'cb'/; s/== 'acouchbase'/== 'acb'/; s/== 'txcouchbase'/== 'txcb'/;" conftest.py > pycbc_test/conftest.py
        test_path="${test_path}/pycbc_test"
    elif [ "$PROJECT_PREFIX" == "PYCBCC" ]; then
        mkdir pycbcc_test
        mkdir -p pycbcc_test/acb/tests
        mkdir -p pycbcc_test/cb/tests
        mkdir -p pycbcc_test/tests
        cp -r acouchbase_columnar/tests/*.py pycbcc_test/acb/tests
        cp -r couchbase_columnar/tests/*.py pycbcc_test/cb/tests
        cp -r tests/** pycbcc_test/tests
        touch pycbcc_test/acb/__init__.py
        touch pycbcc_test/cb/__init__.py
        sed "s/couchbase_columnar\/tests/cb\/tests/g; s/== 'couchbase_columnar'/== 'cb'/; s/== 'acouchbase_columnar'/== 'acb'/;" conftest.py > pycbcc_test/conftest.py
        test_path="${test_path}/pycbcc_test"
    elif [ "$PROJECT_PREFIX" == "PYCBAC" ]; then
        mkdir pycbac_test
        mkdir -p pycbac_test/acb/tests
        mkdir -p pycbac_test/cb/tests
        mkdir -p pycbac_test/tests
        cp -r acouchbase_analytics/tests/*.py pycbac_test/acb/tests
        cp -r couchbase_analytics/tests/*.py pycbac_test/cb/tests
        cp -r tests/** pycbac_test/tests
        touch pycbac_test/acb/__init__.py
        touch pycbac_test/cb/__init__.py
        sed "s/couchbase_analytics\/tests/cb\/tests/g; s/== 'couchbase_analytics'/== 'cb'/; s/== 'acouchbase_analytics'/== 'acb'/;" conftest.py > pycbac_test/conftest.py
        test_path="${test_path}/pycbac_test"
    else
        echo "Invalid project prefix: $PROJECT_PREFIX"
        exit 1
    fi

    exit_code=0
    output_msg=$(python "$CI_SCRIPTS_PATH/pygha.py" "build_test_ini" "$test_path/tests") || exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "output_msg=$output_msg"
        echo "Failed to build test_config.ini."
        exit 1
    fi
    # we need to parse the pyproject.toml to create the pytest.ini file
    python -m pip install tomli
    output_msg=$(python "$CI_SCRIPTS_PATH/pygha.py" "build_pytest_ini" "${PROJECT_ROOT}/pyproject.toml" "$test_path") || exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "output_msg=$output_msg"
        echo "Failed to build pytest.ini."
        exit 1
    fi
    python -m pip uninstall tomli -y

    output_msg=$(python "$CI_SCRIPTS_PATH/pygha.py" "build_dev_requirements" "$test_path") || exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "output_msg=$output_msg"
        echo "Failed to build dev requirements."
        exit 1
    fi

    output_msg=$(python "$CI_SCRIPTS_PATH/pygha.py" "build_cbdino_config_yaml" "$test_path") || exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "output_msg=$output_msg"
        echo "Failed to build cbdino cluster config yaml."
        exit 1
    fi
    
}

function build_publish_config {
    exit_code=0
    publish_config=$(python "$CI_SCRIPTS_PATH/pygha.py" "build_publish_config" "CBCI_CONFIG" "CBCI_VERSION") || exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "publish_config=$publish_config"
        echo "Failed to build publish config."
        exit 1
    fi
    echo "$publish_config"
}

cmd="${1:-empty}"

if [ "$cmd" == "display_info" ]; then
    display_info
elif [ "$cmd" == "validate_input" ]; then
    validate_input "${@:2}"
elif [ "$cmd" == "lint" ]; then
    setup_and_execute_linting
elif [ "$cmd" == "sdist" ]; then
    build_sdist
elif [ "$cmd" == "get_sdist_name" ]; then
    get_sdist_name
elif [ "$cmd" == "get_stage_matrices" ]; then
    get_stage_matrices
elif [ "$cmd" == "wheel" ]; then
    build_wheels "${@:2}"
elif [ "$cmd" == "save_shared_obj" ]; then
    save_shared_obj "${@:2}"
elif [ "$cmd" == "build_test_setup" ]; then
    build_test_setup
elif [ "$cmd" == "build_test_config_ini" ]; then
    build_test_config_ini "${@:2}"
elif [ "$cmd" == "build_publish_config" ]; then
    build_publish_config
else
    echo "Invalid command: $cmd"
fi
