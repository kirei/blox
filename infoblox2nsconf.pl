#!/usr/bin/perl
#
# Copyright (c) 2012 Kirei AB. All rights reserved.
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
use Infoblox;    # fetched from
                 # https://appliance/api/dist/CPAN/authors/id/INFOBLOX/
use YAML 'LoadFile';

my $cfdata      = undef;    # Global configuration data
my $session     = undef;    # Session handle
my $opt_verbose = 0;

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

    unless ($session) {
        $session = Infoblox::Session->new(
            master   => $cfdata->{infoblox}->{master},
            username => $cfdata->{infoblox}->{username},
            password => $cfdata->{infoblox}->{password}
        ) || die "Failed to establish session with Infoblox";
    }

    unless ($session->status_code == 0) {
        die $session->status_detail();
    }

    # Use "default" view unless defined
    if (!defined($cfdata->{infoblox}->{view})) {
        $cfdata->{infoblox}->{view} = "default";
    }

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

    ## Find zones served by my name server groups
    my @zones = find_zones($hostname);

    open(CONFIG, ">:encoding(utf8)", $config)
      || die "Failed to open output: $config";
    select(CONFIG);

    foreach my $z (@zones) {
        print_config_zone($z, $nsconf);
    }
    select(STDOUT);

    close(CONFIG);
}

# find all NS groups containing a specific host
sub find_nsgroups ($) {
    my $hostname = shift;

    print_debug("Finding NS groups for $hostname");

    my %result = ();
    my @nsgroups = $session->search(object => "Infoblox::Grid::DNS::Nsgroup");

    foreach my $nsg (@nsgroups) {
        if (is_secondary($hostname, $nsg->secondaries)) {
            $result{ $nsg->name } = 1;
        }
    }

    return keys(%result);
}

# find all zones served by a specific host
sub find_zones ($) {
    my $hostname = shift;

    # find NS groups
    my @nsgroups = find_nsgroups($hostname);

    print_debug("Extrating zones for $hostname");

    my @result = ();

    my @zones = $session->search(
        object => "Infoblox::DNS::Zone",
        name   => ".*",
        view   => $cfdata->{infoblox}->{view},
    );

    foreach my $z (@zones) {
        if (is_nameserver($hostname, $z, \@nsgroups)) {
            push @result, $z;
        }
    }

    return @result;
}

# check if hostname is in list of secondaries
sub is_secondary ($$) {
    my $hostname    = shift;    # hostname to check
    my $secondaries = shift;    # reference to array of secondaries

    foreach my $member (@{$secondaries}) {
        return 1 if ($member->name eq $hostname);
    }

    return 0;
}

# check if hostname serves a specific zone
sub is_nameserver ($$$) {
    my $hostname = shift;       # hostname
    my $zone     = shift;       # reference to zone object to check
    my $nsgroups = shift;       # reference to array of NS groups

    my $zname = $zone->dns_name;

    if (defined $zone->ns_group) {
        foreach my $g (@{$nsgroups}) {
            if ($zone->ns_group eq $g) {
                print_debug(
                    sprintf("Include %s - is in one of our NS groups", $zname));
                return 1;
            }
        }
        print_debug(
            sprintf("Exclude %s - is not in one of our NS groups", $zname));
        return 0;
    }

    if (is_secondary($hostname, $zone->secondaries)) {
        print_debug(
            sprintf("Include %s - we are explicitly listed as NS", $zname));
        return 1;
    }

    print_debug(sprintf("Exclude %s - we are not NS", $zname));
    return 0;
}

# Convert zone name to filename
#
sub zonename2filename ($) {
    my $name = shift;

    $name =~ s/\//_/;    # avoid slash in file names

    return $name;
}

# Print zone configuration sniplet
#
sub print_config_zone ($) {
    my $zone   = shift;
    my $nsconf = shift;

    my $dname = $zone->name;
    my $zname = $zone->dns_name;

    my $filename = sprintf("%s/%s", $nsconf->{path}, zonename2filename($zname));
    my @masters = ();

    push @masters, $nsconf->{master};
    my $tsig = $nsconf->{tsig};

    print_info(sprintf("%s (%s)", $dname, $zname));

    if ($nsconf->{format} eq "bind") {

        printf("# %s\n",          $dname);
        printf("zone \"%s\" {\n", $zname);
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
        printf("# %s\n", $dname);
        printf("zone:\n");

        printf("\tname: \"%s\"\n",     $zname);
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
