// usbhost_shim.c
// Thin wrappers over the vendored libusb. Keeps libusb types out of Swift.
#include "usbhost_shim.h"

#include <libusb.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <sys/time.h>
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>

// Bounded capture of libusb's own debug log, so Phase 0 hardware runs can
// show exactly why darwin_scan_devices skipped a device (e.g. the IOReturn
// from IOCreatePlugInInterfaceForService) without needing a host Mac attached.
#define UHS_LOG_CAP (16 * 1024)
static pthread_mutex_t uhs_log_lock = PTHREAD_MUTEX_INITIALIZER;
static CFMutableStringRef uhs_log_buffer = NULL;

static void uhs_log_callback(libusb_context *ctx, enum libusb_log_level level, const char *str) {
    (void)ctx;
    (void)level;
    // The 50 ms event-loop heartbeat can evict the useful open/capture error
    // from the bounded on-device log in a few seconds.
    if (str != NULL &&
        (strstr(str, "[usbi_wait_for_events]") != NULL ||
         strstr(str, "[libusb_get_next_timeout]") != NULL ||
         strstr(str, "[libusb_handle_events_timeout_completed]") != NULL)) {
        return;
    }
    pthread_mutex_lock(&uhs_log_lock);
    if (uhs_log_buffer == NULL) {
        uhs_log_buffer = CFStringCreateMutable(kCFAllocatorDefault, 0);
    }
    if (uhs_log_buffer != NULL && str != NULL) {
        CFStringAppendCString(uhs_log_buffer, str, kCFStringEncodingUTF8);
        CFIndex length = CFStringGetLength(uhs_log_buffer);
        if (length > UHS_LOG_CAP) {
            CFStringDelete(uhs_log_buffer, CFRangeMake(0, length - UHS_LOG_CAP));
        }
    }
    pthread_mutex_unlock(&uhs_log_lock);
}

char *uhs_get_log(void) {
    pthread_mutex_lock(&uhs_log_lock);
    CFStringRef snapshot = uhs_log_buffer != NULL ? CFStringCreateCopy(kCFAllocatorDefault, uhs_log_buffer) : NULL;
    pthread_mutex_unlock(&uhs_log_lock);
    if (snapshot == NULL) {
        return NULL;
    }
    size_t utf8Length = (size_t)CFStringGetLength(snapshot) * 4 + 1;
    char *result = (char *)calloc(utf8Length, 1);
    if (result != NULL) {
        CFStringGetCString(snapshot, result, utf8Length, kCFStringEncodingUTF8);
    }
    CFRelease(snapshot);
    return result;
}

uhs_error uhs_init(uhs_context **context) {
    // libusb_init() runs the darwin backend's initial device scan
    // synchronously before it returns, so the log callback must be
    // registered before calling it -- otherwise the one scan that actually
    // touches already-connected devices logs nothing. GLOBAL mode alone is
    // enough and is safe to register against the default (NULL) context
    // before any context exists: log_str() (which invokes the global
    // handler) runs unconditionally for every message regardless of
    // context, and with ENABLE_DEBUG_LOGGING (config.h) regardless of level
    // too -- that flag is what actually makes the darwin backend's initial
    // scan log anything at all, since our shim always retrieves an explicit
    // context via libusb_init(&ctx), which bypasses libusb's normal
    // default-context log-level mechanism (see config.h for why).
    libusb_set_log_cb(NULL, uhs_log_callback, LIBUSB_LOG_CB_GLOBAL);

    libusb_context *ctx = NULL;
    int rc = libusb_init(&ctx);
    if (rc != LIBUSB_SUCCESS) {
        return (uhs_error)rc;
    }
    *context = (uhs_context *)ctx;
    return UHS_OK;
}

void uhs_exit(uhs_context *context) {
    if (context != NULL) {
        libusb_exit((libusb_context *)context);
    }
}

