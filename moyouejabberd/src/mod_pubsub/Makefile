# $Id$

CC = gcc
CFLAGS = -g -O2 -Wall 
CPPFLAGS = -I/usr/local/ssl/include -g -O2 -Wall 
LDFLAGS = 
LIBS = 

ERLANG_CFLAGS = -I/usr/lib64/erlang/lib/erl_interface-3.7.1/include -I/usr/lib64/erlang/usr/include
ERLANG_LIBS = -L/usr/lib64/erlang/lib/erl_interface-3.7.1/lib -lerl_interface -lei

Transform = '{parse_transform, lager_transform}'
EFLAGS += -I .. +$(Transform)
EFLAGS += -pz ..

# make debug=true to compile Erlang module with debug informations.
ifdef debug
	EFLAGS+=+debug_info +export_all
endif

OUTDIR = ..
ERLBEHAVS = gen_pubsub_node.erl gen_pubsub_nodetree.erl
SOURCES_ALL = $(wildcard *.erl)
SOURCES = $(filter-out $(ERLBEHAVS),$(SOURCES_ALL))
ERLBEHAVBEAMS = $(addprefix $(OUTDIR)/,$(ERLBEHAVS:.erl=.beam))
BEAMS = $(addprefix $(OUTDIR)/,$(SOURCES:.erl=.beam))


all: mod_pubsub_odbc.erl $(ERLBEHAVBEAMS) $(BEAMS)

$(BEAMS): $(ERLBEHAVBEAMS)

$(OUTDIR)/%.beam:       %.erl
	/usr/bin/erlc -W $(EFLAGS) -o $(OUTDIR) $<

clean:
	rm -f $(BEAMS)

distclean: clean
	rm -f Makefile

mod_pubsub_odbc.erl:
	patch -o mod_pubsub_odbc.erl mod_pubsub.erl pubsub_odbc.patch

TAGS:
	etags *.erl

