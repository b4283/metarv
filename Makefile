PREFIX = /usr
DATA_DIR = .
#$(PREFIX)/share/metarv

DESTDIR =

PROGRAM = metarv
SRC = metarv.vala
PKGS = --pkg posix --pkg gio-2.0 --pkg config --vapidir . -X -I.
VALAC = valac
VALAC_OPTS = --enable-experimental --enable-checking

all: metarv

metarv: metarv.vala stations.gz
	echo "#define DATA_DIR \"$(DATA_DIR)\"" > config.h
	@$(VALAC) $(VALAC_OPTS) $(PKGS) $(SRC)

clean:
	rm metarv

install: all
	mkdir -p $(DESTDIR)$(DATA_DIR)
	mkdir -p $(DESTDIR)$(PREFIX)/bin
	cp metarv $(DESTDIR)$(PREFIX)/bin
	cp stations.gz $(DESTDIR)$(DATA_DIR)
