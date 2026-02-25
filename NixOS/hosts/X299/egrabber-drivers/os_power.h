#ifndef OS_POWER_COMMON_HEADER_FILE
#define OS_POWER_COMMON_HEADER_FILE

enum OsSystemPowerState {
    OS_POWER_SYSTEM_WORKING     = 1, // working state S0 (maximum power state)
    OS_POWER_SYSTEM_SLEEPING1   = 2, // sleeping state S1
    OS_POWER_SYSTEM_SLEEPING2   = 3, // sleeping state S2
    OS_POWER_SYSTEM_SLEEPING3   = 4, // sleeping state S3
    OS_POWER_SYSTEM_HIBERNATE   = 5, // sleeping state S4 (hibernate)
    OS_POWER_SYSTEM_SHUTDOWN    = 6, // sleeping state S5 (off)
};

enum OsDevicePowerState {
    OS_POWER_DEVICE_D0          = 1, // working state D0 (maximum power state)
    OS_POWER_DEVICE_D1          = 2, // sleeping state D1
    OS_POWER_DEVICE_D2          = 3, // sleeping state D2
    OS_POWER_DEVICE_D3          = 4, // sleeping state D3 (lowest-powered device sleeping state)
};

#endif
