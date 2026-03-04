
########################################################################
# INSTRUCTIONS:
########################################################################
# 1. Drop this makefile snippet it into your Makefile or Makefile.am
#    
#    echo -e "\ninclude .bedrock-docmaker.mk" >> "Makefile"
#
########################################################################
# NOTES:
########################################################################
#  - .bedrock-docmaker/README.roc is the HTML wrapper...you can edit
#    this after it is fetched for the first time, but add it to YOUR
#    project as an artifact
#
#  - Dependencies:
#
#    - md-utils
#    - bedrock-docmaker
#    - bedrock
#
########################################################################

DOCMAKER = "perl -I ~/git/bedrock-docmaker/lib ~/git/bedrock-docmaker/lib/Bedrock/DocMaker.pm"
#DOCMAKER = $(shell command -v bedrock-docmaker)
MD_UTILS = $(shell command -v md-utils)
BEDROCK  = $(shell command -v bedrock)

########################################################################
# Your project's README.md.in
########################################################################
README = \
    README.md.in

MARKDOWN=$(README:.md.in=.md)

INC=$(MARKDOWN:.md=.inc)

$(MARKDOWN): % : %.in
	$(MD_UTILS) $< > $@ || (rm -f $@ && false);

$(INC): $(MARKDOWN)
	$(MD_UTILS) -r -R $< > $@ || (rm -f $@ && false);


########################################################################
# HTML wrapper for your README, customize if you want
########################################################################
WRAPPER = \
    .bedrock-docmaker/README.roc

HTML = README.html

# This uses the wrapper .bedrock-docmaker/README.roc to create README.html
$(HTML): $(WRAPPER) $(INC)
	$(DOCMAKER) create-index > $@

PHONY: html

html: $(HTML)

index.html: html
	$(DOCMAKER) create-index > $@
	$(DOCMAKER) put $@

PHONY: publish
publish: $(HTML) index.html
	$(DOCMAKER) put-component $<

PHONY: update-css
update-css: .bedrock-docmaker/style.css
	$(DOCMAKER) put-component $<

PHONY: update-wrapper
update-wrapper: $(WRAPPER)
	$(DOCMAKER) put-component $<

CLEANFILES += \
    $(INC) \
    $(MARKDOWN) \
    $(HTML) \
    index.html \
    bedrock.log

########################################################################
# You should have a clean target...but if you don't uncomment this
# section
########################################################################
#clean:
#	for a in $(CLEANFILES); do \
#	  if test -e "$$a"; then \
#	    rm -f $$a; \
#	  fi; \
#	done
