# This Makefile builds Felix and packages it in various forms:
#
#                                                                      Go install
#                                                                         Glide
#                                                                           |
#                                                                           |
#                                                                           |
#                                                    +-------+              v
#                                                    | Felix |   +---------------------+
#                                                    |  Go   |   | calico/go-build     |
#                                                    |  code |   +---------------------+
#                                                    +-------+         /
#                                                           \         /
#                                                            \       /
#                                                             \     /
#                                                             go build
#                                                                 \
#                                                                  \
#                                                                   \
# +----------------------+                                           :
# | calico-build/centos7 |                                           v
# | calico-build/xenial  |                                 +------------------+
# | calico-build/trusty  |                                 | bin/calico-felix |
# +----------------------+                                 +------------------+
#                     \                                          /   /
#                      \             .--------------------------'   /
#                       \           /                              /
#                        \         /                      .-------'
#                         \       /                      /
#                     rpm/build-rpms                    /
#                   debian/build-debs                  /
#                           |                         /
#                           |                   docker build
#                           v                         |
#            +----------------------------+           |
#            |  RPM packages for Centos7  |           |
#            |  RPM packages for Centos6  |           v
#            | Debian packages for Xenial |    +--------------+
#            | Debian packages for Trusty |    | calico/felix |
#            +----------------------------+    +--------------+
#
#
#
###############################################################################
# Both native and cross architecture builds are supported.
# The target architecture is select by setting the ARCH variable.
# When ARCH is undefined it is set to the detected host architecture.
# When ARCH differs from the host architecture a crossbuild will be performed.
ARCHES=$(patsubst docker-image/Dockerfile.%,%,$(wildcard docker-image/Dockerfile.*))


# BUILDARCH is the host architecture
# ARCH is the target architecture
# we need to keep track of them separately
BUILDARCH ?= $(shell uname -m)

# canonicalized names for host architecture
ifeq ($(BUILDARCH),aarch64)
        BUILDARCH=arm64
endif
ifeq ($(BUILDARCH),x86_64)
        BUILDARCH=amd64
endif

# unless otherwise set, I am building for my own architecture, i.e. not cross-compiling
ARCH ?= $(BUILDARCH)

# canonicalized names for target architecture
ifeq ($(ARCH),aarch64)
        override ARCH=arm64
endif
ifeq ($(ARCH),x86_64)
    override ARCH=amd64
endif

GO_BUILD_VER ?= v0.14
# For building, we use the go-build image for the *host* architecture, even if the target is different
# the one for the host should contain all the necessary cross-compilation tools
GO_BUILD_CONTAINER = calico/go-build:$(GO_BUILD_VER)-$(BUILDARCH)
PROTOC_VER ?= v0.1
PROTOC_CONTAINER ?= calico/protoc:$(PROTOC_VER)-$(BUILDARCH)
FV_ETCDIMAGE ?= quay.io/coreos/etcd:v3.2.5-$(BUILDARCH)
FV_K8SIMAGE ?= gcr.io/google_containers/hyperkube-$(BUILDARCH):v1.7.5
FV_TYPHAIMAGE ?= calico/typha:latest-$(BUILDARCH)
FV_FELIXIMAGE ?= calico/felix:latest-$(BUILDARCH)

# If building on amd64 omit the arch in the container name.  Fixme!
ifeq ($(BUILDARCH),amd64)
        FV_ETCDIMAGE=quay.io/coreos/etcd:v3.2.5
        FV_K8SIMAGE=gcr.io/google_containers/hyperkube:v1.7.5
        FV_TYPHAIMAGE=calico/typha:v0.7.2-25-g4314704
endif

# Total number of ginkgo batches to run.  The CI system sets this according to the number
# of jobs that it divides the FVs into.
FV_NUM_BATCHES?=3
# Space-delimited list of FV batches to run in parallel.  Defaults to running all batches
# in parallel on this host.  The CI system runs a subset of batches in each parallel job.
FV_BATCHES_TO_RUN?=$(shell seq $(FV_NUM_BATCHES))
FV_SLOW_SPEC_THRESH=90

