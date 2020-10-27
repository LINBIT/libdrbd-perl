.PHONY: checkvars
checkvars:
ifndef HTMLS
	$(error HTMLS not set)
endif
ifndef HTMLDOCDIR
	$(error HTMLDOCDIR not set)
endif

$(HTMLDOCDIR)/%.html: %.pm
	 pod2html --infile=$< --outfile=$@

html: checkvars $(HTMLS)
