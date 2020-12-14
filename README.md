# libdrbd-perl

This library allow to manipulate DRBD9 resources (adding nodes, volumes, DRBD options) and provides some
useful wrappers on such resource objects. Most of these wrappers are trivial, like `$r->up()` calling `drbdadm
up $resname`, some provide a slightly higher abstraction such as `$r->initial_sync()`.

Further the library allows to serialize a resource object (via `Storable`) and read it back at a later point
in time to for example add further nodes.

# Documentation
HTML rendered Perl documentation can be found [here](https://linbit.github.io/libdrbd-perl).

# Who should use it?
Nobody. If you are unsure, do not use it. [LINSTOR](https://github.com/LINBIT/linstor-server) most likely is
the better choice.