help:
	@echo "Felix Makefile"
	@echo
	@echo "Dependencies: docker 1.12+; go 1.7+"
	@echo
	@echo "Note: initial builds can be slow because they generate docker-based"
	@echo "build environments."
	@echo
	@echo "For any target, set ARCH=<target> to build for a given target."
	@echo "For example, to build for arm64:"
	@echo
	@echo "  make calico/felix ARCH=arm64"
	@echo
	@echo "By default, builds for the architecture on which it is running. Cross-building is supported"
	@echo "only on amd64, i.e. building for other architectures when running on amd64."
	@echo "Supported target ARCH options:       $(ARCHES)"
	@echo
	@echo "Initial set-up:"
	@echo
	@echo "  make update-tools  Update/install the go build dependencies."
	@echo
	@echo "Builds:"
	@echo
	@echo "  make all           Build all the binary packages."
	@echo "  make deb           Build debs in ./dist."
	@echo "  make rpm           Build rpms in ./dist."
	@echo "  make calico/felix  Build calico/felix docker image."
	@echo
	@echo "Tests:"
	@echo
	@echo "  make ut                Run UTs."
	@echo "  make go-cover-browser  Display go code coverage in browser."
	@echo
	@echo "Maintenance:"
	@echo
	@echo "  make update-vendor  Update the vendor directory with new "
	@echo "                      versions of upstream packages.  Record results"
	@echo "                      in glide.lock."
	@echo "  make go-fmt        Format our go code."
	@echo "  make clean         Remove binary files."
	@echo "-----------------------------------------"
	@echo "ARCH (target):          $(ARCH)"
	@echo "BUILDARCH (host):       $(BUILDARCH)"
	@echo "GO_BUILD_CONTAINER:     $(GO_BUILD_CONTAINER)"
	@echo "PROTOC_CONTAINER:       $(PROTOC_CONTAINER)"
	@echo "FV_ETCDIMAGE:           $(FV_ETCDIMAGE)"
	@echo "FV_K8SIMAGE:            $(FV_K8SIMAGE)"
	@echo "FV_TYPHAIMAGE:          $(FV_TYPHAIMAGE)"
	@echo "-----------------------------------------"

TOPDIR:=$(shell pwd)

# Disable make's implicit rules, which are not useful for golang, and slow down the build
# considerably.
.SUFFIXES:

all: deb rpm calico/felix-$(ARCH)
test: ut fv

# Targets used when cross building.
.PHONY: native register
native:
ifneq ($(BUILDARCH),$(ARCH))
	@echo "Target $(MAKECMDGOALS)" is not supported when cross building! && false
endif

# Enable binfmt adding support for miscellaneous binary formats.
# This is only needed when running non-native binaries.
register:
ifneq ($(BUILDARCH),$(ARCH))
	docker run --rm --privileged multiarch/qemu-user-static:register || true
endif

# Figure out version information.  To support builds from release tarballs, we default to
# <unknown> if this isn't a git checkout.
GIT_COMMIT:=$(shell git rev-parse HEAD || echo '<unknown>')
BUILD_ID:=$(shell git rev-parse HEAD || uuidgen | sed 's/-//g')
GIT_DESCRIPTION:=$(shell git describe --tags || echo '<unknown>')

# Calculate a timestamp for any build artefacts.
DATE:=$(shell date -u +'%FT%T%z')

# List of Go files that are generated by the build process.  Builds should
# depend on these, clean removes them.
GENERATED_GO_FILES:=proto/felixbackend.pb.go

# Directories that aren't part of the main Felix program,
# e.g. standalone test programs.
K8SFV_DIR:=k8sfv
NON_FELIX_DIRS:=$(K8SFV_DIR)

# All Felix go files.
FELIX_GO_FILES:=$(shell find . $(foreach dir,$(NON_FELIX_DIRS),-path ./$(dir) -prune -o) -type f -name '*.go' -print) $(GENERATED_GO_FILES)

# Files for the Felix+k8s backend test program.
K8SFV_GO_FILES:=$(shell find ./$(K8SFV_DIR) -name prometheus -prune -o -type f -name '*.go' -print)

# Figure out the users UID/GID.  These are needed to run docker containers
# as the current user and ensure that files built inside containers are
# owned by the current user.
MY_UID:=$(shell id -u)
MY_GID:=$(shell id -g)

