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

package LINBIT::DRBD::Resource;

use strict;
use warnings;

use JSON::XS qw( decode_json );
use Carp qw( confess );

sub new {
    my ( $class, $name ) = @_;

    my $self = bless { name => $name, is_mesh => 1 }, $class;
}

sub add_volume {
    my ( $self, $volume ) = @_;

    push( @{ $self->{volumes} }, $volume );

    return $self;
}

sub add_node {
    my ( $self, $node ) = @_;

    push( @{ $self->{nodes} }, $node );

    return $self;
}

sub set_mesh {
    my ( $self, $is_mesh ) = @_;

    $self->{is_mesh} = $is_mesh;

    return $self;
}

sub add_connection {
    my ( $self, $host1, $host2 ) = @_;

    $self->{is_mesh} = 0;
    push( @{ $self->{connections} }, [ $host1, $host2 ] );

    return $self;
}

sub set_net_option {
    my ( $self, $k, $v ) = @_;

    $self->{net_options}->{$k} = $v;

    return $self;
}

sub set_disk_option {
    my ( $self, $k, $v ) = @_;

    $self->{disk_options}->{$k} = $v;

    return $self;
}

sub set_options_option {
    my ( $self, $k, $v ) = @_;

    $self->{options_options}->{$k} = $v;

    return $self;
}

# print indented
sub _pi {
    my $self = shift;
    my $fh   = $self->{fh};
    print $fh "    " x $self->{indent}, @_;
}

sub _write_volume {
    my ( $self, $volume ) = @_;

    die "Volume does not have a 'disk'" unless defined $volume->{disk};
    die "Volume does not have a 'meta-disk'"
      unless defined $volume->{meta_data};
    die "Volume does not have a 'minor'" unless defined $volume->{minor};

    $self->_pi("volume $volume->{id} {\n");

    $self->{indent}++;
    $self->_pi("disk $volume->{disk};\n");
    $self->_pi("meta-disk $volume->{meta_data};\n");
    $self->_pi("device minor $volume->{minor};\n");
    $self->{indent}--;

    $self->_pi("}\n");
}

sub _write_node {
    my ( $self, $node ) = @_;

    $self->_pi("on $node->{name} {\n");

    $self->{indent}++;
    foreach ( @{ $node->{volumes} } ) {
        $self->_write_volume($_);
    }
    $self->_pi(
        "address $node->{address_type} $node->{address}:$node->{port};\n");
    $self->_pi("node-id $node->{id};\n");
    $self->{indent}--;

    $self->_pi("}\n");
}

sub _write_connection {
    my ( $self, $h1, $h2 ) = @_;

    $self->_pi("connection {\n");

    $self->{indent}++;
	 foreach ($h1, $h2) {
		$self->_pi("host $_->{name} address $_->{address_type} $_->{address}:$_->{port};\n");
	  }
    $self->{indent}--;

    $self->_pi("}\n");
}

sub _write_connections {
    my $self = shift;

    if ( $self->{is_mesh} ) {
        my $hosts = join " ",
          ( my @hosts = map { $_->{name} } @{ $self->{nodes} } );

        $self->_pi("connection-mesh {\n");
        $self->{indent}++;
        $self->_pi("hosts $hosts;\n");
        $self->{indent}--;
        $self->_pi("}\n");
        return;
    }

    # not a mesh, dedicated connections
    foreach ( @{ $self->{connections} } ) {
        $self->_write_connection( $_->[0], $_->[1] );
    }
}

sub _write_options {
    my $self = shift;

    for my $section ( "net", "disk", "options" ) {
        $self->_pi("$section {\n");

        my $opt_dict = "${section}_options";
        $self->{indent}++;
        for my $k ( keys %{ $self->{$opt_dict} } ) {
            $self->_pi("$k $self->{$opt_dict}->{$k};\n");
        }
        $self->{indent}--;

        $self->_pi("}\n");
    }
}

sub write_resource_file {
    my ( $self, $path ) = @_;

    $path = "/etc/drbd.d/$self->{name}.res" if not defined($path);
    if ( $path eq "-" ) {
        $self->{fh} = *STDOUT;
    }
    else {
        open( $self->{fh}, '>', $path ) or die "Can't open ${path}: $!";
    }

    $self->{indent} = 0;
    $self->_pi("resource \"$self->{name}\" {\n");

    $self->{indent}++;

    $self->_write_options;

    foreach ( @{ $self->{volumes} } ) {
        $self->_write_volume($_);
    }

    foreach ( @{ $self->{nodes} } ) {
        $self->_write_node($_);
    }

    $self->_write_connections;

    $self->{indent}--;

    $self->_pi("}\n");

    close( $self->{fh} ) unless $path eq "-";

    return $self;
}

sub _drbdadm {
    my $self = shift;
    my @cmd  = @_;

    push( @cmd, $self->{name} );
    system( "drbdadm", @cmd ) == 0
      or die "Could not execute drbdadm @{cmd}: $!";
}

