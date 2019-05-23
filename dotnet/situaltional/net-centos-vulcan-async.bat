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
::::git clone -b %SDKD_CLIENT_BRANCH% git@github.com/couchbase/sdkd-net
echo Cloning SDKD-NET using branch %SDKD_CLIENT_BRANCH%
git clone http://Oferya:oferhub11@github.com/couchbase/sdkd-net --single-branch --branch %SDKD_CLIENT_BRANCH%
cd %SDKD-NET%

echo ===============================================================STEP3 build sdkdclient-ng
cd %WORKSPACE%
::git clone git@github.com:couchbaselabs/sdkdclient-ng
::cd %SDKDCLIENT-NG%
::git checkout %SDKDCLIENT_NG_BRANCH%
echo Cloning sdkclient-ng using branch %SDKDCLIENT_NG_BRANCH%
git clone http://Oferya:oferhub11@github.com/couchbaselabs/sdkdclient-ng --single-branch --branch %SDKDCLIENT_NG_BRANCH%
cd %SDKDCLIENT-NG%

echo [cluster]> cluster_config.ini
::::echo node=%NODE1%:::kv >> cluster_config.ini
::::echo node=%NODE2%:::kv,n1ql,index,fts >> cluster_config.ini
::::echo node=%NODE3%:::kv,n1ql,index,fts >> cluster_config.ini
::::echo node=%NODE4%:::kv,n1ql,index,fts >> cluster_config.ini
echo node=172.23.120.17:::kv >> cluster_config.ini
echo node=172.23.120.189:::kv,n1ql,index,fts >> cluster_config.ini
echo node=172.23.120.227:::kv,n1ql,index,fts >> cluster_config.ini
echo node=172.23.120.247:::kv,n1ql,index,fts >> cluster_config.ini

echo ssh-username=root >> cluster_config.ini
echo ssh-password=couchbase >> cluster_config.ini
echo setStorageMode = true >> cluster_config.ini

echo [cluster]> n1ql.ini
::::echo node=%NODE1%:::kv >> n1ql.ini
::::echo node=%NODE2%:::index >> n1ql.ini
::::echo node=%NODE3%:::n1ql >> n1ql.ini
::::echo node=%NODE4%:::n1ql >> n1ql.ini
echo node=172.23.120.17:::kv >> n1ql.ini
echo node=172.23.120.189:::index >> n1ql.ini
echo node=172.23.120.227:::n1ql >> n1ql.ini
echo node=172.23.120.247:::n1ql >> n1ql.ini

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

git clone http://github.com/couchbase/couchbase-net-client.git
cd %COUCHBASE-NET-CLIENT%
git checkout %client_version%
echo Cloning Couchbase .NET Client using branch %client_version%
git clone http://Oferya:oferhub11@github.com/couchbase/couchbase-net-client.git --single-branch --branch %client_version%
cd %COUCHBASE-NET-CLIENT%

if %GERRIT_COMMIT% neq 0 git fetch http://jaekwonpark@review.couchbase.org/couchbase-net-client refs/changes/%GERRIT_COMMIT% && git checkout -f FETCH_HEAD

git rev-parse --short HEAD > client_commit.txt
set /p CLIENT_COMMIT=<client_commit.txt
echo CLIENT_COMMIT=%CLIENT_COMMIT%

git log -n 2
cd %COUCHBASE-NET-CLIENT%\src
dotnet restore .\Couchbase\Couchbase.csproj && dotnet build .\Couchbase\Couchbase.csproj

echo ===============================================================STEP5 build sdkd-net

cd %SDKD-NET%
git checkout %SDKD_CLIENT_BRANCH%
cd %WORKSPACE%
echo Cloning SDKD-NET using branch %SDKD_CLIENT_BRANCH%
git clone http://Oferya:oferhub11@github.com/couchbase/sdkd-net --single-branch --branch %SDKD_CLIENT_BRANCH%
cd %SDKD-NET%

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


echo -C 'share\rexec' --rexec_path '%SDKD-NET%\src\SdkdConsole\bin\Debug\SdkdConsole.exe' --rexec_port 8050 > sdkd-async.args


call packages\sdkdclient\bin\brun.bat --rebound %rebound% -A S3Creds_tmp -I cluster_config.ini -I sdkd-async.args --bucket-password="password" --testsuite-variants "HYBRID" --install-url %url% --install-skip false --install-version %cluster_version% --cluster-useSSL=%useSSL% -d all:debug

call packages\sdkdclient\bin\report.bat
copy %SDKDCLIENT-NG%\report.xls %WORKSPACE%\report-async.xls


if %errorlevel% neq 0 echo "ALARM, SDKD tests exit with error!"