# Build a docker image used for building debs for trusty.
.PHONY: calico-build/trusty
calico-build/trusty:
	cd docker-build-images && docker build -f ubuntu-trusty-build.Dockerfile.$(ARCH) -t calico-build/trusty .

# Build a docker image used for building debs for xenial.
.PHONY: calico-build/xenial
calico-build/xenial:
	cd docker-build-images && docker build -f ubuntu-xenial-build.Dockerfile.$(ARCH) -t calico-build/xenial .

# Construct a docker image for building Centos 7 RPMs.
.PHONY: calico-build/centos7
calico-build/centos7:
	cd docker-build-images && \
	  docker build \
	  --build-arg=UID=$(MY_UID) \
	  --build-arg=GID=$(MY_GID) \
	  -f centos7-build.Dockerfile.$(ARCH) \
	  -t calico-build/centos7 .

ifeq ("$(ARCH)","ppc64le")
	# Some commands that would typically be run at container build time must be run in a privileged container.
	@-docker rm -f centos7Tmp
	docker run --privileged --name=centos7Tmp calico-build/centos7 \
		/bin/bash -c "/setup-user; /install-centos-build-deps"
	docker commit centos7Tmp calico-build/centos7:latest
endif

# Construct a docker image for building Centos 6 RPMs.
.PHONY: calico-build/centos6
calico-build/centos6:
	cd docker-build-images && \
	  docker build \
	  --build-arg=UID=$(MY_UID) \
	  --build-arg=GID=$(MY_GID) \
	  -f centos6-build.Dockerfile.$(ARCH) \
	  -t calico-build/centos6 .

# Build the calico/felix docker image, which contains only Felix.
.PHONY: calico/felix calico/felix-$(ARCH) register

# by default, build the image for the target architecture
calico/felix: calico/felix-$(ARCH)
calico/felix-$(ARCH): bin/calico-felix-$(ARCH) register
	rm -rf docker-image/bin
	mkdir -p docker-image/bin
	cp bin/calico-felix-$(ARCH) docker-image/bin/
	docker build --pull -t calico/felix:latest-$(ARCH) --file ./docker-image/Dockerfile.$(ARCH) docker-image
ifeq ($(ARCH),amd64)
	docker tag calico/felix:latest-$(ARCH) calico/felix:latest
endif

# Targets for Felix testing with the k8s backend and a k8s API server,
# with k8s model resources being injected by a separate test client.
GET_CONTAINER_IP := docker inspect --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
GRAFANA_VERSION=4.1.2
.PHONY: k8sfv-test k8sfv-test-existing-felix
# Run k8sfv test with Felix built from current code.
k8sfv-test: calico/felix k8sfv-test-existing-felix
# Run k8sfv test with whatever is the existing 'calico/felix:latest'
# container image.  To use some existing Felix version other than
# 'latest', do 'FELIX_VERSION=<...> make k8sfv-test-existing-felix'.
k8sfv-test-existing-felix: bin/k8sfv.test
	FV_ETCDIMAGE=$(FV_ETCDIMAGE) \
	FV_TYPHAIMAGE=$(FV_TYPHAIMAGE) \
	FV_FELIXIMAGE=$(FV_FELIXIMAGE) \
	FV_K8SIMAGE=$(FV_K8SIMAGE) \
	k8sfv/run-test

PROMETHEUS_DATA_DIR := $$HOME/prometheus-data
K8SFV_PROMETHEUS_DATA_DIR := $(PROMETHEUS_DATA_DIR)/k8sfv

$(K8SFV_PROMETHEUS_DATA_DIR):
	mkdir -p $@

.PHONY: run-prometheus run-grafana stop-prometheus stop-grafana
run-prometheus: stop-prometheus $(K8SFV_PROMETHEUS_DATA_DIR)
	FELIX_IP=`$(GET_CONTAINER_IP) k8sfv-felix` && \
	sed "s/__FELIX_IP__/$${FELIX_IP}/" < $(K8SFV_DIR)/prometheus/prometheus.yml.in > $(K8SFV_DIR)/prometheus/prometheus.yml
	docker run --detach --name k8sfv-prometheus \
	-v $${PWD}/$(K8SFV_DIR)/prometheus/prometheus.yml:/etc/prometheus.yml \
	-v $(K8SFV_PROMETHEUS_DATA_DIR):/prometheus \
	prom/prometheus \
	-config.file=/etc/prometheus.yml \
	-storage.local.path=/prometheus

