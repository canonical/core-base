# dir that contans the filesystem that must be checked
TESTDIR ?= "prime/"
SNAP_NAME=core22
SNAP_BUILD_NAME=core22
SNAP_CORE_TRACK:=latest
CODENAME:="$(shell . /etc/os-release; echo "$$VERSION_CODENAME")"

# include any fips environmental setup if the file exists.
# Variables:
# - SNAP_FIPS_BUILD
# - SNAP_CORE_TRACK
# - SNAP_BUILD_NAME
-include .fips-env
ifdef SNAP_FIPS_BUILD
    export SNAP_FIPS_BUILD
    export SNAP_CORE_TRACK
    export SNAP_BUILD_NAME
endif

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
ifdef SNAP_FIPS_BUILD
	# copy the FIPS PPA config file in if it exists and if
	# the current build is a FIPS build
	if [ -e ./fips.conf ]; then \
		mkdir -p $(DESTDIR)/etc/apt/auth.conf.d/; \
		cp ./fips.conf $(DESTDIR)/etc/apt/auth.conf.d/01-fips.conf; \
	fi    

	# If we are doing a fips build, make sure updates are enabled
	# and we export that to the hooks
	sed -n 's/$(CODENAME)-security/$(CODENAME)-updates/p' /etc/apt/sources.list >> $(DESTDIR)/etc/apt/sources.list;
endif
	mkdir -p $(DESTDIR)/install-data
	/bin/cp -r $(CRAFT_STAGE)/local-debs $(DESTDIR)/install-data/local-debs
	/bin/cp -r patch $(DESTDIR)/install-data
	# customize
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

	# For FIPS we need to to install the one in fips-updates and check against it
	if ! snap list "$(SNAP_NAME)" | grep "$(SNAP_NAME)"; then \
		snap install "$(SNAP_NAME)" --channel=$(SNAP_CORE_TRACK)/beta; \
	else \
		snap refresh "$(SNAP_NAME)" --channel=$(SNAP_CORE_TRACK)/beta; \
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
	if [ -e /build/"$(SNAP_BUILD_NAME)" ]; then \
		/bin/cp $(DESTDIR)/usr/share/snappy/dpkg.list /build/$(SNAP_BUILD_NAME)/$(SNAP_NAME)-$$(date +%Y%m%d%H%M)_$(DPKG_ARCH).manifest; \
		/bin/cp $(DESTDIR)/usr/share/snappy/dpkg.yaml /build/$(SNAP_BUILD_NAME)/$(SNAP_NAME)-$$(date +%Y%m%d%H%M)_$(DPKG_ARCH).dpkg.yaml; \
		if [ -e $(DESTDIR)/usr/share/doc/ChangeLog ]; then \
			/bin/cp $(DESTDIR)/usr/share/doc/ChangeLog /build/$(SNAP_BUILD_NAME)-$$(date +%Y%m%d%H%M)_$(DPKG_ARCH).ChangeLog; \
		fi \
	fi;

	# after generating changelogs we can cleanup those bits
	# from the base
	find "$(DESTDIR)/usr/share/doc/" -name 'changelog.Debian.gz' -print -delete
	find "$(DESTDIR)/usr/share/doc/" -name 'changelog.gz' -print -delete

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

