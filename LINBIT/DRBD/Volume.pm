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

package LINBIT::DRBD::Volume;

use strict;
use warnings;

sub new {
    my ( $class, $id ) = @_;
    my $self = bless { id => $id, meta_data => "internal" }, $class;
}

sub set_disk {
    my ( $self, $disk ) = @_;

    $self->{disk} = $disk;

    return $self;
}

sub set_diskless {
    my $self = shift;

    $self->set_disk("none");

    return $self;
}

sub set_internal_metadata {
    my $self = shift;

    $self->{meta_data} = "internal";

    return $self;
}

sub set_external_metadata {
    my ( $self, $disk ) = @_;

    $self->{meta_data} = $disk;

    return $self;
}

sub set_minor {
    my ( $self, $minor ) = @_;

    $self->{minor} = $minor;

    return $self;
}

sub set_disk_option {
    my ( $self, $k, $v ) = @_;

    $self->{disk_options}->{$k} = $v;

    return $self;
}

1;
__END__

LINBIT::DRBD::Volume - DRBD9 volume related methods

=head1 SYNOPSIS

	use LINBIT::DRBD::Volume;

Methods return the object itself, which allows for:

	my $connection = LINBIT::DRBD::Volume->new(1)
		->set_disk("/dev/thinpool/disk1")
		->set_external_metadata("/dev/thinpool/disk1_md");

=head1 VERSION

0.0.0

=head1 METHODS

=head2 new($id)

	my $vol = LINBIT::DRBD::Volume->new(0);

Create a new volume object with the given volume ID.

=head2 set_disk($blockdev)

	$vol->set_disk("/dev/thinpool/disk1");

Set the DRBD backing device.

=head2 set_diskless()

	$vol->set_diskless();

Set the DRBD backing device to "none" (i.e., diskless).

=head2 set_internal_metadata()

	$vol->set_internal_metadata();

Set the DRBD backing device to contain internal DRBD meta-data.

=head2 set_external_metadata($blockdev)

	$vol->set_external_metadata("/dev/thinpool/disk1_md");

Set the DRBD backing device to contain external DRBD meta-data at the specified block device.

=head2 set_minor($minor_number)

	$vol->set_minor(1000);

Set the DRBD volume's block device minor number.

=head2 set_minor($minor_number)

	$vol->set_minor(1000);

Set the DRBD volume's block device minor number.

=head2 set_disk_option()

	$vol->set_disk_option('key', 'value');

Sets an option in the disk-section of this volume.
