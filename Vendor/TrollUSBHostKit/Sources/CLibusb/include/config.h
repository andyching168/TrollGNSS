/* config.h.  Manually generated for Xcode.  */

#include <AvailabilityMacros.h>

/* Define to the attribute for default visibility. */
#define DEFAULT_VISIBILITY __attribute__ ((visibility ("default")))

/* Define to 1 to enable message logging. */
#define ENABLE_LOGGING 1

/* Force full debug output regardless of any libusb_context's configured log
   level. Needed for Phase 0 USB diagnostics: our shim always retrieves an
   explicit context via libusb_init(&ctx), and libusb's per-context debug
   level can only be set through libusb_set_option(NULL, ...) *before*
   libusb_init(NULL) creates the implicit default context -- that shortcut
   does not apply to libusb_init(&ctx), so without this flag the darwin
   backend's initial device scan (which runs synchronously inside
   libusb_init, before we get a context handle back) always logs at
   LIBUSB_LOG_LEVEL_NONE and nothing is ever captured. */
#if defined(DEBUG) && DEBUG
#define ENABLE_DEBUG_LOGGING 1
#endif

/* On 10.12 and later, use newly available clock_*() functions */
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 101200
/* Define to 1 if you have the `clock_gettime' function. */
#define HAVE_CLOCK_GETTIME 1
#endif

/* On 10.6 and later, use newly available pthread_threadid_np() function */
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060
/* Define to 1 if you have the 'pthread_threadid_np' function. */
#define HAVE_PTHREAD_THREADID_NP 1
#endif

/* Define to 1 if the system has the type `nfds_t'. */
#define HAVE_NFDS_T 1

/* Define to 1 if you have the <sys/time.h> header file. */
#define HAVE_SYS_TIME_H 1

/* Define to 1 if compiling for a POSIX platform. */
#define PLATFORM_POSIX 1

/* Define to the attribute for enabling parameter checks on printf-like
   functions. */
#define PRINTF_FORMAT(a, b) __attribute__ ((__format__ (__printf__, a, b)))

/* Enable GNU extensions. */
#define _GNU_SOURCE 1
