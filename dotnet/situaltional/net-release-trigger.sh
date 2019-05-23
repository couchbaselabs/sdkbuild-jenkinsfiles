rm -rf couchbase-net-client
git clone https://github.com/couchbase/couchbase-net-client.git
cd couchbase-net-client

# GERRIT_COMMIT example=14/82314/5
if [ ! -z "$GERRIT_COMMIT" ]
	then
		git fetch http://jaekwonpark@review.couchbase.org/couchbase-net-client refs/changes/${GERRIT_COMMIT} && git checkout FETCH_HEAD
fi

echo CLIENT_COMMIT=$(git rev-parse --short HEAD)


#watson sync
wget "http://sdkbuilds.sc.couchbase.com/view/.NET/job/sdk-net-situational-release/job/net-centos-watson-vs2017/buildWithParameters?token=sdkbuilds&useSSL=$ssl&client_version=$net_commit&GERRIT_COMMIT=$gerrit_commit&SDKDCLIENT_NG_BRANCH=$sdkd_commit"
#watson async
wget "http://sdkbuilds.sc.couchbase.com/view/.NET/job/sdk-net-situational-release/job/net-centos-watson-async-vs2017/buildWithParameters?token=sdkbuilds&useSSL=$ssl&client_version=$net_commit&GERRIT_COMMIT=$gerrit_commit&SDKDCLIENT_NG_BRANCH=$sdkd_commit"

#vulcan sync
wget "http://sdkbuilds.sc.couchbase.com/view/.NET/job/sdk-net-situational-release/job/net-centos-vulcan-vs2017/buildWithParameters?token=sdkbuilds&useSSL=$ssl&client_version=$net_commit&GERRIT_COMMIT=$gerrit_commit&SDKDCLIENT_NG_BRANCH=$sdkd_commit"
#vulcan async
wget "http://sdkbuilds.sc.couchbase.com/view/.NET/job/sdk-net-situational-release/job/net-centos-vulcan-async-vs2017/buildWithParameters?token=sdkbuilds&useSSL=$ssl&client_version=$net_commit&GERRIT_COMMIT=$gerrit_commit&SDKDCLIENT_NG_BRANCH=$sdkd_commit"

#alice sync
wget "http://sdkbuilds.sc.couchbase.com/view/.NET/job/sdk-net-situational-release/job/net-centos-alice-vs2017/buildWithParameters?token=sdkbuilds&useSSL=$ssl&client_version=$net_commit&GERRIT_COMMIT=$gerrit_commit&SDKDCLIENT_NG_BRANCH=$sdkd_commit"
#alice async
wget "http://sdkbuilds.sc.couchbase.com/view/.NET/job/sdk-net-situational-release/job/net-centos-alice-async-vs2017/buildWithParameters?token=sdkbuilds&useSSL=$ssl&client_version=$net_commit&GERRIT_COMMIT=$gerrit_commit&SDKDCLIENT_NG_BRANCH=$sdkd_commit"

#netcore 4.5.1 sync
wget "http://sdkbuilds.sc.couchbase.com/view/.NET/job/sdk-net-situational-release/job/netcore-windows-watson-vs2017/buildWithParameters?token=sdkbuilds&useSSL=$ssl&client_version=$net_commit&GERRIT_COMMIT=$gerrit_commit&SDKDCLIENT_NG_BRANCH=$sdkd_commit"
#netcore 4.5.1 async
wget "http://sdkbuilds.sc.couchbase.com/view/.NET/job/sdk-net-situational-release/job/netcore-windows-watson-async-vs2017/buildWithParameters?token=sdkbuilds&useSSL=$ssl&client_version=$net_commit&GERRIT_COMMIT=$gerrit_commit&SDKDCLIENT_NG_BRANCH=$sdkd_commit"

#netcore 4.5.1 ubuntu sync
wget "http://sdkbuilds.sc.couchbase.com/view/.NET/job/sdk-net-situational-release/job/docker-netcore-ubuntu-watson-vs2017/buildWithParameters?token=sdkbuilds&useSSL=$ssl&client_version=$net_commit&GERRIT_COMMIT=$gerrit_commit&SDKDCLIENT_NG_BRANCH=$sdkd_commit"
#netcore 4.5.1 ubuntu async
wget "http://sdkbuilds.sc.couchbase.com/view/.NET/job/sdk-net-situational-release/job/docker-netcore-ubuntu-watson-async-vs2017/buildWithParameters?token=sdkbuilds&useSSL=$ssl&client_version=$net_commit&GERRIT_COMMIT=$gerrit_commit&SDKDCLIENT_NG_BRANCH=$sdkd_commit"