sub adjust {
    my $self = shift;

    $self->_drbdadm("adjust");
}

sub up {
    my $self = shift;

    $self->_drbdadm("up");
}

sub down {
    my $self = shift;

    $self->_drbdadm("down");
}

sub primary {
    my $self = shift;

    $self->_drbdadm("primary");
}

sub secondary {
    my $self = shift;

    $self->_drbdadm("secondary");
}

sub initial_sync {
    my $self = shift;

    $self->_drbdadm( "primary", "--force" );
}

sub create_md {
    my $self = shift;

    $self->_drbdadm( "create-md", "--force" );
}

sub status {
    my $self = shift;

    my $status;
    eval { $status = decode_json(`drbdsetup status --json $self->{name}`); };
    confess $@ if $@;

    return @$status[0];
}

1;
__END__

=head1 NAME

LINBIT::DRBD::Resource - DRBD9 resource related methods

=head1 SYNOPSIS

	use LINBIT::DRBD::Resource;

Methods return the object itself, which allows for:

	my $res = LINBIT::DRBD::Resource->new('rck')
		->add_volume($v0)
		->add_node($n0)->add_node($n1);

=head1 VERSION

0.0.0

=head1 METHODS

=head2 new()

	my $res = LINBIT::DRBD::Resource->new('resname');

Create a new resource object with the given DRBD resource name.

=head2 add_volume()

	$res->add_volume($volume);

Add a DRBD volume (see C<LINBIT::DRBD::Volume>) to a resource.

=head2 add_node()

	$res->add_node($node);

Add a DRBD node (see C<LINBIT::DRBD::Node>) to a resource.

=head2 set_mesh()

	$res->set_mesh(1);

If set to true, the res file is generated with a C<connection-mesh> directive. This is useful when the cluster consists of many nodes (and therefor many connections between nodes).

=head2 add_connection()

	$res->add_connection($n1, $n2);

Adds a connection between two nodes (i.e., C<LINBIT::DRBD::Node> objects).

=head2 set_net_option()

	$res->set_net_option('key', 'value');

Sets an option in the net-section of the resource file.

=head2 set_disk_option()

	$res->set_disk_option('key', 'value');

Sets an option in the disk-section of the resource file.

=head2 set_options_option()

	$res->set_options_option('key', 'value');

Sets an option in the options-section of the resource file.

=head2 write_resource_file()

	$res->write_resource_file('/etc/drbd.d/r1.res');

Writes a resource file. If a path is given, the resource file gets written to that path. If '-' is given, the resource file is printed to C<STDOUT>, and if the parameter is not defined, F</etc/drbd.d/${resname}.res> is used.

=head2 DRBD Commands

These commands are almost directly mapped to the according C<drbdadm> or C<drbdsetup> commands.

=head3 up()

	$res->up();

Calls C<drbdadm up $resname>

=head3 down()

	$res->down();

Calls C<drbdadm down $resname>

=head3 primary()

	$res->pirmary();

Calls C<drbdadm primary $resname>

=head3 secondary()

	$res->pirmary();

Calls C<drbdadm secondary $resname>

=head3 create_md()

	$res->create_md();

Calls C<drbdadm create-md --force $resname>

=head3 initial_sync()

	$res->create_md();

Starts an initial sync by calling C<drbdadm primary --force $resname>

=head3 status()

	$res->status();

Calls C<drbdsetup status --json $resname> and return the hash matching this resource.

=head1 EXAMPLES

=head2 Creating a new resource on two nodes

	use LINBIT::DRBD::Resource;
	use LINBIT::DRBD::Volume;
	use LINBIT::DRBD::Node;
	
	my $v0 = LINBIT::DRBD::Volume->new(0)
	         ->set_disk('/dev/lvm-local/rck')
	         ->set_minor(23);
	
	my $n0 = LINBIT::DRBD::Node->new('alpha', 0)
	         ->set_address('192.168.122.94')->set_port(2342);
	
	my $n1 = LINBIT::DRBD::Node->new('bravo', 1)
	         ->set_address('192.168.122.95')->set_port(2342);
	
	my $r = LINBIT::DRBD::Resource->new("rck");
	$r->add_volume($v0);
	$r->add_node($n0)->add_node($n1);
	$r->add_connection($n0, $n1);
	$r->set_net_option('allow-two-primaries', 'yes');
	
	$r->write_resource_file(); # implicit to /etc/drbd.d/rck.res
	$r->create_md();
	$r->up();
	# on one node one would call $r->initial_sync();

=head2 Query the status of an existing resource

	use LINBIT::DRBD::Resource;
	
	my $r = LINBIT::DRBD::Resource->new('rck');
	my $s = $r->status();
	
	print "my current role is '$s->{role}' and I'm '$s->{devices}[0]{'disk-state'}'\n";
