set SDKDCLIENT-NG=%WORKSPACE%\sdkdclient-ng
set COUCHBASE-NET-CLIENT=%WORKSPACE%\couchbase-net-client
set SDKD-NET=%WORKSPACE%\sdkd-net
set JAVA_HOME=C:\Progra~1\Java\jdk1.8.0_101


echo ===============================================================STEP1 workspace cleanUP
mkdir %WORKSPACE%
rd /q/s %SDKDCLIENT-NG% 2>nul
rd /q/s %COUCHBASE-NET-CLIENT% 2>nul
rd /q/s %SDKD-NET% 2>nul

TASKKILL /F /IM SdkdConsole.exe /T
rd /q/s %WORKSPACE%\log 2>nul
del /q/s C:\temp\sdkd-out-debug\*
del /q/s C:\temp\*.log
del /q/s c:\temp\*.txt
del %WORKSPACE%\log.txt
del %WORKSPACE%\report.xls

cd %WORKSPACE%
:::git clone -b %SDKD_CLIENT_BRANCH% git@github.com:couchbase/sdkd-net
echo Cloning SDKD-NET using branch %SDKD_CLIENT_BRANCH%
git clone http://Oferya:oferhub11@github.com/couchbase/sdkd-net --single-branch --branch %SDKD_CLIENT_BRANCH%

echo ===============================================================STEP3 build sdkdclient-ng
cd %WORKSPACE%
:::git clone git@github.com:couchbaselabs/sdkdclient-ng
echo Cloning sdkclient-ng using branch %SDKDCLIENT_NG_BRANCH%
git clone http://Oferya:oferhub11@github.com/couchbaselabs/sdkdclient-ng --single-branch --branch %SDKDCLIENT_NG_BRANCH%

cd %SDKDCLIENT-NG%
:::git checkout %SDKDCLIENT_NG_BRANCH%


echo [cluster]> cluster_config.ini
echo node=%NODE1%:::kv >> cluster_config.ini
echo node=%NODE2%:::kv,n1ql,index,fts >> cluster_config.ini
echo node=%NODE3%:::kv,n1ql,index,fts >> cluster_config.ini
echo node=%NODE4%:::kv,n1ql,index,fts >> cluster_config.ini


echo ssh-username=root >> cluster_config.ini
echo ssh-password=couchbase >> cluster_config.ini
echo setStorageMode = true >> cluster_config.ini

echo [cluster]> n1ql.ini
echo node=%NODE1%:::kv >> n1ql.ini
echo node=%NODE2%:::index >> n1ql.ini
echo node=%NODE3%:::n1ql >> n1ql.ini
echo node=%NODE4%:::n1ql >> n1ql.ini
echo ssh-username=root >> n1ql.ini
echo ssh-password=couchbase >> n1ql.ini
echo setStorageMode = true >> n1ql.ini


call mvn clean
call mvn package -Pzip -Dmaven.test.skip=true
cd packages
"C:\Program Files\Java\jdk1.8.0_101\bin\jar.exe" xf sdkdclient-*.zip

copy C:\jenkins\workspace\S3Creds_tmp %SDKDCLIENT-NG%

echo ===============================================================STEP4 build couchbase-net-client
cd %WORKSPACE%
rd /q/s %COUCHBASE-NET-CLIENT% 2>nul

echo Cloning Couchbase .NET Client
git clone http://github.com/couchbase/couchbase-net-client.git --no-checkout
cd %COUCHBASE-NET-CLIENT%

if %GERRIT_COMMIT% neq 0 (
    echo Using Gerrit change set %GERRIT_COMMIT%
    git fetch http://review.couchbase.org/couchbase-net-client refs/changes/%GERRIT_COMMIT% && git checkout FETCH_HEAD
) else (
    echo Checking out branch %NET_CLIENT_BRANCH%
    git checkout %NET_CLIENT_BRANCH%

    if %NET_CLIENT_SHA% neq 0 (
        echo Applying SHA %NET_CLIENT_SHA%
        git checkout %NET_CLIENT_SHA%
    )
)