stop-prometheus:
	@-docker rm -f k8sfv-prometheus
	sleep 2

run-grafana: stop-grafana run-prometheus
	docker run --detach --name k8sfv-grafana -p 3000:3000 \
	-v $${PWD}/$(K8SFV_DIR)/grafana:/etc/grafana \
	-v $${PWD}/$(K8SFV_DIR)/grafana-dashboards:/etc/grafana-dashboards \
	grafana/grafana:$(GRAFANA_VERSION) --config /etc/grafana/grafana.ini
	# Wait for it to get going.
	sleep 5
	# Configure prometheus data source.
	PROMETHEUS_IP=`$(GET_CONTAINER_IP) k8sfv-prometheus` && \
	sed "s/__PROMETHEUS_IP__/$${PROMETHEUS_IP}/" < $(K8SFV_DIR)/grafana-datasources/my-prom.json.in | \
	curl 'http://admin:admin@127.0.0.1:3000/api/datasources' -X POST \
	    -H 'Content-Type: application/json;charset=UTF-8' --data-binary @-

stop-grafana:
	@-docker rm -f k8sfv-grafana
	sleep 2

# Pre-configured docker run command that runs as this user with the repo
# checked out to /code, uses the --rm flag to avoid leaving the container
# around afterwards.
DOCKER_RUN_RM:=docker run --rm --user $(MY_UID):$(MY_GID) -v $${PWD}:/code
DOCKER_RUN_RM_ROOT:=docker run --rm -v $${PWD}:/code

# Allow libcalico-go and the ssh auth sock to be mapped into the build container.
ifdef LIBCALICOGO_PATH
  EXTRA_DOCKER_ARGS += -v $(LIBCALICOGO_PATH):/go/src/github.com/projectcalico/libcalico-go:ro
endif
ifdef SSH_AUTH_SOCK
  EXTRA_DOCKER_ARGS += -v $(SSH_AUTH_SOCK):/ssh-agent --env SSH_AUTH_SOCK=/ssh-agent
endif
DOCKER_GO_BUILD := mkdir -p .go-pkg-cache && \
                   docker run --rm \
                              --net=host \
                              $(EXTRA_DOCKER_ARGS) \
                              -e LOCAL_USER_ID=$(MY_UID) \
                              -v $${PWD}:/go/src/github.com/projectcalico/felix:rw \
                              -v $${PWD}/.go-pkg-cache:/go/pkg:rw \
                              -w /go/src/github.com/projectcalico/felix \
                              -e GOARCH=$(ARCH) \
                              $(GO_BUILD_CONTAINER)

# Build all the debs.
.PHONY: deb
deb: bin/calico-felix
ifeq ($(GIT_COMMIT),<unknown>)
	$(error Package builds must be done from a git working copy in order to calculate version numbers.)
endif
	$(MAKE) calico-build/trusty
	$(MAKE) calico-build/xenial
	utils/make-packages.sh deb

# Build RPMs.
.PHONY: rpm
rpm: bin/calico-felix
ifeq ($(GIT_COMMIT),<unknown>)
	$(error Package builds must be done from a git working copy in order to calculate version numbers.)
endif
	$(MAKE) calico-build/centos7
ifneq ("$(ARCH)","ppc64le") # no ppc64le support in centos6
	$(MAKE) calico-build/centos6
endif
	utils/make-packages.sh rpm

.PHONY: protobuf
protobuf: proto/felixbackend.pb.go

# Generate the protobuf bindings for go.
proto/felixbackend.pb.go: proto/felixbackend.proto
	$(DOCKER_RUN_RM) -v $${PWD}/proto:/src:rw \
	              $(PROTOC_CONTAINER) \
	              --gogofaster_out=plugins=grpc:. \
	              felixbackend.proto

