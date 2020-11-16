# A Perl package to interact with DRBD (>=9) resources
# Copyright (C) LINBIT HA-Solutions GmbH
# All Rights Reserved.
# Author: Roland Kammerer <roland.kammerer@linbit.com>
#
# Licensed under the Apache License, Version 2.0 (the "License"); you may
# not use this file except in compliance with the License. You may obtain
# a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
# WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
# License for the specific language governing permissions and limitations
# under the License.

package LINBIT::DRBD::Node;

use strict;
use warnings;

sub new {
	my ($class, $name, $id) = @_;

	# has to match 'uname -n'
	my $self = bless { name => $name, id => $id, address_type => "ipv4" }, $class;
}

sub set_address {
    my ( $self, $address ) = @_;

	 $self->{address} = $address;

	 return $self;
}

sub set_port {
    my ( $self, $port ) = @_;

	 $self->{port} = $port;

	 return $self;
}

sub set_address_type {
    my ( $self, $address_type ) = @_;

	 $self->{address_type} = $address_type;

	 return $self;
}

sub add_volume {
    my ( $self, $volume ) = @_;

	 push(@{$self->{volumes}}, $volume);

	 return $self;
}

1;
__END__

=head1 NAME

LINBIT::DRBD::Node - DRBD9 node related methods

=head1 SYNOPSIS

	use LINBIT::DRBD::Node;

Methods return the object itself, which allows for:

	my $node = LINBIT::DRBD::Node->new('foo', 0)
	->set_address('1.2.3.4')
	->set_port(7000);

=head1 VERSION

0.0.0

=head1 METHODS

=head2 new()

	my $node = LINBIT::DRBD::Node->new('hostname', $id);

Create a new node object with the given host name (has to match C<uname -n>) and a given DRBD node ID.

=head2 add_volume()

	$node->add_volume($volume);

Add a DRBD volume (see C<LINBIT::DRBD::Volume>) to a node. Usually one wants to add a volume to a C<LINBIT::DRBD::Resource> object.

=head2 set_address()

	$node->set_address('1.2.3.4');

Set the address as defined by C<drbd.conf(5)>

=head2 set_port()

	$node->set_port(7000);

Set the port that is used for the DRBD resource on this node.

=head2 set_address_type()

	$node->set_address_type('ipv4');

Set the address type. This can be 'ipv4' (default) or 'ipv6'.