uhs_error uhs_handle_events_timeout(uhs_context *context, double timeout_seconds, int *completed) {
    if (context == NULL) {
        return UHS_ERROR_INVALID_PARAM;
    }
    struct timeval tv;
    tv.tv_sec = (time_t)timeout_seconds;
    tv.tv_usec = (suseconds_t)((timeout_seconds - (double)tv.tv_sec) * 1000000.0);
    int rc = libusb_handle_events_timeout_completed((libusb_context *)context, &tv, completed);
    return (uhs_error)rc;
}

uhs_error uhs_get_device_list(uhs_context *context, uhs_device_list *out) {
    if (context == NULL || out == NULL) {
        return UHS_ERROR_INVALID_PARAM;
    }
    libusb_device **devices = NULL;
    ssize_t count = libusb_get_device_list((libusb_context *)context, &devices);
    if (count < 0) {
        out->devices = NULL;
        out->count = 0;
        return (uhs_error)count;
    }
    out->devices = (uhs_device **)devices;
    out->count = count;
    return UHS_OK;
}

void uhs_free_device_list(uhs_device_list *list, int unref_devices) {
    if (list != NULL && list->devices != NULL) {
        libusb_free_device_list((libusb_device **)list->devices, unref_devices);
        list->devices = NULL;
        list->count = 0;
    }
}

uhs_error uhs_get_device_descriptor(uhs_device *device, uhs_device_descriptor *out) {
    if (device == NULL || out == NULL) {
        return UHS_ERROR_INVALID_PARAM;
    }
    struct libusb_device_descriptor desc;
    int rc = libusb_get_device_descriptor((libusb_device *)device, &desc);
    if (rc != LIBUSB_SUCCESS) {
        return (uhs_error)rc;
    }
    out->b_length = desc.bLength;
    out->b_descriptor_type = desc.bDescriptorType;
    out->bcd_usb = desc.bcdUSB;
    out->b_device_class = desc.bDeviceClass;
    out->b_device_subclass = desc.bDeviceSubClass;
    out->b_device_protocol = desc.bDeviceProtocol;
    out->b_max_packet_size0 = desc.bMaxPacketSize0;
    out->id_vendor = desc.idVendor;
    out->id_product = desc.idProduct;
    out->bcd_device = desc.bcdDevice;
    out->i_manufacturer = desc.iManufacturer;
    out->i_product = desc.iProduct;
    out->i_serial_number = desc.iSerialNumber;
    out->b_num_configurations = desc.bNumConfigurations;
    return UHS_OK;
}

uhs_error uhs_get_speed(uhs_device *device, uhs_speed *out) {
    if (device == NULL || out == NULL) {
        return UHS_ERROR_INVALID_PARAM;
    }
    int speed = libusb_get_device_speed((libusb_device *)device);
    switch (speed) {
    case LIBUSB_SPEED_LOW:
        *out = UHS_SPEED_LOW;
        break;
    case LIBUSB_SPEED_FULL:
        *out = UHS_SPEED_FULL;
        break;
    case LIBUSB_SPEED_HIGH:
        *out = UHS_SPEED_HIGH;
        break;
    case LIBUSB_SPEED_SUPER:
        *out = UHS_SPEED_SUPER;
        break;
    case LIBUSB_SPEED_SUPER_PLUS:
        *out = UHS_SPEED_SUPER_PLUS;
        break;
    default:
        *out = UHS_SPEED_UNKNOWN;
        break;
    }
    return UHS_OK;
}

uint8_t uhs_get_device_bus_number(uhs_device *device) {
    if (device == NULL) {
        return 0;
    }
    return (uint8_t)libusb_get_bus_number((libusb_device *)device);
}

uint8_t uhs_get_device_address(uhs_device *device) {
    if (device == NULL) {
        return 0;
    }
    return (uint8_t)libusb_get_device_address((libusb_device *)device);
}

