GOOSE ?= goose
PREFIX ?= $(HOME)/.local

all: agent-ls

agent-ls: agent_ls.goose agent_ls.build src/fs.c
	$(GOOSE) build agent_ls.goose

test: agent-ls
	bash test/run.sh

install: agent-ls
	install -d "$(PREFIX)/bin"
	install -m 755 agent-ls "$(PREFIX)/bin/agent-ls"

clean:
	rm -f agent-ls

.PHONY: all test install clean