# Update the vendored dependencies with the latest upstream versions matching
# our glide.yaml.  If there area any changes, this updates glide.lock
# as a side effect.  Unless you're adding/updating a dependency, you probably
# want to use the vendor target to install the versions from glide.lock.
VENDOR_REMADE := false
.PHONY: update-vendor
update-vendor glide.lock:
	mkdir -p $$HOME/.glide
	$(DOCKER_GO_BUILD) glide up --strip-vendor
	touch vendor/.up-to-date
	# Optimization: since glide up does the job of glide install, flag to the
	# vendor target that it doesn't need to do anything.
	$(eval VENDOR_REMADE := true)

# vendor is a shortcut for force rebuilding the go vendor directory.
.PHONY: vendor
vendor vendor/.up-to-date: glide.lock
	if ! $(VENDOR_REMADE); then \
	  mkdir -p $$HOME/.glide && \
	  $(DOCKER_GO_BUILD) glide install --strip-vendor && \
	  touch vendor/.up-to-date; \
	fi

# Linker flags for building Felix.
#
# We use -X to insert the version information into the placeholder variables
# in the buildinfo package.
#
# We use -B to insert a build ID note into the executable, without which, the
# RPM build tools complain.
LDFLAGS:=-ldflags "\
        -X github.com/projectcalico/felix/buildinfo.GitVersion=$(GIT_DESCRIPTION) \
        -X github.com/projectcalico/felix/buildinfo.BuildDate=$(DATE) \
        -X github.com/projectcalico/felix/buildinfo.GitRevision=$(GIT_COMMIT) \
        -B 0x$(BUILD_ID)"

bin/calico-felix: bin/calico-felix-$(ARCH)
	ln -f bin/calico-felix-$(ARCH) bin/calico-felix

bin/calico-felix-$(ARCH): $(FELIX_GO_FILES) vendor/.up-to-date
	@echo Building felix for $(ARCH) on $(BUILDARCH)
	mkdir -p bin
	$(DOCKER_GO_BUILD) \
	   sh -c 'go build -v -i -o $@ -v $(LDFLAGS) "github.com/projectcalico/felix" && \
		( ldd $@ 2>&1 | grep -q -e "Not a valid dynamic program" \
		-e "not a dynamic executable" || \
		( echo "Error: $@ was not statically linked"; false ) )'

bin/iptables-locker: $(FELIX_GO_FILES) vendor/.up-to-date
	@echo Building iptables-locker...
	mkdir -p bin
	$(DOCKER_GO_BUILD) \
	    sh -c 'go build -v -i -o $@ -v $(LDFLAGS) "github.com/projectcalico/felix/fv/iptables-locker"'

bin/test-workload: $(FELIX_GO_FILES) vendor/.up-to-date
	@echo Building test-workload...
	mkdir -p bin
	$(DOCKER_GO_BUILD) \
	    sh -c 'go build -v -i -o $@ -v $(LDFLAGS) "github.com/projectcalico/felix/fv/test-workload"'

bin/test-connection: $(FELIX_GO_FILES) vendor/.up-to-date
	@echo Building test-connection...
	mkdir -p bin
	$(DOCKER_GO_BUILD) \
	    sh -c 'go build -v -i -o $@ -v $(LDFLAGS) "github.com/projectcalico/felix/fv/test-connection"'

bin/k8sfv.test: $(K8SFV_GO_FILES) vendor/.up-to-date
	@echo Building $@...
	$(DOCKER_GO_BUILD) \
	    sh -c 'go test -c -o $@ ./k8sfv && \
		( ldd $@ 2>&1 | grep -q -e "Not a valid dynamic program" \
		-e "not a dynamic executable" || \
		( echo "Error: $@ was not statically linked"; false ) )'

dist/calico-felix/calico-felix: bin/calico-felix
	mkdir -p dist/calico-felix/
	cp bin/calico-felix-$(ARCH) dist/calico-felix/calico-felix

# Cross-compile Felix for Windows
bin/calico-felix.exe: $(FELIX_GO_FILES) vendor/.up-to-date
	@echo Building felix for Windows...
	mkdir -p bin
	$(DOCKER_GO_BUILD) \
           sh -c 'GOOS=windows go build -v -o $@ -v $(LDFLAGS) "github.com/projectcalico/felix" && \
		( ldd $@ 2>&1 | grep -q "Not a valid dynamic program" || \
		( echo "Error: $@ was not statically linked"; false ) )'

