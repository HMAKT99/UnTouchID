CC = clang
CFLAGS = -Wall -Wextra -Werror -O2 -std=c11 -fPIC
LDFLAGS = -lpam -framework Foundation -framework Security
SDK = $(shell xcrun --show-sdk-path)
INCLUDES = -isysroot $(SDK)

TARGET = pam_touchbridge.so

.PHONY: all clean test

all: $(TARGET) touchbridge-trust

$(TARGET): pam_touchbridge.c pam_touchbridge.h evidence.m evidence.h
	$(CC) $(CFLAGS) $(INCLUDES) -arch arm64 -c pam_touchbridge.c -o pam_entry_arm64.o
	$(CC) $(CFLAGS) $(INCLUDES) -arch x86_64 -c pam_touchbridge.c -o pam_entry_x86_64.o
	$(CC) $(CFLAGS) $(INCLUDES) -fobjc-arc -arch arm64 -shared -o pam_touchbridge_arm64.so pam_entry_arm64.o evidence.m $(LDFLAGS)
	$(CC) $(CFLAGS) $(INCLUDES) -fobjc-arc -arch x86_64 -shared -o pam_touchbridge_x86_64.so pam_entry_x86_64.o evidence.m $(LDFLAGS)
	lipo -create pam_touchbridge_arm64.so pam_touchbridge_x86_64.so -output $(TARGET)
	@rm -f pam_touchbridge_arm64.so pam_touchbridge_x86_64.so pam_entry_arm64.o pam_entry_x86_64.o
	@echo "Built $(TARGET) (universal binary)"

touchbridge-trust: trust_admin.m evidence.m evidence.h
	$(CC) $(CFLAGS) $(INCLUDES) -fobjc-arc -arch arm64 -arch x86_64 trust_admin.m evidence.m -framework Foundation -framework Security -o $@

test:
	$(CC) $(CFLAGS) $(INCLUDES) -fobjc-arc -DTB_TESTING -I. tests/evidence_tests.m evidence.m -framework Foundation -framework Security -o evidence-tests
	./evidence-tests
	bash tests/pam_scripts_test.sh

clean:
	rm -f $(TARGET) pam_touchbridge_arm64.so pam_touchbridge_x86_64.so pam_entry_arm64.o pam_entry_x86_64.o touchbridge-trust evidence-tests
