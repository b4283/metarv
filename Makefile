PROGRAM = metarv
SRC = metarv.vala
PKGS = --pkg posix --pkg gio-2.0
VALAC = valac
VALAC_OPTS = --enable-experimental --enable-checking

all:
	@$(VALAC) $(VALAC_OPTS) $(PKGS) $(SRC)