uhs_error uhs_get_active_config(uhs_device *device, uhs_config_info *out) {
    if (device == NULL || out == NULL) {
        return UHS_ERROR_INVALID_PARAM;
    }
    struct libusb_config_descriptor *config = NULL;
    int rc = libusb_get_active_config_descriptor((libusb_device *)device, &config);
    if (rc != LIBUSB_SUCCESS) {
        out->b_configuration_value = 0;
        out->b_num_interfaces = 0;
        out->interfaces = NULL;
        return (uhs_error)rc;
    }

    out->b_configuration_value = config->bConfigurationValue;
    out->b_num_interfaces = config->bNumInterfaces;
    out->interfaces = (uhs_interface_info *)calloc(config->bNumInterfaces, sizeof(uhs_interface_info));
    if (config->bNumInterfaces > 0 && out->interfaces == NULL) {
        libusb_free_config_descriptor(config);
        return UHS_ERROR_NO_MEM;
    }

    for (int i = 0; i < config->bNumInterfaces; i++) {
        const struct libusb_interface *iface = &config->interface[i];
        const struct libusb_interface_descriptor *alt = NULL;
        for (int a = 0; a < iface->num_altsetting; a++) {
            if (iface->altsetting[a].bAlternateSetting == 0) {
                alt = &iface->altsetting[a];
                break;
            }
        }
        if (alt == NULL && iface->num_altsetting > 0) {
            alt = &iface->altsetting[0];
        }
        uhs_interface_info *dst = &out->interfaces[i];
        if (alt == NULL) {
            dst->b_num_endpoints = 0;
            continue;
        }
        dst->b_interface_number = alt->bInterfaceNumber;
        dst->b_alternate_setting = alt->bAlternateSetting;
        dst->b_num_endpoints = alt->bNumEndpoints;
        dst->b_interface_class = alt->bInterfaceClass;
        dst->b_interface_subclass = alt->bInterfaceSubClass;
        dst->b_interface_protocol = alt->bInterfaceProtocol;
        dst->i_interface = alt->iInterface;
        dst->endpoints = (uhs_endpoint_info *)calloc(alt->bNumEndpoints, sizeof(uhs_endpoint_info));
        if (alt->bNumEndpoints > 0 && dst->endpoints == NULL) {
            libusb_free_config_descriptor(config);
            uhs_free_config(out);
            return UHS_ERROR_NO_MEM;
        }
        for (int e = 0; e < alt->bNumEndpoints; e++) {
            const struct libusb_endpoint_descriptor *src = &alt->endpoint[e];
            dst->endpoints[e].b_endpoint_address = src->bEndpointAddress;
            dst->endpoints[e].bm_attributes = src->bmAttributes;
            dst->endpoints[e].w_max_packet_size = src->wMaxPacketSize;
            dst->endpoints[e].b_interval = src->bInterval;
        }
    }
    libusb_free_config_descriptor(config);
    return UHS_OK;
}

void uhs_free_config(uhs_config_info *config) {
    if (config == NULL) {
        return;
    }
    for (int i = 0; i < config->b_num_interfaces; i++) {
        free(config->interfaces[i].endpoints);
    }
    free(config->interfaces);
    config->interfaces = NULL;
    config->b_num_interfaces = 0;
}

uhs_error uhs_open(uhs_device *device, uhs_device_handle **out) {
    if (device == NULL || out == NULL) {
        return UHS_ERROR_INVALID_PARAM;
    }
    libusb_device_handle *handle = NULL;
    int rc = libusb_open((libusb_device *)device, &handle);
    if (rc != LIBUSB_SUCCESS) {
        return (uhs_error)rc;
    }
    *out = (uhs_device_handle *)handle;
    return UHS_OK;
}

void uhs_close(uhs_device_handle *handle) {
    if (handle != NULL) {
        libusb_close((libusb_device_handle *)handle);
    }
}

uhs_error uhs_set_auto_detach_kernel_driver(uhs_device_handle *handle, bool enabled) {
    if (handle == NULL) {
        return UHS_ERROR_INVALID_PARAM;
    }
    int rc = libusb_set_auto_detach_kernel_driver((libusb_device_handle *)handle,
                                                   enabled ? 1 : 0);
    return (uhs_error)rc;
}