# Install or update the tools used by the build
.PHONY: update-tools
update-tools:
	go get -u github.com/Masterminds/glide
	go get -u github.com/onsi/ginkgo/ginkgo

# Run go fmt on all our go files.
.PHONY: go-fmt goimports
go-fmt goimports:
	$(DOCKER_GO_BUILD) sh -c 'glide nv -x | \
	                          grep -v -e "^\\.$$" | \
	                          xargs goimports -w -local github.com/projectcalico/ *.go'

check-licenses/dependency-licenses.txt: vendor/.up-to-date
	$(DOCKER_GO_BUILD) sh -c 'licenses . > check-licenses/dependency-licenses.txt'

.PHONY: ut
ut combined.coverprofile: vendor/.up-to-date $(FELIX_GO_FILES)
	@echo Running Go UTs.
	$(DOCKER_GO_BUILD) ./utils/run-coverage $(GINKGO_ARGS)

fv/fv.test: vendor/.up-to-date $(FELIX_GO_FILES)
	# We pre-build the FV test binaries so that we can run them
	# outside a container and allow them to interact with docker.
	$(DOCKER_GO_BUILD) go test ./$(shell dirname $@) -c --tags fvtests -o $@

.PHONY: fv
fv fv/latency.log: calico/felix bin/iptables-locker bin/test-workload bin/test-connection fv/fv.test
	cd fv && \
	  FV_FELIXIMAGE=$(FV_FELIXIMAGE) \
	  FV_ETCDIMAGE=$(FV_ETCDIMAGE) \
	  FV_TYPHAIMAGE=$(FV_TYPHAIMAGE) \
	  FV_K8SIMAGE=$(FV_K8SIMAGE) \
	  FV_NUM_BATCHES=$(FV_NUM_BATCHES) \
	  FV_BATCHES_TO_RUN="$(FV_BATCHES_TO_RUN)" \
	  GINKGO_ARGS='$(GINKGO_ARGS)' \
	  GINKGO_FOCUS="$(GINKGO_FOCUS)" \
	  ./run-batches
	@if [ -e fv/latency.log ]; then \
	   echo; \
	   echo "Latency results:"; \
	   echo; \
	   cat fv/latency.log; \
	fi

bin/check-licenses: $(FELIX_GO_FILES)
	$(DOCKER_GO_BUILD) go build -v -i -o $@ "github.com/projectcalico/felix/check-licenses"

.PHONY: check-licenses
check-licenses: check-licenses/dependency-licenses.txt bin/check-licenses
	@echo Checking dependency licenses
	$(DOCKER_GO_BUILD) bin/check-licenses

.PHONY: go-meta-linter
go-meta-linter: vendor/.up-to-date $(GENERATED_GO_FILES)
	# Run staticcheck stand-alone since gometalinter runs concurrent copies, which
	# uses a lot of RAM.
	$(DOCKER_GO_BUILD) sh -c 'glide nv | xargs -n 3 staticcheck'
	$(DOCKER_GO_BUILD) gometalinter --deadline=300s \
	                                --disable-all \
	                                --enable=goimports \
	                                --vendor ./...

.PHONY: check-typha-pins
check-typha-pins: vendor/.up-to-date
	@echo "Checking Typha's libcalico-go pin matches ours (so that any datamodel"
	@echo "changes are reflected in the Typha-Felix API)."
	@echo
	@echo "Felix's libcalico-go pin:"
	@grep libcalico-go glide.lock -A 5 | grep 'version:' | head -n 1
	@echo "Typha's libcalico-go pin:"
	@grep libcalico-go vendor/github.com/projectcalico/typha/glide.lock -A 5 | grep 'version:' | head -n 1
	if [ "`grep libcalico-go glide.lock -A 5 | grep 'version:' | head -n 1`" != \
	     "`grep libcalico-go vendor/github.com/projectcalico/typha/glide.lock -A 5 | grep 'version:' | head -n 1`" ]; then \
	     echo "Typha and Felix libcalico-go pins differ."; \
	     false; \
	fi

.PHONY: static-checks
static-checks:
	$(MAKE) check-typha-pins go-meta-linter check-licenses

.PHONY: pre-commit
pre-commit:
	$(DOCKER_GO_BUILD) git-hooks/pre-commit-in-container

