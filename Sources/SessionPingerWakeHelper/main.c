#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/pwr_mgt/IOPMKeys.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define HELPER_VERSION "2"
#define OWNER_IDENTIFIER "com.proxsyi.sessiontracker"
#define ALLOWED_UID_PATH "/Library/Application Support/SessionTracker/allowed_uid"

static void print_usage(void) {
    fprintf(stderr, "usage: wake-helper version | schedule <unix-seconds> | cancel <unix-seconds> | hold <seconds> | sleep\n");
}

static int caller_is_allowed(void) {
    FILE *file = fopen(ALLOWED_UID_PATH, "r");
    if (file == NULL) return 0;
    struct stat info;
    if (fstat(fileno(file), &info) != 0 || info.st_uid != 0 || !S_ISREG(info.st_mode) || (info.st_mode & 0022) != 0) {
        fclose(file);
        return 0;
    }
    unsigned long allowed_uid = 0;
    int parsed = fscanf(file, "%lu", &allowed_uid);
    fclose(file);
    return parsed == 1 && allowed_uid == (unsigned long)getuid();
}

static int parse_timestamp(const char *value, double *timestamp) {
    char *end = NULL;
    errno = 0;
    double parsed = strtod(value, &end);
    if (errno != 0 || end == value || *end != '\0') return 0;
    double now = (double)time(NULL);
    if (parsed < now - 600.0 || parsed > now + (9.0 * 24.0 * 60.0 * 60.0)) return 0;
    *timestamp = parsed;
    return 1;
}

static CFDateRef create_date(double unix_timestamp) {
    return CFDateCreate(kCFAllocatorDefault, unix_timestamp - kCFAbsoluteTimeIntervalSince1970);
}

static int report_result(const char *operation, IOReturn result) {
    if (result == kIOReturnSuccess) return 0;
    fprintf(stderr, "%s failed (IOReturn 0x%08x)\n", operation, result);
    return 1;
}

int main(int argc, const char *argv[]) {
    if (argc == 2 && strcmp(argv[1], "version") == 0) {
        puts(HELPER_VERSION);
        return 0;
    }

    if (geteuid() != 0) {
        fprintf(stderr, "wake helper must be installed root-owned with mode 4755\n");
        return 77;
    }
    if (!caller_is_allowed()) {
        fprintf(stderr, "wake helper rejected this user\n");
        return 77;
    }

    if (argc == 2 && strcmp(argv[1], "sleep") == 0) {
        io_connect_t power_connection = IOPMFindPowerManagement(MACH_PORT_NULL);
        if (power_connection == IO_OBJECT_NULL) {
            fprintf(stderr, "could not connect to macOS power management\n");
            return 1;
        }
        IOReturn result = IOPMSleepSystem(power_connection);
        IOServiceClose(power_connection);
        return report_result("sleep", result);
    }

    if (argc == 3 && strcmp(argv[1], "hold") == 0) {
        char *end = NULL;
        long seconds = strtol(argv[2], &end, 10);
        if (end == argv[2] || *end != '\0' || seconds < 5 || seconds > 120) {
            fprintf(stderr, "invalid wake hold duration\n");
            return 64;
        }
        IOPMAssertionID assertion_id = kIOPMNullAssertionID;
        IOReturn result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventSystemSleep,
            kIOPMAssertionLevelOn,
            CFSTR("Session Pinger scheduled wake"),
            &assertion_id
        );
        if (result != kIOReturnSuccess) {
            return report_result("hold", result);
        }
        sleep((unsigned int)seconds);
        IOPMAssertionRelease(assertion_id);
        return 0;
    }

    if (argc == 3 && (strcmp(argv[1], "schedule") == 0 || strcmp(argv[1], "cancel") == 0)) {
        double timestamp = 0;
        if (!parse_timestamp(argv[2], &timestamp)) {
            fprintf(stderr, "invalid or unsafe wake timestamp\n");
            return 64;
        }
        CFDateRef date = create_date(timestamp);
        if (date == NULL) {
            fprintf(stderr, "could not create wake date\n");
            return 1;
        }
        CFStringRef owner = CFSTR(OWNER_IDENTIFIER);
        CFStringRef event_type = CFSTR(kIOPMAutoWake);
        IOReturn result = strcmp(argv[1], "schedule") == 0
            ? IOPMSchedulePowerEvent(date, owner, event_type)
            : IOPMCancelScheduledPowerEvent(date, owner, event_type);
        CFRelease(date);
        return report_result(argv[1], result);
    }

    print_usage();
    return 64;
}
