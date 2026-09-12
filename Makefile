CC = gcc
CFLAGS = -Wall -Wextra -O2
LDFLAGS = -shared -fPIC

NATIVE_DIR = native
QJS_DIR = $(NATIVE_DIR)/quickjs
SO_TARGET = $(NATIVE_DIR)/librclone.so
QJS_TARGET = $(NATIVE_DIR)/libpipesync_quickjs.so
TEST_BIN = $(NATIVE_DIR)/test_librclone
BIN_TARGET = build/pipesync
DART_SOURCES = $(wildcard dart/lib/*.dart dart/lib/**/*.dart dart/lib/**/**/*.dart dart/bin/*.dart)

.PHONY: all compile android-libs test test-native test-python test-dart test-android clean help

all: compile test

compile: $(SO_TARGET) $(QJS_TARGET) $(TEST_BIN) $(BIN_TARGET) android-libs

$(SO_TARGET): $(NATIVE_DIR)/librclone.c $(NATIVE_DIR)/librclone.h
	@echo "[*] Compiling C-Shared librclone native library..."
	$(CC) $(CFLAGS) $(LDFLAGS) $< -o $@
	@echo "[+] Built $@"

$(QJS_TARGET): $(QJS_DIR)/pipesync_quickjs.c $(QJS_DIR)/pipesync_quickjs.h
	@echo "[*] Compiling embedded QuickJS native FFI library..."
	$(CC) $(CFLAGS) $(LDFLAGS) -D_GNU_SOURCE -DCONFIG_VERSION=\"2026-06-04\" \
		$(QJS_DIR)/pipesync_quickjs.c \
		$(QJS_DIR)/quickjs.c $(QJS_DIR)/cutils.c $(QJS_DIR)/libregexp.c $(QJS_DIR)/libunicode.c $(QJS_DIR)/dtoa.c \
		-lm -lpthread -o $@
	@echo "[+] Built $@"

$(TEST_BIN): $(NATIVE_DIR)/test_librclone.c $(SO_TARGET)
	@echo "[*] Compiling native C verification binary..."
	$(CC) $(CFLAGS) $< -L$(NATIVE_DIR) -lrclone -Wl,-rpath,$(abspath $(NATIVE_DIR)) -o $@
	@echo "[+] Built $@"

$(BIN_TARGET): $(SO_TARGET) $(QJS_TARGET) $(DART_SOURCES)
	@echo "[*] Compiling standalone PipeSync native executable..."
	mkdir -p build
	dart compile exe dart/bin/pipesync.dart -o $@
	@echo "[+] Built $@"

android-libs: $(SO_TARGET) $(QJS_TARGET)
	@echo "[*] Syncing native shared libraries to Android jniLibs..."
	@mkdir -p android/app/src/main/jniLibs/x86_64 android/app/src/main/jniLibs/arm64-v8a
	@cp $(SO_TARGET) android/app/src/main/jniLibs/x86_64/
	@cp $(QJS_TARGET) android/app/src/main/jniLibs/x86_64/
	@cp $(SO_TARGET) android/app/src/main/jniLibs/arm64-v8a/
	@cp $(QJS_TARGET) android/app/src/main/jniLibs/arm64-v8a/
	@echo "[+] Android jniLibs synchronized."

test-native: $(TEST_BIN)
	@echo "[*] Executing Native C tests..."
	./$(TEST_BIN)

test-python: $(SO_TARGET)
	@echo "[*] Executing PipeSync Python Integration Test Suite..."
	python3 tests/run_all_tests.py

test-dart: $(SO_TARGET) $(QJS_TARGET)
	@echo "[*] Executing PipeSync Dart 3.x Native Test Suite..."
	cd dart && dart test

test-android:
	@echo "[*] Executing Android Embedded WebKit Integration Tests..."
	python3 -m unittest tests/test_android_webkit.py

test: test-native test-python test-dart test-android

clean:
	@echo "[*] Cleaning build artifacts..."
	rm -f $(SO_TARGET) $(QJS_TARGET) $(TEST_BIN) $(BIN_TARGET)
	rm -rf __pycache__ */__pycache__ /tmp/pipesync*
