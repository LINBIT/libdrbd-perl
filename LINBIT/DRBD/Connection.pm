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

package LINBIT::DRBD::Connection;

use strict;
use warnings;

use LINBIT::DRBD::Tools qw( nif_or_default );

sub new {
    my ( $class, $node1, $node2, $node1_nif, $node2_nif ) = @_;
    $node1_nif = nif_or_default($node1_nif);
    $node2_nif = nif_or_default($node2_nif);

    my $self = bless {
        node1     => $node1,
        node1_nif => $node1_nif,
        node2     => $node2,
        node2_nif => $node2_nif,
    }, $class;
}

sub set_nodes {
    my ( $self, $node1, $node2, $node1_nif, $node2_nif ) = @_;
    $node1_nif = nif_or_default($node1_nif);
    $node2_nif = nif_or_default($node2_nif);

    $self->{node1}     = $node1;
    $self->{node1_nif} = $node1_nif;
    $self->{node2}     = $node2;
    $self->{node2_nif} = $node2_nif;

    return $self;
}

sub add_volume {
    my ( $self, $volume ) = @_;

	 push(@{$self->{volumes}}, $volume);

	 return $self;
}

sub get_volume {
    my ( $self, $volume_id ) = @_;

    foreach ( @{ $self->{volumes} } ) {
        return $_ if $_->{id} == $volume_id;
    }

    return undef;
}

sub delete_volume {
    my ( $self, $volume_id ) = @_;

    $self->{volumes} = [ grep { $_->{id} != $volume_id } @{ $self->{volumes} } ];

	 return $self;
}

sub _set_option {
    my ( $self, $k, $v, $section ) = @_;

    $self->{$section}->{$k} = $v;

    return $self;
}

sub _delete_option {
    my ( $self, $k, $section ) = @_;

    delete $self->{$section}->{$k};

	 return $self;
}

sub set_net_option {
    return _set_option (@_, "net_options");
}

sub delete_net_option {
    return _delete_option (@_, "net_options");
}

sub set_disk_option {
    return _set_option (@_, "disk_options");
}

sub delete_disk_option {
    return _delete_option (@_, "disk_options");
}

1;
__END__

LINBIT::DRBD::Resource - DRBD9 connection related methods

=head1 SYNOPSIS

	use LINBIT::DRBD::Connection;

Methods return the object itself, which allows for:

	my $connection = LINBIT::DRBD::Connection->new()
		->set_nodes($n0, $n1);

=head1 VERSION

0.1.0

=head1 METHODS

=head2 new()

	my $con = LINBIT::DRBD::Resource->new([n0, n1, n0_nif, n1_nif]);

Create a new connection object with the given C<LINBIT::DRBD::Node> objects an their optional interface names.

=head2 set_nodes($n0, $n1 [, n0_nif, n1_nif])

	$con->set_nodes($n0, n1);
	$con->set_nodes($n0, n1, "default", "eth0");

Set the C<LINBIT::DRBD::Node> objects to the connection.

=head2 add_volume()

	$con->add_volume($volume);

Add a DRBD volume (see C<LINBIT::DRBD::Volume>) to a resource. Usually this is a volume object that only holds peer-device options but not disk/meta-disk.

=head2 get_volume($id)

	$con->get_volume(0);

Get a DRBD volume (see C<LINBIT::DRBD::Volume>) from a connection.

=head2 delete_volume($id)

	$con->delete_volume(0);

Delete a DRBD volume (see C<LINBIT::DRBD::Volume>) from a connection.

=head2 set_net_option()

	$con->set_net_option('key', 'value');

Sets an option in the net-section of the connection in the resource file.

=head2 delete_net_option()

	$con->delete_net_option('key');

Deletes an option in the net-section of the connection in the resource file.

=head2 set_disk_option()

	$con->set_disk_option('key', 'value');

Sets an option in the disk-section of the connection in the resource file. In this context only peer-device-options are useful.

=head2 delete_disk_option()

	$con->delete_disk_option('key');

Delete an option in the disk-section of the connection in the resource file. In this context only peer-device-options are useful.
