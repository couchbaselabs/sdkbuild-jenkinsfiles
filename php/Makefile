# MINIFIER=sed -E 's/^\s+//g'
MINIFIER=cat

all: Jenkinsfile

Jenkinsfile: Jenkinsfile.erb
	erb -T 2 -P  $< | ${MINIFIER} > $@
