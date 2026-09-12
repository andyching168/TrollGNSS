// usbhost_shim.h
// Small C shim over the vendored UTM libusb fork so the Swift layer never
// touches libusb's public C API directly. Declares a small stable surface;
// Phase 1 fills in the full session and hotplug behavior.
#ifndef USBHOST_SHIM_H
#define USBHOST_SHIM_H

#include <stdint.h>
#include <stdbool.h>
#include <sys/types.h>

#if defined(__cplusplus)
extern "C" {
#endif

typedef struct uhs_context uhs_context;
typedef struct uhs_device uhs_device;
typedef struct uhs_device_handle uhs_device_handle;

typedef enum uhs_error {
    UHS_OK = 0,
    UHS_ERROR_IO = -1,
    UHS_ERROR_INVALID_PARAM = -2,
    UHS_ERROR_ACCESS = -3,
    UHS_ERROR_NO_DEVICE = -4,
    UHS_ERROR_NOT_FOUND = -5,
    UHS_ERROR_BUSY = -6,
    UHS_ERROR_TIMEOUT = -7,
    UHS_ERROR_OVERFLOW = -8,
    UHS_ERROR_PIPE = -9,
    UHS_ERROR_INTERRUPTED = -10,
    UHS_ERROR_NO_MEM = -11,
    UHS_ERROR_NOT_SUPPORTED = -12,
    UHS_ERROR_OTHER = -99,
} uhs_error;

typedef enum uhs_speed {
    UHS_SPEED_UNKNOWN = 0,
    UHS_SPEED_LOW = 1,
    UHS_SPEED_FULL = 2,
    UHS_SPEED_HIGH = 3,
    UHS_SPEED_SUPER = 4,
    UHS_SPEED_SUPER_PLUS = 5,
} uhs_speed;

typedef struct uhs_device_descriptor {
    uint8_t b_length;
    uint8_t b_descriptor_type;
    uint16_t bcd_usb;
    uint8_t b_device_class;
    uint8_t b_device_subclass;
    uint8_t b_device_protocol;
    uint8_t b_max_packet_size0;
    uint16_t id_vendor;
    uint16_t id_product;
    uint16_t bcd_device;
    uint8_t i_manufacturer;
    uint8_t i_product;
    uint8_t i_serial_number;
    uint8_t b_num_configurations;
} uhs_device_descriptor;

typedef struct uhs_interface_descriptor {
    uint8_t b_interface_number;
    uint8_t b_alternate_setting;
    uint8_t b_num_endpoints;
    uint8_t b_interface_class;
    uint8_t b_interface_subclass;
    uint8_t b_interface_protocol;
    uint8_t i_interface;
} uhs_interface_descriptor;

typedef struct uhs_endpoint_descriptor {
    uint8_t b_length;
    uint8_t b_descriptor_type;
    uint8_t b_endpoint_address;
    uint8_t bm_attributes;
    uint16_t w_max_packet_size;
    uint8_t b_interval;
} uhs_endpoint_descriptor;

// Active configuration: one entry per interface (default altsetting), with
// its endpoints. Owned storage; release with uhs_free_config.
typedef struct uhs_endpoint_info {
    uint8_t b_endpoint_address;
    uint8_t bm_attributes;
    uint16_t w_max_packet_size;
    uint8_t b_interval;
} uhs_endpoint_info;

typedef struct uhs_interface_info {
    uint8_t b_interface_number;
    uint8_t b_alternate_setting;
    uint8_t b_num_endpoints;
    uint8_t b_interface_class;
    uint8_t b_interface_subclass;
    uint8_t b_interface_protocol;
    uint8_t i_interface;
    uhs_endpoint_info *endpoints;
} uhs_interface_info;

typedef struct uhs_config_info {
    uint8_t b_configuration_value;
    uint8_t b_num_interfaces;
    uhs_interface_info *interfaces;
} uhs_config_info;

// Context
uhs_error uhs_init(uhs_context **context);
void uhs_exit(uhs_context *context);
// Drives the libusb event loop (hotplug dispatch, async transfer completions).
// Blocks up to timeout_seconds; *completed is set to 1 when the caller should
// stop (e.g. context is being destroyed).
uhs_error uhs_handle_events_timeout(uhs_context *context, double timeout_seconds, int *completed);

// Device discovery
typedef struct uhs_device_list {
    uhs_device **devices;
    ssize_t count;
} uhs_device_list;

uhs_error uhs_get_device_list(uhs_context *context, uhs_device_list *out);
void uhs_free_device_list(uhs_device_list *list, int unref_devices);

uhs_error uhs_get_device_descriptor(uhs_device *device, uhs_device_descriptor *out);
uhs_error uhs_get_speed(uhs_device *device, uhs_speed *out);
uint8_t uhs_get_device_bus_number(uhs_device *device);
uint8_t uhs_get_device_address(uhs_device *device);

// Active configuration interfaces/endpoints (default altsetting per interface).
uhs_error uhs_get_active_config(uhs_device *device, uhs_config_info *out);
void uhs_free_config(uhs_config_info *config);

// Device session
uhs_error uhs_open(uhs_device *device, uhs_device_handle **out);
void uhs_close(uhs_device_handle *handle);
// When enabled, claiming an interface asks Darwin to authorize/capture the
// device and detach an in-kernel class driver (for example CDC-ACM) first.
uhs_error uhs_set_auto_detach_kernel_driver(uhs_device_handle *handle, bool enabled);
uhs_error uhs_claim_interface(uhs_device_handle *handle, uint8_t interface_number);
uhs_error uhs_release_interface(uhs_device_handle *handle, uint8_t interface_number);
// Re-enumerates the device, which the peer sees as a physical detach and
// re-attach. Backed by USBDeviceReEnumerate. The handle does not survive it even
// on success: close it, wait for the device to return, and open the new one.
uhs_error uhs_reset_device(uhs_device_handle *handle);

// Hotplug (attach/detach) events. The callback runs on the package-owned
// libusb event loop; keep it fast and never block it. user_data stays valid
// until uhs_hotplug_deregister().
typedef enum uhs_hotplug_event {
    UHS_HOTPLUG_ATTACHED = 1,
    UHS_HOTPLUG_DETACHED = 2,
} uhs_hotplug_event;

typedef struct uhs_hotplug_info {
    uhs_hotplug_event event;
    uhs_device_descriptor descriptor;
    uint8_t bus_number;
    uint8_t device_address;
} uhs_hotplug_info;

typedef void (*uhs_hotplug_cb)(const uhs_hotplug_info *info, void *user_data);
typedef struct uhs_hotplug_handle uhs_hotplug_handle;

uhs_error uhs_hotplug_register(uhs_context *context, uhs_hotplug_cb cb, void *user_data, uhs_hotplug_handle **out);
void uhs_hotplug_deregister(uhs_hotplug_handle *handle);

// Async transfers. Submit returns immediately; the completion callback fires
// on the libusb event loop thread exactly once (or on submit error never).
// `data` in the callback points at the transferred bytes and is only valid
// during the callback. `token` is the transfer token; the callback (or its
// caller) must release it with uhs_free_transfer() exactly once. Do not call
// uhs_cancel_transfer() with a token whose completion has already fired.
typedef struct uhs_transfer uhs_transfer;

typedef void (*uhs_transfer_cb)(uhs_error status,
                                int transferred,
                                const unsigned char *data,
                                uhs_transfer *token,
                                void *user_data);

uhs_error uhs_submit_bulk(uhs_device_handle *handle,
                          uint8_t endpoint,
                          unsigned char *data,
                          int length,
                          unsigned int timeout_ms,
                          uhs_transfer_cb cb,
                          void *user_data,
                          uhs_transfer **out);
uhs_error uhs_cancel_transfer(uhs_transfer *transfer);
void uhs_free_transfer(uhs_transfer *transfer);

// String descriptors (ASCII, best effort).
uhs_error uhs_get_string_descriptor_ascii(uhs_device_handle *handle,
                                          uint8_t desc_index,
                                          char *buffer,
                                          size_t length);

// Transfers
uhs_error uhs_control_transfer(uhs_device_handle *handle,
                               uint8_t bm_request_type,
                               uint8_t b_request,
                               uint16_t w_value,
                               uint16_t w_index,
                               unsigned char *data,
                               uint16_t w_length,
                               unsigned int timeout_ms);
uhs_error uhs_bulk_transfer(uhs_device_handle *handle,
                            uint8_t endpoint,
                            unsigned char *data,
                            int length,
                            int *transferred,
                            unsigned int timeout_ms);

// Error mapping helper
const char *uhs_error_name(uhs_error error);

// IORegistry diagnostic independent of libusb: returns a newly allocated
// UTF-8 summary of the USB IOService classes on the system. The caller owns
// the buffer and must release it with uhs_free_string().
char *uhs_usb_registry_summary(void);
void uhs_free_string(char *str);

// libusb debug log captured since uhs_init (bounded, oldest lines dropped).
// Returns a newly allocated UTF-8 snapshot; release with uhs_free_string().
char *uhs_get_log(void);

#if defined(__cplusplus)
}
#endif

#endif // USBHOST_SHIM_H
