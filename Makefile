# dir that contans the filesystem that must be checked
TESTDIR ?= "prime/"
SNAP_NAME=core26
SNAP_BUILD_NAME=core26
CODENAME:="$(shell . /etc/os-release; echo "$$VERSION_CODENAME")"

# include any fips environmental setup if the file exists.
# Variables:
# - SNAP_FIPS_BUILD
# - SNAP_BUILD_NAME
-include .fips-env
ifdef SNAP_FIPS_BUILD
    export SNAP_FIPS_BUILD
    export SNAP_BUILD_NAME
endif

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

	# FIXME: change channel to beta when core26 is there

	if ! snap list "$(SNAP_NAME)" | grep "$(SNAP_NAME)"; then \
		snap install "$(SNAP_NAME)" --edge; \
	else \
		snap refresh "$(SNAP_NAME)" --edge; \
	fi

	# When building through spread there is no .git, which means we cannot
	# generate the changelog in this case, ensure that the current folder is
	# a git repository
	if git rev-parse HEAD && [ -e "/snap/$(SNAP_NAME)/current/usr/share/snappy/dpkg.yaml" ]; then \
		CHG_PARAMS=; \
		if [ -e /build/$(SNAP_BUILD_NAME) ]; then \
			CHG_PARAMS=--launchpad; \
		fi; \
		./tools/generate-changelog.py \
			"/snap/$(SNAP_NAME)/current" \
			"$(DESTDIR)" \
			"$(SNAP_NAME)" \
			$$CHG_PARAMS; \
	else \
		echo "WARNING: changelog will not be generated for this build"; \
	fi

	# only generate manifest and dpkg.yaml files for lp build
	if [ -e /build/$(SNAP_BUILD_NAME) ]; then \
		/bin/cp $(DESTDIR)/usr/share/snappy/dpkg.list /build/$(SNAP_BUILD_NAME)/$(SNAP_NAME)-$$(date +%Y%m%d%H%M)_$(DPKG_ARCH).manifest; \
		/bin/cp $(DESTDIR)/usr/share/snappy/dpkg.yaml /build/$(SNAP_BUILD_NAME)/$(SNAP_NAME)-$$(date +%Y%m%d%H%M)_$(DPKG_ARCH).dpkg.yaml; \
		if [ -e $(DESTDIR)/usr/share/doc/ChangeLog ]; then \
			/bin/cp $(DESTDIR)/usr/share/doc/ChangeLog /build/$(SNAP_BUILD_NAME)/$(SNAP_NAME)-$$(date +%Y%m%d%H%M)_$(DPKG_ARCH).ChangeLog; \
		fi \
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
	done

# Display a report of files that are (still) present in /etc
.PHONY: etc-report
etc-report:
	cd stage && find etc/
	echo "Amount of cruft in /etc left: `find stage/etc/ | wc -l`"

