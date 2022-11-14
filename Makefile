# st - simple terminal
# See LICENSE file for copyright and license details.
.POSIX:

include config.mk

SRC = st.c x.c
OBJ = $(SRC:.c=.o)

all: options st

options:
	@echo st build options:
	@echo "CFLAGS  = $(STCFLAGS)"
	@echo "LDFLAGS = $(STLDFLAGS)"
	@echo "CC      = $(CC)"

config.h:
	cp config.def.h config.h

.c.o:
	$(CC) $(STCFLAGS) -c $<

st.o: config.h st.h win.h
x.o: arg.h config.h st.h win.h

$(OBJ): config.h config.mk

st: $(OBJ)
	$(CC) -o $@ $(OBJ) $(STLDFLAGS)

clean:
	rm -f config.h st $(OBJ) source_code-$(VERSION).tar.gz source_code-$(VERSION).zip
	rm -f $(DPKG_PKG).deb $(DPKG_TERMINFO_PKG).deb

re: clean all

dist: clean deb
	mkdir -p st-$(VERSION)
	cp -R FAQ LEGACY TODO LICENSE Makefile README config.mk\
		config.def.h st.info st.1 arg.h st.h win.h $(SRC)\
		st-$(VERSION)
	tar -cf - st-$(VERSION) | gzip > source_code-$(VERSION).tar.gz
	zip source_code-$(VERSION).zip -r st-$(VERSION)
	rm -rf st-$(VERSION)

install: st
	mkdir -p $(DESTDIR)$(PREFIX)/bin
	cp -f st $(DESTDIR)$(PREFIX)/bin
	chmod 755 $(DESTDIR)$(PREFIX)/bin/st
	mkdir -p $(DESTDIR)$(MANPREFIX)/man1
	sed "s/VERSION/$(VERSION)/g" < st.1 > $(DESTDIR)$(MANPREFIX)/man1/st.1
	chmod 644 $(DESTDIR)$(MANPREFIX)/man1/st.1
	tic -sx st.info
	@echo Please see the README file regarding the terminfo entry of st.

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/st
	rm -f $(DESTDIR)$(MANPREFIX)/man1/st.1

$(DPKG_PKG).deb: st
	mkdir -p $(DPKG_PKG)/usr/local/bin \
		$(DPKG_PKG)/usr/share/applications \
		$(DPKG_PKG)/usr/share/doc/st-term/ \
		$(DPKG_PKG)/usr/share/man/man1/ \
		$(DPKG_PKG)/DEBIAN
	cp st $(DPKG_PKG)/usr/local/bin/st-term
	chmod 755 $(DPKG_PKG)/usr/local/bin/st-term
	cp st-term.desktop $(DPKG_PKG)/usr/share/applications
	cp LICENSE $(DPKG_PKG)/usr/share/doc/st-term/copyright
	sed "s/VERSION/$(VERSION)/g" < st.1 > $(DPKG_PKG)/usr/share/man/man1/st-term.1
	chmod 644 $(DPKG_PKG)/usr/share/man/man1/st-term.1
	gzip $(DPKG_PKG)/usr/share/man/man1/st-term.1
	@echo "$(DPKG_PACKAGE)"     >  $(DPKG_PKG)/DEBIAN/control
	@echo "$(DPKG_VERSION)"     >> $(DPKG_PKG)/DEBIAN/control
	@echo "$(DPKG_ARCH)"        >> $(DPKG_PKG)/DEBIAN/control
	@echo "$(DPKG_MAINTAINER)"  >> $(DPKG_PKG)/DEBIAN/control
	@echo "$(DPKG_DESCRIPTION)" >> $(DPKG_PKG)/DEBIAN/control
	dpkg-deb --build --root-owner-group $(DPKG_PKG)
	rm -rf $(DPKG_PKG)

$(DPKG_TERMINFO_PKG).deb:
	mkdir -p $(DPKG_TERMINFO_PKG)/usr/share/terminfo \
		$(DPKG_TERMINFO_PKG)/usr/share/doc/st-term/ \
		$(DPKG_TERMINFO_PKG)/DEBIAN
	cp LICENSE $(DPKG_TERMINFO_PKG)/usr/share/doc/st-term/copyright
	tic -o$(DPKG_TERMINFO_PKG)/usr/share/terminfo -sx st.info
	@echo "$(DPKG_TERMINFO_PACKAGE)"     >  $(DPKG_TERMINFO_PKG)/DEBIAN/control
	@echo "$(DPKG_VERSION)"              >> $(DPKG_TERMINFO_PKG)/DEBIAN/control
	@echo "$(DPKG_ARCH)"                 >> $(DPKG_TERMINFO_PKG)/DEBIAN/control
	@echo "$(DPKG_MAINTAINER)"           >> $(DPKG_TERMINFO_PKG)/DEBIAN/control
	@echo "$(DPKG_TERMINFO_DESCRIPTION)" >> $(DPKG_TERMINFO_PKG)/DEBIAN/control
	dpkg-deb --build --root-owner-group $(DPKG_TERMINFO_PKG)
	rm -rf $(DPKG_TERMINFO_PKG)

deb: $(DPKG_PKG).deb $(DPKG_TERMINFO_PKG).deb

.PHONY: all re dpkg options clean dist install uninstall
