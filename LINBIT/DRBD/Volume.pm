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

1;