.PHONY: ut-no-cover
ut-no-cover: vendor/.up-to-date $(FELIX_GO_FILES)
	@echo Running Go UTs without coverage.
	$(DOCKER_GO_BUILD) ginkgo -r -skipPackage fv,k8sfv,windows $(GINKGO_ARGS)

.PHONY: ut-watch
ut-watch: vendor/.up-to-date $(FELIX_GO_FILES)
	@echo Watching go UTs for changes...
	$(DOCKER_GO_BUILD) ginkgo watch -r -skipPackage fv,k8sfv,windows $(GINKGO_ARGS)

# Launch a browser with Go coverage stats for the whole project.
.PHONY: cover-browser
cover-browser: combined.coverprofile
	go tool cover -html="combined.coverprofile"

.PHONY: cover-report
cover-report: combined.coverprofile
	# Print the coverage.  We use sed to remove the verbose prefix and trim down
	# the whitespace.
	@echo
	@echo ======== All coverage =========
	@echo
	@$(DOCKER_GO_BUILD) sh -c 'go tool cover -func combined.coverprofile | \
	                           sed 's=github.com/projectcalico/felix/==' | \
	                           column -t'
	@echo
	@echo ======== Missing coverage only =========
	@echo
	@$(DOCKER_GO_BUILD) sh -c "go tool cover -func combined.coverprofile | \
	                           sed 's=github.com/projectcalico/felix/==' | \
	                           column -t | \
	                           grep -v '100\.0%'"

.PHONY: upload-to-coveralls
upload-to-coveralls: combined.coverprofile
ifndef COVERALLS_REPO_TOKEN
	$(error COVERALLS_REPO_TOKEN is undefined - run using make upload-to-coveralls COVERALLS_REPO_TOKEN=abcd)
endif
	$(DOCKER_GO_BUILD) goveralls -repotoken=$(COVERALLS_REPO_TOKEN) -coverprofile=combined.coverprofile

bin/calico-felix.transfer-url: bin/calico-felix
	$(DOCKER_GO_BUILD) sh -c 'curl --upload-file bin/calico-felix https://transfer.sh/calico-felix > $@'

.PHONY: patch-script
patch-script: bin/calico-felix.transfer-url
	$(DOCKER_GO_BUILD) bash -c 'utils/make-patch-script.sh $$(cat bin/calico-felix.transfer-url)'

# Generate a diagram of Felix's internal calculation graph.
docs/calc.pdf: docs/calc.dot
	cd docs/ && dot -Tpdf calc.dot -o calc.pdf

.PHONY: clean
clean:
	rm -rf bin \
	       docker-image/bin \
	       dist \
	       build \
	       fv/fv.test \
	       $(GENERATED_GO_FILES) \
	       go/docs/calc.pdf \
	       .glide \
	       vendor \
	       .go-pkg-cache \
	       check-licenses/dependency-licenses.txt \
	       release-notes-*
	find . -name "junit.xml" -type f -delete
	find . -name "*.coverprofile" -type f -delete
	find . -name "coverage.xml" -type f -delete
	find . -name ".coverage" -type f -delete
	find . -name "*.pyc" -type f -delete

.PHONY: release release-once-tagged
release: clean
ifndef VERSION
	$(error VERSION is undefined - run using make release VERSION=X.Y.Z)
