# MINIFIER=sed -E 's/^\s+//g'
MINIFIER=cat

all: Jenkinsfile.win Jenkinsfile.lnx

Jenkinsfile.win: Jenkinsfile.erb
	WINDOWS_ONLY=1 erb -T 2 -P  $< | ${MINIFIER} > $@

Jenkinsfile.lnx: Jenkinsfile.erb
	LINUX_ONLY=1 erb -T 2 -P  $< | ${MINIFIER} > $@
