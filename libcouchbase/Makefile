# MINIFIER=sed -E 's/^\s+//g'
MINIFIER=cat

all: Jenkinsfile Jenkinsfile.win

Jenkinsfile: Jenkinsfile.erb
	erb -P  $< | ${MINIFIER} > $@

Jenkinsfile.win: Jenkinsfile.erb
	WINDOWS_ONLY=1 erb -P  $< | ${MINIFIER} > $@
