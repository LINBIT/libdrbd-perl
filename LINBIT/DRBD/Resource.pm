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
use File::Temp qw( tempfile );
use POSIX qw( uname );
use File::Spec;
use File::Copy;
use Data::UUID;
use IPC::Open3;
use IO::File;

use LINBIT::DRBD::Node;

# should be: use parent "Storable"; but we need to support very old perl
use Storable; our @ISA="Storable";

sub new {
    my ( $class, $name ) = @_;

    my $self = bless {
        name             => $name,
        is_mesh          => 1,
        cmd_stdout       => '',
        cmd_stderr       => '',
        debug_out        => '',
        _debug           => 0,
        _debug_to_stderr => 0
    }, $class;
}

sub STORABLE_freeze {
    my $self = shift;

    $self->{cmd_stdout} = '';
    $self->{cmd_stderr} = '';
    $self->{debug_out} = '';
    delete( $self->{fh} );

    return ();
}

sub _get_file_path {
    my $path = shift;
    if ( ( $path eq "-" ) or ( File::Spec->file_name_is_absolute($path) ) ) {
        return $path;
    }

    return "/etc/drbd.d/${path}.res";
}

sub _gen_address {
    my ( $type, $address, $port ) = @_;
    $address = "[${address}]" if $type eq 'ipv6';
    return "address $type ${address}:${port}";
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

    $self->{nodes} = [ grep { $_->{name} ne $node_name } @{ $self->{nodes} } ];

    return $self;
}

sub get_name {
    return $_[0]->{name};
}

sub set_name {
    my ( $self, $name ) = @_;

    $self->{name} = $name;

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

sub set_handlers_option {
    return _set_option (@_, "handlers_options");
}

sub delete_handlers_option {
    return _delete_option (@_, "handlers_options");
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
    print $fh    "    " x $self->{indent}, @_;
    print STDERR "    " x $self->{indent}, @_ if $self->{_debug} and $self->{_debug_to_stderr};
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
        $self->_write_volume( $_, 1 );
    }
    $self->_pi(
        _gen_address(
            $node->{nifs}{default}{address_type},
            $node->{nifs}{default}{address},
            $node->{nifs}{default}{port}
          )
          . ";\n"
    ) if $self->{is_mesh};
    $self->_pi("node-id $node->{id};\n");
    $self->{indent}--;

    $self->_pi("}\n");
}

sub _write_connection {
    my ( $self, $connection ) = @_;

    my $h1     = $connection->{node1};
    my $h2     = $connection->{node2};
    my $h1_nif = $connection->{node1_nif};
    my $h2_nif = $connection->{node2_nif};

    $self->_pi("connection {\n");

    $self->{indent}++;
    foreach ( [ $h1, $h1_nif ], [ $h2, $h2_nif ] ) {
        my ( $h, $nif ) = @$_;
        my $address = $h->{nifs}{$nif}{address};
        my $type    = $h->{nifs}{$nif}{address_type};
        $self->_pi( "host $h->{name} "
              . _gen_address( $type, ${address}, $h->{nifs}{$nif}{port} )
              . ";\n" );
    }
    foreach ( @{ $connection->{volumes} } ) {
        $self->_write_volume( $_, 0 );
    }
    for my $section ( "net", "disk" ) {
        my $opt_dict = $connection->{"${section}_options"};
        $self->_write_options_section( $opt_dict, $section );
    }
    $self->{indent}--;

    $self->_pi("}\n");
}

