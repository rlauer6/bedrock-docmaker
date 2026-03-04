#-*- mode: makefile; -*-

PERL_MODULES = \
    lib/Bedrock/DocMaker.pm \
    lib/Bedrock/DocMaker/Git.pm

SHELL := /bin/bash

.SHELLFLAGS := -ec

VERSION := $(shell cat VERSION)

TARBALL = Bedrock-DocMaker-$(VERSION).tar.gz

%.pm: %.pm.in
	sed  's/[@]PACKAGE_VERSION[@]/$(VERSION)/;' $< > $@

$(TARBALL): buildspec.yml $(PERL_MODULES) requires test-requires README.md
	make-cpan-dist.pl -b $<

README.md: lib/Bedrock/DocMaker.pm
	pod2markdown $< > $@

include version.mk

clean:
	rm -f *.tar.gz $(PERL_MODULES)
