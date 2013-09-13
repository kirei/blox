# Miscellaneous Infoblox Utilities

This repository contains utilities for integrating Infoblox Trinzic DDI
applicances with other systems.

Code found here should be considered work-in-progress and may not work as you
expect, and you should always test carefully before any production use.

N.B.: If it breaks, you get to keep both pieces.

## Programs

- infoblox2nsconf.pl - Build BIND/NSD configuration files based on Infoblox
  configuration.

## infoblox2nsconf

This program creates BIND and/or NSD configuration files for secondary name
servers. The configuration file is in YAML format and may be specified for a
single (**infoblox2nsconf-single.yaml**) or multiple
(**infoblox2nsconf-multiple.yaml**) nameservers in one file.

The resulting configuration file will include all active zones with _hostname_
as non-stealth primary/secondary name server, as well as all zones with any
listed name server group.