git rev-parse --short HEAD > client_commit.txt
set /p CLIENT_COMMIT=<client_commit.txt
echo CLIENT_COMMIT=%CLIENT_COMMIT%

git log -n 2
cd %COUCHBASE-NET-CLIENT%\src
dotnet restore .\Couchbase\Couchbase.csproj && dotnet build .\Couchbase\Couchbase.csproj

echo ===============================================================STEP5 build sdkd-net

cd %SDKD-NET%
git checkout %SDKD_CLIENT_BRANCH%
git log -n 2
copy pylib\s3upload.py c:\pylib\s3upload.py
del C:\temp\log.txt
cd %SDKD-NET%\src
dotnet restore .\Sdkd\Sdkd.csproj && dotnet build .\Sdkd\Sdkd.csproj
dotnet restore .\SdkdConsole\SdkdConsole.csproj && dotnet build .\SdkdConsole\SdkdConsole.csproj
dotnet restore .\Sdkd.Netstandard\Sdkd.Netstandard.csproj && dotnet build .\Sdkd.Netstandard\Sdkd.Netstandard.csproj
dotnet restore .\SdkdConsole.Netstandard\SdkdConsole.Netstandard.csproj && dotnet build .\SdkdConsole.Netstandard\SdkdConsole.Netstandard.csproj
dotnet publish .\SdkdConsole.Netstandard\SdkdConsole.Netstandard.csproj && dotnet build .\SdkdConsole.Netstandard\SdkdConsole.Netstandard.csproj

echo ===============================================================brun

cd %SDKDCLIENT-NG%


echo -C 'share\rexec' --rexec_path '%SDKD-NET%\src\SdkdConsole\bin\Debug\SdkdConsole.exe' --rexec_port 8050 --rexec-args -s true > sdkd-sync.args

::memcached bucket
call packages\sdkdclient\bin\brun.bat --testsuite-test="Rb1Swap" --bucket-type="memcached" --rebound 240 -A S3Creds_tmp -I cluster_config.ini -I sdkd-sync.args --bucket-password="password" --testsuite-variants "MEMD" -d all:debug --install-skip false --install-version %cluster_version% --install-url %url% --cluster-useSSL=%useSSL%
call packages\sdkdclient\bin\brun.bat --testsuite-test="passthrough" --bucket-type="memcached" --rebound 240 -A S3Creds_tmp -I cluster_config.ini -I sdkd-sync.args --bucket-password="password" --testsuite-variants "MEMD" -d all:debug --install-skip false --install-version %cluster_version% --install-url %url% --cluster-useSSL=%useSSL%

::couchbase bucket
call packages\sdkdclient\bin\brun.bat --rebound %rebound% -A S3Creds_tmp -I cluster_config.ini -I sdkd-sync.args --bucket-password="password" --testsuite-variants "HYBRID" -d all:debug --install-skip false --install-version %cluster_version% --install-url %url% --cluster-useSSL=%useSSL%
call packages\sdkdclient\bin\brun.bat --rebound %rebound% -I n1ql.ini -I sdkd-sync.args --bucket-password="password" --testsuite-variants "N1QL" -A S3Creds_tmp --testsuite-suite "suites/N1QL.json"  -d all:trace --n1ql-index-engine gsi --n1ql-index-type secondary --n1ql-scan-consistency=request_plus --n1ql-preload true --n1ql-prepared=true  -d all:debug --cluster-useSSL=%useSSL%
call packages\sdkdclient\bin\brun.bat -A S3Creds_tmp -I cluster_config.ini -I sdkd-sync.args --bucket-password="password" --testsuite-variants "SUBDOC" -d all:debug --rebound %rebound% --cluster-useSSL=%useSSL%

call packages\sdkdclient\bin\report.bat
copy %SDKDCLIENT-NG%\report.xls %WORKSPACE%\report-sync.xls


if %errorlevel% neq 0 echo "ALARM, SDKD tests exit with error!"
