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

sub get_disk {
    my $self = shift;

    return $self->{disk};
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

sub get_metadata_disk {
    my $self = shift;

    return $self->{meta_data};
}

sub set_minor {
    my ( $self, $minor ) = @_;

    $self->{minor} = $minor;

    return $self;
}

sub get_minor {
    my $self = shift;

    return $self->{minor};
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

sub set_disk_option {
    return _set_option (@_, "disk_options");
}

sub delete_disk_option {
    return _delete_option (@_, "disk_options");
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

0.2.1

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

=head2 get_disk()

	$disk = $vol->get_disk();

Gets the DRBD backing device block device path, or "none".

=head2 set_internal_metadata()

	$vol->set_internal_metadata();

Set the DRBD backing device to contain internal DRBD meta-data.

=head2 set_external_metadata($blockdev)

	$vol->set_external_metadata("/dev/thinpool/disk1_md");

Set the DRBD backing device to contain external DRBD meta-data at the specified block device.

=head2 get_metadata_disk()

	$meta_data_disk = $vol->get_metadata_disk();

Gets the DRBD meta-data block device path, or "internal".

=head2 set_minor($minor_number)

	$vol->set_minor(1000);

Set the DRBD volume's block device minor number.

=head2 get_minor()

	$minor_nr = $vol->get_minor();

Get the DRBD volume's minor number.

=head2 set_minor($minor_number)

	$vol->set_minor(1000);

Set the DRBD volume's block device minor number.

=head2 set_disk_option()

	$vol->set_disk_option('key', 'value');

Sets an option in the disk-section of this volume.

=head2 delte_disk_option()

	$vol->delete_disk_option('key');

Deletes an option in the disk-section of this volume.
