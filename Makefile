# ---------------------------------------
# Author: David Marsh <rdmarsh@gmail.com>
# ---------------------------------------
#
# This Makefile is used to generate files for elm
#   for usage: make help
#   more info: make about
#
# elm Extract LogicMonitor
# Copyright (C) 2021--2022 David Marsh rdmarsh@gmail.com
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

# MAKE FLAGS
#MAKEFLAGS += -j4

# FILE EXTENSIONS
# ---------------------------------------
# change only if needed

JSN = json
J2 = j2

# SOURCE DIR and FILENAMES
# ---------------------------------------
# change only if needed

name := elm
prog := $(name).py

bakdir := ../$(name)_back
cmddir := _cmds
defdir := _defs
jnjdir := _jnja

# EXECUTABLE AND PROGRAM FLAGS
# ---------------------------------------
# change only if needed

CURL ?= curl
JQ ?= jq
AWK ?= awk
JINJA ?= jinja2

# for testing non-required commands
GREP ?= grep
GREPFLAGS += -l

# for backup
TAR ?= tar
TARFLAGS += -cvf

lm_swagger_url := https://www.logicmonitor.com/swagger-ui-master/dist/swagger.json

# BUILD SOURCE AND TARGTS
# ---------------------------------------
# do not change

CMDSOURCES := $(wildcard $(defdir)/[A-Z]*.$(JSN))
CMDTARGETS := $(patsubst $(defdir)/%.$(JSN),$(cmddir)/%.py,$(CMDSOURCES))

TSTTARGETS := $(patsubst $(defdir)/%.$(JSN),%,$(CMDSOURCES))
REQSOURCES := $(patsubst $(defdir)/%.$(JSN),%,$$(shell $(GREP) $(GREPFLAGS) "\"required\":true" $(CMDSOURCES)))

NONREQTARGETS := $(filter-out $(REQSOURCES),$(TSTTARGETS))
NONREQTARGETS := $(filter-out ExternalApiStats,$(NONREQTARGETS))

# COLOUR OUTPUT
# ---------------------------------------
# do not change

