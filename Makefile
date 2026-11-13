GOOSE ?= goose
PREFIX ?= $(HOME)/.local

all: al

al: al.goose al.build src/fs.c
	$(GOOSE) build al.goose

test: al
	bash test/run.sh

install: al
	install -d "$(PREFIX)/bin"
	install -m 755 al "$(PREFIX)/bin/al"

clean:
	rm -f al

.PHONY: all test install clean
