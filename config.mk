# st version
VERSION =  22.11
REVISION = 1

DPKG_PKG          = st-term_$(VERSION)-$(REVISION)_amd64
DPKG_TERMINFO_PKG = st-term-terminfo_$(VERSION)-$(REVISION)_amd64

GIT_USER  = $(shell git config --get --local user.name)
GIT_EMAIL = $(shell git config --get --local user.email)

DPKG_PACKAGE     = Package: st-term
DPKG_VERSION     = Version: $(VERSION).$(REVISION)
DPKG_ARCH        = Architecture: amd64
DPKG_MAINTAINER  = Maintainer: $(GIT_USER) <$(GIT_EMAIL)>
DPKG_DESCRIPTION = Description: st-term is a simple terminal emulator fot X.

DPKG_TERMINFO_PACKAGE = Package: st-term-info
DPKG_TERMINFO_DESCRIPTION = Description: st-term-info only contains the terminfo entry.

# Customize below to fit your system

# paths
PREFIX = /usr/local
MANPREFIX = $(PREFIX)/share/man

X11INC = /usr/X11R6/include
X11LIB = /usr/X11R6/lib

PKG_CONFIG = pkg-config

# includes and libs
INCS = -I$(X11INC) \
       `$(PKG_CONFIG) --cflags fontconfig` \
       `$(PKG_CONFIG) --cflags freetype2`
LIBS = -L$(X11LIB) -lm -lrt -lX11 -lutil -lXft \
       `$(PKG_CONFIG) --libs fontconfig` \
       `$(PKG_CONFIG) --libs freetype2`

# flags
STCPPFLAGS = -DVERSION=\"$(VERSION)\" -D_XOPEN_SOURCE=600
STCFLAGS = $(INCS) $(STCPPFLAGS) $(CPPFLAGS) $(CFLAGS)
STLDFLAGS = $(LIBS) $(LDFLAGS)

# OpenBSD:
#CPPFLAGS = -DVERSION=\"$(VERSION)\" -D_XOPEN_SOURCE=600 -D_BSD_SOURCE
#LIBS = -L$(X11LIB) -lm -lX11 -lutil -lXft \
#       `$(PKG_CONFIG) --libs fontconfig` \
#       `$(PKG_CONFIG) --libs freetype2`
#MANPREFIX = ${PREFIX}/man

# compiler and linker
# CC = c99
