#ifndef CHEAM_H
#define CHEAM_H

#include <stdint.h>
#include <sys/types.h>

#define HEAM_NAME_LEN 64

/// Reads Apple Silicon temperature sensors (private IOHID API).
/// `names` must hold `maxn * HEAM_NAME_LEN` bytes. Returns the number of sensors read.
int heam_read_temps(double *values, char *names, int maxn);

/// AppleSMC access (fans, and the fan-control keys). All return 0 on success.
int heam_smc_open(void);
int heam_smc_read(const char *key, uint8_t *bytes, uint32_t *size, char type[5]);
int heam_smc_write(const char *key, const uint8_t *bytes, uint32_t size);

/// The app macOS holds responsible for a process (XPC services, helpers). Same source as Activity Monitor.
pid_t heam_responsible_pid(pid_t pid);

#endif
