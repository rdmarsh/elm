# ---------------------------------------
# Author: David Marsh <rdmarsh@gmail.com>
# ---------------------------------------
#
# This Makefile is used to generate files for elm
#   for usage: make help
#   more info: make about
#
# elm Extract LogicMonitor
# Copyright (C) 2021--2024 David Marsh rdmarsh@gmail.com
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

# API VERSION
# ---------------------------------------
# set to '3' to use api v3, anything else will use v2
apiversion ?= 3

# FILE EXTENSIONS
# ---------------------------------------
# change only if needed

JSN ?= json
J2 ?= j2
PY ?= py

# SOURCE DIR and FILENAMES
# ---------------------------------------
# change only if needed

name := elm
prog := $(name).$(PY)

bakdir := ../$(name)_back
cfgdir := ~/.$(name)
cmddir := _cmds
defdir := _defs
jnjdir := _jnja

# EXECUTABLE AND PROGRAM FLAGS
# ---------------------------------------
# change only if needed

CURL ?= curl
JQ ?= jq
AWK ?= awk
JINJA ?= venv/bin/jinja2

# for testing non-required commands
GREP ?= grep
GREPFLAGS += -l

# for backup
TAR ?= tar
TARFLAGS += -cvf

#python
PYTHON ?= python3

# venv location
VENV := venv

# pip for install
PIP ?= $(VENV)/bin/$(PYTHON) -m pip
PIPFLAGS += install

# for pyinstaller
pyiworkdir := _build
pyidistdir := _dist
PYINST ?= $(VENV)/bin/pyinstaller 
PYINSTFLAGS += --workpath $(pyiworkdir) --distpath $(pyidistdir) --noconfirm --clean

ifneq ($(apiversion),3)
apiversion = 2
endif

ifeq ($(apiversion),3)
lm_swagger_url := https://www.logicmonitor.com/swagger-ui-master/api-v3/dist/swagger.json
else
lm_swagger_url := https://www.logicmonitor.com/swagger-ui-master/dist/swagger.json
endif

# BUILD SOURCE AND TARGTS
# ---------------------------------------
# do not change

CMDSOURCES := $(wildcard $(defdir)/[A-Z]*.$(JSN))
CMDTARGETS := $(patsubst $(defdir)/%.$(JSN),$(cmddir)/%.$(PY),$(CMDSOURCES))

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
all: init cmds cfg ## Build everything except install (init, cmds, cfg)
	@echo "$@ $(OK_STRING)"

# INIT FOR COMPILE
# =======================================
# do not change
 
.PHONY: init
init: $(defdir)/commands.$(JSN) | PYTHON-exists ## Check prerequisites, initialise dirs, get swagger file, create definition files
	@echo "$@ $(OK_STRING)"

# REQ FOR COMPILE
# =======================================
# do not change

.PHONY: PYTHON-exists CURL-exists JINJA-exists JQ-exists
PYTHON-exists: ; which $(PYTHON)
CURL-exists: ; which $(CURL)
JINJA-exists: ; which $(JINJA)
JQ-exists: ; which $(JQ)

# REQ DIRS
# =======================================
# do not change

$(bakdir) $(cmddir) $(defdir) $(cfgdir):
	mkdir -p $@
	chown $$(id -u):$$(id -g) $@
	chmod 700 $@
	@echo "$@ $(OK_STRING)"

# The commands.json file isn't used, but it's handy to trigger when the
# individual defs also need to be (re)built as we don't know the names of the
# individual def files at this stage and CMDSOURCES isn't populated.  There's
# probably a better way to do this, but this will do for now
#
# First jq creates commands.json from swagger.json file
# Second jq creates individual def json files from swagger.json file
# MAKE called again so we don't have to call make manually after all defs have been created
#
# cant split these long lines, high level magic
# https://stackoverflow.com/questions/56167046/jq-split-a-huge-json-of-array-and-save-into-file-named-with-a-value

