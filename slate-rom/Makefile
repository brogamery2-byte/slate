SDK         := iphoneos
ARCH        := arm64
MIN_IOS     := 18.0
NAME        := main
SRCDIR      := rom/src
ZSIGNDIR    := $(SRCDIR)/LindChain/ProcEnvironment/LiveContainer/ZSign
INCDIRS     := -Irom/src -Irom/stubs -Irom/include -I$(ZSIGNDIR) -I$(ZSIGNDIR)/common
FWFLAGS     := -From/frameworks
CC          := $(shell xcrun -sdk $(SDK) -f clang)
LD          := $(shell xcrun -sdk $(SDK) -f clang++)
SYSROOT     := $(shell xcrun -sdk $(SDK) --show-sdk-path)

ROM_SIGNING_KEY ?= $(HOME)/.config/nyxian/romkey/rom.key.pem
ROM_OUT         ?= rom.zip
ROM_ZIP         := $(abspath $(patsubst ~/%,$(HOME)/%,$(ROM_OUT)))
ROM_KEY         := $(patsubst ~/%,$(HOME)/%,$(ROM_SIGNING_KEY))
ifneq ($(words $(ROM_OUT)),1)
$(error ROM_OUT cannot contain spaces (make splits paths on them): "$(ROM_OUT)")
endif

HELLO_SRC   := appsrc/Hello/main.m
HELLO_PLIST := appsrc/Hello/Info.plist
HELLO_APP   := Application/Hello.app
HELLO_BIN   := $(HELLO_APP)/Hello

NOTES_SRC   := appsrc/Notes/main.m
NOTES_PLIST := appsrc/Notes/Info.plist
NOTES_APP   := Application/Notes.app
NOTES_BIN   := $(NOTES_APP)/Notes

SRCS_ALL    := $(shell find $(SRCDIR) \( -name '*.m' -o -name '*.c' -o -name '*.mm' -o -name '*.cpp' \))
SRCS        := $(filter-out \
               $(SRCDIR)/LindChain/ProcEnvironment/Shims/% \
               $(SRCDIR)/LindChain/ProcEnvironment/LiveContainer/Tweaks/% \
               $(SRCDIR)/LindChain/ProcEnvironment/LiveContainer/LCBootstrap.m, \
               $(SRCS_ALL))
OBJS        := $(SRCS:%=build/%.o)

CFLAGS      := -arch $(ARCH) -isysroot $(SYSROOT) -miphoneos-version-min=$(MIN_IOS) \
               -fobjc-arc -O2 -g -DHOST_ENV=1 -Wno-nonportable-include-path $(INCDIRS)
LDFLAGS     := -arch $(ARCH) -isysroot $(SYSROOT) -miphoneos-version-min=$(MIN_IOS) \
               -dynamiclib -install_name @rpath/$(NAME) \
               -rpath @executable_path/Frameworks $(FWFLAGS) \
               -framework Foundation -framework UIKit -framework CoreFoundation \
               -framework CoreGraphics -framework QuartzCore -framework Security \
               -framework FrontBoard -framework OpenSSL -larchive
HELLO_FLAGS := -arch $(ARCH) -isysroot $(SYSROOT) -miphoneos-version-min=$(MIN_IOS) \
               -fobjc-arc -Os -framework Foundation -framework UIKit
NOTES_FLAGS := $(HELLO_FLAGS)

all: $(ROM_ZIP)

build/%.o: %
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(if $(filter %.cpp,$<),-x c++,$(if $(filter %.mm,$<),-x objective-c++)) -c $< -o $@

$(NAME): $(OBJS)
	$(LD) $(LDFLAGS) $(OBJS) -o $(NAME)

$(HELLO_BIN): $(HELLO_SRC) $(HELLO_PLIST)
	rm -rf $(HELLO_APP)
	mkdir -p $(HELLO_APP)
	cp $(HELLO_PLIST) $(HELLO_APP)/Info.plist
	$(CC) $(HELLO_FLAGS) -dynamiclib -Wl,-install_name,@rpath/Hello $(HELLO_SRC) -o $(HELLO_BIN)

$(NOTES_BIN): $(NOTES_SRC) $(NOTES_PLIST)
	rm -rf $(NOTES_APP)
	mkdir -p $(NOTES_APP)
	cp $(NOTES_PLIST) $(NOTES_APP)/Info.plist
	$(CC) $(NOTES_FLAGS) -dynamiclib -Wl,-install_name,@rpath/Notes $(NOTES_SRC) -o $(NOTES_BIN)

$(ROM_ZIP): $(NAME) $(HELLO_BIN) $(NOTES_BIN) manifest.plist
	@test -f "$(ROM_KEY)" || { echo "no ROM signing key at $(ROM_KEY): python3 RomGen.py genkey --name rom, or make ROM_SIGNING_KEY=..."; exit 1; }
	@case "$(ROM_ZIP)" in *.zip) ;; *) echo "ROM_OUT has to end in .zip: $(ROM_ZIP)"; exit 1;; esac
	rm -rf .rompkg "$(ROM_ZIP)"
	mkdir -p .rompkg/ROM "$(dir $(ROM_ZIP))"
	cp $(NAME) manifest.plist .rompkg/ROM/
	cp -R Application .rompkg/ROM/Application
	cd .rompkg && zip -qry -X "$(ROM_ZIP)" ROM -x '*.DS_Store' '*/._*'
	rm -rf .rompkg
	python3 -I RomGen.py sign "$(ROM_ZIP)" --key "$(ROM_KEY)"
	@echo "ROM: $(ROM_ZIP)"

clean:
	rm -rf build .rompkg Application $(NAME) rom.zip

.PHONY: all clean
