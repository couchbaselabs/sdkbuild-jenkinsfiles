# MINIFIER=sed -E 's/^\s+//g'
MINIFIER=cat

Jenkinsfile: Jenkinsfile.erb
	erb -P  $< | ${MINIFIER} > $@
