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
use File::Spec;
use File::Copy;
use Data::UUID;

# should be: use parent "Storable"; but we need to support very old perl
use Storable; our @ISA="Storable";

sub new {
    my ( $class, $name ) = @_;

    my $self = bless { name => $name, is_mesh => 1 }, $class;
}

sub _get_file_path {
    my $path = shift;
    if ( ( $path eq "-" ) or ( File::Spec->file_name_is_absolute($path) ) ) {
        return $path;
    }

    return "/etc/drbd.d/${path}.res";
}

sub add_volume {
    my ( $self, $volume ) = @_;

    push( @{ $self->{volumes} }, $volume );

    return $self;
}

sub get_volume {
    my ( $self, $volume_id ) = @_;

    foreach ( @{ $self->{volumes} } ) {
        return $_ if ( $_->{id} == $volume_id );
    }

    return undef;
}

sub delete_volume {
    my ( $self, $volume_id ) = @_;

    $self->{volumes} =
      [ grep { $_->{id} != $volume_id } @{ $self->{volumes} } ];

    return $self;
}

sub add_node {
    my ( $self, $node ) = @_;

    push( @{ $self->{nodes} }, $node );

    return $self;
}

sub get_node {
    my ( $self, $node_name ) = @_;

    foreach ( @{ $self->{nodes} } ) {
        return $_ if ( $_->{name} eq $node_name );
    }

    return undef;
}

sub delete_node {
    my ( $self, $node_name ) = @_;

    $self->{nodes} = [ grep { $_->{name} != $node_name } @{ $self->{nodes} } ];

    return $self;
}

sub set_mesh {
    my ( $self, $is_mesh ) = @_;

    $self->{is_mesh} = $is_mesh;

    return $self;
}

sub add_connection {
    my ( $self, $connection ) = @_;

    $self->{is_mesh} = 0;
    push( @{ $self->{connections} }, $connection );

    return $self;
}

sub _canon_connection_hostnames {
	my ($n1, $n2) = @_;

	if ($n1 lt $n2) {
		return $n1 . '-' . $n2;
	}
	return $n2 . '-' . $n1;
}

sub get_connection {
    my ( $self, $nodename1, $nodename2 ) = @_;

    my $conn_find = _canon_connection_hostnames( $nodename1, $nodename2 );

    foreach ( @{ $self->{connections} } ) {
        my ( $n1, $n2 ) = ( $_->{node1}->{name}, $_->{node2}->{name} );
        return undef unless defined $n1 and defined $n2;

        my $conn_current = _canon_connection_hostnames( $n1, $n2 );

        return $_ if $conn_find eq $conn_current;
    }

    return undef;
}

