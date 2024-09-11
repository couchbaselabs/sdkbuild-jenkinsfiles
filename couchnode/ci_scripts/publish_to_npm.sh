#!/bin/bash

set -e -u
current_working_dir=$1
prebuilds_dir=$2

function npm_publish {
    working_dir="$1"
    pushd $working_dir > /dev/null
    if [ "${PUBLISH_DRY_RUN:=true}"  == "true" ]; then
        echo "ls -alh $working_dir"
        ls -alh
        cat package.json
        if [[ -n "${NPM_TAG-}" ]]; then
            echo ""
            echo "npm publish --access public --tag $NPM_TAG --dry-run"
        else
            echo ""
            echo "npm publish --access public --dry-run"
        fi
    else
        if [[ -n "${NPM_TAG-}" ]]; then
            echo "npm publish --access public --tag $NPM_TAG"
        else
            echo "npm publish --access public"
        fi
    fi
    popd > /dev/null
}

echo "publishing prebuilds..."
pushd $prebuilds_dir > /dev/null
for prebuild_dir in *; do
    npm_publish "$prebuild_dir"
done
popd > /dev/null

echo "publishing main package..."
if [ "${PUBLISH_DRY_RUN:=true}"  == "true" ]; then
    echo "ls -alh dist"
    ls -alh dist
    echo "ls -alh src"
    ls -alh src
    echo "ls -alh deps/couchbase-cxx-client"
    ls -alh deps/couchbase-cxx-client
    echo "ls -alh deps/couchbase-cxx-cache"
    ls -alh deps/couchbase-cxx-cache
fi

npm_publish "$current_working_dir"

echo "Things are great!"