uhs_error uhs_claim_interface(uhs_device_handle *handle, uint8_t interface_number) {
    if (handle == NULL) {
        return UHS_ERROR_INVALID_PARAM;
    }
    int rc = libusb_claim_interface((libusb_device_handle *)handle, interface_number);
    return (uhs_error)rc;
}

uhs_error uhs_release_interface(uhs_device_handle *handle, uint8_t interface_number) {
    if (handle == NULL) {
        return UHS_ERROR_INVALID_PARAM;
    }
    int rc = libusb_release_interface((libusb_device_handle *)handle, interface_number);
    return (uhs_error)rc;
}

uhs_error uhs_reset_device(uhs_device_handle *handle) {
    if (handle == NULL) {
        return UHS_ERROR_INVALID_PARAM;
    }
    int rc = libusb_reset_device((libusb_device_handle *)handle);
    return (uhs_error)rc;
}

uhs_error uhs_get_string_descriptor_ascii(uhs_device_handle *handle,
                                          uint8_t desc_index,
                                          char *buffer,
                                          size_t length) {
    if (handle == NULL || buffer == NULL || length == 0) {
        return UHS_ERROR_INVALID_PARAM;
    }
    int rc = libusb_get_string_descriptor_ascii((libusb_device_handle *)handle,
                                                desc_index,
                                                (unsigned char *)buffer,
                                                (int)length);
    if (rc < 0) {
        return (uhs_error)rc;
    }
    return UHS_OK;
}

uhs_error uhs_control_transfer(uhs_device_handle *handle,
                               uint8_t bm_request_type,
                               uint8_t b_request,
                               uint16_t w_value,
                               uint16_t w_index,
                               unsigned char *data,
                               uint16_t w_length,
                               unsigned int timeout_ms) {
    if (handle == NULL) {
        return UHS_ERROR_INVALID_PARAM;
    }
    int rc = libusb_control_transfer((libusb_device_handle *)handle,
                                     bm_request_type,
                                     b_request,
                                     w_value,
                                     w_index,
                                     data,
                                     w_length,
                                     timeout_ms);
    if (rc < 0) {
        return (uhs_error)rc;
    }
    return UHS_OK;
}

uhs_error uhs_bulk_transfer(uhs_device_handle *handle,
                            uint8_t endpoint,
                            unsigned char *data,
                            int length,
                            int *transferred,
                            unsigned int timeout_ms) {
    if (handle == NULL) {
        return UHS_ERROR_INVALID_PARAM;
    }
    int rc = libusb_bulk_transfer((libusb_device_handle *)handle,
                                  endpoint,
                                  data,
                                  length,
                                  transferred,
                                  timeout_ms);
    return (uhs_error)rc;
}

// ---------------------------------------------------------------------------
// Hotplug events
// ---------------------------------------------------------------------------

typedef struct uhs_hotplug_registration {
    uhs_hotplug_cb cb;
    void *user_data;
} uhs_hotplug_registration;

struct uhs_hotplug_handle {
    libusb_context *ctx;
    libusb_hotplug_callback_handle handle;
    uhs_hotplug_registration *registration;
};

static void uhs_fill_device_descriptor(const struct libusb_device_descriptor *desc,
                                       uhs_device_descriptor *out) {
    out->b_length = desc->bLength;
    out->b_descriptor_type = desc->bDescriptorType;
    out->bcd_usb = desc->bcdUSB;
    out->b_device_class = desc->bDeviceClass;
    out->b_device_subclass = desc->bDeviceSubClass;
    out->b_device_protocol = desc->bDeviceProtocol;
    out->b_max_packet_size0 = desc->bMaxPacketSize0;
    out->id_vendor = desc->idVendor;
    out->id_product = desc->idProduct;
    out->bcd_device = desc->bcdDevice;
    out->i_manufacturer = desc->iManufacturer;
    out->i_product = desc->iProduct;
    out->i_serial_number = desc->iSerialNumber;
    out->b_num_configurations = desc->bNumConfigurations;
}

