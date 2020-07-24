# MINIFIER=sed -E 's/^\s+//g'
MINIFIER=cat

all: lcb-scripted-build-pipeline.groovy lcb-win-scripted-build-pipeline.groovy lcb-lnx-scripted-build-pipeline.groovy lcb-repo-pipeline.groovy

lcb-scripted-build-pipeline.groovy: Jenkinsfile.erb
	erb -P -T 2  $< | ${MINIFIER} > $@

lcb-win-scripted-build-pipeline.groovy: Jenkinsfile.erb
	WINDOWS_ONLY=1 erb -P -T 2  $< | ${MINIFIER} > $@

lcb-lnx-scripted-build-pipeline.groovy: Jenkinsfile.erb
	LINUX_ONLY=1 erb -P -T 2  $< | ${MINIFIER} > $@

lcb-repo-pipeline.groovy: Jenkinsfile.repo.erb
	erb -P -T 2  $< | ${MINIFIER} > $@
