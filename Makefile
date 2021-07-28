DPKG_ARCH := $(shell dpkg --print-architecture)
#LTS=focal
#BASE := $(LTS)-base-$(DPKG_ARCH).tar.gz
#URL := http://cdimage.ubuntu.com/ubuntu-base/$(LTS)/daily/current/$(BASE)
DEVEL=hirsute
BASE := $(DEVEL)-base-$(DPKG_ARCH).tar.gz
URL := http://cdimage.ubuntu.com/ubuntu-base/daily/current/$(BASE)

# dir that contans the filesystem that must be checked
TESTDIR ?= "prime/"

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
	if [ ! -f ../$(BASE) ]; then \
		wget -P ../ $(URL); \
	fi
	rm -rf $(DESTDIR)
	mkdir -p $(DESTDIR)
	tar -x --xattrs-include=* -f ../$(BASE) -C $(DESTDIR)
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
	/bin/cp $(SNAPCRAFT_PART_INSTALL)/../../consoleconf-deb/install/*.deb $(DESTDIR)/tmp
	# customize
	set -ex; for f in ./hooks/[0-9]*.chroot; do \
		/bin/cp -a $$f $(DESTDIR)/tmp && \
		if ! chroot $(DESTDIR) /tmp/$$(basename $$f); then \
                    exit 1; \
                fi && \
		rm -f $(DESTDIR)/tmp/$$(basename $$f); \
	done;

	# only generate manifest file for lp build
	if [ -e /build/core22 ]; then \
		echo $$f; \
		/bin/cp $(DESTDIR)/usr/share/snappy/dpkg.list /build/core22/core22-$$(date +%Y%m%d%H%M)_$(DPKG_ARCH).manifest; \
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

