#!/usr/bin/perl
#
# Copyright (c) 2012-2013 Kirei AB. All rights reserved.
#
# Principal author: Jakob Schlyter <jakob@kirei.se>
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
# IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
# DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
# GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER
# IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
# OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN
# IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
######################################################################

require 5.6.0;

use utf8;
use warnings;
use strict;
use Data::Dumper;
use Pod::Usage;
use Getopt::Long;
use WWW::Curl::Easy;
use Net::IP;
use JSON;
use YAML 'LoadFile';

my $cfdata      = undef;    # Global configuration data
my $session     = undef;    # Session handle
my $opt_verbose = 0;

my $wapi_version = "v1.2.1";

my $curl = undef;
my $view = undef;

sub main {
    my $opt_help   = undef;
    my $opt_config = "infoblox2nsconf.yaml";

    Getopt::Long::Configure("bundling");
    GetOptions(
        'help|h|?'   => \$opt_help,
        'verbose|v+' => \$opt_verbose,
    ) or pod2usage(2);
    pod2usage(1) if ($opt_help);
    pod2usage(2) if ($#ARGV > 0);

    if ($#ARGV >= 0) {
        $opt_config = shift @ARGV;
    }

    $cfdata = LoadFile($opt_config);

    # Use port 443 unless defined
    if (!defined($cfdata->{infoblox}->{port})) {
        $cfdata->{infoblox}->{port} = 443;
    }

    # Use "default" view unless defined
    if (!defined($cfdata->{infoblox}->{view})) {
        $cfdata->{infoblox}->{view} = "default";
    }

    # initialize WAPI configuration
    wapi_init();

    # support both a single and multiple nameservers
    if ($cfdata->{nameservers}) {
        for my $ns (sort keys %{ $cfdata->{nameservers} }) {
            process_nameserver($cfdata->{nameservers}->{$ns});
        }
    } else {
        process_nameserver($cfdata->{nameserver});
    }
}

# process single nameserver
sub process_nameserver ($) {
    my $nsconf = shift;

    my $hostname = $nsconf->{hostname};
    my $config   = $nsconf->{config};

    print_info("# exporting data for $hostname");

    ## Find zones served by nameserver
    my @zones = find_zones($nsconf);

    open(CONFIG, ">:encoding(utf8)", $config)
      || die "Failed to open output: $config";
    select(CONFIG);

    foreach my $z (@zones) {
        print_config_zone($z, $nsconf);
    }
    select(STDOUT);

    close(CONFIG);
}

# find all zones served by a specific host
sub find_zones ($) {
    my $nsconf = shift;

    my $hostname = $nsconf->{hostname};

    print_debug("Extracting zones for $hostname");

    my @fields = (
        "dns_fqdn",           "disable",
        "zone_format",        "ns_group",
        "external_primaries", "external_secondaries"
    );
    my $json = wapi_get("zone_auth",
        "view=default&_return_fields=" . join(",", @fields));

    my $infoblox_zones = decode_json($json);

    my @results = ();

    foreach my $z (@{$infoblox_zones}) {

        my %zone = ();

        # skip disabled zones
        next if ($z->{disable} eq JSON::true);

        # skip non-FORWARD/IPv4/IPv6 zones
        next
          unless ($z->{zone_format} eq "FORWARD"
            or $z->{zone_format} eq "IPV4"
            or $z->{zone_format} eq "IPV6");

        $zone{name} = $z->{dns_fqdn};
        $zone{type} = $z->{zone_format};

        push @results, \%zone
          if (is_nameserver($z, $nsconf));
    }

    return @results;
}

# check if hostname serves a specific zone
sub is_nameserver ($$) {
    my $zone   = shift;    # reference to IPAM zone data
    my $nsconf = shift;    # reference to nameserver configuration

    my $hostname = $nsconf->{hostname};
    my $zname    = $zone->{dns_fqdn};

    my @ns_groups = ();
    push @ns_groups, $nsconf->{group}       if ($nsconf->{group});
    push @ns_groups, @{ $nsconf->{groups} } if ($nsconf->{groups});

    # include zone if it has a listed nameserver group
    if ($zone->{ns_group}) {
        for my $group (@ns_groups) {
            if ($zone->{ns_group} eq $group) {
                print_debug(
                    sprintf("Include %s - is in one of our NS groups", $zname));
                return 1;
            }

        }
    }

    # include zone if nameserver is listed as external primary
    for my $ext (@{ $zone->{external_primaries} }) {
        if ($ext->{stealth} eq JSON::true) {
            print_debug(sprintf("Exclude %s - is stealth primary", $zname));
            return 0;

        }
        if ($ext->{name} eq $hostname) {
            print_debug(sprintf("Include %s - is external primary", $zname));
            return 1;
        }
    }

    # include zone if nameserver is listed as external secondary
    for my $ext (@{ $zone->{external_secondaries} }) {
        if ($ext->{stealth} eq JSON::true) {
            print_debug(sprintf("Exclude %s - is stealth secondary", $zname));
            return 0;

        }
        if ($ext->{name} eq $hostname) {
            print_debug(sprintf("Include %s - is external secondary", $zname));
            return 1;
        }
    }

    print_debug(sprintf("Exclude %s - we are not NS", $zname));
    return 0;
}

# Convert FQDN to filename
#
sub name2fqdn ($$) {
    my $name = shift;
    my $type = shift;

    if ($type eq "FORWARD") {
        return $name;
    }
    if ($type eq "IPV4" or $type eq "IPV6") {
        my $ip   = new Net::IP($name);
        my $fqdn = $ip->reverse_ip();
        $fqdn =~ s/\.$//;
        return $fqdn;
    }

    return undef;
}

# Convert FQDN to filename
#
sub fqdn2filename ($) {
    my $filename = shift;

    $filename =~ s/\//_/;    # avoid slash in file names

    return $filename;
}

# Print zone configuration sniplet
#
sub print_config_zone ($) {
    my $zone   = shift;
    my $nsconf = shift;

    my $name = $zone->{name};
    my $fqdn = name2fqdn($zone->{name}, $zone->{type});

    my $filename =
      sprintf("%s/%s", $nsconf->{path}, fqdn2filename($fqdn));
    my @masters = ();

    push @masters, $nsconf->{master};
    my $tsig = $nsconf->{tsig};

    print_info(sprintf("- %s (%s)", $name, $fqdn));

    if ($nsconf->{format} eq "bind") {

        printf("# %s\n",          $name);
        printf("zone \"%s\" {\n", $fqdn);
        printf("\ttype slave;\n");
        printf("\tfile \"%s\";\n", $filename);

        my @mdef = ();
        foreach my $m (@masters) {
            push @mdef, sprintf("%s key %s", $m, $tsig);
        }
        printf("\tmasters { %s; };\n", join(";", @mdef));

        printf("};\n");
        printf("\n");

        return;
    }

    if ($nsconf->{format} eq "nsd") {
        printf("# %s\n", $name);
        printf("zone:\n");

        printf("\tname: \"%s\"\n",     $fqdn);
        printf("\tzonefile: \"%s\"\n", $filename);

        foreach my $m (@masters) {
            printf("\tallow-notify: %s %s\n", $m, $tsig);
        }
        foreach my $m (@masters) {
            printf("\trequest-xfr: %s %s\n", $m, $tsig);
        }

        printf("\n");

        return;
    }

    die "Unknown configuration format";
}

sub wapi_init {
    $curl = WWW::Curl::Easy->new;

    $curl->setopt(CURLOPT_HEADER,         0);
    $curl->setopt(CURLOPT_VERBOSE,        0);
    $curl->setopt(CURLOPT_SSL_VERIFYPEER, 0);
    $curl->setopt(
        CURLOPT_USERPWD,
        join(":",
            $cfdata->{infoblox}->{username},
            $cfdata->{infoblox}->{password})
    );
}

sub wapi_get ($) {
    my $command = shift;
    my $params  = shift;

    my $base = sprintf(
        "https://%s:%d/wapi/%s",
        $cfdata->{infoblox}->{host},
        $cfdata->{infoblox}->{port},
        $wapi_version
    );
    my $url =
      sprintf("%s/%s?%s&_return_type=json-pretty", $base, $command, $params);

    $curl->setopt(CURLOPT_URL, $url);

    my $response_body;
    $curl->setopt(CURLOPT_WRITEDATA, \$response_body);
    my $retcode = $curl->perform;

    if ($retcode == 0) {
        return $response_body;
    } else {

        print(  "An error happened: $retcode "
              . $curl->strerror($retcode) . " "
              . $curl->errbuf
              . "\n");
        return undef;
    }
}

# print informational messages
sub print_info ($) {
    my $message = shift;
    printf STDERR ("%s\n", $message) if ($opt_verbose);
}

# print debug messages
sub print_debug ($) {
    my $message = shift;
    printf STDERR ("DEBUG: %s\n", $message) if ($opt_verbose > 1);
}

main();

__END__

=head1 NAME

infoblox2nsconf.pl - Infoblox to NS Configuration Converter

=head1 SYNOPSIS

infoblox2nsconf.pl [options] [infoblox2nsconf.yaml]

Options:

 --help           brief help message
 --verbose        enable verbose output (may be used multiple times)
