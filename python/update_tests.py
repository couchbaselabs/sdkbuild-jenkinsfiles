try:
    from configparser import ConfigParser
except:
    from ConfigParser import ConfigParser

import os
import sys

fp = open("tests.ini.sample", "r")
template = ConfigParser()
template.readfp(fp)
is_realserver = (len(sys.argv) > 1)
template.set("realserver", "enabled", str(is_realserver))
template.set("mock", "enabled", str(not is_realserver))
if is_realserver:
    template.set("realserver", "host", sys.argv[1])
template.set("realserver", "admin_username", "Administrator")
template.set("realserver", "admin_password", "password")
template.set("realserver", "bucket_password", "password")
with open("tests.ini", "w") as fp:
    template.write(fp)
    print("Wrote to file")
print("Done writing")
with open("tests.ini", "r") as fp:
    print("Wrote {}".format(fp.read()))