$(defdir)/commands.$(JSN): $(defdir)/swagger.$(JSN) $(MAKEFILE_LIST) | $(defdir) JQ-exists
	$(JQ) '{ "commands": [ .paths | to_entries[] | .key as $$path | .value | to_entries[] | select(.key == "get") | .value.operationId as $$opid | .value.operationId |= gsub("^(get|collect|fetch)";"") | { opid:$$opid, command:.value.operationId, path:$$path, summary:.value.summary, tag:.value.tags[0], options:.value.parameters } ]}' $< > $@
	$(JQ) -c '.commands[] | (.command | if type == "number" then . else tostring | gsub("[^A-Za-z0-9-_]";"+") end), .' $@ | $(AWK) 'function fn(s) { sub(/^"/,"",s); sub(/"$$/,"",s); return "$(defdir)/" s ".$(JSN)"; } NR%2{f=fn($$0); next} {print > f; close(f);} '
	@echo "$@ $(OK_STRING)"
	$(MAKE)

$(defdir)/swagger.$(JSN): $(MAKEFILE_LIST) | $(defdir) CURL-exists
	$(CURL) $(lm_swagger_url) $(OUTPUT_OPTION)
	@echo "$@ $(OK_STRING)"

.PHONY: cfg
cfg: $(cfgdir)/config.example.ini ## Create config dir, copy example file and set permissions of all config files
	@echo "$@ $(OK_STRING)"