NO_COLOR=\x1b[0m
OK_COLOR=\x1b[32;01m
OK_STRING=$(OK_COLOR)[OK]$(NO_COLOR)

# TARGETS
# ---------------------------------------
# do not change

.PHONY: all
all: init cmds cfg ## Build everything (init, cmds, cfg)
	@echo "$@ $(OK_STRING)"

# INIT FOR COMPILE
# =======================================
# do not change

.PHONY: init
init: reqs $(bakdir) $(cmddir) $(defdir) $(defdir)/commands.$(JSN) ## Initialise dirs, get swagger file, create definition files
	@echo "$@ $(OK_STRING)"

.PHONY: reqs PYTHON-exists CURL-exists JQ-exists AWK-exists JINJA-exists GREP-exists TAR-exists
reqs: PYTHON-exists CURL-exists JQ-exists AWK-exists JINJA-exists GREP-exists TAR-exists
	@echo "$@ $(OK_STRING)"
PYTHON-exists: ; @which python3 > /dev/null
CURL-exists: ; @which $(CURL) > /dev/null
JQ-exists: ; @which $(JQ) > /dev/null
AWK-exists: ; @which $(AWK) > /dev/null
JINJA-exists: ; @which $(JINJA) > /dev/null
GREP-exists: ; @which $(GREP) > /dev/null
TAR-exists: ; @which $(TAR) > /dev/null

$(bakdir) $(cmddir) $(defdir):
	mkdir -p $@
	@echo "$@ $(OK_STRING)"

$(defdir)/swagger.$(JSN): $(defdir)
	$(CURL) $(lm_swagger_url) $(OUTPUT_OPTION)
	@echo "$@ $(OK_STRING)"

# The commands.json file isn't used, but it's handy to trigger when the
# individual defs also need to be (re)built as we don't the names of the
# individual def files at this stage and CMDSOURCES isn't populated.
# There's probably a better way to do this, but this will do for now
#
# First jq creates commands.json from swagger.json file
# Second jq creates individual def json files from swagger.json file
# make called again so we don't have to call make manually after all defs have been created
#
# cant split these long lines, high level magic
# https://stackoverflow.com/questions/56167046/jq-split-a-huge-json-of-array-and-save-into-file-named-with-a-value
$(defdir)/commands.$(JSN): $(defdir)/swagger.$(JSN)
	$(JQ) '{ "commands": [ .paths | to_entries[] | .key as $$path | .value | to_entries[] | select(.key == "get") | .value.operationId as $$opid | .value.operationId |= gsub("^(get|collect)";"") | { opid:$$opid, command:.value.operationId, path:$$path, summary:.value.summary, tag:.value.tags[0], options:.value.parameters } ]}' $< > $@
	$(JQ) -c '.commands[] | (.command | if type == "number" then . else tostring | gsub("[^A-Za-z0-9-_]";"+") end), .' $@ | $(AWK) 'function fn(s) { sub(/^"/,"",s); sub(/"$$/,"",s); return "$(defdir)/" s ".$(JSN)"; } NR%2{f=fn($$0); next} {print > f; close(f);} '
	$(MAKE)
	@echo "$@ $(OK_STRING)"

.PHONY: cfg
cfg: ~/.$(name)/config.example.ini ## Create config dir, copy example file and set permissions of all config files
	@echo "$@ $(OK_STRING)"

~/.$(name)/config.example.ini: config.example.ini
	mkdir -p $(@D)
	chmod 700 $(@D)
	cp $< $@
	chmod 600 $(@D)/*
	chown $$(id -u):$$(id -g) $(@D)
	@if [ ! -s $(@D)/config.ini ] ; then \
		echo ;\
		echo "$(OK_COLOR)>>> now do the below and edit to taste <<<$(NO_COLOR)" ;\
		echo ;\
		echo "$(OK_COLOR)cp $@ $(@D)/config.ini$(NO_COLOR)" ;\
		echo "$(OK_COLOR)vi $(@D)/config.ini$(NO_COLOR)" ;\
		echo ;\
		echo ;\
	fi
	@echo "$(@F) $(OK_STRING)"


# BUILD COMMANDS
# =======================================
# do not change

.PHONY: cmds
cmds: engine.py $(name) ## Make python commands from templates
	@echo "$@ $(OK_STRING)"

$(name): $(prog)
	ln -sf $< $@
	@echo "$@ $(OK_STRING)"

$(prog): $(jnjdir)/$(prog).$(J2) $(defdir)/commands.$(JSN) $(CMDTARGETS)
	$(JINJA) $(jnjdir)/$(prog).$(J2) $(defdir)/commands.$(JSN) $(OUTPUT_OPTION)
	chmod 755 $@
	@echo "$@ $(OK_STRING)"

engine.py: $(jnjdir)/engine.py.$(J2) $(defdir)/commands.$(JSN)
	$(JINJA) $^ $(OUTPUT_OPTION)
	@echo "$@ $(OK_STRING)"

$(cmddir)/%.py: $(jnjdir)/command.py.$(J2) $(defdir)/%.$(JSN)
	$(JINJA) $^ $(OUTPUT_OPTION)
	@echo "$@ $(OK_STRING)"

# TESTS
# =======================================
# do not change

.PHONY: test
test: testbasic testfmts testverb testid ## Run quick and simple tests
	@echo "$@ $(OK_STRING)"

.PHONY: testlong
testlong: testhelp testcount testtotal ## Tests that take a long time to complete
	@echo "$@ $(OK_STRING)"

.PHONY: testbasic
testbasic: ## Test basic flags
	@echo testing: ./$(name) ; ./$(name) >/dev/null
	@echo testing: ./$(name) --help ; ./$(name) --help >/dev/null
	@echo testing: ./$(name) --version ; ./$(name) --version >/dev/null
	@echo "$@ $(OK_STRING)"

.PHONY: testhelp
testhelp: ## Test all commands with help flag
	@$(foreach cmd,$(TSTTARGETS), \
		echo testing: ./$(name) $(cmd) --help ;\
		./$(name) $(cmd) --help >/dev/null || exit ;\
		)
	@echo "$@ $(OK_STRING)"

.PHONY: testid
testid: ## Test one command with an id flag             (connects to LM)
	@echo testing: ./$(name) AdminById --id 2 ; ./$(name) AdminById --id 2 ;
	@echo "$@ $(OK_STRING)"

.PHONY: testcount
testcount: ## Test 'non-required' commands with count flag (connects to LM)
	@$(foreach cmd,$(NONREQTARGETS), \
		echo testing: ./$(name) $(cmd) -c ;\
		./$(name) $(cmd) -c || exit ;\
		)
	@echo "$@ $(OK_STRING)"

.PHONY: testtotal
testtotal: ## Test 'non-required' commands with total flag (connects to LM)
	@$(foreach cmd,$(NONREQTARGETS), \
		echo testing: ./$(name) $(cmd) -C ;\
		./$(name) $(cmd) -C || exit ;\
		)
	@echo "$@ $(OK_STRING)"

.PHONY: testfmts
testfmts: ## Test one command with all formats            (connects to LM)
	@echo testing: ./$(name) --output csv        MetricsUsage ; ./$(name) --output csv        MetricsUsage
	@echo testing: ./$(name) --output html       MetricsUsage ; ./$(name) --output html       MetricsUsage
	@echo testing: ./$(name) --output prettyhtml MetricsUsage ; ./$(name) --output prettyhtml MetricsUsage
	@echo testing: ./$(name) --output json       MetricsUsage ; ./$(name) --output json       MetricsUsage
	@echo testing: ./$(name) --output prettyjson MetricsUsage ; ./$(name) --output prettyjson MetricsUsage
	@echo testing: ./$(name) --output latex      MetricsUsage ; ./$(name) --output latex      MetricsUsage
	@echo testing: ./$(name) --output raw        MetricsUsage ; ./$(name) --output raw        MetricsUsage
	@echo testing: ./$(name) --output txt        MetricsUsage ; ./$(name) --output txt        MetricsUsage
	@echo "$@ $(OK_STRING)"

.PHONY: testverb
testverb: ## Test the verbose flags                       (connects to LM)
	@echo testing: ./$(name) -v  MetricsUsage ; ./$(name) -v  MetricsUsage
	@echo testing: ./$(name) -vv MetricsUsage ; ./$(name) -vv MetricsUsage
	@echo "$@ $(OK_STRING)"

.PHONY: fail
fail: ## a failing test
	@echo test false ; false >/dev/null

# BACKUP
# =======================================
# do not change

.PHONY: back
back: nomac $(bakdir) TAR-exists ## TAR and backup (eg ../name_backup/name.YYYY-MM-DD.tar.gz)
	$(TAR) $(TARFLAGS) $(bakdir)/$(name).$(shell date +%Y-%m-%d).tar.gz .
	@echo "$@ $(OK_STRING)"

.PHONY: clean
clean: nomac ## Remove generated files
	$(RM) -r __pycache__
	$(RM) -r $(cmddir) $(defdir)
	$(RM) $(CMDTARGETS)
	$(RM) $(name)
	$(RM) $(prog)
	$(RM) engine.py
	@echo "$@ $(OK_STRING)"

.PHONY: nomac
nomac: ## Remove unneeded mac files
	$(RM) .DS_Store
	@echo "$@ $(OK_STRING)"

# ABOUT COPY HELP
# =======================================
# do not change

.PHONY: about
about: ## About this Makefile
	@echo
	@echo 'This Makefile is used to generate files for elm'
	@echo
	@echo 'Run "make help" to for how to run'
	@echo
	@echo 'See https://github.com/rdmarsh/elm'
	@echo

.PHONY: copying
copying: ## Copyright notice
	@echo
	@echo 'Copyright (C) 2021--2022 David Marsh'
	@echo 'rdmarsh@gmail.com'
	@echo
	@echo 'This program is free software: you can redistribute it and/or modify'
	@echo 'it under the terms of the GNU General Public License as published by'
	@echo 'the Free Software Foundation, either version 3 of the License, or'
	@echo '(at your option) any later version.'
	@echo
	@echo 'This program comes with ABSOLUTELY NO WARRANTY.'
	@echo 'This is free software, and you are welcome to redistribute it'
	@echo 'under certain conditions. View the file "LICENSE" for details.'
	@echo

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage: make [flags] [option]\n"} /^[$$()% \.0-9a-zA-Z_-]+:.*?##/ { printf "  \033[36mmake %-12s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)
	@echo
	@echo 'Useful make flags:'
	@echo '  make -n  dry run'
	@echo '  make -j  run simultaneous jobs'
	@echo '  make -B  force make target'
	@echo
