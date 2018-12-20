# MINIFIER=sed -E 's/^\s+//g'
MINIFIER=cat

all: Jenkinsfile Jenkinsfile.win Jenkinsfile.lnx

Jenkinsfile: Jenkinsfile.erb
	erb -P  $< | ${MINIFIER} > $@

Jenkinsfile.win: Jenkinsfile.erb
	WINDOWS_ONLY=1 erb -P  $< | ${MINIFIER} > $@

Jenkinsfile.lnx: Jenkinsfile.erb
	LINUX_ONLY=1 erb -P  $< | ${MINIFIER} > $@