sub _write_connections {
    my $self = shift;

    if ( $self->{is_mesh} ) {
        return unless @{$self->{nodes}} > 0;
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

    for my $section ( "net", "disk", "options", "handlers" ) {
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

sub _write_resource_file {
    my ( $self, $test_config, $path ) = @_;

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
            $path, "sh-nop" ) if $test_config;
        move( $tmppath, $path ) or die "Move ($tmppath -> $path) failed: $!";
    }

    return $self;
}

sub write_resource_file {
    my $self = shift;
    return $self->_write_resource_file( 1, @_ );
}

sub _run_command {
    my $self = shift;
    my $cmd  = shift;
    my @args = @_;

    $self->{debug_out} = "--- Executing: $cmd @args\n" if $self->{_debug};

    # should be run IPC::Cmd; but again, very very old perl
    my $in = '';
    local *CATCHOUT = IO::File->new_tmpfile;
    local *CATCHERR = IO::File->new_tmpfile;
    my $pid        = open3( $in, ">&CATCHOUT", ">&CATCHERR", $cmd, @args );
    my $waitstatus = waitpid( $pid, 0 );
    my ( $rc, $sig, $core ) = ( $? >> 8, $? & 127, $? & 128 );

    seek $_, 0, 0 for \*CATCHOUT, \*CATCHERR;
    $self->{cmd_stdout} = do { local $/; <CATCHOUT> };
    $self->{cmd_stderr} = do { local $/; <CATCHERR> };

    if ( $self->{_debug} > 1 ) {
        $self->{debug_out} .= sprintf "| STDOUT: %s\n", $self->{cmd_stdout}
          if $self->{cmd_stdout} ne '';
        $self->{debug_out} .= sprintf "| STDERR: %s\n", $self->{cmd_stderr}
          if $self->{cmd_stderr} ne '';
    }
    print STDERR "\n", "$self->{debug_out}"
      if $self->{_debug} and $self->{_debug_to_stderr} and $self->{debug_out} ne '';

    die "could not wait for $cmd @{args}" unless $waitstatus > 0;
    die "could not successfully execute $cmd @{args}" unless $rc == 0;
}

sub get_cmd_stdout {
    return $_[0]->{cmd_stdout};
}

sub get_cmd_stderr {
    return $_[0]->{cmd_stderr};
}

sub get_debug_output {
    return $_[0]->{debug_out};
}

sub _drbdadm {
    my $self = shift;
    my @args = @_;

    push( @args, "$self->{name}" );
    return $self->_run_command( "drbdadm", @args );
}

sub _drbdsetup {
    my $self = shift;
    my @args = @_;

    push( @args, "$self->{name}" );
    return $self->_run_command( "drbdsetup", @args );
}

sub _drbdadm_volume {
    my $self   = shift;
    my $volume = shift;
    my @args   = @_;

    push( @args, "$self->{name}/$volume" );
    return $self->_run_command( "drbdadm", @args );
}

sub _drbdadm_node {
    my $self = shift;
    my $node = shift;
    my @args = @_;

    push( @args, "$self->{name}:${node}" );
    return $self->_run_command( "drbdadm", @args );
}

sub adjust {
    my $self = shift;

    $self->_drbdadm_maybe_node( "adjust", @_ );
}

sub resume {
    my $self = shift;
    return $self->adjust(@_);
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

sub verify {
    my $self = shift;

    $self->_drbdadm("verify");
}

sub begins_with {
    return 0 if not defined $_[0];
    return substr( $_[0], 0, length( $_[1] ) ) eq $_[1];
}

sub _get_node_args {
    return undef, @_ if begins_with( $_[0], "-" );    # already an option
    return @_;                                        # receiver splits it into $node, @args
}

sub _drbdadm_maybe_node {
    my $self = shift;
    my $cmd  = shift;
    my ( $node, @args ) = _get_node_args(@_);

    if ( defined $node ) {
        return $self->_drbdadm_node( $node, $cmd, @args );
    }
    return $self->_drbdadm( $cmd, @args );
}

sub connect {
    my $self = shift;

    $self->_drbdadm_maybe_node( "connect", @_ );
}

sub disconnect {
    my $self = shift;

    $self->_drbdadm_maybe_node( "disconnect", @_ );
}

sub pause {
    my $self = shift;
    return $self->disconnect(@_);
}

sub initial_sync {
    my $self = shift;

    $self->_drbdadm( "primary", "--force" );
    $self->_drbdadm( "secondary" );
}

sub invalidate {
    my $self = shift;

    $self->_drbdadm_maybe_node( "invalidate", @_ );
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

        if ( scalar @{ $self->{nodes} } == 1 ) {

            # workaround for drbdadm bug if there is only one node
            $self->_drbdadm_volume( $volume, 'sh-md-dev' );
            chomp( my $md_dev = $self->{cmd_stdout} );

            $self->_drbdadm_volume( $volume, 'sh-md-idx' );
            chomp( my $md_idx = $self->{cmd_stdout} );
            $md_idx = 'flex-external' unless $md_idx eq 'internal';

            $self->_run_command( 'drbdmeta', '--force',
                '--node-id', $self->{nodes}[0]->{id},
                '2342', 'v09', $md_dev, $md_idx, 'set-gi', "$gid" );
        }
        else {
            # yes, here the syntax is weird/reverse
            $self->_drbdadm_volume( $volume, "$gid", "set-gi", "--force" );
        }
    }
}

sub status {
    my $self = shift;

    $self->_drbdsetup( 'status', '--json' );
    my $status;
    eval { $status = decode_json( $self->{cmd_stdout} ); };
    confess $@ if $@;

    return @$status[0];
}

sub local_dstate {
    my $self = shift;

    $self->_drbdadm('dstate');
    my $dstate = $self->{cmd_stdout};

    return ( split /\//, $dstate, 2 )[0];
}

sub wait_for_usable {
    my ( $self, $timeout ) = @_;

    $timeout = 30 if not defined $timeout;

    eval {
        $self->_drbdsetup( 'wait-connect-resource', '--wfc-timeout', $timeout,
            '--degr-wfc-timeout', $timeout, '--outdated-wfc-timeout',
            $timeout );
    };
    if ($@) {
        open( my $fh, '-|', 'drbdadm', 'dstate', $self->{name} ) or die $!;
        while ( my $line = <$fh> ) {
            die "wait-connect-resource failed AND none UpToDate"
              if ( $line !~ m/UpToDate/ );
        }
    }
}

sub validate_drbd_option {
    my ( $class, $k, $v ) = @_;

    my %drbd_opts = (
        'after-resync-target'       => 'handlers',
        'after-sb-0pri'             => 'net',
        'after-sb-1pri'             => 'net',
        'after-sb-2pri'             => 'net',
        'al-extents'                => 'disk',
        'al-updates'                => 'disk',
        'allow-remote-read'         => 'net',
        'allow-two-primaries'       => 'net',
        'always-asbp'               => 'net',
        'auto-promote'              => 'options',
        'auto-promote-timeout'      => 'options',
        'before-resync-source'      => 'handlers',
        'before-resync-target'      => 'handlers',
        'bitmap'                    => 'disk',
        'c-delay-target'            => 'disk',
        'c-fill-target'             => 'disk',
        'c-max-rate'                => 'disk',
        'c-min-rate'                => 'disk',
        'c-plan-ahead'              => 'disk',
        'congestion-extents'        => 'net',
        'congestion-fill'           => 'net',
        'connect-int'               => 'net',
        'cpu-mask'                  => 'options',
        'cram-hmac-alg'             => 'net',
        'csums-after-crash-only'    => 'net',
        'csums-alg'                 => 'net',
        'data-integrity-alg'        => 'net',
        'disable-write-same'        => 'disk',
        'discard-zeroes-if-aligned' => 'disk',
        'disk-barrier'              => 'disk',
        'disk-drain'                => 'disk',
        'disk-flushes'              => 'disk',
        'disk-timeout'              => 'disk',
        'fence-peer'                => 'handlers',
        'fencing'                   => 'net',
        'initial-split-brain'       => 'handlers',
        'ko-count'                  => 'net',
        'local-io-error'            => 'handlers',
        'max-buffers'               => 'net',
        'max-epoch-size'            => 'net',
        'max-io-depth'              => 'options',
        'md-flushes'                => 'disk',
        'on-congestion'             => 'net',
        'on-io-error'               => 'disk',
        'on-no-data-accessible'     => 'options',
        'on-no-quorum'              => 'options',
        'out-of-sync'               => 'handlers',
        'peer-ack-delay'            => 'options',
        'peer-ack-window'           => 'options',
        'ping-int'                  => 'net',
        'ping-timeout'              => 'net',
        'pri-lost'                  => 'handlers',
        'pri-lost-after-sb'         => 'handlers',
        'pri-on-incon-degr'         => 'handlers',
        'protocol'                  => 'net',
        'quorum'                    => 'options',
        'quorum-lost'               => 'handlers',
        'quorum-minimum-redundancy' => 'options',
        'rcvbuf-size'               => 'net',
        'read-balancing'            => 'disk',
        'resync-after'              => 'disk',
        'resync-rate'               => 'disk',
        'rr-conflict'               => 'net',
        'rs-discard-granularity'    => 'disk',
        'shared-secret'             => 'net',
        'sndbuf-size'               => 'net',
        'socket-check-timeout'      => 'net',
        'split-brain'               => 'handlers',
        'tcp-cork'                  => 'net',
        'timeout'                   => 'net',
        'transport'                 => 'net',
        'twopc-retry-timeout'       => 'options',
        'twopc-timeout'             => 'options',
        'unfence-peer'              => 'handlers',
        'use-rle'                   => 'net',
        'verify-alg'                => 'net',
    );

    die "Option '$k' is not a valid drbd option" unless exists $drbd_opts{$k};

    my $section = $drbd_opts{$k};
    return $section unless defined $v;

    # need to check value via res file
    my $r = $class->new('libdrbdperl');
    my ( undef, $nodename ) = uname();
    my $n0 = LINBIT::DRBD::Node->new( $nodename, 0 )->set_address('1.2.3.4')
      ->set_port(1234);
    $r->add_node($n0);

    $r->set_net_option( $k, $v )      if ( $section eq 'net' );
    $r->set_disk_option( $k, $v )     if ( $section eq 'disk' );
    $r->set_options_option( $k, $v )  if ( $section eq 'options' );
    $r->set_handlers_option( $k, $v ) if ( $section eq 'handlers' );

    my ( undef, $tmppath ) = tempfile( OPEN => 0 );
    $r->_write_resource_file( 0, $tmppath );
    eval { $r->_drbdadm( '-c', $tmppath, "sh-nop" ); };
    my $failed = $@;
    unlink $tmppath;
    if ($failed) {
        my $how = $r->get_cmd_stderr();
        die "Option '$k' has an invalid value: ${how}";
    }

    return $section;
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

0.3.0

=head1 CLASS METHODS

=head2 validate_drbd_option()

	my $section = LINBIT::DRBD::Resource->validate_drbd_option('allow-two-primaries');
	my $section = LINBIT::DRBD::Resource->validate_drbd_option('allow-two-primaries', 'yes');

This command takes a key like "allow-two-primaries" in the above example and checks if it is a valid option.
If it is valid, it returns the DRBD section that key. In the example it would return "net".

If validation (key or value) fails, this calls C<die()>.

If a value is passed, a temporary fake res file is generated with the given option and its value, and C<drbdadm> is exected on that file to check that option.

=head1 METHODS

=head2 new()

	my $res = LINBIT::DRBD::Resource->new('resname');

Create a new resource object with the given DRBD resource name.

=head2 get_name()

	my $name = $res->get_name();

Get the name of the resource.

=head2 set_name($resname)

	my $name = $res->set_name('newname');

Sets the name in the resource object. Note that this does not rename a resource on DRBD level. In order to do that, you want to C<down> the resource, remove the old C<.res> file, write the new one, C<up> the resource.

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

=head2 set_handlers_option()

	$res->set_handlers_option('key', 'value');

Sets a hanlder in the handlers-section of the resource file.

=head2 delete_handlers_option()

	$res->delete_handlers_option('key');

Delete an option in the handlers-section of the resource file.

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

=head2 wait_for_usable([timeout])

	$res->wait_for_usable(30);

We often see that users think that as soon as the device is created, the resource is also usable, which is wrong. This method waits the given amount of seconds (default is 30 seconds). If the resource is not usable within this timeout the method calls C<die()>.

Most likely one wants to call it after an C<initial_sync()> on the initiator node, or after an C<up> on the other nodes.

=head2 DRBD Commands

These commands are almost directly mapped to the according C<drbdadm> or C<drbdsetup> commands. In case of an error, commands in this section call C<die()>.

The stdout and stderr outputs are stored internally and be retrieved via C<get_cmd_stdout> and C<get_cmd_stderr>. These bufferes set to the the empty string before serialization with C<Storable>.

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

=head3 adjust()

	$res->adjust();
	$res->connect("peer1");

Adjusts a resource by calling C<drbdadm adjust [args,...] $resname>.
If the first argument is a peer (i.e., not starting with "-"), the command is executed for that peer only.

=head3 connect()

	$res->connect();
	$res->connect("--discard-my-data");
	$res->connect("peer1", --discard-my-data");

Connects a resource calling C<drbdadm connect [args,...] $resname>.
If the first argument is a peer (i.e., not starting with "-"), the command is executed for that peer only.

=head3 disconnect()

	$res->disconnect();
	$res->disconnect("--force");

Disconnects a resource calling C<drbdadm disconnect [args,...] $resname>
If the first argument is a peer (i.e., not starting with "-"), the command is executed for that peer only.

=head3 invalidate()

	$res->invalidate();
	$res->invalidate("--force");
	$res->invalidate("peer1", --force");

Invalidate a resource by calling C<drbdadm invalidate [args,...] $resname>.
If the first argument is a peer (i.e., not starting with "-"), the command is executed for that peer, trying to sync from that peer.

=head3 pause()

	$res->pause();
	$res->pause("peer1");

Pauses replication. This is an alias to C<disconnect>.
If the first argument is a peer (i.e., not starting with "-"), the command is executed for that peer only.

=head3 resume()

	$res->resume();
	$res->resume("peer1");

Resumes a paused (i.e., disconnected) replication. This is an alias to C<adjust>.
If the first argument is a peer (i.e., not starting with "-"), the command is executed for that peer only.

=head3 verify()

	$res->verify();

Starts a verify process calling C<drbdadm verify $resname>

=head3 status()

	$res->status();

Calls C<drbdsetup status --json $resname> and returns the hash matching this resource.

=head3 local_dstate()

	$res->local_dstate();

Calls C<drbdadm dstate> and returns the first element (i.e., the local dstate).

=head3 get_cmd_stdout()

	print $res->get_cmd_stdout();

Get the stdout of the last external command.

=head3 get_cmd_stderr()

	print $res->get_cmd_stderr();

Get the stderr of the last external command.

=head3 get_debug_output()

	print $res->get_debug_output();

Gets debug output for externally executed commands (C<drbdadm>,C<drbdsetup>) including the commands arguments and its stdout/stderr.
This is meant for developers.
This requires to set C<_debug> to a level greater or equal to 1. Most users don't want to use this getter, but set C<_debug_to_stderr> instead.

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

In order to extend a resource at a later point in time, one has to serialize its state. Note that on serialization internal buffers not required (or even dangerous because leeking information) are discarded. These are currently the buffers that store stdout/stderr of the last command.

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
