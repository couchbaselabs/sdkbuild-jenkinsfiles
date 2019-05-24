command=test.cmd

rm -rf sdkqe-resource
PKG=NULL
URL=NULL
APP_TARGET=netcoreapp2.0
PUBLISH_DIR=/root/sdkd-net/src/SdkdConsole.NetStandard/bin/Debug/${APP_TARGET}/publish
EXECUTABLE=${PUBLISH_DIR}/run-sdkd-dotnet-async

IFS='-' read -a arr <<< "${cluster_version}"
ver=${arr[0]}
build=${arr[1]}

[[ -z ${build} ]] && build=NULL && PKG=$pkg && URL=$url


if [[ $cluster_version =~ ^([0-9]+)\.([0-9]+) ]]
then
    major=${BASH_REMATCH[1]}
    minor=${BASH_REMATCH[2]}
fi

if (($major>=5)); then
	pwstring=--bucket-password=password
else
	pwstring=--bucket-password=""
fi



###git clone git@github.com:couchbaselabs/sdkqe-resource
git clone http://Oferya:oferhub11@github.com/couchbaselabs/sdkqe-resource

cp sdkqe-resource/utils/ipv4-test.sh .

cat > ${command} << EOF
#memcached bucket
-I docker-basic.ini $pwstring --install-skip true --rebound $rebound --testsuite-variants=MEMD --bucket-type=memcached -A S3Creds_tmp -d all:debug -C share/rexec  --rexec_path=${EXECUTABLE} --rexec-port 8050
#couchbase bucket
-I docker-ssl.ini  $pwstring --install-skip true --rebound $rebound --testsuite-variants=HYBRID -A S3Creds_tmp -d all:debug -C share/rexec  --rexec_path=${EXECUTABLE} --rexec-port 8050
-I docker-ssl.ini  $pwstring --install-skip true --rebound $rebound --testsuite-variants=SPATIAL -A S3Creds_tmp -d all:debug -C share/rexec  --rexec_path=${EXECUTABLE} --rexec-port 8050
-I docker-n1ql.ini $pwstring --install-skip true --rebound $rebound --testsuite-variants=N1QL --testsuite-suite suites/N1QL.json  --cluster-useSSL=true --n1ql-index-engine gsi --n1ql-index-type secondary --n1ql-scan-consistency=not_bounded --n1ql-preload true --n1ql-prepared=true -A S3Creds_tmp -d all:debug -C share/rexec --rexec_path=${EXECUTABLE} --rexec-port 8050
-I docker-n1ql.ini $pwstring --install-skip true --rebound $rebound --testsuite-variants=N1QLHYBRID --testsuite-suite suites/N1QL.json  --cluster-useSSL=true --n1ql-index-engine gsi --n1ql-index-type secondary --n1ql-scan-consistency=not_bounded --n1ql-preload true --n1ql-prepared=true -A S3Creds_tmp -d all:debug -C share/rexec  --rexec_path=${EXECUTABLE} --rexec-port 8050
-I docker-ssl.ini  $pwstring --install-skip true --rebound $rebound --testsuite-variants=SUBDOC -A S3Creds_tmp -d all:debug -C share/rexec  --rexec_path=${EXECUTABLE} --rexec-port 8050
EOF


./ipv4-test.sh -k net -a ubuntu -l 14.04 -v ${ver} -b ${build} -p ${pkg} -u ${url} -c ${sdkdclient} -d ${sdkd} -m ${client_version} -i 3 -n ${command}