static int LIBUSB_CALL uhs_hotplug_callback(libusb_context *ctx,
                                            libusb_device *device,
                                            libusb_hotplug_event event,
                                            void *user_data) {
    (void)ctx;
    uhs_hotplug_registration *reg = (uhs_hotplug_registration *)user_data;
    if (reg == NULL || reg->cb == NULL || device == NULL) {
        return 0;
    }

    uhs_hotplug_info info;
    memset(&info, 0, sizeof(info));
    info.event = (event == LIBUSB_HOTPLUG_EVENT_DEVICE_ARRIVED) ? UHS_HOTPLUG_ATTACHED : UHS_HOTPLUG_DETACHED;
    info.bus_number = (uint8_t)libusb_get_bus_number(device);
    info.device_address = (uint8_t)libusb_get_device_address(device);

    /* The descriptor is cached on the libusb_device, so it is still readable
       for a DEVICE_LEFT event. */
    struct libusb_device_descriptor desc;
    if (libusb_get_device_descriptor(device, &desc) == LIBUSB_SUCCESS) {
        uhs_fill_device_descriptor(&desc, &info.descriptor);
    }

    reg->cb(&info, reg->user_data);
    return 0;
}

uhs_error uhs_hotplug_register(uhs_context *context, uhs_hotplug_cb cb, void *user_data, uhs_hotplug_handle **out) {
    if (context == NULL || out == NULL) {
        return UHS_ERROR_INVALID_PARAM;
    }

    uhs_hotplug_registration *reg = calloc(1, sizeof(*reg));
    struct uhs_hotplug_handle *handle = calloc(1, sizeof(*handle));
    if (reg == NULL || handle == NULL) {
        free(reg);
        free(handle);
        return UHS_ERROR_NO_MEM;
    }
    reg->cb = cb;
    reg->user_data = user_data;

    int rc = libusb_hotplug_register_callback((libusb_context *)context,
                                              LIBUSB_HOTPLUG_EVENT_DEVICE_ARRIVED |
                                              LIBUSB_HOTPLUG_EVENT_DEVICE_LEFT,
                                              LIBUSB_HOTPLUG_NO_FLAGS,
                                              LIBUSB_HOTPLUG_MATCH_ANY,
                                              LIBUSB_HOTPLUG_MATCH_ANY,
                                              LIBUSB_HOTPLUG_MATCH_ANY,
                                              uhs_hotplug_callback,
                                              reg,
                                              &handle->handle);
    if (rc != LIBUSB_SUCCESS) {
        free(reg);
        free(handle);
        return (uhs_error)rc;
    }
    handle->ctx = (libusb_context *)context;
    handle->registration = reg;
    *out = handle;
    return UHS_OK;
}

void uhs_hotplug_deregister(uhs_hotplug_handle *handle) {
    if (handle == NULL) {
        return;
    }
    if (handle->handle != 0 && handle->ctx != NULL) {
        libusb_hotplug_deregister_callback(handle->ctx, handle->handle);
    }
    free(handle->registration);
    free(handle);
}

// ---------------------------------------------------------------------------
// Async transfers
// ---------------------------------------------------------------------------

struct uhs_transfer {
    struct libusb_transfer *transfer;
    uhs_transfer_cb cb;
    void *user_data;
    size_t data_offset; /* LIBUSB_CONTROL_SETUP_SIZE for control transfers */
};

static uhs_error uhs_status_from_transfer_status(enum libusb_transfer_status status) {
    switch (status) {
    case LIBUSB_TRANSFER_COMPLETED:
        return UHS_OK;
    case LIBUSB_TRANSFER_TIMED_OUT:
        return UHS_ERROR_TIMEOUT;
    case LIBUSB_TRANSFER_STALL:
        return UHS_ERROR_PIPE;
    case LIBUSB_TRANSFER_OVERFLOW:
        return UHS_ERROR_OVERFLOW;
    case LIBUSB_TRANSFER_NO_DEVICE:
        return UHS_ERROR_NO_DEVICE;
    case LIBUSB_TRANSFER_CANCELLED:
        return UHS_ERROR_INTERRUPTED;
    case LIBUSB_TRANSFER_ERROR:
    default:
        return UHS_ERROR_IO;
    }
}