sub delete_connection {
    my ( $self, $nodename1, $nodename2 ) = @_;

    # is there even such a connection?
    my $conn = $self->get_connection( $nodename1, $nodename2 );
    return $self unless defined $conn;

    my ( $name1, $name2 ) = ( $conn->{node1}->{name}, $conn->{node2}->{name} );
	 # not to confuse with $nodename[12]. These are already in the matching order.

    $self->{connections} = [
        grep {
            !( $_->{node1}->{name} eq $name1 and $_->{node2}->{name} eq $name2 )
        } @{ $self->{connections} }
    ];

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

sub set_options_option {
    return _set_option (@_, "options_options");
}

sub delete_options_option {
    return _delete_option (@_, "options_options");
}

sub set_comment {
    # key with out a value, "plain comment"
    if ( scalar @_ == 2 ) {
        push @_, undef;
    }
    return _set_option( @_, "comments" );
}

sub get_comment {
    my ( $self, $k ) = @_;
    return $self->{comments}->{$k};
}

sub delete_comment {
    return _delete_option (@_, "comments");
}

sub _add_reserved_prefix {
    return '__libdrbd-perl-' . $_[0];
}

sub _initial_uuid_prefix {
    return _add_reserved_prefix('initial-uuid');
}

sub set_random_initial_uuid {
    my $self = shift;
    my $ui   = Data::UUID->new();

    return $self->set_comment( _initial_uuid_prefix,
        substr( $ui->create_hex(), 2 + 16, -1 )
          . sprintf( '%X', int( rand(16) ) & 0xe ) )
      ; # 2 for 0x; skip unused 16 (64bit of 128bit UUID), strip last, add random hex without the Primary flag set
}

sub set_initial_uuid {
    my ($self, $uuid) = @_;

    return $self->set_comment( _initial_uuid_prefix, $uuid);
}

sub get_initial_uuid {
    my $self = shift;
    return $self->get_comment( _initial_uuid_prefix );
}

sub delete_initial_uuid {
    my $self = shift;
    return $self->delete_comment( _initial_uuid_prefix );
}

# print indented
sub _pi {
    my $self = shift;
    my $fh   = $self->{fh};
    print $fh "    " x $self->{indent}, @_;
}

# strict is used for "real volumes", where non strict is used if we are only interested in the disk options.
sub _write_volume {
    my ( $self, $volume, $strict ) = @_;

    if ($strict) {
        die "Volume does not have a 'disk'" unless defined $volume->{disk};
        die "Volume does not have a 'meta-disk'"
          unless defined $volume->{meta_data};
        die "Volume does not have a 'minor'" unless defined $volume->{minor};
    }

    $self->_pi("volume $volume->{id} {\n");

    $self->{indent}++;
    $self->_pi("disk $volume->{disk};\n") if defined $volume->{disk};
    $self->_pi("meta-disk $volume->{meta_data};\n")
      if defined $volume->{disk}; # use disk here as well as it has a default value
    $self->_pi("device minor $volume->{minor};\n") if defined $volume->{minor};
    for my $section ("disk") {
        my $opt_dict = $volume->{"${section}_options"};
        $self->_write_options_section( $opt_dict, $section );
    }
    $self->{indent}--;

    $self->_pi("}\n");
}

sub _write_node {
    my ( $self, $node ) = @_;

    $self->_pi("on $node->{name} {\n");

    $self->{indent}++;
    foreach ( @{ $node->{volumes} } ) {
        $self->_write_volume($_, 1);
    }
    $self->_pi(
        "address $node->{address_type} $node->{address}:$node->{port};\n");
    $self->_pi("node-id $node->{id};\n");
    $self->{indent}--;

    $self->_pi("}\n");
}

sub _write_connection {
    my ( $self, $connection ) = @_;

    my $h1 = $connection->{node1};
    my $h2 = $connection->{node2};

    $self->_pi("connection {\n");

    $self->{indent}++;
    foreach ( $h1, $h2 ) {
        $self->_pi( "host $_->{name} address $_->{address_type} $_->{address}:$_->{port};\n" );
    }
    foreach ( @{ $connection->{volumes} } ) {
        $self->_write_volume( $_, 0 );
    }
    for my $section ("net", "disk") {
        my $opt_dict = $connection->{"${section}_options"};
        $self->_write_options_section( $opt_dict, $section );
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
        $self->_write_connection( $_ );
    }
}

sub _write_options_section {
    my ( $self, $opt_dict, $section ) = @_;
    return if !defined($opt_dict);

    $self->_pi("$section {\n");
    $self->{indent}++;
    for my $k ( keys %{$opt_dict} ) {
        $self->_pi("$k $opt_dict->{$k};\n");
    }
    $self->{indent}--;
    $self->_pi("}\n");
}

sub _write_options {
    my $self = shift;

    for my $section ( "net", "disk", "options" ) {
        my $opt_dict = $self->{"${section}_options"};
        $self->_write_options_section( $opt_dict, $section );
    }
}

sub _write_comments {
    my $self = shift;

    for my $k ( keys %{ $self->{comments} } ) {
        my $v = $self->{comments}->{$k};
        $self->_pi("# $k");
        $self->_pi(":$v") if defined($v);
        $self->_pi("\n");
    }
}

sub write_resource_file {
    my ( $self, $path ) = @_;

    $path = $self->{name} if not defined($path);
    $path = _get_file_path($path);

    my $tmppath = $path . ".tmp";

    if ( $path eq "-" ) {
        $self->{fh} = *STDOUT;
    }
    else {
        open( $self->{fh}, '>', $tmppath ) or die "Can't open ${tmppath}: $!";
    }

    $self->{indent} = 0;
    $self->_pi(
        "# THIS FILE WAS AUTOGENERATED BY 'libdrbd-perl', DO NOT EDIT\n");
    $self->_write_comments;
    $self->_pi("resource \"$self->{name}\" {\n");

    $self->{indent}++;

    $self->_write_options;

    foreach ( @{ $self->{volumes} } ) {
        $self->_write_volume($_, 1);
    }

    foreach ( @{ $self->{nodes} } ) {
        $self->_write_node($_);
    }

    $self->_write_connections;

    $self->{indent}--;

    $self->_pi("}\n");

    if ( $path ne "-" ) {
        close( $self->{fh} );
        delete( $self->{fh} );    # otherwise we can not store() the object

        $self->_drbdadm( '--config-to-test', $tmppath, '--config-to-exclude',
            $path, "sh-nop" );
        move( $tmppath, $path ) or die "Move ($tmppath -> $path) failed: $!";
    }

    return $self;
}

sub __drbdadm {
    my $self = shift;
    my @cmd  = @_;

    system( "drbdadm", @cmd ) == 0
      or die "Could not execute drbdadm @{cmd}: $!";
}

sub _drbdadm {
    my $self = shift;
    my @cmd  = @_;

    push( @cmd, "$self->{name}" );
    return $self->__drbdadm(@cmd);
}

sub _drbdadm_volume {
    my $self   = shift;
    my $volume = shift;
    my @cmd    = @_;

    push( @cmd, "$self->{name}/$volume" );
    return $self->__drbdadm(@cmd);
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
    my ( $self, $volume, $uuid, $uptodate ) = @_;

    $self->_drbdadm_volume( $volume, "create-md", "--force", "--max-peers=7" );

    if ( defined $uuid ) {
        my $history1 = '0';
        my $gid      = $uuid . ':';
        $gid .= '0:' . $history1 . ':0:';

        $uptodate = 1 if not defined $uptodate;

# in this case this really is the sane default if the user did not specify otherwise
# the only use case I can imagine is if the meta-data needs to be restored for whatever reason
# one still wants to set the saved UUID, but not set the data UpToDate to trigger a sync.
        if ($uptodate) {
            $gid .= '1:1:';    #UpToDate
        }

        # yes, here the syntax is weird/reverse
        $self->_drbdadm_volume( $volume, "$gid", "set-gi", "--force", );
    }
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

=head2 get_volume()

	$res->get_volume($id);

Get a DRBD volume (see C<LINBIT::DRBD::Volume>) from a resource.

=head2 delete_volume()

	$res->delete_volume($id);

Delete a DRBD volume (see C<LINBIT::DRBD::Volume>) from a resource.

=head2 add_node()

	$res->add_node($node);

Add a DRBD node (see C<LINBIT::DRBD::Node>) to a resource.

=head2 get_node()

	$res->get_node($node_name);

Get a DRBD node (see C<LINBIT::DRBD::Node>) from a resource.

=head2 delete_node()

	$res->delete_node($node_name);

Delete a DRBD node (see C<LINBIT::DRBD::Node>) from a resource.

=head2 set_mesh()

	$res->set_mesh(1);

If set to true, the res file is generated with a C<connection-mesh> directive. This is useful when the cluster consists of many nodes (and therefor many connections between nodes).

=head2 add_connection()

	$res->add_connection($connection)

Adds a connection between nodes via a C<LINBIT::DRBD::Connection> object.

=head2 get_connection()

	$res->get_connection($node_name1, $node_name2);

Get a connection between two nodes.

=head2 delete_connection()

	$res->delete_connection($node_name1, $node_name2);

Delete a connection between two nodes.

=head2 set_net_option()

	$res->set_net_option('key', 'value');

Sets an option in the net-section of the resource file.

=head2 delete_net_option()

	$res->delete_net_option('key');

Delete an option in the net-section of the resource file.

=head2 set_disk_option()

	$res->set_disk_option('key', 'value');

Sets an option in the disk-section of the resource file.

=head2 delete_disk_option()

	$res->delete_disk_option('key');

Delete an option in the disk-section of the resource file.

=head2 set_options_option()

	$res->set_options_option('key', 'value');

Sets an option in the options-section of the resource file.

=head2 delete_options_option()

	$res->delete_options_option('key');

Delete an option in the options-section of the resource file.

=head2 set_comment('key', ['value'])

	$res->set_comment('foo');
	$res->set_comment('bar', 'baz');

Sets a comment in the resource object. These are written as comments in the resource file.
This can be used as a simple key/value store when serializing/deserializing resources.

=head2 get_comment('key')

	$res->get_comment('bar');

Gets the value of a comment if it had one. If it was a plain comment, or it does not exist, it returns undef.

=head2 delete_comment('key')

	$res->delete_comment('bar');

Delete the comment.

=head2 set_random_initial_uuid()

	$res->set_random_initial_uuid();

Generate a random UUID that can be used for skipping the initial sync.

=head2 set_initial_uuid($uuid)

	$res->set_initial_uuid();

Set a UUID that can be used for skipping the initial sync.

=head2 get_initial_uuid()

	$res->get_initial_uuid();

Get the stored UUID that can be used for skipping the initial sync.

=head2 delete_initial_uuid()

	$res->delete_initial_uuid();

Delete the stored initial UUID that can be used for skipping the initial sync.

=head2 write_resource_file()

	$res->write_resource_file('/etc/drbd.d/r1.res');

Writes a resource file. If a path is given, the resource file gets written to that path. If '-' is given, the resource file is printed to C<STDOUT>, and if the parameter is not defined, F</etc/drbd.d/${resname}.res> is used.

The resource file, if not written to STDOUT, first gets generated to a C<.tmp> file, which gets tested for validity by calling C<drbdadm>. If the resource file is valid, it gets moved to its final name (without the C<.tmp> postfix).

This method might call C<die()>.

=head2 DRBD Commands

These commands are almost directly mapped to the according C<drbdadm> or C<drbdsetup> commands. In case of an error, commands in this section call C<die()>.

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

=head3 create_md($volid, [$gid, [$up2date]])

	$res->create_md(0);

Calls C<drbdadm create-md --force $resname/$volid>. If a $gid is given, it is set via C<drbdadm set-gi>. $up2date is only used if a $gid is given and it's default is true/1.

=head3 initial_sync()

	$res->initial_sync();

Starts an initial sync by calling C<drbdadm primary --force $resname>

=head3 status()

	$res->status();

Calls C<drbdsetup status --json $resname> and return the hash matching this resource.

=head1 EXAMPLES

=head2 Creating a new resource on two nodes

	use LINBIT::DRBD::Resource;
	use LINBIT::DRBD::Volume;
	use LINBIT::DRBD::Node;
	use LINBIT::DRBD::Connection;
	
	my $v0 = LINBIT::DRBD::Volume->new(0)
	         ->set_disk('/dev/lvm-local/rck')
	         ->set_minor(23);
	
	my $n0 = LINBIT::DRBD::Node->new('alpha', 0)
	         ->set_address('192.168.122.94')->set_port(2342);
	
	my $n1 = LINBIT::DRBD::Node->new('bravo', 1)
	         ->set_address('192.168.122.95')->set_port(2342);
	
	my $c0 = LINBIT::DRBD::Connection->new($n0, $n1);
	
	my $r = LINBIT::DRBD::Resource->new("rck");
	$r->add_volume($v0);
	$r->add_node($n0)->add_node($n1);
	$r->add_connection($c0);
	$r->set_net_option('allow-two-primaries', 'yes');
	
	$r->write_resource_file(); # implicit to /etc/drbd.d/rck.res
	$r->create_md(0);
	$r->up();
	# on one node one would call $r->initial_sync();

=head2 Query the status of an existing resource

	use LINBIT::DRBD::Resource;
	
	my $r = LINBIT::DRBD::Resource->new('rck');
	my $s = $r->status();
	
	print "my current role is '$s->{role}' and I'm '$s->{devices}[0]{'disk-state'}'\n";

=head2 Extend an existing resource

In order to extend a resource at a later point in time, one has to serialize its state.

	use Storable;
	my $r = LINBIT::DRBD::Resource->new("rck"); # and more
	$r->set_comment('my-info', 'very important');
	$r->store('/etc/drbd.d/rck.res.dump');
	# later...
	my $r2 = retrieve('/etc/drbd.d/rck.res.dump');
	print $r2->get_comment('my-info');
	
	# in order to modify an object one has to get a handle first
	# this can be done via the get_ methods
	$r2->get_node('alpha')->set_address('1.1.1.3');

=head2 Skipping the initial sync

If one uses backing devices that guarantee that they read 0s, or where the backing devices are zeroed locally
by other means, it makes sense to skip the initial sync. This needs a shared initial DRBD generation ID from
where then the actual sync starts. With the library one can do that like this:

	# # first node:
	# setup the resource as usual and then do:
	$r->set_random_initial_uuid();
	$r->write_resource_file();
	$r->store('/path/res.db');
	$r->create_md($volid, $r->get_initial_uuid());
	$r->up();
	$r->initial_sync();
	
	# # other nodes (after copying the stored file)
	my $r = retrieve('/path/res.db');
	$r->write_resource_file();
	$r->create_md($volid, $r->get_initial_uuid());
	$r->up();
