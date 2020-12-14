#!/usr/bin/env perl

use strict;
use warnings;

use JSON::XS qw( decode_json );
use File::Slurp qw( read_file );
use Data::Dumper qw( Dumper );

my $linstor_opts = decode_json(read_file($ARGV[0]));
my %props = %{$linstor_opts->{properties}};
my %opts;

foreach my $key (keys %props) {
	my $section = $props{$key}{drbd_res_file_section};
	my $name = $props{$key}{drbd_option_name};
	$opts{$name} = $section;
}
print Dumper \%opts;
