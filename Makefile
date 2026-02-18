# dir that contans the filesystem that must be checked
TESTDIR ?= "prime/"
SNAP_NAME=core26
SNAP_BUILD_NAME=core26
CODENAME:="$(shell . /etc/os-release; echo "$$VERSION_CODENAME")"

.PHONY: all
all: check
	# nothing

.PHONY: install
install:
	set -ex; if [ -z "$(DESTDIR)" ]; then \
		echo "no DESTDIR set"; \
		exit 1; \
	fi
	rm -rf $(DESTDIR)
	cp -a $(CRAFT_STAGE)/base $(DESTDIR)
	
	# copy static files verbatim
	/bin/cp -a static/* $(DESTDIR)

	# since recently we're also missing some /dev files that might be
	# useful during build - make sure they're there
	mkdir -p $(DESTDIR)/dev
	[ -e $(DESTDIR)/dev/null ] || mknod -m 666 $(DESTDIR)/dev/null c 1 3
	[ -e $(DESTDIR)/dev/zero ] || mknod -m 666 $(DESTDIR)/dev/zero c 1 5
	[ -e $(DESTDIR)/dev/random ] || mknod -m 666 $(DESTDIR)/dev/random c 1 8
	[ -e $(DESTDIR)/dev/urandom ] || \
		mknod -m 666 $(DESTDIR)/dev/urandom c 1 9
	
	# create a symlink from /usr/bin to /bin, we need
	# this for the hooks to work properly
	if ! [ -e $(DESTDIR)/bin ]; then \
		ln -sf usr/bin $(DESTDIR)/bin; \
	fi

	# symlink bash to sh if not already present, otherwise we wont be able
	# to run the hooks, this has not been done for us by the chisel slices
	# as you may choose your own /bin/sh implementation
	if ! [ -e $(DESTDIR)/bin/sh ]; then \
		ln -sf bash $(DESTDIR)/bin/sh; \
	fi

	# create install-data for hooks
	mkdir -p $(DESTDIR)/install-data

.PHONY: hooks
hooks:
	set -ex; if [ -z "$(DESTDIR)" ]; then \
		echo "no DESTDIR set"; \
		exit 1; \
	fi

	set -eux; for f in ./hooks/[0-9]*.chroot; do		\
		base="$$(basename "$${f}")";			\
		cp -a "$${f}" $(DESTDIR)/install-data/;		\
		chroot $(DESTDIR) "/install-data/$${base}";	\
		rm "$(DESTDIR)/install-data/$${base}";		\
	done
	rm -rf $(DESTDIR)/install-data

	# remove the auth file again
	rm -f $(DESTDIR)/etc/apt/auth.conf.d/01-fips.conf

	# see https://github.com/systemd/systemd/blob/v247/src/shared/clock-util.c#L145
	touch $(DESTDIR)/usr/lib/clock-epoch

	# TODO: Update the changelog generation to support chisel builds.

	# TODO: Coordinate with the LP team that we now produce chisel artifacts
	

.PHONY: check
check:
	# exclude "useless cat" from checks, while useless they also make
	# some code more readable
	shellcheck -e SC2002 hooks/*

.PHONY: test
test:
	# run tests - each hook should have a matching ".test" file
	set -ex; if [ ! -d $(TESTDIR) ]; then \
		echo "no $(TESTDIR) found, please build the tree first "; \
		exit 1; \
	fi
	set -ex; for f in $$(pwd)/hook-tests/[0-9]*.test; do \
			if !(cd $(TESTDIR) && $$f); then \
				exit 1; \
			fi; \
	done

# Display a report of files that are (still) present in /etc
.PHONY: etc-report
etc-report:
	cd stage && find etc/
	echo "Amount of cruft in /etc left: `find stage/etc/ | wc -l`"

