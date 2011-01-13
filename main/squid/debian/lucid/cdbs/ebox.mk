DEB_CONFIGURE_SCRIPT_ENV += LOGPATH="/var/log/zentyal"
DEB_CONFIGURE_SCRIPT_ENV += CONFPATH="/var/lib/ebox/conf"
DEB_CONFIGURE_SCRIPT_ENV += STUBSPATH="/usr/share/zentyal-core/stubs"
DEB_CONFIGURE_SCRIPT_ENV += CGIPATH="/usr/share/zentyal-core/cgi/"
DEB_CONFIGURE_SCRIPT_ENV += TEMPLATESPATH="/usr/share/zentyal-core/templates"
DEB_CONFIGURE_SCRIPT_ENV += WWWPATH="/usr/share/zentyal-core/www/"
DEB_CONFIGURE_SCRIPT_ENV += CSSPATH="/usr/share/zentyal-core/www/css"
DEB_CONFIGURE_SCRIPT_ENV += IMAGESPATH="/usr/share/zentyal-core/www/images"
DEB_CONFIGURE_SCRIPT_ENV += VARPATH="/var"
DEB_CONFIGURE_SCRIPT_ENV += ETCPATH="/etc/zentyal"
DEB_CONFIGURE_SCRIPT_ENV += SQUIDCONF="/etc/squid/squid.conf" 

DEB_CONFIGURE_EXTRA_FLAGS := --disable-runtime-tests 
DEB_MAKE_INVOKE = $(MAKE) $(DEB_MAKE_FLAGS) -C $(DEB_BUILDDIR)

$(patsubst %,binary-install/%,$(DEB_PACKAGES)) :: binary-install/%:
	for event in debian/*.upstart ; do \
		install -d -m 755 debian/$(cdbs_curpkg)/etc/init; \
		DESTFILE=$$(basename $$(echo $$event | sed 's/\.upstart/.conf/g')); \
		install -m 644 "$$event" debian/$(cdbs_curpkg)/etc/init/$$DESTFILE; \
	done;

