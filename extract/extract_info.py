#!/usr/bin/python3

import sys
import yaml

with open(sys.argv[2], "r") as f:
    data = yaml.load(f)

print(data[sys.argv[1]])