static void LIBUSB_CALL uhs_transfer_completed(struct libusb_transfer *transfer) {
    struct uhs_transfer *uhs = (struct uhs_transfer *)transfer->user_data;
    if (uhs == NULL) {
        libusb_free_transfer(transfer);
        return;
    }

    uhs_transfer_cb cb = uhs->cb;
    void *user_data = uhs->user_data;
    uhs_error status = uhs_status_from_transfer_status(transfer->status);
    int transferred = transfer->actual_length;
    const unsigned char *data = transfer->buffer + uhs->data_offset;

    /* The buffer is valid until the token is freed, so hand both the bytes and
       the token to the callback. The caller (Swift) must call
       uhs_free_transfer() exactly once -- it owns the libusb_transfer and the
       shim token after this point. */
    if (cb != NULL) {
        cb(status, transferred, data, uhs, user_data);
    }
}

uhs_error uhs_submit_bulk(uhs_device_handle *handle,
                          uint8_t endpoint,
                          unsigned char *data,
                          int length,
                          unsigned int timeout_ms,
                          uhs_transfer_cb cb,
                          void *user_data,
                          uhs_transfer **out) {
    if (handle == NULL || data == NULL || length < 0 || out == NULL) {
        return UHS_ERROR_INVALID_PARAM;
    }

    struct uhs_transfer *uhs = calloc(1, sizeof(*uhs));
    if (uhs == NULL) {
        return UHS_ERROR_NO_MEM;
    }
    struct libusb_transfer *transfer = libusb_alloc_transfer(0);
    if (transfer == NULL) {
        free(uhs);
        return UHS_ERROR_NO_MEM;
    }
    unsigned char *buffer = malloc((size_t)(length > 0 ? length : 1));
    if (buffer == NULL) {
        libusb_free_transfer(transfer);
        free(uhs);
        return UHS_ERROR_NO_MEM;
    }
    if (length > 0) {
        memcpy(buffer, data, (size_t)length);
    }

    uhs->cb = cb;
    uhs->user_data = user_data;
    uhs->data_offset = 0;
    uhs->transfer = transfer;

    libusb_fill_bulk_transfer(transfer, (libusb_device_handle *)handle, endpoint,
                              buffer, length, uhs_transfer_completed, uhs, timeout_ms);
    transfer->flags = LIBUSB_TRANSFER_FREE_BUFFER;

    int rc = libusb_submit_transfer(transfer);
    if (rc != LIBUSB_SUCCESS) {
        libusb_free_transfer(transfer);
        free(uhs);
        return (uhs_error)rc;
    }
    *out = uhs;
    return UHS_OK;
}

uhs_error uhs_cancel_transfer(uhs_transfer *transfer) {
    if (transfer == NULL || transfer->transfer == NULL) {
        return UHS_ERROR_INVALID_PARAM;
    }
    int rc = libusb_cancel_transfer(transfer->transfer);
    return (uhs_error)rc;
}

void uhs_free_transfer(uhs_transfer *transfer) {
    if (transfer == NULL) {
        return;
    }
    if (transfer->transfer != NULL) {
        /* LIBUSB_TRANSFER_FREE_BUFFER frees the data buffer with the transfer. */
        libusb_free_transfer(transfer->transfer);
    }
    free(transfer);
}

const char *uhs_error_name(uhs_error error) {
    const char *name = libusb_error_name((int)error);
    return name != NULL ? name : "UNKNOWN";
}