$(cfgdir)/config.example.ini: config.example.ini | $(cfgdir)
	cp $< $@
	chmod 600 $(@D)/*
	@if [ ! -s $(@D)/config.ini ] ; then \
		echo ;\
		echo "$(OK_COLOR)>>> now do the below and edit to taste <<<$(NO_COLOR)" ;\
		echo ;\
		echo "$(OK_COLOR)cp $@ $(@D)/config.ini$(NO_COLOR)" ;\
		echo "$(OK_COLOR)vi $(@D)/config.ini$(NO_COLOR)" ;\
		echo ;\
		echo ;\
	fi
	@echo "$@ $(OK_STRING)"

# BUILD AND INSTALL COMMANDS
# =======================================
# do not change

.PHONY: cmds
cmds: reqs engine.$(PY) $(name) ## Make python commands from templates and install requirements
	@echo "$@ $(OK_STRING)"

$(name): $(prog)
	ln -sf $< $@
	@echo "$@ $(OK_STRING)"

$(prog): $(jnjdir)/$(prog).$(J2) $(defdir)/commands.$(JSN) $(CMDTARGETS) | JINJA-exists
	$(JINJA) $(jnjdir)/$(prog).$(J2) $(defdir)/commands.$(JSN) $(OUTPUT_OPTION)
	chmod 755 $@
	@echo "$@ $(OK_STRING)"

engine.$(PY): $(jnjdir)/engine.$(PY).$(J2) $(defdir)/commands.$(JSN) | JINJA-exists
	$(JINJA) -D apiversion=$(apiversion) $^ $(OUTPUT_OPTION)
	@echo "$@ $(OK_STRING)"

$(cmddir)/%.$(PY): $(jnjdir)/command.$(PY).$(J2) $(defdir)/%.$(JSN) | $(cmddir) JINJA-exists
	$(JINJA) -D apiversion=$(apiversion) $^ $(OUTPUT_OPTION)
	@echo "$@ $(OK_STRING)"

.PHONY: install
install: reqs | PYTHON-exists ## (Re)installs the script so it's available in the path
	$(PIP) $(PIPFLAGS) --editable .
	$(PYINST) $(PYINSTFLAGS) $(prog)
	@echo "$@ $(OK_STRING)"
	@echo
	@echo "Copy the binary to a dir that you can add to PATH, for example:"
	@echo
	@echo "     mkdir -p ~/bin"
	@echo "     cp -r $(pyidistdir)/$(name)/* ~/bin"
	@echo "     vi ~/.bash_profile"
	@echo "add: export PATH=\"\$${HOME}/bin:\$${PATH}\""
	@echo "     source ~/.bash_profile"
	@echo
	@echo "It's recommended to place your API credentials in an ini file:"
	@echo
	@echo "     cp ~/.elm/config.example.ini ~/.elm/config.ini"
	@echo "     vi ~/.elm/config.ini"
	@echo
	@echo "Now you can run 'elm' from anywhere on the cli and it should work as expected."
	@echo
	@echo "Note: The first run will take longer than normal."
	@echo

#$(PIP) $(PIPFLAGS) --user -r $<
.PHONY: reqs
reqs: requirements.txt $(VENV) | PYTHON-exists ## Install python requirements
	$(PIP) $(PIPFLAGS) -r $<
	@echo "$@ $(OK_STRING)"

$(VENV): | PYTHON-exists
	$(PYTHON) -m venv $@
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

.PHONY: texttext
testtext: testH testI testHI testhead testfoot testheadfoot ## Test commands that alter columns, indices, header and footer
	@echo "$@ $(OK_STRING)"

.PHONY: testhelp
testhelp: ## Test all commands with help flag
	@$(foreach cmd,$(TSTTARGETS), \
		echo testing: ./$(name) $(cmd) --help ;\
		./$(name) $(cmd) --help >/dev/null || exit ;\
		)
	@echo "$@ $(OK_STRING)"

.PHONY: testid
testid: ## Test a command with an id flag                (connects to LM)
	@echo testing: ./$(name) AdminById --id 2 ; ./$(name) AdminById --id 2 ;
	@echo "$@ $(OK_STRING)"

.PHONY: testcount
testcount: ## Test 'non-required' commands with count flag  (connects to LM)
	@$(foreach cmd,$(NONREQTARGETS), \
		echo testing: ./$(name) $(cmd) -c ;\
		./$(name) $(cmd) -c || exit ;\
		)
	@echo "$@ $(OK_STRING)"

.PHONY: testtotal
testtotal: ## Test 'non-required' commands with total flag  (connects to LM)
	@$(foreach cmd,$(NONREQTARGETS), \
		echo testing: ./$(name) $(cmd) -C ;\
		./$(name) $(cmd) -C || exit ;\
		)
	@echo "$@ $(OK_STRING)"

.PHONY: testfmts
testfmts: ## Test a command with all formats               (connects to LM)
	@echo testing: ./$(name) --format csv        MetricsUsage ; ./$(name) --format csv        MetricsUsage
	@echo testing: ./$(name) --format html       MetricsUsage ; ./$(name) --format html       MetricsUsage
	@echo testing: ./$(name) --format prettyhtml MetricsUsage ; ./$(name) --format prettyhtml MetricsUsage
	@echo testing: ./$(name) --format jira       MetricsUsage ; ./$(name) --format jira       MetricsUsage
	@echo testing: ./$(name) --format json       MetricsUsage ; ./$(name) --format json       MetricsUsage
	@echo testing: ./$(name) --format prettyjson MetricsUsage ; ./$(name) --format prettyjson MetricsUsage
	@echo testing: ./$(name) --format latex      MetricsUsage ; ./$(name) --format latex      MetricsUsage
	@echo testing: ./$(name) --format md         MetricsUsage ; ./$(name) --format md         MetricsUsage
	@echo testing: ./$(name) --format rst        MetricsUsage ; ./$(name) --format rst        MetricsUsage
	@echo testing: ./$(name) --format tab        MetricsUsage ; ./$(name) --format tab        MetricsUsage
	@echo testing: ./$(name) --format raw        MetricsUsage ; ./$(name) --format raw        MetricsUsage
	@echo testing: ./$(name) --format txt        MetricsUsage ; ./$(name) --format txt        MetricsUsage
	@echo testing: ./$(name) --format api        MetricsUsage ; ./$(name) --format api        MetricsUsage
	@echo "$@ $(OK_STRING)"

.PHONY: testH
testH: ## Test a command and hide headers               (connects to LM)
	@echo testing: ./$(name) -H --format csv        MetricsUsage ; ./$(name) -H --format csv        MetricsUsage
	@echo testing: ./$(name) -H --format html       MetricsUsage ; ./$(name) -H --format html       MetricsUsage
	@echo testing: ./$(name) -H --format prettyhtml MetricsUsage ; ./$(name) -H --format prettyhtml MetricsUsage
	@echo testing: ./$(name) -H --format jira       MetricsUsage ; ./$(name) -H --format jira       MetricsUsage
	@echo testing: ./$(name) -H --format latex      MetricsUsage ; ./$(name) -H --format latex      MetricsUsage
	@echo testing: ./$(name) -H --format md         MetricsUsage ; ./$(name) -H --format md         MetricsUsage
	@echo testing: ./$(name) -H --format rst        MetricsUsage ; ./$(name) -H --format rst        MetricsUsage
	@echo testing: ./$(name) -H --format tab        MetricsUsage ; ./$(name) -H --format tab        MetricsUsage
	@echo testing: ./$(name) -H --format txt        MetricsUsage ; ./$(name) -H --format txt        MetricsUsage
	@echo "$@ $(OK_STRING)"

.PHONY: testI
testI: ## Test a command and show index                 (connects to LM)
	@echo testing: ./$(name) -I --format csv        MetricsUsage ; ./$(name) -I --format csv        MetricsUsage
	@echo testing: ./$(name) -I --format html       MetricsUsage ; ./$(name) -I --format html       MetricsUsage
	@echo testing: ./$(name) -I --format prettyhtml MetricsUsage ; ./$(name) -I --format prettyhtml MetricsUsage
	@echo testing: ./$(name) -I --format jira       MetricsUsage ; ./$(name) -I --format jira       MetricsUsage
	@echo testing: ./$(name) -I --format latex      MetricsUsage ; ./$(name) -I --format latex      MetricsUsage
	@echo testing: ./$(name) -I --format md         MetricsUsage ; ./$(name) -I --format md         MetricsUsage
	@echo testing: ./$(name) -I --format rst        MetricsUsage ; ./$(name) -I --format rst        MetricsUsage
	@echo testing: ./$(name) -I --format tab        MetricsUsage ; ./$(name) -I --format tab        MetricsUsage
	@echo testing: ./$(name) -I --format txt        MetricsUsage ; ./$(name) -I --format txt        MetricsUsage
	@echo "$@ $(OK_STRING)"

.PHONY: testHI
testHI: ## Test a command, hide headers and show index   (connects to LM)
	@echo testing: ./$(name) -H -I --format csv        MetricsUsage ; ./$(name) -H -I --format csv        MetricsUsage
	@echo testing: ./$(name) -H -I --format html       MetricsUsage ; ./$(name) -H -I --format html       MetricsUsage
	@echo testing: ./$(name) -H -I --format prettyhtml MetricsUsage ; ./$(name) -H -I --format prettyhtml MetricsUsage
	@echo testing: ./$(name) -H -I --format jira       MetricsUsage ; ./$(name) -H -I --format jira       MetricsUsage
	@echo testing: ./$(name) -H -I --format latex      MetricsUsage ; ./$(name) -H -I --format latex      MetricsUsage
	@echo testing: ./$(name) -H -I --format md         MetricsUsage ; ./$(name) -H -I --format md         MetricsUsage
	@echo testing: ./$(name) -H -I --format rst        MetricsUsage ; ./$(name) -H -I --format rst        MetricsUsage
	@echo testing: ./$(name) -H -I --format tab        MetricsUsage ; ./$(name) -H -I --format tab        MetricsUsage
	@echo testing: ./$(name) -H -I --format txt        MetricsUsage ; ./$(name) -H -I --format txt        MetricsUsage
	@echo "$@ $(OK_STRING)"

.PHONY: testhead
testhead: ## Test a command, custom header text            (connects to LM)
	@echo testing: ./$(name) --head \"this is header text\" --format jira       MetricsUsage ; ./$(name) --head "this is header text" --format jira       MetricsUsage
	@echo testing: ./$(name) --head \"this is header text\" --format md         MetricsUsage ; ./$(name) --head "this is header text" --format md         MetricsUsage
	@echo testing: ./$(name) --head \"this is header text\" --format rst        MetricsUsage ; ./$(name) --head "this is header text" --format rst        MetricsUsage
	@echo testing: ./$(name) --head \"this is header text\" --format tab        MetricsUsage ; ./$(name) --head "this is header text" --format tab        MetricsUsage
	@echo testing: ./$(name) --head \"this is header text\" --format txt        MetricsUsage ; ./$(name) --head "this is header text" --format txt        MetricsUsage
	@echo "$@ $(OK_STRING)"

.PHONY: testfoot
testfoot: ## Test a command, custom footer text            (connects to LM)
	@echo testing: ./$(name) --foot \"this is footer text\" --format jira       MetricsUsage ; ./$(name) --foot "this is footer text" --format jira       MetricsUsage
	@echo testing: ./$(name) --foot \"this is footer text\" --format md         MetricsUsage ; ./$(name) --foot "this is footer text" --format md         MetricsUsage
	@echo testing: ./$(name) --foot \"this is footer text\" --format rst        MetricsUsage ; ./$(name) --foot "this is footer text" --format rst        MetricsUsage
	@echo testing: ./$(name) --foot \"this is footer text\" --format tab        MetricsUsage ; ./$(name) --foot "this is footer text" --format tab        MetricsUsage
	@echo testing: ./$(name) --foot \"this is footer text\" --format txt        MetricsUsage ; ./$(name) --foot "this is footer text" --format txt        MetricsUsage
	@echo "$@ $(OK_STRING)"

.PHONY: testheadfoot
testheadfoot: ## Test a command, custom header and footer text (connects to LM)
	@echo testing: ./$(name) --head \"this is header text\" --foot \"this is footer text\" --format jira       MetricsUsage ; ./$(name) --head "this is header text" --foot "this is footer text" --format jira       MetricsUsage
	@echo testing: ./$(name) --head \"this is header text\" --foot \"this is footer text\" --format md         MetricsUsage ; ./$(name) --head "this is header text" --foot "this is footer text" --format md         MetricsUsage
	@echo testing: ./$(name) --head \"this is header text\" --foot \"this is footer text\" --format rst        MetricsUsage ; ./$(name) --head "this is header text" --foot "this is footer text" --format rst        MetricsUsage
	@echo testing: ./$(name) --head \"this is header text\" --foot \"this is footer text\" --format tab        MetricsUsage ; ./$(name) --head "this is header text" --foot "this is footer text" --format tab        MetricsUsage
	@echo testing: ./$(name) --head \"this is header text\" --foot \"this is footer text\" --format txt        MetricsUsage ; ./$(name) --head "this is header text" --foot "this is footer text" --format txt        MetricsUsage
	@echo "$@ $(OK_STRING)"

.PHONY: testverb
testverb: ## Test the verbose flags                        (connects to LM)
	@echo testing: ./$(name) -v  MetricsUsage ; ./$(name) -v  MetricsUsage
	@echo testing: ./$(name) -vv MetricsUsage ; ./$(name) -vv MetricsUsage
	@echo "$@ $(OK_STRING)"

.PHONY: fail
fail: ## A failing test
	@echo test false ; false >/dev/null

# BACKUP
# =======================================
# do not change

.PHONY: back
back: nomac $(bakdir) ## TAR and backup (eg ../name_backup/name.YYYY-MM-DD.tar.gz)
	$(TAR) $(TARFLAGS) $(bakdir)/$(name).$(shell date +%Y-%m-%d).tar.gz .
	@echo "$@ $(OK_STRING)"

.PHONY: clean
clean: nomac ## Remove generated files
	$(RM) -r $(VENV)
	$(RM) -r __pycache__
	$(RM) -r $(name).egg-info
	$(RM) -r $(cmddir) $(defdir)
	$(RM) -r $(pyiworkdir) $(pyidistdir)
ifdef CMDTARGETS
	$(RM) $(CMDTARGETS)
endif
	$(RM) $(name)
	$(RM) $(prog)
	$(RM) engine.$(PY)
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
	@echo 'This Makefile is used to generate files for $(name)'
	@echo
	@echo 'Run "make help" to for how to run'
	@echo
	@echo 'See https://github.com/rdmarsh/$(name)'
	@echo

.PHONY: copying
copying: ## Copyright notice
	@echo
	@echo 'Copyright (C) 2021--2024 David Marsh'
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
	@echo '  make -n   : dry run'
	@echo '  make -j   : run simultaneous jobs'
	@echo '  make -B   : force make target'
	@echo
	@echo 'You can override Makefile vars like so:'
	@echo '  make apiversion=2'
	@echo