endif
ifeq ($(GIT_COMMIT),<unknown>)
	$(error git commit ID couldn't be determined, releases must be done from a git working copy)
endif
	$(DOCKER_GO_BUILD) utils/tag-release.sh $(VERSION)

.PHONY: continue-release
continue-release:
	@echo "Edited release notes are:"
	@echo
	@cat ./release-notes-$(VERSION)
	@echo
	@echo "Hit Return to go ahead and create the tag, or Ctrl-C to cancel."
	@bash -c read
	# Create annotated release tag.
	git tag $(VERSION) -F ./release-notes-$(VERSION)
	rm ./release-notes-$(VERSION)

	# Now decouple onto another make invocation, as we want some variables
	# (GIT_DESCRIPTION and BUNDLE_FILENAME) to be recalculated based on the
	# new tag.
	$(MAKE) release-once-tagged

release-once-tagged:
	@echo
	@echo "Will now build release artifacts..."
	@echo
	$(MAKE) bin/calico-felix calico/felix
	# default image until we use multi-arch manifest
    ifeq ($(ARCH),amd64)
	docker tag calico/felix:latest-$(ARCH) calico/felix:latest
	docker tag calico/felix:latest-$(ARCH) quay.io/calico/felix:latest
	docker tag calico/felix:latest calico/felix:$(VERSION)
	docker tag calico/felix:$(VERSION) quay.io/calico/felix:$(VERSION)
    endif
	docker tag calico/felix:latest-$(ARCH) quay.io/calico/felix:latest-$(ARCH)
	docker tag calico/felix:latest-$(ARCH) calico/felix:$(VERSION)-$(ARCH)
	docker tag calico/felix:$(VERSION)-$(ARCH) quay.io/calico/felix:$(VERSION)-$(ARCH)
	@echo
	@echo "Checking built felix has correct version..."
	@result=true; \
	for img in calico/felix:latest-$(ARCH) quay.io/calico/felix:latest-$(ARCH) calico/felix:$(VERSION)-$(ARCH) quay.io/calico/felix:$(VERSION)-$(ARCH); do \
	  if docker run $$img calico-felix --version | grep -q '$(VERSION)$$'; \
	  then \
	    echo "Check successful. ($$img)"; \
	  else \
	    echo "Incorrect version in docker image $$img!"; \
	    result=false; \
	  fi \
	done; \
	$$result
	@echo
	@echo "Felix release artifacts have been built:"
	@echo
	@echo "- Binary:                 bin/calico-felix-$(ARCH)"
	@echo "- Docker container image: calico/felix:$(VERSION)-$(ARCH)"
	@echo "- Same, tagged for Quay:  quay.io/calico/felix:$(VERSION)-$(ARCH)"
    ifeq ($(ARCH),amd64)
	@echo "- Docker container image default arch: calico/felix:$(VERSION)"
	@echo "- Same, tagged for Quay:  quay.io/calico/felix:$(VERSION)"
    endif
	@echo
	@echo "Now to publish this release to Github:"
	@echo
	@echo "- Push the new tag ($(VERSION)) to https://github.com/projectcalico/felix"
	@echo "- Go to https://github.com/projectcalico/felix/releases/tag/$(VERSION)"
	@echo "- Copy the tag content (release notes) shown on that page"
	@echo "- Go to https://github.com/projectcalico/felix/releases/new?tag=$(VERSION)"
	@echo "- Name the GitHub release:"
	@echo "  - For a stable release: 'Felix $(VERSION)'"
	@echo "  - For a test release:   'Felix $(VERSION) pre-release for testing'"
	@echo "- Paste the copied tag content into the large textbox"
	@echo "- Add an introduction message and, for a significant release,"
	@echo "  append information about where to get the release.  (See the 2.2.0"
	@echo "  release for an example.)"
	@echo "- Attach the binary"
	@echo "- Click the 'This is a pre-release' checkbox, if appropriate"
	@echo "- Click 'Publish release'"
	@echo
	@echo "Then, push the versioned docker images to Dockerhub and Quay:"
	@echo
	@echo "- docker push calico/felix:$(VERSION)-$(ARCH)"
    ifeq ($(ARCH),amd64)
	@echo "- docker push calico/felix:$(VERSION)"
    endif
	@echo "- docker push quay.io/calico/felix:$(VERSION)-$(ARCH)"
    ifeq ($(ARCH),amd64)
	@echo "- docker push quay.io/calico/felix:$(VERSION)"
    endif
	@echo
	@echo "If this is the latest release from the most recent stable"
	@echo "release series, also push the 'latest' tag:"
	@echo
	@echo "- docker push calico/felix:latest-$(ARCH)"
    ifeq ($(ARCH),amd64)
	@echo "- docker push calico/felix:latest"
    endif
	@echo "- docker push quay.io/calico/felix:latest-$(ARCH)"
    ifeq ($(ARCH),amd64)
	@echo "- docker push quay.io/calico/felix:latest"
    endif
	@echo
	@echo "If you also want to build Debian/Ubuntu and RPM packages for"
	@echo "the new release, use 'make deb' and 'make rpm'."
	@echo