char *uhs_usb_registry_summary(void) {
    static const char *class_names[] = {
        "IOUSBHostDevice",
        "IOUSBDevice",
        "IOUSBHostInterface",
        "IOUSBInterface",
    };
    const size_t class_count = sizeof(class_names) / sizeof(class_names[0]);

    CFMutableStringRef out = CFStringCreateMutable(kCFAllocatorDefault, 0);
    if (out == NULL) {
        return NULL;
    }

    for (size_t i = 0; i < class_count; i++) {
        CFMutableDictionaryRef matching = IOServiceMatching(class_names[i]);
        if (matching == NULL) {
            CFStringAppendFormat(out, NULL, CFSTR("%s: no matching dict\n"), class_names[i]);
            continue;
        }
        io_iterator_t iter = 0;
        kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter);
        if (kr != KERN_SUCCESS) {
            CFStringAppendFormat(out, NULL, CFSTR("%s: lookup failed (%d)\n"), class_names[i], kr);
            continue;
        }

        io_service_t service = IOIteratorNext(iter);
        int found = 0;
        while (service != 0) {
            found++;

            char serviceName[128] = "?";
            IORegistryEntryGetName(service, serviceName);

            CFTypeRef ioClass = IORegistryEntryCreateCFProperty(service, CFSTR("IOClass"), kCFAllocatorDefault, 0);
            char ioClassStr[64] = "?";
            if (ioClass != NULL && CFGetTypeID(ioClass) == CFStringGetTypeID()) {
                CFStringGetCString((CFStringRef)ioClass, ioClassStr, sizeof(ioClassStr), kCFStringEncodingUTF8);
            }
            if (ioClass != NULL) {
                CFRelease(ioClass);
            }

            CFStringAppendFormat(out, NULL, CFSTR("%s[%d] name=%s class=%s:\n"), class_names[i], found, serviceName, ioClassStr);

            CFMutableDictionaryRef props = NULL;
            kern_return_t kr2 = IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0);
            if (kr2 != KERN_SUCCESS || props == NULL) {
                CFStringAppendFormat(out, NULL, CFSTR("  props denied (%d)\n"), kr2);
            } else {
                CFTypeRef vendor = CFDictionaryGetValue((CFDictionaryRef)props, CFSTR("idVendor"));
                CFTypeRef product = CFDictionaryGetValue((CFDictionaryRef)props, CFSTR("idProduct"));
                if (vendor != NULL && product != NULL &&
                    CFGetTypeID(vendor) == CFNumberGetTypeID() &&
                    CFGetTypeID(product) == CFNumberGetTypeID()) {
                    uint16_t v = 0, p = 0;
                    CFNumberGetValue((CFNumberRef)vendor, kCFNumberSInt16Type, &v);
                    CFNumberGetValue((CFNumberRef)product, kCFNumberSInt16Type, &p);
                    CFStringAppendFormat(out, NULL, CFSTR("  vid:pid 0x%04X:0x%04X\n"), v, p);
                } else {
                    CFStringAppendFormat(out, NULL, CFSTR("  no idVendor/idProduct numbers\n"));
                }
                CFStringRef desc = CFCopyDescription((CFTypeRef)props);
                if (desc != NULL) {
                    size_t descLength = CFStringGetLength(desc);
                    size_t limit = descLength < 300 ? descLength : 300;
                    CFStringRef head = CFStringCreateWithSubstring(kCFAllocatorDefault, desc, CFRangeMake(0, limit));
                    if (head != NULL) {
                        CFStringAppendFormat(out, NULL, CFSTR("  props=%@\n"), head);
                        CFRelease(head);
                    }
                    CFRelease(desc);
                }
                CFRelease(props);
            }
            IOObjectRelease(service);
            service = IOIteratorNext(iter);
        }
        IOObjectRelease(iter);

        if (found == 0) {
            CFStringAppendFormat(out, NULL, CFSTR("%s: 0\n"), class_names[i]);
        }
    }

    size_t utf8Length = CFStringGetLength(out) * 4 + 1;
    char *result = (char *)calloc(utf8Length, 1);
    if (result != NULL) {
        CFStringGetCString(out, result, utf8Length, kCFStringEncodingUTF8);
    }
    CFRelease(out);
    return result;
}

void uhs_free_string(char *str) {
    free(str);
}
