DESTDIR=
PREFIX=/usr

export PERLDIR=${PREFIX}/share/perl5

install:
	install -D -m 0644 ./LINBIT/DRBD/Resource.pm ${DESTDIR}$(PERLDIR)/LINBIT/DRBD/Resource.pm
	install -D -m 0644 ./LINBIT/DRBD/Volume.pm ${DESTDIR}$(PERLDIR)/LINBIT/DRBD/Volume.pm
	install -D -m 0644 ./LINBIT/DRBD/Node.pm ${DESTDIR}$(PERLDIR)/LINBIT/DRBD/Node.pm
	install -D -m 0644 ./LINBIT/DRBD/Connection.pm ${DESTDIR}$(PERLDIR)/LINBIT/DRBD/Connection.pm

html:
	make -C LINBIT/DRBD $@
