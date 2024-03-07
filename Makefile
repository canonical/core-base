# dir that contans the filesystem that must be checked
TESTDIR ?= "prime/"
SNAP_NAME=core24
BUILDDIR=/build/$(SNAP_NAME)

.PHONY: all
all: check
	# nothing

.PHONY: install
install:
	# install base
	set -ex; if [ -z "$(DESTDIR)" ]; then \
		echo "no DESTDIR set"; \
		exit 1; \
	fi
	rm -rf $(DESTDIR)
	cp -aT $(CRAFT_STAGE)/base $(DESTDIR)
	# ensure resolving works inside the chroot
	cat /etc/resolv.conf > $(DESTDIR)/etc/resolv.conf
	# copy-in launchpad's build archive
	if grep -q ftpmaster.internal /etc/apt/sources.list; then \
		cp /etc/apt/sources.list $(DESTDIR)/etc/apt/sources.list; \
		cp /etc/apt/trusted.gpg $(DESTDIR)/etc/apt/ || true; \
		cp -r /etc/apt/trusted.gpg.d $(DESTDIR)/etc/apt/ || true; \
	fi
	# since recently we're also missing some /dev files that might be
	# useful during build - make sure they're there
	[ -e $(DESTDIR)/dev/null ] || mknod -m 666 $(DESTDIR)/dev/null c 1 3
	[ -e $(DESTDIR)/dev/zero ] || mknod -m 666 $(DESTDIR)/dev/zero c 1 5
	[ -e $(DESTDIR)/dev/random ] || mknod -m 666 $(DESTDIR)/dev/random c 1 8
	[ -e $(DESTDIR)/dev/urandom ] || \
		mknod -m 666 $(DESTDIR)/dev/urandom c 1 9
	# copy static files verbatim
	/bin/cp -a static/* $(DESTDIR)
	mkdir -p $(DESTDIR)/install-data
	# customize
	set -eux; for f in ./hooks/[0-9]*.chroot; do		\
		base="$$(basename "$${f}")";			\
		cp -a "$${f}" $(DESTDIR)/install-data/;		\
		chroot $(DESTDIR) "/install-data/$${base}";	\
		rm "$(DESTDIR)/install-data/$${base}";		\
	done
	rm -rf $(DESTDIR)/install-data

	# see https://github.com/systemd/systemd/blob/v247/src/shared/clock-util.c#L145
	touch $(DESTDIR)/usr/lib/clock-epoch

	# only generate manifest and dpkg.yaml files for lp build
	if [ -e $(BUILDDIR) ]; then \
		/bin/cp $(DESTDIR)/usr/share/snappy/dpkg.list $(BUILDDIR)/$(SNAP_NAME)-$$(date +%Y%m%d%H%M)_$(DPKG_ARCH).manifest; \
		/bin/cp $(DESTDIR)/usr/share/snappy/dpkg.yaml $(BUILDDIR)/$(SNAP_NAME)-$$(date +%Y%m%d%H%M)_$(DPKG_ARCH).dpkg.yaml; \
	fi;

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
	    	done; \
	set -ex; for f in $$(pwd)/tests/test_*.sh; do \
		sh -e $$f; \
	done

# Display a report of files that are (still) present in /etc
.PHONY: etc-report
etc-report:
	cd stage && find etc/
	echo "Amount of cruft in /etc left: `find stage/etc/ | wc -l`"

